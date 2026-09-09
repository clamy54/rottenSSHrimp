{ Ping ICMP sans privilege, portable.

  Windows: IcmpSendEcho2 / Icmp6SendEcho2 (iphlpapi), aucun droit requis.
  macOS et Linux: socket SOCK_DGRAM sur IPPROTO_ICMP(V6), sans root; sous
  Linux elle depend de net.ipv4.ping_group_range, ouvert par defaut depuis
  systemd 243. Refusee (EACCES/EPERM), on se replie sur le binaire ping du
  systeme, lance en LANG=C et lu ligne a ligne -- lui porte la capacite.

  Un thread par cible: resolution, un echo par intervalle avec timeout, et
  chaque resultat remonte au thread UI par Queue (jamais Synchronize: le
  destructeur de l'onglet joint le thread, un Synchronize en attente y
  bloquerait). Rien de LCL ici.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uIcmpPing;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TPingResultKind = (prkReply, prkTimeout, prkUnreachable, prkError);

  TPingSample = record
    Seq: Integer;
    Kind: TPingResultKind;
    RttMs: Double;      // reponse seulement
    Ttl: Integer;       // -1 = inconnu
    Msg: string;        // detail d'une erreur ou d'un « unreachable »
    When: TDateTime;    // heure locale de la reponse ou de l'expiration
  end;

  TPingSampleEvent = procedure(const ASample: TPingSample) of object;
  // AAddr vide = echec de resolution, AErr le dit. AFallback = binaire ping.
  TPingResolvedEvent = procedure(const AAddr, AErr: string;
    AFallback: Boolean) of object;

  TPinger = class(TThread)
  private
    FHost: string;
    FIntervalMs: LongInt;
    FTimeoutMs: LongInt;
    FPaused: LongInt;
    FSeq: Integer;
    FOnSample: TPingSampleEvent;
    FOnResolved: TPingResolvedEvent;
    FLock: SyncObjs.TCriticalSection;
    FQueue: array of TPingSample;
    FQueued: Integer;
    FResAddr, FResErr: string;
    FResFallback, FResPending: Boolean;
    procedure DrainSamples;
    procedure DrainResolved;
    procedure Emit(const ASample: TPingSample);
    procedure EmitResolved(const AAddr, AErr: string; AFallback: Boolean);
    function Aborted: Boolean;
    procedure SleepChecked(AMs: Integer);
    function GetIntervalMs: Integer;
    function GetTimeoutMs: Integer;
    procedure SetIntervalMs(AValue: Integer);
    procedure SetTimeoutMs(AValue: Integer);
    function GetPaused: Boolean;
    procedure SetPaused(AValue: Boolean);
    // True = le backend natif a pris la main; False = a essayer autrement
    function RunNative(AIpv6: Boolean; ASock: Pointer): Boolean;
    procedure RunFallback;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHost: string; AIntervalMs, ATimeoutMs: Integer);
    destructor Destroy; override;
    // Terminate + join, puis purge de ce qui restait en file pour l'UI
    procedure Stop;
    property Host: string read FHost;
    property IntervalMs: Integer read GetIntervalMs write SetIntervalMs;
    property TimeoutMs: Integer read GetTimeoutMs write SetTimeoutMs;
    property Paused: Boolean read GetPaused write SetPaused;
    property OnSample: TPingSampleEvent read FOnSample write FOnSample;
    property OnResolved: TPingResolvedEvent read FOnResolved write FOnResolved;
  end;

const
  PING_INTERVAL_MIN_MS = 200;
  PING_INTERVAL_MAX_MS = 60000;
  PING_TIMEOUT_MIN_MS = 100;
  PING_TIMEOUT_MAX_MS = 30000;

// Horloge haute resolution en millisecondes.
function HiResMs: Double;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF UNIX}BaseUnix, Unix, Process,{$ENDIF}
  Sockets, ctypes, uNetResolve, uSockCompat;

const
  ECHO_PAYLOAD = 32;

type
  TSockAddrBuf = record
    Len: Integer;
    Ipv6: Boolean;
    Data: array[0..127] of Byte;
  end;
  PSockAddrBuf = ^TSockAddrBuf;

{$IFDEF WINDOWS}
// En deux morceaux: compteur x 1000 depasse 2^53. Et transtypages en Double
// explicites: pour FPC une constante « 1000.0 » est un Single, et tout le
// calcul se faisait en simple precision, par pas de 64 ms.
function HiResMs: Double;
var
  f, c: Int64;
begin
  QueryPerformanceFrequency(f);
  QueryPerformanceCounter(c);
  Result := Double(c div f) * 1000 + Double(c mod f) * 1000 / Double(f);
end;
{$ELSE}
// Horloge MONOTONE: les RTT et les echeances sont des durees, et l'heure
// civile bouge (NTP, changement manuel), ce qui donnait des RTT negatifs ou
// un timeout premature. L'identifiant differe entre Linux et macOS.
const
  {$IFDEF DARWIN}
  CLOCK_MONOTONIC_ID = 6;
  {$ELSE}
  CLOCK_MONOTONIC_ID = 1;
  {$ENDIF}

function clock_gettime(AClock: cint; ATs: ptimespec): cint; cdecl;
  external 'c' name 'clock_gettime';

function HiResMs: Double;
var
  ts: timespec;
  tv: TTimeVal;
begin
  if clock_gettime(CLOCK_MONOTONIC_ID, @ts) = 0 then
    // memes transtypages: « 1000.0 » serait un Single pour FPC
    Result := Double(ts.tv_sec) * 1000 + Double(ts.tv_nsec) / 1000000
  else
  begin
    fpGetTimeOfDay(@tv, nil);
    Result := Double(tv.tv_sec) * 1000 + Double(tv.tv_usec) / 1000;
  end;
end;
{$ENDIF}

function AddrToString(const ABuf: TSockAddrBuf): string;
begin
  if ABuf.Ipv6 then
    Result := NetAddrToStr6(psockaddr_in6(@ABuf.Data)^.sin6_addr)
  else
    Result := NetAddrToStr(psockaddr_in(@ABuf.Data)^.sin_addr);
end;

// Premiere adresse, IPv4 de preference: c'est ce que ping fait par defaut.
function PickAddress(AList: Paddrinfo; out ABuf: TSockAddrBuf): Boolean;
var
  ai, best: Paddrinfo;
begin
  Result := False;
  best := nil;
  ai := AList;
  while ai <> nil do
  begin
    if (ai^.ai_addr <> nil) and
       ((ai^.ai_family = AF_INET) or (ai^.ai_family = AF_INET6)) then
    begin
      if (best = nil) or ((best^.ai_family = AF_INET6) and
        (ai^.ai_family = AF_INET)) then
        best := ai;
    end;
    ai := ai^.ai_next;
  end;
  if best = nil then Exit;
  FillChar(ABuf, SizeOf(ABuf), 0);
  ABuf.Ipv6 := best^.ai_family = AF_INET6;
  ABuf.Len := Integer(best^.ai_addrlen);
  if (ABuf.Len <= 0) or (ABuf.Len > SizeOf(ABuf.Data)) then Exit;
  Move(best^.ai_addr^, ABuf.Data, ABuf.Len);
  Result := True;
end;

{ ================================ TPinger ================================ }

constructor TPinger.Create(const AHost: string; AIntervalMs, ATimeoutMs: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHost := AHost;
  FLock := SyncObjs.TCriticalSection.Create;
  SetIntervalMs(AIntervalMs);
  SetTimeoutMs(ATimeoutMs);
  FPaused := 0;
  FSeq := 0;
  FQueued := 0;
end;

destructor TPinger.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

procedure TPinger.Stop;
begin
  Terminate;
  if not Suspended then
    WaitFor
  else
    Start; // un thread jamais lance ne se joint pas: on le laisse sortir
  if not Finished then WaitFor;
  // ce qui n'a pas ete draine ne le sera jamais: l'onglet part
  TThread.RemoveQueuedEvents(Self);
end;

function TPinger.GetIntervalMs: Integer;
begin
  Result := InterLockedExchangeAdd(FIntervalMs, 0);
end;

function TPinger.GetTimeoutMs: Integer;
begin
  Result := InterLockedExchangeAdd(FTimeoutMs, 0);
end;

procedure TPinger.SetIntervalMs(AValue: Integer);
begin
  if AValue < PING_INTERVAL_MIN_MS then AValue := PING_INTERVAL_MIN_MS;
  if AValue > PING_INTERVAL_MAX_MS then AValue := PING_INTERVAL_MAX_MS;
  InterLockedExchange(FIntervalMs, AValue);
end;

procedure TPinger.SetTimeoutMs(AValue: Integer);
begin
  if AValue < PING_TIMEOUT_MIN_MS then AValue := PING_TIMEOUT_MIN_MS;
  if AValue > PING_TIMEOUT_MAX_MS then AValue := PING_TIMEOUT_MAX_MS;
  InterLockedExchange(FTimeoutMs, AValue);
end;

function TPinger.GetPaused: Boolean;
begin
  Result := InterLockedExchangeAdd(FPaused, 0) <> 0;
end;

procedure TPinger.SetPaused(AValue: Boolean);
begin
  InterLockedExchange(FPaused, Ord(AValue));
end;

function TPinger.Aborted: Boolean;
begin
  Result := Terminated;
end;

procedure TPinger.SleepChecked(AMs: Integer);
var
  left: Integer;
begin
  left := AMs;
  while (left > 0) and (not Terminated) do
  begin
    if left > 50 then Sleep(50) else Sleep(left);
    Dec(left, 50);
  end;
end;

// Thread UI
procedure TPinger.DrainSamples;
var
  local: array of TPingSample;
  i: Integer;
begin
  FLock.Acquire;
  try
    SetLength(local, FQueued);
    for i := 0 to FQueued - 1 do local[i] := FQueue[i];
    FQueued := 0;
  finally
    FLock.Release;
  end;
  if Assigned(FOnSample) then
    for i := 0 to High(local) do
      FOnSample(local[i]);
end;

// Thread UI
procedure TPinger.DrainResolved;
var
  a, e: string;
  fb, pending: Boolean;
begin
  FLock.Acquire;
  try
    a := FResAddr; e := FResErr; fb := FResFallback;
    pending := FResPending;
    FResPending := False;
  finally
    FLock.Release;
  end;
  if pending and Assigned(FOnResolved) then
    FOnResolved(a, e, fb);
end;

procedure TPinger.Emit(const ASample: TPingSample);
begin
  if Terminated then Exit;
  FLock.Acquire;
  try
    if FQueued >= Length(FQueue) then
      SetLength(FQueue, FQueued + 16);
    FQueue[FQueued] := ASample;
    Inc(FQueued);
  finally
    FLock.Release;
  end;
  Queue(@DrainSamples);
end;

procedure TPinger.EmitResolved(const AAddr, AErr: string; AFallback: Boolean);
begin
  if Terminated then Exit;
  FLock.Acquire;
  try
    FResAddr := AAddr;
    FResErr := AErr;
    FResFallback := AFallback;
    FResPending := True;
  finally
    FLock.Release;
  end;
  Queue(@DrainResolved);
end;

{ ---- backend natif ---- }

{$IFDEF WINDOWS}

type
  TIpOptionInformation = record
    Ttl, Tos, Flags, OptionsSize: Byte;
    OptionsData: Pointer;
  end;
  TIcmpEchoReply = record
    Address: DWORD;
    Status: DWORD;
    RoundTripTime: DWORD;
    DataSize: Word;
    Reserved: Word;
    Data: Pointer;
    Options: TIpOptionInformation;
  end;
  // IPV6_ADDRESS_EX est packe (26 octets), le reste aligne sur 4
  TIcmpv6EchoReply = record
    Address: array[0..25] of Byte;
    Pad: Word;
    Status: DWORD;
    RoundTripTime: DWORD;
  end;

const
  IP_SUCCESS = 0;
  IP_DEST_NET_UNREACHABLE = 11002;
  IP_DEST_HOST_UNREACHABLE = 11003;
  IP_DEST_PROT_UNREACHABLE = 11004;
  IP_DEST_PORT_UNREACHABLE = 11005;
  IP_REQ_TIMED_OUT = 11010;
  IP_TTL_EXPIRED_TRANSIT = 11013;
  IP_GENERAL_FAILURE = 11050;

function IcmpCreateFile: THandle; stdcall; external 'iphlpapi.dll';
function Icmp6CreateFile: THandle; stdcall; external 'iphlpapi.dll';
function IcmpCloseHandle(h: THandle): BOOL; stdcall; external 'iphlpapi.dll';
function IcmpSendEcho2(h: THandle; Event: THandle; ApcRoutine, ApcContext: Pointer;
  Dest: DWORD; Data: Pointer; Size: Word; Options: Pointer; Reply: Pointer;
  ReplySize, Timeout: DWORD): DWORD; stdcall; external 'iphlpapi.dll';
function Icmp6SendEcho2(h: THandle; Event: THandle; ApcRoutine, ApcContext: Pointer;
  Src, Dest: Pointer; Data: Pointer; Size: Word; Options: Pointer; Reply: Pointer;
  ReplySize, Timeout: DWORD): DWORD; stdcall; external 'iphlpapi.dll';
function IcmpParseReplies(Reply: Pointer; ReplySize: DWORD): DWORD; stdcall;
  external 'iphlpapi.dll';
function Icmp6ParseReplies(Reply: Pointer; ReplySize: DWORD): DWORD; stdcall;
  external 'iphlpapi.dll';

const
  ERROR_IO_PENDING_ = 997;
  REPLY_BUF = 1024;

type
  // IcmpCloseHandle attend l'achevement d'une requete en vol, et ce handle
  // n'est pas un objet noyau: CancelIoEx le refuse. Fermer l'onglet d'un hote
  // muet bloquait donc l'UI le temps du timeout. Ce thread jetable recupere
  // handle, evenement et tampon de reponse, attend la fin et nettoie.
  TIcmpReaper = class(TThread)
  private
    FH, FEv: THandle;
    FBuf: Pointer;
    FMaxWaitMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AH, AEv: THandle; ABuf: Pointer; AMaxWaitMs: Integer);
  end;

constructor TIcmpReaper.Create(AH, AEv: THandle; ABuf: Pointer;
  AMaxWaitMs: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FH := AH; FEv := AEv; FBuf := ABuf; FMaxWaitMs := AMaxWaitMs;
  Start;
end;

procedure TIcmpReaper.Execute;
begin
  WaitForSingleObject(FEv, FMaxWaitMs);
  IcmpCloseHandle(FH);
  CloseHandle(FEv);
  FreeMem(FBuf);
end;

function StatusText(AStatus: DWORD): string;
begin
  case AStatus of
    IP_DEST_NET_UNREACHABLE: Result := 'network unreachable';
    IP_DEST_HOST_UNREACHABLE: Result := 'host unreachable';
    IP_DEST_PROT_UNREACHABLE: Result := 'protocol unreachable';
    IP_DEST_PORT_UNREACHABLE: Result := 'port unreachable';
    IP_TTL_EXPIRED_TRANSIT: Result := 'TTL expired in transit';
    IP_GENERAL_FAILURE: Result := 'general failure';
  else
    Result := Format('ICMP status %d', [AStatus]);
  end;
end;

// Envoi ASYNCHRONE (evenement): un appel bloquant tenait le thread jusqu'au
// timeout, et fermer l'onglet d'un hote muet gelait l'interface d'autant.
// Ici on attend par tranches de 50 ms et Terminated coupe court; fermer le
// handle annule la requete en vol.
function TPinger.RunNative(AIpv6: Boolean; ASock: Pointer): Boolean;
var
  pb: PSockAddrBuf;
  h, ev: THandle;
  src6: sockaddr_in6;
  reqData: array[0..ECHO_PAYLOAD - 1] of Byte;
  reply: PByte;      // sur le tas: un balayeur peut lui survivre
  r4: ^TIcmpEchoReply;
  r6: ^TIcmpv6EchoReply;
  n, status, apiRtt, w: DWORD;
  s: TPingSample;
  t0, t1: Double;
  i: Integer;
  handedOff: Boolean;
begin
  Result := False;
  pb := PSockAddrBuf(ASock);
  if AIpv6 then h := Icmp6CreateFile else h := IcmpCreateFile;
  if (h = INVALID_HANDLE_VALUE) or (h = 0) then Exit;
  Result := True;
  ev := CreateEvent(nil, True, False, nil);
  reply := GetMem(REPLY_BUF);
  r4 := Pointer(reply);
  r6 := Pointer(reply);
  handedOff := False;
  for i := 0 to High(reqData) do reqData[i] := Byte(i);
  FillChar(src6, SizeOf(src6), 0);
  src6.sin6_family := AF_INET6;
  try
    while not Terminated do
    begin
      if Paused then
      begin
        SleepChecked(100);
        Continue;
      end;
      Inc(FSeq);
      s := Default(TPingSample);
      s.Seq := FSeq;
      s.Ttl := -1;
      FillChar(reply^, REPLY_BUF, 0);
      ResetEvent(ev);
      t0 := HiResMs;
      if AIpv6 then
        n := Icmp6SendEcho2(h, ev, nil, nil, @src6, @pb^.Data, @reqData,
          ECHO_PAYLOAD, nil, reply, REPLY_BUF, TimeoutMs)
      else
        n := IcmpSendEcho2(h, ev, nil, nil,
          DWORD(psockaddr_in(@pb^.Data)^.sin_addr.s_addr), @reqData,
          ECHO_PAYLOAD, nil, reply, REPLY_BUF, TimeoutMs);
      status := GetLastError;
      if (n = 0) and (status = ERROR_IO_PENDING_) then
      begin
        repeat
          w := WaitForSingleObject(ev, 50);
        until (w <> WAIT_TIMEOUT) or Terminated;
        if Terminated then
        begin
          // requete en vol: le balayeur fermera, nous on part tout de suite
          TIcmpReaper.Create(h, ev, reply, TimeoutMs + 1000);
          handedOff := True;
          Break;
        end;
        if AIpv6 then
          n := Icmp6ParseReplies(reply, REPLY_BUF)
        else
          n := IcmpParseReplies(reply, REPLY_BUF);
        status := GetLastError;
      end;
      t1 := HiResMs;
      s.When := Now;
      if n > 0 then
      begin
        if AIpv6 then status := r6^.Status else status := r4^.Status;
      end;
      if status = IP_SUCCESS then
      begin
        s.Kind := prkReply;
        // l'API arrondit a la milliseconde; notre chrono est plus fin mais
        // ne peut que majorer: on le garde, borne par la valeur API + 1 ms
        if AIpv6 then apiRtt := r6^.RoundTripTime else apiRtt := r4^.RoundTripTime;
        s.RttMs := t1 - t0;
        if s.RttMs > apiRtt + 1.0 then s.RttMs := apiRtt + 0.5;
        if not AIpv6 then s.Ttl := r4^.Options.Ttl;
      end
      else if status = IP_REQ_TIMED_OUT then
        s.Kind := prkTimeout
      else if (status = IP_DEST_NET_UNREACHABLE) or
              (status = IP_DEST_HOST_UNREACHABLE) or
              (status = IP_DEST_PROT_UNREACHABLE) or
              (status = IP_DEST_PORT_UNREACHABLE) then
      begin
        s.Kind := prkUnreachable;
        s.Msg := StatusText(status);
      end
      else
      begin
        s.Kind := prkError;
        s.Msg := StatusText(status);
      end;
      Emit(s);
      // l'intervalle court depuis l'envoi, comme ping
      SleepChecked(IntervalMs - Round(t1 - t0));
    end;
  finally
    if not handedOff then
    begin
      IcmpCloseHandle(h);
      CloseHandle(ev);
      FreeMem(reply);
    end;
  end;
end;

procedure TPinger.RunFallback;
begin
  // pas de repli sous Windows: iphlpapi est toujours la
end;

{$ELSE}

const
  IPPROTO_ICMP_ = 1;
  IPPROTO_ICMPV6_ = 58;
  ICMP_ECHO = 8;
  ICMP_ECHOREPLY = 0;
  ICMP_DEST_UNREACH = 3;
  ICMP6_ECHO_REQUEST = 128;
  ICMP6_ECHO_REPLY = 129;
  ICMP6_DST_UNREACH = 1;

function IcmpChecksum(P: PByte; ALen: Integer): Word;
var
  sum: LongWord;
  i: Integer;
begin
  sum := 0;
  i := 0;
  while i + 1 < ALen do
  begin
    sum := sum + (LongWord(P[i]) shl 8) + P[i + 1];
    Inc(i, 2);
  end;
  if i < ALen then sum := sum + (LongWord(P[i]) shl 8);
  while (sum shr 16) <> 0 do
    sum := (sum and $FFFF) + (sum shr 16);
  Result := Word(not sum);
end;

function TPinger.RunNative(AIpv6: Boolean; ASock: Pointer): Boolean;
var
  pb: PSockAddrBuf;
  fd: cint;
  pkt: array[0..7 + ECHO_PAYLOAD] of Byte;
  rbuf: array[0..1499] of Byte;
  ident, sum, rseq: Word;
  s: TPingSample;
  t0, t1, deadline: Double;
  n, off, waitMs, rc, i: Integer;
  fds: TSockSet;
  got: Boolean;
  from: array[0..127] of Byte;
  fromLen: TSockLen;
  rtype: Byte;
  {$IFDEF LINUX}
  ttlOn: cint;
  {$ENDIF}
begin
  Result := False;
  pb := PSockAddrBuf(ASock);
  if AIpv6 then
    fd := fpsocket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6_)
  else
    fd := fpsocket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP_);
  if fd < 0 then Exit;   // EACCES/EPERM: ping_group_range ferme, on se replie
  Result := True;
  ident := Word(GetProcessID and $FFFF);
  {$IFDEF LINUX}
  // Le TTL de la reponse ne se lit pas sans message de controle sous Linux;
  // on ne l'exploite pas encore, mais l'option ne coute rien.
  ttlOn := 1;
  if not AIpv6 then
    fpsetsockopt(fd, 0 { SOL_IP }, 12 { IP_RECVTTL }, @ttlOn, SizeOf(ttlOn));
  {$ENDIF}
  try
    while not Terminated do
    begin
      if Paused then
      begin
        SleepChecked(100);
        Continue;
      end;
      Inc(FSeq);
      s := Default(TPingSample);
      s.Seq := FSeq;
      s.Ttl := -1;
      FillChar(pkt, SizeOf(pkt), 0);
      if AIpv6 then pkt[0] := ICMP6_ECHO_REQUEST else pkt[0] := ICMP_ECHO;
      pkt[1] := 0;
      pkt[4] := ident shr 8; pkt[5] := ident and $FF;
      pkt[6] := (FSeq shr 8) and $FF; pkt[7] := FSeq and $FF;
      for i := 0 to ECHO_PAYLOAD - 1 do pkt[8 + i] := Byte(i);
      if not AIpv6 then
      begin
        // Linux le recalcule, Darwin non: on le pose toujours
        sum := IcmpChecksum(@pkt, SizeOf(pkt));
        pkt[2] := sum shr 8; pkt[3] := sum and $FF;
      end;
      t0 := HiResMs;
      n := fpsendto(fd, @pkt, SizeOf(pkt), 0, psockaddr(@pb^.Data), pb^.Len);
      if n < 0 then
      begin
        s.When := Now;
        if (fpGetErrno = ESysENETUNREACH) or (fpGetErrno = ESysEHOSTUNREACH) or
           (fpGetErrno = ESysEHOSTDOWN) then
        begin
          s.Kind := prkUnreachable;
          s.Msg := 'no route to host';
        end
        else
        begin
          s.Kind := prkError;
          s.Msg := 'send failed, errno ' + IntToStr(fpGetErrno);
        end;
        Emit(s);
        SleepChecked(IntervalMs);
        Continue;
      end;
      deadline := t0 + TimeoutMs;
      got := False;
      repeat
        waitMs := Round(deadline - HiResMs);
        if waitMs <= 0 then Break;
        if waitMs > 100 then waitMs := 100;   // Terminated relu souvent
        SockSetZero(fds);
        SockSetAdd(fd, fds);
        rc := SockSelect(fd + 1, @fds, nil, nil, waitMs);
        if rc < 0 then
        begin
          if SockErrIsIntr(SockLastError) then Continue;
          Break;
        end;
        if rc = 0 then
        begin
          if Terminated then Break;
          Continue;
        end;
        fromLen := SizeOf(from);
        n := fprecvfrom(fd, @rbuf, SizeOf(rbuf), 0, psockaddr(@from), @fromLen);
        t1 := HiResMs;
        if n <= 0 then Break;
        off := 0;
        // Darwin livre l'en-tete IP devant l'ICMP, Linux non
        if (not AIpv6) and (n > 20) and ((rbuf[0] shr 4) = 4) then
        begin
          off := (rbuf[0] and $0F) * 4;
          if off > n - 8 then Continue;
          s.Ttl := rbuf[8];
        end;
        if n - off < 8 then Continue;
        rtype := rbuf[off];
        rseq := (Word(rbuf[off + 6]) shl 8) or rbuf[off + 7];
        if (AIpv6 and (rtype = ICMP6_ECHO_REPLY)) or
           ((not AIpv6) and (rtype = ICMP_ECHOREPLY)) then
        begin
          if rseq <> Word(FSeq and $FFFF) then Continue; // reponse tardive
          s.Kind := prkReply;
          s.RttMs := t1 - t0;
          got := True;
        end
        else if (AIpv6 and (rtype = ICMP6_DST_UNREACH)) or
                ((not AIpv6) and (rtype = ICMP_DEST_UNREACH)) then
        begin
          s.Kind := prkUnreachable;
          s.Msg := 'destination unreachable';
          got := True;
        end;
      until got or Terminated;
      s.When := Now;
      if not got then s.Kind := prkTimeout;
      Emit(s);
      SleepChecked(IntervalMs - Round(HiResMs - t0));
    end;
  finally
    SockClose(fd);
  end;
end;

// Binaire ping du systeme. iputils: « 64 bytes from 10.0.0.1: icmp_seq=1
// ttl=64 time=0.123 ms », « no answer yet for icmp_seq=2 » (-O), « From
// 10.0.0.1 icmp_seq=1 Destination Host Unreachable ». BSD/macOS: « Request
// timeout for icmp_seq 3 » et le meme format de reponse.
procedure TPinger.RunFallback;

  function FieldAfter(const ALine, AKey: string): string;
  var
    p, e: Integer;
  begin
    Result := '';
    p := Pos(AKey, ALine);
    if p = 0 then Exit;
    p := p + Length(AKey);
    e := p;
    while (e <= Length(ALine)) and (ALine[e] in ['0'..'9', '.']) do Inc(e);
    Result := Copy(ALine, p, e - p);
  end;

var
  proc: TProcess;
  acc, line, v, chunkStr: string;
  chunk: array[0..4095] of Byte;
  n, p, lastSeq, seqv, delta, curInterval, curTimeout: Integer;
  s: TPingSample;
  fmt: TFormatSettings;
begin
  fmt := DefaultFormatSettings;
  fmt.DecimalSeparator := '.';
  lastSeq := 0;
  curInterval := 0;
  curTimeout := 0;
  acc := '';
  proc := nil;
  try
    while not Terminated do
    begin
      if Paused then
      begin
        if proc <> nil then
        begin
          proc.Terminate(0);
          FreeAndNil(proc);
        end;
        SleepChecked(100);
        Continue;
      end;
      if proc = nil then
      begin
        curInterval := IntervalMs;
        curTimeout := TimeoutMs;
        proc := TProcess.Create(nil);
        proc.Executable := '/bin/ping';
        if not FileExists(proc.Executable) then
          proc.Executable := '/sbin/ping';
        proc.Environment.Add('LANG=C');
        proc.Environment.Add('LC_ALL=C');
        proc.Parameters.Add('-n');
        {$IFDEF LINUX}
        proc.Parameters.Add('-O');
        proc.Parameters.Add('-W');
        proc.Parameters.Add(FormatFloat('0.0', curTimeout / 1000, fmt));
        {$ELSE}
        proc.Parameters.Add('-W');
        proc.Parameters.Add(IntToStr(curTimeout));
        {$ENDIF}
        proc.Parameters.Add('-i');
        proc.Parameters.Add(FormatFloat('0.0', curInterval / 1000, fmt));
        proc.Parameters.Add(FHost);
        proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
        try
          proc.Execute;
        except
          on E: Exception do
          begin
            s := Default(TPingSample);
            s.Kind := prkError;
            s.Msg := 'cannot run ping: ' + E.Message;
            s.When := Now;
            s.Ttl := -1;
            Emit(s);
            FreeAndNil(proc);
            SleepChecked(2000);
            Continue;
          end;
        end;
        acc := '';
        lastSeq := 0;   // le nouveau ping renumerote depuis 1
      end;
      // reglages changes: on relance le binaire avec les nouveaux
      if (curInterval <> IntervalMs) or (curTimeout <> TimeoutMs) then
      begin
        proc.Terminate(0);
        FreeAndNil(proc);
        Continue;
      end;
      if proc.Output.NumBytesAvailable > 0 then
      begin
        n := proc.Output.Read(chunk, SizeOf(chunk));
        if n > 0 then
        begin
          SetString(chunkStr, PChar(@chunk), n);
          acc := acc + chunkStr;
        end;
      end
      else if not proc.Running then
      begin
        s := Default(TPingSample);
        s.Kind := prkError;
        s.Msg := 'ping exited';
        s.When := Now;
        s.Ttl := -1;
        Emit(s);
        FreeAndNil(proc);
        SleepChecked(2000);
        Continue;
      end
      else
        SleepChecked(50);
      p := Pos(#10, acc);
      while p > 0 do
      begin
        line := Copy(acc, 1, p - 1);
        Delete(acc, 1, p);
        p := Pos(#10, acc);
        s := Default(TPingSample);
        s.When := Now;
        s.Ttl := -1;
        v := FieldAfter(line, 'icmp_seq=');
        if v = '' then v := FieldAfter(line, 'icmp_seq ');
        if v = '' then Continue;
        seqv := StrToIntDef(v, 0);
        // iputils numerote sur 16 bits: apres 65535 vient 0, soit 36 h a
        // 2 s. Avance = ecart modulo 65536 dans la demi-fenetre; 0 ou un
        // recul = doublon (« DUP! ») ou reponse tardive deja comptee.
        delta := (seqv - lastSeq) and $FFFF;
        if (delta = 0) or (delta > $7FFF) then Continue;
        lastSeq := seqv;
        Inc(FSeq);
        s.Seq := FSeq;
        if Pos('time=', line) > 0 then
        begin
          s.Kind := prkReply;
          s.RttMs := StrToFloatDef(FieldAfter(line, 'time='), 0, fmt);
          v := FieldAfter(line, 'ttl=');
          if v <> '' then s.Ttl := StrToIntDef(v, -1);
        end
        else if Pos('nreachable', line) > 0 then
        begin
          s.Kind := prkUnreachable;
          s.Msg := Trim(Copy(line, Pos('icmp_seq', line) + 10, MaxInt));
        end
        else
          s.Kind := prkTimeout;   // « no answer yet » / « Request timeout »
        Emit(s);
      end;
    end;
  finally
    if proc <> nil then
    begin
      proc.Terminate(0);
      proc.Free;
    end;
  end;
end;

{$ENDIF}

procedure TPinger.Execute;
var
  res: Paddrinfo;
  err: string;
  buf: TSockAddrBuf;
begin
  res := nil;
  if not ResolveCancellable(AnsiString(FHost), '0', @Aborted, res, err) then
  begin
    if Terminated then Exit;
    if err = '' then err := 'cannot resolve host';
    EmitResolved('', err, False);
    Exit;
  end;
  try
    if not PickAddress(res, buf) then
    begin
      EmitResolved('', 'no usable address', False);
      Exit;
    end;
  finally
    freeaddrinfo(res);
  end;
  EmitResolved(AddrToString(buf), '', False);
  if Terminated then Exit;
  if RunNative(buf.Ipv6, @buf) then Exit;
  {$IFDEF UNIX}
  EmitResolved(AddrToString(buf), '', True);
  RunFallback;
  {$ELSE}
  EmitResolved('', 'ICMP is not available on this system', False);
  {$ENDIF}
end;

end.
