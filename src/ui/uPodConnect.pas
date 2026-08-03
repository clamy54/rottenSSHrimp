unit uPodConnect;

{$mode objfpc}{$H+}

// Comme un conteneur: un pod n'est pas un protocole reseau, c'est la session
// SSH du noeud PARENT plus une commande forcee (kubectl exec ou logs). Tout
// vient du parent -- identifiants ET rebond unique.
//
// SECURITE: namespace, pod et container sont valides a la saisie (RFC 1123) ET
// quotes en simple dans uPodCmd, donc sans metacaractere shell; la commande
// passe par 'exec', jamais par un shell de login.

interface

uses
  ComCtrls, uRshDocument, uRshModel, uSessionManager, uSshSessionTab,
  uSessionTabBase;

// nil avec AErr vide = annulation utilisateur (cle d'hote du parent refusee...)
function StartPodSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;

implementation

uses
  SysUtils, uSshTransport, uSshConnect, uSshTunnel, uSshTunnelConnect,
  uPodCmd;

function PodLabel(const ACfg: TPodConfig): string;
begin
  if ACfg.Namespace <> '' then
    Result := ACfg.Namespace + '/' + ACfg.PodName
  else
    Result := ACfg.PodName;
end;

function StartPodSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TSshSessionTab;
var
  cfg: TPodConfig;
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
  if not AModel.GetPodConfig(AConnUuid, cfg) then
  begin
    AErr := 'This pod is misconfigured (no host to connect via).';
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
    params.ExecCommand := BuildPodCommand(cfg.Namespace, cfg.PodName,
      cfg.ContainerName, cfg.Shell);
    params.RequestPty := cfg.Shell <> csLog;   // log = flux sans PTY

    // rebond du PARENT: un seul saut, le pod n'en ajoute aucun
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
    tab.SetCaptionSuffix('Pod');
    // log = lecture seule stricte, et l'onglet survit a la fin du flux: les
    // derniers journaux d'un pod qui meurt sont ceux qui interessent
    tab.SetLogMode(cfg.Shell = csLog);
    hostLabel := parentDisplay;
    tab.AddExitMessage(POD_EXIT_NO_KUBECTL, Format(
      'kubectl was not found on %s.', [hostLabel]));
    tab.AddExitMessage(POD_EXIT_NO_POD, Format(
      'Pod "%s" was not found (namespace or cluster unreachable) on %s.',
      [PodLabel(cfg), hostLabel]));
    if cfg.Shell <> csLog then
      tab.AddExitMessage(POD_EXIT_NO_CONTAINER, Format(
        'Cannot open a shell in pod "%s": container or shell %s unavailable.',
        [PodLabel(cfg), CONTAINER_SHELL_PATHS[cfg.Shell]]));
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
