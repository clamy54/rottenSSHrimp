{ Dessine a la main: une TListView native reste blanche en theme sombre sous
  Windows, ignore la police embarquee, et ses en-tetes ne se recolorent pas.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uFilePanel;

{$mode objfpc}{$H+}

interface

uses
  uThemedControls, Classes, SysUtils, Types, Controls, Graphics, Forms, StdCtrls, ExtCtrls,
  Menus, LCLType, LCLIntf, uScpBackend, uScpErrors, uScpPaths, uTheme,
  uScpIcons, uTreeScrollBar, uMenuBar;

type
  TFileSortColumn = (fscName, fscSize, fscModified, fscMode, fscOwner);

  TFilePanelSide = (fpsLocal, fpsRemote);

  TFilePanelAction = (
    fpaNavigate,
    fpaParent,
    fpaBack,
    fpaForward,
    fpaHome,
    fpaRefresh,
    fpaNewFolder,
    fpaRename,
    fpaDelete,
    fpaTransfer,
    fpaDuplicate,     // copie sur place, sous un nom libre
    fpaCopyPath,
    fpaProperties,
    fpaFocusOther);

  TFilePanelActionEvent = procedure(AAction: TFilePanelAction) of object;
  TFilePathEvent = procedure(const APath: string) of object;

  // ASubFolder vide = dossier affiche; sinon le survole, racine de confinement
  TFileDropEvent = procedure(ASourceSide: TFilePanelSide;
    const ASubFolder: string) of object;

  TFileListView = class;

  TFilePanel = class(TPanel)
  private
    FSide: TFilePanelSide;
    FTitle: TLabel;
    FPathEdit: TEdit;
    FVolumeBox: TThemedCombo;
    FToolbar: TPaintBox;
    FList: TFileListView;
    FScroll: TTreeScrollBar;
    FBanner: TPanel;
    FBannerText: TLabel;
    FBannerRetry: TThemedButton;
    FBusy: TLabel;
    FMenu: TPopupMenu;
    FMiTransfer: TMenuItem;
    FMiRename: TMenuItem;
    FMiDuplicate: TMenuItem;
    FMiDelete: TMenuItem;
    // nil en local: pas de droits Unix a montrer
    FMiProps: TMenuItem;
    FOnAction: TFilePanelActionEvent;
    FOnNavigate: TFilePathEvent;
    FOnDrop: TFileDropEvent;
    FVolumePaths: TStringList;
    FHoverButton: Integer;
    FPressedButton: Integer;
    FSuppressVolumeEvent: Boolean;

    procedure ToolbarPaint(Sender: TObject);
    procedure ToolbarMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure ToolbarMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ToolbarMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ToolbarMouseLeave(Sender: TObject);
    procedure PathEditKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure VolumeSelected(Sender: TObject);
    procedure RetryClick(Sender: TObject);
    procedure ListActivate(Sender: TObject);
    procedure MenuPopup(Sender: TObject);
    procedure MenuTransfer(Sender: TObject);
    procedure MenuRename(Sender: TObject);
    procedure MenuDuplicate(Sender: TObject);
    procedure MenuDelete(Sender: TObject);
    procedure MenuProps(Sender: TObject);
    function ButtonAt(X: Integer): Integer;
    function ButtonCount: Integer;
    function ButtonIcon(AIndex: Integer): TScpIcon;
    function ButtonHint(AIndex: Integer): string;
    function ButtonAction(AIndex: Integer): TFilePanelAction;
    function ButtonSize: Integer;
    procedure BuildMenu;
    procedure SetOnDrop(AValue: TFileDropEvent);
  public
    constructor CreateSide(AOwner: TComponent; ASide: TFilePanelSide);
    destructor Destroy; override;

    procedure ApplyTheme;
    // plancher du separateur des volets
    function ToolbarMinWidth: Integer;
    procedure SetPathText(const APath: string);
    function PathText: string;
    procedure SetEntries(const APath: string;
      const AEntries: TScpEntryArray; AHasParent: Boolean);
    procedure ShowError(const AError: TScpError);
    procedure ClearError;
    procedure SetBusy(AActive: Boolean; const AText: string);
    procedure SetVolumes(const ACaptions, APaths: array of string);
    procedure SelectVolumeFor(const APath: string);
    procedure FocusList;

    property List: TFileListView read FList;
    property Side: TFilePanelSide read FSide;
    property OnAction: TFilePanelActionEvent read FOnAction write FOnAction;
    property OnNavigate: TFilePathEvent read FOnNavigate write FOnNavigate;
    property OnDrop: TFileDropEvent read FOnDrop write SetOnDrop;
  end;

  TFileListView = class(TCustomControl, IThemedScrollTarget)
  private
    FSide: TFilePanelSide;
    FEntries: TScpEntryArray;
    FOrder: array of Integer;    // indices dans FEntries, tries
    FSelected: array of Boolean;
    FFocusIndex: Integer;        // index dans FOrder
    FAnchor: Integer;
    FTop: Integer;               // defilement, en pixels
    FRowHeight: Integer;
    FHeaderHeight: Integer;
    FSortCol: TFileSortColumn;
    FSortDesc: Boolean;
    FColWidths: array[TFileSortColumn] of Integer;
    FPanelActive: Boolean;
    FOnViewChanged: TNotifyEvent;
    FOnActivate: TNotifyEvent;
    FOnAction: TFilePanelActionEvent;
    FOnDrop: TFileDropEvent;
    FOnSelectionTaken: TNotifyEvent;
    FHoverHeader: Integer;
    FDragArmed: Boolean;
    FDragOrigin: TPoint;
    // clic nu DANS la selection: elle ne se reduit qu'au relacher, si rien
    // n'a ete glisse. -1 = rien en attente.
    FCollapseOnUp: Integer;
    FDragOver: Boolean;
    FDropIndex: Integer;         // -1 = le dossier affiche
    // « .. » synthetique, vit dans FEntries: a EXCLURE partout. -1 = racine.
    FParentIndex: Integer;

    function VisibleCount: Integer;
    function RowAt(AY: Integer): Integer;
    function IsParentRow(AViewIndex: Integer): Boolean;
    procedure EnsureVisible(AIndex: Integer);
    procedure Reorder;
    procedure DrawRow(AIndex, AY: Integer);
    procedure DrawHeader;
    procedure LayoutColumns;
    procedure SelectSingle(AIndex: Integer);
    procedure SelectRange(AFrom, ATo: Integer);
    procedure SelectionTaken;
    procedure SetFocusIndex(AValue: Integer);
    function EntryIcon(const AEntry: TScpEntry): TScpIcon;
    function EntryColor(const AEntry: TScpEntry): TColor;
  protected
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure DoEndDrag(Target: TObject; X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure Resize; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;

    // publiques comme dans TControl: on ne reduit pas une visibilite heritee
    procedure DragOver(Source: TObject; X, Y: Integer; AState: TDragState;
      var Accept: Boolean); override;
    procedure DragDrop(Source: TObject; X, Y: Integer); override;

    procedure SetEntries(const AEntries: TScpEntryArray; AHasParent: Boolean);
    procedure SelectAll;
    procedure ClearSelection;
    // Non transferables compris: le moteur les refuse AVEC un motif, pas nous en silence.
    function SelectedNames: TStringArray;
    function SelectedEntries: TScpEntryArray;
    function FocusedEntry(out AEntry: TScpEntry): Boolean;
    function FocusedIsParent: Boolean;
    function SelectionCount: Integer;
    procedure CaptureView(out ASelected: TStringArray; out AFocused: string;
      out ATop: Integer);
    procedure RestoreView(const ASelected: TStringArray;
      const AFocused: string; ATop: Integer);
    procedure SetPanelActive(AValue: Boolean);
    procedure SetSideKind(AValue: TFilePanelSide);
    property SideKind: TFilePanelSide read FSide;
    procedure RecomputeMetrics;

    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);

    property OnActivate: TNotifyEvent read FOnActivate write FOnActivate;
    // L'utilisateur vient de selectionner ICI: le panneau d'en face lache la
    // sienne, on ne travaille que d'un cote a la fois.
    property OnSelectionTaken: TNotifyEvent read FOnSelectionTaken
      write FOnSelectionTaken;
    property OnAction: TFilePanelActionEvent read FOnAction write FOnAction;
    property OnDrop: TFileDropEvent read FOnDrop write FOnDrop;
    property EntryCount: Integer read VisibleCount;
    property RowHeight: Integer read FRowHeight;
    property HeaderHeight: Integer read FHeaderHeight;
  end;

implementation

uses
  Math, DateUtils, uTransferQueue;

const
  PANEL_PAD = 6;
  MIN_ROW_HEIGHT = 18;
  DRAG_THRESHOLD = 6;   // px; plus bas, le moindre tremblement devient un glisser

function FormatStamp(AUnixUtc: Int64): string;
var
  dt: TDateTime;
begin
  if AUnixUtc <= 0 then Exit('');
  dt := UniversalTimeToLocal(UnixToDateTime(AUnixUtc));
  Result := FormatDateTime('yyyy-mm-dd hh:nn', dt);
end;

constructor TFileListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FFocusIndex := -1;
  FAnchor := -1;
  FCollapseOnUp := -1;
  FSortCol := fscName;
  FHoverHeader := -1;
  FDropIndex := -1;
  FParentIndex := -1;
  DoubleBuffered := True;
  RecomputeMetrics;
end;

procedure TFileListView.RecomputeMetrics;
begin
  if RSUiFontName <> '' then Canvas.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Canvas.Font.Size := RSUiFontSize;
  FRowHeight := UiTextHeight('Wg') + 6;
  if FRowHeight < MIN_ROW_HEIGHT then FRowHeight := MIN_ROW_HEIGHT;
  FHeaderHeight := FRowHeight + 2;
  LayoutColumns;
end;

procedure TFileListView.SetSideKind(AValue: TFilePanelSide);
begin
  FSide := AValue;
  LayoutColumns;
end;

procedure TFileListView.LayoutColumns;
var
  avail: Integer;
  charW: Integer;

  // Trop etroit: la colonne s'EFFACE plutot que d'etre coupee a droite, sans
  // defilement horizontal pour la ravoir.
  procedure ShedIfCramped(ACol: TFileSortColumn);
  begin
    if (FColWidths[ACol] = 0) or (avail >= charW * 12) then Exit;
    Inc(avail, FColWidths[ACol]);
    FColWidths[ACol] := 0;
  end;

begin
  charW := UiTextWidth('0');
  if charW < 4 then charW := 7;
  FColWidths[fscSize] := charW * 11;
  FColWidths[fscModified] := charW * 17;
  if FSide = fpsRemote then
  begin
    FColWidths[fscMode] := charW * 11;
    FColWidths[fscOwner] := charW * 12;
  end
  else
  begin
    FColWidths[fscMode] := 0;
    FColWidths[fscOwner] := 0;
  end;
  avail := ClientWidth - PANEL_PAD * 2 - FColWidths[fscSize] -
    FColWidths[fscModified] - FColWidths[fscMode] - FColWidths[fscOwner];
  // de la moins utile a la plus utile
  ShedIfCramped(fscOwner);
  ShedIfCramped(fscMode);
  ShedIfCramped(fscModified);
  ShedIfCramped(fscSize);
  // plancher meme si ca deborde: sans nom, le reste ne sert a rien
  FColWidths[fscName] := Max(avail, charW * 12);
end;

procedure TFileListView.Resize;
begin
  inherited Resize;
  LayoutColumns;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

function TFileListView.VisibleCount: Integer;
begin
  Result := Length(FOrder);
end;

// dossiers d'abord, quel que soit le tri
procedure TFileListView.Reorder;
var
  i, j, tmp: Integer;

  function Less(A, B: Integer): Boolean;
  var
    ea, eb: TScpEntry;
    r: Integer;
  begin
    if A = FParentIndex then Exit(True);
    if B = FParentIndex then Exit(False);
    ea := FEntries[A];
    eb := FEntries[B];
    if ea.IsDir <> eb.IsDir then Exit(ea.IsDir);
    r := 0;
    case FSortCol of
      fscName: r := CompareText(ea.Name, eb.Name);
      fscSize:
        if ea.Size < eb.Size then r := -1
        else if ea.Size > eb.Size then r := 1;
      fscModified:
        if ea.MTimeUtc < eb.MTimeUtc then r := -1
        else if ea.MTimeUtc > eb.MTimeUtc then r := 1;
      fscMode:
        if ea.Mode < eb.Mode then r := -1
        else if ea.Mode > eb.Mode then r := 1;
      fscOwner: r := CompareText(ea.Owner, eb.Owner);
    end;
    if r = 0 then r := CompareStr(ea.Name, eb.Name);
    if FSortDesc then r := -r;
    Result := r < 0;
  end;

begin
  SetLength(FOrder, Length(FEntries));
  for i := 0 to High(FEntries) do FOrder[i] := i;
  for i := 1 to High(FOrder) do
  begin
    tmp := FOrder[i];
    j := i - 1;
    while (j >= 0) and Less(tmp, FOrder[j]) do
    begin
      FOrder[j + 1] := FOrder[j];
      Dec(j);
    end;
    FOrder[j + 1] := tmp;
  end;
end;

function TFileListView.IsParentRow(AViewIndex: Integer): Boolean;
begin
  Result := (FParentIndex >= 0) and (AViewIndex >= 0) and
    (AViewIndex < Length(FOrder)) and (FOrder[AViewIndex] = FParentIndex);
end;

procedure TFileListView.SetEntries(const AEntries: TScpEntryArray;
  AHasParent: Boolean);
begin
  FEntries := Copy(AEntries, 0, Length(AEntries));
  FParentIndex := -1;
  if AHasParent then
  begin
    SetLength(FEntries, Length(FEntries) + 1);
    FParentIndex := High(FEntries);
    FEntries[FParentIndex] := Default(TScpEntry);
    FEntries[FParentIndex].Name := '..';
    FEntries[FParentIndex].IsDir := True;
  end;
  SetLength(FSelected, Length(FEntries));
  // FSelected[0] sur tableau vide = dereference de nil
  if Length(FSelected) > 0 then
    FillChar(FSelected[0], Length(FSelected) * SizeOf(Boolean), 0);
  Reorder;
  if FFocusIndex >= Length(FOrder) then FFocusIndex := Length(FOrder) - 1;
  if (FFocusIndex < 0) and (Length(FOrder) > 0) then FFocusIndex := 0;
  if FTop > ScrollMaxTop then FTop := ScrollMaxTop;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

procedure TFileListView.CaptureView(out ASelected: TStringArray;
  out AFocused: string; out ATop: Integer);
var
  i, n: Integer;
begin
  ASelected := nil;
  AFocused := '';
  ATop := FTop;
  n := 0;
  for i := 0 to High(FOrder) do
    if FSelected[FOrder[i]] then
    begin
      SetLength(ASelected, n + 1);
      ASelected[n] := FEntries[FOrder[i]].Name;
      Inc(n);
    end;
  if (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) then
    AFocused := FEntries[FOrder[FFocusIndex]].Name;
end;

procedure TFileListView.RestoreView(const ASelected: TStringArray;
  const AFocused: string; ATop: Integer);
var
  i, j: Integer;
begin
  // par NOM: apres un renommage, les index mentent
  for i := 0 to High(FOrder) do
    for j := 0 to High(ASelected) do
      if FEntries[FOrder[i]].Name = ASelected[j] then
      begin
        FSelected[FOrder[i]] := True;
        Break;
      end;
  if AFocused <> '' then
    for i := 0 to High(FOrder) do
      if FEntries[FOrder[i]].Name = AFocused then
      begin
        FFocusIndex := i;
        Break;
      end;
  FTop := Min(ATop, ScrollMaxTop);
  if FTop < 0 then FTop := 0;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

procedure TFileListView.SelectAll;
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := (i <> FParentIndex);
  Invalidate;
end;

procedure TFileListView.ClearSelection;
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  Invalidate;
end;

function TFileListView.SelectionCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSelected) do
    if FSelected[i] then Inc(Result);
end;

function TFileListView.SelectedNames: TStringArray;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  for i := 0 to High(FOrder) do
    if FSelected[FOrder[i]] and (not IsParentRow(i)) then
    begin
      SetLength(Result, n + 1);
      Result[n] := FEntries[FOrder[i]].Name;
      Inc(n);
    end;
  // rien de coche: l'element sous le curseur, sauf « .. »
  if (n = 0) and (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) and
     (not IsParentRow(FFocusIndex)) then
  begin
    SetLength(Result, 1);
    Result[0] := FEntries[FOrder[FFocusIndex]].Name;
  end;
end;

function TFileListView.SelectedEntries: TScpEntryArray;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  for i := 0 to High(FOrder) do
    if FSelected[FOrder[i]] and (not IsParentRow(i)) then
    begin
      SetLength(Result, n + 1);
      Result[n] := FEntries[FOrder[i]];
      Inc(n);
    end;
  if (n = 0) and (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) and
     (not IsParentRow(FFocusIndex)) then
  begin
    SetLength(Result, 1);
    Result[0] := FEntries[FOrder[FFocusIndex]];
  end;
end;

function TFileListView.FocusedIsParent: Boolean;
begin
  Result := IsParentRow(FFocusIndex);
end;

function TFileListView.FocusedEntry(out AEntry: TScpEntry): Boolean;
begin
  Result := (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder));
  if Result then
    AEntry := FEntries[FOrder[FFocusIndex]]
  else
    AEntry := Default(TScpEntry);
end;

procedure TFileListView.SelectSingle(AIndex: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  if (AIndex >= 0) and (AIndex < Length(FOrder)) and
     (not IsParentRow(AIndex)) then
    FSelected[FOrder[AIndex]] := True;
  FAnchor := AIndex;
end;

procedure TFileListView.SelectRange(AFrom, ATo: Integer);
var
  i, a, b: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  a := Min(AFrom, ATo);
  b := Max(AFrom, ATo);
  for i := Max(a, 0) to Min(b, High(FOrder)) do
    if not IsParentRow(i) then
      FSelected[FOrder[i]] := True;
end;

// Gestes de l'utilisateur seulement: RestoreView ne passe pas par ici.
procedure TFileListView.SelectionTaken;
begin
  if (SelectionCount > 0) and Assigned(FOnSelectionTaken) then
    FOnSelectionTaken(Self);
end;

procedure TFileListView.SetFocusIndex(AValue: Integer);
begin
  if Length(FOrder) = 0 then
  begin
    FFocusIndex := -1;
    Exit;
  end;
  FFocusIndex := Max(0, Min(AValue, High(FOrder)));
  EnsureVisible(FFocusIndex);
end;

procedure TFileListView.EnsureVisible(AIndex: Integer);
var
  rowTop, viewH: Integer;
begin
  if (AIndex < 0) or (FRowHeight <= 0) then Exit;
  rowTop := AIndex * FRowHeight;
  viewH := ScrollViewportHeight;
  if rowTop < FTop then
    FTop := rowTop
  else if rowTop + FRowHeight > FTop + viewH then
    FTop := rowTop + FRowHeight - viewH;
  FTop := Max(0, Min(FTop, ScrollMaxTop));
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

function TFileListView.RowAt(AY: Integer): Integer;
begin
  if AY < FHeaderHeight then Exit(-1);
  Result := (AY - FHeaderHeight + FTop) div FRowHeight;
  if (Result < 0) or (Result >= Length(FOrder)) then Result := -1;
end;

function TFileListView.EntryIcon(const AEntry: TScpEntry): TScpIcon;
begin
  if AEntry.IsLink then
  begin
    if AEntry.BrokenLink then Exit(siLinkBroken);
    Exit(siLink);
  end;
  if AEntry.IsSpecial then Exit(siSpecial);
  if AEntry.IsDir then Exit(siFolder);
  Result := siFile;
end;

function TFileListView.EntryColor(const AEntry: TScpEntry): TColor;
begin
  if AEntry.IsSpecial then Exit(clScpWarn);
  if AEntry.BrokenLink then Exit(clScpErr);
  if AEntry.IsLink then Exit(clAccent);
  if AEntry.AttrsUnknown then Exit(clTextSecondary);
  if AEntry.IsDir then Exit(clSideTextHi);
  Result := clAppFg;
end;

procedure TFileListView.DrawHeader;
var
  x, w: Integer;
  headText: string;
  r: TRect;
  idx: Integer;

  procedure Head(ACol: TFileSortColumn; const ACaption: string);
  var
    bg: TColor;
    arrowBox, arrowX: Integer;
  begin
    if FColWidths[ACol] <= 0 then Exit;
    w := FColWidths[ACol];
    r := Rect(x, 0, x + w, FHeaderHeight);
    bg := clPanelHeader;
    if idx = FHoverHeader then
    begin
      bg := BlendColor(clPanelHeader, clAppFg, 88);
      Canvas.Brush.Color := bg;
      Canvas.FillRect(r);
    end;
    headText := ACaption;
    Canvas.Font.Color := clPanelHeaderText;
    Canvas.TextRect(Rect(x + PANEL_PAD, 0, x + w - 2, FHeaderHeight),
      x + PANEL_PAD, (FHeaderHeight - Canvas.TextHeight('Wg')) div 2,
      headText);
    // omise plutot que rognee: une demi-fleche ne dit plus ou elle pointe
    if FSortCol = ACol then
    begin
      arrowBox := FHeaderHeight - 6;
      arrowX := x + PANEL_PAD + Canvas.TextWidth(headText) + 2;
      if arrowX + arrowBox <= x + w - 2 then
        if FSortDesc then
          DrawScpIcon(Canvas, Rect(arrowX, 3, arrowX + arrowBox,
            3 + arrowBox), siSortDesc, clPanelHeaderText, bg)
        else
          DrawScpIcon(Canvas, Rect(arrowX, 3, arrowX + arrowBox,
            3 + arrowBox), siSortAsc, clPanelHeaderText, bg);
    end;
    Canvas.Pen.Color := clPanelGrid;
    Canvas.Line(x + w - 1, 2, x + w - 1, FHeaderHeight - 2);
    Inc(x, w);
    Inc(idx);
  end;

begin
  Canvas.Brush.Color := clPanelHeader;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(Rect(0, 0, ClientWidth, FHeaderHeight));
  Canvas.Brush.Style := bsClear;
  x := 0;
  idx := 0;
  Head(fscName, 'Name');
  Head(fscSize, 'Size');
  if FSide = fpsRemote then
  begin
    Head(fscMode, 'Mode');
    Head(fscOwner, 'Owner');
  end;
  Head(fscModified, 'Modified');
  Canvas.Pen.Color := clPanelGrid;
  Canvas.Line(0, FHeaderHeight - 1, ClientWidth, FHeaderHeight - 1);
end;

procedure TFileListView.DrawRow(AIndex, AY: Integer);
var
  e: TScpEntry;
  sel: Boolean;
  x, w, iconBox, textTop: Integer;
  fg, rowBg: TColor;
  s: string;
  r: TRect;
  drop, parentRow: Boolean;

  procedure Cell(ACol: TFileSortColumn; const AText: string;
    ARightAlign: Boolean; AColor: TColor);
  var
    tw: Integer;
  begin
    w := FColWidths[ACol];
    if w <= 0 then Exit;
    Canvas.Font.Color := AColor;
    r := Rect(x + PANEL_PAD, AY, x + w - PANEL_PAD, AY + FRowHeight);
    if ARightAlign then
    begin
      tw := Canvas.TextWidth(AText);
      Canvas.TextRect(r, r.Right - tw, textTop, AText);
    end
    else
      Canvas.TextRect(r, r.Left, textTop, AText);
    Inc(x, w);
  end;

begin
  e := FEntries[FOrder[AIndex]];
  parentRow := IsParentRow(AIndex);
  sel := FSelected[FOrder[AIndex]] and (not parentRow);
  drop := FDragOver and (AIndex = FDropIndex);
  r := Rect(0, AY, ClientWidth, AY + FRowHeight);

  if drop then
    // distinct de la selection: l'un dit OU, l'autre QUOI
    rowBg := BlendColor(clAccent, clPanelBg, 40)
  else if sel then
  begin
    if FPanelActive then
      rowBg := clSelActive
    else
      rowBg := clSelInactive;
  end
  else if Odd(AIndex) then
    rowBg := clPanelAltRow
  else
    rowBg := clPanelBg;
  Canvas.Brush.Color := rowBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(r);
  Canvas.Brush.Style := bsClear;

  if drop then
  begin
    Canvas.Pen.Color := clAccent;
    Canvas.Pen.Style := psSolid;
    Canvas.Rectangle(0, AY, ClientWidth, AY + FRowHeight);
  end;

  if sel or drop then fg := clSelText
  else if parentRow then fg := clTextSecondary
  else fg := EntryColor(e);

  textTop := AY + (FRowHeight - Canvas.TextHeight('Wg')) div 2;
  iconBox := FRowHeight - 4;
  if parentRow then
    DrawScpIcon(Canvas, Rect(PANEL_PAD, AY + 2, PANEL_PAD + iconBox,
      AY + 2 + iconBox), siParent, fg, rowBg)
  else
    DrawScpIcon(Canvas, Rect(PANEL_PAD, AY + 2, PANEL_PAD + iconBox,
      AY + 2 + iconBox), EntryIcon(e), fg, rowBg);

  x := 0;
  w := FColWidths[fscName];
  Canvas.Font.Color := fg;
  s := DisplaySafeName(e.Name);
  if e.IsLink and (e.LinkTarget <> '') then
    s := s + '  ->  ' + e.LinkTarget;
  Canvas.TextRect(Rect(PANEL_PAD * 2 + iconBox, AY, x + w - PANEL_PAD,
    AY + FRowHeight), PANEL_PAD * 2 + iconBox, textTop, s);
  Inc(x, w);

  // « .. »: ni taille, ni date, ni mode; ceux du parent comme du courant mentiraient
  if not parentRow then
  begin
    if e.IsDir then
      s := ''
    else if e.Size < 0 then
      s := '--'
    else
      s := FormatBytes(e.Size);
    if sel then Cell(fscSize, s, True, fg)
    else Cell(fscSize, s, True, clTextSecondary);

    if FSide = fpsRemote then
    begin
      if sel then
        Cell(fscMode, FormatUnixMode(e.Mode), False, fg)
      else
        Cell(fscMode, FormatUnixMode(e.Mode), False, clTextSecondary);
      if sel then
        Cell(fscOwner, e.Owner, False, fg)
      else
        Cell(fscOwner, e.Owner, False, clTextSecondary);
    end;

    if sel then
      Cell(fscModified, FormatStamp(e.MTimeUtc), False, fg)
    else
      Cell(fscModified, FormatStamp(e.MTimeUtc), False, clTextSecondary);
  end;

  if (AIndex = FFocusIndex) and FPanelActive and Focused then
  begin
    Canvas.Pen.Color := clAccent;
    Canvas.Pen.Style := psDot;
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(0, AY, ClientWidth - 1, AY + FRowHeight - 1);
    Canvas.Pen.Style := psSolid;
  end;
end;

procedure TFileListView.Paint;
var
  i, y, firstRow, lastRow: Integer;
begin
  Canvas.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Canvas.Font.Size := RSUiFontSize;
  Canvas.Brush.Color := clPanelBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  Canvas.Brush.Style := bsClear;

  if Length(FOrder) > 0 then
  begin
    firstRow := FTop div FRowHeight;
    lastRow := (FTop + ScrollViewportHeight) div FRowHeight;
    if lastRow > High(FOrder) then lastRow := High(FOrder);
    for i := firstRow to lastRow do
    begin
      y := FHeaderHeight + i * FRowHeight - FTop;
      if y + FRowHeight < FHeaderHeight then Continue;
      if y > ClientHeight then Break;
      DrawRow(i, y);
    end;
  end
  else
  begin
    Canvas.Font.Color := clTextSecondary;
    Canvas.TextOut(PANEL_PAD * 2, FHeaderHeight + PANEL_PAD,
      'This folder is empty.');
  end;

  DrawHeader;

  if FDragOver then
  begin
    Canvas.Pen.Color := clAccent;
    Canvas.Pen.Width := 2;
    Canvas.Pen.Style := psSolid;
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(1, 1, ClientWidth - 1, ClientHeight - 1);
    Canvas.Pen.Width := 1;
  end;
end;

procedure TFileListView.KeyDown(var Key: Word; Shift: TShiftState);
var
  newIndex, page: Integer;
  handled: Boolean;
begin
  handled := True;
  newIndex := FFocusIndex;
  page := Max(1, ScrollViewportHeight div Max(FRowHeight, 1));
  case Key of
    VK_UP: newIndex := FFocusIndex - 1;
    VK_DOWN: newIndex := FFocusIndex + 1;
    VK_PRIOR: newIndex := FFocusIndex - page;
    VK_NEXT: newIndex := FFocusIndex + page;
    VK_HOME: newIndex := 0;
    VK_END: newIndex := High(FOrder);
    VK_SPACE:
      begin
        if (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) and
           (not IsParentRow(FFocusIndex)) then
          FSelected[FOrder[FFocusIndex]] :=
            not FSelected[FOrder[FFocusIndex]];
        SelectionTaken;
        Invalidate;
        Key := 0;
        Exit;
      end;
    VK_RETURN:
      begin
        if Assigned(FOnActivate) then FOnActivate(Self);
        Key := 0;
        Exit;
      end;
    VK_BACK:
      begin
        if Assigned(FOnAction) then FOnAction(fpaParent);
        Key := 0;
        Exit;
      end;
    VK_F2:
      begin
        if Assigned(FOnAction) then FOnAction(fpaRename);
        Key := 0;
        Exit;
      end;
    VK_F5:
      begin
        if Assigned(FOnAction) then FOnAction(fpaTransfer);
        Key := 0;
        Exit;
      end;
    VK_DELETE:
      begin
        if Assigned(FOnAction) then FOnAction(fpaDelete);
        Key := 0;
        Exit;
      end;
    VK_F9:
      begin
        if Assigned(FOnAction) then FOnAction(fpaProperties);
        Key := 0;
        Exit;
      end;
    VK_TAB:
      begin
        if Assigned(FOnAction) then FOnAction(fpaFocusOther);
        Key := 0;
        Exit;
      end;
    VK_A:
      begin
        if (ssCtrl in Shift) or (ssMeta in Shift) then
        begin
          SelectAll;
          SelectionTaken;
          Key := 0;
          Exit;
        end;
        handled := False;
      end;
  else
    handled := False;
  end;

  if not handled then
  begin
    inherited KeyDown(Key, Shift);
    Exit;
  end;

  if Length(FOrder) = 0 then
  begin
    Key := 0;
    Exit;
  end;
  newIndex := Max(0, Min(newIndex, High(FOrder)));
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := FFocusIndex;
    SelectRange(FAnchor, newIndex);
  end
  else if not ((ssCtrl in Shift) or (ssMeta in Shift)) then
    SelectSingle(newIndex);
  SetFocusIndex(newIndex);
  SelectionTaken;
  Invalidate;
  Key := 0;
end;

procedure TFileListView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  idx, x0, i: Integer;
  col: TFileSortColumn;

  function NextCol(var ACol: TFileSortColumn): Boolean;
  begin
    Result := False;
    case i of
      0: begin ACol := fscName; Result := True; end;
      1: begin ACol := fscSize; Result := True; end;
      2: if FSide = fpsRemote then begin ACol := fscMode; Result := True; end;
      3: if FSide = fpsRemote then begin ACol := fscOwner; Result := True; end;
      4: begin ACol := fscModified; Result := True; end;
    end;
  end;

begin
  if CanFocus then SetFocus;
  FDragArmed := False;
  FCollapseOnUp := -1;
  if Y < FHeaderHeight then
  begin
    x0 := 0;
    for i := 0 to 4 do
    begin
      col := fscName;
      if not NextCol(col) then Continue;
      if FColWidths[col] <= 0 then Continue;
      if (X >= x0) and (X < x0 + FColWidths[col]) then
      begin
        if FSortCol = col then
          FSortDesc := not FSortDesc
        else
        begin
          FSortCol := col;
          FSortDesc := False;
        end;
        Reorder;
        Invalidate;
        Exit;
      end;
      Inc(x0, FColWidths[col]);
    end;
    Exit;
  end;

  idx := RowAt(Y);
  if idx < 0 then Exit;
  // clic droit DANS la selection: on la garde, sinon dix fichiers deviennent un
  if (Button = mbRight) and (not IsParentRow(idx)) and
     FSelected[FOrder[idx]] then
  begin
    SetFocusIndex(idx);
    SelectionTaken;
    Invalidate;
    Exit;
  end;
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := FFocusIndex;
    SelectRange(FAnchor, idx);
  end
  else if (ssCtrl in Shift) or (ssMeta in Shift) then
  begin
    if not IsParentRow(idx) then
      FSelected[FOrder[idx]] := not FSelected[FOrder[idx]];
    FAnchor := idx;
  end
  // deja selectionnee: peut-etre le depart d'un glisser, on tranche au relacher
  else if (Button = mbLeft) and (not IsParentRow(idx)) and
          FSelected[FOrder[idx]] then
    FCollapseOnUp := idx
  else
    SelectSingle(idx);
  SetFocusIndex(idx);
  SelectionTaken;
  FDragArmed := (Button = mbLeft) and (SelectionCount > 0);
  FDragOrigin := Point(X, Y);
  Invalidate;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TFileListView.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  FDragArmed := False;
  if (Button = mbLeft) and (FCollapseOnUp >= 0) then
  begin
    if FCollapseOnUp = RowAt(Y) then
    begin
      SelectSingle(FCollapseOnUp);
      Invalidate;
      if Assigned(FOnViewChanged) then FOnViewChanged(Self);
    end;
    FCollapseOnUp := -1;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TFileListView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  newHover, x0, i: Integer;
  col: TFileSortColumn;
begin
  newHover := -1;
  if Y < FHeaderHeight then
  begin
    x0 := 0;
    for i := 0 to 4 do
    begin
      col := fscModified;
      case i of
        0: col := fscName;
        1: col := fscSize;
        2: col := fscMode;
        3: col := fscOwner;
      end;
      if FColWidths[col] <= 0 then Continue;
      if (X >= x0) and (X < x0 + FColWidths[col]) then
      begin
        newHover := i;
        Break;
      end;
      Inc(x0, FColWidths[col]);
    end;
  end;
  if newHover <> FHoverHeader then
  begin
    FHoverHeader := newHover;
    Invalidate;
  end;
  if FDragArmed and (ssLeft in Shift) and
     ((Abs(X - FDragOrigin.X) >= DRAG_THRESHOLD) or
      (Abs(Y - FDragOrigin.Y) >= DRAG_THRESHOLD)) then
  begin
    FDragArmed := False;
    FCollapseOnUp := -1;
    if SelectionCount > 0 then
      BeginDrag(True, -1);
  end;
  inherited MouseMove(Shift, X, Y);
end;

// AUTRE panneau seulement: cet onglet ne fait pas de copie sur place
procedure TFileListView.DragOver(Source: TObject; X, Y: Integer;
  AState: TDragState; var Accept: Boolean);
var
  src: TFileListView;
  idx, newDrop: Integer;
begin
  Accept := False;
  if not (Source is TFileListView) then Exit;
  src := TFileListView(Source);
  if (src = Self) or (src.SideKind = FSide) then Exit;
  if src.SelectionCount = 0 then Exit;
  Accept := True;

  if AState = dsDragLeave then
  begin
    if FDragOver then
    begin
      FDragOver := False;
      FDropIndex := -1;
      Invalidate;
    end;
    Exit;
  end;

  // Un lien n'est pas une destination: ecrire au travers sortirait du panneau.
  newDrop := -1;
  idx := RowAt(Y);
  if (idx >= 0) and (idx < Length(FOrder)) and (not IsParentRow(idx)) then
    if FEntries[FOrder[idx]].IsDir and (not FEntries[FOrder[idx]].IsLink) then
      newDrop := idx;
  if (not FDragOver) or (newDrop <> FDropIndex) then
  begin
    FDragOver := True;
    FDropIndex := newDrop;
    Invalidate;
  end;
end;

procedure TFileListView.DragDrop(Source: TObject; X, Y: Integer);
var
  src: TFileListView;
  sub: string;
begin
  sub := '';
  if (FDropIndex >= 0) and (FDropIndex < Length(FOrder)) then
    sub := FEntries[FOrder[FDropIndex]].Name;
  FDragOver := False;
  FDropIndex := -1;
  Invalidate;
  if not (Source is TFileListView) then Exit;
  src := TFileListView(Source);
  if (src.SideKind <> FSide) and Assigned(FOnDrop) then
    FOnDrop(src.SideKind, sub);
end;

// sur la SOURCE, quelle que soit la fin: lacher, Echap ou perte du focus
procedure TFileListView.DoEndDrag(Target: TObject; X, Y: Integer);
begin
  FDragArmed := False;
  if FDragOver then
  begin
    FDragOver := False;
    FDropIndex := -1;
    Invalidate;
  end;
  inherited DoEndDrag(Target, X, Y);
end;

procedure TFileListView.MouseLeave;
begin
  FDragArmed := False;
  if FHoverHeader <> -1 then
  begin
    FHoverHeader := -1;
    Invalidate;
  end;
  inherited MouseLeave;
end;

procedure TFileListView.DblClick;
begin
  if Assigned(FOnActivate) then FOnActivate(Self);
  inherited DblClick;
end;

function TFileListView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  ScrollWheelBy(WheelDelta);
  Result := True;
end;

procedure TFileListView.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TFileListView.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TFileListView.SetPanelActive(AValue: Boolean);
begin
  if FPanelActive = AValue then Exit;
  FPanelActive := AValue;
  Invalidate;
end;

function TFileListView.ScrollViewportHeight: Integer;
begin
  Result := ClientHeight - FHeaderHeight;
  if Result < 0 then Result := 0;
end;

function TFileListView.ScrollMaxTop: Integer;
begin
  Result := Length(FOrder) * FRowHeight - ScrollViewportHeight;
  if Result < 0 then Result := 0;
end;

function TFileListView.ScrollGetTop: Integer;
begin
  Result := FTop;
end;

procedure TFileListView.ScrollSetTop(AValue: Integer);
begin
  AValue := Max(0, Min(AValue, ScrollMaxTop));
  if AValue = FTop then Exit;
  FTop := AValue;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

procedure TFileListView.ScrollAnimateBy(ADelta: Integer);
begin
  ScrollSetTop(FTop + ADelta);
end;

procedure TFileListView.ScrollWheelBy(AWheelDelta: Integer);
begin
  ScrollSetTop(FTop - (AWheelDelta div 120) * FRowHeight * 3);
end;

procedure TFileListView.SetOnScrollViewChanged(AHandler: TNotifyEvent);
begin
  FOnViewChanged := AHandler;
end;

constructor TFilePanel.CreateSide(AOwner: TComponent; ASide: TFilePanelSide);
var
  topRow: TPanel;
begin
  inherited Create(AOwner);
  FSide := ASide;
  FHoverButton := -1;
  FPressedButton := -1;
  FVolumePaths := TStringList.Create;
  BevelOuter := bvNone;
  ParentBackground := False;
  ParentColor := False;
  Color := clPanelBg;

  FTitle := TLabel.Create(Self);
  FTitle.Parent := Self;
  FTitle.Align := alTop;
  FTitle.BorderSpacing.Around := PANEL_PAD;
  FTitle.Font.Style := [fsBold];
  if ASide = fpsLocal then
    FTitle.Caption := 'LOCAL'
  else
    FTitle.Caption := 'REMOTE';

  topRow := TPanel.Create(Self);
  topRow.Parent := Self;
  topRow.Align := alTop;
  topRow.BevelOuter := bvNone;
  topRow.ParentBackground := False;
  topRow.ParentColor := False;
  topRow.Height := 30;

  if ASide = fpsLocal then
  begin
    FVolumeBox := TThemedCombo.Create(Self);
    FVolumeBox.Parent := topRow;
    FVolumeBox.Align := alLeft;
    FVolumeBox.Width := 170;
    FVolumeBox.Style := csDropDownList;
    FVolumeBox.BorderSpacing.Around := 3;
    FVolumeBox.OnChange := @VolumeSelected;
  end;

  FPathEdit := TEdit.Create(Self);
  FPathEdit.Parent := topRow;
  FPathEdit.Align := alClient;
  FPathEdit.BorderSpacing.Around := 3;
  FPathEdit.OnKeyDown := @PathEditKey;

  FToolbar := TPaintBox.Create(Self);
  FToolbar.Parent := Self;
  FToolbar.Align := alTop;
  FToolbar.Height := 30;
  FToolbar.OnPaint := @ToolbarPaint;
  FToolbar.OnMouseMove := @ToolbarMouseMove;
  FToolbar.OnMouseDown := @ToolbarMouseDown;
  FToolbar.OnMouseUp := @ToolbarMouseUp;
  FToolbar.OnMouseLeave := @ToolbarMouseLeave;

  FBanner := TPanel.Create(Self);
  FBanner.Parent := Self;
  FBanner.Align := alTop;
  FBanner.Height := 34;
  FBanner.BevelOuter := bvNone;
  FBanner.ParentBackground := False;
  FBanner.ParentColor := False;
  FBanner.Visible := False;

  FBannerRetry := TThemedButton.Create(Self);
  FBannerRetry.Parent := FBanner;
  FBannerRetry.Align := alRight;
  FBannerRetry.Width := 70;
  FBannerRetry.Caption := 'Retry';
  FBannerRetry.BorderSpacing.Around := 4;
  FBannerRetry.OnClick := @RetryClick;

  FBannerText := TLabel.Create(Self);
  FBannerText.Parent := FBanner;
  FBannerText.Align := alClient;
  FBannerText.Layout := tlCenter;
  FBannerText.BorderSpacing.Left := PANEL_PAD;

  FBusy := TLabel.Create(Self);
  FBusy.Parent := Self;
  FBusy.Align := alBottom;
  FBusy.BorderSpacing.Around := 4;
  FBusy.Visible := False;

  FScroll := TTreeScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alRight;
  FScroll.Width := 12;

  FList := TFileListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.SetSideKind(ASide);
  FList.OnActivate := @ListActivate;
  FList.OnDrop := FOnDrop;
  FScroll.Bind(FList);

  BuildMenu;

  ApplyTheme;
end;

// Rien que le clavier ne fasse deja: pas de second jeu de regles.
procedure TFilePanel.BuildMenu;

  function AddItem(const ACaption: string; AHandler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AHandler;
    FMenu.Items.Add(Result);
  end;

  procedure AddSeparator;
  var
    sep: TMenuItem;
  begin
    sep := TMenuItem.Create(Self);
    sep.Caption := '-';
    FMenu.Items.Add(sep);
  end;

begin
  FMenu := TPopupMenu.Create(Self);
  FMenu.OnPopup := @MenuPopup;
  if FSide = fpsLocal then
    FMiTransfer := AddItem('Upload', @MenuTransfer)
  else
    FMiTransfer := AddItem('Download', @MenuTransfer);
  AddSeparator;
  FMiRename := AddItem('Rename...', @MenuRename);
  FMiDuplicate := AddItem('Duplicate', @MenuDuplicate);
  AddSeparator;
  FMiDelete := AddItem('Delete', @MenuDelete);
  if FSide = fpsRemote then
  begin
    AddSeparator;
    FMiProps := AddItem('Properties...', @MenuProps);
  end;
  FList.PopupMenu := FMenu;
  {$IFNDEF DARWIN}
  ThemePopupMenu(FMenu);
  {$ENDIF}
end;

// GRISE, pas absent: un menu qui change de forme ne s'apprend pas
procedure TFilePanel.MenuPopup(Sender: TObject);
var
  n: Integer;
begin
  n := FList.SelectionCount;
  if (n = 0) and (not FList.FocusedIsParent) then
    n := Ord(FList.EntryCount > 0);
  FMiTransfer.Enabled := n > 0;
  FMiDuplicate.Enabled := n > 0;
  FMiDelete.Enabled := n > 0;
  FMiRename.Enabled := (FList.EntryCount > 0) and (not FList.FocusedIsParent);
  if FMiProps <> nil then FMiProps.Enabled := n > 0;
end;

procedure TFilePanel.MenuTransfer(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaTransfer);
end;

procedure TFilePanel.MenuRename(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaRename);
end;

procedure TFilePanel.MenuDuplicate(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaDuplicate);
end;

procedure TFilePanel.MenuDelete(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaDelete);
end;

procedure TFilePanel.MenuProps(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaProperties);
end;

procedure TFilePanel.SetOnDrop(AValue: TFileDropEvent);
begin
  FOnDrop := AValue;
  if FList <> nil then
    FList.OnDrop := AValue;
end;

destructor TFilePanel.Destroy;
begin
  FVolumePaths.Free;
  inherited Destroy;
end;

procedure TFilePanel.ApplyTheme;
begin
  Color := clPanelBg;
  FTitle.Font.Color := clPanelHeaderText;
  FBanner.Color := BlendColor(clScpErr, clPanelBg, 22);
  FBannerText.Font.Color := clAppFg;
  FBusy.Font.Color := clTextSecondary;
  if FPathEdit <> nil then
  begin
    FPathEdit.Color := BlendColor(clPanelBg, clAppFg, 92);
    FPathEdit.Font.Color := clAppFg;
  end;
  if FVolumeBox <> nil then
  begin
    FVolumeBox.Color := BlendColor(clPanelBg, clAppFg, 92);
    FVolumeBox.Font.Color := clAppFg;
  end;
  if FList <> nil then
  begin
    FList.RecomputeMetrics;
    FList.Invalidate;
  end;
  {$IFNDEF DARWIN}
  if FMenu <> nil then ThemeMenuItems(FMenu.Items);
  {$ENDIF}
  if FScroll <> nil then
    FScroll.ApplyTheme(clPanelBg,
      BlendColor(clAppFg, clPanelBg, 22),
      BlendColor(clAppFg, clPanelBg, 42));
  ApplyUiFont(Self);
  Invalidate;
end;

function TFilePanel.ButtonCount: Integer;
begin
  Result := 8;
end;

function TFilePanel.ToolbarMinWidth: Integer;
begin
  // meme arithmetique que ToolbarPaint
  Result := 2 * PANEL_PAD + ButtonCount * (ButtonSize + 6) - 6;
end;

function TFilePanel.ButtonIcon(AIndex: Integer): TScpIcon;
begin
  case AIndex of
    0: Result := siBack;
    1: Result := siForward;
    2: Result := siParent;
    3: Result := siHome;
    4: Result := siRefresh;
    5: Result := siNewFolder;
    6: Result := siCopy;
    7: if FSide = fpsLocal then Result := siUpload else Result := siDownload;
  else
    Result := siNone;
  end;
end;

function TFilePanel.ButtonHint(AIndex: Integer): string;
begin
  case AIndex of
    0: Result := 'Back';
    1: Result := 'Forward';
    2: Result := 'Parent folder';
    3: Result := 'Home';
    4: Result := 'Refresh';
    5: Result := 'New folder';
    6: Result := 'Copy full path';
    7: if FSide = fpsLocal then
         Result := 'Upload the selection to the remote panel (F5)'
       else
         Result := 'Download the selection to the local panel (F5)';
  else
    Result := '';
  end;
end;

function TFilePanel.ButtonAction(AIndex: Integer): TFilePanelAction;
begin
  case AIndex of
    0: Result := fpaBack;
    1: Result := fpaForward;
    2: Result := fpaParent;
    3: Result := fpaHome;
    4: Result := fpaRefresh;
    5: Result := fpaNewFolder;
    6: Result := fpaCopyPath;
  else
    Result := fpaTransfer;
  end;
end;

function TFilePanel.ButtonSize: Integer;
begin
  Result := FToolbar.Height - 6;
  if Result < 14 then Result := 14;
end;

function TFilePanel.ButtonAt(X: Integer): Integer;
var
  step: Integer;
begin
  step := ButtonSize + 6;
  Result := (X - PANEL_PAD) div step;
  if (Result < 0) or (Result >= ButtonCount) then Result := -1;
end;

procedure TFilePanel.ToolbarPaint(Sender: TObject);
var
  i, size, step, x: Integer;
  r: TRect;
  ink, bg: TColor;
begin
  FToolbar.Canvas.Brush.Color := clPanelBg;
  FToolbar.Canvas.Brush.Style := bsSolid;
  FToolbar.Canvas.FillRect(FToolbar.ClientRect);
  size := ButtonSize;
  step := size + 6;
  for i := 0 to ButtonCount - 1 do
  begin
    x := PANEL_PAD + i * step;
    r := Rect(x, 3, x + size, 3 + size);
    // par le fond, pas par un decalage: une icone qui bouge d'un pixel fait bug
    if i = FPressedButton then
    begin
      bg := clSelActive;
      FToolbar.Canvas.Brush.Color := bg;
      FToolbar.Canvas.FillRect(r);
    end
    else if i = FHoverButton then
    begin
      bg := clSideHover;
      FToolbar.Canvas.Brush.Color := bg;
      FToolbar.Canvas.FillRect(r);
    end
    else
      bg := clPanelBg;
    if i = FPressedButton then ink := clSelText else ink := clAppFg;
    DrawScpIcon(FToolbar.Canvas, r, ButtonIcon(i), ink, bg);
  end;
end;

procedure TFilePanel.ToolbarMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  b: Integer;
begin
  b := ButtonAt(X);
  if b <> FHoverButton then
  begin
    FHoverButton := b;
    if b >= 0 then
      FToolbar.Hint := ButtonHint(b)
    else
      FToolbar.Hint := '';
    FToolbar.ShowHint := b >= 0;
    FToolbar.Invalidate;
  end;
end;

procedure TFilePanel.ToolbarMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  FPressedButton := ButtonAt(X);
  FToolbar.Invalidate;
end;

procedure TFilePanel.ToolbarMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  b: Integer;
begin
  b := ButtonAt(X);
  // sortir du bouton avant de relacher, c'est renoncer
  if (b >= 0) and (b = FPressedButton) and Assigned(FOnAction) then
    FOnAction(ButtonAction(b));
  FPressedButton := -1;
  FToolbar.Invalidate;
end;

procedure TFilePanel.ToolbarMouseLeave(Sender: TObject);
begin
  FHoverButton := -1;
  FPressedButton := -1;
  FToolbar.Invalidate;
end;

procedure TFilePanel.PathEditKey(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    Key := 0;
    if Assigned(FOnNavigate) then
      FOnNavigate(Trim(FPathEdit.Text));
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    FocusList;
  end;
end;

procedure TFilePanel.VolumeSelected(Sender: TObject);
var
  i: Integer;
begin
  // sinon repositionner le selecteur relance une navigation
  if FSuppressVolumeEvent or (FVolumeBox = nil) then Exit;
  i := FVolumeBox.ItemIndex;
  if (i < 0) or (i >= FVolumePaths.Count) then Exit;
  if Assigned(FOnNavigate) then
    FOnNavigate(FVolumePaths[i]);
end;

procedure TFilePanel.RetryClick(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaRefresh);
end;

procedure TFilePanel.ListActivate(Sender: TObject);
begin
  if Assigned(FOnAction) then FOnAction(fpaNavigate);
end;

procedure TFilePanel.SetPathText(const APath: string);
begin
  if FPathEdit.Focused then Exit;   // ne pas ecraser une saisie en cours
  FPathEdit.Text := APath;
end;

function TFilePanel.PathText: string;
begin
  Result := Trim(FPathEdit.Text);
end;

procedure TFilePanel.SetEntries(const APath: string;
  const AEntries: TScpEntryArray; AHasParent: Boolean);
begin
  SetPathText(APath);
  FList.SetEntries(AEntries, AHasParent);
end;

procedure TFilePanel.ShowError(const AError: TScpError);
begin
  if AError.Kind = sekNone then
  begin
    ClearError;
    Exit;
  end;
  FBannerText.Caption := ScpErrorText(AError);
  FBanner.Color := BlendColor(clScpErr, clPanelBg, 22);
  FBanner.Visible := True;
end;

procedure TFilePanel.ClearError;
begin
  FBanner.Visible := False;
end;

procedure TFilePanel.SetBusy(AActive: Boolean; const AText: string);
begin
  FBusy.Caption := AText;
  FBusy.Visible := AActive and (AText <> '');
end;

procedure TFilePanel.SetVolumes(const ACaptions, APaths: array of string);
var
  i: Integer;
begin
  if FVolumeBox = nil then Exit;
  FSuppressVolumeEvent := True;
  try
    FVolumeBox.Items.BeginUpdate;
    try
      FVolumeBox.Items.Clear;
      FVolumePaths.Clear;
      for i := 0 to High(ACaptions) do
      begin
        FVolumeBox.Items.Add(ACaptions[i]);
        FVolumePaths.Add(APaths[i]);
      end;
    finally
      FVolumeBox.Items.EndUpdate;
    end;
  finally
    FSuppressVolumeEvent := False;
  end;
end;

procedure TFilePanel.SelectVolumeFor(const APath: string);
var
  i, best, bestLen: Integer;
begin
  if FVolumeBox = nil then Exit;
  best := -1;
  bestLen := 0;
  // le plus SPECIFIQUE: le lecteur contient aussi « Home »
  for i := 0 to FVolumePaths.Count - 1 do
    if LocalIsUnder(FVolumePaths[i], APath) and
       (Length(FVolumePaths[i]) > bestLen) then
    begin
      best := i;
      bestLen := Length(FVolumePaths[i]);
    end;
  FSuppressVolumeEvent := True;
  try
    FVolumeBox.ItemIndex := best;
  finally
    FSuppressVolumeEvent := False;
  end;
end;

procedure TFilePanel.FocusList;
begin
  if FList.CanFocus then FList.SetFocus;
end;

end.
