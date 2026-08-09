unit uFrmMain;

{$mode objfpc}{$H+}

// Fenetre principale, construite par code (pas de .lfm): document .rsh,
// arborescence, onglets de session SSH/RDP/VNC.

interface

uses
  Classes, SysUtils, Forms, Controls, Menus, ComCtrls, ExtCtrls, StdCtrls,
  Graphics, LCLType, LMessages, uRshDocument, uRshModel, uSessionManager,
  uSessionState, uSessionTabBase, uSshSessionTab, uSshTransport,
  uRdpSessionTab, uVncSessionTab, uVncConnect, uClusterSshTab, uCrashRecovery,
  uSessionTabBar, uSearchBox, uTreeScrollBar, uImportExport, uGroupDashboard,
  uTabSweep, uRecent
  {$IFNDEF DARWIN}, uMenuBar{$ENDIF};

type
  TNodeRef = class
  public
    Uuid: string;
    Kind: TNodeKind;
    constructor Create(const AUuid: string; AKind: TNodeKind);
  end;

  TfrmMain = class(TForm, ITabList)
  private
    FMenu: TMainMenu;
    {$IFNDEF DARWIN}
    FMenuBar: TRSMenuBar;
    {$ENDIF}
    FLeftPanel: TPanel;
    FSearchBox: TRottenSearchBox;
    FTree: TScrollTreeView;
    FTreeScroll: TTreeScrollBar;
    FSplitter: TSplitter;
    FSessionPanel: TPanel;
    FTabBar: TSessionTabBar;
    FPages: TPageControl;
    FStatusBar: TStatusBar;
    FTreePopup: TPopupMenu;
    FTreeImages: TImageList;
    FDoc: TRshDocument;
    FModel: TRshModel;
    FSessions: TSessionManager;
    // Un etablissement de session pompe la boucle de messages: toute commande
    // qui libererait FDoc/FModel s'abstient (UAF). Idem pendant BruteForceDelay.
    FConnecting: Boolean;
    FPwDelay: Boolean;
    FMiSave, FMiSaveAs, FMiIntegrity, FMiClose, FMiChangePw: TMenuItem;
    FMiLock: TMenuItem;
    FLockPanel: TPanel;
    FLockLabel: TLabel;
    FMiRename, FMiDuplicate, FMiDelete, FMiFind: TMenuItem;
    FMiExpandAll, FMiCollapseAll: TMenuItem;
    FMiConnect, FMiDisconnect, FMiCtrlAltDel: TMenuItem;
    FMiFavorites, FMiRecent: TMenuItem;   // connexions, menu Connection
    FMiOpenRecent: TMenuItem;             // documents .rsh, menu File
    FMiImport, FMiExport, FMiCredMgr: TMenuItem;
    FMiScreenshot: TMenuItem;
    FMiDashboard: TMenuItem;
    FDashboard: TGroupDashboard;
    FMiLogEnabled, FMiLogDebug, FMiLogConfidential: TMenuItem;
    FPwFailCount: Integer;
    FEditRequested: Boolean;
    FRecoveryChecked: Boolean;
    FShortcutsSuspended: Boolean;
    FSavedShortcutItems: array of TMenuItem;
    FSavedShortcutKeys: array of TShortCut;
    procedure ActiveControlChanged(Sender: TObject; LastControl: TControl);
    procedure SetSessionKeyCapture(ACaptured: Boolean);
    procedure SessionEscapeCapture(Sender: TObject);
    procedure BuildMenu;
    procedure BuildUI;
    function AddItem(AParent: TMenuItem; const ACaption: string;
      AShortCut: TShortCut; AEnabled: Boolean;
      AHandler: TNotifyEvent): TMenuItem;
    procedure UpdateDocumentState;
    procedure LockDocClick(Sender: TObject);
    procedure UnlockClick(Sender: TObject);
    procedure UpdateLockState;
    procedure ConnMenuNeeded(Sender: TObject);
    procedure FileMenuNeeded(Sender: TObject);
    procedure OpenDocumentPath(const APath: string);
    procedure OpenRecentClick(Sender: TObject);
    procedure ClearOpenRecentClick(Sender: TObject);
    procedure RebuildQuickMenu(AParent: TMenuItem; AList: TRshQuickList;
      AShowWhen: Boolean);
    procedure QuickEntryClick(Sender: TObject);
    procedure ToggleFavoriteClick(Sender: TObject);
    procedure ClearRecentClick(Sender: TObject);
    procedure ConnectByUuid(const AConnUuid: string);
    procedure ImportOpenSshClick(Sender: TObject);
    procedure ImportJsonClick(Sender: TObject);
    procedure ImportHostsCsvClick(Sender: TObject);
    procedure ExportJsonClick(Sender: TObject);
    procedure ExportCsvClick(Sender: TObject);
    procedure DoExport(AFormat: TExportFormat; const AExt, AFilter: string);
    procedure ShowImportReport(var AReport: TImportReport);
    function ImportTargetUuid: string;
    procedure DashboardClick(Sender: TObject);
    procedure DashboardClosed(Sender: TObject; var CloseAction: TCloseAction);
    function DashSessionState(const AConnUuid: string): string;
    procedure CloseDashboard;
    procedure RecordAttempt(const AConnUuid: string; AResult: TSessionResult);
    function FavoriteMark(ANode: TRshNode): string;
    procedure BuildLockPanel;
    procedure InhibitAllReconnects;
    function RawCount: Integer;
    function RawItem(AIndex: Integer): Pointer;
    function IsSessionTab(APtr: Pointer): Boolean;
    function VisitBeginShutdownUnsettled(APtr: Pointer): Boolean;
    function VisitFreeUnsettled(APtr: Pointer): Boolean;
    function ConfirmCloseAllSessions: Boolean;
    function VisitFree(APtr: Pointer): Boolean;
    procedure DisconnectUnsettledSessions;
    procedure ShowDocError(const AErr: TDocError);
    procedure ShowModelError(const AMsg: string);
    procedure BruteForceDelay;
    function DocCommandsBusy: Boolean;
    function ConfirmCloseCurrent: Boolean;
    procedure BuildTree;
    function SelectedRef: TNodeRef;
    function SelectedUuid: string;
    procedure SelectNodeByUuid(const AUuid: string);
    procedure TreeDeletion(Sender: TObject; Node: TTreeNode);
    // le TTreeView Cocoa ignore Font.Color: on repeint le texte en post-paint
    procedure TreeAdvancedDrawItem(Sender: TCustomTreeView; Node: TTreeNode;
      State: TCustomDrawState; Stage: TCustomDrawStage;
      var PaintImages, DefaultDraw: Boolean);
    {$IFDEF WINDOWS}
    // la StatusBar native Win32 ignore Font.Color: illisible en theme sombre
    procedure StatusDrawPanel(AStatusBar: TStatusBar; APanel: TStatusPanel;
      const ARect: TRect);
    {$ENDIF}
    function HasOpenSessionForConn(const AConnUuid: string): Boolean;
    procedure TreePopupNeeded(Sender: TObject);
    procedure TreeKeyDown(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure TreeDblClick(Sender: TObject);
    procedure TreeSelectionChanged(Sender: TObject);
    procedure TreeEditing(Sender: TObject; Node: TTreeNode;
      var AllowEdit: Boolean);
    procedure TreeEditingEnd(Sender: TObject; Node: TTreeNode;
      Cancel: Boolean);
    procedure TreeEdited(Sender: TObject; Node: TTreeNode; var S: string);
    procedure TreeDragOver(Sender, Source: TObject; X, Y: Integer;
      State: TDragState; var Accept: Boolean);
    procedure TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
    procedure SearchChanged(Sender: TObject);
    procedure SearchEscape(Sender: TObject);
    procedure AddGroupClick(Sender: TObject);
    procedure AddSshClick(Sender: TObject);
    procedure AddRdpClick(Sender: TObject);
    procedure AddVncClick(Sender: TObject);
    procedure AddContainerClick(Sender: TObject);
    procedure AddPodClick(Sender: TObject);
    procedure ConnectAllInFolderClick(Sender: TObject);
    procedure DisconnectAllInFolderClick(Sender: TObject);
    procedure ClusterSshClick(Sender: TObject);
    function GroupNameOf(const AUuid: string): string;
    function ExistingVncTab(const AConnUuid: string): TVncSessionTab;
    function SessionTabConnUuid(APage: TTabSheet): string;
    procedure SessionTabShutdown(APage: TTabSheet);
    function SessionTabCountIn(APage: TTabSheet; AUuids: TStrings): Integer;
    procedure SessionTabShutdownIn(APage: TTabSheet; AUuids: TStrings);
    function CountLiveSessionsIn(AUuids: TStrings): Integer;
    function CountLiveSessionsInNode(const AUuid: string;
      AIsGroup: Boolean): Integer;
    procedure RenameClick(Sender: TObject);
    procedure DuplicateClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    function NodeProtocol(const AUuid: string): TRshProtocol;
    procedure PropertiesClick(Sender: TObject);
    procedure ChangeIconClick(Sender: TObject);
    procedure CopyHostnameClick(Sender: TObject);
    procedure CopyUsernameClick(Sender: TObject);
    procedure ExpandAllClick(Sender: TObject);
    procedure CollapseAllClick(Sender: TObject);
    procedure FindClick(Sender: TObject);
    procedure LocalTerminalClick(Sender: TObject);
    procedure CredentialManagerClick(Sender: TObject);
    procedure CopySshIdClick(Sender: TObject);
    procedure TerminalFontClick(Sender: TObject);
    procedure TakeScreenshotClick(Sender: TObject);
    procedure ThemeClick(Sender: TObject);
    procedure ApplyThemeToUi;
    procedure RebuildTreeImages;
    function SearchFilter: string;
    procedure LogEnabledClick(Sender: TObject);
    procedure LogDebugClick(Sender: TObject);
    procedure LogConfidentialClick(Sender: TObject);
    procedure OpenLogFolderClick(Sender: TObject);
    procedure ConnectClick(Sender: TObject);
    procedure DisconnectClick(Sender: TObject);
    procedure SessionNotice(const AMessage: string);
    procedure SessionTabGone(Sender: TObject);
    procedure PagesChange(Sender: TObject);
    function CurrentSessionTab: TSshSessionTab;
    function CurrentRdpTab: TRdpSessionTab;
    function ExistingRdpTab(const AConnUuid: string): TRdpSessionTab;
    function HasActiveSessionTab: Boolean;
    procedure TabBarInfo(APage: TTabSheet; out AName: string;
      out AGlyph: TTabGlyphKind);
    procedure TabBarActivate(APage: TTabSheet);
    procedure TabBarClose(APage: TTabSheet);
    function TabBarThumb(APage: TTabSheet): TBitmap;
    procedure SessionStatusChanged(Sender: TObject);
    procedure CtrlAltDelClick(Sender: TObject);
    function CloseAllSessions(AAsk: Boolean): Boolean;
    procedure UpdateSessionUi;
    procedure NewDocClick(Sender: TObject);
    procedure OpenDocClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SaveAsClick(Sender: TObject);
    function SaveAsInteractive: Boolean;
    function UnlockInteractive: Boolean;
    function NormalizeRshSaveName(var APath: string): Boolean;
    procedure ChangePasswordClick(Sender: TObject);
    procedure IntegrityClick(Sender: TObject);
    procedure CloseDocClick(Sender: TObject);
    procedure QuitClick(Sender: TObject);
    procedure AboutClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormShow(Sender: TObject);
    procedure CheckCrashRecovery;
    procedure RecoverAsCurrent(const AItem: TRecoveryItem);
    function RecoverToFile(const AItem: TRecoveryItem): Boolean;
    procedure HandleAppException(Sender: TObject; E: Exception);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    {$IFNDEF DARWIN}
    // la LCL n'interroge pas les popups de la barre custom: on dispatch nous-memes
    function IsShortcut(var Message: TLMKey): Boolean; override;
    {$ENDIF}
  end;

var
  frmMain: TfrmMain;

implementation

uses
  Math, Dialogs, Clipbrd, LCLIntf, LazFileUtils, uTheme, uAbout, uVersion,
  uPasswordDialog, uTreeIcons, uIconPicker, uNodeDialogs, uLocalTermTab,
  uSshConnect, uSafeSave, uRdpConnect, uPrefsDialog, uPreferences, uLog,
  uCrashRecoveryDialog, uThemeLoad, uTermControl, uRdpControl, uVncControl,
  uSshKnownHosts, uHostKeyDialog, uContainerConnect, uContainerDialog,
  uPodConnect, uPodDialog, uSshTunnel, uSshTunnelConnect, uAppPaths,
  uCredManagerWindow, uSshCopyIdConnect, uSecretClipGuard, LazUTF8;

function PlatformShortCut(AKey: Word; AShift: Boolean = False): TShortCut;
var
  st: TShiftState;
begin
  {$IFDEF DARWIN}
  st := [ssMeta];
  {$ELSE}
  st := [ssCtrl];
  {$ENDIF}
  if AShift then Include(st, ssShift);
  Result := ShortCut(AKey, st);
end;

constructor TNodeRef.Create(const AUuid: string; AKind: TNodeKind);
begin
  inherited Create;
  Uuid := AUuid;
  Kind := AKind;
end;

constructor TfrmMain.Create(TheOwner: TComponent);
begin
  inherited CreateNew(TheOwner, 0);
  Caption := RSSH_APP_NAME;
  Width := 1000;
  Height := 640;
  Position := poScreenCenter;
  WindowState := wsMaximized;
  Constraints.MinWidth := 480;
  Constraints.MinHeight := 320;
  FSessions := TSessionManager.Create;
  FTreeImages := BuildTreeImageList(Self, Screen.PixelsPerInch);
  BuildMenu;
  BuildUI;
  ApplyUiFont(Self);
  ApplyThemeToUi;
  OnCloseQuery := @FormCloseQuery;
  OnShow := @FormShow;
  Application.OnException := @HandleAppException;
  Screen.AddHandlerActiveControlChanged(@ActiveControlChanged);
  UpdateDocumentState;
end;

destructor TfrmMain.Destroy;
begin
  Screen.RemoveHandlerActiveControlChanged(@ActiveControlChanged);
  // onglets et dashboard empruntent FDoc/FModel: ils meurent d'abord
  CloseAllSessions(False);
  CloseDashboard;
  FreeAndNil(FSessions);
  FreeAndNil(FModel);
  FreeAndNil(FDoc);
  inherited Destroy;
end;

{$IFNDEF DARWIN}
function TfrmMain.IsShortcut(var Message: TLMKey): Boolean;
begin
  Result := inherited IsShortcut(Message);
  if (not Result) and (FMenuBar <> nil) then
    Result := FMenuBar.DispatchShortcut(Message);
end;
{$ENDIF}

function TfrmMain.AddItem(AParent: TMenuItem; const ACaption: string;
  AShortCut: TShortCut; AEnabled: Boolean; AHandler: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := ACaption;
  Result.ShortCut := AShortCut;
  Result.Enabled := AEnabled;
  Result.OnClick := AHandler;
  AParent.Add(Result);
end;

procedure TfrmMain.ActiveControlChanged(Sender: TObject; LastControl: TControl);
var
  ctl: TWinControl;
begin
  ctl := Screen.ActiveControl;
  SetSessionKeyCapture((ctl is TRottenTerminalControl) or
    (ctl is TRottenRdpControl) or (ctl is TRottenVncControl));
end;

procedure TfrmMain.SetSessionKeyCapture(ACaptured: Boolean);
var
  i: Integer;

  procedure Sweep(AItem: TMenuItem);
  var
    j, n: Integer;
  begin
    if AItem.ShortCut <> 0 then
    begin
      n := Length(FSavedShortcutItems);
      SetLength(FSavedShortcutItems, n + 1);
      SetLength(FSavedShortcutKeys, n + 1);
      FSavedShortcutItems[n] := AItem;
      FSavedShortcutKeys[n] := AItem.ShortCut;
      AItem.ShortCut := 0;   // la LCL Cocoa retire le keyEquivalent natif
    end;
    for j := 0 to AItem.Count - 1 do
      Sweep(AItem.Items[j]);
  end;

begin
  if ACaptured = FShortcutsSuspended then Exit;
  FShortcutsSuspended := ACaptured;
  if ACaptured then
  begin
    FSavedShortcutItems := nil;
    FSavedShortcutKeys := nil;
    Sweep(FMenu.Items);
    {$IFNDEF DARWIN}
    if FMenuBar <> nil then
      for i := 0 to FMenuBar.MenuCount - 1 do
        Sweep(FMenuBar.MenuRoot(i));
    {$ENDIF}
  end
  else
  begin
    for i := 0 to High(FSavedShortcutItems) do
      FSavedShortcutItems[i].ShortCut := FSavedShortcutKeys[i];
    FSavedShortcutItems := nil;
    FSavedShortcutKeys := nil;
  end;
  if (FStatusBar <> nil) and (FStatusBar.Panels.Count > 2) then
  begin
    if ACaptured then
      FStatusBar.Panels[2].Text :=
        'Keyboard captured: Ctrl+Alt+Enter to release'
    else
      FStatusBar.Panels[2].Text := '';
  end;
end;

procedure TfrmMain.SessionEscapeCapture(Sender: TObject);
begin
  if (FTree <> nil) and FTree.CanFocus then
    FTree.SetFocus
  else
    SetFocus;
end;

procedure TfrmMain.BuildMenu;
var
  mFile, mEdit, mView, mConn, mTools, mHelp, mDiag, mTheme, mi: TMenuItem;
  i: Integer;
begin
  FMenu := TMainMenu.Create(Self);
  {$IFDEF DARWIN}
  Menu := FMenu;
  {$ELSE}
  // la LCL auto-assigne tout TMainMenu dont l'Owner est la fenetre: sans cette
  // annulation, le menu natif s'affiche EN PLUS de la barre custom
  Menu := nil;
  {$ENDIF}

  mFile := TMenuItem.Create(FMenu);
  mFile.Caption := '&File';
  FMenu.Items.Add(mFile);

  AddItem(mFile, 'New Document…', PlatformShortCut(VK_N), True, @NewDocClick);
  AddItem(mFile, 'Open Document…', PlatformShortCut(VK_O), True, @OpenDocClick);
  // peuple a l'ouverture du menu File (FileMenuNeeded), comme les connexions
  // recentes le font a l'ouverture du menu Connection
  FMiOpenRecent := AddItem(mFile, 'Open Recent', 0, False, nil);
  mFile.OnClick := @FileMenuNeeded;
  AddItem(mFile, '-', 0, True, nil);
  FMiSave := AddItem(mFile, 'Save Document', PlatformShortCut(VK_S), False,
    @SaveClick);
  FMiSaveAs := AddItem(mFile, 'Save Document As…',
    PlatformShortCut(VK_S, True), False, @SaveAsClick);
  AddItem(mFile, '-', 0, True, nil);
  FMiChangePw := AddItem(mFile, 'Change Master Password…', 0, False,
    @ChangePasswordClick);
  FMiLock := AddItem(mFile, 'Lock Document', 0, False,
    @LockDocClick);
  FMiIntegrity := AddItem(mFile, 'Check Document Integrity…', 0, False,
    @IntegrityClick);
  AddItem(mFile, '-', 0, True, nil);
  FMiImport := AddItem(mFile, 'Import', 0, False, nil);
  AddItem(FMiImport, 'From OpenSSH config…', 0, True, @ImportOpenSshClick);
  AddItem(FMiImport, 'From RottenSSHrimp JSON…', 0, True, @ImportJsonClick);
  FMiExport := AddItem(mFile, 'Export', 0, False, nil);
  AddItem(FMiExport, 'As RottenSSHrimp JSON…', 0, True, @ExportJsonClick);
  AddItem(FMiExport, 'As CSV…', 0, True, @ExportCsvClick);
  AddItem(mFile, '-', 0, True, nil);
  FMiClose := AddItem(mFile, 'Close Document', 0, False, @CloseDocClick);
  {$IFNDEF DARWIN}
  AddItem(mFile, 'Exit', 0, True, @QuitClick);
  {$ENDIF}

  mEdit := TMenuItem.Create(FMenu);
  mEdit.Caption := '&Edit';
  FMenu.Items.Add(mEdit);
  FMiRename := AddItem(mEdit, 'Rename', ShortCut(VK_F2, []), False,
    @RenameClick);
  FMiDuplicate := AddItem(mEdit, 'Duplicate', 0, False,
    @DuplicateClick);
  FMiDelete := AddItem(mEdit, 'Delete', 0, False, @DeleteClick);
  AddItem(mEdit, '-', 0, True, nil);
  FMiFind := AddItem(mEdit, 'Find', PlatformShortCut(VK_F), False,
    @FindClick);

  mView := TMenuItem.Create(FMenu);
  mView.Caption := '&View';
  FMenu.Items.Add(mView);
  FMiExpandAll := AddItem(mView, 'Expand All', 0, False, @ExpandAllClick);
  FMiCollapseAll := AddItem(mView, 'Collapse All', 0, False,
    @CollapseAllClick);
  AddItem(mView, '-', 0, True, nil);
  mTheme := TMenuItem.Create(FMenu);
  mTheme.Caption := 'Theme';
  mView.Add(mTheme);
  for i := 0 to ThemeCount - 1 do
  begin
    mi := TMenuItem.Create(FMenu);
    mi.Caption := ThemeName(i);
    mi.Tag := i;
    mi.RadioItem := True;
    mi.GroupIndex := 7;
    mi.Checked := i = CurrentThemeIndex;
    mi.OnClick := @ThemeClick;
    mTheme.Add(mi);
  end;

  mConn := TMenuItem.Create(FMenu);
  mConn.Caption := '&Connection';
  FMenu.Items.Add(mConn);
  FMiConnect := AddItem(mConn, 'Connect', PlatformShortCut(VK_RETURN), False,
    @ConnectClick);
  FMiDisconnect := AddItem(mConn, 'Disconnect', PlatformShortCut(VK_W), False,
    @DisconnectClick);
  AddItem(mConn, '-', 0, True, nil);
  FMiCtrlAltDel := AddItem(mConn, 'Send Ctrl+Alt+Delete', 0, False,
    @CtrlAltDelClick);
  AddItem(mConn, '-', 0, True, nil);
  FMiDashboard := AddItem(mConn, 'Group Dashboard…', 0, False,
    @DashboardClick);
  AddItem(mConn, '-', 0, True, nil);
  FMiFavorites := AddItem(mConn, 'Favorites', 0, False, nil);
  FMiRecent := AddItem(mConn, 'Recent Connections', 0, False, nil);
  mConn.OnClick := @ConnMenuNeeded;

  mTools := TMenuItem.Create(FMenu);
  mTools.Caption := '&Tools';
  FMenu.Items.Add(mTools);
  AddItem(mTools, 'Terminal Font…', 0, True, @TerminalFontClick);
  AddItem(mTools, '-', 0, True, nil);
  AddItem(mTools, 'Local Terminal', PlatformShortCut(VK_T, True), True,
    @LocalTerminalClick);
  AddItem(mTools, '-', 0, True, nil);
  FMiScreenshot := AddItem(mTools, 'Take Screenshot…', 0, False,
    @TakeScreenshotClick);
  AddItem(mTools, '-', 0, True, nil);
  FMiCredMgr := AddItem(mTools, 'Credential Manager…', 0, False,
    @CredentialManagerClick);
  AddItem(mTools, '-', 0, True, nil);
  mDiag := TMenuItem.Create(FMenu);
  mDiag.Caption := 'Diagnostics';
  mTools.Add(mDiag);
  FMiLogEnabled := AddItem(mDiag, 'Enable Logging', 0, True, @LogEnabledClick);
  FMiLogEnabled.ShowAlwaysCheckable := True;
  FMiLogEnabled.Checked := PrefLogEnabled;
  FMiLogDebug := AddItem(mDiag, 'Debug Level', 0, True, @LogDebugClick);
  FMiLogDebug.ShowAlwaysCheckable := True;
  FMiLogDebug.Checked := PrefLogDebug;
  FMiLogConfidential := AddItem(mDiag, 'Confidential Mode (mask hosts)', 0,
    True, @LogConfidentialClick);
  FMiLogConfidential.ShowAlwaysCheckable := True;
  FMiLogConfidential.Checked := PrefLogConfidential;
  AddItem(mDiag, '-', 0, True, nil);
  AddItem(mDiag, 'Open Log Folder…', 0, True, @OpenLogFolderClick);

  mHelp := TMenuItem.Create(FMenu);
  mHelp.Caption := '&Help';
  FMenu.Items.Add(mHelp);
  AddItem(mHelp, 'About ' + RSSH_APP_NAME, 0, True, @AboutClick);
end;

procedure TfrmMain.BuildUI;
begin
  {$IFNDEF DARWIN}
  FMenuBar := TRSMenuBar.Create(Self);
  FMenuBar.Parent := Self;
  FMenuBar.Align := alTop;
  FMenuBar.Height := 26;
  FMenuBar.AdoptMainMenu(FMenu);
  {$ENDIF}

  FLeftPanel := TPanel.Create(Self);
  FLeftPanel.Parent := Self;
  FLeftPanel.Align := alLeft;
  FLeftPanel.Width := 240;
  FLeftPanel.BevelOuter := bvNone;
  FLeftPanel.Caption := '';

  FSearchBox := TRottenSearchBox.Create(Self);
  FSearchBox.Parent := FLeftPanel;
  FSearchBox.Align := alTop;
  FSearchBox.Height := 34;
  FSearchBox.SetEnabledLook(False);
  FSearchBox.OnSearchChange := @SearchChanged;
  FSearchBox.OnEscape := @SearchEscape;

  // creee AVANT l'arbre (alClient), sinon la zone client avale le strip
  FTreeScroll := TTreeScrollBar.Create(Self);
  FTreeScroll.Parent := FLeftPanel;
  FTreeScroll.Align := alRight;
  FTreeScroll.Width := 12;

  FTree := TScrollTreeView.Create(Self);
  FTree.Parent := FLeftPanel;
  FTree.Align := alClient;
  FTree.BorderStyle := bsNone;
  FTree.ScrollBars := ssNone;
  FTree.Images := FTreeImages;
  FTree.ReadOnly := False;
  FTree.RightClickSelect := True;
  FTree.DragMode := dmAutomatic;
  FTree.OnDeletion := @TreeDeletion;
  FTree.OnAdvancedCustomDrawItem := @TreeAdvancedDrawItem;
  FTree.OnKeyDown := @TreeKeyDown;
  FTree.OnDblClick := @TreeDblClick;
  FTree.OnSelectionChanged := @TreeSelectionChanged;
  FTree.OnEditing := @TreeEditing;
  FTree.OnEditingEnd := @TreeEditingEnd;
  FTree.OnEdited := @TreeEdited;
  FTree.OnDragOver := @TreeDragOver;
  FTree.OnDragDrop := @TreeDragDrop;
  FTreeScroll.Bind(FTree);

  FTreePopup := TPopupMenu.Create(Self);
  FTreePopup.Images := FTreeImages;
  FTreePopup.OnPopup := @TreePopupNeeded;
  FTree.PopupMenu := FTreePopup;
  {$IFNDEF DARWIN}
  FTreePopup.OwnerDraw := True;
  {$ENDIF}

  FLockPanel := TPanel.Create(Self);
  FLockPanel.Parent := FLeftPanel;
  FLockPanel.Align := alClient;
  FLockPanel.BevelOuter := bvNone;
  FLockPanel.Caption := '';
  FLockPanel.Visible := False;
  BuildLockPanel;

  FSplitter := TSplitter.Create(Self);
  FSplitter.Parent := Self;
  FSplitter.Align := alLeft;
  FSplitter.Left := FLeftPanel.Width + 1;

  FSessionPanel := TPanel.Create(Self);
  FSessionPanel.Parent := Self;
  FSessionPanel.Align := alClient;
  FSessionPanel.BevelOuter := bvNone;
  FSessionPanel.Caption := '';

  FPages := TPageControl.Create(Self);
  FPages.Parent := FSessionPanel;
  FPages.Align := alClient;
  FPages.Visible := False;
  FPages.ShowTabs := False;
  FPages.OnChange := @PagesChange;

  FTabBar := TSessionTabBar.Create(Self);
  FTabBar.Parent := FSessionPanel;
  FTabBar.Align := alTop;
  FTabBar.Height := 34;
  FTabBar.Visible := False;
  FTabBar.Attach(FPages);
  FTabBar.OnInfo := @TabBarInfo;
  FTabBar.OnActivateTab := @TabBarActivate;
  FTabBar.OnCloseTab := @TabBarClose;
  FTabBar.OnThumb := @TabBarThumb;

  FStatusBar := TStatusBar.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.SimplePanel := False;
  with FStatusBar.Panels.Add do
  begin
    Width := 400;
    Text := 'No document';
  end;
  with FStatusBar.Panels.Add do
  begin
    Width := 200;
    Text := '0 sessions';
  end;
  with FStatusBar.Panels.Add do
  begin
    Width := 380;
    Text := '';
  end;
  {$IFDEF WINDOWS}
  FStatusBar.OnDrawPanel := @StatusDrawPanel;
  FStatusBar.Panels[0].Style := psOwnerDraw;
  FStatusBar.Panels[1].Style := psOwnerDraw;
  FStatusBar.Panels[2].Style := psOwnerDraw;
  {$ENDIF}
end;

procedure TfrmMain.BuildLockPanel;
var
  lbl: TLabel;
  btn: TButton;
begin
  FLockPanel.Color := clSideBg;
  lbl := TLabel.Create(Self);
  lbl.Parent := FLockPanel;
  // Top explicite avant alTop: a Top egal, l'empilage suit l'ordre inverse
  lbl.Top := 0;
  lbl.Align := alTop;
  lbl.BorderSpacing.Around := 12;
  lbl.WordWrap := True;
  lbl.Font.Color := clSideText;
  FLockLabel := lbl;
  lbl.Caption := 'Document locked.'#10#10 +
    'The encryption key has been wiped from memory. ' +
    'The master password is required to resume.';

  btn := TButton.Create(Self);
  btn.Parent := FLockPanel;
  btn.Top := 1000;
  btn.Align := alTop;
  btn.BorderSpacing.Around := 12;
  btn.Height := 28;
  btn.Caption := 'Unlock…';
  btn.OnClick := @UnlockClick;
end;

procedure TfrmMain.LockDocClick(Sender: TObject);
var
  policy: TLockSessionPolicy;
begin
  if FDoc = nil then Exit;
  if DocCommandsBusy then Exit;
  if FDoc.Locked then
  begin
    UnlockClick(Sender);
    Exit;
  end;

  policy := PrefLockSessionPolicy;
  if (policy = lspAsk) and (FPages.PageCount > 0) then
    case QuestionDlg('Lock Document',
      'Sessions are open. What should happen when locking?', mtConfirmation,
      [mrYes, 'Disconnect and Lock', mrNo, 'Keep Sessions',
       mrCancel, 'Cancel'], 0) of
      mrYes: policy := lspDisconnect;
      mrNo: policy := lspKeep;
    else
      Exit;
    end
  else if policy = lspAsk then
    policy := lspDisconnect;

  if policy = lspDisconnect then
  begin
    if not CloseAllSessions(True) then
      Exit;
  end
  else
  begin
    // une session pas encore etablie aboutirait APRES le verrou
    DisconnectUnsettledSessions;
    InhibitAllReconnects;
  end;

  CloseDashboard;
  FDoc.Lock;
  // sans ca, un secret copie pendant le verrou part a tous les serveurs gardes
  SetClipboardSharingSuspended(True);
  LogInfo('document locked');
  UpdateLockState;
  UpdateDocumentState;
end;

function TfrmMain.UnlockInteractive: Boolean;
var
  pw: RawByteString;
  err: TDocError;
begin
  Result := False;
  if FDoc = nil then Exit;
  if not FDoc.Locked then Exit(True);
  if not AskUnlockPassword(pw) then Exit;
  try
    BruteForceDelay;
    // BruteForceDelay a pompe la boucle: Unlock sur un FDoc nil = crash sec
    if FDoc = nil then Exit;
    if not FDoc.Unlock(pw, err) then
    begin
      Inc(FPwFailCount);
      ShowDocError(err);
      Exit;
    end;
  finally
    if pw <> '' then
      FillChar(pw[1], Length(pw), 0);
  end;
  FPwFailCount := 0;
  SetClipboardSharingSuspended(False);
  LogInfo('document unlocked');
  UpdateLockState;
  BuildTree;
  UpdateDocumentState;
  Result := True;
end;

procedure TfrmMain.UnlockClick(Sender: TObject);
begin
  if (FDoc = nil) or not FDoc.Locked then Exit;
  UnlockInteractive;
end;

// l'arbre est masque ET vide: ses libelles viennent du document en clair
procedure TfrmMain.UpdateLockState;
var
  locked: Boolean;
  savedOnSel: TNotifyEvent;
begin
  locked := (FDoc <> nil) and FDoc.Locked;
  if locked then
  begin
    // Clear deselectionne -> TreeSelectionChanged -> UpdateLockState -> Clear:
    // recursion infinie, run loop figee. Le rappel se tait pendant le vidage.
    savedOnSel := FTree.OnSelectionChanged;
    FTree.OnSelectionChanged := nil;
    try
      FTree.Items.Clear;
    finally
      FTree.OnSelectionChanged := savedOnSel;
    end;
  end;
  FTree.Visible := not locked;
  FTreeScroll.Visible := not locked;
  FSearchBox.Visible := not locked;
  FLockPanel.Visible := locked;
  if FMiLock <> nil then
    if locked then
      FMiLock.Caption := 'Unlock Document…'
    else
      FMiLock.Caption := 'Lock Document';
end;

procedure TfrmMain.UpdateDocumentState;
var
  hasDoc, hasSel, locked, usable: Boolean;
  docName: string;
begin
  hasDoc := FDoc <> nil;
  locked := hasDoc and FDoc.Locked;
  usable := hasDoc and not locked;
  hasSel := usable and (SelectedRef <> nil) and (SelectedUuid <> '');
  FMiSave.Enabled := usable;
  FMiSaveAs.Enabled := usable;
  FMiIntegrity.Enabled := usable;
  FMiClose.Enabled := hasDoc;
  FMiChangePw.Enabled := usable and not FDoc.ReadOnly;
  FMiLock.Enabled := hasDoc;
  FMiImport.Enabled := usable;
  if FMiCredMgr <> nil then
    FMiCredMgr.Enabled := usable;
  FMiDashboard.Enabled := usable;
  FMiExport.Enabled := usable;
  FMiRename.Enabled := hasSel;
  FMiDuplicate.Enabled := hasSel;
  FMiDelete.Enabled := hasSel;
  FMiFind.Enabled := usable;
  FMiExpandAll.Enabled := usable;
  FMiCollapseAll.Enabled := usable;
  FSearchBox.SetEnabledLook(usable);
  if hasDoc then
  begin
    docName := ExtractFileName(FDoc.SourcePath);
    if locked then
      docName := docName + ' [locked]';
    if FDoc.ReadOnly then
      docName := docName + ' [read-only]';
    if FDoc.Dirty then
      docName := docName + ' •';
    Caption := docName + ' — ' + RSSH_APP_NAME;
    FStatusBar.Panels[0].Text := FDoc.SourcePath;
  end
  else
  begin
    Caption := RSSH_APP_NAME;
    FStatusBar.Panels[0].Text := 'No document';
    FSearchBox.Clear;
  end;
  UpdateLockState;
  UpdateSessionUi;
end;

procedure TfrmMain.TreeSelectionChanged(Sender: TObject);
begin
  UpdateDocumentState;
end;

function TfrmMain.CurrentSessionTab: TSshSessionTab;
begin
  Result := nil;
  if (FPages <> nil) and (FPages.ActivePage is TSshSessionTab) then
    Result := TSshSessionTab(FPages.ActivePage);
end;

function TfrmMain.CurrentRdpTab: TRdpSessionTab;
begin
  Result := nil;
  if (FPages <> nil) and (FPages.ActivePage is TRdpSessionTab) then
    Result := TRdpSessionTab(FPages.ActivePage);
end;

function TfrmMain.ExistingRdpTab(const AConnUuid: string): TRdpSessionTab;
var
  i: Integer;
begin
  Result := nil;
  if (FPages = nil) or (AConnUuid = '') then Exit;
  for i := 0 to FPages.PageCount - 1 do
    if FPages.Pages[i] is TRdpSessionTab then
      if TRdpSessionTab(FPages.Pages[i]).ConnectionUuid = AConnUuid then
        Exit(TRdpSessionTab(FPages.Pages[i]));
end;

function TfrmMain.ExistingVncTab(const AConnUuid: string): TVncSessionTab;
var
  i: Integer;
begin
  Result := nil;
  if (FPages = nil) or (AConnUuid = '') then Exit;
  for i := 0 to FPages.PageCount - 1 do
    if FPages.Pages[i] is TVncSessionTab then
      if TVncSessionTab(FPages.Pages[i]).ConnectionUuid = AConnUuid then
        Exit(TVncSessionTab(FPages.Pages[i]));
end;

function TfrmMain.SessionTabConnUuid(APage: TTabSheet): string;
begin
  Result := '';
  if APage is TSessionTabBase then
    Result := TSessionTabBase(APage).TabConnUuid;
end;

procedure TfrmMain.SessionTabShutdown(APage: TTabSheet);
begin
  if APage is TSessionTabBase then
    TSessionTabBase(APage).BeginShutdown;
end;

// un onglet broadcast porte N connexions et rend '' a TabConnUuid
function TfrmMain.SessionTabCountIn(APage: TTabSheet;
  AUuids: TStrings): Integer;
begin
  Result := 0;
  if APage is TSessionTabBase then
    Result := TSessionTabBase(APage).CountSessionsIn(AUuids);
end;

procedure TfrmMain.SessionTabShutdownIn(APage: TTabSheet; AUuids: TStrings);
begin
  if APage is TSessionTabBase then
    TSessionTabBase(APage).ShutdownSessionsIn(AUuids);
end;

function TfrmMain.CountLiveSessionsIn(AUuids: TStrings): Integer;
var
  j: Integer;
begin
  Result := 0;
  if (FPages = nil) or (AUuids = nil) then Exit;
  for j := 0 to FPages.PageCount - 1 do
    Inc(Result, SessionTabCountIn(FPages.Pages[j], AUuids));
end;

function TfrmMain.CountLiveSessionsInNode(const AUuid: string;
  AIsGroup: Boolean): Integer;
var
  uuids: TStringList;
  list: TRshQuickList;
  i: Integer;
begin
  Result := 0;
  if (FModel = nil) or (FPages = nil) or (AUuid = '') then Exit;
  uuids := TStringList.Create;
  try
    uuids.Sorted := True;
    if AIsGroup then
    begin
      list := FModel.ListSubtreeConnections(AUuid);
      try
        for i := 0 to list.Count - 1 do
          uuids.Add(list[i].ConnUuid);
      finally
        list.Free;
      end;
    end
    else
      uuids.Add(AUuid);
    Result := CountLiveSessionsIn(uuids);
  finally
    uuids.Free;
  end;
end;

function TfrmMain.HasActiveSessionTab: Boolean;
begin
  Result := (FPages <> nil) and (FPages.ActivePage is TSessionTabBase);
end;

procedure TfrmMain.TabBarInfo(APage: TTabSheet; out AName: string;
  out AGlyph: TTabGlyphKind);

  function MapGlyph(AState: TRemoteSessionState): TTabGlyphKind;
  begin
    case AState of
      rssConnected: Result := tgkConnected;
      rssFailed: Result := tgkFailed;
      rssCreated, rssConnecting, rssAuthenticating, rssDisconnecting:
        Result := tgkBusy;
    else
      Result := tgkNone;
    end;
  end;

begin
  AName := '';
  AGlyph := tgkNone;
  if APage is TSessionTabBase then
  begin
    AName := TSessionTabBase(APage).TabBarCaption;
    // log rompu = pastille rouge, quoi qu'en dise le transport
    if TSessionTabBase(APage).TabIsDeadLog or
       TSessionTabBase(APage).TabIsFailedKept then
      AGlyph := tgkDead
    else
      AGlyph := MapGlyph(TSessionTabBase(APage).TabState);
  end;
end;

procedure TfrmMain.TabBarActivate(APage: TTabSheet);
begin
  if (FPages = nil) or (APage = nil) then Exit;
  FPages.ActivePage := APage;
  if APage is TSessionTabBase then
    TSessionTabBase(APage).FocusContent;
end;

function TfrmMain.TabBarThumb(APage: TTabSheet): TBitmap;
begin
  Result := nil;
  if APage is TSessionTabBase then
    Result := TSessionTabBase(APage).GrabThumbnail;
end;

procedure TfrmMain.TabBarClose(APage: TTabSheet);
begin
  if not (APage is TSessionTabBase) then Exit;
  if not TSessionTabBase(APage).ConfirmClose then Exit;
  APage.Free;
  UpdateSessionUi;
end;

procedure TfrmMain.SessionStatusChanged(Sender: TObject);
var
  uuid: string;
  st: TRemoteSessionState;
begin
  if FTabBar <> nil then
    FTabBar.RefreshBar;

  uuid := '';
  st := rssCreated;
  if Sender is TSessionTabBase then
  begin
    uuid := TSessionTabBase(Sender).TabConnUuid;
    st := TSessionTabBase(Sender).TabState;
  end;
  if uuid = '' then Exit;
  case st of
    rssConnected: RecordAttempt(uuid, srOk);
    rssFailed: RecordAttempt(uuid, srFailed);
  end;
end;

procedure TfrmMain.UpdateSessionUi;
var
  n: Integer;
  tab: TSshSessionTab;
  ref: TNodeRef;
begin
  n := FPages.PageCount;
  FPages.Visible := n > 0;
  FTabBar.Visible := n > 0;
  FTabBar.RefreshBar;
  if n = 1 then
    FStatusBar.Panels[1].Text := '1 session'
  else
    FStatusBar.Panels[1].Text := Format('%d sessions', [n]);

  ref := SelectedRef;
  FMiConnect.Enabled := (FModel <> nil) and (ref <> nil) and
    (ref.Uuid <> '') and (ref.Kind = nkConnection);
  FMiDisconnect.Enabled := HasActiveSessionTab;
  FMiCtrlAltDel.Enabled := CurrentRdpTab <> nil;
  if FMiScreenshot <> nil then
    FMiScreenshot.Enabled := HasActiveSessionTab;
  if FTree <> nil then
    FTree.Invalidate;
end;

procedure TfrmMain.PagesChange(Sender: TObject);
begin
  if (FPages <> nil) and (FPages.ActivePage is TSessionTabBase) then
    TSessionTabBase(FPages.ActivePage).FocusContent;
  UpdateSessionUi;
end;

procedure TfrmMain.InhibitAllReconnects;
var
  i: Integer;
begin
  for i := 0 to FPages.PageCount - 1 do
  begin
    if FPages.Pages[i] is TRdpSessionTab then
      TRdpSessionTab(FPages.Pages[i]).InhibitReconnect;
    // VNC garde son mot de passe pour la reprise: le verrou doit l'effacer
    if FPages.Pages[i] is TVncSessionTab then
      TVncSessionTab(FPages.Pages[i]).InhibitReconnect;
  end;
end;

function TfrmMain.RawCount: Integer;
begin
  if FPages = nil then Result := 0 else Result := FPages.PageCount;
end;

function TfrmMain.RawItem(AIndex: Integer): Pointer;
begin
  Result := Pointer(FPages.Pages[AIndex]);
end;

function TfrmMain.IsSessionTab(APtr: Pointer): Boolean;
begin
  Result := TObject(APtr) is TSessionTabBase;
end;

function TfrmMain.VisitBeginShutdownUnsettled(APtr: Pointer): Boolean;
var
  tab: TSessionTabBase;
begin
  tab := TSessionTabBase(APtr);
  if tab.TabState in [rssCreated, rssConnecting, rssAuthenticating] then
    tab.BeginShutdown;
  Result := True;
end;

function TfrmMain.VisitFreeUnsettled(APtr: Pointer): Boolean;
var
  tab: TSessionTabBase;
begin
  tab := TSessionTabBase(APtr);
  if tab.TabState in [rssCreated, rssConnecting, rssAuthenticating] then
    tab.Free;
  Result := True;
end;

function TfrmMain.ConfirmCloseAllSessions: Boolean;
var
  j, n: Integer;
  tab: TSessionTabBase;
  list: string;
begin
  Result := True;
  if FPages = nil then Exit;
  n := 0;
  list := '';
  for j := 0 to FPages.PageCount - 1 do
    if FPages.Pages[j] is TSessionTabBase then
    begin
      tab := TSessionTabBase(FPages.Pages[j]);
      if not IsTerminalState(tab.TabState) then
      begin
        Inc(n);
        list := list + LineEnding + '   •  ' + tab.TabBarCaption;
      end;
    end;
  if n = 0 then Exit;
  Result := QuestionDlg(RSSH_APP_NAME,
    Format('%d active session(s) will be disconnected:%s%sDisconnect all and close?',
      [n, list, LineEnding + LineEnding]),
    mtConfirmation,
    [mrOK, 'Disconnect All', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

function TfrmMain.VisitFree(APtr: Pointer): Boolean;
begin
  TSessionTabBase(APtr).Free;
  Result := True;
end;

procedure TfrmMain.DisconnectUnsettledSessions;
var
  snap: TFPList;
begin
  if FPages = nil then Exit;
  snap := TFPList.Create;
  try
    SnapshotSessionTabs(Self, snap);
    SweepSnapshot(Self, snap, False, @VisitBeginShutdownUnsettled);
    SweepSnapshot(Self, snap, True, @VisitFreeUnsettled);
  finally
    snap.Free;
  end;
  UpdateSessionUi;
end;

procedure TfrmMain.SessionNotice(const AMessage: string);
begin
  FStatusBar.Panels[0].Text := AMessage;
  // hosts et users se cachent jusque dans le texte d'erreur
  if LogIsConfidential then
    LogWarning('session: error (details hidden in confidential mode)')
  else
    LogWarning('session: ' + AMessage);
end;

function TfrmMain.DashSessionState(const AConnUuid: string): string;
var
  i: Integer;
  st: TRemoteSessionState;
  found: Boolean;
begin
  Result := '';
  found := False;
  st := rssCreated;
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TSessionTabBase) and
       (TSessionTabBase(FPages.Pages[i]).TabConnUuid = AConnUuid) then
    begin
      st := TSessionTabBase(FPages.Pages[i]).TabState;
      found := True;
      Break;
    end;
  if not found then Exit;
  case st of
    rssConnected: Result := 'connected';
    rssConnecting, rssAuthenticating: Result := 'connecting';
    rssDisconnecting: Result := 'closing';
    rssFailed: Result := 'failed';
  else
    Result := 'open';
  end;
end;

procedure TfrmMain.DashboardClick(Sender: TObject);
var
  ref: TNodeRef;
  uuid, title: string;
  n: TRshNode;
begin
  if (FModel = nil) or ((FDoc <> nil) and FDoc.Locked) then Exit;

  uuid := '';
  title := ExtractFileName(FDoc.SourcePath);
  ref := SelectedRef;
  if (ref <> nil) and (ref.Uuid <> '') then
  try
    n := FModel.GetNode(ref.Uuid);
    try
      if n.Kind = nkGroup then
      begin
        uuid := n.Uuid;
        title := n.DisplayName;
      end
      else
        uuid := n.ParentUuid;
    finally
      n.Free;
    end;
    if (uuid <> '') and (uuid <> ref.Uuid) then
    begin
      n := FModel.GetNode(uuid);
      try
        title := n.DisplayName;
      finally
        n.Free;
      end;
    end;
  except
    on EModelError do ;
  end;

  CloseDashboard;
  FDashboard := TGroupDashboard.CreateFor(Self, FModel, uuid, title);
  FDashboard.OnSessionState := @DashSessionState;
  FDashboard.OnConnect := @ConnectByUuid;
  FDashboard.OnClose := @DashboardClosed;
  FDashboard.Show;
end;

procedure TfrmMain.DashboardClosed(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  // caFree libererait la fenetre dans son propre gestionnaire
  CloseAction := caHide;
  FDashboard := nil;
  if Sender is TGroupDashboard then
    TGroupDashboard(Sender).Release;
end;

procedure TfrmMain.CloseDashboard;
var
  d: TGroupDashboard;
begin
  if FDashboard = nil then Exit;
  d := FDashboard;
  FDashboard := nil;
  d.OnClose := nil;
  d.Detach;
  d.Release;
end;

function TfrmMain.ImportTargetUuid: string;
var
  ref: TNodeRef;
  n: TRshNode;
begin
  Result := '';
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') then Exit;
  if ref.Kind = nkGroup then
    Exit(ref.Uuid);
  try
    n := FModel.GetNode(ref.Uuid);
    try
      Result := n.ParentUuid;
    finally
      n.Free;
    end;
  except
    on EModelError do Result := '';
  end;
end;

procedure TfrmMain.ShowImportReport(var AReport: TImportReport);
var
  msg: string;
begin
  msg := Format('%d group(s) and %d connection(s) imported.',
    [AReport.GroupsCreated, AReport.ConnectionsCreated]);
  if AReport.Skipped > 0 then
    msg := msg + LineEnding +
      Format('%d entries skipped.', [AReport.Skipped]);
  if AReport.Messages.Count > 0 then
  begin
    msg := msg + LineEnding + LineEnding;
    if AReport.Messages.Count <= 12 then
      msg := msg + AReport.Messages.Text
    else
      msg := msg + Copy(AReport.Messages.Text, 1, 1200) + LineEnding +
        Format('… and %d more.', [AReport.Messages.Count - 12]);
  end;
  MessageDlg('Import', msg, mtInformation, [mbOK], 0);
end;

// borne la taille AVANT de charger: une entree non fiable ne remplit pas la RAM
function ReadFileCapped(const APath: string; AMaxBytes: Int64;
  out AData: RawByteString; out AErr: string): Boolean;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := False;
  AData := '';
  AErr := '';
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
    try
      // taille lue UNE fois pour la borne, l'allocation ET la lecture: sur un
      // montage reseau, grandir entre SetLength et ReadBuffer deborde le tas
      n := fs.Size;
      if n > AMaxBytes then
      begin
        AErr := Format('File too large (max %d bytes).', [AMaxBytes]);
        Exit;
      end;
      SetLength(AData, n);
      if n > 0 then
        fs.ReadBuffer(AData[1], n);
      Result := True;
    finally
      fs.Free;
    end;
  except
    on E: Exception do
      AErr := 'Unreadable file.';
  end;
end;

procedure TfrmMain.ImportOpenSshClick(Sender: TObject);
var
  dlg: TOpenDialog;
  src: TStringList;
  rep: TImportReport;
  data: RawByteString;
  err: string;
  target: string;
begin
  if (FModel = nil) or ((FDoc <> nil) and FDoc.Locked) then Exit;
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Import OpenSSH config';
    dlg.Filter := 'OpenSSH config|config;*.conf|All files (*)|*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    dlg.InitialDir := GetEnvironmentVariable('HOME') + PathDelim + '.ssh';
    if not dlg.Execute then Exit;

    if not ReadFileCapped(dlg.FileName, MAX_IMPORT_FILE_BYTES, data, err) then
    begin
      MessageDlg('Import', err, mtError, [mbOK], 0);
      Exit;
    end;
    src := TStringList.Create;
    try
      src.Text := data;
      target := ImportTargetUuid;
      try
        rep := ImportOpenSshConfig(FModel, target, src.Text);
      except
        on E: EImportExportError do
        begin
          MessageDlg('Import', E.Message, mtError, [mbOK], 0);
          Exit;
        end;
        on E: EModelError do
        begin
          ShowModelError(E.Message);
          Exit;
        end;
      end;
      try
        ShowImportReport(rep);
      finally
        rep.Messages.Free;
      end;
    finally
      src.Free;
    end;
  finally
    dlg.Free;
    BuildTree;
    UpdateDocumentState;
  end;
end;

procedure TfrmMain.ImportJsonClick(Sender: TObject);
var
  dlg: TOpenDialog;
  src: TStringList;
  rep: TImportReport;
  data: RawByteString;
  err: string;
  target: string;
begin
  if (FModel = nil) or ((FDoc <> nil) and FDoc.Locked) then Exit;
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Import RottenSSHrimp JSON';
    dlg.DefaultExt := 'json';
    dlg.Filter := 'JSON (*.json)|*.json|All files (*)|*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if not dlg.Execute then Exit;

    if not ReadFileCapped(dlg.FileName, MAX_IMPORT_FILE_BYTES, data, err) then
    begin
      MessageDlg('Import', err, mtError, [mbOK], 0);
      Exit;
    end;
    src := TStringList.Create;
    try
      src.Text := data;
      target := ImportTargetUuid;
      try
        rep := ImportJson(FModel, target, src.Text);
      except
        on E: EImportExportError do
        begin
          MessageDlg('Import', E.Message, mtError, [mbOK], 0);
          Exit;
        end;
        on E: EModelError do
        begin
          ShowModelError(E.Message);
          Exit;
        end;
      end;
      try
        ShowImportReport(rep);
      finally
        rep.Messages.Free;
      end;
    finally
      src.Free;
    end;
  finally
    dlg.Free;
  end;
  BuildTree;
  UpdateDocumentState;
end;

procedure TfrmMain.ImportHostsCsvClick(Sender: TObject);
var
  dlg: TOpenDialog;
  ref: TNodeRef;
  data: RawByteString;
  err, target: string;
  rep: TImportReport;
begin
  if (FModel = nil) or ((FDoc <> nil) and FDoc.Locked) then Exit;
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') or (ref.Kind <> nkGroup) then Exit;
  target := ref.Uuid;

  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Import hosts from CSV';
    dlg.DefaultExt := 'csv';
    dlg.Filter := 'CSV (*.csv)|*.csv|All files (*)|*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if not dlg.Execute then Exit;

    if not ReadFileCapped(dlg.FileName, MAX_IMPORT_FILE_BYTES, data, err) then
    begin
      MessageDlg('Import', err, mtError, [mbOK], 0);
      Exit;
    end;

    try
      rep := ImportHostsCsv(FModel, target, data);
    except
      on E: EImportExportError do
      begin
        MessageDlg('Import', E.Message, mtError, [mbOK], 0);
        Exit;
      end;
      on E: EModelError do
      begin
        ShowModelError(E.Message);
        Exit;
      end;
    end;
    try
      ShowImportReport(rep);
    finally
      rep.Messages.Free;
    end;
  finally
    dlg.Free;
  end;
  BuildTree;
  UpdateDocumentState;
end;

procedure TfrmMain.DoExport(AFormat: TExportFormat;
  const AExt, AFilter: string);
var
  dlg: TSaveDialog;
  data: string;
  ref: TNodeRef;
  rootUuid: string;
  outFile: TStringList;
begin
  if (FModel = nil) or ((FDoc <> nil) and FDoc.Locked) then Exit;
  rootUuid := '';
  ref := SelectedRef;
  if (ref <> nil) and (ref.Uuid <> '') and (ref.Kind = nkGroup) then
    rootUuid := ref.Uuid;

  try
    data := ExportSubtree(FModel, rootUuid, AFormat);
  except
    on E: Exception do
    begin
      MessageDlg('Export', E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;

  dlg := TSaveDialog.Create(Self);
  try
    dlg.Title := 'Export';
    dlg.DefaultExt := AExt;
    dlg.Filter := AFilter;
    dlg.Options := dlg.Options + [ofOverwritePrompt, ofPathMustExist];
    if not dlg.Execute then Exit;
    outFile := TStringList.Create;
    try
      outFile.Text := data;
      try
        // 0600 d'emblee: ecrire puis chmod laisse une fenetre umask
        SavePrivateFile(dlg.FileName, outFile.Text);
      except
        on E: Exception do
        begin
          MessageDlg('Export', 'Cannot write file: ' + E.Message,
            mtError, [mbOK], 0);
          Exit;
        end;
      end;
    finally
      outFile.Free;
    end;
    MessageDlg('Export',
      'Export complete.' + LineEnding + LineEnding +
      'This file contains NO password and NO private key: ' +
      'only the names, hosts, ports and the name of the associated credential.',
      mtInformation, [mbOK], 0);
  finally
    dlg.Free;
  end;
end;

procedure TfrmMain.ExportJsonClick(Sender: TObject);
begin
  DoExport(efJson, 'json', 'JSON (*.json)|*.json');
end;

procedure TfrmMain.ExportCsvClick(Sender: TObject);
begin
  DoExport(efCsv, 'csv', 'CSV (*.csv)|*.csv');
end;

function TfrmMain.FavoriteMark(ANode: TRshNode): string;
begin
  Result := '';
  if (FModel = nil) or (ANode = nil) or (ANode.Kind <> nkConnection) then Exit;
  if FModel.IsFavorite(ANode.Uuid) then
    Result := '★ ';
end;

procedure TfrmMain.RebuildQuickMenu(AParent: TMenuItem; AList: TRshQuickList;
  AShowWhen: Boolean);
var
  i: Integer;
  mi: TMenuItem;
  e: TRshQuickEntry;
  cap: string;
begin
  AParent.Clear;
  AParent.Enabled := AShowWhen and (AList <> nil) and (AList.Count > 0);
  if AList = nil then Exit;
  for i := 0 to AList.Count - 1 do
  begin
    e := AList[i];
    mi := TMenuItem.Create(AParent);
    cap := e.DisplayName + '  —  ' + UpperCase(PROTOCOL_NAMES[e.Protocol]) +
      ' ' + e.Hostname;
    if (e.LastConnectedMs > 0) and (e.LastResult = srFailed) then
      cap := cap + '  (failed)';
    mi.Caption := cap;
    mi.Hint := e.ConnUuid;
    mi.OnClick := @QuickEntryClick;
    AParent.Add(mi);
  end;
end;

procedure TfrmMain.ConnMenuNeeded(Sender: TObject);
var
  favs, recents: TRshQuickList;
  usable: Boolean;
  mi: TMenuItem;
begin
  if FMiFavorites = nil then Exit;
  usable := (FModel <> nil) and (FDoc <> nil) and not FDoc.Locked;
  if not usable then
  begin
    RebuildQuickMenu(FMiFavorites, nil, False);
    RebuildQuickMenu(FMiRecent, nil, False);
    Exit;
  end;

  favs := nil;
  recents := nil;
  try
    favs := FModel.ListFavorites;
    recents := FModel.ListRecent(MAX_RECENT_ENTRIES);
    RebuildQuickMenu(FMiFavorites, favs, True);
    RebuildQuickMenu(FMiRecent, recents, True);
    if FMiRecent.Count > 0 then
    begin
      mi := TMenuItem.Create(FMiRecent);
      mi.Caption := '-';
      FMiRecent.Add(mi);
      mi := TMenuItem.Create(FMiRecent);
      mi.Caption := 'Clear Recent Connections';
      mi.OnClick := @ClearRecentClick;
      FMiRecent.Add(mi);
    end;
  finally
    favs.Free;
    recents.Free;
  end;
end;

procedure TfrmMain.QuickEntryClick(Sender: TObject);
begin
  if Sender is TMenuItem then
    ConnectByUuid(TMenuItem(Sender).Hint);
end;

procedure TfrmMain.ToggleFavoriteClick(Sender: TObject);
var
  ref: TNodeRef;
begin
  if FModel = nil then Exit;
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') or (ref.Kind <> nkConnection) then Exit;
  try
    FModel.SetFavorite(ref.Uuid, not FModel.IsFavorite(ref.Uuid));
  except
    on E: EModelError do
    begin
      ShowModelError(E.Message);
      Exit;
    end;
  end;
  BuildTree;
  UpdateDocumentState;
end;

procedure TfrmMain.ClearRecentClick(Sender: TObject);
begin
  if FModel = nil then Exit;
  if MessageDlg('Recent Connections',
    'Clear the list of recent connections?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;
  try
    FModel.ClearRecent;
  except
    on E: EModelError do
      ShowModelError(E.Message);
  end;
  UpdateDocumentState;
end;

// File > Open Recent, peuple a chaque ouverture du menu: une autre instance a
// pu ouvrir un document entre-temps, et RecentReload refusionne le fichier.
procedure TfrmMain.FileMenuNeeded(Sender: TObject);
var
  i, n: Integer;
  mi: TMenuItem;
begin
  if FMiOpenRecent = nil then Exit;
  FMiOpenRecent.Clear;
  RecentReload;
  n := RecentCount;
  for i := 0 to n - 1 do
  begin
    mi := TMenuItem.Create(FMiOpenRecent);
    // « & » est l'accelerateur de la LCL: tel quel, un chemin qui en contient
    // perdrait le caractere et soulignerait la lettre suivante
    mi.Caption := StringReplace(RecentDisplay(i), '&', '&&', [rfReplaceAll]);
    mi.Hint := RecentPath(i);   // chemin BRUT: le libelle est tronque a 200
    mi.OnClick := @OpenRecentClick;
    FMiOpenRecent.Add(mi);
  end;
  if n > 0 then
  begin
    mi := TMenuItem.Create(FMiOpenRecent);
    mi.Caption := '-';
    FMiOpenRecent.Add(mi);
    mi := TMenuItem.Create(FMiOpenRecent);
    mi.Caption := 'Clear Menu';
    mi.OnClick := @ClearOpenRecentClick;
    FMiOpenRecent.Add(mi);
  end;
  FMiOpenRecent.Enabled := n > 0;
end;

procedure TfrmMain.OpenRecentClick(Sender: TObject);
var
  path: string;
begin
  if not (Sender is TMenuItem) then Exit;
  path := TMenuItem(Sender).Hint;
  if path = '' then Exit;
  // Deplace, renomme, ou sur un volume absent: l'entree ne servira plus jamais.
  // On le dit et on la retire, plutot que de laisser un choix mort dans le menu.
  if not FileExists(path) then
  begin
    MessageDlg('Document not found',
      'This document is no longer at:' + LineEnding + LineEnding + path +
      LineEnding + LineEnding + 'It has been removed from the recent list.',
      mtWarning, [mbOK], 0);
    RecentRemove(path);
    Exit;
  end;
  OpenDocumentPath(path);
end;

procedure TfrmMain.ClearOpenRecentClick(Sender: TObject);
begin
  if MessageDlg('Open Recent',
    'Clear the list of recently opened documents?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;
  RecentClear;
end;

procedure TfrmMain.ConnectClick(Sender: TObject);
var
  ref: TNodeRef;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> nkConnection) then Exit;
  ConnectByUuid(ref.Uuid);
end;

procedure TfrmMain.ConnectByUuid(const AConnUuid: string);
var
  n: TRshNode;
  proto: TRshProtocol;
  sshTab: TSshSessionTab;
  rdpTab: TRdpSessionTab;
  vncTab: TVncSessionTab;
  err: string;
begin
  if FModel = nil then Exit;
  if AConnUuid = '' then Exit;
  // le tunnel pompe la boucle: un double-clic repartirait sur un etat a moitie bati
  if DocCommandsBusy then Exit;
  if (FDoc <> nil) and FDoc.Locked then Exit;
  try
    n := FModel.GetNode(AConnUuid);
  except
    on E: EModelError do
    begin
      ShowModelError(E.Message);
      Exit;
    end;
  end;
  try
    proto := n.Protocol;
  finally
    n.Free;
  end;

  // sans ces nil, l'historisation plus bas lit des variables indeterminees
  sshTab := nil;
  rdpTab := nil;
  vncTab := nil;
  err := '';
  if proto = rpVnc then
  begin
    vncTab := ExistingVncTab(AConnUuid);
    if vncTab <> nil then
    begin
      FPages.ActivePage := vncTab;
      if vncTab.View.CanFocus then
        vncTab.View.SetFocus;
      UpdateSessionUi;
      Exit;
    end;
    FConnecting := True;
    try
      vncTab := StartVncSession(FPages, FDoc, FModel, FSessions, AConnUuid,
        @SessionNotice, err);
    finally
      FConnecting := False;
    end;
    if vncTab <> nil then
    begin
      vncTab.OnDestroyed := @SessionTabGone;
      vncTab.OnStatusChanged := @SessionStatusChanged;
      vncTab.View.OnEscapeCapture := @SessionEscapeCapture;
    end;
  end
  else if proto = rpRdp then
  begin
    rdpTab := ExistingRdpTab(AConnUuid);
    if rdpTab <> nil then
    begin
      FPages.ActivePage := rdpTab;
      if rdpTab.View.CanFocus then
        rdpTab.View.SetFocus;
      UpdateSessionUi;
      Exit;
    end;
    FConnecting := True;
    try
      rdpTab := StartRdpSession(FPages, FDoc, FModel, FSessions, AConnUuid,
        @SessionNotice, err);
    finally
      FConnecting := False;
    end;
    if rdpTab <> nil then
    begin
      rdpTab.OnDestroyed := @SessionTabGone;
      rdpTab.OnStatusChanged := @SessionStatusChanged;
      rdpTab.View.OnEscapeCapture := @SessionEscapeCapture;
    end;
  end
  else if proto = rpContainer then
  begin
    FConnecting := True;
    try
      sshTab := StartContainerSession(FPages, FDoc, FModel, FSessions, AConnUuid,
        @SessionNotice, err);
    finally
      FConnecting := False;
    end;
    if sshTab <> nil then
    begin
      sshTab.OnDestroyed := @SessionTabGone;
      sshTab.OnStatusChanged := @SessionStatusChanged;
      sshTab.Terminal.OnEscapeCapture := @SessionEscapeCapture;
    end;
  end
  else if proto = rpPod then
  begin
    FConnecting := True;
    try
      sshTab := StartPodSession(FPages, FDoc, FModel, FSessions, AConnUuid,
        @SessionNotice, err);
    finally
      FConnecting := False;
    end;
    if sshTab <> nil then
    begin
      sshTab.OnDestroyed := @SessionTabGone;
      sshTab.OnStatusChanged := @SessionStatusChanged;
      sshTab.Terminal.OnEscapeCapture := @SessionEscapeCapture;
    end;
  end
  else
  begin
    FConnecting := True;
    try
      sshTab := StartSshSession(FPages, FDoc, FModel, FSessions, AConnUuid,
        @SessionNotice, err);
    finally
      FConnecting := False;
    end;
    if sshTab <> nil then
    begin
      sshTab.OnDestroyed := @SessionTabGone;
      sshTab.OnStatusChanged := @SessionStatusChanged;
      sshTab.Terminal.OnEscapeCapture := @SessionEscapeCapture;
    end;
  end;
  // seul l'echec de LANCEMENT se note ici
  if (sshTab = nil) and (rdpTab = nil) and (vncTab = nil) and (err <> '') then
    RecordAttempt(AConnUuid, srFailed);

  if err <> '' then
    MessageDlg(RSSH_APP_NAME, err, mtError, [mbOK], 0);
  UpdateSessionUi;
end;

procedure TfrmMain.RecordAttempt(const AConnUuid: string;
  AResult: TSessionResult);
begin
  if FModel = nil then Exit;
  try
    FModel.TouchRecent(AConnUuid, AResult);
  except
    on E: Exception do
      LogWarning('recent history: ' + E.ClassName);
  end;
end;

procedure TfrmMain.CtrlAltDelClick(Sender: TObject);
var
  tab: TRdpSessionTab;
begin
  tab := CurrentRdpTab;
  if tab <> nil then
    tab.SendCtrlAltDel;
end;

procedure TfrmMain.SessionTabGone(Sender: TObject);
begin
  UpdateSessionUi;
  UpdateDocumentState;
  // OnChange ne tire PAS sur un retrait de page: sans ca, il faut recliquer
  if (FPages <> nil) and (FPages.ActivePage is TSessionTabBase) then
    TSessionTabBase(FPages.ActivePage).FocusContent
  else if (FTree <> nil) and FTree.CanFocus then
    FTree.SetFocus;
end;

procedure TfrmMain.DisconnectClick(Sender: TObject);
var
  page: TTabSheet;
begin
  if FPages = nil then Exit;
  page := FPages.ActivePage;
  if not (page is TSessionTabBase) then Exit;
  if not TSessionTabBase(page).ConfirmClose then Exit;
  page.Free;
  UpdateSessionUi;
end;

function TfrmMain.CloseAllSessions(AAsk: Boolean): Boolean;
var
  snap: TFPList;
begin
  Result := True;
  if FPages = nil then Exit;
  snap := TFPList.Create;
  try
    SnapshotSessionTabs(Self, snap);
    if AAsk and not ConfirmCloseAllSessions then
      Exit(False);
    // arret demande a tous d'abord, les threads finissent en parallele
    FSessions.ShutdownAll;
    // Free joint le worker: CheckSynchronize peut y lancer une modale AskHostKey
    SweepSnapshot(Self, snap, True, @VisitFree);
  finally
    snap.Free;
  end;
  UpdateSessionUi;
end;

procedure TfrmMain.ShowDocError(const AErr: TDocError);
begin
  MessageDlg(RSSH_APP_NAME, AErr.UserMessage, mtError, [mbOK], 0);
end;

procedure TfrmMain.ShowModelError(const AMsg: string);
begin
  MessageDlg(RSSH_APP_NAME, AMsg, mtError, [mbOK], 0);
end;

// dossiers d'abord puis alphabetique: le sort_order manuel ne se voit plus
function TreeSiblingOrder(const A, B: TRshNode): Integer;
begin
  if A.Kind <> B.Kind then
    Exit(Ord(A.Kind) - Ord(B.Kind));
  Result := UTF8CompareText(A.DisplayName, B.DisplayName);
end;

procedure TfrmMain.BuildTree;
var
  nodes: TRshNodeList;
  byUuid: TStringList;
  root: TTreeNode;
  i: Integer;
  inserted: Boolean;
  tn: TTreeNode;
  filter: string;
  rootIcon: string;
  visibleIds: TStringList;
  expanded: TStringList;

  function NodeVisible(ANode: TRshNode): Boolean;
  begin
    Result := visibleIds.IndexOf(ANode.Uuid) >= 0;
  end;

  procedure MarkVisibleWithAncestors(AList: TRshNodeList);
  var
    k, j: Integer;
    parentName, credName, src, credUuid: string;
    cred: TRshCredential;
    cur: string;
  begin
    for k := 0 to AList.Count - 1 do
    begin
      parentName := '';
      for j := 0 to AList.Count - 1 do
        if AList[j].Uuid = AList[k].ParentUuid then
        begin
          parentName := AList[j].DisplayName;
          Break;
        end;
      credName := '';
      if AList[k].Kind = nkConnection then
      begin
        credUuid := AList[k].CredentialUuid;
        if credUuid <> '' then
        try
          cred := FModel.GetCredential(credUuid);
          try
            credName := cred.DisplayName;
          finally
            cred.Free;
          end;
        except
          on EModelError do ;
        end;
      end;
      if AList[k].Kind = nkConnection then
      begin
        if not MatchesSearch(filter, AList[k].DisplayName,
          AList[k].Hostname, PROTOCOL_NAMES[AList[k].Protocol],
          AList[k].Description, parentName, credName) then
          Continue;
      end
      else if not MatchesSearch(filter, AList[k].DisplayName, '', '',
        AList[k].Description, parentName, '') then
        Continue;
      cur := AList[k].Uuid;
      while cur <> '' do
      begin
        if visibleIds.IndexOf(cur) >= 0 then Break;
        visibleIds.Add(cur);
        for j := 0 to AList.Count - 1 do
          if AList[j].Uuid = cur then
          begin
            cur := AList[j].ParentUuid;
            Break;
          end;
      end;
    end;
  end;

begin
  expanded := TStringList.Create;
  FTree.Items.BeginUpdate;
  try
    expanded.Sorted := True;
    for i := 0 to FTree.Items.Count - 1 do
      if (FTree.Items[i].Data <> nil) and FTree.Items[i].Expanded then
        expanded.Add(TNodeRef(FTree.Items[i].Data).Uuid);
    FTree.Items.Clear;
    if FModel = nil then Exit;
    filter := SearchFilter;
    root := FTree.Items.Add(nil, ExtractFileName(FDoc.SourcePath));
    root.Data := TNodeRef.Create('', nkGroup);
    rootIcon := FModel.GetRootIcon;
    if rootIcon = '' then
      rootIcon := ICON_ROOT_DEFAULT;
    root.ImageIndex := TreeIconIndex(rootIcon);
    root.SelectedIndex := root.ImageIndex;
    nodes := FModel.LoadNodes;
    nodes.Sort(@TreeSiblingOrder);
    byUuid := TStringList.Create;
    visibleIds := TStringList.Create;
    try
      visibleIds.Sorted := False;
      if filter <> '' then
        MarkVisibleWithAncestors(nodes);
      byUuid.Sorted := True;
      // LoadNodes ne garantit pas les parents avant les enfants
      repeat
        i := 0;
        inserted := False;
        while i < nodes.Count do
        begin
          if (byUuid.IndexOf(nodes[i].Uuid) < 0) and
             ((filter = '') or NodeVisible(nodes[i])) then
          begin
            if nodes[i].ParentUuid = '' then
              tn := root
            else if byUuid.IndexOf(nodes[i].ParentUuid) >= 0 then
              tn := TTreeNode(
                byUuid.Objects[byUuid.IndexOf(nodes[i].ParentUuid)])
            else
              tn := nil;
            if tn <> nil then
            begin
              tn := FTree.Items.AddChild(tn,
                FavoriteMark(nodes[i]) + nodes[i].DisplayName);
              tn.Data := TNodeRef.Create(nodes[i].Uuid, nodes[i].Kind);
              tn.ImageIndex := TreeIconIndex(nodes[i].IconId);
              tn.SelectedIndex := tn.ImageIndex;
              byUuid.AddObject(nodes[i].Uuid, TObject(tn));
              inserted := True;
            end;
          end;
          Inc(i);
        end;
      until not inserted;
    finally
      visibleIds.Free;
      byUuid.Free;
      nodes.Free;
    end;
    if filter <> '' then
      FTree.FullExpand
    else
    begin
      root.Expand(False);
      for i := 0 to FTree.Items.Count - 1 do
        if (FTree.Items[i].Data <> nil) and
           (expanded.IndexOf(TNodeRef(FTree.Items[i].Data).Uuid) >= 0) then
          FTree.Items[i].Expand(False);
    end;
  finally
    FTree.Items.EndUpdate;
    expanded.Free;
  end;
end;

function TfrmMain.SelectedRef: TNodeRef;
begin
  Result := nil;
  if (FTree.Selected <> nil) and (FTree.Selected.Data <> nil) then
    Result := TNodeRef(FTree.Selected.Data);
end;

function TfrmMain.SelectedUuid: string;
var
  ref: TNodeRef;
begin
  ref := SelectedRef;
  if ref = nil then
    Result := ''
  else
    Result := ref.Uuid;
end;

procedure TfrmMain.SelectNodeByUuid(const AUuid: string);
var
  i: Integer;
begin
  for i := 0 to FTree.Items.Count - 1 do
    if (FTree.Items[i].Data <> nil) and
       (TNodeRef(FTree.Items[i].Data).Uuid = AUuid) then
    begin
      FTree.Items[i].Selected := True;
      FTree.Items[i].MakeVisible;
      Exit;
    end;
end;

procedure TfrmMain.TreeDeletion(Sender: TObject; Node: TTreeNode);
begin
  if Node.Data <> nil then
  begin
    TNodeRef(Node.Data).Free;
    Node.Data := nil;
  end;
end;

function TfrmMain.HasOpenSessionForConn(const AConnUuid: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (FPages = nil) or (AConnUuid = '') then Exit;
  for i := 0 to FPages.PageCount - 1 do
    if (FPages.Pages[i] is TSessionTabBase) and
       TSessionTabBase(FPages.Pages[i]).HasSessionFor(AConnUuid) then
      Exit(True);
end;

procedure TfrmMain.TreeAdvancedDrawItem(Sender: TCustomTreeView;
  Node: TTreeNode; State: TCustomDrawState; Stage: TCustomDrawStage;
  var PaintImages, DefaultDraw: Boolean);
var
  ref: TNodeRef;
  tr: TRect;
  bg, fg: TColor;
  ty: Integer;
  isActive: Boolean;
begin
  DefaultDraw := True;
  if Stage <> cdPostPaint then Exit;
  ref := nil;
  if Node.Data <> nil then
    ref := TNodeRef(Node.Data);
  isActive := (ref <> nil) and (ref.Kind = nkConnection) and
    HasOpenSessionForConn(ref.Uuid);
  if (cdsSelected in State) and (not isActive) then Exit;
  if cdsSelected in State then
    bg := clSideSel
  else
    bg := clSideBg;
  if isActive then
    fg := clSideActive
  else if cdsSelected in State then
    fg := clSideTextHi
  else
    fg := clSideText;
  tr := Node.DisplayRect(True);
  Sender.Canvas.Brush.Color := bg;
  Sender.Canvas.Brush.Style := bsSolid;
  Sender.Canvas.FillRect(tr);
  Sender.Canvas.Brush.Style := bsClear;
  Sender.Canvas.Font.Color := fg;
  ty := tr.Top + (tr.Bottom - tr.Top - Sender.Canvas.TextHeight('Ag')) div 2;
  Sender.Canvas.TextOut(tr.Left + 2, ty, Node.Text);
end;

{$IFDEF WINDOWS}
procedure TfrmMain.StatusDrawPanel(AStatusBar: TStatusBar;
  APanel: TStatusPanel; const ARect: TRect);
var
  ty: Integer;
begin
  with AStatusBar.Canvas do
  begin
    Brush.Color := clStatusBg;
    Brush.Style := bsSolid;
    Font.Color := clStatusText;
    ty := ARect.Top + (ARect.Bottom - ARect.Top - TextHeight('Ag')) div 2;
    TextRect(ARect, ARect.Left + 4, ty, APanel.Text);
  end;
end;
{$ENDIF}

procedure TfrmMain.TreePopupNeeded(Sender: TObject);
var
  ref: TNodeRef;
  isRoot, isGroup, isConn: Boolean;
  currentIcon: string;
  n: TRshNode;

  function Add(const ACaption: string; AHandler: TNotifyEvent;
    AEnabled: Boolean = True): TMenuItem;
  begin
    Result := TMenuItem.Create(FTreePopup);
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
    Result.Enabled := AEnabled;
    FTreePopup.Items.Add(Result);
  end;

begin
  FTreePopup.Items.Clear;
  if FModel = nil then Exit;
  ref := SelectedRef;
  if ref = nil then Exit;
  isRoot := ref.Uuid = '';
  isGroup := (not isRoot) and (ref.Kind = nkGroup);
  isConn := ref.Kind = nkConnection;

  if isRoot or isGroup then
  begin
    Add('Add Group…', @AddGroupClick);
    Add('Add SSH Connection…', @AddSshClick);
    Add('Add RDP Connection…', @AddRdpClick);
    Add('Add VNC Connection…', @AddVncClick);
    Add('Add Container…', @AddContainerClick);
    Add('Add Kubernetes Pod…', @AddPodClick);
  end;
  if isGroup then
  begin
    Add('-', nil);
    Add('Connect All in Folder', @ConnectAllInFolderClick);
    Add('Disconnect All in Folder', @DisconnectAllInFolderClick);
    Add('Broadcast SSH…', @ClusterSshClick);
    Add('-', nil);
    Add('Import Hosts from CSV…', @ImportHostsCsvClick);
  end;
  if isConn then
  begin
    Add('Connect', @ConnectClick, True);
    Add('-', nil);
    // ssh-copy-id sans terminal, si le credential est une cle geree
    if CanCopySshId(FModel, ref.Uuid) then
    begin
      Add('Copy SSH ID to This Host…', @CopySshIdClick);
      Add('-', nil);
    end;
    if FModel.IsFavorite(ref.Uuid) then
      Add('Remove from Favorites', @ToggleFavoriteClick)
    else
      Add('Add to Favorites', @ToggleFavoriteClick);
    Add('-', nil);
    Add('Copy Hostname', @CopyHostnameClick);
    Add('Copy Username', @CopyUsernameClick);
  end;
  if isRoot then
  begin
    Add('-', nil);
    Add('Change Icon…', @ChangeIconClick);
  end;
  if not isRoot then
  begin
    Add('-', nil);
    Add('Rename', @RenameClick);
    Add('Duplicate', @DuplicateClick);
    Add('Change Icon…', @ChangeIconClick);
  end;
  Add('-', nil);
  Add('Expand All', @ExpandAllClick);
  Add('Collapse All', @CollapseAllClick);
  if not isRoot then
  begin
    Add('-', nil);
    Add('Properties…', @PropertiesClick);
    Add('Delete…', @DeleteClick);
  end;
  {$IFNDEF DARWIN}
  ThemeMenuItems(FTreePopup.Items);
  {$ENDIF}
end;

procedure TfrmMain.TreeKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  ref: TNodeRef;
begin
  if (Key = VK_F2) and (SelectedUuid <> '') then
  begin
    Key := 0;
    RenameClick(Sender);
    Exit;
  end;
  if Key = VK_RETURN then
  begin
    ref := SelectedRef;
    if (ref = nil) or (ref.Uuid = '') then Exit;
    Key := 0;
    if ref.Kind = nkConnection then
      ConnectClick(Sender)
    else if FTree.Selected <> nil then
      FTree.Selected.Expanded := not FTree.Selected.Expanded;
  end;
end;

procedure TfrmMain.TreeDblClick(Sender: TObject);
var
  ref: TNodeRef;
begin
  ref := SelectedRef;
  if (ref <> nil) and (ref.Uuid <> '') and (ref.Kind = nkConnection) then
    ConnectClick(Sender);
end;

procedure TfrmMain.TreeEditing(Sender: TObject; Node: TTreeNode;
  var AllowEdit: Boolean);
begin
  // pas d'edition au clic lent: uniquement F2 / menu Rename
  AllowEdit := FEditRequested and (Node.Data <> nil) and
    (TNodeRef(Node.Data).Uuid <> '');
  FEditRequested := False;
  // l'editeur inline herite de FTree.Font (clair) sur un fond natif clair
  if AllowEdit then
    FTree.Font.Color := clWindowText;
end;

procedure TfrmMain.TreeEditingEnd(Sender: TObject; Node: TTreeNode;
  Cancel: Boolean);
begin
  FTree.Font.Color := clSideText;
end;

procedure TfrmMain.TreeEdited(Sender: TObject; Node: TTreeNode;
  var S: string);
var
  ref: TNodeRef;
begin
  ref := TNodeRef(Node.Data);
  if (ref = nil) or (ref.Uuid = '') then Exit;
  try
    FModel.RenameNode(ref.Uuid, S);
    S := Trim(S);
  except
    on E: EModelError do
    begin
      ShowModelError(E.Message);
      S := Node.Text;
    end;
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.TreeDragOver(Sender, Source: TObject; X, Y: Integer;
  State: TDragState; var Accept: Boolean);
var
  target: TTreeNode;
begin
  Accept := False;
  if (Source <> FTree) or (FModel = nil) then Exit;
  if (FTree.Selected = nil) or (SelectedUuid = '') then Exit;
  target := FTree.GetNodeAt(X, Y);
  Accept := target <> nil;
end;

procedure TfrmMain.TreeDragDrop(Sender, Source: TObject; X, Y: Integer);
var
  target: TTreeNode;
  srcUuid: string;
  tgtRef: TNodeRef;
  n: TRshNode;
begin
  if Source <> FTree then Exit;
  srcUuid := SelectedUuid;
  if srcUuid = '' then Exit;
  target := FTree.GetNodeAt(X, Y);
  if target = nil then Exit;
  tgtRef := TNodeRef(target.Data);
  if tgtRef = nil then Exit;
  try
    if (tgtRef.Uuid = '') or (tgtRef.Kind = nkGroup) then
      FModel.MoveNode(srcUuid, tgtRef.Uuid, -1)
    else
    begin
      n := FModel.GetNode(tgtRef.Uuid);
      try
        FModel.MoveNode(srcUuid, n.ParentUuid, n.SortOrder);
      finally
        n.Free;
      end;
    end;
    BuildTree;
    SelectNodeByUuid(srcUuid);
  except
    on E: EModelError do
    begin
      ShowModelError(E.Message);
      BuildTree;
    end;
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.SearchChanged(Sender: TObject);
begin
  if FModel <> nil then
    BuildTree;
end;

function TfrmMain.SearchFilter: string;
begin
  Result := FSearchBox.SearchText;
end;

procedure TfrmMain.SearchEscape(Sender: TObject);
begin
  if FTree.CanFocus then
    FTree.SetFocus;
end;

procedure TfrmMain.AddGroupClick(Sender: TObject);
var
  groupName, uuid: string;
begin
  groupName := '';
  if not InputQuery('New Group', 'Group name:', groupName) then Exit;
  try
    uuid := FModel.CreateGroup(SelectedUuid, groupName);
    BuildTree;
    SelectNodeByUuid(uuid);
  except
    on E: EModelError do
      ShowModelError(E.Message);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.AddSshClick(Sender: TObject);
var
  uuid: string;
begin
  uuid := ShowNewConnectionDialog(FModel, SelectedUuid, rpSsh);
  if uuid <> '' then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.AddRdpClick(Sender: TObject);
var
  uuid: string;
begin
  uuid := ShowNewConnectionDialog(FModel, SelectedUuid, rpRdp);
  if uuid <> '' then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.AddVncClick(Sender: TObject);
var
  uuid: string;
begin
  uuid := ShowNewConnectionDialog(FModel, SelectedUuid, rpVnc);
  if uuid <> '' then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.AddContainerClick(Sender: TObject);
var
  uuid: string;
begin
  uuid := ShowNewContainerDialog(FModel, SelectedUuid);
  if uuid <> '' then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.AddPodClick(Sender: TObject);
var
  uuid: string;
begin
  uuid := ShowNewPodDialog(FModel, SelectedUuid);
  if uuid <> '' then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.ConnectAllInFolderClick(Sender: TObject);
var
  ref: TNodeRef;
  list: TRshQuickList;
  i: Integer;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') or (ref.Kind <> nkGroup) then Exit;
  if FModel = nil then Exit;
  list := FModel.ListSubtreeConnections(ref.Uuid);
  try
    for i := 0 to list.Count - 1 do
      if not HasOpenSessionForConn(list[i].ConnUuid) then
        ConnectByUuid(list[i].ConnUuid);
  finally
    list.Free;
  end;
end;

procedure TfrmMain.DisconnectAllInFolderClick(Sender: TObject);
var
  ref: TNodeRef;
  list: TRshQuickList;
  i, j, nb: Integer;
  uuids: TStringList;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') or (ref.Kind <> nkGroup) then Exit;
  if (FModel = nil) or (FPages = nil) then Exit;
  list := FModel.ListSubtreeConnections(ref.Uuid);
  uuids := TStringList.Create;
  try
    uuids.Sorted := True;
    for i := 0 to list.Count - 1 do
      uuids.Add(list[i].ConnUuid);
    nb := CountLiveSessionsIn(uuids);
    if nb = 0 then Exit;
    if QuestionDlg('Disconnect All',
      Format('Disconnect %d session(s) in this folder?', [nb]),
      mtConfirmation,
      [mrOK, 'Disconnect', mrCancel, 'Cancel', 'IsCancel'], 0) <> mrOK then
      Exit;
    // QuestionDlg pompe les messages: des onglets ont pu mourir, on recompte
    if CountLiveSessionsIn(uuids) = 0 then Exit;
    for j := 0 to FPages.PageCount - 1 do
      SessionTabShutdownIn(FPages.Pages[j], uuids);
  finally
    uuids.Free;
    list.Free;
  end;
  UpdateSessionUi;
end;

function TfrmMain.GroupNameOf(const AUuid: string): string;
var
  nref: TRshNode;
begin
  Result := 'Broadcast';
  if (FModel = nil) or (AUuid = '') then Exit;
  nref := FModel.GetNode(AUuid);
  try
    Result := nref.DisplayName;
  finally
    nref.Free;
  end;
end;

procedure TfrmMain.ClusterSshClick(Sender: TObject);
var
  ref: TNodeRef;
  list: TRshQuickList;
  displays, uuids: array of string;
  params: array of TSshConnectParams;
  tunnels: array of TSshTunnel;
  brokers: array of TSshTunnelBroker;
  p: TSshConnectParams;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  jumpUuid, dn, err, grpName: string;
  i, cnt, totalSsh, nbPrompt, localPort: Integer;
  tab: TClusterSshTab;
  transferred: Boolean;
  newHosts: array of string;
  kh: TSshKnownHosts;
  bulkDecision: TSshHostKeyDecision;
  bulkAsked, bulkCancelled: Boolean;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') or (ref.Kind <> nkGroup) then Exit;
  if (FModel = nil) or (FDoc = nil) then Exit;

  list := FModel.ListSubtreeConnections(ref.Uuid);
  try
    cnt := 0;
    totalSsh := 0;
    nbPrompt := 0;
    for i := 0 to list.Count - 1 do
      if list[i].Protocol = rpSsh then
      begin
        Inc(totalSsh);
        // un hote qui demande un secret ouvrirait sa modale avant la grille
        if SshConnectWouldPrompt(FModel, list[i].ConnUuid) then
        begin
          Inc(nbPrompt);
          Continue;
        end;
        Inc(cnt);
      end;
    if totalSsh = 0 then
    begin
      MessageDlg('Broadcast SSH', 'No SSH connection under this folder.',
        mtInformation, [mbOK], 0);
      Exit;
    end;
    if cnt = 0 then
    begin
      MessageDlg('Broadcast SSH', Format('No SSH connection under this ' +
        'folder can be broadcast: %d ask for credentials at connect time. ' +
        'Give them a stored or inherited credential first.', [nbPrompt]),
        mtInformation, [mbOK], 0);
      Exit;
    end;
    if cnt > CLUSTER_MAX_SESSIONS then
    begin
      MessageDlg('Broadcast SSH', Format(
        'This folder contains %d SSH connections; the broadcast view is ' +
        'limited to %d.', [cnt, CLUSTER_MAX_SESSIONS]), mtWarning, [mbOK], 0);
      Exit;
    end;
    // en amont: sinon la (N+1)e inscription leve en pleine grille
    if FSessions.Count + cnt > FSessions.MaxSessions then
    begin
      MessageDlg('Broadcast SSH', Format(
        'Not enough session slots: %d needed, %d available.',
        [cnt, FSessions.MaxSessions - FSessions.Count]), mtWarning, [mbOK], 0);
      Exit;
    end;

    SetLength(displays, 0);
    SetLength(uuids, 0);
    SetLength(params, 0);
    SetLength(tunnels, 0);
    SetLength(brokers, 0);
    transferred := False;
    try
      for i := 0 to list.Count - 1 do
      begin
        if list[i].Protocol <> rpSsh then Continue;
        if SshConnectWouldPrompt(FModel, list[i].ConnUuid) then
        begin
          SessionNotice(Format(
            '%s: asks for credentials at connect time, skipped in Broadcast.',
            [list[i].DisplayName]));
          Continue;
        end;
        if not BuildSshConnectParams(FDoc, FModel, list[i].ConnUuid,
          p, dn, err) then
        begin
          if err <> '' then
            SessionNotice(Format('%s: %s', [list[i].DisplayName, err]));
          Continue;
        end;
        // un tunnel par cellule, la cellule en prend possession
        tun := nil;
        broker := nil;
        jumpUuid := FModel.GetJumpVia(list[i].ConnUuid);
        if jumpUuid <> '' then
        begin
          if not EstablishJumpTunnel(FDoc, FModel, jumpUuid, p.Host, p.Port,
            tun, broker, localPort, err) then
          begin
            if err <> '' then
              SessionNotice(Format('%s: %s', [list[i].DisplayName, err]));
            p.Free;
            Continue;
          end;
          p.ConnectHost := '127.0.0.1';
          p.ConnectPort := localPort;
        end;
        SetLength(displays, Length(displays) + 1);
        displays[High(displays)] := dn;
        SetLength(uuids, Length(uuids) + 1);
        uuids[High(uuids)] := list[i].ConnUuid;
        SetLength(params, Length(params) + 1);
        params[High(params)] := p;
        SetLength(tunnels, Length(tunnels) + 1);
        tunnels[High(tunnels)] := tun;
        SetLength(brokers, Length(brokers) + 1);
        brokers[High(brokers)] := broker;
        p := nil;
        tun := nil;
        broker := nil;
      end;
      if Length(params) = 0 then Exit;

      // trancher AVANT le demarrage: apres, les AskHostKey s'empilent en modales
      SetLength(newHosts, 0);
      kh := TSshKnownHosts.Create(FDoc);
      try
        for i := 0 to High(params) do
          if Length(kh.KnownKeyTypes(params[i].Host, params[i].Port)) = 0 then
          begin
            SetLength(newHosts, Length(newHosts) + 1);
            newHosts[High(newHosts)] := Format('%s  (%s:%d)',
              [displays[i], params[i].Host, params[i].Port]);
          end;
      finally
        kh.Free;
      end;
      bulkAsked := False;
      bulkDecision := hkdReject;
      if Length(newHosts) > 1 then
      begin
        if AskBulkUnknownHostKeys(newHosts, bulkDecision, bulkCancelled) then
          bulkAsked := True
        else if bulkCancelled then
          Exit;
      end;

      // CreateCluster PREND POSSESSION des params/tunnels, meme si elle leve
      grpName := GroupNameOf(ref.Uuid);
      transferred := True;
      tab := TClusterSshTab.CreateCluster(FPages, FDoc, FSessions,
        grpName, displays, uuids, params, tunnels, brokers);
      tab.OnNotice := @SessionNotice;
      tab.OnDestroyed := @SessionTabGone;
      tab.OnStatusChanged := @SessionStatusChanged;
      if bulkAsked then
        tab.SetUnknownHostKeyPolicy(bulkDecision);
      FPages.ActivePage := tab;
      tab.Start;
      UpdateSessionUi;
    finally
      if not transferred then
        for i := 0 to High(params) do
        begin
          params[i].Free;
          if tunnels[i] <> nil then
          begin
            tunnels[i].Shutdown;
            tunnels[i].Free;
          end;
          brokers[i].Free;
        end;
    end;
  finally
    list.Free;
  end;
end;

procedure TfrmMain.RenameClick(Sender: TObject);
begin
  if (FTree.Selected = nil) or (SelectedUuid = '') then Exit;
  FEditRequested := True;
  FTree.Selected.EditText;
end;

procedure TfrmMain.DuplicateClick(Sender: TObject);
var
  uuid: string;
begin
  if SelectedUuid = '' then Exit;
  try
    uuid := FModel.DuplicateNode(SelectedUuid);
    BuildTree;
    SelectNodeByUuid(uuid);
  except
    on E: EModelError do
      ShowModelError(E.Message);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.DeleteClick(Sender: TObject);
var
  ref: TNodeRef;
  msg: string;
  live: Integer;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') then Exit;
  // un onglet survivrait a un noeud disparu: on refuse tant qu'une session vit
  live := CountLiveSessionsInNode(ref.Uuid, ref.Kind = nkGroup);
  if live > 0 then
  begin
    if ref.Kind = nkGroup then
      MessageDlg(RSSH_APP_NAME, Format('This folder still has %d open ' +
        'session(s). Disconnect them before deleting it.', [live]),
        mtWarning, [mbOK], 0)
    else
      MessageDlg(RSSH_APP_NAME, 'This connection is still open. Disconnect ' +
        'it before deleting it.', mtWarning, [mbOK], 0);
    Exit;
  end;
  if (ref.Kind = nkConnection) and (NodeProtocol(ref.Uuid) = rpSsh) then
  begin
    live := FModel.CountContainerDependents(ref.Uuid);
    if live > 0 then
      if MessageDlg(RSSH_APP_NAME, Format('This host is used by %d ' +
        'container(s). Deleting it will leave them unusable. Delete anyway?',
        [live]), mtWarning, [mbYes, mbCancel], 0) <> mrYes then Exit;
    live := FModel.CountPodDependents(ref.Uuid);
    if live > 0 then
      if MessageDlg(RSSH_APP_NAME, Format('This host is used by %d ' +
        'pod(s). Deleting it will leave them unusable. Delete anyway?',
        [live]), mtWarning, [mbYes, mbCancel], 0) <> mrYes then Exit;
  end;
  if ref.Kind = nkGroup then
    msg := 'Delete this folder and everything in it?'
  else if NodeProtocol(ref.Uuid) = rpContainer then
    msg := 'Delete this container?'
  else if NodeProtocol(ref.Uuid) = rpPod then
    msg := 'Delete this pod?'
  else
    msg := 'Delete this connection?';
  if MessageDlg(RSSH_APP_NAME, msg, mtConfirmation, [mbYes, mbCancel], 0)
    <> mrYes then Exit;
  try
    FModel.DeleteNode(ref.Uuid);
    BuildTree;
  except
    on E: EModelError do
      ShowModelError(E.Message);
  end;
  UpdateDocumentState;
end;

function TfrmMain.NodeProtocol(const AUuid: string): TRshProtocol;
var
  n: TRshNode;
begin
  Result := rpSsh;
  if AUuid = '' then Exit;
  try
    n := FModel.GetNode(AUuid);
  except
    on EModelError do Exit;
  end;
  try
    if n.Kind = nkConnection then
      Result := n.Protocol;
  finally
    n.Free;
  end;
end;

procedure TfrmMain.PropertiesClick(Sender: TObject);
var
  ref: TNodeRef;
  uuid: string;
  isGroup, modified: Boolean;
begin
  ref := SelectedRef;
  if (ref = nil) or (ref.Uuid = '') then Exit;
  // copie AVANT le dialogue: BuildTree detruit les TNodeRef de l'arbre
  uuid := ref.Uuid;
  isGroup := ref.Kind = nkGroup;
  if isGroup then
    modified := ShowGroupProperties(FModel, uuid)
  else if NodeProtocol(uuid) = rpContainer then
    modified := ShowContainerProperties(FModel, uuid)
  else if NodeProtocol(uuid) = rpPod then
    modified := ShowPodProperties(FModel, uuid)
  else
    modified := ShowConnectionProperties(FModel, uuid);
  if modified then
  begin
    BuildTree;
    SelectNodeByUuid(uuid);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.ChangeIconClick(Sender: TObject);
var
  ref: TNodeRef;
  uuid, iconId, current: string;
  n: TRshNode;
begin
  if FModel = nil then Exit;
  ref := SelectedRef;
  if ref = nil then Exit;
  uuid := ref.Uuid;

  if uuid = '' then
  begin
    current := ResolveIconId(FModel.GetRootIcon);
    if current = '' then
      current := ICON_ROOT_DEFAULT;
  end
  else
  begin
    current := '';
    try
      n := FModel.GetNode(uuid);
      try
        current := ResolveIconId(n.IconId);
      finally
        n.Free;
      end;
    except
      on EModelError do ;
    end;
  end;

  if not ChooseTreeIcon(Self, current, iconId) then Exit;
  try
    if uuid = '' then
    begin
      FModel.SetRootIcon(iconId);
      BuildTree;
    end
    else
    begin
      FModel.SetNodeIcon(uuid, iconId);
      BuildTree;
      SelectNodeByUuid(uuid);
    end;
  except
    on E: EModelError do
      ShowModelError(E.Message);
  end;
  UpdateDocumentState;
end;

procedure TfrmMain.CopyHostnameClick(Sender: TObject);
var
  n: TRshNode;
begin
  if SelectedUuid = '' then Exit;
  n := FModel.GetNode(SelectedUuid);
  try
    Clipboard.AsText := n.Hostname;
  finally
    n.Free;
  end;
end;

procedure TfrmMain.CopyUsernameClick(Sender: TObject);
var
  n: TRshNode;
  cred, src: string;
  c: TRshCredential;
begin
  if SelectedUuid = '' then Exit;
  n := FModel.GetNode(SelectedUuid);
  try
    cred := n.CredentialUuid;
  finally
    n.Free;
  end;
  if cred = '' then Exit;
  c := FModel.GetCredential(cred);
  try
    Clipboard.AsText := c.Username;
  finally
    c.Free;
  end;
end;

procedure TfrmMain.ExpandAllClick(Sender: TObject);
begin
  FTree.FullExpand;
end;

procedure TfrmMain.CollapseAllClick(Sender: TObject);
begin
  FTree.FullCollapse;
  if FTree.Items.Count > 0 then
    FTree.Items[0].Expand(False);
end;

procedure TfrmMain.FindClick(Sender: TObject);
begin
  if FSearchBox.CanFocusEdit then
    FSearchBox.FocusEdit;
end;

procedure TfrmMain.TerminalFontClick(Sender: TObject);
begin
  if not ShowTerminalFontDialog then
    Exit;
  MessageDlg(RSSH_APP_NAME,
    'The new font will apply to the next sessions.',
    mtInformation, [mbOK], 0);
end;

procedure TfrmMain.TakeScreenshotClick(Sender: TObject);

  function SanitizeForFile(const S: string): string;
  var
    i: Integer;
    c: Char;
    lastUnd: Boolean;
  begin
    Result := '';
    lastUnd := False;
    for i := 1 to Length(S) do
    begin
      c := S[i];
      if c in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '(', ')'] then
      begin
        Result := Result + c;
        lastUnd := False;
      end
      else if not lastUnd then
      begin
        Result := Result + '_';
        lastUnd := True;
      end;
    end;
    while (Result <> '') and (Result[1] = '_') do
      Delete(Result, 1, 1);
    while (Result <> '') and (Result[Length(Result)] = '_') do
      SetLength(Result, Length(Result) - 1);
    if Result = '' then
      Result := 'screenshot';
  end;

var
  bmp: TBitmap;
  png: TPortableNetworkGraphic;
  dlg: TSaveDialog;
  mem: TMemoryStream;
begin
  if (FPages = nil) or not (FPages.ActivePage is TSessionTabBase) then
    Exit;
  // rendu hors-ecran pleine resolution; l'appelant possede le bitmap
  bmp := TSessionTabBase(FPages.ActivePage).GrabThumbnail;
  if bmp = nil then
  begin
    MessageDlg(RSSH_APP_NAME, 'This session has nothing to capture yet.',
      mtInformation, [mbOK], 0);
    Exit;
  end;
  try
    dlg := TSaveDialog.Create(Self);
    try
      dlg.Title := 'Take Screenshot';
      dlg.DefaultExt := 'png';
      dlg.Filter := 'PNG image (*.png)|*.png';
      dlg.Options := dlg.Options + [ofOverwritePrompt, ofPathMustExist];
      dlg.FileName :=
        SanitizeForFile(TSessionTabBase(FPages.ActivePage).TabBarCaption) +
        '-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.png';
      if not dlg.Execute then
        Exit;
      png := TPortableNetworkGraphic.Create;
      try
        png.Assign(bmp);
        try
          mem := TMemoryStream.Create;
          try
            png.SaveToStream(mem);
            SavePrivateStream(dlg.FileName, mem);
          finally
            mem.Free;
          end;
        except
          on E: Exception do
            MessageDlg(RSSH_APP_NAME, 'Cannot write image: ' + E.Message,
              mtError, [mbOK], 0);
        end;
      finally
        png.Free;
      end;
    finally
      dlg.Free;
    end;
  finally
    bmp.Free;
  end;
end;

procedure TfrmMain.LocalTerminalClick(Sender: TObject);
var
  tab: TLocalTermTab;
  err: string;
begin
  tab := TLocalTermTab.CreateTab(FPages);
  tab.OnDestroyed := @SessionTabGone;
  tab.OnStatusChanged := @SessionStatusChanged;
  tab.Terminal.OnEscapeCapture := @SessionEscapeCapture;
  FPages.ActivePage := tab;
  if not tab.Start(err) then
  begin
    tab.Free;
    MessageDlg(RSSH_APP_NAME, 'Cannot start shell: ' + err, mtError, [mbOK], 0);
    Exit;
  end;
  UpdateSessionUi;
  tab.FocusContent;
end;

procedure TfrmMain.CredentialManagerClick(Sender: TObject);
begin
  if (FDoc = nil) or FDoc.Locked or (FModel = nil) then Exit;
  ShowCredentialManager(Self, FDoc, FModel, @SaveClick);
  BuildTree;
  UpdateDocumentState;
end;

procedure TfrmMain.CopySshIdClick(Sender: TObject);
var
  ref: TNodeRef;
  err: string;
begin
  if (FDoc = nil) or FDoc.Locked or (FModel = nil) then Exit;
  ref := SelectedRef;
  if (ref = nil) or (ref.Kind <> nkConnection) then Exit;
  if CopySshIdToHost(FDoc, FModel, ref.Uuid, err) then
    MessageDlg('Copy SSH ID',
      'The public key is now installed on this host.' + LineEnding +
      'New SSH sessions will authenticate with the managed key.',
      mtInformation, [mbOK], 0)
  else if err <> '' then
    MessageDlg('Copy SSH ID', err, mtError, [mbOK], 0);
end;

procedure TfrmMain.ApplyThemeToUi;
begin
  Color := clAppBg;
  if FLeftPanel <> nil then
    FLeftPanel.Color := clSideBg;
  if FSessionPanel <> nil then
    FSessionPanel.Color := clAppBg;
  if FTree <> nil then
  begin
    FTree.Color := clSideBg;
    FTree.Font.Color := clSideText;
    FTree.BackgroundColor := clSideBg;
  end;
  if FTreeScroll <> nil then
    FTreeScroll.ApplyTheme(clSideBg,
      BlendColor(clSideText, clSideBg, 22),
      BlendColor(clSideText, clSideBg, 42));
  if FSearchBox <> nil then
    FSearchBox.ApplyTheme(
      clSideBg,
      clSideHover,
      BlendColor(clSideText, clSideBg, 30),
      clAccent,
      clSideText,
      BlendColor(clSideText, clSideBg, 55),
      BlendColor(clSideText, clSideBg, 45));
  if FLockPanel <> nil then
    FLockPanel.Color := clSideBg;
  if FLockLabel <> nil then
    FLockLabel.Font.Color := clSideText;
  if FStatusBar <> nil then
  begin
    FStatusBar.Color := clStatusBg;
    FStatusBar.Font.Color := clStatusText;
    FStatusBar.Invalidate;
  end;
  RebuildTreeImages;
  if FTree <> nil then
    FTree.Invalidate;
  if FTabBar <> nil then
    FTabBar.RefreshTheme;
  {$IFNDEF DARWIN}
  if FMenuBar <> nil then
    FMenuBar.RefreshTheme;
  {$ENDIF}
  Invalidate;
end;

procedure TfrmMain.RebuildTreeImages;
var
  old: TImageList;
begin
  if FTree = nil then Exit;
  old := FTreeImages;
  FTreeImages := BuildTreeImageList(Self, Screen.PixelsPerInch);
  FTree.Images := FTreeImages;
  if FTreePopup <> nil then
    FTreePopup.Images := FTreeImages;
  BuildTree;
  old.Free;
end;

procedure TfrmMain.ThemeClick(Sender: TObject);
begin
  if not (Sender is TMenuItem) then Exit;
  if not ApplyThemeIndex(TMenuItem(Sender).Tag) then Exit;
  TMenuItem(Sender).Checked := True;
  PrefThemeName := CurrentThemeName;
  SavePreferences;
  ApplyThemeToUi;
  LogInfo('theme applied: ' + CurrentThemeName);
end;

procedure TfrmMain.LogEnabledClick(Sender: TObject);
begin
  PrefLogEnabled := not PrefLogEnabled;
  FMiLogEnabled.Checked := PrefLogEnabled;
  ApplyLogPreferences;
  SavePreferences;
  if PrefLogEnabled then
    LogInfo('logging enabled by the user');
end;

procedure TfrmMain.LogDebugClick(Sender: TObject);
begin
  PrefLogDebug := not PrefLogDebug;
  FMiLogDebug.Checked := PrefLogDebug;
  ApplyLogPreferences;
  SavePreferences;
end;

procedure TfrmMain.LogConfidentialClick(Sender: TObject);
begin
  PrefLogConfidential := not PrefLogConfidential;
  FMiLogConfidential.Checked := PrefLogConfidential;
  ApplyLogPreferences;
  SavePreferences;
end;

procedure TfrmMain.OpenLogFolderClick(Sender: TObject);
var
  d: string;
begin
  d := LogDir;
  if not DirectoryExists(d) then
    ForceDirectories(d);
  LCLIntf.OpenDocument(d);
end;

function TfrmMain.DocCommandsBusy: Boolean;
begin
  Result := FConnecting or FPwDelay;
end;

procedure TfrmMain.BruteForceDelay;
var
  waitMs, slept: Integer;
begin
  if FPwFailCount <= 0 then Exit;
  waitMs := Min(1 shl Min(FPwFailCount - 1, 5), 30) * 1000;
  slept := 0;
  // ProcessMessages evite la fenetre gelee mais rend le menu cliquable: sans
  // cette garde, un Fermer libere FDoc sous les pieds de l'appelant suspendu ici
  FPwDelay := True;
  Screen.Cursor := crHourGlass;
  try
    while slept < waitMs do
    begin
      Sleep(100);
      Inc(slept, 100);
      Application.ProcessMessages;
    end;
  finally
    Screen.Cursor := crDefault;
    FPwDelay := False;
  end;
end;

function TfrmMain.ConfirmCloseCurrent: Boolean;
var
  err: TDocError;
begin
  Result := True;
  if DocCommandsBusy then Exit(False);
  if FDoc = nil then Exit;
  // decider AVANT de fermer, un Cancel doit tout laisser intact
  if FDoc.Dirty then
    case QuestionDlg(RSSH_APP_NAME, 'The document has been modified.',
      mtConfirmation,
      [mrYes, 'Save', mrNo, 'Don''t Save',
       mrCancel, 'Cancel', 'IsCancel'], 0) of
      mrYes:
        begin
          // resceller l'enveloppe exige la matiere de cle effacee au
          // verrou -- on la redemande plutot que de rendre « Save » morte
          if FDoc.Locked and not UnlockInteractive then
            Exit(False);
          if FDoc.SourcePath = '' then
          begin
            if not SaveAsInteractive then Exit(False);
          end
          else if not FDoc.Save(err) then
          begin
            ShowDocError(err);
            Exit(False);
          end;
        end;
      mrNo: ;
    else
      Exit(False);
    end;
  if not CloseAllSessions(True) then
    Exit(False);
  CloseDashboard;
  FreeAndNil(FModel);
  FreeAndNil(FDoc);
  // drapeau global: fermer sans deverrouiller le laissait leve pour toujours
  SetClipboardSharingSuspended(False);
  BuildTree;
  UpdateDocumentState;
end;

procedure TfrmMain.NewDocClick(Sender: TObject);
var
  dlg: TSaveDialog;
  pw: RawByteString;
  doc: TRshDocument;
  err: TDocError;
  path: string;
begin
  if DocCommandsBusy then Exit;
  dlg := TSaveDialog.Create(Self);
  try
    dlg.Title := 'New Document';
    dlg.DefaultExt := 'rsh';
    dlg.Filter := 'RottenSSHrimp documents (*.rsh)|*.rsh';
    dlg.Options := dlg.Options + [ofOverwritePrompt, ofPathMustExist];
    if not dlg.Execute then Exit;
    path := dlg.FileName;
  finally
    dlg.Free;
  end;
  if not NormalizeRshSaveName(path) then Exit;
  if not AskNewDocumentPassword(pw) then Exit;
  try
    // on ne ferme QU'ICI, chemin et mot de passe acquis: annuler ne detruit rien
    if not ConfirmCloseCurrent then Exit;
    Screen.Cursor := crHourGlass;
    try
      if not TRshDocument.NewDocument(path, pw, doc, err) then
      begin
        ShowDocError(err);
        Exit;
      end;
    finally
      Screen.Cursor := crDefault;
    end;
    FDoc := doc;
    FModel := TRshModel.Create(FDoc);
    RecentAdd(path);
    BuildTree;
    UpdateDocumentState;
  finally
    if pw <> '' then
      FillChar(pw[1], Length(pw), 0);
  end;
end;

procedure TfrmMain.OpenDocClick(Sender: TObject);
var
  dlg: TOpenDialog;
  path: string;
begin
  if DocCommandsBusy then Exit;
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Open Document';
    dlg.DefaultExt := 'rsh';
    dlg.Filter := 'RottenSSHrimp documents (*.rsh)|*.rsh|All files (*)|*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if not dlg.Execute then Exit;
    path := dlg.FileName;
  finally
    dlg.Free;
  end;
  OpenDocumentPath(path);
end;

// Ouverture par CHEMIN, sans dialogue: partagee par File > Open Document et
// par File > Open Recent, pour que la MRU emprunte exactement le meme chemin
// de code (verrou, lecture seule, reessai du mot de passe).
procedure TfrmMain.OpenDocumentPath(const APath: string);
var
  pw: RawByteString;
  doc: TRshDocument;
  err: TDocError;
  path: string;
  retry, ro, sameFile, havePw: Boolean;
begin
  if DocCommandsBusy then Exit;
  if APath = '' then Exit;
  path := APath;
  ro := False;
  havePw := False;
  // rouvrir LE fichier deja ouvert: le verrou est a nous, on ferme d'abord.
  // ResolveLink car ExpandFileNameUTF8 ne suit pas les symlinks.
  sameFile := (FDoc <> nil) and (FDoc.SourcePath <> '') and
    (CompareFilenames(ResolveLink(ExpandFileNameUTF8(path)),
      ResolveLink(ExpandFileNameUTF8(FDoc.SourcePath))) = 0);
  if sameFile then
  begin
    // verifie sur le document deja ouvert: fermer d'abord puis decouvrir la
    // faute de frappe laissait l'utilisateur sans document ni sessions
    repeat
      if not AskOpenPassword(path, pw) then Exit;
      BruteForceDelay;
      if FDoc.VerifyPassword(pw) then Break;
      Inc(FPwFailCount);
      if pw <> '' then
        FillChar(pw[1], Length(pw), 0);
      ShowDocError(BadPasswordError('mot de passe refuse avant reouverture'));
    until False;
    FPwFailCount := 0;
    havePw := True;
    if not ConfirmCloseCurrent then
    begin
      if pw <> '' then
        FillChar(pw[1], Length(pw), 0);
      Exit;
    end;
    sameFile := False;
  end;
  // l'ouverture reussirait, seul le Save echouerait plus tard
  if not DirectoryIsWritable(ExtractFilePath(ExpandFileNameUTF8(path))) then
    if MessageDlg('Read-only location',
      'This document is on a read-only location and cannot be saved back here.'
      + LineEnding + LineEnding + 'Open read-only?',
      mtWarning, [mbOK, mbCancel], 0) = mrOK then
      ro := True;
  repeat
    retry := False;
    if havePw then
      havePw := False
    else if not AskOpenPassword(path, pw) then
      Exit;
    try
      BruteForceDelay;
      Screen.Cursor := crHourGlass;
      try
        if TRshDocument.OpenDocument(path, pw, doc, err, ro) then
        begin
          FPwFailCount := 0;
          Screen.Cursor := crDefault;
          if not ConfirmCloseCurrent then
          begin
            doc.Free;
            Exit;
          end;
          FDoc := doc;
          FModel := TRshModel.Create(FDoc);
          BuildTree;
          UpdateDocumentState;
          if FTree.CanFocus then
            FTree.SetFocus;
          RecentAdd(path);
          if ro then
            LogInfo('document opened read-only: ' + RedactHome(path))
          else
            LogInfo('document opened: ' + RedactHome(path));
          Exit;
        end;
      finally
        Screen.Cursor := crDefault;
      end;
      if err.Code = decLocked then
      begin
        if MessageDlg('Document already open', err.UserMessage + LineEnding +
          LineEnding + 'Open read-only?', mtWarning,
          [mbOK, mbCancel], 0) = mrOK then
        begin
          ro := True;
          retry := True;
        end;
        Continue;
      end;
      ShowDocError(err);
      if err.Code = decBadPasswordOrCorrupt then
      begin
        Inc(FPwFailCount);
        retry := True;
      end;
    finally
      if pw <> '' then
        FillChar(pw[1], Length(pw), 0);
    end;
  until not retry;
end;

procedure TfrmMain.SaveClick(Sender: TObject);
var
  err: TDocError;
begin
  if FDoc = nil then Exit;
  if FDoc.SourcePath = '' then
  begin
    SaveAsClick(Sender);
    Exit;
  end;
  if not FDoc.Save(err) then
  begin
    case err.Code of
      decConflict:
        case QuestionDlg('External change', err.UserMessage + LineEnding +
          LineEnding + 'What do you want to do?', mtWarning,
          [mrYes, 'Overwrite', mrNo, 'Save As…', mrCancel, 'Cancel'], 0) of
          mrYes:
            if not FDoc.SaveOverwrite(err) then
              ShowDocError(err);
          mrNo:
            SaveAsInteractive;
        end;
      decReadOnly:
        if MessageDlg('Read-only document', err.UserMessage, mtInformation,
          [mbOK, mbCancel], 0) = mrOK then
          SaveAsInteractive;
    else
      ShowDocError(err);
    end;
  end;
  UpdateDocumentState;
end;

// OPENFILENAME n'ajoute pas DefaultExt si un fichier porte exactement le nom
// TAPE: on force .rsh et on repose la question d'ecrasement sur le nom corrige
function TfrmMain.NormalizeRshSaveName(var APath: string): Boolean;
begin
  Result := True;
  if SameText(ExtractFileExt(APath), '.rsh') then
    Exit;
  APath := APath + '.rsh';
  if FileExists(APath) then
    Result := MessageDlg('Replace file',
      Format('%s already exists. Replace it?', [ExtractFileName(APath)]),
      mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

function TfrmMain.SaveAsInteractive: Boolean;
var
  dlg: TSaveDialog;
  err: TDocError;
  path: string;
begin
  Result := False;
  if FDoc = nil then Exit;
  dlg := TSaveDialog.Create(Self);
  try
    dlg.Title := 'Save Document As';
    dlg.DefaultExt := 'rsh';
    dlg.Filter := 'RottenSSHrimp documents (*.rsh)|*.rsh';
    dlg.Options := dlg.Options + [ofOverwritePrompt, ofPathMustExist];
    if not dlg.Execute then Exit;
    path := dlg.FileName;
    if not NormalizeRshSaveName(path) then Exit;
    if FDoc.SaveAs(path, err) then
    begin
      Result := True;
      RecentAdd(path);   // le document vit desormais ici, pas a son ancien nom
    end
    else
      ShowDocError(err);
    BuildTree;
    UpdateDocumentState;
  finally
    dlg.Free;
  end;
end;

procedure TfrmMain.SaveAsClick(Sender: TObject);
begin
  SaveAsInteractive;
end;

procedure TfrmMain.ChangePasswordClick(Sender: TObject);
var
  oldPw, newPw: RawByteString;
  err: TDocError;
begin
  if FDoc = nil then Exit;
  if not AskCurrentPassword(oldPw) then Exit;
  try
    if not AskNewDocumentPassword(newPw, 'Change Master Password', 'Change')
    then
      Exit;
    try
      Screen.Cursor := crHourGlass;
      try
        if FDoc.ChangeMasterPassword(oldPw, newPw, err) then
          MessageDlg(RSSH_APP_NAME, 'Master password changed.',
            mtInformation, [mbOK], 0)
        else
          ShowDocError(err);
      finally
        Screen.Cursor := crDefault;
      end;
      UpdateDocumentState;
    finally
      if newPw <> '' then
        FillChar(newPw[1], Length(newPw), 0);
    end;
  finally
    if oldPw <> '' then
      FillChar(oldPw[1], Length(oldPw), 0);
  end;
end;

procedure TfrmMain.IntegrityClick(Sender: TObject);
begin
  if FDoc = nil then Exit;
  Screen.Cursor := crHourGlass;
  try
    if FDoc.Db.IntegrityCheckOk then
      MessageDlg(RSSH_APP_NAME, 'Integrity check passed.', mtInformation,
        [mbOK], 0)
    else
      MessageDlg(RSSH_APP_NAME, 'Integrity check FAILED. Save a copy with' +
        ' Save Document As… and stop using the original file.',
        mtError, [mbOK], 0);
  finally
    Screen.Cursor := crDefault;
  end;
end;

procedure TfrmMain.CloseDocClick(Sender: TObject);
begin
  ConfirmCloseCurrent;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if DocCommandsBusy then
  begin
    CanClose := False;
    Exit;
  end;
  CanClose := ConfirmCloseCurrent;
end;

procedure TfrmMain.HandleAppException(Sender: TObject; E: Exception);
var
  ctx, report: string;
begin
  ctx := Format('%s %s; fpc %s', [RSSH_APP_NAME, RSSH_VERSION,
    {$I %FPCVERSION%}]);
  report := WriteCrashReport(E, ctx);
  LogError('unhandled exception: ' + E.ClassName);
  if report <> '' then
    MessageDlg(RSSH_APP_NAME,
      Format('An unexpected error occurred:'#10'%s'#10#10 +
        'A crash report was saved to:'#10'%s', [E.Message, report]),
      mtError, [mbOK], 0)
  else
    MessageDlg(RSSH_APP_NAME,
      'An unexpected error occurred:'#10 + E.Message, mtError, [mbOK], 0);
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if FRecoveryChecked then Exit;
  FRecoveryChecked := True;
  // repose ici: sous Cocoa la restauration d'etat ecrase un wsMaximized trop tot
  WindowState := wsMaximized;
  // no-op sous Unix: supprimer un temoin sous flock casserait l'exclusion
  PurgeStaleDocumentLocks;
  CheckCrashRecovery;
end;

procedure TfrmMain.CheckCrashRecovery;
var
  items: TRecoveryItems;
  idx: Integer;
  choice: TRecoveryChoice;
begin
  items := ScanOrphanRecoveries;
  while Length(items) > 0 do
  begin
    if not ShowCrashRecovery(items, idx, choice) then
      Exit;
    if (idx < 0) or (idx > High(items)) then Exit;
    case choice of
      rcDelete:
        DiscardRecovery(items[idx]);
      rcSaveCopy:
        RecoverToFile(items[idx]);
      rcRecover:
        begin
          RecoverAsCurrent(items[idx]);
          Exit;
        end;
    end;
    items := ScanOrphanRecoveries;
  end;
end;

procedure TfrmMain.RecoverAsCurrent(const AItem: TRecoveryItem);
var
  pw: RawByteString;
  doc: TRshDocument;
  origin: string;
  err: TDocError;
  promptName: string;
begin
  if AItem.OriginPath <> '' then
    promptName := AItem.OriginPath
  else
    promptName := AItem.WorkingPath;
  if not AskOpenPassword(promptName, pw) then Exit;
  try
    // recuperer d'abord, remplacer ensuite: annuler ne coute alors rien
    if TRshDocument.RecoverDocument(AItem.WorkingPath, pw, doc, origin, err) then
    begin
      if not ConfirmCloseCurrent then
      begin
        doc.Free;
        Exit;
      end;
      FDoc := doc;
      FModel := TRshModel.Create(FDoc);
      BuildTree;
      UpdateDocumentState;
      LogInfo('document recovered after an abnormal shutdown');
      DiscardRecovery(AItem);
      if doc.RecoveredUnsaved then
        MessageDlg(RSSH_APP_NAME,
          'Recovered unsaved changes. Use Save Document As… to keep them.',
          mtInformation, [mbOK], 0);
    end
    else
      ShowDocError(err);
  finally
    if pw <> '' then
      FillChar(pw[1], Length(pw), 0);
  end;
end;

function TfrmMain.RecoverToFile(const AItem: TRecoveryItem): Boolean;
var
  pw: RawByteString;
  doc: TRshDocument;
  origin, promptName: string;
  err: TDocError;
  dlg: TSaveDialog;
begin
  Result := False;
  if AItem.OriginPath <> '' then
    promptName := AItem.OriginPath
  else
    promptName := AItem.WorkingPath;
  if not AskOpenPassword(promptName, pw) then Exit;
  try
    if not TRshDocument.RecoverDocument(AItem.WorkingPath, pw, doc, origin,
      err) then
    begin
      ShowDocError(err);
      Exit;
    end;
    try
      dlg := TSaveDialog.Create(Self);
      try
        dlg.Title := 'Save Recovered Copy As';
        dlg.DefaultExt := 'rsh';
        dlg.Filter := 'RottenSSHrimp documents (*.rsh)|*.rsh';
        dlg.Options := dlg.Options + [ofOverwritePrompt, ofPathMustExist];
        if origin <> '' then
          dlg.FileName := 'recovered-' + ExtractFileName(origin);
        if dlg.Execute then
        begin
          if doc.SaveAs(dlg.FileName, err) then
          begin
            DiscardRecovery(AItem);
            LogInfo('recovery saved under a new name');
            Result := True;
          end
          else
            ShowDocError(err);
        end;
      finally
        dlg.Free;
      end;
    finally
      doc.Free;
    end;
  finally
    if pw <> '' then
      FillChar(pw[1], Length(pw), 0);
  end;
end;

procedure TfrmMain.QuitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.AboutClick(Sender: TObject);
begin
  ShowAbout;
end;

end.
