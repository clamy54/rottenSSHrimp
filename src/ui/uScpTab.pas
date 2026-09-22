{ Onglet Scp: deux panneaux de fichiers, une file de transferts, et les trois
  fils qui les alimentent -- le thread UI, qui ne fait ni DNS, ni reseau, ni
  listing, ni copie; TSftpTransport; et TLocalFsWorker. Ce dernier existe
  parce qu'un partage reseau hors ligne fait bloquer un listing le temps du
  timeout systeme: sur le thread UI cela gele l'application, sur celui du
  transport cela arrete un envoi en cours.

  Le chemin AFFICHE et le chemin DEMANDE sont deux choses: FLocalPath et
  FRemotePath ne bougent qu'a l'arrivee d'un listing reussi, et toute
  operation se construit sur le chemin affiche.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpTab;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, ExtCtrls, StdCtrls,
  Graphics, LCLType,
  uSessionTabBase, uSessionState, uSessionManager, uRshDocument,
  uSshTransport, uSshKnownHosts, uSshTunnel, uSshTunnelConnect, uSecureBytes,
  uScpBackend, uScpErrors, uScpPaths, uTransferQueue, uSftpTransport,
  uLocalFileSystem, uLocalFsWorker, uFilePanel, uTransferQueueView, uTheme,
  uScpIcons;

type
  TScpTab = class;

  TScpSessionHandle = class(TManagedSession)
  private
    FTab: TScpTab;
  public
    constructor Create(ATab: TScpTab);
    function SessionState: TRemoteSessionState; override;
    function DisplayName: string; override;
    procedure BeginShutdown; override;
  end;

  TNavHistory = class
  private
    FItems: TStringList;
    FIndex: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const APath: string);
    function CanBack: Boolean;
    function CanForward: Boolean;
    function Back: string;
    function Forward: string;
    function Current: string;
  end;

  TScpTab = class(TSessionTabBase)
  private
    FDoc: TRshDocument;
    FManager: TSessionManager;
    FHandle: TScpSessionHandle;
    FKnownHosts: TSshKnownHosts;
    FDisplayName: string;
    FConnUuid: string;
    FState: TRemoteSessionState;
    FErrorMsg: string;
    FClosing: Boolean;
    FEverConnected: Boolean;
    FUserAbort: Boolean;
    FSkNotice: TObject;
    // ProcessMessages peut reentrer dans la fermeture: le drapeau l'arrete.
    FCleaningPartials: Boolean;

    FLocalFs: TLocalFileSystem;
    FLocalWorker: TLocalFsWorker;
    FQueue: TTransferQueue;
    FTransport: TSftpTransport;
    FTunnel: TSshTunnel;
    FTunnelBroker: TSshTunnelBroker;

    FHeader: TPanel;
    FHeaderInfo: TLabel;
    FBtnReconnect: TButton;
    FBtnClose: TButton;
    FSplit: TSplitter;
    FQueueSplit: TSplitter;
    FLocalPanel: TFilePanel;
    FRemotePanel: TFilePanel;
    FMiddle: TPanel;
    FCenterBar: TPanel;
    FBtnUpload: TButton;
    FBtnDownload: TButton;
    FQueueView: TTransferQueueView;
    FNotices: TLabel;

    FLocalPath: string;
    FRemotePath: string;
    FLocalHistory: TNavHistory;
    FRemoteHistory: TNavHistory;
    FActiveSide: TFilePanelSide;
    FRefreshTimer: TTimer;
    FPendingRemoteRefresh: Boolean;
    FPendingLocalRefresh: Boolean;
    FLocalSavedSel: TStringArray;
    FLocalSavedFocus: string;
    FLocalSavedTop: Integer;
    FRemoteSavedSel: TStringArray;
    FRemoteSavedFocus: string;
    FRemoteSavedTop: Integer;

    procedure BuildUi;
    procedure UpdateCaption;
    procedure UpdateHeader;
    procedure Note(const AText: string);

    procedure LocalAction(AAction: TFilePanelAction);
    procedure RemoteAction(AAction: TFilePanelAction);
    procedure PanelAction(ASide: TFilePanelSide; AAction: TFilePanelAction);
    procedure LocalNavigate(const APath: string);
    procedure RemoteNavigate(const APath: string);
    procedure NavigateTo(ASide: TFilePanelSide; const APath: string;
      APushHistory: Boolean);
    procedure RefreshSide(ASide: TFilePanelSide);
    procedure CaptureSide(ASide: TFilePanelSide);
    procedure UpdateTransferButtons;
    procedure WaitForPartialCleanup;

    procedure UploadClick(Sender: TObject);
    procedure DownloadClick(Sender: TObject);
    procedure ReconnectClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure StartTransfer(ASide: TFilePanelSide);
    procedure QueueCommand(ACommand: TQueueCommand);
    procedure RefreshTick(Sender: TObject);

    // --- relais du worker local (thread UI) ---
    procedure LocalListed(const APath: string;
      const AEntries: TScpEntryArray; const AError: TScpError);
    procedure LocalOpDone(const AError: TScpError);
    procedure LocalVolumes(const AVolumes: TLocalVolumeArray);

    // --- relais du transport (thread UI) ---
    procedure RemoteListed(const APath: string;
      const AEntries: TScpEntryArray; const AError: TScpError);
    procedure RemoteHomeReady(const APath: string; const AError: TScpError);
    procedure RemoteOpDone(const AError: TScpError);
    procedure TransportQueueChanged;
    procedure TransportNote(const AText: string);
    procedure TransportConnected(Sender: TObject);
    procedure TransportFailed(const AError: TScpError);
    procedure TransportConflict(const AInfo: TConflictInfo;
      var ADecision: TConflictDecision);
    procedure TransportNonAtomic(const ATargetPath: string;
      var AAllow: Boolean);
    procedure HostKeyLookup(const AHost: string; APort: Integer;
      const AKeyType, AFingerprint: string;
      out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
    procedure HostKeyAsk(const AInfo: TSshHostKeyInfo;
      var ADecision: TSshHostKeyDecision);
    procedure HostKeySave(const AInfo: TSshHostKeyInfo);
    procedure SkNotice(AActive: Boolean; const AText: string);
    procedure SkPin(const APrompt: string; out APin: TSecureBytes;
      var ACancelled: Boolean);
    procedure SkNoticeCancel(Sender: TObject);
  public
    // Prend possession de AParams.
    constructor CreateSession(APages: TPageControl; ADoc: TRshDocument;
      AManager: TSessionManager; const ADisplayName, AConnUuid: string;
      AParams: TSshConnectParams);
    destructor Destroy; override;

    procedure Start;
    procedure AttachTunnel(ATunnel: TSshTunnel; ABroker: TSshTunnelBroker);
    procedure RefreshTheme;

    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    function TabState: TRemoteSessionState; override;
    function TabIsFailedKept: Boolean; override;
    function TabBarCaption: string; override;
    function TabConnUuid: string; override;

    property SessionState: TRemoteSessionState read FState;
    property SessionName: string read FDisplayName;
    property ConnectionUuid: string read FConnUuid;
  end;

implementation

uses
  Clipbrd, Math, uHostKeyDialog, uFidoPrompt, uScpConflictDialog, uVersion;

const
  NAV_HISTORY_MAX = 64;
  REFRESH_DEBOUNCE_MS = 120;
  // Delai laisse au transport pour retirer ses temporaires: un aller-retour
  // SFTP, pas de quoi figer une fermeture.
  PARTIAL_CLEANUP_GRACE_MS = 5000;

{ TScpSessionHandle }

constructor TScpSessionHandle.Create(ATab: TScpTab);
begin
  inherited Create;
  FTab := ATab;
end;

function TScpSessionHandle.SessionState: TRemoteSessionState;
begin
  Result := FTab.SessionState;
end;

function TScpSessionHandle.DisplayName: string;
begin
  Result := FTab.SessionName;
end;

procedure TScpSessionHandle.BeginShutdown;
begin
  FTab.BeginShutdown;
end;

{ TNavHistory }

constructor TNavHistory.Create;
begin
  inherited Create;
  FItems := TStringList.Create;
  FIndex := -1;
end;

destructor TNavHistory.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TNavHistory.Push(const APath: string);
begin
  if (FIndex >= 0) and (FIndex < FItems.Count) and
     (FItems[FIndex] = APath) then
    Exit;
  while FItems.Count > FIndex + 1 do
    FItems.Delete(FItems.Count - 1);
  FItems.Add(APath);
  if FItems.Count > NAV_HISTORY_MAX then
    FItems.Delete(0);
  FIndex := FItems.Count - 1;
end;

function TNavHistory.CanBack: Boolean;
begin
  Result := FIndex > 0;
end;

function TNavHistory.CanForward: Boolean;
begin
  Result := (FIndex >= 0) and (FIndex < FItems.Count - 1);
end;

function TNavHistory.Back: string;
begin
  if not CanBack then Exit('');
  Dec(FIndex);
  Result := FItems[FIndex];
end;

function TNavHistory.Forward: string;
begin
  if not CanForward then Exit('');
  Inc(FIndex);
  Result := FItems[FIndex];
end;

function TNavHistory.Current: string;
begin
  if (FIndex >= 0) and (FIndex < FItems.Count) then
    Result := FItems[FIndex]
  else
    Result := '';
end;

{ TScpTab }

constructor TScpTab.CreateSession(APages: TPageControl; ADoc: TRshDocument;
  AManager: TSessionManager; const ADisplayName, AConnUuid: string;
  AParams: TSshConnectParams);
begin
  inherited Create(APages);
  PageControl := APages;
  FDoc := ADoc;
  FManager := AManager;
  FDisplayName := ADisplayName;
  FConnUuid := AConnUuid;
  FState := rssCreated;
  FKnownHosts := TSshKnownHosts.Create(ADoc);
  FLocalHistory := TNavHistory.Create;
  FRemoteHistory := TNavHistory.Create;
  FActiveSide := fpsLocal;

  FQueue := TTransferQueue.Create;
  FLocalFs := TLocalFileSystem.Create;
  FLocalWorker := TLocalFsWorker.Create(FLocalFs);
  FLocalWorker.OnListed := @LocalListed;
  FLocalWorker.OnOpDone := @LocalOpDone;
  FLocalWorker.OnVolumes := @LocalVolumes;

  FTransport := TSftpTransport.Create(AParams, FLocalFs, FQueue);
  FTransport.OnListed := @RemoteListed;
  FTransport.OnHome := @RemoteHomeReady;
  FTransport.OnOpDone := @RemoteOpDone;
  FTransport.OnQueueChanged := @TransportQueueChanged;
  FTransport.OnNote := @TransportNote;
  FTransport.OnConnected := @TransportConnected;
  FTransport.OnFailed := @TransportFailed;
  FTransport.OnConflict := @TransportConflict;
  FTransport.OnNonAtomic := @TransportNonAtomic;
  FTransport.OnHostKey := @HostKeyAsk;
  FTransport.OnHostKeyLookup := @HostKeyLookup;
  FTransport.OnHostKeySave := @HostKeySave;
  FTransport.OnSkNotice := @SkNotice;
  FTransport.OnSkPin := @SkPin;

  BuildUi;

  FHandle := TScpSessionHandle.Create(Self);
  FManager.RegisterSession(FHandle);
  UpdateCaption;
end;

destructor TScpTab.Destroy;
var
  cb: TNotifyEvent;
begin
  // 1. Marquer ferme: tout relais teste ce drapeau avant de toucher un
  //    controle.
  FClosing := True;
  if (FManager <> nil) and (FHandle <> nil) then
    FManager.UnregisterSession(FHandle);

  // 2. Detacher les callbacks AVANT de couper: un resultat deja en vol ne
  //    doit pas trouver de destinataire.
  if FTransport <> nil then
  begin
    FTransport.OnListed := nil;
    FTransport.OnHome := nil;
    FTransport.OnOpDone := nil;
    FTransport.OnQueueChanged := nil;
    FTransport.OnNote := nil;
    FTransport.OnConnected := nil;
    FTransport.OnFailed := nil;
    FTransport.OnConflict := nil;
    FTransport.OnNonAtomic := nil;
    FTransport.OnSkNotice := nil;
    FTransport.OnSkPin := nil;
  end;
  if FLocalWorker <> nil then
  begin
    FLocalWorker.OnListed := nil;
    FLocalWorker.OnOpDone := nil;
    FLocalWorker.OnVolumes := nil;
  end;

  // 3. Couper puis JOINDRE les deux threads. Le destructeur de TThread
  //    attend la fin de Execute, d'ou l'importance que toute attente reseau
  //    soit reveillable.
  if FTransport <> nil then
  begin
    FTransport.Shutdown;
    FTransport.Free;
    FTransport := nil;
  end;
  if FLocalWorker <> nil then
  begin
    FLocalWorker.Shutdown;
    FLocalWorker.Free;
    FLocalWorker := nil;
  end;

  // 4. Retirer ce qui attendait encore dans la file asynchrone de la LCL.
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FSkNotice);

  // 5. Tunnel et courtier APRES le transport: le transport s'appuie sur le
  //    port local du tunnel.
  if FTunnel <> nil then
  begin
    FTunnel.Shutdown;
    FTunnel.Free;
    FTunnel := nil;
  end;
  FreeAndNil(FTunnelBroker);

  FreeAndNil(FHandle);
  FreeAndNil(FKnownHosts);
  FreeAndNil(FQueue);
  FreeAndNil(FLocalFs);
  FreeAndNil(FLocalHistory);
  FreeAndNil(FRemoteHistory);

  cb := FOnDestroyed;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TScpTab.BuildUi;
begin
  Color := clAppBg;

  FHeader := TPanel.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.Height := 34;
  FHeader.BevelOuter := bvNone;
  FHeader.ParentBackground := False;
  FHeader.ParentColor := False;

  FBtnClose := TButton.Create(Self);
  FBtnClose.Parent := FHeader;
  FBtnClose.Align := alRight;
  FBtnClose.Caption := 'Close';
  FBtnClose.AutoSize := True;
  FBtnClose.BorderSpacing.Around := 4;
  FBtnClose.OnClick := @CloseClick;

  FBtnReconnect := TButton.Create(Self);
  FBtnReconnect.Parent := FHeader;
  FBtnReconnect.Align := alRight;
  FBtnReconnect.Caption := 'Reconnect';
  FBtnReconnect.AutoSize := True;
  FBtnReconnect.BorderSpacing.Around := 4;
  FBtnReconnect.OnClick := @ReconnectClick;

  FHeaderInfo := TLabel.Create(Self);
  FHeaderInfo.Parent := FHeader;
  FHeaderInfo.Align := alClient;
  FHeaderInfo.Layout := tlCenter;
  FHeaderInfo.BorderSpacing.Left := 8;

  FNotices := TLabel.Create(Self);
  FNotices.Parent := Self;
  FNotices.Align := alBottom;
  FNotices.BorderSpacing.Around := 4;
  FNotices.Caption := '';

  FQueueView := TTransferQueueView.CreateView(Self, FQueue);
  FQueueView.Parent := Self;
  FQueueView.Align := alBottom;
  FQueueView.Height := 160;
  FQueueView.OnCommand := @QueueCommand;

  FQueueSplit := TSplitter.Create(Self);
  FQueueSplit.Parent := Self;
  FQueueSplit.Align := alBottom;
  FQueueSplit.Height := 5;
  FQueueSplit.MinSize := 60;

  FMiddle := TPanel.Create(Self);
  FMiddle.Parent := Self;
  FMiddle.Align := alClient;
  FMiddle.BevelOuter := bvNone;
  FMiddle.ParentBackground := False;
  FMiddle.ParentColor := False;

  FLocalPanel := TFilePanel.CreateSide(Self, fpsLocal);
  FLocalPanel.Parent := FMiddle;
  FLocalPanel.Align := alLeft;
  FLocalPanel.Width := 480;
  FLocalPanel.OnAction := @LocalAction;
  FLocalPanel.OnNavigate := @LocalNavigate;
  FLocalPanel.List.OnAction := @LocalAction;

  FSplit := TSplitter.Create(Self);
  FSplit.Parent := FMiddle;
  FSplit.Align := alLeft;
  FSplit.Width := 5;
  FSplit.MinSize := 220;

  // La barre centrale doit rester visible quel que soit le partage: elle est
  // posee sur le panneau distant, cote gauche.
  FRemotePanel := TFilePanel.CreateSide(Self, fpsRemote);
  FRemotePanel.Parent := FMiddle;
  FRemotePanel.Align := alClient;
  FRemotePanel.OnAction := @RemoteAction;
  FRemotePanel.OnNavigate := @RemoteNavigate;
  FRemotePanel.List.OnAction := @RemoteAction;

  FCenterBar := TPanel.Create(Self);
  FCenterBar.Parent := FMiddle;
  FCenterBar.Align := alLeft;
  FCenterBar.Width := 128;
  FCenterBar.BevelOuter := bvNone;
  FCenterBar.ParentBackground := False;
  FCenterBar.ParentColor := False;

  FBtnUpload := TButton.Create(Self);
  FBtnUpload.Parent := FCenterBar;
  FBtnUpload.Align := alTop;
  FBtnUpload.Height := 30;
  FBtnUpload.Caption := 'Upload ->';
  FBtnUpload.BorderSpacing.Around := 6;
  FBtnUpload.OnClick := @UploadClick;

  FBtnDownload := TButton.Create(Self);
  FBtnDownload.Parent := FCenterBar;
  FBtnDownload.Align := alTop;
  FBtnDownload.Height := 30;
  FBtnDownload.Caption := '<- Download';
  FBtnDownload.BorderSpacing.Around := 6;
  FBtnDownload.OnClick := @DownloadClick;

  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Interval := REFRESH_DEBOUNCE_MS;
  FRefreshTimer.Enabled := False;
  FRefreshTimer.OnTimer := @RefreshTick;

  RefreshTheme;
end;

procedure TScpTab.RefreshTheme;
begin
  Color := clAppBg;
  if FHeader <> nil then FHeader.Color := clPanelHeader;
  if FHeaderInfo <> nil then FHeaderInfo.Font.Color := clPanelHeaderText;
  if FMiddle <> nil then FMiddle.Color := clAppBg;
  if FCenterBar <> nil then FCenterBar.Color := clAppBg;
  if FNotices <> nil then FNotices.Font.Color := clTextSecondary;
  if FLocalPanel <> nil then FLocalPanel.ApplyTheme;
  if FRemotePanel <> nil then FRemotePanel.ApplyTheme;
  if FQueueView <> nil then FQueueView.ApplyTheme;
  ApplyUiFont(Self);
  Invalidate;
end;

procedure TScpTab.Start;
begin
  FTransport.Start;
  FLocalWorker.Start;
  FLocalWorker.RequestVolumes;
  // Un panneau est actif des le depart: sinon aucune des deux selections
  // ne se distingue, et F5 n'a pas de sens defini.
  FLocalPanel.List.SetPanelActive(True);
  FRemotePanel.List.SetPanelActive(False);
  UpdateTransferButtons;
  NavigateTo(fpsLocal, LocalHomePath, True);
  UpdateHeader;
end;

procedure TScpTab.AttachTunnel(ATunnel: TSshTunnel;
  ABroker: TSshTunnelBroker);
begin
  FTunnel := ATunnel;
  FTunnelBroker := ABroker;
end;

procedure TScpTab.UpdateCaption;
var
  mark: string;
begin
  case FState of
    rssCreated, rssConnecting: mark := '○ ';
    rssAuthenticating: mark := '◐ ';
    rssConnected: mark := '● ';
    rssDisconnecting: mark := '◌ ';
    rssFailed: mark := '✕ ';
  else
    mark := '';
  end;
  Caption := mark + FDisplayName + ' — Scp';
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

procedure TScpTab.UpdateHeader;
var
  stateText: string;
begin
  if FClosing or (FHeaderInfo = nil) then Exit;
  case FState of
    rssCreated, rssConnecting: stateText := 'connecting';
    rssAuthenticating: stateText := 'authenticating';
    rssConnected: stateText := 'connected';
    rssDisconnecting: stateText := 'disconnecting';
    rssDisconnected: stateText := 'disconnected';
    rssFailed: stateText := 'failed';
  else
    stateText := '';
  end;
  FHeaderInfo.Caption := Format('%s  •  %s  •  Protocol: SFTP over SSH',
    [FDisplayName, stateText]);
  if (FState = rssFailed) and (FErrorMsg <> '') then
    FHeaderInfo.Caption := FHeaderInfo.Caption + '  •  ' + FErrorMsg;
  FBtnReconnect.Enabled := FState in [rssFailed, rssDisconnected];
end;

// Un bouton actif qui ne ferait rien est un bouton qui ment: ils suivent la
// selection et l'etat de la connexion.
procedure TScpTab.UpdateTransferButtons;
var
  live: Boolean;
begin
  if FClosing or (FBtnUpload = nil) then Exit;
  live := FState = rssConnected;
  FBtnUpload.Enabled := live and (FLocalPanel.SelectionCount > 0);
  FBtnDownload.Enabled := live and (FRemotePanel.SelectionCount > 0);
end;

procedure TScpTab.Note(const AText: string);
begin
  if FClosing or (FNotices = nil) then Exit;
  // Le texte peut contenir un nom du serveur: deja neutralise, mais une seconde
  // passe ne coute rien.
  FNotices.Caption := DisplaySafeName(AText);
  if Assigned(FOnNotice) then
    FOnNotice(Format('%s: %s', [FDisplayName, AText]));
end;

// --- Navigation -----------------------------------------------------------

procedure TScpTab.CaptureSide(ASide: TFilePanelSide);
begin
  if ASide = fpsLocal then
    FLocalPanel.List.CaptureView(FLocalSavedSel, FLocalSavedFocus,
      FLocalSavedTop)
  else
    FRemotePanel.List.CaptureView(FRemoteSavedSel, FRemoteSavedFocus,
      FRemoteSavedTop);
end;

procedure TScpTab.NavigateTo(ASide: TFilePanelSide; const APath: string;
  APushHistory: Boolean);
var
  norm: string;
begin
  if FClosing then Exit;
  if ASide = fpsLocal then
  begin
    if APath = '' then Exit;
    norm := LocalNormalize(APath);
    if norm <> FLocalPath then
    begin
      FLocalSavedSel := nil;
      FLocalSavedFocus := '';
      FLocalSavedTop := 0;
    end
    else
      CaptureSide(fpsLocal);
    FLocalPath := norm;
    if APushHistory then FLocalHistory.Push(norm);
    FLocalPanel.SetBusy(True, 'Reading ' + DisplaySafeName(norm) + '...');
    FLocalPanel.SelectVolumeFor(norm);
    FLocalWorker.RequestList(norm);
  end
  else
  begin
    if APath = '' then Exit;
    norm := RemoteNormalize(APath);
    if norm <> FRemotePath then
    begin
      FRemoteSavedSel := nil;
      FRemoteSavedFocus := '';
      FRemoteSavedTop := 0;
    end
    else
      CaptureSide(fpsRemote);
    FRemotePath := norm;
    if APushHistory then FRemoteHistory.Push(norm);
    FRemotePanel.SetBusy(True, 'Reading ' + DisplaySafeName(norm) + '...');
    FTransport.RequestList(norm);
  end;
end;

procedure TScpTab.RefreshSide(ASide: TFilePanelSide);
begin
  if ASide = fpsLocal then
  begin
    FPendingLocalRefresh := True;
    CaptureSide(fpsLocal);
  end
  else
  begin
    FPendingRemoteRefresh := True;
    CaptureSide(fpsRemote);
  end;
  FRefreshTimer.Enabled := False;
  FRefreshTimer.Enabled := True;
end;

procedure TScpTab.RefreshTick(Sender: TObject);
begin
  FRefreshTimer.Enabled := False;
  if FClosing then Exit;
  if FPendingLocalRefresh then
  begin
    FPendingLocalRefresh := False;
    if FLocalPath <> '' then FLocalWorker.RequestList(FLocalPath);
  end;
  if FPendingRemoteRefresh then
  begin
    FPendingRemoteRefresh := False;
    if (FRemotePath <> '') and (FTransport <> nil) then
      FTransport.RequestList(FRemotePath);
  end;
end;

procedure TScpTab.LocalNavigate(const APath: string);
begin
  FActiveSide := fpsLocal;
  NavigateTo(fpsLocal, APath, True);
end;

procedure TScpTab.RemoteNavigate(const APath: string);
begin
  FActiveSide := fpsRemote;
  NavigateTo(fpsRemote, APath, True);
end;

procedure TScpTab.LocalAction(AAction: TFilePanelAction);
begin
  PanelAction(fpsLocal, AAction);
end;

procedure TScpTab.RemoteAction(AAction: TFilePanelAction);
begin
  PanelAction(fpsRemote, AAction);
end;

procedure TScpTab.PanelAction(ASide: TFilePanelSide;
  AAction: TFilePanelAction);
var
  panel: TFilePanel;
  hist: TNavHistory;
  entry: TScpEntry;
  cur, target, newName, msg: string;
  names: TStringArray;
  i: Integer;
  v: TNameVerdict;
begin
  if FClosing then Exit;
  FActiveSide := ASide;
  if ASide = fpsLocal then
  begin
    panel := FLocalPanel;
    hist := FLocalHistory;
    cur := FLocalPath;
  end
  else
  begin
    panel := FRemotePanel;
    hist := FRemoteHistory;
    cur := FRemotePath;
  end;
  FLocalPanel.List.SetPanelActive(ASide = fpsLocal);
  FRemotePanel.List.SetPanelActive(ASide = fpsRemote);
  UpdateTransferButtons;

  case AAction of
    fpaNavigate:
      begin
        if not panel.List.FocusedEntry(entry) then Exit;
        // Un lien n'est jamais SUIVI en recursion; y entrer a la main est un choix.
        if not (entry.IsDir or (entry.IsLink and entry.TargetIsDir)) then
        begin
          // Aucune ouverture ni execution automatique d'un fichier distant.
          Note('Double-click opens folders only; files are never opened ' +
            'or run from here.');
          Exit;
        end;
        if CheckRemoteChildName(entry.Name) <> nvOk then Exit;
        if ASide = fpsLocal then
          NavigateTo(ASide, LocalJoin(cur, entry.Name), True)
        else
          NavigateTo(ASide, RemoteJoin(cur, entry.Name), True);
      end;
    fpaParent:
      if ASide = fpsLocal then
        NavigateTo(ASide, LocalParent(cur), True)
      else
        NavigateTo(ASide, RemoteParent(cur), True);
    fpaBack:
      if hist.CanBack then NavigateTo(ASide, hist.Back, False);
    fpaForward:
      if hist.CanForward then NavigateTo(ASide, hist.Forward, False);
    fpaHome:
      if ASide = fpsLocal then
        NavigateTo(ASide, LocalHomePath, True)
      else
        FTransport.RequestHome;
    fpaRefresh:
      begin
        panel.ClearError;
        RefreshSide(ASide);
      end;
    fpaNewFolder:
      begin
        newName := '';
        if not InputQuery('New folder', 'Name of the new folder:',
           newName) then Exit;
        newName := Trim(newName);
        if newName = '' then Exit;
        if ASide = fpsLocal then
          v := CheckLocalName(newName)
        else
          v := CheckRemoteChildName(newName);
        if v <> nvOk then
        begin
          MessageDlg(RSSH_APP_NAME,
            NameVerdictText(v, DisplaySafeName(newName)), mtError, [mbOK], 0);
          Exit;
        end;
        if ASide = fpsLocal then
          FLocalWorker.RequestMkdir(LocalJoin(cur, newName))
        else
          FTransport.RequestMkdir(RemoteJoin(cur, newName));
      end;
    fpaRename:
      begin
        if not panel.List.FocusedEntry(entry) then Exit;
        newName := entry.Name;
        if not InputQuery('Rename',
           Format('New name for "%s":', [DisplaySafeName(entry.Name)]),
           newName) then Exit;
        newName := Trim(newName);
        if (newName = '') or (newName = entry.Name) then Exit;
        if ASide = fpsLocal then
          v := CheckLocalName(newName)
        else
          v := CheckRemoteChildName(newName);
        if v <> nvOk then
        begin
          MessageDlg(RSSH_APP_NAME,
            NameVerdictText(v, DisplaySafeName(newName)), mtError, [mbOK], 0);
          Exit;
        end;
        if ASide = fpsLocal then
          FLocalWorker.RequestRename(LocalJoin(cur, entry.Name),
            LocalJoin(cur, newName))
        else
          FTransport.RequestRename(RemoteJoin(cur, entry.Name),
            RemoteJoin(cur, newName));
      end;
    fpaDelete:
      begin
        names := panel.List.SelectedNames;
        if Length(names) = 0 then Exit;
        // Le contenu d'un dossier n'est pas compte d'avance: la formulation
        // le dit, plutot que de laisser croire a un total.
        if Length(names) = 1 then
          msg := Format('Delete "%s"?', [DisplaySafeName(names[0])])
        else
          msg := Format('Delete these %d items?', [Length(names)]);
        msg := msg + LineEnding + LineEnding +
          'Folders are deleted with everything they contain. This cannot ' +
          'be undone.';
        if QuestionDlg('Delete', msg, mtWarning,
           [mrNo, 'Cancel', 'IsCancel', 'IsDefault',
            mrYes, 'Delete'], 0) <> mrYes then Exit;
        for i := 0 to High(names) do
        begin
          if CheckRemoteChildName(names[i]) <> nvOk then Continue;
          if ASide = fpsLocal then
            FLocalWorker.RequestDelete(LocalJoin(cur, names[i]))
          else
            FTransport.RequestDelete(RemoteJoin(cur, names[i]));
        end;
      end;
    fpaTransfer:
      StartTransfer(ASide);
    fpaCopyPath:
      begin
        if panel.List.FocusedEntry(entry) then
        begin
          if ASide = fpsLocal then
            target := LocalJoin(cur, entry.Name)
          else
            target := RemoteJoin(cur, entry.Name);
        end
        else
          target := cur;
        Clipboard.AsText := target;
        Note('Path copied to the clipboard.');
      end;
    fpaReveal:
      if ASide = fpsLocal then
      begin
        if not RevealInFileManager(FLocalPath) then
          Note('The system file manager could not be opened.');
      end;
    fpaFocusOther:
      if ASide = fpsLocal then
        FRemotePanel.FocusList
      else
        FLocalPanel.FocusList;
  end;
end;

// --- Transferts -----------------------------------------------------------

procedure TScpTab.StartTransfer(ASide: TFilePanelSide);
var
  names: TStringArray;
  sources: TStringArray;
  i, n: Integer;
begin
  if FClosing or (FTransport = nil) then Exit;
  if FState <> rssConnected then
  begin
    Note('Not connected: reconnect before transferring.');
    Exit;
  end;
  if ASide = fpsLocal then
  begin
    names := FLocalPanel.List.SelectedNames;
    if Length(names) = 0 then Exit;
    n := 0;
    SetLength(sources, Length(names));
    for i := 0 to High(names) do
    begin
      if CheckRemoteChildName(names[i]) <> nvOk then Continue;
      sources[n] := LocalJoin(FLocalPath, names[i]);
      Inc(n);
    end;
    SetLength(sources, n);
    if n = 0 then Exit;
    // La RACINE de confinement est le dossier distant affiche: rien de ce
    // lot ne pourra etre ecrit en dehors.
    FTransport.RequestUpload(sources, FRemotePath, FRemotePath);
  end
  else
  begin
    names := FRemotePanel.List.SelectedNames;
    if Length(names) = 0 then Exit;
    n := 0;
    SetLength(sources, Length(names));
    for i := 0 to High(names) do
    begin
      if CheckRemoteChildName(names[i]) <> nvOk then Continue;
      sources[n] := RemoteJoin(FRemotePath, names[i]);
      Inc(n);
    end;
    SetLength(sources, n);
    if n = 0 then Exit;
    FTransport.RequestDownload(sources, FLocalPath, FLocalPath);
  end;
  // « Apply to all » ne vaut que pour son propre lot.
  FQueue.ClearConflictPolicy;
  FQueue.ClearSkipKinds;
  FQueueView.Refresh;
end;

procedure TScpTab.UploadClick(Sender: TObject);
begin
  StartTransfer(fpsLocal);
end;

procedure TScpTab.DownloadClick(Sender: TObject);
begin
  StartTransfer(fpsRemote);
end;

procedure TScpTab.QueueCommand(ACommand: TQueueCommand);
var
  ids: TStringArray;
  i, id: Integer;
  item: TTransferItem;
begin
  if FClosing or (FTransport = nil) then Exit;
  case ACommand of
    qcPause:
      begin
        FTransport.PauseTransfers;
        Note('Queue paused. The item in progress finishes first.');
      end;
    qcResume:
      FTransport.ResumeTransfers;
    qcCancelSelected:
      begin
        ids := FQueueView.SelectedItemIds;
        for i := 0 to High(ids) do
          if TryStrToInt(ids[i], id) then
          begin
            item := FQueue.FindById(id);
            FQueue.CancelItem(item);
          end;
      end;
    qcClearCompleted:
      FQueue.ClearFinished;
    qcRetryFailed:
      FTransport.RequestRetryFailed;
  end;
  FQueueView.Refresh;
end;

procedure TScpTab.ReconnectClick(Sender: TObject);
begin
  // Une reconnexion demande de reconstruire une session complete, avec ses
  // invites: c'est le role de uScpConnect, pas de l'onglet. On demande donc
  // la fermeture et on le dit clairement plutot que de reconnecter a moitie.
  Note('Close this tab and open Scp again on the host to reconnect.');
end;

procedure TScpTab.CloseClick(Sender: TObject);
begin
  if ConfirmClose then
    Free;
end;

// --- Relais du worker local ----------------------------------------------

procedure TScpTab.LocalListed(const APath: string;
  const AEntries: TScpEntryArray; const AError: TScpError);
begin
  if FClosing then Exit;
  FLocalPanel.SetBusy(False, '');
  if AError.Kind <> sekNone then
  begin
    // L'ancien contenu RESTE affiche: vider la vue sur une erreur ferait
    // croire a un dossier vide.
    FLocalPanel.ShowError(AError);
    Exit;
  end;
  FLocalPanel.ClearError;
  FLocalPanel.SetEntries(APath, AEntries);
  FLocalPanel.List.RestoreView(FLocalSavedSel, FLocalSavedFocus,
    FLocalSavedTop);
  UpdateTransferButtons;
end;

procedure TScpTab.LocalOpDone(const AError: TScpError);
begin
  if FClosing then Exit;
  if AError.Kind <> sekNone then
    Note(ScpErrorText(AError));
  RefreshSide(fpsLocal);
end;

procedure TScpTab.LocalVolumes(const AVolumes: TLocalVolumeArray);
var
  caps, paths: array of string;
  i: Integer;
begin
  if FClosing then Exit;
  SetLength(caps, Length(AVolumes));
  SetLength(paths, Length(AVolumes));
  for i := 0 to High(AVolumes) do
  begin
    caps[i] := AVolumes[i].Caption;
    paths[i] := AVolumes[i].Path;
  end;
  FLocalPanel.SetVolumes(caps, paths);
  if FLocalPath <> '' then
    FLocalPanel.SelectVolumeFor(FLocalPath);
end;

// --- Relais du transport --------------------------------------------------

procedure TScpTab.RemoteListed(const APath: string;
  const AEntries: TScpEntryArray; const AError: TScpError);
begin
  if FClosing then Exit;
  FRemotePanel.SetBusy(False, '');
  if AError.Kind <> sekNone then
  begin
    FRemotePanel.ShowError(AError);
    // Une erreur de listing n'invalide pas la connexion: seule une perte reseau
    // le fait, par TransportFailed.
    Exit;
  end;
  FRemotePanel.ClearError;
  FRemotePanel.SetEntries(APath, AEntries);
  FRemotePanel.List.RestoreView(FRemoteSavedSel, FRemoteSavedFocus,
    FRemoteSavedTop);
  UpdateTransferButtons;
end;

procedure TScpTab.RemoteHomeReady(const APath: string;
  const AError: TScpError);
begin
  if FClosing then Exit;
  if APath = '' then
  begin
    FRemotePanel.SetBusy(False, '');
    FRemotePanel.ShowError(AError);
    Exit;
  end;
  NavigateTo(fpsRemote, APath, True);
end;

procedure TScpTab.RemoteOpDone(const AError: TScpError);
begin
  if FClosing then Exit;
  if AError.Kind <> sekNone then
    Note(ScpErrorText(AError));
  RefreshSide(fpsRemote);
end;

procedure TScpTab.TransportQueueChanged;
begin
  if FClosing then Exit;
  FQueueView.Refresh;
  UpdateTransferButtons;
  if FQueue.IsFinished then
  begin
    RefreshSide(fpsLocal);
    RefreshSide(fpsRemote);
  end;
end;

procedure TScpTab.TransportNote(const AText: string);
begin
  if FClosing then Exit;
  Note(AText);
end;

procedure TScpTab.TransportConnected(Sender: TObject);
begin
  if FClosing then Exit;
  FState := rssConnected;
  FEverConnected := True;
  UpdateCaption;
  UpdateHeader;
  UpdateTransferButtons;
  FTransport.RequestHome;
end;

procedure TScpTab.TransportFailed(const AError: TScpError);
begin
  if FClosing then Exit;
  FState := rssFailed;
  FErrorMsg := FTransport.LastErrorText;
  if FErrorMsg = '' then FErrorMsg := ScpErrorText(AError);
  if (FTunnel <> nil) and (FTunnel.LastError <> '') then
    FErrorMsg := FTunnel.LastError;
  UpdateCaption;
  UpdateHeader;
  // Un echec garde l'onglet OUVERT avec sa raison, et les elements en vol
  // passent a « interrompu », pas a « reussi ».
  FRemotePanel.ShowError(MakeScpError(sekConnectionLost, 'Connection',
    FDisplayName, FErrorMsg));
  FQueueView.Refresh;
  Note(FErrorMsg);
end;

procedure TScpTab.TransportConflict(const AInfo: TConflictInfo;
  var ADecision: TConflictDecision);
begin
  if FClosing then
  begin
    ADecision.Action := cnCancelQueue;
    Exit;
  end;
  ADecision := AskTransferConflict(AInfo);
end;

procedure TScpTab.TransportNonAtomic(const ATargetPath: string;
  var AAllow: Boolean);
begin
  if FClosing then
  begin
    AAllow := False;
    Exit;
  end;
  AAllow := AskNonAtomicReplace(ATargetPath);
end;

procedure TScpTab.HostKeyLookup(const AHost: string; APort: Integer;
  const AKeyType, AFingerprint: string;
  out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
var
  entry: TKnownHostEntry;
begin
  AVerdict := hkUnknown;
  AKnownFingerprint := '';
  case FKnownHosts.Verify(AHost, APort, AKeyType, AFingerprint, entry) of
    khvMatch:
      begin
        AVerdict := hkMatch;
        FKnownHosts.TouchSeen(entry.Uuid);
      end;
    khvChanged:
      begin
        AVerdict := hkChanged;
        AKnownFingerprint := entry.Fingerprint;
      end;
  end;
end;

procedure TScpTab.HostKeyAsk(const AInfo: TSshHostKeyInfo;
  var ADecision: TSshHostKeyDecision);
begin
  // Exactement le dialogue des sessions SSH: une cle modifiee reste bloquante.
  if AInfo.Verdict = hkChanged then
    ADecision := AskChangedHostKey(AInfo)
  else
    ADecision := AskUnknownHostKey(AInfo);
end;

procedure TScpTab.HostKeySave(const AInfo: TSshHostKeyInfo);
begin
  FKnownHosts.Remember(AInfo.Host, AInfo.Port, AInfo.KeyType,
    AInfo.Fingerprint, AInfo.Blob);
end;

procedure TScpTab.SkNotice(AActive: Boolean; const AText: string);
begin
  if AActive then
  begin
    if FSkNotice = nil then
      FSkNotice := TFidoTouchNotice.Create(AText, @SkNoticeCancel)
    else
      TFidoTouchNotice(FSkNotice).SetText(AText);
  end
  else
    FreeAndNil(FSkNotice);
end;

procedure TScpTab.SkNoticeCancel(Sender: TObject);
begin
  FUserAbort := True;
  if FTransport <> nil then
    FTransport.Shutdown;
end;

procedure TScpTab.SkPin(const APrompt: string; out APin: TSecureBytes;
  var ACancelled: Boolean);
begin
  APin := nil;
  ACancelled := not AskFidoPin(APrompt, APin);
end;

// --- Cycle de vie ---------------------------------------------------------

function TScpTab.ConfirmClose: Boolean;
var
  s: TQueueSummary;
  partials: Integer;
  msg: string;
begin
  s := FQueue.Summary;
  partials := 0;
  if FTransport <> nil then
    partials := FTransport.ActivePartialCount;
  if (s.Pending + s.Running + s.Interrupted = 0) and (partials = 0) then
    Exit(True);

  msg := Format('%d transfer(s) are still queued or in progress.',
    [s.Pending + s.Running + s.Interrupted]);
  if partials > 0 then
    // Le nombre de partiels est DIT: ils restent sur le disque ou le serveur, et
    // les decouvrir plus tard sans explication est le pire des deux mondes.
    msg := msg + LineEnding + Format('%d partial file(s) have been written ' +
      'and will be removed if possible, or left clearly named otherwise.',
      [partials]);
  msg := msg + LineEnding + LineEnding +
    'No destination file has been replaced by an incomplete transfer.';
  Result := QuestionDlg('Close Scp', msg, mtConfirmation,
    [mrCancel, 'Keep open', 'IsCancel', 'IsDefault',
     mrOK, 'Close anyway'], 0) = mrOK;
  if Result and (FTransport <> nil) then
  begin
    FQueue.CancelAll;
    if partials > 0 then
      WaitForPartialCleanup;
  end;
end;

// On vient de promettre de retirer les temporaires « si possible ». Detruire
// l'onglet dans la foulee tuerait le thread avant qu'il voie la commande: on
// lui laisse un court delai en pompant la boucle, et on DIT ce qui reste.
procedure TScpTab.WaitForPartialCleanup;
var
  waited: Integer;
  remaining: Integer;
begin
  if (FTransport = nil) or FCleaningPartials then Exit;
  FCleaningPartials := True;
  Screen.Cursor := crHourGlass;
  try
    FTransport.RequestCleanupPartials;
    waited := 0;
    while waited < PARTIAL_CLEANUP_GRACE_MS do
    begin
      Application.ProcessMessages;
      if FTransport.ActivePartialCount = 0 then Break;
      Sleep(20);
      Inc(waited, 20);
    end;
    remaining := FTransport.ActivePartialCount;
    if remaining > 0 then
      // Pas de silence: un partiel tu se decouvre des semaines plus tard.
      EmitNotice(Format('%s: %d partial file(s) could not be removed in ' +
        'time and are still there, named ".rssh-*.part".',
        [FDisplayName, remaining]));
  finally
    Screen.Cursor := crDefault;
    FCleaningPartials := False;
  end;
end;

procedure TScpTab.BeginShutdown;
begin
  FUserAbort := True;
  if FQueue <> nil then FQueue.CancelAll;
  if FLocalFs <> nil then FLocalFs.Cancel;
  if FTransport <> nil then FTransport.Shutdown;
  if FLocalWorker <> nil then FLocalWorker.Shutdown;
end;

procedure TScpTab.FocusContent;
begin
  if FClosing then Exit;
  if FActiveSide = fpsLocal then
    FLocalPanel.FocusList
  else
    FRemotePanel.FocusList;
end;

function TScpTab.TabState: TRemoteSessionState;
begin
  Result := FState;
end;

function TScpTab.TabIsFailedKept: Boolean;
begin
  Result := (FState = rssFailed) and (not FUserAbort);
end;

function TScpTab.TabBarCaption: string;
begin
  Result := FDisplayName + ' — Scp';
end;

function TScpTab.TabConnUuid: string;
begin
  Result := FConnUuid;
end;

end.
