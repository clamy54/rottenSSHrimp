{ Resolution DNS annulable, partagee par tous les transports.

  getaddrinfo n'est pas interruptible et le destructeur d'un onglet JOINT son
  thread de session: un nom qui ne resout pas gelait l'UI le temps du resolveur
  systeme, ~40 s sous macOS. On resout donc dans un thread jetable, on attend
  par petits pas, et on ABANDONNE le job sans bloquer -- compte de references
  atomique, le dernier a le relacher libere le job et son resultat.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uNetResolve;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Sockets, ctypes;

type
  Paddrinfo = ^addrinfo;
  // Layout par plateforme: ai_canonname et ai_addr sont inverses entre Darwin et
  // Linux, Windows a un ai_addrlen en size_t la ou POSIX veut socklen_t. Se
  // tromper ici rend un pointeur de sockaddr bidon.
  addrinfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
    {$IFDEF WINDOWS}
    ai_addrlen: NativeUInt;   // size_t
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
    {$ELSE}
    ai_addrlen: cuint32;
    {$IFDEF DARWIN}
    ai_canonname: PAnsiChar;
    ai_addr: Pointer;
    {$ELSE}
    ai_addr: Pointer;
    ai_canonname: PAnsiChar;
    {$ENDIF}
    {$ENDIF}
    ai_next: Paddrinfo;
  end;

{$IFDEF WINDOWS}
// le WSAStartup requis vient de l'initialisation de l'unite Sockets de FPC
function getaddrinfo(node, service: PAnsiChar; hints: Paddrinfo;
  res: PPointer): cint; stdcall; external 'ws2_32.dll' name 'getaddrinfo';
procedure freeaddrinfo(ai: Paddrinfo); stdcall;
  external 'ws2_32.dll' name 'freeaddrinfo';
{$ELSE}
function getaddrinfo(node, service: PAnsiChar; hints: Paddrinfo;
  res: PPointer): cint; cdecl; external 'c' name 'getaddrinfo';
procedure freeaddrinfo(ai: Paddrinfo); cdecl; external 'c' name 'freeaddrinfo';
{$ENDIF}

type
  TResolveJob = class
  private
    FRef: LongInt;
  public
    Host, Port: AnsiString;
    Lock: TCriticalSection;
    DoneEv: TEvent;
    Res: Paddrinfo;
    Rc: cint;
    Taken: Boolean;   // l'appelant a pris Res (il en devient responsable)
    constructor Create(const AHost, APort: AnsiString);
    destructor Destroy; override;
    procedure AddRef;
    procedure Release;
  end;

  TResolveThread = class(TThread)
  private
    FJob: TResolveJob;
  protected
    procedure Execute; override;
  public
    constructor Create(AJob: TResolveJob);
  end;

type
  // Terminated est une propriete: pas d'adresse a prendre, d'ou cette methode.
  TAbortQuery = function: Boolean of object;

{ True: ARes appartient a l'appelant, a liberer par freeaddrinfo. False: abandon,
  echec du resolveur ou thread impossible; AErr est vide sur abandon, l'arret
  venant de l'appelant il n'a rien a apprendre. }
function ResolveCancellable(const AHost, APort: AnsiString;
  AAborted: TAbortQuery; out ARes: Paddrinfo; out AErr: string): Boolean;

implementation

const
  RESOLVE_POLL_MS = 200;

constructor TResolveJob.Create(const AHost, APort: AnsiString);
begin
  inherited Create;
  Host := AHost;
  Port := APort;
  Lock := TCriticalSection.Create;
  DoneEv := TEvent.Create(nil, True, False, '');
  Res := nil;
  Rc := 0;
  Taken := False;
  FRef := 0;
end;

destructor TResolveJob.Destroy;
begin
  if (Res <> nil) and (not Taken) then
    freeaddrinfo(Res);
  DoneEv.Free;
  Lock.Free;
  inherited Destroy;
end;

procedure TResolveJob.AddRef;
begin
  InterLockedIncrement(FRef);
end;

procedure TResolveJob.Release;
begin
  if InterLockedDecrement(FRef) = 0 then
    Free;
end;

constructor TResolveThread.Create(AJob: TResolveJob);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FJob := AJob;
end;

procedure TResolveThread.Execute;
var
  res: Paddrinfo;
  rc: cint;
  hints: addrinfo;
begin
  FillChar(hints, SizeOf(hints), 0);
  hints.ai_family := AF_UNSPEC;
  hints.ai_socktype := SOCK_STREAM;
  res := nil;
  rc := getaddrinfo(PAnsiChar(FJob.Host), PAnsiChar(FJob.Port), @hints, @res);
  FJob.Lock.Acquire;
  try
    FJob.Res := res;
    FJob.Rc := rc;
  finally
    FJob.Lock.Release;
  end;
  FJob.DoneEv.SetEvent;
  FJob.Release;   // peut liberer le job
end;

function ResolveCancellable(const AHost, APort: AnsiString;
  AAborted: TAbortQuery; out ARes: Paddrinfo; out AErr: string): Boolean;
var
  job: TResolveJob;
  rc: cint;
begin
  Result := False;
  ARes := nil;
  AErr := '';
  job := TResolveJob.Create(AHost, APort);
  job.AddRef;                          // reference de l'appelant
  job.AddRef;                          // reference du worker
  try
    TResolveThread.Create(job).Start;
  except
    // Le worker ne tournera pas et ne relachera jamais SA reference: on reprend
    // les deux. Le TThread mort-ne peut fuir, il ne touchera plus le job.
    job.Release;
    job.Release;
    AErr := 'DNS resolution: cannot create the resolver thread';
    Exit;
  end;
  while not AAborted() do
    if job.DoneEv.WaitFor(RESOLVE_POLL_MS) = wrSignaled then Break;
  if AAborted() then
  begin
    // on relache sans bloquer: le worker liberera le job en sortant enfin de
    // getaddrinfo
    job.Release;
    Exit;
  end;
  job.Lock.Acquire;
  try
    ARes := job.Res;
    rc := job.Rc;
    job.Taken := True;
  finally
    job.Lock.Release;
  end;
  job.Release;
  if (rc <> 0) or (ARes = nil) then
  begin
    if ARes <> nil then
    begin
      freeaddrinfo(ARes);
      ARes := nil;
    end;
    AErr := Format('Name not found: %s', [string(AHost)]);
    Exit;
  end;
  Result := True;
end;

end.
