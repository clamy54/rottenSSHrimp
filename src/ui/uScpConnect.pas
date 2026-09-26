{ Parametres via BuildSshConnectParams, le MEME que le terminal: un second
  chemin d'authentification serait un second endroit ou oublier un controle.
  Rebond: seule la SOCKET vise 127.0.0.1, la cle d'hote reste celle de la cible.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpConnect;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ComCtrls,
  uRshDocument, uRshModel, uSessionManager, uSessionTabBase, uScpTab,
  uSshTransport, uSshTunnel, uSshTunnelConnect;

// ACTIVE l'onglet existant s'il y en a un. nil + AErr vide = annulation.
function StartScpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TScpTab;

function CanOpenScp(AModel: TRshModel; const AConnUuid: string): Boolean;

function ExistingScpTab(APages: TPageControl;
  const AConnUuid: string): TScpTab;

// Ouverture ET reconnexion: un seul chemin. False + AErr vide = annulation.
function BuildScpConnection(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AParams: TSshConnectParams;
  out ATunnel: TSshTunnel; out ABroker: TSshTunnelBroker;
  out ADisplayName: string; out AErr: string): Boolean;

implementation

uses
  uSshConnect, uSessionState;

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
    // un conteneur n'a pas de SFTP a lui
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

function BuildScpConnection(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AParams: TSshConnectParams;
  out ATunnel: TSshTunnel; out ABroker: TSshTunnelBroker;
  out ADisplayName: string; out AErr: string): Boolean;
var
  params: TSshConnectParams;
  jumpUuid: string;
  localPort: Integer;
begin
  Result := False;
  AParams := nil;
  ATunnel := nil;
  ABroker := nil;
  ADisplayName := '';
  AErr := '';
  if not BuildSshConnectParams(ADoc, AModel, AConnUuid, params,
     ADisplayName, AErr) then
    Exit;
  try
    // sous-systeme SFTP seul
    params.RequestPty := False;
    params.ExecCommand := '';
    params.StartupCommand := '';

    jumpUuid := AModel.ResolveJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid,
         params.Host, params.Port, ATunnel, ABroker, localPort, AErr) then
        Exit;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
    end;
    AParams := params;
    params := nil;
    Result := True;
  finally
    params.Free;           // nil des que rendue a l'appelant
  end;
end;

function StartScpSession(APages: TPageControl; ADoc: TRshDocument;
  AModel: TRshModel; AManager: TSessionManager; const AConnUuid: string;
  ANotice: TSessionNoticeEvent; out AErr: string): TScpTab;
var
  params, handed: TSshConnectParams;
  tab: TScpTab;
  displayName: string;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
begin
  Result := nil;
  AErr := '';
  tun := nil;
  broker := nil;

  // compte dans le plafond: socket et LIBSSH2_SESSION a elle
  if not AManager.CanOpen then
  begin
    AErr := Format('Limit of %d concurrent sessions reached.',
      [AManager.MaxSessions]);
    Exit;
  end;
  if not BuildScpConnection(ADoc, AModel, AConnUuid, params, tun, broker,
     displayName, AErr) then
    Exit;
  try
    if (tun <> nil) and Assigned(ANotice) then
      ANotice(Format('%s: file transfer via the SSH jump host.',
        [displayName]));

    // Possede DES l'appel: si le constructeur echoue, il libere lui-meme.
    handed := params;
    params := nil;
    tab := TScpTab.CreateSession(APages, ADoc, AManager, displayName,
      AConnUuid, handed);
    tab.AttachTunnel(tun, broker);
    tun := nil;
    broker := nil;
    tab.OnNotice := ANotice;
    tab.EnableReconnect(AModel, @BuildScpConnection);
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
