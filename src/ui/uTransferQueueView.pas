{ Vue de la file de transferts: une ligne par element, barre de progression,
  debit, ETA, etat et motif d'echec, plus les commandes du lot.

  Dessinee a la main pour les memes raisons que les panneaux de fichiers, et
  avec une regle supplementaire: rien n'y est ecrit qui ne soit vrai. Un
  element de taille inconnue n'affiche pas de pourcentage, une ETA sans debit
  ne s'affiche pas, et le bandeau de fin ne dit « Completed » que si tout a
  reussi -- c'est TTransferQueue.SummaryText qui en decide, pas cette vue.

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
  public
    constructor CreateView(AOwner: TComponent; AQueue: TTransferQueue);
    destructor Destroy; override;
    procedure ApplyTheme;
    procedure Refresh;
    function SelectedItemIds: TStringArray;
    procedure ClearSelection;
    property OnCommand: TQueueCommandEvent read FOnCommand write FOnCommand;
    property List: TQueueListView read FList;
  end;

  TQueueListView = class(TCustomControl, IThemedScrollTarget)
  private
    FQueue: TTransferQueue;
    FSelected: array of Boolean;
    FTop: Integer;
    FRowHeight: Integer;
    FOnViewChanged: TNotifyEvent;
    procedure DrawRow(AIndex, AY: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure Resize; override;
  public
    constructor CreateFor(AOwner: TComponent; AQueue: TTransferQueue);
    procedure SyncSelection;
    function SelectedIds: TStringArray;
    procedure ClearSelection;
    procedure RecomputeMetrics;

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

{ TQueueListView }

constructor TQueueListView.CreateFor(AOwner: TComponent;
  AQueue: TTransferQueue);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  FQueue := AQueue;
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
begin
  if Length(FSelected) <> FQueue.Count then
    SetLength(FSelected, FQueue.Count);
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

procedure TQueueListView.ClearSelection;
var
  i: Integer;
begin
  for i := 0 to High(FSelected) do FSelected[i] := False;
  Invalidate;
end;

procedure TQueueListView.DrawRow(AIndex, AY: Integer);
var
  it: TTransferItem;
  x, barX, pct, iconBox: Integer;
  r, barR: TRect;
  s: string;
  fg: TColor;
  textTop: Integer;
begin
  it := FQueue.Items[AIndex];
  r := Rect(0, AY, ClientWidth, AY + FRowHeight);
  if (AIndex < Length(FSelected)) and FSelected[AIndex] then
    Canvas.Brush.Color := clSelActive
  else if Odd(AIndex) then
    Canvas.Brush.Color := clPanelAltRow
  else
    Canvas.Brush.Color := clPanelBg;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(r);
  Canvas.Brush.Style := bsClear;

  textTop := AY + (FRowHeight - Canvas.TextHeight('Wg')) div 2;
  iconBox := FRowHeight - 6;
  x := PAD;

  // Sens du transfert, puis etat: deux icones, jamais de texte redondant.
  case it.Direction of
    tdUpload:
      DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
        siUpload, clAccent);
    tdDuplicateLocal, tdDuplicateRemote:
      DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
        siCopy, clAccent);
  else
    DrawScpIcon(Canvas, Rect(x, AY + 3, x + iconBox, AY + 3 + iconBox),
      siDownload, clAccent);
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
    // Taille inconnue, transfert commence: hachures plutot qu'un faux pourcentage.
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
      StateIcon(it.State), StateColor(it.State));
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
  // Sous verrou le temps du dessin: le fil de transfert y ecrit pendant qu'on
  // lit.
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
  idx, i: Integer;
begin
  if CanFocus then SetFocus;
  SyncSelection;
  idx := (Y + FTop) div FRowHeight;
  if (idx < 0) or (idx >= FQueue.Count) then Exit;
  if (ssCtrl in Shift) or (ssMeta in Shift) then
    FSelected[idx] := not FSelected[idx]
  else
  begin
    for i := 0 to High(FSelected) do FSelected[i] := False;
    FSelected[idx] := True;
  end;
  Invalidate;
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

{ TTransferQueueView }

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
    // ETA annoncee seulement si le total est COMPLET: sinon elle raccourcirait
    // a vue d'oeil.
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
  FBtnClear.Enabled := s.Completed + s.Skipped + s.Failed + s.Canceled > 0;
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

end.
