unit uVncTransport;

{$mode objfpc}{$H+}

// Transport VNC/RFB, sans LCL. libvncclient interdit deux threads sur une
// connexion: tout passe par le thread de session, les entrees UI par une file.

interface

uses
  SysUtils, Classes, SyncObjs, ctypes,
  Sockets, uSockCompat, uNetResolve,
  uLibVncApi, uRemoteSurface, uSessionState, uSecureBytes, uVncKeysyms;

const
  VNC_WAIT_US = 50 * 1000;

  VNC_INPUT_QUEUE_MAX = 4096;

  // Plafond DUR: le profil peut en demander moins, jamais plus.
  VNC_RECONNECT_BASE_MS = 1500;
  VNC_RECONNECT_MAX_MS  = 8000;
  VNC_RECONNECT_MAX_ATTEMPTS = 3;
  VNC_CONNECT_TIMEOUT_S = 15;
  VNC_CONNECT_POLL_MS = 200;
  VNC_READ_TIMEOUT_S    = 20;
  VNC_CLIP_SEND_MAX = 4 * 1024 * 1024;

type
  EVncTransportError = class(Exception);

  TVncConfig = record
    Host: string;
    Port: Integer;
    ViewOnly: Boolean;
    Shared: Boolean;
    CompressLevel: Integer;
    QualityLevel: Integer;
    ClipboardTextEnabled: Boolean;
    ViewActualSize: Boolean;
    AutoReconnect: Boolean;
    MaxReconnectAttempts: Integer;
  end;

  TVncInputKind = (vikPointer, vikKey, vikClipboard, vikRefresh);

  TVncInputEvent = record
    Kind: TVncInputKind;
    X, Y: Integer;
    ButtonMask: Integer;
    Keysym: Cardinal;
    Down: Boolean;
    Text: string;
  end;

  TVncStateEvent = procedure(ASender: TObject;
    AState: TRemoteSessionState) of object;
  TVncTextEvent = procedure(ASender: TObject; const AText: string) of object;
  TVncSizeEvent = procedure(ASender: TObject; AWidth, AHeight: Integer) of object;
  TVncReconnectEvent = procedure(ASender: TObject; const AMessage: string;
    AActive: Boolean) of object;

  TVncTransport = class;

  TVncThread = class(TThread)
  private
    FOwner: TVncTransport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVncTransport);
  end;

  TVncTransport = class
  private
    FConfig: TVncConfig;
    FPassword: TSecureBytes;
    FPwLock: TCriticalSection;    // FPassword lu (thread session) / efface (UI)
    FReconnectInhibited: Boolean;
    FClient: PVncClient;
    FFrameBuffer: PByte;          // NOTRE tampon, possede independamment de FClient
    FSockFd: cint;
    // Duplicata confie a libvncclient (SockDup). Sous Windows, shutdown() sur
    // l'original ne debloque pas le duplicata: BeginShutdown vise LES DEUX.
    FLibSockFd: cint;
    FSockLock: TCriticalSection;
    FThread: TVncThread;
    FSurface: TRemoteSurface;
    FStates: TSessionStateMachine;
    FStop: Boolean;

    FQueueLock: TCriticalSection;
    FQueue: array of TVncInputEvent;
    FQueueCount: Integer;
    FDropped: Int64;

    FLastError: string;
    FErrLock: TCriticalSection;
    FDesktopName: string;

    FOnStateChanged: TVncStateEvent;
    FOnClipboardText: TVncTextEvent;
    FOnDesktopResize: TVncSizeEvent;
    FOnBell: TNotifyEvent;
    FOnReconnect: TVncReconnectEvent;

    function GetState: TRemoteSessionState;
    function GetDesktopName: string;
    function GetLastError: string;
    procedure SetLastError(const AValue: string);
    procedure SetState(AState: TRemoteSessionState);

    procedure Enqueue(const AEvent: TVncInputEvent);
    procedure DrainInput;
    procedure FlushInput;
    procedure RunSession;
    function BuildClient: Boolean;
    function IsAborted: Boolean;
    // Publie le descripteur AVANT le handshake: BeginShutdown doit avoir prise.
    function ConnectSocket: Boolean;
    function ConnectClient: Boolean;
    procedure TeardownClient;
    function ServeMessages: Boolean;
    function TryReconnect: Boolean;
    procedure PublishReconnect(const AMessage: string; AActive: Boolean);
    function InterruptibleSleep(AMs: Integer): Boolean;
  public
    constructor Create(const AConfig: TVncConfig; APassword: TSecureBytes);
    destructor Destroy; override;

    procedure Start;
    procedure BeginShutdown;
    procedure WaitForShutdown;
    procedure InhibitReconnect;

    procedure SendPointer(AX, AY, AButtonMask: Integer);
    procedure SendKey(AKeysym: Cardinal; ADown: Boolean);
    procedure SendClipboard(const AText: string);
    procedure RequestFullRefresh;

    property Surface: TRemoteSurface read FSurface;
    property State: TRemoteSessionState read GetState;
    property LastError: string read GetLastError;
    property DesktopName: string read GetDesktopName;
    property DroppedInputs: Int64 read FDropped;

    // Emis depuis le THREAD DE SESSION: l'abonne doit marshaller vers l'UI.
    property OnStateChanged: TVncStateEvent
      read FOnStateChanged write FOnStateChanged;
    property OnClipboardText: TVncTextEvent
      read FOnClipboardText write FOnClipboardText;
    property OnDesktopResize: TVncSizeEvent
      read FOnDesktopResize write FOnDesktopResize;
    property OnBell: TNotifyEvent read FOnBell write FOnBell;
    property OnReconnect: TVncReconnectEvent
      read FOnReconnect write FOnReconnect;
  end;

// Cut text RFB classique = LATIN-1, etendu = UTF-8; les confondre mange les accents.
function Latin1ToUtf8(const S: AnsiString): string;
function Utf8ToLatin1(const S: string): AnsiString;

implementation

function Latin1ToUtf8(const S: AnsiString): string;
var
  i, n: Integer;
  b: Byte;
  r: AnsiString;
begin
  SetLength(r, Length(S) * 2);
  n := 0;
  for i := 1 to Length(S) do
  begin
    b := Ord(S[i]);
    if b < $80 then
    begin
      Inc(n);
      r[n] := AnsiChar(b);
    end
    else
    begin
      r[n + 1] := AnsiChar($C0 or (b shr 6));
      r[n + 2] := AnsiChar($80 or (b and $3F));
      Inc(n, 2);
    end;
  end;
  SetLength(r, n);
  Result := string(r);
end;

function Utf8ToLatin1(const S: string): AnsiString;
var
  i, used, n: Integer;
  cp: Cardinal;
begin
  SetLength(Result, Length(S));
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    if Utf8FirstCodepoint(Copy(S, i, 4), cp, used) then
    begin
      Inc(n);
      if cp <= $FF then
        Result[n] := AnsiChar(cp)
      else
        Result[n] := '?';
      Inc(i, used);
    end
    else
      Inc(i);
  end;
  SetLength(Result, n);
end;

// Rappels C -> Pascal: thread de session, aucune exception ne remonte.

function TransportOf(AClient: PVncClient): TVncTransport;
begin
  Result := TVncTransport(VncGetClientData(AClient));
end;

function CbMallocFrameBuffer(AClient: PVncClient): cint8; cdecl;
var
  t: TVncTransport;
  w, h: Integer;
  buf, old: PByte;
begin
  Result := 0;
  try
    t := TransportOf(AClient);
    if t = nil then Exit;
    w := VncGetWidth(AClient);
    h := VncGetHeight(AClient);

    t.FSurface.Resize(w, h);

    // Le framebuffer est a NOUS et vit hors de FClient: sinon il fuit a l'init ratee.
    buf := GetMem(PtrUInt(w) * PtrUInt(h) * REMOTE_BYTES_PER_PIXEL);
    FillChar(buf^, PtrUInt(w) * PtrUInt(h) * REMOTE_BYTES_PER_PIXEL, 0);
    old := t.FFrameBuffer;
    t.FFrameBuffer := buf;
    VncSetFrameBuffer(AClient, buf);
    if old <> nil then
      FreeMem(old);

    if Assigned(t.FOnDesktopResize) then
      t.FOnDesktopResize(t, w, h);
    Result := 1;
  except
    on E: Exception do
    begin
      try
        t := TransportOf(AClient);
        if t <> nil then
          t.SetLastError('desktop size refused: ' + E.Message);
      except
      end;
      Result := 0;
    end;
  end;
end;

procedure CbGotFrameBufferUpdate(AClient: PVncClient;
  x, y, w, h: cint); cdecl;
var
  t: TVncTransport;
  fb: PByte;
begin
  try
    t := TransportOf(AClient);
    if t = nil then Exit;
    fb := VncGetFrameBuffer(AClient);
    if fb = nil then Exit;
    t.FSurface.BlitFrom(fb, VncGetWidth(AClient) * REMOTE_BYTES_PER_PIXEL,
      x, y, w, h);
  except
  end;
end;

function CbGetPassword(AClient: PVncClient): PAnsiChar; cdecl;
var
  t: TVncTransport;
begin
  Result := nil;
  try
    t := TransportOf(AClient);
    if t = nil then Exit;
    t.FPwLock.Acquire;
    try
      if t.FPassword = nil then Exit;
      // La lib rend ce pointeur a free(): malloc de la CRT, jamais GetMem.
      Result := VncStrDupCBuf(t.FPassword.Data, t.FPassword.Len);
    finally
      t.FPwLock.Release;
    end;
  except
    Result := nil;
  end;
end;

procedure ClipTextIn(AClient: PVncClient; const AText: PAnsiChar;
  ALen: cint; AIsUtf8: Boolean);
var
  t: TVncTransport;
  s: AnsiString;
  txt: string;
begin
  t := TransportOf(AClient);
  if (t = nil) or (AText = nil) or (ALen <= 0) then Exit;
  if not t.FConfig.ClipboardTextEnabled then Exit;
  if ALen > 1024 * 1024 then
    ALen := 1024 * 1024;
  SetLength(s, ALen);
  Move(AText^, PAnsiChar(s)^, ALen);
  if AIsUtf8 then
    txt := string(s)
  else
    txt := Latin1ToUtf8(s);
  if Assigned(t.FOnClipboardText) then
    t.FOnClipboardText(t, txt);
end;

procedure CbGotXCutText(AClient: PVncClient; const AText: PAnsiChar;
  ALen: cint); cdecl;
begin
  try
    ClipTextIn(AClient, AText, ALen, False);
  except
  end;
end;

procedure CbGotXCutTextUTF8(AClient: PVncClient; const AText: PAnsiChar;
  ALen: cint); cdecl;
begin
  try
    ClipTextIn(AClient, AText, ALen, True);
  except
  end;
end;

procedure CbBell(AClient: PVncClient); cdecl;
var
  t: TVncTransport;
begin
  try
    t := TransportOf(AClient);
    if (t <> nil) and Assigned(t.FOnBell) then
      t.FOnBell(t);
  except
  end;
end;

constructor TVncThread.Create(AOwner: TVncTransport);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(True);
end;

procedure TVncThread.Execute;
begin
  FOwner.RunSession;
end;

constructor TVncTransport.Create(const AConfig: TVncConfig;
  APassword: TSecureBytes);
begin
  inherited Create;
  // Avant tout ce qui peut lever: 0, defaut d'un entier, est un fd valide.
  FSockFd := -1;
  FLibSockFd := -1;
  FConfig := AConfig;
  if FConfig.Port <= 0 then
    FConfig.Port := VNC_DEFAULT_PORT;
  FPassword := APassword;
  FSurface := TRemoteSurface.Create;
  FStates := TSessionStateMachine.Create;
  FQueueLock := TCriticalSection.Create;
  FErrLock := TCriticalSection.Create;
  FPwLock := TCriticalSection.Create;
  FSockLock := TCriticalSection.Create;
  SetLength(FQueue, 64);
end;

destructor TVncTransport.Destroy;
begin
  BeginShutdown;
  WaitForShutdown;
  FThread.Free;
  FPassword.Free;
  if FFrameBuffer <> nil then
  begin
    FreeMem(FFrameBuffer);
    FFrameBuffer := nil;
  end;
  FSurface.Free;
  FStates.Free;
  FQueueLock.Free;
  FErrLock.Free;
  FPwLock.Free;
  FSockLock.Free;
  inherited Destroy;
end;

function TVncTransport.GetState: TRemoteSessionState;
begin
  Result := FStates.State;
end;

procedure TVncTransport.SetState(AState: TRemoteSessionState);
begin
  if FStates.TryTransitionTo(AState) then
    if Assigned(FOnStateChanged) then
      FOnStateChanged(Self, AState);
end;

function TVncTransport.GetLastError: string;
begin
  FErrLock.Acquire;
  try
    Result := FLastError;
  finally
    FErrLock.Release;
  end;
end;

function TVncTransport.GetDesktopName: string;
begin
  FErrLock.Acquire;
  try
    Result := FDesktopName;
  finally
    FErrLock.Release;
  end;
end;

procedure TVncTransport.SetLastError(const AValue: string);
begin
  FErrLock.Acquire;
  try
    FLastError := AValue;
  finally
    FErrLock.Release;
  end;
end;

procedure TVncTransport.Start;
begin
  if FThread <> nil then
    raise EVncTransportError.Create('VNC session already started');
  SetState(rssConnecting);
  FThread := TVncThread.Create(Self);
  FThread.Start;
end;

procedure TVncTransport.BeginShutdown;
begin
  FStop := True;
  if FSockLock <> nil then
  begin
    FSockLock.Acquire;
    try
      if FSockFd >= 0 then
        SockShutdownBoth(FSockFd);
      if FLibSockFd >= 0 then
        SockShutdownBoth(FLibSockFd);
    finally
      FSockLock.Release;
    end;
  end;
end;

procedure TVncTransport.InhibitReconnect;
begin
  FReconnectInhibited := True;
  FPwLock.Acquire;
  try
    FreeAndNil(FPassword);
  finally
    FPwLock.Release;
  end;
end;

procedure TVncTransport.WaitForShutdown;
begin
  if FThread <> nil then
    FThread.WaitFor;
end;

procedure TVncTransport.FlushInput;
begin
  FQueueLock.Acquire;
  try
    FQueueCount := 0;
  finally
    FQueueLock.Release;
  end;
end;

procedure TVncTransport.Enqueue(const AEvent: TVncInputEvent);
begin
  FQueueLock.Acquire;
  try
    if FQueueCount >= VNC_INPUT_QUEUE_MAX then
    begin
      Inc(FDropped);
      Exit;
    end;
    if FQueueCount >= Length(FQueue) then
      SetLength(FQueue, Length(FQueue) * 2);
    FQueue[FQueueCount] := AEvent;
    Inc(FQueueCount);
  finally
    FQueueLock.Release;
  end;
end;

procedure TVncTransport.SendPointer(AX, AY, AButtonMask: Integer);
var
  e: TVncInputEvent;
begin
  if FConfig.ViewOnly then Exit;
  e := Default(TVncInputEvent);
  e.Kind := vikPointer;
  e.X := AX;
  e.Y := AY;
  e.ButtonMask := AButtonMask;
  Enqueue(e);
end;

procedure TVncTransport.SendKey(AKeysym: Cardinal; ADown: Boolean);
var
  e: TVncInputEvent;
begin
  if FConfig.ViewOnly then Exit;
  if AKeysym = 0 then Exit;
  e := Default(TVncInputEvent);
  e.Kind := vikKey;
  e.Keysym := AKeysym;
  e.Down := ADown;
  Enqueue(e);
end;

procedure TVncTransport.SendClipboard(const AText: string);
var
  e: TVncInputEvent;
  t: string;
begin
  if FConfig.ViewOnly then Exit;
  if not FConfig.ClipboardTextEnabled then Exit;
  if AText = '' then Exit;
  t := AText;
  if Length(t) > VNC_CLIP_SEND_MAX then
    SetLength(t, VNC_CLIP_SEND_MAX);
  e := Default(TVncInputEvent);
  e.Kind := vikClipboard;
  e.Text := t;
  Enqueue(e);
end;

procedure TVncTransport.RequestFullRefresh;
var
  e: TVncInputEvent;
begin
  e := Default(TVncInputEvent);
  e.Kind := vikRefresh;
  Enqueue(e);
end;

procedure TVncTransport.DrainInput;
var
  batch: array of TVncInputEvent;
  i, n: Integer;
  raw: AnsiString;
begin
  FQueueLock.Acquire;
  try
    n := FQueueCount;
    if n = 0 then Exit;
    SetLength(batch, n);
    for i := 0 to n - 1 do
      batch[i] := FQueue[i];
    FQueueCount := 0;
  finally
    FQueueLock.Release;
  end;

  for i := 0 to n - 1 do
  begin
    if FClient = nil then Exit;
    case batch[i].Kind of
      vikPointer:
        SendPointerEvent(FClient, batch[i].X, batch[i].Y, batch[i].ButtonMask);
      vikKey:
        SendKeyEvent(FClient, batch[i].Keysym, Ord(batch[i].Down));
      vikClipboard:
        begin
          raw := AnsiString(batch[i].Text);
          if raw <> '' then
            if SendClientCutTextUTF8(FClient, PAnsiChar(raw),
               Length(raw)) = 0 then
            begin
              raw := Utf8ToLatin1(batch[i].Text);
              if raw <> '' then
                SendClientCutText(FClient, PAnsiChar(raw), Length(raw));
            end;
        end;
      vikRefresh:
        SendFramebufferUpdateRequest(FClient, 0, 0,
          VncGetWidth(FClient), VncGetHeight(FClient), 0);
    end;
  end;
end;

function TVncTransport.BuildClient: Boolean;
begin
  Result := False;
  FClient := rfbGetClient(VNC_BITS_PER_SAMPLE, VNC_SAMPLES_PER_PIXEL,
    VNC_BYTES_PER_PIXEL);
  if FClient = nil then
  begin
    SetLastError('cannot allocate the VNC client');
    Exit;
  end;

  VncSetClientData(FClient, Self);
  VncSetMallocFrameBuffer(FClient, @CbMallocFrameBuffer);
  VncSetGotFrameBufferUpdate(FClient, @CbGotFrameBufferUpdate);
  VncSetGetPassword(FClient, @CbGetPassword);
  VncSetGotXCutText(FClient, @CbGotXCutText);
  VncSetGotXCutTextUTF8(FClient, @CbGotXCutTextUTF8);
  VncSetBell(FClient, @CbBell);

  VncSetPixelFormatBgra(FClient);
  VncSetCompressLevel(FClient, FConfig.CompressLevel);
  VncSetQualityLevel(FClient, FConfig.QualityLevel);
  VncSetViewOnly(FClient, FConfig.ViewOnly);
  VncSetShared(FClient, FConfig.Shared);
  VncSetCanHandleNewFBSize(FClient, True);
  VncSetConnectTimeout(FClient, VNC_CONNECT_TIMEOUT_S);
  VncSetReadTimeout(FClient, VNC_READ_TIMEOUT_S);
  VncSetProgramName(FClient, 'RottenSSHrimp');
  VncSetServerHost(FClient, FConfig.Host);
  VncSetServerPort(FClient, FConfig.Port);
  Result := True;
end;

function TVncTransport.IsAborted: Boolean;
begin
  Result := FStop;
end;

function TVncTransport.ConnectSocket: Boolean;
var
  res, ai: Paddrinfo;
  fd, rc: cint;
  waited: Integer;
  resErr: string;
  connected: Boolean;
begin
  Result := False;
  res := nil;
  if not ResolveCancellable(AnsiString(FConfig.Host),
       AnsiString(IntToStr(FConfig.Port)), @IsAborted, res, resErr) then
  begin
    if resErr <> '' then
      SetLastError(resErr);
    Exit;
  end;
  try
    ai := res;
    while (ai <> nil) and (not FStop) do
    begin
      fd := fpSocket(ai^.ai_family, ai^.ai_socktype, ai^.ai_protocol);
      if fd < 0 then
      begin
        ai := ai^.ai_next;
        Continue;
      end;
      SockSetNonBlocking(fd, True);
      connected := False;
      if fpConnect(fd, ai^.ai_addr, TSocklen(ai^.ai_addrlen)) = 0 then
        connected := True
      else if SockErrIsInProgress(SockLastError) then
      begin
        waited := 0;
        while (waited < VNC_CONNECT_TIMEOUT_S * 1000) and (not FStop) do
        begin
          rc := SockWaitConnect(fd, VNC_CONNECT_POLL_MS);
          if rc > 0 then
          begin
            connected := SockGetPendingError(fd) = 0;
            Break;
          end;
          if rc < 0 then Break;
          Inc(waited, VNC_CONNECT_POLL_MS);
        end;
      end;
      if connected then
      begin
        // Pair eteint brutalement (ni FIN ni RST): sans keepalive, un zombie.
        SockEnableKeepalive(fd, 20, 10);
        {$IFNDEF WINDOWS}
        SockSetNonBlocking(fd, False);
        {$ENDIF}
        // Windows: RESTER non bloquant. Sous WinSock, shutdown() ne reveille
        // jamais un recv/select deja bloque, meme via le duplicata.
        FSockLock.Acquire;
        try
          FSockFd := fd;
        finally
          FSockLock.Release;
        end;
        Exit(True);
      end;
      SockClose(fd);
      ai := ai^.ai_next;
    end;
  finally
    freeaddrinfo(res);
  end;
  if not FStop then
    SetLastError(Format('Cannot connect to %s:%d',
      [FConfig.Host, FConfig.Port]));
end;

function TVncTransport.ConnectClient: Boolean;
var
  dupFd: cint;
begin
  Result := False;
  if not BuildClient then Exit;
  if not ConnectSocket then Exit;
  dupFd := SockDup(FSockFd);
  if dupFd < 0 then
  begin
    SetLastError('VNC: cannot duplicate the connection socket');
    Exit;
  end;
  FSockLock.Acquire;
  try
    FLibSockFd := dupFd;
  finally
    FSockLock.Release;
  end;
  VncSetSock(FClient, dupFd);
  // Saute la connexion de rfbInitConnection. PAS via serverPort = -1: ce mode
  // relecture vncrec saute aussi l'authentification.
  VncSetListenSpecified(FClient, True);
  if not VncInitClient(FClient) then
  begin
    if GetLastError = '' then
      SetLastError(Format('VNC connection refused (%s:%d)',
        [FConfig.Host, FConfig.Port]));
    Exit;
  end;
  FErrLock.Acquire;
  try
    FDesktopName := VncGetDesktopName(FClient);
  finally
    FErrLock.Release;
  end;
  SendFramebufferUpdateRequest(FClient, 0, 0,
    VncGetWidth(FClient), VncGetHeight(FClient), 0);
  Result := True;
end;

procedure TVncTransport.TeardownClient;
var
  ourFd: cint;
begin
  ourFd := -1;
  try
    // Depublier AVANT de liberer: BeginShutdown ne doit pas viser un fd mourant.
    FSockLock.Acquire;
    try
      ourFd := FSockFd;
      FSockFd := -1;
      FLibSockFd := -1;
    finally
      FSockLock.Release;
    end;
    if FClient <> nil then
      VncSetFrameBuffer(FClient, nil);
    if FFrameBuffer <> nil then
    begin
      FreeMem(FFrameBuffer);
      FFrameBuffer := nil;
    end;
    if FClient <> nil then
    begin
      rfbClientCleanup(FClient);
      FClient := nil;
    end;
  except
  end;
  if ourFd >= 0 then
    SockClose(ourFd);
end;

function TVncTransport.ServeMessages: Boolean;
var
  n: Integer;
begin
  while not FStop do
  begin
    DrainInput;
    n := WaitForMessage(FClient, VNC_WAIT_US);
    if n < 0 then
    begin
      SetLastError('VNC connection interrupted');
      Exit(False);
    end;
    if n = 0 then
      Continue;
    if HandleRFBServerMessage(FClient) = 0 then
    begin
      SetLastError('invalid VNC server message');
      Exit(False);
    end;
  end;
  Result := True;
end;

function TVncTransport.InterruptibleSleep(AMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while waited < AMs do
  begin
    if FStop then Exit(False);
    Sleep(100);
    Inc(waited, 100);
  end;
  Result := not FStop;
end;

procedure TVncTransport.PublishReconnect(const AMessage: string;
  AActive: Boolean);
begin
  if Assigned(FOnReconnect) then
    FOnReconnect(Self, AMessage, AActive);
end;

function TVncTransport.TryReconnect: Boolean;
var
  attempt, maxAttempts, backoff, shift: Integer;
begin
  Result := False;
  if (not FConfig.AutoReconnect) or (FConfig.MaxReconnectAttempts <= 0)
     or FReconnectInhibited then
    Exit;
  maxAttempts := FConfig.MaxReconnectAttempts;
  if maxAttempts > VNC_RECONNECT_MAX_ATTEMPTS then
    maxAttempts := VNC_RECONNECT_MAX_ATTEMPTS;
  attempt := 0;
  while (not FStop) and (not FReconnectInhibited) and (attempt < maxAttempts) do
  begin
    Inc(attempt);
    TeardownClient;
    PublishReconnect(Format('Reconnecting %d/%d…',
      [attempt, maxAttempts]), True);

    shift := attempt - 1;
    if shift > 20 then shift := 20;
    backoff := VNC_RECONNECT_BASE_MS shl shift;
    if backoff > VNC_RECONNECT_MAX_MS then
      backoff := VNC_RECONNECT_MAX_MS;
    if not InterruptibleSleep(backoff) then
      Break;

    if ConnectClient then
    begin
      if FReconnectInhibited then
      begin
        TeardownClient;
        PublishReconnect('', False);
        Exit(False);
      end;
      FlushInput;
      PublishReconnect('', False);
      Exit(True);
    end;
    if attempt < maxAttempts then
      SetLastError('');
  end;
  PublishReconnect('', False);
end;

procedure TVncTransport.RunSession;
begin
  try
    VncEnsureLoaded;
    SetState(rssAuthenticating);
    if not ConnectClient then
    begin
      if GetLastError = '' then
        SetLastError(Format('VNC connection refused (%s:%d)',
          [FConfig.Host, FConfig.Port]));
      SetState(rssFailed);
      TeardownClient;
      Exit;
    end;

    // Sans reconnexion le secret ne resservira jamais: au feu.
    if not FConfig.AutoReconnect then
    begin
      FPwLock.Acquire;
      try
        FreeAndNil(FPassword);
      finally
        FPwLock.Release;
      end;
    end;
    SetState(rssConnected);

    while not FStop do
    begin
      if ServeMessages then
        Break;
      if FStop then
        Break;
      if not TryReconnect then
      begin
        SetState(rssFailed);
        TeardownClient;
        Exit;
      end;
    end;

    SetState(rssDisconnecting);
  except
    on E: Exception do
    begin
      SetLastError(E.Message);
      SetState(rssFailed);
    end;
  end;

  TeardownClient;
  if not IsTerminalState(FStates.State) then
    SetState(rssDisconnected);
end;

end.
