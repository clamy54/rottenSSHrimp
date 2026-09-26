{ Regle: rien d'affiche qui ne soit vrai. Pas de pourcentage sans taille, pas
  d'ETA sans debit; « Completed », c'est TTransferQueue.SummaryText qui decide.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uTransferQueueView;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, Forms, StdCtrls, ExtCtrls,
  LCLType, uTransferQueue, uScpErrors, uScpPaths, uTheme, uScpIcons,
  uTreeScrollBar;

type
  TQueueCommand = (qcPause, qcResume, qcCancelSelected, qcClearCompleted,
    qcRetryFailed);

  TQueueCommandEvent = procedure(ACommand: TQueueCommand) of object;

  TQueueListView = class;

  TTransferQueueView = class(TPanel)
  private
    FQueue: TTransferQueue;
    FHeader: TPanel;
    FSummary: TLabel;
    FBtnPause, FBtnResume, FBtnCancel, FBtnClear, FBtnRetry: TButton;
    FList: TQueueListView;
    FScroll: TTreeScrollBar;
    FOnCommand: TQueueCommandEvent;
    FRate: TRateMeter;
    procedure CommandClick(Sender: TObject);
    procedure ListSelectionChanged(Sender: TObject);
    procedure ListCancelKey(Sender: TObject);
  public
    constructor CreateView(AOwner: TComponent; AQueue: TTransferQueue);
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure Refresh;
    function SelectedItemIds: TStringArray;
    procedure ClearSelection;
    // Par identifiant: apres « Clear completed », les positions ont bouge.
    procedure RestoreSelection(const AIds: TStringArray; AFocusId: Int64);
    function FocusedItemId: Int64;
    property OnCommand: TQueueCommandEvent read FOnCommand write FOnCommand;
    property List: TQueueListView read FList;
  end;

  TQueueListView = class(TCustomControl, IThemedScrollTarget)
  private
    FQueue: TTransferQueue;
    // Par POSITION: ajout en queue seulement, retrait par le seul thread UI.
    FSelected: array of Boolean;
    FFocus: Integer;         // -1 = aucune ligne
    FAnchor: Integer;        // origine d'une plage au Maj+clic
    FTop: Integer;
    FRowHeight: Integer;
    FOnViewChanged: TNotifyEvent;
    FOnSelectionChanged: TNotifyEvent;
    FOnCancelKey: TNotifyEvent;
    procedure DrawRow(AIndex, AY: Integer);
    procedure SelectRange(AFrom, ATo: Integer);
    procedure SelectOnly(AIndex: Integer);
    procedure SetFocusRow(AIndex: Integer);
    procedure SelectionChanged;
  protected
    procedure Paint; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor CreateFor(AOwner: TComponent; AQueue: TTransferQueue);
    procedure SyncSelection;
    function SelectedIds: TStringArray;
    function SelectionCount: Integer;
    procedure ClearSelection;
    procedure SelectAll;
    procedure SelectIds(const AIds: TStringArray; AFocusId: Int64);
    function FocusedId: Int64;
    procedure RecomputeMetrics;
    property OnSelectionChanged: TNotifyEvent
      read FOnSelectionChanged write FOnSelectionChanged;
    // Suppr
    property OnCancelKey: TNotifyEvent read FOnCancelKey write FOnCancelKey;

    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);
  end;

implementation

uses
  Math;

const
  PAD = 6;
  BAR_W = 120;

function StateColor(AState: TTransferState): TColor;
begin
  case AState of
    tsCompleted: Result := clScpOk;
    tsFailed: Result := clScpErr;
    tsSkipped: Result := clScpWarn;
    tsCanceled: Result := clTextSecondary;
    tsInterrupted: Result := clScpWarn;
    tsTransferring, tsEnumerating: Result := clAccent;
  else
    Result := clTextSecondary;
  end;
end;

function StateIcon(AState: TTransferState): TScpIcon;
begin
  case AState of
    tsCompleted: Result := siCheck;
    tsFailed: Result := siError;
    tsSkipped: Result := siWarning;
    tsCanceled: Result := siCancel;
    tsInterrupted: Result := siWarning;
    tsPaused: Result := siPause;
    tsTransferring: Result := siPlay;
  else
    Result := siNone;
  end;
end;

constructor TQueueListView.CreateFor(AOwner: TComponent;
  AQueue: TTransferQueue);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  FQueue := AQueue;
  FFocus := -1;
  FAnchor := -1;
  RecomputeMetrics;
end;

procedure TQueueListView.RecomputeMetrics;
begin
  if RSUiFontName <> '' then Canvas.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Canvas.Font.Size := RSUiFontSize;
  FRowHeight := UiTextHeight('Wg') + 8;
  if FRowHeight < 20 then FRowHeight := 20;
end;

procedure TQueueListView.SyncSelection;
var
  c: Integer;
begin
  c := FQueue.Count;
  if Length(FSelected) <> c then
    SetLength(FSelected, c);
  if FFocus >= c then FFocus := c - 1;
  if FAnchor >= c then FAnchor := -1;
  if FTop > ScrollMaxTop then FTop := ScrollMaxTop;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
end;

function TQueueListView.SelectedIds: TStringArray;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  FQueue.Lock;
  try
    for i := 0 to Min(High(FSelected), FQueue.Count - 1) do
      if FSelected[i] then
      begin
        SetLength(Result, n + 1);
        Result[n] := IntToStr(FQueue.Items[i].Id);
        Inc(n);
      end;
  finally
    FQueue.Unlock;
  end;
end;

function TQueueListView.SelectionCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FSelected) do
    if FSelected[i] then Inc(Result);
end;

procedure TQueueListView.SelectionChanged;
begin
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TQueueListView.ClearSelection;
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  FAnchor := -1;
  SelectionChanged;
end;

procedure TQueueListView.SelectAll;
var
  i: Integer;
begin
  SyncSelection;
  for i := 0 to High(FSelected) do FSelected[i] := True;
  SelectionChanged;
end;

procedure TQueueListView.SelectOnly(AIndex: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  if (AIndex >= 0) and (AIndex < Length(FSelected)) then
    FSelected[AIndex] := True;
  FAnchor := AIndex;
end;

procedure TQueueListView.SelectRange(AFrom, ATo: Integer);
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do
    FSelected[i] := (i >= Min(AFrom, ATo)) and (i <= Max(AFrom, ATo));
end;

procedure TQueueListView.SetFocusRow(AIndex: Integer);
var
  rowTop: Integer;
begin
  if Length(FSelected) = 0 then
  begin
    FFocus := -1;
    Exit;
  end;
  FFocus := Max(0, Min(AIndex, High(FSelected)));
  rowTop := FFocus * FRowHeight;
  if rowTop < FTop then
    ScrollSetTop(rowTop)
  else if rowTop + FRowHeight > FTop + ClientHeight then
    ScrollSetTop(rowTop + FRowHeight - ClientHeight);
end;

function TQueueListView.FocusedId: Int64;
begin
  Result := -1;
  FQueue.Lock;
  try
    if (FFocus >= 0) and (FFocus < FQueue.Count) then
      Result := FQueue.Items[FFocus].Id;
  finally
    FQueue.Unlock;
  end;
end;

// Liste triee: sinon Ctrl+A puis « Clear completed » = O(n^2) sur le thread UI.
procedure TQueueListView.SelectIds(const AIds: TStringArray;
  AFocusId: Int64);
var
  i, k: Integer;
  id: Int64;
  wanted: TStringList;
begin
  SyncSelection;
  for i := 0 to High(FSelected) do FSelected[i] := False;
  FFocus := -1;
  wanted := TStringList.Create;
  try
    wanted.Sorted := True;
    wanted.Duplicates := dupIgnore;
    for k := 0 to High(AIds) do wanted.Add(AIds[k]);
    FQueue.Lock;
    try
      for i := 0 to Min(High(FSelected), FQueue.Count - 1) do
      begin
        id := FQueue.Items[i].Id;
        if id = AFocusId then FFocus := i;
        FSelected[i] := wanted.Find(IntToStr(id), k);
      end;
    finally
      FQueue.Unlock;
    end;
  finally
    wanted.Free;
  end;
  FAnchor := FFocus;
  SelectionChanged;
end;

procedure TQueueListView.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TQueueListView.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

// ssMeta = Cmd sous macOS: meme role que Ctrl.
procedure TQueueListView.KeyDown(var Key: Word; Shift: TShiftState);
var
  target, page: Integer;
begin
  SyncSelection;
  page := Max(1, ClientHeight div Max(FRowHeight, 1));
  case Key of
    VK_UP: target := FFocus - 1;
    VK_DOWN: target := FFocus + 1;
    VK_PRIOR: target := FFocus - page;
    VK_NEXT: target := FFocus + page;
    VK_HOME: target := 0;
    VK_END: target := High(FSelected);
    VK_SPACE:
      begin
        if (FFocus >= 0) and (FFocus < Length(FSelected)) then
        begin
          FSelected[FFocus] := not FSelected[FFocus];
          FAnchor := FFocus;
          SelectionChanged;
        end;
        Key := 0;
        Exit;
      end;
    VK_A:
      begin
        if (ssCtrl in Shift) or (ssMeta in Shift) then
        begin
          SelectAll;
          Key := 0;
        end
        else
          inherited KeyDown(Key, Shift);
        Exit;
      end;
    VK_ESCAPE:
      begin
        ClearSelection;
        Key := 0;
        Exit;
      end;
    VK_DELETE:
      begin
        if Assigned(FOnCancelKey) then FOnCancelKey(Self);
        Key := 0;
        Exit;
      end;
  else
    inherited KeyDown(Key, Shift);
    Exit;
  end;
  Key := 0;
  if Length(FSelected) = 0 then Exit;
  if FFocus < 0 then target := 0;
  target := Max(0, Min(target, High(FSelected)));
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := Max(FFocus, 0);
    SelectRange(FAnchor, target);
  end
  else if not ((ssCtrl in Shift) or (ssMeta in Shift)) then
    SelectOnly(target);
  SetFocusRow(target);
  SelectionChanged;
end;

procedure TQueueListView.DrawRow(AIndex, AY: Integer);
var
  it: TTransferItem;
  x, barX, pct, iconBox: Integer;
  r, barR: TRect;
  s: string;
  fg, rowBg: TColor;
  textTop: Integer;
begin
  it := FQueue.Items[AIndex];
  r := Rect(0, AY, ClientWidth, AY + FRowHeight);
  if (AIndex < Length(FSelected)) and FSelected[AIndex] then
    rowBg := clSelActive
  else if Odd(AIndex) then
    rowBg := clPanelAltRow
  else
    rowBg := clPanelBg;
  Canvas.Brush.Color := rowBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(r);
  Canvas.Brush.Style := bsClear;

  textTop := AY + (FRowHeight - Canvas.TextHeight('Wg')) div 2;
  iconBox := FRowHeight - 6;
  x := PAD;

  case it.Direction of
    tdUpload:
      DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
        siUpload, clAccent, rowBg);
    tdDuplicateLocal, tdDuplicateRemote:
      DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
        siCopy, clAccent, rowBg);
  else
    DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
      siDownload, clAccent, rowBg);
  end;
  Inc(x, iconBox + PAD);

  fg := clAppFg;
  if (AIndex < Length(FSelected)) and FSelected[AIndex] then fg := clSelText;
  Canvas.Font.Color := fg;
  s := it.DisplayName;
  if it.Kind = tikMakeDir then s := s + '  (folder)';
  Canvas.TextRect(Rect(x, AY, ClientWidth - BAR_W - 340, AY + FRowHeight),
    x, textTop, s);

  barX := ClientWidth - BAR_W - 330;
  if barX < x + 40 then barX := x + 40;

  pct := it.PercentDone;
  barR := Rect(barX, AY + (FRowHeight - 10) div 2, barX + BAR_W,
    AY + (FRowHeight - 10) div 2 + 10);
  Canvas.Brush.Color := clProgressTrack;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(barR);
  if pct > 0 then
  begin
    Canvas.Brush.Color := clProgressBar;
    Canvas.FillRect(Rect(barR.Left, barR.Top,
      barR.Left + (BAR_W * pct) div 100, barR.Bottom));
  end
  else if pct < 0 then
  begin
    // Taille inconnue: pas de faux pourcentage.
    Canvas.Brush.Color := BlendColor(clProgressBar, clProgressTrack, 40);
    Canvas.FillRect(barR);
  end;
  Canvas.Brush.Style := bsClear;

  x := barX + BAR_W + PAD;
  Canvas.Font.Color := clTextSecondary;
  if it.TotalBytes >= 0 then
    s := Format('%s / %s', [FormatBytes(it.DoneBytes),
      FormatBytes(it.TotalBytes)])
  else if it.DoneBytes > 0 then
    s := FormatBytes(it.DoneBytes)
  else
    s := '';
  Canvas.TextRect(Rect(x, AY, x + 160, AY + FRowHeight), x, textTop, s);
  Inc(x, 165);

  Canvas.Font.Color := StateColor(it.State);
  if StateIcon(it.State) <> siNone then
  begin
    DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
      StateIcon(it.State), StateColor(it.State), rowBg);
    Inc(x, iconBox + 4);
  end;
  s := TransferStateName(it.State);
  // Le motif prime sur l'etat: « Failed » seul n'aide personne.
  if it.Error.Kind <> sekNone then
    s := s + ' - ' + ScpErrorKindLabel(it.Error.Kind)
  else if it.Warning <> '' then
    s := s + ' - attributes not preserved';
  Canvas.TextRect(Rect(x, AY, ClientWidth - PAD, AY + FRowHeight), x,
    textTop, s);

  if Focused and (AIndex = FFocus) then
  begin
    Canvas.Pen.Color := BlendColor(clAppFg, rowBg, 45);
    Canvas.Brush.Style := bsClear;
    Canvas.Rectangle(Rect(0, AY, ClientWidth, AY + FRowHeight));
  end;
end;

procedure TQueueListView.Paint;
var
  i, y, firstRow, lastRow: Integer;
begin
  Canvas.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then Canvas.Font.Size := RSUiFontSize;
  Canvas.Brush.Color := clPanelBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  Canvas.Brush.Style := bsClear;
  // le fil de transfert ecrit pendant qu'on lit
  FQueue.Lock;
  try
    if FQueue.Count = 0 then
    begin
      Canvas.Font.Color := clTextSecondary;
      Canvas.TextOut(PAD * 2, PAD, 'No transfers queued.');
      Exit;
    end;
    firstRow := FTop div FRowHeight;
    lastRow := (FTop + ClientHeight) div FRowHeight;
    if lastRow > FQueue.Count - 1 then lastRow := FQueue.Count - 1;
    for i := firstRow to lastRow do
    begin
      y := i * FRowHeight - FTop;
      if y > ClientHeight then Break;
      DrawRow(i, y);
    end;
  finally
    FQueue.Unlock;
  end;
end;

procedure TQueueListView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  idx: Integer;
begin
  if CanFocus then SetFocus;
  SyncSelection;
  idx := (Y + FTop) div FRowHeight;
  // FSelected, pas la file: elle a pu grossir depuis SyncSelection.
  if (idx < 0) or (idx >= Length(FSelected)) then Exit;
  if ssShift in Shift then
  begin
    if FAnchor < 0 then FAnchor := Max(FFocus, 0);
    SelectRange(FAnchor, idx);
  end
  else if (ssCtrl in Shift) or (ssMeta in Shift) then
  begin
    FSelected[idx] := not FSelected[idx];
    FAnchor := idx;
  end
  // Clic droit dans la selection: elle reste entiere.
  else if not ((Button = mbRight) and FSelected[idx]) then
    SelectOnly(idx);
  SetFocusRow(idx);
  SelectionChanged;
  inherited MouseDown(Button, Shift, X, Y);
end;

function TQueueListView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  ScrollWheelBy(WheelDelta);
  Result := True;
end;

procedure TQueueListView.Resize;
begin
  inherited Resize;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

function TQueueListView.ScrollViewportHeight: Integer;
begin
  Result := ClientHeight;
end;

function TQueueListView.ScrollMaxTop: Integer;
begin
  Result := FQueue.Count * FRowHeight - ClientHeight;
  if Result < 0 then Result := 0;
end;

function TQueueListView.ScrollGetTop: Integer;
begin
  Result := FTop;
end;

procedure TQueueListView.ScrollSetTop(AValue: Integer);
begin
  AValue := Max(0, Min(AValue, ScrollMaxTop));
  if AValue = FTop then Exit;
  FTop := AValue;
  if Assigned(FOnViewChanged) then FOnViewChanged(Self);
  Invalidate;
end;

procedure TQueueListView.ScrollAnimateBy(ADelta: Integer);
begin
  ScrollSetTop(FTop + ADelta);
end;

procedure TQueueListView.ScrollWheelBy(AWheelDelta: Integer);
begin
  ScrollSetTop(FTop - (AWheelDelta div 120) * FRowHeight * 3);
end;

procedure TQueueListView.SetOnScrollViewChanged(AHandler: TNotifyEvent);
begin
  FOnViewChanged := AHandler;
end;

constructor TTransferQueueView.CreateView(AOwner: TComponent;
  AQueue: TTransferQueue);

  function AddBtn(const ACaption: string; ATag: Integer): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := FHeader;
    Result.Align := alRight;
    Result.Caption := ACaption;
    Result.AutoSize := True;
    Result.Tag := ATag;
    Result.BorderSpacing.Around := 3;
    Result.OnClick := @CommandClick;
  end;

begin
  inherited Create(AOwner);
  FQueue := AQueue;
  FRate := TRateMeter.Create;
  BevelOuter := bvNone;
  ParentBackground := False;
  ParentColor := False;

  FHeader := TPanel.Create(Self);
  FHeader.Parent := Self;
  FHeader.Align := alTop;
  FHeader.Height := 32;
  FHeader.BevelOuter := bvNone;
  FHeader.ParentBackground := False;
  FHeader.ParentColor := False;

  FBtnClear := AddBtn('Clear completed', Ord(qcClearCompleted));
  FBtnRetry := AddBtn('Retry failed', Ord(qcRetryFailed));
  FBtnCancel := AddBtn('Cancel selected', Ord(qcCancelSelected));
  FBtnResume := AddBtn('Resume queue', Ord(qcResume));
  FBtnPause := AddBtn('Pause queue', Ord(qcPause));

  FSummary := TLabel.Create(Self);
  FSummary.Parent := FHeader;
  FSummary.Align := alClient;
  FSummary.Layout := tlCenter;
  FSummary.BorderSpacing.Left := PAD;

  FScroll := TTreeScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alRight;
  FScroll.Width := 12;

  FList := TQueueListView.CreateFor(Self, AQueue);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.OnSelectionChanged := @ListSelectionChanged;
  FList.OnCancelKey := @ListCancelKey;
  FScroll.Bind(FList);

  ApplyTheme;
end;

destructor TTransferQueueView.Destroy;
begin
  FRate.Free;
  inherited Destroy;
end;

procedure TTransferQueueView.ApplyTheme;
begin
  Color := clPanelBg;
  FHeader.Color := clPanelHeader;
  FSummary.Font.Color := clPanelHeaderText;
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

procedure TTransferQueueView.ListSelectionChanged(Sender: TObject);
begin
  FBtnCancel.Enabled := FList.SelectionCount > 0;
end;

procedure TTransferQueueView.ListCancelKey(Sender: TObject);
begin
  if (FList.SelectionCount > 0) and Assigned(FOnCommand) then
    FOnCommand(qcCancelSelected);
end;

procedure TTransferQueueView.CommandClick(Sender: TObject);
begin
  if Assigned(FOnCommand) then
    FOnCommand(TQueueCommand(TButton(Sender).Tag));
end;

procedure TTransferQueueView.Refresh;
var
  s: TQueueSummary;
  txt, extra: string;
  remaining: Int64;
  eta: Int64;
begin
  FList.SyncSelection;
  s := FQueue.Summary;
  txt := FQueue.SummaryText;

  FRate.Sample(GetTickCount64, s.BytesDone);
  extra := '';
  if s.Running > 0 then
  begin
    if FRate.BytesPerSecond > 0 then
      extra := '  -  ' + FormatRate(FRate.BytesPerSecond);
    // total partiel = ETA qui fond a vue d'oeil: on s'abstient
    if not s.BytesTotalIsPartial then
    begin
      remaining := s.BytesTotal - s.BytesDone;
      eta := FRate.EtaSeconds(remaining);
      if eta >= 0 then
        extra := extra + '  -  ' + FormatEta(eta) + ' left';
    end;
  end;
  if FQueue.IsPaused and (s.Pending > 0) then
    extra := extra + '  -  queue paused';
  FSummary.Caption := txt + extra;

  FBtnPause.Enabled := (not FQueue.IsPaused) and (s.Pending + s.Running > 0);
  FBtnResume.Enabled := FQueue.IsPaused;
  FBtnRetry.Enabled := s.Failed + s.Interrupted > 0;
  // les echecs survivent a la purge, ils ne l'activent pas
  FBtnClear.Enabled := s.Completed + s.Skipped + s.Canceled > 0;
  FBtnCancel.Enabled := FList.SelectionCount > 0;
  FList.Invalidate;
end;

function TTransferQueueView.SelectedItemIds: TStringArray;
begin
  Result := FList.SelectedIds;
end;

procedure TTransferQueueView.ClearSelection;
begin
  FList.ClearSelection;
end;

procedure TTransferQueueView.RestoreSelection(const AIds: TStringArray;
  AFocusId: Int64);
begin
  FList.SelectIds(AIds, AFocusId);
end;

function TTransferQueueView.FocusedItemId: Int64;
begin
  Result := FList.FocusedId;
end;

end.
