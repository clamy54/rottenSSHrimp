{ Panneau de fichiers de l'onglet Scp: barre d'adresse, barre d'outils, liste
  en vue detaillee, bandeau d'erreur. Le meme controle sert des deux cotes;
  seules les colonnes affichees changent.

  Tout est dessine a la main, comme le reste du projet: une TListView native
  reste blanche en plein theme sombre sous Windows, ignore la police embarquee,
  et ses en-tetes ne se recolorent pas du tout.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uFilePanel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, StdCtrls, ExtCtrls,
  LCLType, LCLIntf, uScpBackend, uScpErrors, uScpPaths, uTheme, uScpIcons,
  uTreeScrollBar;

type
  TFileSortColumn = (fscName, fscSize, fscModified, fscMode, fscOwner);

  TFilePanelSide = (fpsLocal, fpsRemote);

  TFilePanelAction = (
    fpaNavigate,      // entrer dans le dossier sous le curseur
    fpaParent,
    fpaBack,
    fpaForward,
    fpaHome,
    fpaRefresh,
    fpaNewFolder,
    fpaRename,
    fpaDelete,
    fpaTransfer,      // F5 ou bouton: envoyer vers l'autre panneau
    fpaCopyPath,
    fpaReveal,
    fpaFocusOther);

  TFilePanelActionEvent = procedure(AAction: TFilePanelAction) of object;
  TFilePathEvent = procedure(const APath: string) of object;

  TFileListView = class;

  TFilePanel = class(TPanel)
  private
    FSide: TFilePanelSide;
    FTitle: TLabel;
    FPathEdit: TEdit;
    FVolumeBox: TComboBox;
    FToolbar: TPaintBox;
    FList: TFileListView;
    FScroll: TTreeScrollBar;
    FBanner: TPanel;
    FBannerText: TLabel;
    FBannerRetry: TButton;
    FBusy: TLabel;
    FOnAction: TFilePanelActionEvent;
    FOnNavigate: TFilePathEvent;
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
    function ButtonAt(X: Integer): Integer;
    function ButtonCount: Integer;
    function ButtonIcon(AIndex: Integer): TScpIcon;
    function ButtonHint(AIndex: Integer): string;
    function ButtonAction(AIndex: Integer): TFilePanelAction;
    function ButtonSize: Integer;
  public
    constructor CreateSide(AOwner: TComponent; ASide: TFilePanelSide);
    destructor Destroy; override;

    procedure ApplyTheme;
    procedure SetPathText(const APath: string);
    function PathText: string;
    procedure SetEntries(const APath: string;
      const AEntries: TScpEntryArray);
    procedure ShowError(const AError: TScpError);
    procedure ClearError;
    procedure SetBusy(AActive: Boolean; const AText: string);
    function SelectionCount: Integer;
    procedure SetVolumes(const ACaptions, APaths: array of string);
    procedure SelectVolumeFor(const APath: string);
    procedure FocusList;

    property List: TFileListView read FList;
    property Side: TFilePanelSide read FSide;
    property OnAction: TFilePanelActionEvent read FOnAction write FOnAction;
    property OnNavigate: TFilePathEvent read FOnNavigate write FOnNavigate;
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
    FHoverHeader: Integer;

    function VisibleCount: Integer;
    function RowAt(AY: Integer): Integer;
    procedure EnsureVisible(AIndex: Integer);
    procedure Reorder;
    procedure DrawRow(AIndex, AY: Integer);
    procedure DrawHeader;
    procedure LayoutColumns;
    procedure SelectSingle(AIndex: Integer);
    procedure SelectRange(AFrom, ATo: Integer);
    procedure SetFocusIndex(AValue: Integer);
    function EntryIcon(const AEntry: TScpEntry): TScpIcon;
    function EntryColor(const AEntry: TScpEntry): TColor;
  protected
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure Resize; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetEntries(const AEntries: TScpEntryArray);
    procedure SelectAll;
    procedure ClearSelection;
    // Noms selectionnes, y compris les entrees non transferables: c'est le moteur
    // qui tranche, avec un motif. Les cacher ici les ferait disparaitre sans un mot.
    function SelectedNames: TStringArray;
    function FocusedEntry(out AEntry: TScpEntry): Boolean;
    function SelectionCount: Integer;
    procedure CaptureView(out ASelected: TStringArray; out AFocused: string;
      out ATop: Integer);
    procedure RestoreView(const ASelected: TStringArray;
      const AFocused: string; ATop: Integer);
    procedure SetPanelActive(AValue: Boolean);
    procedure SetSideKind(AValue: TFilePanelSide);
    procedure RecomputeMetrics;

    // IThemedScrollTarget
    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);

    property OnActivate: TNotifyEvent read FOnActivate write FOnActivate;
    property OnAction: TFilePanelActionEvent read FOnAction write FOnAction;
    property EntryCount: Integer read VisibleCount;
  end;

implementation

uses
  Math, DateUtils, uTransferQueue;

const
  PANEL_PAD = 6;
  MIN_ROW_HEIGHT = 18;

function FormatStamp(AUnixUtc: Int64): string;
var
  dt: TDateTime;
begin
  if AUnixUtc <= 0 then Exit('');
  dt := UniversalTimeToLocal(UnixToDateTime(AUnixUtc));
  Result := FormatDateTime('yyyy-mm-dd hh:nn', dt);
end;

{ TFileListView }

constructor TFileListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  FFocusIndex := -1;
  FAnchor := -1;
  FSortCol := fscName;
  FHoverHeader := -1;
  DoubleBuffered := True;
  RecomputeMetrics;
end;

procedure TFileListView.RecomputeMetrics;
begin
  Canvas.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Canvas.Font.Size := RSUiFontSize;
  FRowHeight := Canvas.TextHeight('Wg') + 6;
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
  avail, fixed: Integer;
  charW: Integer;
begin
  charW := Canvas.TextWidth('0');
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
    // Pas de mode POSIX ni de proprietaire en local: une colonne inventee vaut
    // moins qu'une colonne absente.
    FColWidths[fscMode] := 0;
    FColWidths[fscOwner] := 0;
  end;
  fixed := FColWidths[fscSize] + FColWidths[fscModified] +
    FColWidths[fscMode] + FColWidths[fscOwner];
  avail := ClientWidth - fixed - PANEL_PAD * 2;
  // Le nom prend le reste, avec un plancher: une fenetre etroite reduirait
  // sinon la colonne la plus utile a rien.
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

// Les dossiers d'abord, quoi qu'il arrive: les melanger dans un tri par
// taille rend la navigation impraticable.
procedure TFileListView.Reorder;
var
  i, j, tmp: Integer;

  function Less(A, B: Integer): Boolean;
  var
    ea, eb: TScpEntry;
    r: Integer;
  begin
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

procedure TFileListView.SetEntries(const AEntries: TScpEntryArray);
begin
  FEntries := AEntries;
  SetLength(FSelected, Length(FEntries));
  // FSelected[0] sur un tableau vide dereference nil, et un dossier vide est
  // un cas courant.
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
  // Sur les NOMS: apres un renommage les index ont bouge, et restaurer par
  // position selectionnerait autre chose.
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
  for i := 0 to High(FSelected) do FSelected[i] := True;
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
    if FSelected[FOrder[i]] then
    begin
      SetLength(Result, n + 1);
      Result[n] := FEntries[FOrder[i]].Name;
      Inc(n);
    end;
  // Rien de coche: l'element sous le curseur fait office de selection, comme
  // dans tout gestionnaire de fichiers.
  if (n = 0) and (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) then
  begin
    SetLength(Result, 1);
    Result[0] := FEntries[FOrder[FFocusIndex]].Name;
  end;
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
  if (AIndex >= 0) and (AIndex < Length(FOrder)) then
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
    FSelected[FOrder[i]] := True;
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
  begin
    if FColWidths[ACol] <= 0 then Exit;
    w := FColWidths[ACol];
    r := Rect(x, 0, x + w, FHeaderHeight);
    if idx = FHoverHeader then
    begin
      Canvas.Brush.Color := BlendColor(clPanelHeader, clAppFg, 88);
      Canvas.FillRect(r);
    end;
    headText := ACaption;
    // La fleche de tri porte le sens: une colonne sans fleche n'est pas celle
    // qui trie, et l'utilisateur n'a pas a s'en souvenir.
    if FSortCol = ACol then
      if FSortDesc then headText := headText + '  v'
      else headText := headText + '  ^';
    Canvas.Font.Color := clPanelHeaderText;
    Canvas.TextRect(Rect(x + PANEL_PAD, 0, x + w - 2, FHeaderHeight),
      x + PANEL_PAD, (FHeaderHeight - Canvas.TextHeight('Wg')) div 2,
      headText);
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
  fg: TColor;
  s: string;
  r: TRect;

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
  sel := FSelected[FOrder[AIndex]];
  r := Rect(0, AY, ClientWidth, AY + FRowHeight);

  if sel then
  begin
    if FPanelActive then
      Canvas.Brush.Color := clSelActive
    else
      Canvas.Brush.Color := clSelInactive;
  end
  else if Odd(AIndex) then
    Canvas.Brush.Color := clPanelAltRow
  else
    Canvas.Brush.Color := clPanelBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(r);
  Canvas.Brush.Style := bsClear;

  if sel then fg := clSelText else fg := EntryColor(e);

  textTop := AY + (FRowHeight - Canvas.TextHeight('Wg')) div 2;
  iconBox := FRowHeight - 4;
  DrawScpIcon(Canvas, Rect(PANEL_PAD, AY + 2, PANEL_PAD + iconBox,
    AY + 2 + iconBox), EntryIcon(e), fg);

  x := 0;
  w := FColWidths[fscName];
  Canvas.Font.Color := fg;
  s := DisplaySafeName(e.Name);
  if e.IsLink and (e.LinkTarget <> '') then
    s := s + '  ->  ' + e.LinkTarget;
  Canvas.TextRect(Rect(PANEL_PAD * 2 + iconBox, AY, x + w - PANEL_PAD,
    AY + FRowHeight), PANEL_PAD * 2 + iconBox, textTop, s);
  Inc(x, w);

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
        if (FFocusIndex >= 0) and (FFocusIndex < Length(FOrder)) then
          FSelected[FOrder[FFocusIndex]] :=
            not FSelected[FOrder[FFocusIndex]];
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
    VK_TAB:
      begin
        if Assigned(FOnAction) then FOnAction(fpaFocusOther);
        Key := 0;
        Exit;
      end;
    VK_A:
      begin
        // Ctrl+A ou Cmd+A: la LCL met Meta dans ssMeta, les deux doivent marcher.
        if (ssCtrl in Shift) or (ssMeta in Shift) then
        begin
          SelectAll;
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
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := FFocusIndex;
    SelectRange(FAnchor, idx);
  end
  else if (ssCtrl in Shift) or (ssMeta in Shift) then
  begin
    FSelected[FOrder[idx]] := not FSelected[FOrder[idx]];
    FAnchor := idx;
  end
  else
    SelectSingle(idx);
  SetFocusIndex(idx);
  Invalidate;
  inherited MouseDown(Button, Shift, X, Y);
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
  inherited MouseMove(Shift, X, Y);
end;

procedure TFileListView.MouseLeave;
begin
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

{ TFilePanel }

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

  FVolumeBox := TComboBox.Create(Self);
  FVolumeBox.Parent := topRow;
  FVolumeBox.Align := alLeft;
  FVolumeBox.Width := 170;
  FVolumeBox.Style := csDropDownList;
  FVolumeBox.BorderSpacing.Around := 3;
  FVolumeBox.OnChange := @VolumeSelected;

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

  FBannerRetry := TButton.Create(Self);
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
  FScroll.Bind(FList);

  ApplyTheme;
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
  if FScroll <> nil then
    FScroll.ApplyTheme(clPanelBg,
      BlendColor(clAppFg, clPanelBg, 22),
      BlendColor(clAppFg, clPanelBg, 42));
  ApplyUiFont(Self);
  Invalidate;
end;

function TFilePanel.ButtonCount: Integer;
begin
  if FSide = fpsLocal then Result := 8 else Result := 7;
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
    7: Result := siReveal;
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
    7: Result := 'Open in file manager';
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
    Result := fpaReveal;
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
  ink: TColor;
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
    // Hover et pressed se distinguent par le fond, pas par un deplacement: une
    // icone qui bouge d'un pixel a l'air d'un defaut d'affichage.
    if i = FPressedButton then
    begin
      FToolbar.Canvas.Brush.Color := clSelActive;
      FToolbar.Canvas.FillRect(r);
    end
    else if i = FHoverButton then
    begin
      FToolbar.Canvas.Brush.Color := clSideHover;
      FToolbar.Canvas.FillRect(r);
    end;
    if i = FPressedButton then ink := clSelText else ink := clAppFg;
    DrawScpIcon(FToolbar.Canvas, r, ButtonIcon(i), ink);
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
  // Relachement sur le meme bouton que l'appui: en sortir, c'est renoncer.
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
  // Sans ce drapeau, repositionner le selecteur relancerait une navigation.
  if FSuppressVolumeEvent then Exit;
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
  const AEntries: TScpEntryArray);
begin
  SetPathText(APath);
  FList.SetEntries(AEntries);
end;

function TFilePanel.SelectionCount: Integer;
begin
  Result := FList.SelectionCount;
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
  best := -1;
  bestLen := 0;
  // Le volume RETENU est le plus SPECIFIQUE qui contienne le chemin: sinon
  // « Home » gagnerait contre son propre lecteur.
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
