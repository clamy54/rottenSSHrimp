unit uContainerConnect;

{$mode objfpc}{$H+}

// Un conteneur n'est pas un protocole reseau: c'est la session SSH du noeud
// PARENT plus une commande forcee (docker/podman exec ou logs). Tout vient du
// parent -- identifiants ET rebond unique -- on n'injecte que la commande.
//
// SECURITE: le nom du conteneur est valide a la saisie ET quote en simple, donc
// sans metacaractere shell; la commande passe par 'exec', jamais par un shell
// de login.

interface

uses
  ComCtrls, uRshDocument, uRshModel, uSessionManager, uSshSessionTab,
  uSessionTabBase;

// nil avec AErr vide = annulation utilisateur (cle d'hote du parent refusee...)
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
  // la cle d'hote sera verifiee contre l'hote du PARENT (params.Host)
  if not BuildSshConnectParams(ADoc, AModel, cfg.ParentUuid, params,
    parentDisplay, AErr) then
    Exit;
  try
    params.ExecCommand := BuildContainerCommand(cfg.Engine, cfg.ContainerName,
      cfg.Shell);
    params.RequestPty := cfg.Shell <> csLog;   // log = flux sans PTY

    // rebond du PARENT: un seul saut, le conteneur n'en ajoute aucun
    jumpUuid := AModel.GetJumpVia(cfg.ParentUuid);
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
    // log = lecture seule stricte, et l'onglet survit a la fin du flux: les
    // derniers journaux d'un conteneur qui meurt sont ceux qui interessent
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
    params.Free;   // nil si l'onglet l'a prise
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
