unit uRdpConnect;

{$mode objfpc}{$H+}

// Lancement d'une session RDP depuis un noeud du document. Modele et secrets se
// touchent ici, sur le thread UI; le thread reseau ne recoit qu'un instantane.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Dialogs, Forms,
  uRshDocument, uRshModel, uSessionManager, uSessionTabBase, uRdpSessionTab,
  uRdpTransport;

function StartRdpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TRdpSessionTab;

implementation

uses
  uSecureBytes, uRshValidation, uAuthPrompt, uSshTunnel, uSshTunnelConnect
  {$IFDEF DARWIN}, uMacKbdLayout{$ENDIF};

function StartRdpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TRdpSessionTab;
var
  node: TRshNode;
  cred: TRshCredential;
  credUuid, host, vErr, askUser, askDomain, srcFolder, jumpUuid: string;
  params: TRdpConnectParams;
  tab: TRdpSessionTab;
  secret: TSecureBytes;
  gw: TRshRdpGateway;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  localPort: Integer;
begin
  Result := nil;
  AErr := '';
  node := nil;
  cred := nil;
  params := nil;
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
    if node.Protocol <> rpRdp then
    begin
      AErr := 'This connection is not an RDP connection.';
      Exit;
    end;

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

    params := TRdpConnectParams.Create;
    params.Host := host;
    params.Port := node.Port;
    {$IFDEF DARWIN}
    // Lue ICI: Text Input Services refuse l'appel hors thread UI (crash en live).
    params.KeyboardKlid := MacKeyboardKlid;
    {$ENDIF}

    gw := AModel.GetRdpGateway(AConnUuid);
    if gw.Hostname <> '' then
    begin
      if not ValidateHostname(gw.Hostname, vErr) then
      begin
        AErr := 'Invalid gateway: ' + vErr;
        Exit;
      end;
      params.GatewayHostname := gw.Hostname;
      // gateway_port n'a pas de CHECK SQL: 0 = non configure, hors plage = refus.
      if (gw.Port < 0) or (gw.Port > 65535) then
      begin
        AErr := 'Invalid gateway: port out of range (1..65535).';
        Exit;
      end;
      if gw.Port > 0 then
        params.GatewayPort := gw.Port;
    end;

    if node.InheritCredential then
      credUuid := AModel.ResolveFolderCredential(node.ParentUuid,
        node.Protocol, srcFolder)
    else
      credUuid := node.CredentialUuid;
    if credUuid = '' then
    begin
      askUser := '';
      askDomain := '';
      if not AskLogin('Connect to ' + node.DisplayName,
        Format('Sign in to %s:%d', [host, node.Port]), True,
        askUser, askDomain, secret) then
      begin
        AErr := '';
        Exit;
      end;
      params.Username := askUser;
      params.DomainName := askDomain;
      params.Password := secret;
    end
    else
    begin
      cred := AModel.GetCredential(credUuid);
      if cred.AuthType in [atSshKey, atSshAgent, atManagedKey] then
      begin
        AErr := 'This credential is an SSH key: RDP cannot use it. ' +
          'Pick a credential with a username and a password.';
        Exit;
      end;
      params.Username := cred.Username;
      params.DomainName := cred.DomainName;
      if cred.HasPassword then
      begin
        if not AModel.GetSecret(credUuid, FIELD_CRED_PASSWORD,
           params.Password) then
        begin
          AErr := 'Cannot read the password for this credential.';
          Exit;
        end;
      end
      else
      begin
        askUser := cred.Username;
        askDomain := cred.DomainName;
        if not AskLogin('Connect to ' + node.DisplayName,
          Format('Sign in to %s:%d', [host, node.Port]), True,
          askUser, askDomain, secret) then
        begin
          AErr := '';
          Exit;
        end;
        params.Username := askUser;
        params.DomainName := askDomain;
        params.Password := secret;
      end;
    end;

    if params.Username = '' then
    begin
      AErr := 'No username for this connection.';
      Exit;
    end;

    jumpUuid := AModel.GetJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      // Gateway ET rebond: le certificat de la passerelle serait reindexe sous
      // l'identite de la cible. On refuse plutot que d'affaiblir le TOFU.
      if params.GatewayHostname <> '' then
      begin
        AErr := 'Unsupported combination: an RDP connection cannot use ' +
          'both an RD Gateway and an SSH jump host.';
        Exit;
      end;
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid, params.Host,
        params.Port, tun, broker, localPort, AErr) then
        Exit;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
      if Assigned(ANotice) then
        ANotice(Format('%s: RDP tunneled over SSH.', [node.DisplayName]));
    end;

    tab := TRdpSessionTab.CreateSession(APages, ADoc, AManager,
      node.DisplayName, AConnUuid, params);
    params := nil;
    tab.AttachTunnel(tun, broker);
    tun := nil;
    broker := nil;
    tab.OnNotice := ANotice;
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
    params.Free;
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
