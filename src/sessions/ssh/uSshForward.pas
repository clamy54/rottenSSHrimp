unit uSshForward;

{$mode objfpc}{$H+}

// Tunnels locaux (ssh -L) portes par la session du TERMINAL: pas de seconde
// connexion ni de seconde authentification. Tout tourne dans le thread de la
// session, pompe a chaque tour de sa boucle: une session libssh2 ne se
// partage pas entre threads.
//
// Trois contraintes de libssh2 (1.11) dictent la forme, verifiees dans ses
// sources et pas theoriques:
// - UNE seule ouverture de canal a la fois par session: l'etat de l'ouverture
//   est porte par la SESSION. Un second appel reprendrait le premier et
//   rendrait son canal a la mauvaise connexion. Les connexions acceptees font
//   donc la queue, et une ouverture commencee va TOUJOURS a son terme. PIEGE:
//   une destination filtree (paquets jetes, pas de refus) retient ainsi les
//   ouvertures de TOUS les tunnels jusqu'a ce que libssh2 renonce (son delai
//   de lecture, 60 s) ou que le serveur reponde. Le terminal, lui, continue.
// - Un envoi qui a rendu EAGAIN doit etre rejoue a l'identique avant tout
//   autre envoi; les autres recoivent EAGAIN en attendant. On ne quitte
//   jamais un canal avec un envoi en suspens: on le vide d'abord, sinon la
//   session entiere (terminal compris) resterait bloquee.
// - channel_send_eof construit son paquet sur la PILE: deux canaux qui s'y
//   relaieraient au meme endroit seraient confondus. EOF et fermeture passent
//   donc un par un (jeton FSerialOwner).
//
// Ecoute sur la boucle locale SEULEMENT (127.0.0.1 et ::1): jamais sur une
// interface reseau, sinon n'importe quelle machine du voisinage entrerait
// dans le reseau du serveur par ce poste.

interface

uses
  SysUtils, ctypes, Sockets, uSockCompat, uLibssh2Api;

type
  TSshForwardSpec = record
    LocalPort: Integer;
    DestHost: string;
    DestPort: Integer;
  end;

  TSshForwardSpecs = array of TSshForwardSpec;

  TSshForwardFail = (sffNone, sffInUse, sffDenied, sffOther);

  TSshForwardStatus = record
    Spec: TSshForwardSpec;
    Fail: TSshForwardFail;
    Detail: string;
  end;

  TSshForwardReport = array of TSshForwardStatus;

  // Probleme APRES la mise en place (serveur qui refuse, destination muette).
  // Appelee depuis le thread de session, au plus une fois par tunnel: cinq
  // connexions refusees ne font pas cinq messages.
  TSshForwardProblem = procedure(AIndex: Integer;
    const AMessage: string) of object;

  TFwdState = (fsQueued, fsOpening, fsOpen, fsClosing, fsDead);

  TFwdConn = class
  public
    Listener: Integer;
    Sock: cint;
    Channel: PLIBSSH2_CHANNEL;
    State: TFwdState;
    Since: QWord;
    ToChan: RawByteString;
    ToLocal: RawByteString;
    LocalEof: Boolean;
    EofSent: Boolean;
    RemoteEof: Boolean;
    WriteShut: Boolean;
    Broken: Boolean;
  end;

  TFwdListener = record
    Spec: TSshForwardSpec;
    HostA: AnsiString;   // vit aussi longtemps que l'ouverture qui le lit
    Socks: array[0..1] of cint;
    Reported: Boolean;
  end;

  TSshLocalForwarder = class
  private
    FSession: PLIBSSH2_SESSION;
    FOpenTimeoutS: Integer;
    FListeners: array of TFwdListener;
    FConns: array of TFwdConn;
    FOpening: TFwdConn;
    FSerialOwner: TFwdConn;
    FOnProblem: TSshForwardProblem;
    FBuf: array[0..32767] of Byte;

    function OpenListener(AIndex: Integer; out AFail: TSshForwardFail;
      out ADetail: string): Boolean;
    procedure Problem(AListener: Integer; const AMessage: string);
    function LastError: string;
    procedure CloseLocal(AConn: TFwdConn);
    function AcceptNew: Boolean;
    function AdvanceOpen: Boolean;
    function PumpConn(AConn: TFwdConn; var AFromServer: Boolean): Boolean;
    function AdvanceClose(AConn: TFwdConn): Boolean;
    procedure Reap;
  public
    constructor Create(ASession: PLIBSSH2_SESSION;
      const ASpecs: TSshForwardSpecs; AOpenTimeoutS: Integer);
    destructor Destroy; override;

    // Ouvre les ecoutes. Rend l'etat de CHAQUE tunnel, dans l'ordre recu.
    function Listen: TSshForwardReport;
    // Un tour, sans jamais bloquer. True = quelque chose a bouge.
    // AFromServer: des octets sont arrives du serveur (preuve de vie).
    function Pump(out AFromServer: Boolean): Boolean;
    // Sockets a surveiller en plus de celle de la session.
    procedure AddWaitFds(var ARead, AWrite: TSockSet; var AMaxFd: cint);
    // Ferme ecoutes et connexions locales. Les canaux partent avec la session:
    // les liberer apres elle viserait de la memoire rendue.
    procedure CloseAll;
    function ListeningCount: Integer;

    property OnProblem: TSshForwardProblem read FOnProblem write FOnProblem;
  end;

// Texte d'un echec de mise en place, pour le message a l'utilisateur.
function ForwardFailText(const AStatus: TSshForwardStatus): string;

implementation

const
  // Un select Windows surveille 64 sockets au plus: 1 (session) + 32 ecoutes
  // (16 tunnels, IPv4 et IPv6) + 28 connexions = 61. Au-dela, les clients
  // attendent dans la file d'ecoute qu'une connexion se libere.
  MAX_FWD_CONNS = 28;
  MAX_FWD_LISTENERS = 16;
  LISTEN_BACKLOG = 16;
  // Au-dela, on renonce a liberer un canal: la socket de la session n'ecrit
  // plus depuis ce temps, la session est morte et le keepalive le dira.
  CLOSE_GIVEUP_MS = 10000;
  {$IFDEF WINDOWS}
  SO_EXCLUSIVEADDRUSE = cint(not cint(SO_REUSEADDR));
  {$ENDIF}
  SHUT_WR_ = 1;   // SD_SEND sous Windows, SHUT_WR ailleurs: meme valeur

function ForwardFailText(const AStatus: TSshForwardStatus): string;
begin
  case AStatus.Fail of
    sffInUse:
      Result := 'local port already in use';
    sffDenied:
      {$IFDEF WINDOWS}
      Result := 'local port refused by Windows (reserved range or blocked)';
      {$ELSE}
      Result := 'local port refused by the system';
      {$ENDIF}
  else
    Result := AStatus.Detail;
    if Result = '' then
      Result := 'cannot listen on the local port';
  end;
end;

{ TSshLocalForwarder }

constructor TSshLocalForwarder.Create(ASession: PLIBSSH2_SESSION;
  const ASpecs: TSshForwardSpecs; AOpenTimeoutS: Integer);
var
  i, n: Integer;
begin
  inherited Create;
  FSession := ASession;
  FOpenTimeoutS := AOpenTimeoutS;
  if FOpenTimeoutS <= 0 then
    FOpenTimeoutS := 15;
  // le modele borne deja; on rebornerait sans lui, le select en depend
  n := Length(ASpecs);
  if n > MAX_FWD_LISTENERS then
    n := MAX_FWD_LISTENERS;
  SetLength(FListeners, n);
  for i := 0 to n - 1 do
  begin
    FListeners[i].Spec := ASpecs[i];
    FListeners[i].HostA := AnsiString(ASpecs[i].DestHost);
    FListeners[i].Socks[0] := -1;
    FListeners[i].Socks[1] := -1;
    FListeners[i].Reported := False;
  end;
end;

destructor TSshLocalForwarder.Destroy;
begin
  CloseAll;
  inherited Destroy;
end;

procedure TSshLocalForwarder.CloseAll;
var
  i, k: Integer;
begin
  for i := 0 to High(FListeners) do
    for k := 0 to 1 do
      if FListeners[i].Socks[k] >= 0 then
      begin
        CloseSocket(FListeners[i].Socks[k]);
        FListeners[i].Socks[k] := -1;
      end;
  for i := 0 to High(FConns) do
  begin
    CloseLocal(FConns[i]);
    FConns[i].Free;
  end;
  FConns := nil;
  FOpening := nil;
  FSerialOwner := nil;
end;

function TSshLocalForwarder.ListeningCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FListeners) do
    if FListeners[i].Socks[0] >= 0 then
      Inc(Result);
end;

function TSshLocalForwarder.OpenListener(AIndex: Integer;
  out AFail: TSshForwardFail; out ADetail: string): Boolean;
var
  s4, s6: cint;
  a4: TInetSockAddr;
  a6: TInetSockAddr6;
  yes, err: cint;

  procedure Classify(ACode: cint; const AStep: string);
  begin
    if SockErrIsAddrInUse(ACode) then
      AFail := sffInUse
    else if SockErrIsAccess(ACode) then
      AFail := sffDenied
    else
    begin
      AFail := sffOther;
      ADetail := Format('cannot listen on the local port (%s, error %d)',
        [AStep, ACode]);
    end;
  end;

  procedure Prepare(AFd: cint);
  begin
    yes := 1;
    {$IFDEF WINDOWS}
    // Sous Windows, SO_REUSEADDR laisserait un AUTRE processus se lier au
    // meme port et detourner les connexions -- semantique inverse d'Unix.
    fpSetSockOpt(AFd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, @yes, SizeOf(yes));
    {$ELSE}
    fpSetSockOpt(AFd, SOL_SOCKET, SO_REUSEADDR, @yes, SizeOf(yes));
    {$ENDIF}
  end;

begin
  Result := False;
  AFail := sffNone;
  ADetail := '';

  s4 := fpSocket(AF_INET, SOCK_STREAM, 0);
  if s4 < 0 then
  begin
    Classify(SockLastError, 'socket');
    Exit;
  end;
  Prepare(s4);
  FillChar(a4, SizeOf(a4), 0);
  a4.sin_family := AF_INET;
  a4.sin_port := htons(FListeners[AIndex].Spec.LocalPort);
  a4.sin_addr.s_addr := htonl($7F000001);
  if (fpBind(s4, @a4, SizeOf(a4)) <> 0) or
     (fpListen(s4, LISTEN_BACKLOG) <> 0) then
  begin
    Classify(SockLastError, 'bind');
    CloseSocket(s4);
    Exit;
  end;
  SockSetNonBlocking(s4, True);

  // ::1 aussi: « localhost » y mene d'abord sous Windows et macOS. Sans
  // IPv6 sur le poste, on s'en passe; mais un ::1 DEJA PRIS enverrait les
  // clients de « localhost » vers un autre programme: c'est un echec.
  s6 := fpSocket(AF_INET6, SOCK_STREAM, 0);
  if s6 >= 0 then
  begin
    Prepare(s6);
    FillChar(a6, SizeOf(a6), 0);
    a6.sin6_family := AF_INET6;
    a6.sin6_port := htons(FListeners[AIndex].Spec.LocalPort);
    a6.sin6_addr.u6_addr8[15] := 1;
    if (fpBind(s6, @a6, SizeOf(a6)) <> 0) or
       (fpListen(s6, LISTEN_BACKLOG) <> 0) then
    begin
      err := SockLastError;
      CloseSocket(s6);
      s6 := -1;
      if SockErrIsAddrInUse(err) then
      begin
        AFail := sffInUse;
        CloseSocket(s4);
        Exit;
      end;
    end
    else
      SockSetNonBlocking(s6, True);
  end;

  FListeners[AIndex].Socks[0] := s4;
  FListeners[AIndex].Socks[1] := s6;
  Result := True;
end;

function TSshLocalForwarder.Listen: TSshForwardReport;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FListeners));
  for i := 0 to High(FListeners) do
  begin
    Result[i].Spec := FListeners[i].Spec;
    OpenListener(i, Result[i].Fail, Result[i].Detail);
  end;
end;

procedure TSshLocalForwarder.Problem(AListener: Integer;
  const AMessage: string);
begin
  if (AListener < 0) or (AListener > High(FListeners)) then Exit;
  if FListeners[AListener].Reported then Exit;
  FListeners[AListener].Reported := True;
  if Assigned(FOnProblem) then
    FOnProblem(AListener, AMessage);
end;

function TSshLocalForwarder.LastError: string;
var
  msg: PAnsiChar;
  len: cint;
begin
  msg := nil;
  len := 0;
  libssh2_session_last_error(FSession, @msg, @len, 0);
  if (msg <> nil) and (len > 0) then
    Result := string(AnsiString(msg))
  else
    Result := '';
end;

procedure TSshLocalForwarder.CloseLocal(AConn: TFwdConn);
begin
  if AConn.Sock >= 0 then
  begin
    CloseSocket(AConn.Sock);
    AConn.Sock := -1;
  end;
  // plus personne a qui livrer
  AConn.ToLocal := '';
end;

function TSshLocalForwarder.AcceptNew: Boolean;
var
  i, k, n: Integer;
  s: cint;
  c: TFwdConn;
begin
  Result := False;
  for i := 0 to High(FListeners) do
    for k := 0 to 1 do
    begin
      if FListeners[i].Socks[k] < 0 then Continue;
      while Length(FConns) < MAX_FWD_CONNS do
      begin
        s := fpAccept(FListeners[i].Socks[k], nil, nil);
        if s < 0 then Break;
        if not SockFitsInSet(s) then
        begin
          CloseSocket(s);
          Continue;
        end;
        SockSetNonBlocking(s, True);
        // meme raison que le tunnel de rebond: de petits echanges
        // interactifs, que Nagle retiendrait jusqu'a 200 ms
        SockSetNoDelay(s);
        c := TFwdConn.Create;
        c.Listener := i;
        c.Sock := s;
        c.Channel := nil;
        c.State := fsQueued;
        c.Since := GetTickCount64;
        n := Length(FConns);
        SetLength(FConns, n + 1);
        FConns[n] := c;
        Result := True;
      end;
    end;
end;

function TSshLocalForwarder.AdvanceOpen: Boolean;
var
  i: Integer;
  c: TFwdConn;
  l: ^TFwdListener;
  ch: PLIBSSH2_CHANNEL;
  why: string;
begin
  Result := False;
  if FOpening = nil then
    for i := 0 to High(FConns) do
      if FConns[i].State = fsQueued then
      begin
        FOpening := FConns[i];
        FOpening.State := fsOpening;
        FOpening.Since := GetTickCount64;
        Break;
      end;
  if FOpening = nil then Exit;

  c := FOpening;
  l := @FListeners[c.Listener];
  // Trop long: on ne peut PAS lacher l'ouverture (etat de session), mais le
  // client n'a pas a attendre le delai du noyau d'en face (~2 min). On le
  // libere, et le canal, s'il vient, sera referme aussitot.
  if (c.Sock >= 0) and
     (GetTickCount64 - c.Since > QWord(FOpenTimeoutS) * 1000) then
  begin
    CloseLocal(c);
    // Dire aussi l'effet de bord: l'ouverture reste en cours dans la session,
    // les AUTRES tunnels attendent qu'elle aboutisse avant d'ouvrir les leurs.
    Problem(c.Listener, Format('no answer from %s:%d within %ds, seen from ' +
      'the SSH server (unreachable, filtered, or the name does not resolve ' +
      'there). New connections through the other tunnels of this session ' +
      'wait until the attempt gives up (up to a minute).',
      [l^.Spec.DestHost, l^.Spec.DestPort, FOpenTimeoutS]));
    Result := True;
  end;

  ch := libssh2_channel_direct_tcpip_ex(FSession, PAnsiChar(l^.HostA),
    l^.Spec.DestPort, '127.0.0.1', l^.Spec.LocalPort);
  if ch <> nil then
  begin
    FOpening := nil;
    c.Channel := ch;
    c.Since := GetTickCount64;
    if c.Sock < 0 then
      c.State := fsClosing
    else
      c.State := fsOpen;
    Exit(True);
  end;
  if libssh2_session_last_errno(FSession) = LIBSSH2_ERROR_EAGAIN then
    Exit;

  // Le code de refus du serveur passe dans le texte de libssh2: il distingue
  // « interdit » (AllowTcpForwarding no, PermitOpen) de « injoignable ».
  FOpening := nil;
  why := LastError;
  // libssh2 renonce seul au bout de son delai de lecture (60 s): la
  // destination n'a jamais repondu. Deja signale par notre propre delai si
  // le client attendait encore; sinon, le dire ici.
  if libssh2_session_last_errno(FSession) = LIBSSH2_ERROR_TIMEOUT then
    Problem(c.Listener, Format('no answer from %s:%d, seen from the SSH ' +
      'server (unreachable, filtered, or the name does not resolve there).',
      [l^.Spec.DestHost, l^.Spec.DestPort]))
  else if Pos('administratively prohibited', why) > 0 then
    Problem(c.Listener, Format('the SSH server does not allow tunnels to ' +
      '%s:%d (TCP forwarding is disabled or restricted there: ' +
      'AllowTcpForwarding, PermitOpen).',
      [l^.Spec.DestHost, l^.Spec.DestPort]))
  else if Pos('connect failed', why) > 0 then
    Problem(c.Listener, Format('the SSH server could not reach %s:%d ' +
      '(connection refused, or the name does not resolve there).',
      [l^.Spec.DestHost, l^.Spec.DestPort]))
  else
  begin
    if why <> '' then
      why := ' (' + why + ')';
    Problem(c.Listener, Format('the SSH server refused to open the tunnel ' +
      'to %s:%d%s.', [l^.Spec.DestHost, l^.Spec.DestPort, why]));
  end;
  CloseLocal(c);
  c.State := fsDead;
  Result := True;
end;

function TSshLocalForwarder.PumpConn(AConn: TFwdConn;
  var AFromServer: Boolean): Boolean;
var
  n: cssize_t;
  w: cssize_t;
  rc: cint;
begin
  Result := False;
  with AConn do
  begin
    // local -> canal. On ne lit la suite qu'une fois le morceau precedent
    // parti: c'est le meme tampon qui doit etre rejoue apres EAGAIN.
    if (ToChan = '') and (not LocalEof) and (Sock >= 0) then
    begin
      n := fpRecv(Sock, @FBuf[0], SizeOf(FBuf), 0);
      if n > 0 then
      begin
        SetLength(ToChan, n);
        Move(FBuf[0], ToChan[1], n);
        Result := True;
      end
      else if n = 0 then
      begin
        LocalEof := True;
        Result := True;
      end
      else if not SockErrIsWouldBlock(SockLastError) then
      begin
        // remise a zero cote client: ce qui a deja ete lu part quand meme
        LocalEof := True;
        CloseLocal(AConn);
        Result := True;
      end;
    end;
    if ToChan <> '' then
    begin
      w := libssh2_channel_write_ex(Channel, 0, PAnsiChar(ToChan),
        Length(ToChan));
      if w > 0 then
      begin
        Delete(ToChan, 1, w);
        Result := True;
      end
      else if (w <> LIBSSH2_ERROR_EAGAIN) and (w <> 0) then
      begin
        // canal mort: rien n'est en suspens dans la session pour lui
        ToChan := '';
        Broken := True;
      end;
    end;

    // canal -> local, meme discipline: un client lent retient le canal, et
    // la fenetre SSH retient le serveur. Rien ne grossit sans borne.
    if (not Broken) and (ToLocal = '') and (not RemoteEof) then
    begin
      n := libssh2_channel_read_ex(Channel, 0, @FBuf[0], SizeOf(FBuf));
      if n > 0 then
      begin
        if Sock >= 0 then
        begin
          SetLength(ToLocal, n);
          Move(FBuf[0], ToLocal[1], n);
        end;
        AFromServer := True;
        Result := True;
      end
      else if (n < 0) and (n <> LIBSSH2_ERROR_EAGAIN) then
        Broken := True
      else if libssh2_channel_eof(Channel) <> 0 then
      begin
        RemoteEof := True;
        Result := True;
      end;
    end;
    if (ToLocal <> '') and (Sock >= 0) then
    begin
      w := fpSend(Sock, PAnsiChar(ToLocal), Length(ToLocal), 0);
      if w > 0 then
      begin
        Delete(ToLocal, 1, w);
        Result := True;
      end
      else if (w < 0) and (not SockErrIsWouldBlock(SockLastError)) then
      begin
        LocalEof := True;
        CloseLocal(AConn);
        Result := True;
      end;
    end;

    // demi-fermetures, comme ssh -L: le serveur a fini, le client le voit;
    // le client a fini, le serveur le voit -- l'autre sens continue.
    if RemoteEof and (ToLocal = '') and (not WriteShut) and (Sock >= 0) then
    begin
      fpShutdown(Sock, SHUT_WR_);
      WriteShut := True;
    end;
    // Client parti (Sock < 0): pas d'EOF a part, la fermeture l'envoie.
    if LocalEof and (Sock >= 0) and (ToChan = '') and (not EofSent) and
       (not Broken) and ((FSerialOwner = nil) or (FSerialOwner = AConn)) then
    begin
      rc := libssh2_channel_send_eof(Channel);
      if rc = LIBSSH2_ERROR_EAGAIN then
        FSerialOwner := AConn
      else
      begin
        if FSerialOwner = AConn then
          FSerialOwner := nil;
        EofSent := True;
        Result := True;
      end;
    end;

    // Fin: canal casse, client parti, ou les deux sens termines. JAMAIS avec
    // ToChan non vide: un envoi abandonne bloquerait toute la session.
    if (ToChan = '') and (FSerialOwner <> AConn) and
       (Broken or (Sock < 0) or
        (LocalEof and EofSent and RemoteEof and (ToLocal = ''))) then
    begin
      State := fsClosing;
      Since := GetTickCount64;
      Result := True;
    end;
  end;
end;

function TSshLocalForwarder.AdvanceClose(AConn: TFwdConn): Boolean;
var
  rc: cint;
begin
  Result := False;
  CloseLocal(AConn);
  if AConn.Channel = nil then
  begin
    AConn.State := fsDead;
    Exit(True);
  end;
  if (FSerialOwner <> nil) and (FSerialOwner <> AConn) then Exit;
  rc := libssh2_channel_free(AConn.Channel);
  if rc = LIBSSH2_ERROR_EAGAIN then
  begin
    FSerialOwner := AConn;
    if GetTickCount64 - AConn.Since < CLOSE_GIVEUP_MS then Exit;
    // session sans issue: le canal partira avec elle
  end;
  if FSerialOwner = AConn then
    FSerialOwner := nil;
  AConn.Channel := nil;
  AConn.State := fsDead;
  Result := True;
end;

procedure TSshLocalForwarder.Reap;
var
  i, j: Integer;
begin
  j := 0;
  for i := 0 to High(FConns) do
    if FConns[i].State = fsDead then
    begin
      if FOpening = FConns[i] then FOpening := nil;
      if FSerialOwner = FConns[i] then FSerialOwner := nil;
      CloseLocal(FConns[i]);
      FConns[i].Free;
    end
    else
    begin
      FConns[j] := FConns[i];
      Inc(j);
    end;
  SetLength(FConns, j);
end;

function TSshLocalForwarder.Pump(out AFromServer: Boolean): Boolean;
var
  i: Integer;
begin
  AFromServer := False;
  Result := AcceptNew;
  if AdvanceOpen then
    Result := True;
  for i := 0 to High(FConns) do
    case FConns[i].State of
      fsOpen:
        if PumpConn(FConns[i], AFromServer) then
          Result := True;
      fsClosing:
        if AdvanceClose(FConns[i]) then
          Result := True;
    end;
  Reap;
end;

procedure TSshLocalForwarder.AddWaitFds(var ARead, AWrite: TSockSet;
  var AMaxFd: cint);

  procedure Add(AFd: cint; var ASet: TSockSet);
  begin
    SockSetAdd(AFd, ASet);
    if AFd > AMaxFd then
      AMaxFd := AFd;
  end;

var
  i, k: Integer;
begin
  if Length(FConns) < MAX_FWD_CONNS then
    for i := 0 to High(FListeners) do
      for k := 0 to 1 do
        if FListeners[i].Socks[k] >= 0 then
          Add(FListeners[i].Socks[k], ARead);
  for i := 0 to High(FConns) do
    with FConns[i] do
    begin
      if (Sock < 0) or (State <> fsOpen) then Continue;
      if (ToChan = '') and (not LocalEof) then
        Add(Sock, ARead);
      if ToLocal <> '' then
        Add(Sock, AWrite);
    end;
end;

end.
