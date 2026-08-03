unit uVncConnect;

{$mode objfpc}{$H+}

// Ouverture d'une session VNC. Meme forme que uSshConnect et uRdpConnect:
// revalider le document, resoudre le credential, creer l'onglet.

interface

uses
  Classes, SysUtils, ComCtrls, uRshDocument, uRshModel, uSessionManager,
  uSessionTabBase, uVncSessionTab;

function StartVncSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TVncSessionTab;

implementation

uses
  Dialogs, uSecureBytes, uRshValidation, uAuthPrompt, uVncTransport,
  uLibVncApi, uSshTunnel, uSshTunnelConnect;

function StartVncSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TVncSessionTab;
var
  node: TRshNode;
  cred: TRshCredential;
  credUuid, host, vErr, askUser, askDomain, srcFolder, jumpUuid: string;
  cfg: TVncConfig;
  tab: TVncSessionTab;
  secret: TSecureBytes;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  localPort: Integer;
  pfShared, pfViewOnly, pfClip: Boolean;
  pfCompress, pfQuality: Integer;
begin
  Result := nil;
  AErr := '';
  node := nil;
  cred := nil;
  secret := nil;

  tun := nil;
  broker := nil;
  if not AManager.CanOpen then
  begin
    AErr := Format('Limit of %d concurrent sessions reached.',
      [AManager.MaxSessions]);
    Exit;
  end;

  try try
    node := AModel.GetNode(AConnUuid);
    if node.Kind <> nkConnection then
    begin
      AErr := 'This node is not a connection.';
      Exit;
    end;
    if node.Protocol <> rpVnc then
    begin
      AErr := 'This connection is not a VNC connection.';
      Exit;
    end;

    // le document est une entree non fiable: revalider avant d'ouvrir la socket
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

    cfg := Default(TVncConfig);
    cfg.Host := host;
    cfg.Port := node.Port;
    // ClipboardTextEnabled est un reglage de SECURITE: le profil a le dernier
    // mot, aucune constante ne doit le rallumer derriere le dos de l'utilisateur
    AModel.GetVncProfile(AConnUuid, pfShared, pfViewOnly, pfClip,
      pfCompress, pfQuality);
    cfg.Shared := pfShared;
    cfg.ClipboardTextEnabled := pfClip;
    cfg.CompressLevel := pfCompress;
    cfg.QualityLevel := pfQuality;
    cfg.ViewOnly := pfViewOnly;
    cfg.ViewActualSize := AModel.GetVncActualSize(AConnUuid);
    // reconnexion auto = le transport GARDE le mot de passe pour rejouer
    // l'authentification (efface a sa destruction)
    AModel.GetVncReconnect(AConnUuid, cfg.AutoReconnect,
      cfg.MaxReconnectAttempts);

    // VNC n'a pas de nom d'utilisateur: on ne demande QUE le mot de passe.
    if node.InheritCredential then
      credUuid := AModel.ResolveFolderCredential(node.ParentUuid,
        node.Protocol, srcFolder)
    else
      credUuid := node.CredentialUuid;
    askUser := '';
    askDomain := '';
    if credUuid = '' then
    begin
      if not AskLogin('Connect to ' + node.DisplayName,
        Format('VNC password for %s:%d', [host, node.Port]), False,
        askUser, askDomain, secret, False) then
      begin
        AErr := '';
        Exit;
      end;
    end
    else
    begin
      cred := AModel.GetCredential(credUuid);
      // l'UI ne propose pas ces types pour VNC, le document si
      if cred.AuthType in [atSshKey, atSshAgent, atManagedKey] then
      begin
        AErr := 'This credential is an SSH key: VNC cannot use it. ' +
          'Pick a credential with a password.';
        Exit;
      end;
      if cred.HasPassword then
      begin
        if not AModel.GetSecret(credUuid, FIELD_CRED_PASSWORD, secret) then
        begin
          AErr := 'Cannot read the password for this credential.';
          Exit;
        end;
      end
      else
      begin
        if not AskLogin('Connect to ' + node.DisplayName,
          Format('VNC password for %s:%d', [host, node.Port]), False,
          askUser, askDomain, secret, False) then
        begin
          AErr := '';
          Exit;
        end;
      end;
    end;

    if secret = nil then
    begin
      AErr := 'No password for this VNC connection.';
      Exit;
    end;

    // charger ICI et pas dans le thread: un echec doit sortir en message clair
    try
      VncEnsureLoaded;
    except
      on E: Exception do
      begin
        AErr := 'libvncclient not available: ' + E.Message;
        Exit;
      end;
    end;

    // le tunnel SSH est la seule chose qui chiffre une session VNC: RFB, lui,
    // ne chiffre rien
    jumpUuid := AModel.GetJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid, host, node.Port,
        tun, broker, localPort, AErr) then
        Exit;   // AErr vide = annulation
      cfg.Host := '127.0.0.1';
      cfg.Port := localPort;
    end;

    tab := TVncSessionTab.CreateSession(APages, AManager,
      node.DisplayName, AConnUuid, cfg, secret);
    secret := nil;   // possede par l'onglet desormais
    tab.AttachTunnel(tun, broker);   // l'onglet possede le tunnel
    tun := nil;
    broker := nil;
    tab.OnNotice := ANotice;
    if Assigned(ANotice) then
    begin
      if jumpUuid <> '' then
        ANotice(Format('%s: VNC tunneled over SSH — encrypted up to the jump ' +
          'host; the jump host to server leg stays in cleartext unless the ' +
          'server is local to the jump host.', [node.DisplayName]))
      else
        ANotice(Format('%s: unencrypted VNC session — keystrokes, screen and' +
          ' clipboard travel in cleartext.', [node.DisplayName]));
    end;
    APages.ActivePage := tab;
    tab.Start;
    Result := tab;
  except
    on E: Exception do
      AErr := E.Message;
  end;
  finally
    node.Free;
    cred.Free;
    secret.Free;   // nil si transmis a l'onglet
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
