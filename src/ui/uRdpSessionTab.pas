unit uRdpSessionTab;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, Menus, Graphics,
  ExtCtrls, StdCtrls, Clipbrd, uRshDocument, uRdpControl, uRemoteSurface, uRdpTransport,
  uRdpKnownCerts, uSessionState, uSessionManager, uSessionTabBase,
  uClipboardBridge, uSshTunnel, uSshTunnelConnect;

type
  TRdpSessionTab = class;

  TRdpSessionHandle = class(TManagedSession)
  private
    FTab: TRdpSessionTab;
  public
    constructor Create(ATab: TRdpSessionTab);
    function SessionState: TRemoteSessionState; override;
    function DisplayName: string; override;
    procedure BeginShutdown; override;
  end;

  TRdpSessionTab = class(TSessionTabBase)
  private
    FScroll: TScrollBox;
    FView: TRottenRdpControl;
    FSurface: TRemoteSurface;
    FTransport: TRdpTransport;
    FKnownCerts: TRdpKnownCerts;
    // Libere APRES le transport.
    FTunnel: TSshTunnel;
    FTunnelBroker: TSshTunnelBroker;
    FManager: TSessionManager;
    FHandle: TRdpSessionHandle;
    FDisplayName: string;
    FConnUuid: string;
    FState: TRemoteSessionState;
    FErrorMsg: string;
    FClosing: Boolean;
    FLastReqW, FLastReqH: Integer;
    // Sans debounce, une reallocation par pixel du geste.
    FResizeTimer: TTimer;
    // Pas de notification presse-papiers sur Cocoa: on sonde.
    FClipTimer: TTimer;
    FClipBridge: TClipboardBridge;
    // Dernier CF_HDROP vu: ni echo vers le serveur, ni double envoi.
    FClipFilesSig: string;
    FFilesPrimed: Boolean;
    // Lot recu onglet cache. Si la sequence a bouge d'ici le retour, il n'est
    // PAS pose.
    FPendingFiles: TStringArray;
    FPendingSeq: LongWord;
    FReconnectMsg: string;
    // Un echec d'ETABLISSEMENT garde l'onglet ouvert avec sa raison.
    FEverConnected: Boolean;
    FUserAbort: Boolean;
    FFailedOpen: Boolean;
    FFailPanel: TPanel;
    FFailLabel: TLabel;

    procedure ViewMouse(AFlags: Integer; AX, AY: Integer);
    procedure ViewSyncLocks(Sender: TObject);
    procedure AppActivated(Sender: TObject);
    procedure ViewExtMouse(AFlags: Integer; AX, AY: Integer);
    procedure ViewKey(AFlags: Integer; ACode: Integer);
    procedure ViewEscapeCapture(Sender: TObject);
    procedure ScrollResize(Sender: TObject);
    procedure ResizeSettled(Sender: TObject);
    function ViewportW: Integer;
    function ViewportH: Integer;
    procedure RequestRemoteSize;
    procedure TransportState(AState: TRemoteSessionState);
    procedure TransportError(const AMessage: string);
    procedure TransportPaint;
    procedure TransportResized(AWidth, AHeight: Integer);
    procedure TransportFinished;
    procedure ClipboardFromRemote(const AText: UnicodeString);
    procedure ClipboardFilesFromRemote(const APaths: TStringArray);
    procedure ClipNoteFromTransport(const AText: string);
    {$IFDEF WINDOWS}
    function TryReadLocalFiles(out APaths: TStringArray): Boolean;
    function WriteLocalFiles(const APaths: TStringArray): Boolean;
    {$ENDIF}
    procedure PollLocalFiles;
    procedure ClipPoll(Sender: TObject);
    function TryReadLocalClipboard(out AText: string): Boolean;
    function WriteLocalClipboard(const AText: string): Boolean;
    procedure SendClipToServer(const AText: string);
    function ClipForeground: Boolean;
    procedure TransportReconnect(const AStatus: string; AActive: Boolean);
    procedure CertAsk(const AInfo: TRdpCertInfo; var ADecision: TRdpCertDecision);
    procedure CertLookup(const AHost: string; APort: Integer;
      const AFingerprint: string; out AVerdict: Integer;
      out AKnownFingerprint: string);
    procedure CertSave(const AInfo: TRdpCertInfo);
    procedure UpdateCaption;
    procedure DeferredClose(Data: PtrInt);
    procedure RequestClose;
    procedure ShowFailureOverlay;
    procedure FailDismiss(Sender: TObject);
    procedure TunnelFailed;
  public
    // Possede AParams.
    constructor CreateSession(APages: TPageControl; ADoc: TRshDocument;
      AManager: TSessionManager; const ADisplayName, AConnUuid: string;
      AParams: TRdpConnectParams);
    destructor Destroy; override;
    procedure AttachTunnel(ATunnel: TSshTunnel; ABroker: TSshTunnelBroker);

    procedure Start;
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure SendCtrlAltDel;
    procedure InhibitReconnect;
    procedure FocusContent; override;
    function GrabThumbnail: TBitmap; override;
    function TabState: TRemoteSessionState; override;
    function TabBarCaption: string; override;
    function TabConnUuid: string; override;
    function TabIsFailedKept: Boolean; override;

    property SessionState: TRemoteSessionState read FState;
    property SessionName: string read FDisplayName;
    property ConnectionUuid: string read FConnUuid;
    property View: TRottenRdpControl read FView;
  end;

implementation

uses
  uRdpCertDialog, uClipDropFiles, uRdpClipFiles;

var
  // Tous onglets confondus: ce qui vient du serveur A ne repart jamais vers B.
  // Thread UI seulement.
  GFilesRemoteSig: string = '';

function FilesSig(const APaths: TStringArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(APaths) do
    Result := Result + APaths[i] + #1;
end;

constructor TRdpSessionHandle.Create(ATab: TRdpSessionTab);
begin
  inherited Create;
  FTab := ATab;
end;

function TRdpSessionHandle.SessionState: TRemoteSessionState;
begin
  Result := FTab.SessionState;
end;

function TRdpSessionHandle.DisplayName: string;
begin
  Result := FTab.SessionName;
end;

procedure TRdpSessionHandle.BeginShutdown;
begin
  FTab.BeginShutdown;
end;

constructor TRdpSessionTab.CreateSession(APages: TPageControl;
  ADoc: TRshDocument; AManager: TSessionManager;
  const ADisplayName, AConnUuid: string;
  AParams: TRdpConnectParams);
begin
  inherited Create(APages);
  PageControl := APages;
  FDisplayName := ADisplayName;
  FConnUuid := AConnUuid;
  FState := rssCreated;
  FManager := AManager;
  FKnownCerts := TRdpKnownCerts.Create(ADoc);

  FSurface := TRemoteSurface.Create;

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;
  FScroll.AutoScroll := True;
  FScroll.HorzScrollBar.Tracking := True;
  FScroll.VertScrollBar.Tracking := True;
  FScroll.Color := clBlack;
  FScroll.OnResize := @ScrollResize;

  FResizeTimer := TTimer.Create(Self);
  FResizeTimer.Enabled := False;
  FResizeTimer.Interval := 250;
  FResizeTimer.OnTimer := @ResizeSettled;

  FClipTimer := TTimer.Create(Self);
  FClipTimer.Enabled := False;
  FClipTimer.Interval := 700;
  FClipTimer.OnTimer := @ClipPoll;
  // Le transport coupe a 2 Mo d'unites UTF-16, jusqu'a 3 octets UTF-8 chacune.
  FClipBridge := TClipboardBridge.Create(
    @TryReadLocalClipboard, @SendClipToServer, 3 * 2 * 1024 * 1024,
    @ClipForeground);

  FView := TRottenRdpControl.Create(Self);
  FView.Parent := FScroll;
  FView.SetBounds(0, 0, 800, 600);
  FView.AttachSurface(FSurface);
  FView.OnMouseEvent := @ViewMouse;
  FView.OnExtMouseEvent := @ViewExtMouse;
  FView.OnKeyEvent := @ViewKey;
  FView.OnEscapeCapture := @ViewEscapeCapture;
  FView.OnSyncLocks := @ViewSyncLocks;
  Application.AddOnActivateHandler(@AppActivated);

  FTransport := TRdpTransport.Create(AParams, FSurface);
  FTransport.OnStateChanged := @TransportState;
  FTransport.OnError := @TransportError;
  FTransport.OnPaint := @TransportPaint;
  FTransport.OnResized := @TransportResized;
  FTransport.OnFinished := @TransportFinished;
  FTransport.OnCertificate := @CertAsk;
  FTransport.OnCertLookup := @CertLookup;
  FTransport.OnCertSave := @CertSave;
  FTransport.OnClipboardText := @ClipboardFromRemote;
  FTransport.OnClipboardFiles := @ClipboardFilesFromRemote;
  FTransport.OnClipNote := @ClipNoteFromTransport;
  FTransport.OnReconnect := @TransportReconnect;

  FHandle := TRdpSessionHandle.Create(Self);
  FManager.RegisterSession(FHandle);

  UpdateCaption;
end;

destructor TRdpSessionTab.Destroy;
var
  cb: TNotifyEvent;
begin
  FClosing := True;
  Application.RemoveOnActivateHandler(@AppActivated);
  if (FManager <> nil) and (FHandle <> nil) then
    FManager.UnregisterSession(FHandle);
  if FTransport <> nil then
  begin
    FTransport.Shutdown;
    FTransport.Free;
    FTransport := nil;
  end;
  // La fin de session a pu deposer un DeferredClose: il tirerait a vide.
  Application.RemoveAsyncCalls(Self);
  if FTunnel <> nil then
  begin
    FTunnel.Shutdown;
    FTunnel.Free;
    FTunnel := nil;
  end;
  FreeAndNil(FTunnelBroker);
  FreeAndNil(FHandle);
  FreeAndNil(FSurface);
  FreeAndNil(FKnownCerts);
  FreeAndNil(FClipBridge);
  cb := FOnDestroyed;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TRdpSessionTab.AttachTunnel(ATunnel: TSshTunnel;
  ABroker: TSshTunnelBroker);
begin
  FTunnel := ATunnel;
  FTunnelBroker := ABroker;
  // Notifie directement: freerdp_connect retente en interne, l'onglet resterait noir.
  if FTunnel <> nil then
    FTunnel.OnAsyncError := @TunnelFailed;
end;

procedure TRdpSessionTab.TunnelFailed;
begin
  if FEverConnected or FFailedOpen or FClosing then Exit;
  if FTunnel <> nil then
    FErrorMsg := FTunnel.LastError;
  FFailedOpen := True;
  ShowFailureOverlay;
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
  if Assigned(FOnNotice) and (FErrorMsg <> '') then
    FOnNotice(Format('%s: %s', [FDisplayName, FErrorMsg]));
  if FTransport <> nil then
    FTransport.Shutdown;
end;

procedure TRdpSessionTab.Start;
begin
  FTransport.Start;
end;

procedure TRdpSessionTab.UpdateCaption;
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
  Caption := mark + FDisplayName + ' — RDP';
  if FReconnectMsg <> '' then
    Caption := '⟳ ' + FDisplayName + ' — ' + FReconnectMsg;
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

procedure TRdpSessionTab.ViewMouse(AFlags: Integer; AX, AY: Integer);
begin
  if FTransport <> nil then
    FTransport.SendMouse(AFlags, AX, AY);
end;

procedure TRdpSessionTab.ViewExtMouse(AFlags: Integer; AX, AY: Integer);
begin
  if FTransport <> nil then
    FTransport.SendExtendedMouse(AFlags, AX, AY);
end;

procedure TRdpSessionTab.ViewKey(AFlags: Integer; ACode: Integer);
begin
  if FTransport <> nil then
    FTransport.SendScancode(AFlags, ACode);
end;

procedure TRdpSessionTab.ViewSyncLocks(Sender: TObject);
begin
  if (FTransport <> nil) and (FState = rssConnected) then
    FTransport.SendSynchronize(FView.LockFlags);
end;

// Retour d'Alt+Tab: le focus revient SANS DoEnter, les verrous resteraient faux.
procedure TRdpSessionTab.AppActivated(Sender: TObject);
begin
  if FClosing or (FView = nil) then Exit;
  if FView.Focused or (Screen.ActiveControl = FView) then
    ViewSyncLocks(nil);
end;

procedure TRdpSessionTab.ViewEscapeCapture(Sender: TObject);
begin
  if (Parent <> nil) and (Parent is TWinControl) then
    if TWinControl(Parent).CanFocus then
      TWinControl(Parent).SetFocus;
end;

function TRdpSessionTab.ViewportW: Integer;
begin
  Result := FScroll.ClientWidth and (not 1);
  if Result < REMOTE_MIN_WIDTH then Result := REMOTE_MIN_WIDTH;
  if Result > REMOTE_MAX_WIDTH then Result := REMOTE_MAX_WIDTH;
end;

function TRdpSessionTab.ViewportH: Integer;
begin
  Result := FScroll.ClientHeight and (not 1);
  if Result < REMOTE_MIN_HEIGHT then Result := REMOTE_MIN_HEIGHT;
  if Result > REMOTE_MAX_HEIGHT then Result := REMOTE_MAX_HEIGHT;
end;

procedure TRdpSessionTab.RequestRemoteSize;
var
  w, h: Integer;
begin
  if (FTransport = nil) or (FState <> rssConnected) then
    Exit;
  w := ViewportW;
  h := ViewportH;
  if (w = FLastReqW) and (h = FLastReqH) then
    Exit;
  FLastReqW := w;
  FLastReqH := h;
  FTransport.RequestResize(w, h);
end;

procedure TRdpSessionTab.ScrollResize(Sender: TObject);
begin
  FResizeTimer.Enabled := False;
  FResizeTimer.Enabled := True;
end;

procedure TRdpSessionTab.ResizeSettled(Sender: TObject);
begin
  FResizeTimer.Enabled := False;
  RequestRemoteSize;
end;

procedure TRdpSessionTab.InhibitReconnect;
begin
  if FTransport <> nil then
    FTransport.InhibitReconnect;
end;

procedure TRdpSessionTab.SendCtrlAltDel;
begin
  if FTransport <> nil then
    FTransport.SendCtrlAltDel;
end;

procedure TRdpSessionTab.FocusContent;
begin
  if (FView <> nil) and FView.CanFocus then
    FView.SetFocus;
end;

function TRdpSessionTab.TabState: TRemoteSessionState;
begin
  Result := FState;
end;

function TRdpSessionTab.TabIsFailedKept: Boolean;
begin
  Result := FFailedOpen;
end;

function TRdpSessionTab.TabBarCaption: string;
begin
  Result := FDisplayName + ' — RDP';
end;

function TRdpSessionTab.TabConnUuid: string;
begin
  Result := FConnUuid;
end;

function TRdpSessionTab.GrabThumbnail: TBitmap;
begin
  Result := nil;
  if FView <> nil then
    Result := FView.Snapshot;
end;

procedure TRdpSessionTab.TransportState(AState: TRemoteSessionState);
begin
  FState := AState;
  UpdateCaption;
  if AState = rssConnected then
  begin
    FEverConnected := True;
    if FView.CanFocus then
      FView.SetFocus;
    FLastReqW := 0;
    FLastReqH := 0;
    RequestRemoteSize;
    // le focus a pu arriver AVANT la connexion
    ViewSyncLocks(nil);
    if (FTransport <> nil) and FTransport.ClipboardTextEnabled then
    begin
      // Sinon le premier sondage offre au serveur ce qui trainait avant.
      FClipBridge.PrimeBaseline;
      FFilesPrimed := False;
      FClipTimer.Enabled := True;
    end;
  end
  else
    FClipTimer.Enabled := False;
end;

procedure TRdpSessionTab.TransportError(const AMessage: string);
begin
  FErrorMsg := AMessage;
  if (FTunnel <> nil) and (FTunnel.LastError <> '') then
    FErrorMsg := FTunnel.LastError;
end;

procedure TRdpSessionTab.TransportPaint;
begin
  FView.NotifyPainted;
end;

procedure TRdpSessionTab.TransportResized(AWidth, AHeight: Integer);
begin
  FView.NotifyPainted;
end;

procedure TRdpSessionTab.CertAsk(const AInfo: TRdpCertInfo;
  var ADecision: TRdpCertDecision);
begin
  ADecision := AskRdpCertificate(AInfo);
end;

procedure TRdpSessionTab.CertLookup(const AHost: string; APort: Integer;
  const AFingerprint: string; out AVerdict: Integer;
  out AKnownFingerprint: string);
var
  e: TRdpCertEntry;
  v: TRdpCertVerdict;
begin
  AVerdict := 0;
  AKnownFingerprint := '';
  v := FKnownCerts.Verify(AHost, APort, AFingerprint, e);
  case v of
    rcvMatch:
      begin
        AVerdict := 1;
        FKnownCerts.TouchSeen(AHost, APort);
      end;
    rcvChanged:
      begin
        AVerdict := 2;
        AKnownFingerprint := e.Fingerprint;
      end;
  end;
end;

procedure TRdpSessionTab.CertSave(const AInfo: TRdpCertInfo);
begin
  FKnownCerts.Remember(AInfo.Host, AInfo.Port, AInfo.Fingerprint,
    AInfo.CommonName);
end;

procedure TRdpSessionTab.TransportReconnect(const AStatus: string;
  AActive: Boolean);
begin
  if AActive then
  begin
    FReconnectMsg := AStatus;
    FClipTimer.Enabled := False;
  end
  else
  begin
    FReconnectMsg := '';
    if (FTransport <> nil) and FTransport.ClipboardTextEnabled then
      FClipTimer.Enabled := True;
    ViewSyncLocks(nil);   // session rebatie: le serveur a oublie les verrous
  end;
  UpdateCaption;
end;

procedure TRdpSessionTab.ClipboardFromRemote(const AText: UnicodeString);
var
  u: string;
begin
  if AText = '' then
    Exit;
  u := UTF8Encode(AText);
  FClipBridge.NoteRemote(u, @WriteLocalClipboard);
end;

function TRdpSessionTab.WriteLocalClipboard(const AText: string): Boolean;
begin
  Result := False;
  try
    Clipboard.AsText := AText;
    Result := True;
  except
  end;
end;

// False = echec franc; un presse-papiers vide est une reference valide.
function TRdpSessionTab.TryReadLocalClipboard(out AText: string): Boolean;
begin
  AText := '';
  try
    if Clipboard.HasFormat(CF_TEXT) then
      AText := Clipboard.AsText;
    Result := True;
  except
    Result := False;
  end;
end;

procedure TRdpSessionTab.SendClipToServer(const AText: string);
begin
  if FTransport <> nil then
    FTransport.AnnounceLocalClipboard(UTF8Decode(AText));
end;

// Un onglet cache n'annonce rien: ce que A vient de poser partirait chez B.
function TRdpSessionTab.ClipForeground: Boolean;
begin
  Result := (PageControl <> nil) and (PageControl.ActivePage = Self);
end;

procedure TRdpSessionTab.ClipPoll(Sender: TObject);
var
  pending: TStringArray;
begin
  if (FTransport = nil) or (FState <> rssConnected) then
    Exit;
  if (Length(FPendingFiles) > 0) and ClipForeground then
  begin
    pending := FPendingFiles;
    FPendingFiles := nil;
    if ClipSequence = FPendingSeq then
      ClipboardFilesFromRemote(pending)
    else if Assigned(FOnNotice) then
      FOnNotice(Format('%s: the clipboard changed while this tab was in ' +
        'the background; the remote files were not placed on it.',
        [FDisplayName]));
  end;
  FClipBridge.Poll;
  PollLocalFiles;
end;

// Presse-papiers verrouille: retente au tick suivant.
procedure TRdpSessionTab.PollLocalFiles;
{$IFDEF WINDOWS}
var
  paths: TStringArray;
  sig: string;
begin
  if not TryReadLocalFiles(paths) then
    Exit;
  sig := FilesSig(paths);
  if not FFilesPrimed then
  begin
    FClipFilesSig := sig;
    FFilesPrimed := True;
    Exit;
  end;
  if sig = FClipFilesSig then
    Exit;
  // Ni envoi ni adoption: la copie partira au retour au premier plan.
  if not ClipForeground then
    Exit;
  FClipFilesSig := sig;
  if Length(paths) = 0 then
    Exit;
  if (GFilesRemoteSig <> '') and (sig = GFilesRemoteSig) then
    Exit;   // recu d'un serveur: adopte, jamais retransmis
  // Refus MOTIVE, pas de troncature muette. Signature adoptee: un seul message.
  if Length(paths) > RDPCLIP_MAX_FILES then
  begin
    if Assigned(FOnNotice) then
      FOnNotice(Format('%s: more than %d items on the clipboard; they were ' +
        'not offered to the remote desktop.',
        [FDisplayName, RDPCLIP_MAX_FILES]));
    Exit;
  end;
  FTransport.AnnounceLocalFiles(paths);
end;
{$ELSE}
begin
end;
{$ENDIF}

// Provenance marquee AVANT l'ecriture, sinon le sondage suivant le renvoie.
procedure TRdpSessionTab.ClipboardFilesFromRemote(const APaths: TStringArray);
{$IFDEF WINDOWS}
var
  sig, prevSig, prevRemote: string;
  prevPrimed: Boolean;
begin
  if Length(APaths) = 0 then
    Exit;
  if not ClipForeground then
  begin
    // Poser maintenant ecraserait ce que l'utilisateur manipule AILLEURS.
    FPendingFiles := APaths;
    FPendingSeq := ClipSequence;
    if Assigned(FOnNotice) then
      FOnNotice(Format('%s: the remote files are ready; they will be placed ' +
        'on the clipboard when you come back to this tab.', [FDisplayName]));
    Exit;
  end;
  sig := FilesSig(APaths);
  prevSig := FClipFilesSig;
  prevPrimed := FFilesPrimed;
  prevRemote := GFilesRemoteSig;
  FClipFilesSig := sig;
  FFilesPrimed := True;
  GFilesRemoteSig := sig;
  if not WriteLocalFiles(APaths) then
  begin
    FClipFilesSig := prevSig;
    FFilesPrimed := prevPrimed;
    GFilesRemoteSig := prevRemote;
    if Assigned(FOnNotice) then
      FOnNotice(Format('%s: the remote files could not be placed on the ' +
        'clipboard.', [FDisplayName]));
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

procedure TRdpSessionTab.ClipNoteFromTransport(const AText: string);
begin
  if Assigned(FOnNotice) then
    FOnNotice(Format('%s: %s', [FDisplayName, AText]));
end;

{$IFDEF WINDOWS}
function TRdpSessionTab.TryReadLocalFiles(out APaths: TStringArray): Boolean;
begin
  Result := ClipReadHdrop(APaths);
end;

function TRdpSessionTab.WriteLocalFiles(const APaths: TStringArray): Boolean;
begin
  Result := ClipWriteHdrop(APaths);
end;
{$ENDIF}

procedure TRdpSessionTab.TransportFinished;
begin
  FState := FTransport.State;
  FClipTimer.Enabled := False;
  UpdateCaption;
  if FFailedOpen then Exit;
  if (FErrorMsg <> '') and Assigned(FOnNotice) then
    FOnNotice(Format('%s: %s', [FDisplayName, FErrorMsg]));
  if (FState = rssFailed) and (not FEverConnected) and (not FUserAbort)
     and (not FClosing) then
  begin
    FFailedOpen := True;
    ShowFailureOverlay;
    if Assigned(FOnStatusChanged) then
      FOnStatusChanged(Self);
    Exit;
  end;
  // Differe: on scie la branche du transport sur laquelle on est assis.
  if not FClosing then
  begin
    FClosing := True;
    Application.QueueAsyncCall(@DeferredClose, 0);
  end;
end;

procedure TRdpSessionTab.DeferredClose(Data: PtrInt);
begin
  Free;
end;

procedure TRdpSessionTab.BeginShutdown;
begin
  FUserAbort := True;
  if FTransport <> nil then
    FTransport.Shutdown;
end;

procedure TRdpSessionTab.RequestClose;
begin
  if FClosing then Exit;
  FClosing := True;
  Application.QueueAsyncCall(@DeferredClose, 0);
end;

procedure TRdpSessionTab.FailDismiss(Sender: TObject);
begin
  RequestClose;
end;

procedure TRdpSessionTab.ShowFailureOverlay;
var
  reason: string;
begin
  reason := FErrorMsg;
  if reason = '' then reason := 'Connection failed (no details available).';
  FClipTimer.Enabled := False;
  FResizeTimer.Enabled := False;
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

function TRdpSessionTab.ConfirmClose: Boolean;
begin
  if IsTerminalState(FState) then
    Exit(True);
  Result := QuestionDlg('Disconnect',
    Format('Disconnect from %s?', [FDisplayName]), mtConfirmation,
    [mrOK, 'Disconnect', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

end.
