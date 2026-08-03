unit uSshTunnel;

{$mode objfpc}{$H+}

// Tunnel SSH par direct-tcpip: jump hosts, VNC/RDP/SSH-over-SSH.
// Session vers la passerelle (memes etapes et meme TOFU que le transport shell),
// puis ecoute sur 127.0.0.1:<port ephemere>, une connexion locale a la fois.
// Mise en place bloquante, pompe non bloquante: un cote lent gelerait l'autre.

interface

uses
  SysUtils, Classes, SyncObjs, ctypes, Sockets, uSockCompat,
  uLibssh2Api, uSshTransport, uSessionState;

type
  TSshTunnel = class(TSshChannelBase)
  private
    FTargetHost: string;
    FTargetPort: Integer;

    FListenSock: libssh2_socket_t;
    FLocalPort: Integer;

    FReadyEvent: TEvent;
    FReady: Boolean;
    FErrLock: TCriticalSection;
    FErrorMsg: string;
    FOnAsyncError: TThreadMethod;
    FErrNotified: Boolean;

    procedure SetError(const AMessage: string);
    function GetLastError: string;
    procedure DeliverAsyncError;

    function ResolveAndConnect: Boolean;
    function OpenLocalListener: Boolean;
    function WaitTwo(AFd1, AFd2: libssh2_socket_t; AMs: Integer): Boolean;
    function WaitWritable(AFd: libssh2_socket_t; AMs: Integer): Boolean;
    // la DIRECTION que libssh2 reclame: un blocage en ecriture n'attend pas la
    // lecture
    function WaitSession(AMs: Integer): Boolean;
    procedure ForwardOne(ALocalSock: libssh2_socket_t);
    procedure ForwardLoop;
    procedure Cleanup;
  protected
    procedure ReportError(const AMessage: string); override;
    function WaitIo(AMs: Integer): Boolean; override;
    function ErrInitFailed: string; override;
    function ErrHandshakeTimeout: string; override;
    function ErrHandshakeRefused: string; override;
    function ErrHostKeyUnavailable: string; override;
    function ErrHostKeyChanged: string; override;
    function ErrHostKeyNotApproved: string; override;
    function ErrNoUsername: string; override;
    function AuthRefusedMsg(const AUser, AMethods: string): string; override;
    procedure Execute; override;
  public
    constructor Create(AParams: TSshConnectParams;
      const ATargetHost: string; ATargetPort: Integer);
    destructor Destroy; override;

    procedure Shutdown;

    // Pas de WaitReady bloquant: la mise en place passe par Synchronize, qui
    // exige un thread UI vivant -- l'attendre depuis l'UI serait un interblocage.
    property LocalPort: Integer read FLocalPort;
    property LastError: string read GetLastError;
    // echec livre UNE fois sur le thread UI; le destinataire relit LastError
    property OnAsyncError: TThreadMethod read FOnAsyncError write FOnAsyncError;
    property OnHostKey: TSshHostKeyEvent read FOnHostKey write FOnHostKey;
    property OnHostKeyLookup: TSshHostKeyLookup
      read FOnHostKeyLookup write FOnHostKeyLookup;
    property OnHostKeySave: TSshHostKeySave
      read FOnHostKeySave write FOnHostKeySave;
  end;

implementation

uses
  uNetResolve, uLog;

const
  TUNNEL_BUF = 32768;
  ACCEPT_POLL_MS = 200;
  {$IFDEF WINDOWS}
  SO_EXCLUSIVEADDRUSE = cint(not cint(SO_REUSEADDR));
  {$ENDIF}

{ TSshTunnel }

constructor TSshTunnel.Create(AParams: TSshConnectParams;
  const ATargetHost: string; ATargetPort: Integer);
begin
  inherited Create(True);
  FParams := AParams;
  FTargetHost := ATargetHost;
  FTargetPort := ATargetPort;
  FListenSock := -1;
  FLocalPort := 0;
  FErrLock := TCriticalSection.Create;
  FReadyEvent := TEvent.Create(nil, True, False, '');
end;

destructor TSshTunnel.Destroy;
begin
  inherited Destroy;
  FReadyEvent.Free;
  FErrLock.Free;
end;

procedure TSshTunnel.SetError(const AMessage: string);
var
  isFirst: Boolean;
begin
  FErrLock.Acquire;
  try
    isFirst := FErrorMsg = '';
    if isFirst then
      FErrorMsg := AMessage;
  finally
    FErrLock.Release;
  end;
  if not isFirst then Exit;
  // le message porte hotes et ports: en confidentiel, on ne trace que le fait
  if LogIsConfidential then
    LogWarning('tunnel: error (details hidden in confidential mode)')
  else
    LogWarning('tunnel: ' + AMessage);
  if Assigned(FOnAsyncError) and (not FErrNotified) then
  begin
    FErrNotified := True;
    Queue(@DeliverAsyncError);
  end;
end;

procedure TSshTunnel.DeliverAsyncError;
begin
  if Assigned(FOnAsyncError) then
    FOnAsyncError();
end;

function TSshTunnel.GetLastError: string;
begin
  FErrLock.Acquire;
  try
    Result := FErrorMsg;
  finally
    FErrLock.Release;
  end;
end;

procedure TSshTunnel.ReportError(const AMessage: string);
begin
  SetError(AMessage);
end;

function TSshTunnel.WaitIo(AMs: Integer): Boolean;
begin
  Result := WaitSession(AMs);
end;

function TSshTunnel.ErrInitFailed: string;
begin
  Result := 'Cannot initialize libssh2 (tunnel)';
end;

function TSshTunnel.ErrHandshakeTimeout: string;
begin
  Result := 'SSH handshake timed out (tunnel)';
end;

function TSshTunnel.ErrHandshakeRefused: string;
begin
  Result := 'SSH handshake refused (tunnel)';
end;

function TSshTunnel.ErrHostKeyUnavailable: string;
begin
  Result := 'Jump host key unavailable';
end;

function TSshTunnel.ErrHostKeyChanged: string;
begin
  Result := 'Tunnel refused: the jump host key has changed.';
end;

function TSshTunnel.ErrHostKeyNotApproved: string;
begin
  Result := 'Tunnel refused: jump host key not approved.';
end;

function TSshTunnel.ErrNoUsername: string;
begin
  Result := 'No username for the jump host.';
end;

function TSshTunnel.AuthRefusedMsg(const AUser, AMethods: string): string;
begin
  Result := Format('Jump host authentication refused for %s', [AUser]);
end;

procedure TSshTunnel.Shutdown;
begin
  Terminate;
  FHostKeyDecision := hkdReject;
  FHostKeyEvent.SetEvent;
end;

function TSshTunnel.ResolveAndConnect: Boolean;
var
  res, ai: Paddrinfo;
  fd, rc: cint;
  waited: Integer;
  connected: Boolean;
  resErr: string;
begin
  Result := False;

  // resolution ANNULABLE: getaddrinfo n'est pas interruptible
  if not ResolveCancellable(AnsiString(FParams.Host),
       AnsiString(IntToStr(FParams.Port)), @IsAborted, res, resErr) then
  begin
    if resErr <> '' then
      SetError(Format('Jump host not found: %s', [FParams.Host]));
    Exit;
  end;
  try
    ai := res;
    while (ai <> nil) and (not Terminated) do
    begin
      // candidat LOCAL: publie a l'essai, il exposerait un fd mort au thread UI
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
        // select DECOUPE: la fermeture ne doit pas rester coincee tout le timeout
        waited := 0;
        while (waited < FParams.ConnectTimeoutS * 1000) and (not Terminated) do
        begin
          rc := SockWaitConnect(fd, 200);
          if rc > 0 then
          begin
            connected := SockGetPendingError(fd) = 0;
            Break;
          end;
          if rc < 0 then Break;
          Inc(waited, 200);
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
    SetError(Format('Jump host unreachable %s:%d (timeout %ds)',
      [FParams.Host, FParams.Port, FParams.ConnectTimeoutS]));
end;

function TSshTunnel.OpenLocalListener: Boolean;
var
  addr: TInetSockAddr;
  len: TSocklen;
  yes: cint;
begin
  Result := False;
  FListenSock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if FListenSock < 0 then
  begin
    SetError('Cannot open the local listener (socket)');
    Exit;
  end;
  yes := 1;
  {$IFDEF WINDOWS}
  // Sous Windows, SO_REUSEADDR laisserait un AUTRE processus se lier au meme
  // port et detourner les connexions -- semantique inverse d'Unix.
  fpSetSockOpt(FListenSock, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, @yes, SizeOf(yes));
  {$ELSE}
  fpSetSockOpt(FListenSock, SOL_SOCKET, SO_REUSEADDR, @yes, SizeOf(yes));
  {$ENDIF}
  FillChar(addr, SizeOf(addr), 0);
  addr.sin_family := AF_INET;
  addr.sin_port := 0;
  addr.sin_addr.s_addr := htonl($7F000001); // 127.0.0.1 UNIQUEMENT, jamais expose
  if fpBind(FListenSock, @addr, SizeOf(addr)) <> 0 then
  begin
    SetError('Cannot open the local listener (bind)');
    Exit;
  end;
  if fpListen(FListenSock, 1) <> 0 then
  begin
    SetError('Cannot open the local listener (listen)');
    Exit;
  end;
  len := SizeOf(addr);
  if fpGetSockName(FListenSock, @addr, @len) <> 0 then
  begin
    SetError('Cannot open the local listener (getsockname)');
    Exit;
  end;
  FLocalPort := ntohs(addr.sin_port);
  Result := FLocalPort > 0;
end;

function TSshTunnel.WaitTwo(AFd1, AFd2: libssh2_socket_t;
  AMs: Integer): Boolean;
var
  rfds: TSockSet;
  mx: libssh2_socket_t;
begin
  SockSetZero(rfds);
  SockSetAdd(AFd1, rfds);
  if AFd2 >= 0 then
    SockSetAdd(AFd2, rfds);
  mx := AFd1;
  if AFd2 > mx then mx := AFd2;
  Result := SockSelect(mx + 1, @rfds, nil, nil, AMs) > 0;
end;

function TSshTunnel.WaitWritable(AFd: libssh2_socket_t; AMs: Integer): Boolean;
var
  wfds: TSockSet;
begin
  SockSetZero(wfds);
  SockSetAdd(AFd, wfds);
  Result := SockSelect(AFd + 1, nil, @wfds, nil, AMs) > 0;
end;

function TSshTunnel.WaitSession(AMs: Integer): Boolean;
var
  rfds, wfds: TSockSet;
  dir: cint;
begin
  dir := libssh2_session_block_directions(FSession);
  SockSetZero(rfds);
  SockSetZero(wfds);
  if (dir and LIBSSH2_SESSION_BLOCK_INBOUND) <> 0 then
    SockSetAdd(FSock, rfds);
  if (dir and LIBSSH2_SESSION_BLOCK_OUTBOUND) <> 0 then
    SockSetAdd(FSock, wfds);
  if dir = 0 then
    SockSetAdd(FSock, rfds);
  Result := SockSelect(FSock + 1, @rfds, @wfds, nil, AMs) > 0;
end;

procedure TSshTunnel.ForwardOne(ALocalSock: libssh2_socket_t);
var
  channel: PLIBSSH2_CHANNEL;
  buf: array[0..TUNNEL_BUF - 1] of Byte;
  n, w, off: cssize_t;
  tries: cint;
  openStart: QWord;
begin
  // Ouverture BORNEE: un bastion qui ne joint pas la cible ne refuse pas le
  // canal, il rend EAGAIN jusqu'au timeout TCP de SON noyau (~2 min) -- onglet
  // noir et muet. Au-dela du budget, on ferme en disant pourquoi.
  channel := nil;
  openStart := GetTickCount64;
  repeat
    channel := libssh2_channel_direct_tcpip_ex(FSession,
      PAnsiChar(AnsiString(FTargetHost)), FTargetPort,
      PAnsiChar('127.0.0.1'), FLocalPort);
    if (channel = nil) and
       (libssh2_session_last_errno(FSession) = LIBSSH2_ERROR_EAGAIN) then
    begin
      if Terminated then Break;
      if (GetTickCount64 - openStart) >=
         QWord(FParams.ConnectTimeoutS) * 1000 then
      begin
        SetError(Format(
          'The jump host could not reach %s:%d within %ds: the target did ' +
          'not answer (unreachable, filtered, or the name does not resolve ' +
          'to a reachable address from the jump host).',
          [FTargetHost, FTargetPort, FParams.ConnectTimeoutS]));
        CloseSocket(ALocalSock);
        Exit;
      end;
      WaitSession(200);
    end;
  until (channel <> nil) or Terminated;
  if channel = nil then
  begin
    // libssh2 ne distingue pas AllowTcpForwarding no d'une cible injoignable
    if not Terminated then
      SetError(LastSshError(Format(
        'The jump host refused to open a tunnel to %s:%d. Either it forbids ' +
        'TCP forwarding (AllowTcpForwarding no), or it cannot reach that ' +
        'target', [FTargetHost, FTargetPort])));
    CloseSocket(ALocalSock);
    Exit;
  end;

  SockSetNonBlocking(ALocalSock, True);
  try
    while not Terminated do
    begin
      WaitTwo(FSock, ALocalSock, 200);

      n := fpRecv(ALocalSock, @buf[0], SizeOf(buf), 0);
      if n = 0 then
        Break;
      if n < 0 then
      begin
        if not SockErrIsWouldBlock(SockLastError) then
          Break;
      end
      else
      begin
        off := 0;
        while off < n do
        begin
          w := libssh2_channel_write_ex(channel, 0, @buf[off], n - off);
          if (w = LIBSSH2_ERROR_EAGAIN) or (w = 0) then   // w = 0: boucle a vide
          begin
            if Terminated then Break;
            WaitSession(200);
            Continue;
          end;
          if w < 0 then Exit;
          Inc(off, w);
        end;
      end;

      repeat
        n := libssh2_channel_read_ex(channel, 0, @buf[0], SizeOf(buf));
        if n = LIBSSH2_ERROR_EAGAIN then
          Break;
        if n < 0 then
          Exit;
        if n > 0 then
        begin
          off := 0;
          while off < n do
          begin
            w := fpSend(ALocalSock, @buf[off], n - off, 0);
            if w <= 0 then
            begin
              if (w < 0) and SockErrIsWouldBlock(SockLastError) then
              begin
                // sortir AVANT de dormir: un pair local muet bloquait le join
                if Terminated then Exit;
                WaitWritable(ALocalSock, 200);
                Continue;
              end;
              Exit;
            end;
            Inc(off, w);
          end;
        end;
      until (n = 0) or Terminated;

      if libssh2_channel_eof(channel) <> 0 then
        Break;
    end;
  finally
    // close/free rendent EAGAIN: un seul appel laisserait le canal ouvert
    tries := 0;
    while (libssh2_channel_close(channel) = LIBSSH2_ERROR_EAGAIN)
          and (tries < 50) and (not Terminated) do
    begin
      WaitSession(100);
      Inc(tries);
    end;
    tries := 0;
    while (libssh2_channel_free(channel) = LIBSSH2_ERROR_EAGAIN)
          and (tries < 50) and (not Terminated) do
    begin
      WaitSession(100);
      Inc(tries);
    end;
    CloseSocket(ALocalSock);
  end;
end;

procedure TSshTunnel.ForwardLoop;
var
  local: libssh2_socket_t;
  sa: TInetSockAddr;
  slen: TSocklen;
begin
  libssh2_session_set_blocking(FSession, 0);
  SockSetNonBlocking(FListenSock, True);
  while not Terminated do
  begin
    if not WaitTwo(FListenSock, -1, ACCEPT_POLL_MS) then
      Continue;
    slen := SizeOf(sa);
    local := fpAccept(FListenSock, @sa, @slen);
    if local < 0 then
      Continue;
    ForwardOne(local);
  end;
end;

procedure TSshTunnel.Cleanup;
var
  sockToClose: libssh2_socket_t;
begin
  if FSession <> nil then
  begin
    // l'adieu SSH est une courtoisie: sur un pair mort il attendrait des minutes
    libssh2_session_set_timeout(FSession, 3000);
    libssh2_session_set_blocking(FSession, 1);
    libssh2_session_disconnect_ex(FSession, SSH_DISCONNECT_BY_APPLICATION,
      'tunnel closed', '');
    libssh2_session_free(FSession);
    FSession := nil;
  end;
  if FListenSock >= 0 then
  begin
    CloseSocket(FListenSock);
    FListenSock := -1;
  end;
  // depublier AVANT de fermer: un shutdown() concurrent viserait un fd rendu
  sockToClose := TakeSock;
  if sockToClose >= 0 then
    CloseSocket(sockToClose);
end;

procedure TSshTunnel.Execute;
begin
  try
    try
      // premier utilisateur de libssh2 si VNC/RDP sans session shell: sinon
      // Handshake appelle des pointeurs nuls
      Libssh2EnsureLoaded;
      if not ResolveAndConnect then Exit;
      // PAS de keepalive TCP sur la socket du bastion: un pare-feu strict jette
      // ses sondes et tuait le relais en ~15 s (voir uSshTransport.Execute).
      if Terminated then Exit;
      if not Handshake then Exit;
      if not VerifyHostKey then Exit;
      if not Authenticate then Exit;
      if not OpenLocalListener then Exit;
      FReady := True;
      FReadyEvent.SetEvent;
      ForwardLoop;
    except
      on E: Exception do
      begin
        SetError('Tunnel: ' + E.Message);
        FReady := False;
      end;
    end;
  finally
    FReadyEvent.SetEvent;   // toujours: sinon l'appelant attend pour toujours
    Cleanup;
  end;
end;

end.
