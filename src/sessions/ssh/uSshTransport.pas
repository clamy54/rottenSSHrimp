unit uSshTransport;

{$mode objfpc}{$H+}

// Transport SSH: un thread par session, aucun pointeur libssh2 ne sort d'ici,
// aucune LCL, aucun secret dans les messages. Seule la boucle shell est non bloquante: clavier, annulation.

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, uSecureBytes, uSessionState;

type
  ESshTransportError = class(Exception);

  // sakFidoKey: la cle privee est dans un token; libssh2 nous rappelle pour
  // chaque signature, ce qui suppose un geste de l'utilisateur en plein milieu
  // de l'authentification.
  TSshAuthKind = (sakPassword, sakKey, sakAgent, sakPrompt, sakFidoKey);

  TSshHostKeyVerdictKind = (hkUnknown, hkMatch, hkChanged);

  TSshHostKeyDecision = (hkdReject, hkdAcceptOnce, hkdAcceptAndSave);

  TSshHostKeyInfo = record
    Host: string;
    Port: Integer;
    KeyType: string;
    Fingerprint: string;
    Blob: TBytes;
    Verdict: TSshHostKeyVerdictKind;
    KnownFingerprint: string;
  end;

  // Instantane pris sur le thread UI: le thread reseau ne touche pas TRshModel.
  TSshConnectParams = class
  public
    Host: string;
    Port: Integer;
    // Rebond: la SOCKET vise le tunnel local, la cle d'hote reste
    // celle de la cible -- sinon le TOFU se ferait sous 127.0.0.1. Vides = direct.
    ConnectHost: string;
    ConnectPort: Integer;
    Username: string;
    AuthKind: TSshAuthKind;
    Password: TSecureBytes;
    PrivateKey: TSecureBytes;
    Passphrase: TSecureBytes;
    PublicKey: TSecureBytes;
    ConnectTimeoutS: Integer;
    KeepaliveS: Integer;
    KeepaliveMaxFailures: Integer;
    StrictHostKey: Boolean;
    TermType: string;
    Cols, Rows: Integer;
    StartupCommand: string;
    ExecCommand: string;
    RequestPty: Boolean;
    KnownKeyTypes: array of string;
    constructor Create;
    destructor Destroy; override;
    procedure WipeSecrets;
  end;

  TSshDataEvent = procedure(const AData: RawByteString) of object;
  TSshStateEvent = procedure(AState: TRemoteSessionState) of object;
  TSshErrorEvent = procedure(const AMessage: string) of object;
  TSshFinishedEvent = procedure(AExitCode: Integer) of object;
  TSshHostKeyEvent = procedure(const AInfo: TSshHostKeyInfo;
    var ADecision: TSshHostKeyDecision) of object;
  TSshHostKeyLookup = procedure(const AHost: string; APort: Integer;
    const AKeyType, AFingerprint: string;
    out AVerdict: TSshHostKeyVerdictKind;
    out AKnownFingerprint: string) of object;
  TSshHostKeySave = procedure(const AInfo: TSshHostKeyInfo) of object;

  // « Touchez votre cle »: NON modal, l'utilisateur doit pouvoir renoncer et la
  // session continuer a vivre. AActive=False ferme l'avis.
  TSshSkNoticeEvent = procedure(AActive: Boolean; const AText: string) of object;
  // PIN du token: modal, sur le thread UI. ACancelled=True si l'utilisateur
  // renonce -- l'authentification s'arrete alors sans message d'echec.
  TSshSkPinEvent = procedure(const APrompt: string; out APin: TSecureBytes;
    var ACancelled: Boolean) of object;

  // Socle commun au transport shell et au tunnel: pin du
  // type de cle, TOFU, auth. Duplique, le tunnel restait en retrait, en silence.
  TSshChannelBase = class(TThread)
  protected
    FParams: TSshConnectParams;   // possede
    FSession: Pointer;
    // Ecrit par le thread de session, lu par le thread UI (Shutdown): publie et
    // depublie UNIQUEMENT sous FSockLock, sinon on vise un descripteur referme.
    FSock: cint;
    FSockLock: TCriticalSection;

    FHostKeyEvent: TEvent;
    FHostKeyInfo: TSshHostKeyInfo;
    FHostKeyDecision: TSshHostKeyDecision;
    FOnHostKey: TSshHostKeyEvent;
    FOnHostKeyLookup: TSshHostKeyLookup;
    FOnHostKeySave: TSshHostKeySave;

    // Cle de securite. FSkOp est publie sous FSockLock, comme le descripteur:
    // Shutdown vient de l'UI et doit pouvoir annuler l'operation en cours.
    FSkOp: TObject;
    FSkEvent: TEvent;
    FSkPrompt: string;
    FSkPin: TSecureBytes;
    FSkPinCancelled: Boolean;
    FSkNoticeActive: Boolean;
    FSkNoticeText: string;
    FOnSkNotice: TSshSkNoticeEvent;
    FOnSkPin: TSshSkPinEvent;
    // Message d'echec d'authentification plus precis que « refuse »: la cause
    // vient du token ou de libssh2, pas du serveur.
    FAuthDetail: string;

    // Publie une connexion ABOUTIE seulement: un candidat en essai reste local.
    procedure PublishSock(AFd: cint);
    // Rend le descripteur a fermer (-1 si aucun): on ferme apres, jamais avant.
    function TakeSock: cint;
    // shutdown() sur le descripteur publie, appelable depuis le thread UI.
    procedure ShutdownSock;

    procedure ReportError(const AMessage: string); virtual; abstract;
    function WaitIo(AMs: Integer): Boolean; virtual; abstract;
    function ErrInitFailed: string; virtual;
    function ErrHandshakeTimeout: string; virtual;
    function ErrHandshakeRefused: string; virtual;
    function ErrHostKeyUnavailable: string; virtual;
    function ErrHostKeyChanged: string; virtual;
    function ErrHostKeyNotApproved: string; virtual;
    function ErrNoUsername: string; virtual;
    function AuthRefusedMsg(const AUser, AMethods: string): string; virtual;
    function ErrNoSkSupport: string; virtual;
    function ErrSkBackend: string; virtual;
    function ErrSkRejectedBeforeSign: string; virtual;

    function IsAborted: Boolean;
    function LastSshError(const AContext: string): string;
    function SetupWait(ADeadline: QWord): Boolean;
    procedure DoHostKeyLookup;
    procedure AskHostKey;
    procedure DoHostKeySave;
    // Tous trois s'executent sur le thread UI, postes par Queue.
    procedure DoSkNotice;
    procedure AskSkPin;
    // Appelees depuis le thread de session (et depuis la callback libssh2).
    procedure SkNotice(AActive: Boolean; const AText: string);
    function WaitSkPin(const AReason: string; out APin: TSecureBytes): Boolean;
    procedure SkCancel;
    function Handshake: Boolean;
    function VerifyHostKey: Boolean;
    function Authenticate: Boolean;
  public
    constructor Create(ACreateSuspended: Boolean);
    destructor Destroy; override;
  end;

  TSshTransport = class(TSshChannelBase)
  private
    FStates: TSessionStateMachine;

    FChannel: Pointer;

    FOutLock: TCriticalSection;
    FOutBuf: RawByteString;

    FPendingCols, FPendingRows: Integer;
    FResizeWanted: Boolean;

    // chaine MANAGEE: sans verrou, le refcount se course et la libere sous l'UI
    FErrorMsg: string;
    FErrLock: TCriticalSection;
    FExitCode: Integer;
    FDataChunk: RawByteString;
    FStateQ: array of TRemoteSessionState;
    FStateLock: TCriticalSection;

    FOnData: TSshDataEvent;
    FOnState: TSshStateEvent;
    FOnError: TSshErrorEvent;
    FOnFinished: TSshFinishedEvent;

    procedure PublishData;
    procedure PublishState;
    procedure PublishError;
    procedure PublishFinished;

    procedure SetState(ANext: TRemoteSessionState);
    procedure Fail(const AMessage: string);

    function ResolveAndConnect: Boolean;
    function OpenShell: Boolean;
    procedure ShellLoop;
    procedure Cleanup;
    function WaitSocket(AMs: Integer): Boolean;
    function WaitSocketEx(AMs: Integer; out AReadable: Boolean): Boolean;
  protected
    procedure ReportError(const AMessage: string); override;
    function WaitIo(AMs: Integer): Boolean; override;
    procedure Execute; override;
  public
    constructor Create(AParams: TSshConnectParams);
    destructor Destroy; override;

    // Appelables depuis le thread UI.
    procedure SendData(const AData: RawByteString);
    procedure RequestResize(ACols, ARows: Integer);
    procedure Shutdown;

    function State: TRemoteSessionState;

    property OnData: TSshDataEvent read FOnData write FOnData;
    property OnStateChanged: TSshStateEvent read FOnState write FOnState;
    property OnError: TSshErrorEvent read FOnError write FOnError;
    property OnFinished: TSshFinishedEvent read FOnFinished write FOnFinished;
    property OnHostKey: TSshHostKeyEvent read FOnHostKey write FOnHostKey;
    property OnSkNotice: TSshSkNoticeEvent read FOnSkNotice write FOnSkNotice;
    property OnSkPin: TSshSkPinEvent read FOnSkPin write FOnSkPin;
    property OnHostKeyLookup: TSshHostKeyLookup
      read FOnHostKeyLookup write FOnHostKeyLookup;
    property OnHostKeySave: TSshHostKeySave
      read FOnHostKeySave write FOnHostKeySave;
  end;

implementation

uses
  Sockets, uSockCompat, uLibssh2Api, uSshKnownHosts, uNetResolve, uSshFido, uSshSkKeyGen;

// Terminate n'interrompt ni un handshake bloque en lecture ni une auth en cours:
// couper la socket est le seul levier.

const
  READ_CHUNK = 16384;
  // latence max avant qu'une frappe parte: a 100 ms, Backspace maintenu saccadait
  SHELL_POLL_MS = 16;
  HOSTKEY_ANSWER_TIMEOUT_MS = 5 * 60 * 1000;
  // Saisie d'un PIN: meme patience que pour une cle d'hote.
  SK_ANSWER_TIMEOUT_MS = 5 * 60 * 1000;
  CONNECT_POLL_MS = 200;
  SHUTDOWN_GRACE_MS = 3000;

{ TSshConnectParams }

constructor TSshConnectParams.Create;
begin
  inherited Create;
  Port := 22;
  ConnectTimeoutS := 15;
  KeepaliveS := 30;
  KeepaliveMaxFailures := 3;
  StrictHostKey := True;
  TermType := 'xterm-256color';
  Cols := 80;
  Rows := 24;
  RequestPty := True;
end;

procedure TSshConnectParams.WipeSecrets;
begin
  FreeAndNil(Password);
  FreeAndNil(PrivateKey);
  FreeAndNil(Passphrase);
  FreeAndNil(PublicKey);
end;

destructor TSshConnectParams.Destroy;
begin
  WipeSecrets;
  inherited Destroy;
end;

{ TSshChannelBase }

constructor TSshChannelBase.Create(ACreateSuspended: Boolean);
begin
  inherited Create(ACreateSuspended);
  FreeOnTerminate := False;
  // -1 avant tout: 0, defaut d'un entier, est un descripteur valide (stdin).
  FSock := -1;
  FSockLock := TCriticalSection.Create;
  FHostKeyEvent := TEvent.Create(nil, True, False, '');
  FSkEvent := TEvent.Create(nil, True, False, '');
end;

destructor TSshChannelBase.Destroy;
begin
  inherited Destroy;   // TThread joint le thread AVANT qu'on libere ses vivres
  FHostKeyEvent.Free;
  FSkEvent.Free;
  FSkPin.Free;
  FSockLock.Free;
  FParams.Free;
end;

procedure TSshChannelBase.PublishSock(AFd: cint);
begin
  FSockLock.Acquire;
  try
    FSock := AFd;
  finally
    FSockLock.Release;
  end;
end;

function TSshChannelBase.TakeSock: cint;
begin
  FSockLock.Acquire;
  try
    Result := FSock;
    FSock := -1;
  finally
    FSockLock.Release;
  end;
end;

procedure TSshChannelBase.ShutdownSock;
begin
  if FSockLock = nil then
    Exit;
  FSockLock.Acquire;
  try
    if FSock >= 0 then
      SockShutdownBoth(FSock);
  finally
    FSockLock.Release;
  end;
end;

function TSshChannelBase.ErrInitFailed: string;
begin
  Result := 'Cannot initialize libssh2';
end;

function TSshChannelBase.ErrHandshakeTimeout: string;
begin
  Result := 'The SSH handshake timed out';
end;

function TSshChannelBase.ErrHandshakeRefused: string;
begin
  Result := 'SSH handshake refused';
end;

function TSshChannelBase.ErrHostKeyUnavailable: string;
begin
  Result := 'Host key unavailable';
end;

function TSshChannelBase.ErrHostKeyChanged: string;
begin
  Result := 'Connection refused: the host key has changed.';
end;

function TSshChannelBase.ErrHostKeyNotApproved: string;
begin
  Result := 'Connection refused: host key not approved.';
end;

function TSshChannelBase.ErrNoUsername: string;
begin
  Result := 'No username for this connection.';
end;

function TSshChannelBase.AuthRefusedMsg(const AUser, AMethods: string): string;
begin
  if AMethods <> '' then
    Result := Format('Authentication refused for %s (methods: %s)',
      [AUser, AMethods])
  else
    Result := Format('Authentication refused for %s', [AUser]);
end;

function TSshChannelBase.ErrNoSkSupport: string;
begin
  Result := 'This libssh2 build cannot use FIDO2 security keys ' +
    '(libssh2_userauth_publickey_sk is missing). It needs libssh2 1.11 or ' +
    'newer built against OpenSSL.';
end;

function TSshChannelBase.ErrSkBackend: string;
begin
  Result := 'This libssh2 build does not support FIDO2 security keys';
end;

function TSshChannelBase.ErrSkRejectedBeforeSign: string;
begin
  // Le serveur a refuse la cle AVANT de demander une signature: la cle de
  // securite n'a meme pas clignote. Deux causes, et l'utilisateur ne peut pas
  // les distinguer sans qu'on les nomme.
  Result := 'The server rejected the security key before asking for a ' +
    'signature: either it runs OpenSSH older than 8.2, which knows nothing ' +
    'of sk- keys, or this key is not in authorized_keys.';
end;

// --- Cle de securite: plomberie thread de session <-> interface -------------
// Meme motif que la validation de cle d'hote: Queue (jamais Synchronize, une
// modale ouverte ailleurs viderait la file et libererait d'autres onglets),
// puis attente reveillable bornee.

procedure TSshChannelBase.DoSkNotice;
begin
  if Assigned(FOnSkNotice) then
    FOnSkNotice(FSkNoticeActive, FSkNoticeText);
end;

procedure TSshChannelBase.SkNotice(AActive: Boolean; const AText: string);
begin
  if not Assigned(FOnSkNotice) then Exit;
  FSkNoticeActive := AActive;
  FSkNoticeText := AText;
  Queue(@DoSkNotice);
end;

procedure TSshChannelBase.AskSkPin;
begin
  try
    FSkPin := nil;
    FSkPinCancelled := True;
    if Assigned(FOnSkPin) then
      FOnSkPin(FSkPrompt, FSkPin, FSkPinCancelled);
  finally
    FSkEvent.SetEvent;
  end;
end;

function TSshChannelBase.WaitSkPin(const AReason: string;
  out APin: TSecureBytes): Boolean;
var
  i: Integer;
begin
  Result := False;
  APin := nil;
  if not Assigned(FOnSkPin) then Exit;
  FSkPrompt := AReason;
  FSkPin.Free;
  FSkPin := nil;
  FSkEvent.ResetEvent;
  Queue(@AskSkPin);
  i := 0;
  while (FSkEvent.WaitFor(200) = wrTimeout) and (not Terminated) do
  begin
    Inc(i, 200);
    if i >= SK_ANSWER_TIMEOUT_MS then
      Break;
  end;
  if Terminated or FSkPinCancelled then Exit;
  APin := FSkPin;      // la propriete passe a l'appelant
  FSkPin := nil;
  Result := APin <> nil;
end;

procedure TSshChannelBase.SkCancel;
begin
  FSkPinCancelled := True;
  FSkEvent.SetEvent;
  // Cancel SOUS le verrou: TryFidoKey depublie FSkOp sous ce meme verrou
  // avant de liberer l'objet. Relacher entre la lecture et l'appel laisserait
  // le thread de session le detruire sous nos pieds. Cancel ne bloque pas
  // (un drapeau et fido_dev_cancel), tenir le verrou ne coute rien.
  FSockLock.Acquire;
  try
    if FSkOp <> nil then
      TFidoOperation(FSkOp).Cancel;
  finally
    FSockLock.Release;
  end;
end;

{ TSshTransport }

constructor TSshTransport.Create(AParams: TSshConnectParams);
begin
  inherited Create(True);
  FStates := TSessionStateMachine.Create;
  FOutLock := TCriticalSection.Create;
  FStateLock := TCriticalSection.Create;
  FErrLock := TCriticalSection.Create;
  FExitCode := -1;
  FParams := AParams;
end;

destructor TSshTransport.Destroy;
begin
  inherited Destroy;
  FErrLock.Free;
  FStateLock.Free;
  FOutLock.Free;
  FStates.Free;
end;

function TSshTransport.State: TRemoteSessionState;
begin
  Result := FStates.State;
end;

procedure TSshTransport.SetState(ANext: TRemoteSessionState);
begin
  if not FStates.TryTransitionTo(ANext) then
    Exit;
  if not Assigned(FOnState) then
    Exit;
  FStateLock.Acquire;
  try
    SetLength(FStateQ, Length(FStateQ) + 1);
    FStateQ[High(FStateQ)] := ANext;
  finally
    FStateLock.Release;
  end;
  Queue(@PublishState);
end;

procedure TSshTransport.PublishState;
var
  st: TRemoteSessionState;
  has: Boolean;
begin
  FStateLock.Acquire;
  try
    has := Length(FStateQ) > 0;
    if has then
    begin
      st := FStateQ[0];
      Delete(FStateQ, 0, 1);
    end;
  finally
    FStateLock.Release;
  end;
  if has and Assigned(FOnState) then
    FOnState(st);
end;

procedure TSshTransport.PublishData;
var
  chunk: RawByteString;
begin
  chunk := FDataChunk;
  FDataChunk := '';
  if Assigned(FOnData) and (chunk <> '') then
    FOnData(chunk);
end;

procedure TSshTransport.PublishError;
var
  msg: string;
begin
  FErrLock.Acquire;
  try
    msg := FErrorMsg;
  finally
    FErrLock.Release;
  end;
  if Assigned(FOnError) then
    FOnError(msg);
end;

procedure TSshTransport.PublishFinished;
begin
  if Assigned(FOnFinished) then
    FOnFinished(FExitCode);
end;

procedure TSshTransport.Fail(const AMessage: string);
begin
  FErrLock.Acquire;
  try
    FErrorMsg := AMessage;
  finally
    FErrLock.Release;
  end;
  SetState(rssFailed);
  if Assigned(FOnError) then
    Queue(@PublishError);
end;

procedure TSshTransport.ReportError(const AMessage: string);
begin
  Fail(AMessage);
end;

function TSshTransport.WaitIo(AMs: Integer): Boolean;
begin
  Result := WaitSocket(AMs);
end;

function TSshChannelBase.LastSshError(const AContext: string): string;
var
  msg: PAnsiChar;
  len, rc: cint;
begin
  msg := nil;
  len := 0;
  rc := libssh2_session_last_error(FSession, @msg, @len, 0);
  if (msg <> nil) and (len > 0) then
    Result := Format('%s: %s (%d)', [AContext, string(AnsiString(msg)), rc])
  else
    Result := Format('%s (%d)', [AContext, rc]);
end;

procedure TSshTransport.SendData(const AData: RawByteString);
begin
  if AData = '' then
    Exit;
  FOutLock.Acquire;
  try
    FOutBuf := FOutBuf + AData;
  finally
    FOutLock.Release;
  end;
end;

procedure TSshTransport.RequestResize(ACols, ARows: Integer);
begin
  FOutLock.Acquire;
  try
    FPendingCols := ACols;
    FPendingRows := ARows;
    FResizeWanted := True;
  finally
    FOutLock.Release;
  end;
end;

procedure TSshTransport.Shutdown;
begin
  Terminate;
  FHostKeyDecision := hkdReject;
  FHostKeyEvent.SetEvent;
  // Un token qui attend le doigt ne regarde pas la socket: il faut lui dire
  // d'abandonner, sinon le thread reste bloque jusqu'au bout du delai.
  SkCancel;
  ShutdownSock;
end;

function TSshTransport.WaitSocket(AMs: Integer): Boolean;
var
  readable: Boolean;
begin
  Result := WaitSocketEx(AMs, readable);
end;

function TSshTransport.WaitSocketEx(AMs: Integer;
  out AReadable: Boolean): Boolean;
var
  rfds, wfds: TSockSet;
  dir, rc: cint;
  wantRead: Boolean;
begin
  SockSetZero(rfds);
  SockSetZero(wfds);
  dir := libssh2_session_block_directions(FSession);
  wantRead := (dir = 0) or ((dir and LIBSSH2_SESSION_BLOCK_INBOUND) <> 0);
  if wantRead then
    SockSetAdd(FSock, rfds);
  if (dir and LIBSSH2_SESSION_BLOCK_OUTBOUND) <> 0 then
    SockSetAdd(FSock, wfds);
  rc := SockSelect(FSock + 1, @rfds, @wfds, nil, AMs);
  Result := rc > 0;
  AReadable := (rc > 0) and wantRead and SockSetHas(FSock, rfds);
end;

function TSshChannelBase.IsAborted: Boolean;
begin
  Result := Terminated;
end;

// Tranche d'attente de l'etablissement non bloquant, False = abandonner (decision
// 0016): sous WinSock, shutdown() ne reveille ni un recv bloque ni un select.
function TSshChannelBase.SetupWait(ADeadline: QWord): Boolean;
begin
  Result := False;
  if Terminated or (GetTickCount64 >= ADeadline) then
    Exit;
  WaitIo(CONNECT_POLL_MS);
  Result := not Terminated;
end;

function TSshTransport.ResolveAndConnect: Boolean;
var
  res, ai: Paddrinfo;
  fd, rc: cint;
  waited: Integer;
  connected: Boolean;
  portStr, hostStr, resErr: string;
begin
  Result := False;
  res := nil;
  if FParams.ConnectHost <> '' then
  begin
    hostStr := FParams.ConnectHost;
    portStr := IntToStr(FParams.ConnectPort);
  end
  else
  begin
    hostStr := FParams.Host;
    portStr := IntToStr(FParams.Port);
  end;
  // Resolution ANNULABLE: getaddrinfo n'est pas interruptible et
  // le destructeur de l'onglet JOINT ce thread -- 40 s d'UI gelee sinon.
  if not ResolveCancellable(AnsiString(hostStr), AnsiString(portStr),
       @IsAborted, res, resErr) then
  begin
    if resErr <> '' then
      Fail(resErr);
    Exit;
  end;
  try
    ai := res;
    while (ai <> nil) and (not Terminated) do
    begin
      // candidat LOCAL: publie plus tot, Shutdown viserait un fd deja referme
      fd := fpSocket(ai^.ai_family, ai^.ai_socktype, ai^.ai_protocol);
      if fd < 0 then
      begin
        ai := ai^.ai_next;
        Continue;
      end;
      SockSetNonBlocking(fd, True);
      connected := False;
      rc := fpConnect(fd, ai^.ai_addr, TSocklen(ai^.ai_addrlen));
      if rc = 0 then
        connected := True
      else if SockErrIsInProgress(SockLastError) then
      begin
        // par TRANCHES: un select unique ignore Terminated, et l'onglet JOINT ce
        // thread -- 300 s pour le fermer
        waited := 0;
        while waited < FParams.ConnectTimeoutS * 1000 do
        begin
          if Terminated then Break;
          rc := SockWaitConnect(fd, CONNECT_POLL_MS);
          if rc > 0 then
          begin
            connected := SockGetPendingError(fd) = 0;
            Break;
          end;
          if rc < 0 then
          begin
            if SockErrIsIntr(SockLastError) then Continue;
            Break;
          end;
          Inc(waited, CONNECT_POLL_MS);
        end;
      end;
      if connected then
      begin
        SockSetNonBlocking(fd, False);
        PublishSock(fd);
        Exit(True);
      end;
      CloseSocket(fd);
      ai := ai^.ai_next;
    end;
  finally
    freeaddrinfo(res);
  end;
  if not Terminated then
    Fail(Format('Cannot connect to %s:%d (timeout %ds)',
      [FParams.Host, FParams.Port, FParams.ConnectTimeoutS]));
end;

function TSshChannelBase.Handshake: Boolean;
var
  rc: cint;
  deadline: QWord;
begin
  Result := False;
  FSession := libssh2_session_init_ex(nil, nil, nil, nil);
  if FSession = nil then
  begin
    ReportError(ErrInitFailed);
    Exit;
  end;
  libssh2_session_set_blocking(FSession, 0);
  libssh2_session_set_timeout(FSession, FParams.ConnectTimeoutS * 1000);

  // Hote connu: n'accepter que les types enregistres, sinon un serveur hostile en
  // presente un autre et sa cle modifiee passe pour un hote inconnu.
  if Length(FParams.KnownKeyTypes) > 0 then
    libssh2_session_method_pref(FSession, LIBSSH2_METHOD_HOSTKEY,
      PAnsiChar(AnsiString(Libssh2HostKeyPref(FParams.KnownKeyTypes))));

  deadline := GetTickCount64 + QWord(FParams.ConnectTimeoutS) * 1000;
  repeat
    rc := libssh2_session_handshake(FSession, FSock);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not SetupWait(deadline);
  if Terminated then
    Exit;
  if rc <> 0 then
  begin
    if (rc = LIBSSH2_ERROR_TIMEOUT) or (rc = LIBSSH2_ERROR_EAGAIN) then
      ReportError(ErrHandshakeTimeout)
    else
      ReportError(LastSshError(ErrHandshakeRefused));
    Exit;
  end;
  Result := True;
end;

procedure TSshChannelBase.DoHostKeyLookup;
begin
  if Assigned(FOnHostKeyLookup) then
    FOnHostKeyLookup(FHostKeyInfo.Host, FHostKeyInfo.Port,
      FHostKeyInfo.KeyType, FHostKeyInfo.Fingerprint,
      FHostKeyInfo.Verdict, FHostKeyInfo.KnownFingerprint);
end;

// Thread UI. La modale de FOnHostKey vide QueueAsyncCall dans sa boucle: elle
// libere d'AUTRES onglets, jamais celui-ci -- le SetEvent frapperait un mort.
procedure TSshChannelBase.AskHostKey;
begin
  try
    if Assigned(FOnHostKey) then
      FOnHostKey(FHostKeyInfo, FHostKeyDecision)
    else
      FHostKeyDecision := hkdReject;
  finally
    FHostKeyEvent.SetEvent;
  end;
end;

procedure TSshChannelBase.DoHostKeySave;
begin
  if Assigned(FOnHostKeySave) then
    FOnHostKeySave(FHostKeyInfo);
end;

function TSshChannelBase.VerifyHostKey: Boolean;
var
  hash: PAnsiChar;
  keyData: PAnsiChar;
  keyLen: csize_t;
  keyType: cint;
  raw: TBytes;
  i: Integer;
begin
  Result := False;
  hash := libssh2_hostkey_hash(FSession, LIBSSH2_HOSTKEY_HASH_SHA256);
  if hash = nil then
  begin
    ReportError(ErrHostKeyUnavailable);
    Exit;
  end;
  SetLength(raw, 32);
  Move(hash^, raw[0], 32);

  keyLen := 0;
  keyType := LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
  keyData := libssh2_session_hostkey(FSession, @keyLen, @keyType);

  FHostKeyInfo := Default(TSshHostKeyInfo);
  FHostKeyInfo.Host := FParams.Host;
  FHostKeyInfo.Port := FParams.Port;
  FHostKeyInfo.KeyType := Libssh2HostKeyTypeName(keyType);
  FHostKeyInfo.Fingerprint := FormatFingerprintSha256(raw);
  if (keyData <> nil) and (keyLen > 0) then
  begin
    SetLength(FHostKeyInfo.Blob, keyLen);
    Move(keyData^, FHostKeyInfo.Blob[0], keyLen);
  end;

  FHostKeyInfo.Verdict := hkUnknown;
  FHostKeyInfo.KnownFingerprint := '';
  Synchronize(@DoHostKeyLookup);

  if FHostKeyInfo.Verdict = hkMatch then
    Exit(True);

  // Non strict leve le TOFU pour un hote INCONNU, jamais pour une cle MODIFIEE:
  // avaler un changement de cle, c'est taire le seul signal de MITM qu'on ait.
  if (not FParams.StrictHostKey) and (FHostKeyInfo.Verdict <> hkChanged) then
    Exit(True);

  // inconnu ou modifie: l'utilisateur tranche
  FHostKeyDecision := hkdReject;
  FHostKeyEvent.ResetEvent;
  Queue(@AskHostKey);
  i := 0;
  while (FHostKeyEvent.WaitFor(200) = wrTimeout) and (not Terminated) do
  begin
    Inc(i, 200);
    if i >= HOSTKEY_ANSWER_TIMEOUT_MS then
      Break;
  end;

  if Terminated then
    Exit(False);

  case FHostKeyDecision of
    hkdAcceptOnce:
      Result := True;
    hkdAcceptAndSave:
      begin
        Synchronize(@DoHostKeySave);
        Result := True;
      end;
  else
    if FHostKeyInfo.Verdict = hkChanged then
      ReportError(ErrHostKeyChanged)
    else
      ReportError(ErrHostKeyNotApproved);
    Result := False;
  end;
end;

// --- Signature par cle de securite ------------------------------------------
// libssh2 lit le fichier de cle privee sk (qui ne contient aucun secret, juste
// le key handle), puis nous rappelle pour chaque signature. C'est lui qui
// fabrique ensuite le blob SSH « string sig || byte flags || uint32 counter ».

{$IFDEF WINDOWS}
// MEME CRT que libssh2: c'est son free() qui liberera sig_r/sig_s.
function c_malloc(ASize: PtrUInt): Pointer; cdecl;
  external 'ucrtbase.dll' name 'malloc';
{$ELSE}
function c_malloc(ASize: PtrUInt): Pointer; cdecl; external 'c' name 'malloc';
{$ENDIF}

type
  // Passe a libssh2 par le parametre « abstract », qui nous le repasse tel quel.
  TSshSkContext = class
    Owner: TSshChannelBase;
    Op: TFidoOperation;
    Alg: TSkAlg;
    Invoked: Boolean;        // la callback a-t-elle ete appelee au moins une fois
    GestureTick: QWord;      // date du dernier geste, pour re-armer le budget
    ErrorText: string;
    function TouchToNotice(AActive: Boolean; const ADevice: string): string;
    procedure OnTouch(AActive: Boolean; const ADevice: string);
    function OnPin(const AReason: string; out APin: TSecureBytes): Boolean;
  end;

function TSshSkContext.TouchToNotice(AActive: Boolean;
  const ADevice: string): string;
begin
  if ADevice <> '' then
    Result := 'Touch your security key (' + ADevice + ')'
  else
    Result := 'Touch your security key';
end;

procedure TSshSkContext.OnTouch(AActive: Boolean; const ADevice: string);
begin
  Owner.SkNotice(AActive, TouchToNotice(AActive, ADevice));
  if not AActive then
    GestureTick := GetTickCount64;
end;

function TSshSkContext.OnPin(const AReason: string;
  out APin: TSecureBytes): Boolean;
begin
  // L'avis « touchez » disparait pendant la saisie: deux fenetres a la fois
  // pour une seule action, c'est une de trop.
  Owner.SkNotice(False, '');
  Result := Owner.WaitSkPin(AReason, APin);
end;

function CopyToC(const ASrc: TBytes): PByte;
begin
  Result := nil;
  if Length(ASrc) = 0 then Exit;
  Result := PByte(c_malloc(Length(ASrc)));
  if Result <> nil then
    Move(ASrc[0], Result^, Length(ASrc));
end;

function SkSignCallback(session: PLIBSSH2_SESSION;
  sig_info: PLIBSSH2_SK_SIG_INFO; data: PByte; data_len: csize_t;
  algorithm: cint; flags: cuint8; application: PAnsiChar;
  key_handle: PByte; handle_len: csize_t; abstract_: PPointer): cint; cdecl;
var
  ctx: TSshSkContext;
  sig: TFidoSignature;
  alg: TSkAlg;
  handle: TBytes;
  err: string;
begin
  Result := -1;
  if (abstract_ = nil) or (abstract_^ = nil) or (sig_info = nil) then Exit;
  ctx := TSshSkContext(abstract_^);
  ctx.Invoked := True;
  // « algorithm » vient du type lu dans la cle privee, pas d'un choix a nous.
  case algorithm of
    LIBSSH2_HOSTKEY_TYPE_ED25519: alg := skaEd25519;
    LIBSSH2_HOSTKEY_TYPE_ECDSA_256: alg := skaEcdsaP256;
  else
    ctx.ErrorText := 'Unsupported security key algorithm';
    Exit;
  end;
  ctx.Alg := alg;

  SetLength(handle, handle_len);
  if handle_len > 0 then
    Move(key_handle^, handle[0], handle_len);

  // application, data et key_handle appartiennent a libssh2: on copie, on ne
  // libere rien.
  if not ctx.Op.Sign(string(AnsiString(application)), handle, Byte(flags),
    data, data_len, alg, sig, err) then
  begin
    ctx.ErrorText := err;
    Exit;
  end;

  sig_info^.flags := sig.Flags;
  sig_info^.counter := sig.Counter;
  sig_info^.sig_r := CopyToC(sig.R);
  sig_info^.sig_r_len := Length(sig.R);
  sig_info^.sig_s := nil;
  sig_info^.sig_s_len := 0;
  if sig_info^.sig_r = nil then
  begin
    ctx.ErrorText := 'out of memory';
    Exit;
  end;
  if Length(sig.S) > 0 then
  begin
    sig_info^.sig_s := CopyToC(sig.S);
    sig_info^.sig_s_len := Length(sig.S);
    if sig_info^.sig_s = nil then
    begin
      ctx.ErrorText := 'out of memory';
      Exit;
    end;
  end;
  Result := 0;
end;

function TSshChannelBase.Authenticate: Boolean;
var
  rc: cint;
  user: AnsiString;
  agent: Pointer;
  ident, prevIdent: Pointer;
  authList: PAnsiChar;
  methods: string;
  deadline: QWord;

  function TryAgent: Boolean;
  begin
    Result := False;
    agent := libssh2_agent_init(FSession);
    if agent = nil then
      Exit;
    try
      if libssh2_agent_connect(agent) <> 0 then
        Exit;
      try
        if libssh2_agent_list_identities(agent) <> 0 then
          Exit;
        prevIdent := nil;
        repeat
          ident := nil;
          rc := libssh2_agent_get_identity(agent, @ident, prevIdent);
          if rc <> 0 then
            Break;
          repeat
            rc := libssh2_agent_userauth(agent, PAnsiChar(user), ident);
            if rc <> LIBSSH2_ERROR_EAGAIN then Break;
          until not SetupWait(deadline);
          if rc = 0 then
            Exit(True);
          prevIdent := ident;
        until Terminated;
      finally
        libssh2_agent_disconnect(agent);
      end;
    finally
      libssh2_agent_free(agent);
    end;
  end;

  function TryKey: Boolean;
  var
    pass: PAnsiChar;
    passNul: TSecureBytes;
    pubData: PAnsiChar;
    pubLen: csize_t;
  begin
    Result := False;
    if (FParams.PrivateKey = nil) or (FParams.PrivateKey.Len = 0) then
      Exit;
    // libssh2 lit la passphrase comme une chaine C, et TSecureBytes fait pile la
    // taille du secret (garde sodium juste apres): copie +1 octet, ou ca crashe
    pass := nil;
    passNul := nil;
    try
      if (FParams.Passphrase <> nil) and (FParams.Passphrase.Len > 0) then
      begin
        passNul := TSecureBytes.Create(FParams.Passphrase.Len + 1);
        Move(FParams.Passphrase.Data^, passNul.Data^, FParams.Passphrase.Len);
        pass := PAnsiChar(passNul.Data);
      end;
      pubData := nil;
      pubLen := 0;
      if (FParams.PublicKey <> nil) and (FParams.PublicKey.Len > 0) then
      begin
        pubData := PAnsiChar(FParams.PublicKey.Data);
        pubLen := FParams.PublicKey.Len;
      end;
      repeat
        rc := libssh2_userauth_publickey_frommemory(FSession,
          PAnsiChar(user), Length(user),
          pubData, pubLen,
          PAnsiChar(FParams.PrivateKey.Data), FParams.PrivateKey.Len,
          pass);
        if rc <> LIBSSH2_ERROR_EAGAIN then Break;
      until not SetupWait(deadline);
      Result := rc = 0;
    finally
      passNul.Free;   // sodium_free efface la copie
    end;
  end;

  function TryFidoKey: Boolean;
  var
    ctx: TSshSkContext;
    abs: Pointer;
    seenGesture: QWord;
  begin
    Result := False;
    if not Libssh2HasSkAuth then
    begin
      FAuthDetail := ErrNoSkSupport;
      Exit;
    end;
    if (FParams.PrivateKey = nil) or (FParams.PrivateKey.Len = 0) then Exit;

    ctx := TSshSkContext.Create;
    try
      ctx.Owner := Self;
      ctx.Op := TFidoOperation.Create;
      ctx.Op.OnTouch := @ctx.OnTouch;
      ctx.Op.OnPin := @ctx.OnPin;
      // Publie pour que Shutdown, qui vient du thread UI, puisse annuler
      // l'attente du geste.
      FSockLock.Acquire;
      try
        FSkOp := ctx.Op;
      finally
        FSockLock.Release;
      end;
      try
        abs := ctx;
        seenGesture := 0;
        repeat
          rc := libssh2_userauth_publickey_sk(FSession,
            PAnsiChar(user), Length(user),
            nil, 0,
            PAnsiChar(FParams.PrivateKey.Data), FParams.PrivateKey.Len,
            nil, @SkSignCallback, @abs);
          // Le temps passe le doigt en l'air n'est pas du temps reseau: sans ce
          // reglage, un utilisateur qui reflechit dix secondes ferait expirer
          // une connexion parfaitement saine.
          if ctx.GestureTick <> seenGesture then
          begin
            seenGesture := ctx.GestureTick;
            deadline := GetTickCount64 + QWord(FParams.ConnectTimeoutS) * 1000;
          end;
          if rc <> LIBSSH2_ERROR_EAGAIN then Break;
        until not SetupWait(deadline);
        Result := rc = 0;

        if (not Result) and (not Terminated) then
        begin
          if ctx.ErrorText <> '' then
            FAuthDetail := ctx.ErrorText
          else if rc = LIBSSH2_ERROR_FILE then
            FAuthDetail := LastSshError(ErrSkBackend)
          else if not ctx.Invoked then
            FAuthDetail := ErrSkRejectedBeforeSign
          else
            FAuthDetail := LastSshError('FIDO2 authentication failed');
        end;
      finally
        FSockLock.Acquire;
        try
          FSkOp := nil;
        finally
          FSockLock.Release;
        end;
        SkNotice(False, '');
        ctx.Op.Free;
      end;
    finally
      ctx.Free;
    end;
  end;

  function TryPassword: Boolean;
  begin
    Result := False;
    if (FParams.Password = nil) or (FParams.Password.Len = 0) then
      Exit;
    repeat
      rc := libssh2_userauth_password_ex(FSession,
        PAnsiChar(user), Length(user),
        PAnsiChar(FParams.Password.Data), FParams.Password.Len, nil);
      if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not SetupWait(deadline);
    Result := rc = 0;
  end;

begin
  Result := False;
  user := AnsiString(FParams.Username);
  if user = '' then
  begin
    ReportError(ErrNoUsername);
    Exit;
  end;
  deadline := GetTickCount64 + QWord(FParams.ConnectTimeoutS) * 1000;

  repeat
    authList := libssh2_userauth_list(FSession, PAnsiChar(user), Length(user));
    if (authList <> nil) or
       (libssh2_session_last_errno(FSession) <> LIBSSH2_ERROR_EAGAIN) then
      Break;
  until not SetupWait(deadline);
  if authList = nil then
    methods := ''
  else
    methods := string(AnsiString(authList));

  if libssh2_userauth_authenticated(FSession) <> 0 then
  begin
    FParams.WipeSecrets;   // on sort avant celui d'en bas
    Exit(True);
  end;

  // une seule methode: pas d'essai silencieux de tous les credentials
  case FParams.AuthKind of
    sakAgent: Result := TryAgent;
    sakKey: Result := TryKey;
    sakFidoKey: Result := TryFidoKey;
    sakPassword: Result := TryPassword;
    sakPrompt: Result := TryPassword;
  end;

  FParams.WipeSecrets;

  if Terminated then
    Exit;   // fermeture demandee: pas d'echec a signaler

  if not Result then
  begin
    // Un echec de cle de securite a une cause precise (token absent, PIN
    // refuse, serveur trop ancien): « authentification refusee » la perdrait.
    if FAuthDetail <> '' then
      ReportError(FAuthDetail)
    else
      ReportError(AuthRefusedMsg(FParams.Username, methods));
  end;
end;

function TSshTransport.OpenShell: Boolean;
var
  rc: cint;
  cmd: AnsiString;
  deadline: QWord;
begin
  Result := False;
  deadline := GetTickCount64 + QWord(FParams.ConnectTimeoutS) * 1000;
  repeat
    FChannel := libssh2_channel_open_ex(FSession, 'session', 7,
      LIBSSH2_CHANNEL_WINDOW_DEFAULT, LIBSSH2_CHANNEL_PACKET_DEFAULT, nil, 0);
    if (FChannel <> nil) or
       (libssh2_session_last_errno(FSession) <> LIBSSH2_ERROR_EAGAIN) then
      Break;
  until not SetupWait(deadline);
  if FChannel = nil then
  begin
    if not Terminated then
      Fail(LastSshError('Channel open refused'));
    Exit;
  end;

  libssh2_channel_handle_extended_data2(FChannel,
    LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE);

  if FParams.RequestPty then
  begin
    repeat
      rc := libssh2_channel_request_pty_ex(FChannel,
        PAnsiChar(AnsiString(FParams.TermType)), Length(FParams.TermType),
        nil, 0, FParams.Cols, FParams.Rows, 0, 0);
      if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not SetupWait(deadline);
    if rc <> 0 then
    begin
      if not Terminated then
        Fail(LastSshError('PTY request refused'));
      Exit;
    end;
  end;

  // 'exec' et pas de shell: un Ctrl-C y frapperait l'HOTE
  if FParams.ExecCommand <> '' then
  begin
    cmd := AnsiString(FParams.ExecCommand);
    repeat
      rc := libssh2_channel_process_startup(FChannel, 'exec', 4,
        PAnsiChar(cmd), Length(cmd));
      if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not SetupWait(deadline);
    if rc <> 0 then
    begin
      if not Terminated then
        Fail(LastSshError('Command startup refused'));
      Exit;
    end;
    Result := True;
    Exit;
  end;

  repeat
    rc := libssh2_channel_process_startup(FChannel, 'shell', 5, nil, 0);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not SetupWait(deadline);
  if rc <> 0 then
  begin
    if not Terminated then
      Fail(LastSshError('Shell startup refused'));
    Exit;
  end;

  // tapee dans le shell distant, jamais executee localement
  if FParams.StartupCommand <> '' then
  begin
    cmd := AnsiString(FParams.StartupCommand) + #13;
    SendData(cmd);
  end;

  Result := True;
end;

procedure TSshTransport.ShellLoop;
var
  buf: array[0..READ_CHUNK - 1] of AnsiChar;
  n: cssize_t;
  pending: RawByteString;
  wrote: cssize_t;
  cols, rows: Integer;
  doResize: Boolean;
  idle: Boolean;
  secondsToNext: cint;
  rc: cint;
  lastRxMs, deadMs: QWord;
  readable: Boolean;
begin
  libssh2_session_set_blocking(FSession, 0);
  lastRxMs := GetTickCount64;
  deadMs := 0;
  if (FParams.KeepaliveS > 0) and (FParams.KeepaliveMaxFailures > 0) then
    deadMs := QWord(FParams.KeepaliveS)
      * QWord(FParams.KeepaliveMaxFailures + 1) * 1000;
  if FParams.KeepaliveS > 0 then
    // want_reply=1: le serveur DOIT repondre, et la sonde est indiscernable du
    // trafic SSH -- aucun pare-feu ne la filtre.
    libssh2_keepalive_config(FSession, 1, FParams.KeepaliveS);

  while not Terminated do
  begin
    idle := True;

    FOutLock.Acquire;
    try
      doResize := FResizeWanted;
      cols := FPendingCols;
      rows := FPendingRows;
      FResizeWanted := False;
    finally
      FOutLock.Release;
    end;
    if doResize and (cols > 0) and (rows > 0) then
      libssh2_channel_request_pty_size_ex(FChannel, cols, rows, 0, 0);

    FOutLock.Acquire;
    try
      pending := FOutBuf;
      FOutBuf := '';
    finally
      FOutLock.Release;
    end;
    while (pending <> '') and (not Terminated) do
    begin
      wrote := libssh2_channel_write_ex(FChannel, 0,
        PAnsiChar(pending), Length(pending));
      if wrote = LIBSSH2_ERROR_EAGAIN then
      begin
        FOutLock.Acquire;
        try
          FOutBuf := pending + FOutBuf;
        finally
          FOutLock.Release;
        end;
        Break;
      end;
      if wrote < 0 then
      begin
        Fail(LastSshError('SSH write failed'));
        Exit;
      end;
      Delete(pending, 1, wrote);
      idle := False;
    end;

    repeat
      n := libssh2_channel_read_ex(FChannel, 0, @buf[0], READ_CHUNK);
      if n > 0 then
      begin
        SetLength(FDataChunk, n);
        Move(buf[0], FDataChunk[1], n);
        Synchronize(@PublishData);
        idle := False;
        lastRxMs := GetTickCount64;
      end;
    until (n <= 0) or Terminated;

    if n = LIBSSH2_ERROR_EAGAIN then
      // rien a lire pour l'instant
    else if n < 0 then
    begin
      Fail(LastSshError('SSH read failed'));
      Exit;
    end;

    if libssh2_channel_eof(FChannel) <> 0 then
      Break;

    if FParams.KeepaliveS > 0 then
    begin
      secondsToNext := 0;
      rc := libssh2_keepalive_send(FSession, @secondsToNext);
      if (rc < 0) and (rc <> LIBSSH2_ERROR_EAGAIN) and
         (rc <> LIBSSH2_ERROR_SOCKET_SEND) then
      begin
        Fail(LastSshError('Connection lost (keepalive)'));
        Exit;
      end;
    end;

    if idle then
      // rearmer sur la LECTURE seule: le noyau du pair ACKe meme SSH gele
      if WaitSocketEx(SHELL_POLL_MS, readable) and readable then
        lastRxMs := GetTickCount64;

    if (deadMs > 0) and (GetTickCount64 - lastRxMs > deadMs) then
    begin
      Fail('Connection lost: no response from the server.');
      Exit;
    end;
  end;
end;

procedure TSshTransport.Cleanup;
var
  sockToClose: cint;
begin
  if FChannel <> nil then
  begin
    libssh2_session_set_blocking(FSession, 1);
    libssh2_session_set_timeout(FSession, SHUTDOWN_GRACE_MS);
    FExitCode := libssh2_channel_get_exit_status(FChannel);
    libssh2_channel_send_eof(FChannel);
    libssh2_channel_close(FChannel);
    libssh2_channel_free(FChannel);
    FChannel := nil;
  end;
  if FSession <> nil then
  begin
    libssh2_session_set_blocking(FSession, 1);
    libssh2_session_set_timeout(FSession, SHUTDOWN_GRACE_MS);
    libssh2_session_disconnect_ex(FSession, SSH_DISCONNECT_BY_APPLICATION,
      'bye', '');
    libssh2_session_free(FSession);
    FSession := nil;
  end;
  // Depublier AVANT de fermer: Shutdown ne doit pas viser un descripteur mourant.
  sockToClose := TakeSock;
  if sockToClose >= 0 then
    CloseSocket(sockToClose);
end;

procedure TSshTransport.Execute;
begin
  try
    try
      Libssh2EnsureLoaded;

      SetState(rssConnecting);
      if not ResolveAndConnect then
        Exit;
      // PAS de keepalive TCP: un pare-feu strict jette ses sondes et le noyau
      // declare mort un pair bien vivant.
      if Terminated then
        Exit;
      if not Handshake then
        Exit;
      if not VerifyHostKey then
        Exit;

      SetState(rssAuthenticating);
      if not Authenticate then
        Exit;
      if Terminated then
        Exit;

      if not OpenShell then
        Exit;

      SetState(rssConnected);
      ShellLoop;

      SetState(rssDisconnecting);
    except
      on E: Exception do
        Fail(E.Message);
    end;
  finally
    FParams.WipeSecrets;
    try
      Cleanup;
    except
      on E: Exception do
        ;   // deja en train de fermer: rien de plus a tenter
    end;
    FStates.TryTransitionTo(rssDisconnecting);
    FStates.TryTransitionTo(rssDisconnected);
    if Assigned(FOnFinished) then
      Queue(@PublishFinished);
  end;
end;

end.
