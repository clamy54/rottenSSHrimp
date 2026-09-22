{ Lancement d'un onglet Scp depuis un noeud, sur le modele de uSshConnect.

  Les parametres de connexion sont construits par BuildSshConnectParams, le
  MEME que pour une session terminal: credentials, heritage de dossier, mots
  de passe, agent, cles gerees, cles FIDO2, timeouts, keepalives. Il n'y a pas
  de chemin d'authentification parallele ici, et c'est voulu -- un second
  chemin serait un second endroit ou oublier une verification.

  Le rebond par bastion passe par EstablishJumpTunnel, comme SSH, RDP et VNC:
  seule la SOCKET vise 127.0.0.1, la cle d'hote verifiee reste celle de la
  cible.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpConnect;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ComCtrls,
  uRshDocument, uRshModel, uSessionManager, uSessionTabBase, uScpTab,
  uSshTransport;

// Ouvre un onglet Scp, ou ACTIVE celui qui existe deja pour cette connexion.
// AErr vide avec un resultat nil = annulation par l'utilisateur.
function StartScpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TScpTab;

// L'item `Scp` doit-il apparaitre pour ce noeud? Une seule connexion SSH,
// et rien d'autre.
function CanOpenScp(AModel: TRshModel; const AConnUuid: string): Boolean;

// Onglet Scp VIVANT pour cette connexion, nil sinon.
function ExistingScpTab(APages: TPageControl;
  const AConnUuid: string): TScpTab;

implementation

uses
  uSshConnect, uSshTunnel, uSshTunnelConnect, uSessionState;

function CanOpenScp(AModel: TRshModel; const AConnUuid: string): Boolean;
var
  node: TRshNode;
begin
  Result := False;
  if (AModel = nil) or (AConnUuid = '') then Exit;
  try
    node := AModel.GetNode(AConnUuid);
  except
    on Exception do Exit;
  end;
  try
    // nkConnection ET rpSsh seulement: un conteneur n'a pas de systeme de
    // fichiers joignable en SFTP par son propre compte.
    Result := (node.Kind = nkConnection) and (node.Protocol = rpSsh);
  finally
    node.Free;
  end;
end;

function ExistingScpTab(APages: TPageControl;
  const AConnUuid: string): TScpTab;
var
  i: Integer;
begin
  Result := nil;
  if (APages = nil) or (AConnUuid = '') then Exit;
  for i := 0 to APages.PageCount - 1 do
    if APages.Pages[i] is TScpTab then
      if (TScpTab(APages.Pages[i]).ConnectionUuid = AConnUuid) and
         (not IsTerminalState(TScpTab(APages.Pages[i]).SessionState)) then
        Exit(TScpTab(APages.Pages[i]));
end;

function StartScpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TScpTab;
var
  params, handed: TSshConnectParams;
  tab: TScpTab;
  displayName, jumpUuid: string;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  localPort: Integer;
begin
  Result := nil;
  AErr := '';
  tun := nil;
  broker := nil;

  // Une session de fichiers compte dans le plafond: socket et LIBSSH2_SESSION
  // a elle.
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
    // Ni PTY ni shell: cette session n'ouvrira qu'un sous-systeme SFTP.
    params.RequestPty := False;
    params.ExecCommand := '';
    params.StartupCommand := '';

    jumpUuid := AModel.ResolveJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid,
         params.Host, params.Port, tun, broker, localPort, AErr) then
        Exit;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
      if Assigned(ANotice) then
        ANotice(Format('%s: Scp via the SSH jump host.', [displayName]));
    end;

    // La propriete passe a l'onglet DES l'appel: si le constructeur echoue c'est
    // lui qui libere, et un params.Free ici libererait une seconde fois.
    handed := params;
    params := nil;
    tab := TScpTab.CreateSession(APages, ADoc, AManager, displayName,
      AConnUuid, handed);
    tab.AttachTunnel(tun, broker);
    tun := nil;
    broker := nil;
    tab.OnNotice := ANotice;
    APages.ActivePage := tab;
    tab.Start;
    Result := tab;
  finally
    params.Free;           // nil des que l'onglet l'a prise
    if tun <> nil then begin tun.Shutdown; tun.Free; end;
    broker.Free;
  end;
end;

end.
