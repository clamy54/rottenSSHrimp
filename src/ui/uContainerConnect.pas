unit uContainerConnect;

{$mode objfpc}{$H+}

// Conteneur = session SSH du PARENT + commande forcee; tout le reste vient du parent.
// SECURITE: nom valide a la saisie ET quote en simple; 'exec', jamais de shell de login.

interface

uses
  ComCtrls, uRshDocument, uRshModel, uSessionManager, uSshSessionTab,
  uSessionTabBase;

// nil avec AErr vide = annulation (cle d'hote du parent refusee...)
function StartContainerSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;

implementation

uses
  SysUtils, uSshTransport, uSshConnect, uSshTunnel, uSshTunnelConnect,
  uContainerCmd;

function StartContainerSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;
var
  cfg: TContainerConfig;
  params: TSshConnectParams;
  node: TRshNode;
  tab: TSshSessionTab;
  parentDisplay, displayName, jumpUuid, hostLabel: string;
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
  if not AModel.GetContainerConfig(AConnUuid, cfg) then
  begin
    AErr := 'This container is misconfigured (no host to connect via).';
    Exit;
  end;
  node := AModel.GetNode(AConnUuid);
  try
    displayName := node.DisplayName;
  finally
    node.Free;
  end;
  // cle d'hote verifiee contre le PARENT (params.Host)
  if not BuildSshConnectParams(ADoc, AModel, cfg.ParentUuid, params,
    parentDisplay, AErr) then
    Exit;
  try
    params.ExecCommand := BuildContainerCommand(cfg.Engine, cfg.ContainerName,
      cfg.Shell);
    params.RequestPty := cfg.Shell <> csLog;   // log = flux sans PTY

    // rebond du PARENT, le conteneur n'en ajoute aucun
    jumpUuid := AModel.ResolveJumpVia(cfg.ParentUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid,
        params.Host, params.Port, tun, broker, localPort, AErr) then
        Exit;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
      if Assigned(ANotice) then
        ANotice(Format('%s: via the SSH jump host.', [displayName]));
    end;

    tab := TSshSessionTab.CreateSession(APages, ADoc, AManager,
      displayName, AConnUuid, params);
    params := nil;   // possede par l'onglet
    tab.AttachTunnel(tun, broker);
    tun := nil;
    broker := nil;
    tab.SetCaptionSuffix('Container');
    // l'onglet survit a la fin du flux: les dernieres lignes d'un conteneur
    // qui meurt sont les seules qu'on veut lire
    tab.SetLogMode(cfg.Shell = csLog);
    hostLabel := parentDisplay;
    tab.AddExitMessage(CONTAINER_EXIT_NO_ENGINE, Format(
      'Engine "%s" not found on %s.',
      [CONTAINER_ENGINE_NAMES[cfg.Engine], hostLabel]));
    tab.AddExitMessage(CONTAINER_EXIT_NO_CONTAINER, Format(
      'Container "%s" not found on %s.', [cfg.ContainerName, hostLabel]));
    if cfg.Shell <> csLog then
      tab.AddExitMessage(CONTAINER_EXIT_NO_SHELL, Format(
        'Shell %s is not available in container "%s".',
        [CONTAINER_SHELL_PATHS[cfg.Shell], cfg.ContainerName]));
    tab.OnNotice := ANotice;
    APages.ActivePage := tab;
    tab.Start;
    Result := tab;
  finally
    params.Free;
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
