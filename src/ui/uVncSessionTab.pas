unit uVncSessionTab;

{$mode objfpc}{$H+}

// Onglet de session VNC. Le transport emet TOUS ses evenements
// depuis son thread: toucher un widget LCL de la est un crash differe, jamais
// une erreur nette. Tout remonte donc par Application.QueueAsyncCall.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, Graphics,
  ExtCtrls, StdCtrls, Clipbrd, SyncObjs, uVncControl, uRemoteSurface, uVncTransport,
  uSessionState, uSessionManager, uSecureBytes, uSessionTabBase,
  uClipboardBridge, uSshTunnel, uSshTunnelConnect;

type
  TVncSessionTab = class;

  // TTabSheet ne peut pas deriver aussi de TManagedSession.
  TVncSessionHandle = class(TManagedSession)
  private
    FTab: TVncSessionTab;
  public
    constructor Create(ATab: TVncSessionTab);
    function SessionState: TRemoteSessionState; override;
    function DisplayName: string; override;
    procedure BeginShutdown; override;
  end;

  TVncSessionTab = class(TSessionTabBase)
  private
    FScroll: TScrollBox;
    FView: TRottenVncControl;
    FTransport: TVncTransport;
    FManager: TSessionManager;
    FHandle: TVncSessionHandle;
    FDisplayName: string;
    FConnUuid: string;
    FState: TRemoteSessionState;
    FErrorMsg: string;
    FClosing: Boolean;
    FClipEnabled: Boolean;
    // Pas de notification presse-papiers sur Cocoa: on sonde.
    FClipTimer: TTimer;
    FClipBridge: TClipboardBridge;
    // Un echec d'ETABLISSEMENT garde l'onglet ouvert avec sa raison.
    FEverConnected: Boolean;
    FUserAbort: Boolean;
    FFailedOpen: Boolean;
    FFailPanel: TPanel;
    FFailLabel: TLabel;

    procedure ViewPointer(AX, AY, AButtonMask: Integer);
    procedure ViewKey(AKeysym: Cardinal; ADown: Boolean);
    procedure ViewEscapeCapture(Sender: TObject);

    procedure TransportState(ASender: TObject; AState: TRemoteSessionState);
    procedure TransportClipboard(ASender: TObject; const AText: string);
    procedure TransportResize(ASender: TObject; AWidth, AHeight: Integer);
    procedure TransportReconnect(ASender: TObject; const AMessage: string;
      AActive: Boolean);

    procedure AsyncState(Data: PtrInt);
    procedure AsyncClipboard(Data: PtrInt);
    procedure AsyncResize(Data: PtrInt);
    procedure AsyncReconnect(Data: PtrInt);

    procedure ScrollResize(Sender: TObject);
    procedure PaintTick(Sender: TObject);
    procedure ClipPoll(Sender: TObject);
    function TryReadClip(out AText: string): Boolean;
    procedure SendClipToServer(const AText: string);
    procedure UpdateCaption;
    procedure DeferredClose(Data: PtrInt);
    procedure RequestClose;
    procedure ShowFailureOverlay;
    procedure FailDismiss(Sender: TObject);
  private
    FPaintTimer: TTimer;
    // Depose par le thread de session, consomme par le thread UI: sous verrou.
    FPendingClip: string;
    FClipLock: TCriticalSection;
    FReconnectMsg: string;
    FPendingReconnectMsg: string;
    FPendingReconnectActive: Boolean;
    FReconnectLock: TCriticalSection;
    // Tunnel de rebond: nil si direct, libere APRES le transport.
    FTunnel: TSshTunnel;
    FTunnelBroker: TSshTunnelBroker;
  public
    procedure AttachTunnel(ATunnel: TSshTunnel; ABroker: TSshTunnelBroker);
    // Prend possession de APassword.
    constructor CreateSession(APages: TPageControl; AManager: TSessionManager;
      const ADisplayName, AConnUuid: string; const AConfig: TVncConfig;
      APassword: TSecureBytes);
    destructor Destroy; override;

    procedure Start;
    procedure InhibitReconnect;
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    function GrabThumbnail: TBitmap; override;
    function TabState: TRemoteSessionState; override;
    function TabBarCaption: string; override;
    function TabConnUuid: string; override;
    function TabIsFailedKept: Boolean; override;

    property SessionState: TRemoteSessionState read FState;
    property SessionName: string read FDisplayName;
    property ConnectionUuid: string read FConnUuid;
    property View: TRottenVncControl read FView;
  end;

implementation

const
  PAINT_MS = 33;
  CLIP_POLL_MS = 400;

constructor TVncSessionHandle.Create(ATab: TVncSessionTab);
begin
  inherited Create;
  FTab := ATab;
end;

function TVncSessionHandle.SessionState: TRemoteSessionState;
begin
  Result := FTab.FState;
end;

function TVncSessionHandle.DisplayName: string;
begin
  Result := FTab.FDisplayName;
end;

procedure TVncSessionHandle.BeginShutdown;
begin
  FTab.BeginShutdown;
end;

constructor TVncSessionTab.CreateSession(APages: TPageControl;
  AManager: TSessionManager; const ADisplayName, AConnUuid: string;
  const AConfig: TVncConfig; APassword: TSecureBytes);
begin
  inherited Create(APages);
  PageControl := APages;
  FDisplayName := ADisplayName;
  FConnUuid := AConnUuid;
  FManager := AManager;
  FState := rssCreated;
  FClipEnabled := AConfig.ClipboardTextEnabled;
  FClipLock := TCriticalSection.Create;
  FReconnectLock := TCriticalSection.Create;

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;
  FScroll.HorzScrollBar.Tracking := True;
  FScroll.VertScrollBar.Tracking := True;
  FScroll.Color := clBlack;
  FScroll.OnResize := @ScrollResize;

  FView := TRottenVncControl.Create(Self);
  FView.Parent := FScroll;
  FView.SetBounds(0, 0, 1, 1);
  FView.ViewOnly := AConfig.ViewOnly;
  FView.FitToWindow := not AConfig.ViewActualSize;
  FView.OnPointerEvent := @ViewPointer;
  FView.OnKeyEvent := @ViewKey;
  FView.OnEscapeCapture := @ViewEscapeCapture;

  FTransport := TVncTransport.Create(AConfig, APassword);
  FTransport.OnStateChanged := @TransportState;
  FTransport.OnClipboardText := @TransportClipboard;
  FTransport.OnDesktopResize := @TransportResize;
  FTransport.OnReconnect := @TransportReconnect;
  FView.AttachSurface(FTransport.Surface);

  FPaintTimer := TTimer.Create(Self);
  FPaintTimer.Interval := PAINT_MS;
  FPaintTimer.OnTimer := @PaintTick;
  FPaintTimer.Enabled := True;

  FClipBridge := TClipboardBridge.Create(
    @TryReadClip, @SendClipToServer, VNC_CLIP_SEND_MAX);

  if FClipEnabled and (not AConfig.ViewOnly) then
  begin
    FClipTimer := TTimer.Create(Self);
    FClipTimer.Interval := CLIP_POLL_MS;
    FClipTimer.OnTimer := @ClipPoll;
    FClipTimer.Enabled := True;
  end;

  FHandle := TVncSessionHandle.Create(Self);
  FManager.RegisterSession(FHandle);
  UpdateCaption;
end;

destructor TVncSessionTab.Destroy;
var
  cb: TNotifyEvent;
begin
  // Timers coupes avant le transport: un tick lirait une surface liberee.
  if FPaintTimer <> nil then FPaintTimer.Enabled := False;
  if FClipTimer <> nil then FClipTimer.Enabled := False;
  if FManager <> nil then
    FManager.UnregisterSession(FHandle);
  if FTransport <> nil then
  begin
    FTransport.BeginShutdown;
    FTransport.WaitForShutdown;
  end;
  // Des appels differes en attente tireraient sur un onglet mort.
  Application.RemoveAsyncCalls(Self);
  if FView <> nil then
    FView.AttachSurface(nil);
  FreeAndNil(FHandle);
  FreeAndNil(FTransport);
  if FTunnel <> nil then
  begin
    FTunnel.Shutdown;
    FTunnel.Free;
    FTunnel := nil;
  end;
  FreeAndNil(FTunnelBroker);
  FreeAndNil(FClipLock);
  FreeAndNil(FReconnectLock);
  FreeAndNil(FClipBridge);
  cb := FOnDestroyed;
  FOnDestroyed := nil;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TVncSessionTab.Start;
begin
  FTransport.Start;
  UpdateCaption;
end;

procedure TVncSessionTab.AttachTunnel(ATunnel: TSshTunnel;
  ABroker: TSshTunnelBroker);
begin
  FTunnel := ATunnel;
  FTunnelBroker := ABroker;
end;

procedure TVncSessionTab.BeginShutdown;
begin
  FClosing := True;
  FUserAbort := True;
  if FTransport <> nil then
    FTransport.BeginShutdown;
end;

procedure TVncSessionTab.RequestClose;
begin
  if FClosing then Exit;
  FClosing := True;
  Application.QueueAsyncCall(@DeferredClose, 0);
end;

procedure TVncSessionTab.FailDismiss(Sender: TObject);
begin
  RequestClose;
end;

procedure TVncSessionTab.ShowFailureOverlay;
var
  reason: string;
begin
  reason := FErrorMsg;
  if reason = '' then reason := 'Connection failed (no details available).';
  if FClipTimer <> nil then FClipTimer.Enabled := False;
  FFailPanel := TPanel.Create(Self);
  FFailPanel.Parent := Self;
  FFailPanel.Align := alClient;
  FFailPanel.BevelOuter := bvNone;
  FFailPanel.Color := clBlack;
  FFailPanel.OnClick := @FailDismiss;
  FFailLabel := TLabel.Create(FFailPanel);
  FFailLabel.Parent := FFailPanel;
  FFailLabel.Align := alClient;
  FFailLabel.Alignment := taCenter;
  FFailLabel.Layout := tlCenter;
  FFailLabel.WordWrap := True;
  FFailLabel.Font.Color := clRed;
  FFailLabel.Caption :=
    '✕  Connection failed' + LineEnding + LineEnding +
    reason + LineEnding + LineEnding +
    'Click here or close the tab to dismiss.';
  FFailLabel.OnClick := @FailDismiss;
  FFailPanel.BringToFront;
end;

procedure TVncSessionTab.InhibitReconnect;
begin
  if FTransport <> nil then
    FTransport.InhibitReconnect;
end;

function TVncSessionTab.ConfirmClose: Boolean;
begin
  if IsTerminalState(FState) then
    Exit(True);
  Result := QuestionDlg('Disconnect',
    Format('Disconnect from %s?', [FDisplayName]), mtConfirmation,
    [mrOK, 'Disconnect', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

procedure TVncSessionTab.FocusContent;
begin
  if (FView <> nil) and FView.CanFocus then
    FView.SetFocus;
end;

function TVncSessionTab.TabState: TRemoteSessionState;
begin
  Result := FState;
end;

function TVncSessionTab.TabIsFailedKept: Boolean;
begin
  Result := FFailedOpen;
end;

function TVncSessionTab.TabBarCaption: string;
begin
  Result := FDisplayName + ' — VNC';
end;

function TVncSessionTab.TabConnUuid: string;
begin
  Result := FConnUuid;
end;

function TVncSessionTab.GrabThumbnail: TBitmap;
begin
  if FView = nil then
    Exit(nil);
  Result := FView.Snapshot;
end;

procedure TVncSessionTab.ViewPointer(AX, AY, AButtonMask: Integer);
begin
  if FTransport <> nil then
    FTransport.SendPointer(AX, AY, AButtonMask);
end;

procedure TVncSessionTab.ViewKey(AKeysym: Cardinal; ADown: Boolean);
begin
  if FTransport <> nil then
    FTransport.SendKey(AKeysym, ADown);
end;

procedure TVncSessionTab.ViewEscapeCapture(Sender: TObject);
begin
  if (Parent <> nil) and (Parent is TWinControl) then
    if TWinControl(Parent).CanFocus then
      TWinControl(Parent).SetFocus;
end;

procedure TVncSessionTab.TransportState(ASender: TObject;
  AState: TRemoteSessionState);
begin
  Application.QueueAsyncCall(@AsyncState, PtrInt(AState));
end;

procedure TVncSessionTab.TransportClipboard(ASender: TObject;
  const AText: string);
begin
  if not FClipEnabled then Exit;
  FClipLock.Acquire;
  try
    FPendingClip := AText;
  finally
    FClipLock.Release;
  end;
  Application.QueueAsyncCall(@AsyncClipboard, 0);
end;

procedure TVncSessionTab.TransportResize(ASender: TObject;
  AWidth, AHeight: Integer);
begin
  Application.QueueAsyncCall(@AsyncResize, 0);
end;

procedure TVncSessionTab.TransportReconnect(ASender: TObject;
  const AMessage: string; AActive: Boolean);
begin
  FReconnectLock.Acquire;
  try
    FPendingReconnectMsg := AMessage;
    FPendingReconnectActive := AActive;
  finally
    FReconnectLock.Release;
  end;
  Application.QueueAsyncCall(@AsyncReconnect, 0);
end;

procedure TVncSessionTab.AsyncState(Data: PtrInt);
begin
  FState := TRemoteSessionState(Data);
  // Ligne de base, PAS un renvoi: sans elle le premier sondage expedierait au
  // serveur ce qui etait copie avant la session -- un mot de passe, en clair.
  if FState = rssConnected then
  begin
    FEverConnected := True;
    FClipBridge.PrimeBaseline;
  end;
  if FState = rssFailed then
  begin
    FErrorMsg := FTransport.LastError;
    if (FTunnel <> nil) and (FTunnel.LastError <> '') then
      FErrorMsg := FTunnel.LastError;
    if (FErrorMsg <> '') and Assigned(FOnNotice) then
      FOnNotice(Format('%s: %s', [FDisplayName, FErrorMsg]));
  end;
  UpdateCaption;
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
  if IsTerminalState(FState) then
  begin
    if (FState = rssFailed) and (not FEverConnected) and (not FUserAbort)
       and (not FClosing) then
    begin
      FFailedOpen := True;
      if FPaintTimer <> nil then FPaintTimer.Enabled := False;
      ShowFailureOverlay;
      if Assigned(FOnStatusChanged) then
        FOnStatusChanged(Self);
      Exit;
    end;
    FClosing := True;
    Application.QueueAsyncCall(@DeferredClose, 0);
  end;
end;

procedure TVncSessionTab.AsyncClipboard(Data: PtrInt);
var
  txt: string;
begin
  FClipLock.Acquire;
  try
    txt := FPendingClip;
    FPendingClip := '';
  finally
    FClipLock.Release;
  end;
  if txt = '' then Exit;
  // Memoriser AVANT d'ecrire, sinon le sondage local le renvoie: boucle d'echo.
  FClipBridge.NoteRemote(txt);
  Clipboard.AsText := txt;
end;

procedure TVncSessionTab.AsyncResize(Data: PtrInt);
begin
  if FView <> nil then
    FView.NotifyPainted;
end;

procedure TVncSessionTab.AsyncReconnect(Data: PtrInt);
var
  msg: string;
  active: Boolean;
begin
  FReconnectLock.Acquire;
  try
    msg := FPendingReconnectMsg;
    active := FPendingReconnectActive;
  finally
    FReconnectLock.Release;
  end;
  if active then
  begin
    FReconnectMsg := msg;
    if FClipTimer <> nil then FClipTimer.Enabled := False;
  end
  else
  begin
    FReconnectMsg := '';
    if (FClipTimer <> nil) and (FState = rssConnected) and (not FClosing) then
    begin
      FClipBridge.PrimeBaseline;
      FClipTimer.Enabled := True;
    end;
  end;
  UpdateCaption;
end;

procedure TVncSessionTab.ScrollResize(Sender: TObject);
begin
  if FView <> nil then
    FView.UpdateLayout;
end;

procedure TVncSessionTab.PaintTick(Sender: TObject);
begin
  if FView <> nil then
    FView.NotifyPainted;
end;

procedure TVncSessionTab.ClipPoll(Sender: TObject);
begin
  if (FTransport = nil) or (FState <> rssConnected) then Exit;
  FClipBridge.Poll;
end;

// False = echec franc; un presse-papiers vide est une reference valide.
function TVncSessionTab.TryReadClip(out AText: string): Boolean;
begin
  AText := '';
  try
    AText := Clipboard.AsText;
    Result := True;
  except
    Result := False;
  end;
end;

procedure TVncSessionTab.SendClipToServer(const AText: string);
begin
  if FTransport <> nil then
    FTransport.SendClipboard(AText);
end;

procedure TVncSessionTab.UpdateCaption;
var
  s: string;
begin
  if FReconnectMsg <> '' then
  begin
    Caption := '⟳ ' + FDisplayName + ' — ' + FReconnectMsg;
    Exit;
  end;
  case FState of
    rssCreated:        s := ' (…)';
    rssConnecting:     s := ' (connecting…)';
    rssAuthenticating: s := ' (auth…)';
    rssConnected:      s := '';
    rssDisconnecting:  s := ' (closing…)';
    rssDisconnected:   s := ' (closed)';
    rssFailed:         s := ' (failed)';
  end;
  Caption := FDisplayName + s;
end;

procedure TVncSessionTab.DeferredClose(Data: PtrInt);
begin
  Free;
end;

end.
