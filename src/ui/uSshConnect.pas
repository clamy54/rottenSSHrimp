unit uSshConnect;

{$mode objfpc}{$H+}

// Lancement d'une session SSH depuis un noeud. Modele et secrets restent sur le
// thread UI; le reseau ne recoit qu'un TSshConnectParams dont il est proprietaire.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Dialogs, Forms, StdCtrls,
  uRshDocument, uRshModel, uSessionManager, uSessionTabBase, uSshSessionTab,
  uSshTransport;

function StartSshSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;

// L'appelant possede AParams. False + AErr vide = annulation utilisateur.
function BuildSshConnectParams(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AParams: TSshConnectParams;
  out ADisplayName: string; out AErr: string): Boolean;

// A GARDER SYNCHRONISE avec les invites de BuildSshConnectParams.
function SshConnectWouldPrompt(AModel: TRshModel;
  const AConnUuid: string): Boolean;

// True si la connexion s'authentifie par cle de securite FIDO2: un geste par
// session, a annoncer avant d'en lancer plusieurs (Broadcast).
function SshConnectUsesFido(AModel: TRshModel;
  const AConnUuid: string): Boolean;

implementation

uses
  uSecureBytes, uRshValidation, uSshKnownHosts, uTheme, uAuthPrompt,
  uSshTunnel, uSshTunnelConnect, uLibssh2Api, uSshFido;

// Identifiant RESOLU d'une connexion (heritage compris), nil si aucun ou si
// quelque chose cloche -- les deux appelants traitent nil comme « dans le
// doute ».
function ResolvedConnCredential(AModel: TRshModel;
  const AConnUuid: string): TRshCredential;
var
  node: TRshNode;
  credUuid, srcFolder: string;
begin
  Result := nil;
  if AModel = nil then Exit;
  try
    node := AModel.GetNode(AConnUuid);
  except
    on Exception do Exit;
  end;
  try
    try
      if node.Kind <> nkConnection then Exit;
      if node.InheritCredential then
        credUuid := AModel.ResolveFolderCredential(node.ParentUuid,
          node.Protocol, srcFolder)
      else
        credUuid := node.CredentialUuid;
    except
      on Exception do Exit;
    end;
  finally
    node.Free;
  end;
  if credUuid = '' then Exit;
  try
    Result := AModel.GetCredential(credUuid);
  except
    on Exception do Result := nil;
  end;
end;

function SshConnectWouldPrompt(AModel: TRshModel;
  const AConnUuid: string): Boolean;
var
  cred: TRshCredential;
begin
  // Dans le doute, « ca demanderait ».
  Result := True;
  cred := ResolvedConnCredential(AModel, AConnUuid);
  if cred = nil then Exit;
  try
    // atFidoKey: pas de modale AVANT la grille, le geste vient pendant la
    // session (avis non modal) -- ne compte donc pas comme une invite.
    Result := (cred.AuthType = atPrompt) or
      ((cred.AuthType = atPassword) and (not cred.HasPassword));
  finally
    cred.Free;
  end;
end;

function SshConnectUsesFido(AModel: TRshModel;
  const AConnUuid: string): Boolean;
var
  cred: TRshCredential;
begin
  Result := False;
  cred := ResolvedConnCredential(AModel, AConnUuid);
  if cred = nil then Exit;
  try
    Result := cred.AuthType = atFidoKey;
  finally
    cred.Free;
  end;
end;

function BuildSshConnectParams(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AParams: TSshConnectParams;
  out ADisplayName: string; out AErr: string): Boolean;
var
  node: TRshNode;
  cred: TRshCredential;
  credUuid, askUser, askDomain, srcFolder: string;
  params: TSshConnectParams;
  kh: TSshKnownHosts;
  host: string;
  vErr: string;
  secret: TSecureBytes;
begin
  Result := False;
  AParams := nil;
  ADisplayName := '';
  AErr := '';
  node := nil;
  cred := nil;
  params := nil;

  try try
    node := AModel.GetNode(AConnUuid);
    ADisplayName := node.DisplayName;
    if node.Kind <> nkConnection then
    begin
      AErr := 'This node is not a connection.';
      Exit;
    end;
    if node.Protocol <> rpSsh then
    begin
      AErr := 'This connection is not an SSH connection.';
      Exit;
    end;

    // document = entree non fiable: revalider avant la socket
    host := node.Hostname;
    if not ValidateHostname(host, vErr) then
    begin
      AErr := 'Invalid hostname: ' + vErr;
      Exit;
    end;
    if not ValidatePort(node.Port, vErr) then
    begin
      AErr := 'Invalid port: ' + vErr;
      Exit;
    end;

    // resolution vide = demande interactive plus bas
    if node.InheritCredential then
      credUuid := AModel.ResolveFolderCredential(node.ParentUuid,
        node.Protocol, srcFolder)
    else
      credUuid := node.CredentialUuid;

    params := TSshConnectParams.Create;
    params.Host := host;
    params.Port := node.Port;
    if node.ConnectTimeoutS > 0 then
      params.ConnectTimeoutS := node.ConnectTimeoutS;
    // keepalive en bande (want_reply=1): un pare-feu strict jette les sondes TCP
    AModel.GetSshKeepalive(AConnUuid, params.KeepaliveS,
      params.KeepaliveMaxFailures);

    // negociation bornee aux types connus: sinon le serveur esquive la detection
    kh := TSshKnownHosts.Create(ADoc);
    try
      params.KnownKeyTypes := kh.KnownKeyTypes(host, node.Port);
    finally
      kh.Free;
    end;

    if credUuid = '' then
    begin
      askUser := '';
      askDomain := '';
      if not AskLogin('Connect to ' + node.DisplayName,
        Format('Sign in to %s:%d', [host, node.Port]), False,
        askUser, askDomain, secret) then
      begin
        AErr := '';
        Exit;
      end;
      params.Username := askUser;
      params.AuthKind := sakPassword;
      params.Password := secret;
      AParams := params;
      params := nil;
      Exit(True);
    end;

    cred := AModel.GetCredential(credUuid);
    params.Username := cred.Username;

    // une seule methode, celle du credential: pas d'essai des autres
    case cred.AuthType of
      atPassword:
        begin
          params.AuthKind := sakPassword;
          if not cred.HasPassword then
          begin
            if not AskSecret(Format('Password for %s@%s:',
              [cred.Username, host]), secret) then
            begin
              AErr := '';
              Exit;
            end;
            params.Password := secret;
          end
          else if not AModel.GetSecret(credUuid, FIELD_CRED_PASSWORD,
                   params.Password) then
          begin
            AErr := 'Cannot read the password for this credential.';
            Exit;
          end;
        end;
      atSshKey:
        begin
          params.AuthKind := sakKey;
          if not cred.HasPrivateKey then
          begin
            AErr := 'No private key in this credential.';
            Exit;
          end;
          if not AModel.GetSecret(credUuid, FIELD_CRED_PRIVATE_KEY,
             params.PrivateKey) then
          begin
            AErr := 'Cannot read the private key for this credential.';
            Exit;
          end;
          if cred.HasKeyPassphrase then
            AModel.GetSecret(credUuid, FIELD_CRED_KEY_PASSPHRASE,
              params.Passphrase);
        end;
      atSshAgent:
        params.AuthKind := sakAgent;
      atManagedKey:
        begin
          // le PEM part en memoire vers libssh2, jamais sur disque
          params.AuthKind := sakKey;
          if not cred.HasPrivateKey then
          begin
            AErr := 'No key pair has been generated for this credential yet.' +
              ' Open the Credential Manager and save it once to generate one.';
            Exit;
          end;
          if not AModel.GetSecret(credUuid, FIELD_CRED_PRIVATE_KEY,
             params.PrivateKey) then
          begin
            AErr := 'Cannot read the private key for this credential.';
            Exit;
          end;
        end;
      atFidoKey:
        begin
          // Le « PEM » d'une cle de securite ne porte pas de secret: c'est le
          // key handle qui designe la cle restee dans le token.
          params.AuthKind := sakFidoKey;
          if not cred.HasPrivateKey then
          begin
            AErr := 'No security key has been enrolled for this credential ' +
              'yet. Open the Credential Manager and save it once to enrol one.';
            Exit;
          end;
          // Les deux bibliotheques sont chargees ICI, sur le thread UI: un
          // echec doit sortir en message clair, pas en session qui meurt.
          try
            Libssh2EnsureLoaded;
          except
            on E: Exception do
            begin
              AErr := 'libssh2 is not available: ' + E.Message;
              Exit;
            end;
          end;
          if not Libssh2HasSkAuth then
          begin
            AErr := 'This libssh2 build cannot use FIDO2 security keys ' +
              '(libssh2_userauth_publickey_sk is missing). It needs libssh2 ' +
              '1.11 or newer built against OpenSSL.';
            Exit;
          end;
          if not FidoAvailable then
          begin
            AErr := FidoUnavailableMessage;
            Exit;
          end;
          if not AModel.GetSecret(credUuid, FIELD_CRED_PRIVATE_KEY,
             params.PrivateKey) then
          begin
            AErr := 'Cannot read the security key handle for this credential.';
            Exit;
          end;
        end;
      atPrompt:
        begin
          params.AuthKind := sakPassword;
          if not AskSecret(Format('Password for %s@%s:',
            [cred.Username, host]), secret) then
          begin
            AErr := '';
            Exit;
          end;
          params.Password := secret;
        end;
    end;

    if params.Username = '' then
    begin
      AErr := 'This credential carries no username.';
      Exit;
    end;

    AParams := params;
    params := nil;   // possede par l'appelant desormais
    Result := True;
  except
    on E: Exception do
      AErr := E.Message;
  end;
  finally
    node.Free;
    cred.Free;
    params.Free;
  end;
end;

function StartSshSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;
var
  params: TSshConnectParams;
  tab: TSshSessionTab;
  displayName, jumpUuid: string;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  localPort: Integer;
begin
  Result := nil;
  tun := nil;
  broker := nil;
  if not AManager.CanOpen then
  begin
    AErr := Format('Limit of %d concurrent sessions reached.',
      [AManager.MaxSessions]);
    Exit;
  end;
  if not BuildSshConnectParams(ADoc, AModel, AConnUuid, params,
    displayName, AErr) then
    Exit;
  try
    // seule la SOCKET bouge, la cle d'hote reste celle de la cible
    jumpUuid := AModel.GetJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid,
        params.Host, params.Port, tun, broker, localPort, AErr) then
        // pas de Free ici: le finally libere params ET le tunnel
        Exit;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
      if Assigned(ANotice) then
        ANotice(Format('%s: via the SSH jump host.', [displayName]));
    end;
    tab := TSshSessionTab.CreateSession(APages, ADoc, AManager,
      displayName, AConnUuid, params);
    params := nil;   // possede par l'onglet desormais
    tab.AttachTunnel(tun, broker);
    tun := nil;
    broker := nil;
    tab.OnNotice := ANotice;
    APages.ActivePage := tab;
    tab.Start;
    Result := tab;
  finally
    params.Free;   // nil si l'onglet l'a prise
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
