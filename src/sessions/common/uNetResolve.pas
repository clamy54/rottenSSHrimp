{ Resolution DNS annulable. getaddrinfo ne s'interrompt pas (~40 s sous macOS)
  et l'onglet JOINT son thread: on resout dans un thread jetable, qu'on
  abandonne. Refcount atomique, le dernier sorti libere.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uNetResolve;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Sockets, ctypes;

type
  Paddrinfo = ^addrinfo;
  // ai_canonname/ai_addr inverses entre Darwin et Linux; ai_addrlen en size_t
  // sous Windows. Se tromper rend un sockaddr bidon.
  addrinfo = record
    ai_flags: cint;
    ai_family: cint;
    ai_socktype: cint;
    ai_protocol: cint;
    {$IFDEF WINDOWS}
    ai_addrlen: NativeUInt;
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
// WSAStartup: fait par l'unite Sockets de FPC
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
    Taken: Boolean;   // Res appartient a l'appelant
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
  // Terminated est une propriete: pas d'adresse a prendre.
  TAbortQuery = function: Boolean of object;

// True: ARes a liberer par freeaddrinfo. AErr vide sur abandon.
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
  job.AddRef;                          // appelant
  job.AddRef;                          // worker
  try
    TResolveThread.Create(job).Start;
  except
    // Worker mort-ne: on relache aussi SA reference.
    job.Release;
    job.Release;
    AErr := 'DNS resolution: cannot create the resolver thread';
    Exit;
  end;
  while not AAborted() do
    if job.DoneEv.WaitFor(RESOLVE_POLL_MS) = wrSignaled then Break;
  if AAborted() then
  begin
    // le worker liberera le job quand getaddrinfo daignera rendre la main
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
