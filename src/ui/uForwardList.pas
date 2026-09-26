{ Liste des tunnels d'un hote, dans l'onglet « Tunnels » des proprietes:
  actif, port local, destination, note. Peinte aux couleurs du theme, comme
  les panneaux de fichiers. La case de la premiere colonne active ou coupe un
  tunnel sans le perdre.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uForwardList;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, LCLType, uTheme, uRshModel;

type
  TForwardListView = class(TCustomControl)
  private
    FItems: TRshLocalForwards;
    // True: un autre hote ecoute deja ce port (marque dans la colonne)
    FClash: array of Boolean;
    FSel: Integer;
    FTop: Integer;
    FOnSelect: TNotifyEvent;
    FOnToggle: TNotifyEvent;
    FOnDeleteKey: TNotifyEvent;
    function RowH: Integer;
    function HeaderH: Integer;
    function VisibleRows: Integer;
    function RowAt(Y: Integer): Integer;
    procedure ColumnX(out AOn, APort, ADest, ANote: Integer);
    procedure EnsureVisible(AIndex: Integer);
    procedure SetSel(AIndex: Integer);
    function Fit(const S: string; AWidth: Integer): string;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetItems(const AItems: TRshLocalForwards);
    procedure SetClash(AIndex: Integer; AValue: Boolean);
    function Count: Integer;
    function Item(AIndex: Integer): TRshLocalForward;
    procedure Replace(AIndex: Integer; const AItem: TRshLocalForward);
    procedure Append(const AItem: TRshLocalForward);
    procedure Remove(AIndex: Integer);
    procedure Toggle(AIndex: Integer);
    property Items: TRshLocalForwards read FItems;
    // -1 = rien de selectionne
    property Selected: Integer read FSel write SetSel;
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
    property OnToggle: TNotifyEvent read FOnToggle write FOnToggle;
    property OnDeleteKey: TNotifyEvent read FOnDeleteKey write FOnDeleteKey;
  end;

implementation

uses
  uThemedControls;

const
  PAD = 8;
  BOX = 14;

constructor TForwardListView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  DoubleBuffered := True;
  FSel := -1;
  FTop := 0;
end;

function TForwardListView.RowH: Integer;
begin
  Result := UiTextHeight('Ag') + 9;
end;

function TForwardListView.HeaderH: Integer;
begin
  Result := RowH + 2;
end;

function TForwardListView.VisibleRows: Integer;
begin
  Result := (ClientHeight - HeaderH - 2) div RowH;
  if Result < 1 then
    Result := 1;
end;

procedure TForwardListView.ColumnX(out AOn, APort, ADest, ANote: Integer);
var
  rest: Integer;
begin
  AOn := PAD;
  APort := AOn + BOX + 14;
  ADest := APort + UiTextWidth('Local port') + 22;
  rest := ClientWidth - ADest - PAD;
  ANote := ADest + (rest * 60) div 100;
end;

function TForwardListView.RowAt(Y: Integer): Integer;
begin
  Result := -1;
  if Y < HeaderH then Exit;
  Result := FTop + (Y - HeaderH) div RowH;
  if Result >= Length(FItems) then
    Result := -1;
end;

procedure TForwardListView.EnsureVisible(AIndex: Integer);
begin
  if AIndex < 0 then Exit;
  if AIndex < FTop then
    FTop := AIndex
  else if AIndex >= FTop + VisibleRows then
    FTop := AIndex - VisibleRows + 1;
  if FTop < 0 then FTop := 0;
end;

procedure TForwardListView.SetSel(AIndex: Integer);
begin
  if (AIndex < -1) or (AIndex >= Length(FItems)) then
    AIndex := -1;
  if AIndex = FSel then Exit;
  FSel := AIndex;
  EnsureVisible(FSel);
  Invalidate;
  if Assigned(FOnSelect) then
    FOnSelect(Self);
end;

procedure TForwardListView.SetItems(const AItems: TRshLocalForwards);
begin
  FItems := Copy(AItems);
  SetLength(FClash, Length(FItems));
  FSel := -1;
  FTop := 0;
  Invalidate;
end;

procedure TForwardListView.SetClash(AIndex: Integer; AValue: Boolean);
begin
  if (AIndex < 0) or (AIndex > High(FClash)) then Exit;
  if FClash[AIndex] = AValue then Exit;
  FClash[AIndex] := AValue;
  Invalidate;
end;

function TForwardListView.Count: Integer;
begin
  Result := Length(FItems);
end;

function TForwardListView.Item(AIndex: Integer): TRshLocalForward;
begin
  Result := FItems[AIndex];
end;

procedure TForwardListView.Replace(AIndex: Integer;
  const AItem: TRshLocalForward);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  FItems[AIndex] := AItem;
  Invalidate;
end;

procedure TForwardListView.Append(const AItem: TRshLocalForward);
var
  n: Integer;
begin
  n := Length(FItems);
  SetLength(FItems, n + 1);
  SetLength(FClash, n + 1);
  FItems[n] := AItem;
  FClash[n] := False;
  FSel := -1;
  SetSel(n);
end;

procedure TForwardListView.Remove(AIndex: Integer);
var
  i: Integer;
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  for i := AIndex to High(FItems) - 1 do
  begin
    FItems[i] := FItems[i + 1];
    FClash[i] := FClash[i + 1];
  end;
  SetLength(FItems, Length(FItems) - 1);
  SetLength(FClash, Length(FClash) - 1);
  if FTop > 0 then
    Dec(FTop);
  // la selection reste au meme rang: on enchaine les suppressions au clavier
  FSel := -1;
  if Length(FItems) > 0 then
  begin
    if AIndex > High(FItems) then
      AIndex := High(FItems);
    SetSel(AIndex);
  end
  else
  begin
    Invalidate;
    if Assigned(FOnSelect) then
      FOnSelect(Self);
  end;
end;

procedure TForwardListView.Toggle(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FItems)) then Exit;
  FItems[AIndex].Enabled := not FItems[AIndex].Enabled;
  Invalidate;
  if Assigned(FOnToggle) then
    FOnToggle(Self);
end;

// Texte trop long pour sa colonne: coupe avec « … », pour qu'on voie qu'il
// continue (hote coupe net = hote qu'on croit lire en entier).
function TForwardListView.Fit(const S: string; AWidth: Integer): string;
var
  n: Integer;
begin
  Result := S;
  if (AWidth <= 0) or (Canvas.TextWidth(S) <= AWidth) then Exit;
  n := Length(UTF8Decode(S));
  while n > 0 do
  begin
    Dec(n);
    Result := UTF8Encode(Copy(UTF8Decode(S), 1, n)) + '…';
    if Canvas.TextWidth(Result) <= AWidth then Exit;
  end;
  Result := '…';
end;

procedure TForwardListView.Paint;
var
  r, cell: TRect;
  xOn, xPort, xDest, xNote, y, i, th, rh, hh: Integer;
  bg, fg, fg2: TColor;
  it: TRshLocalForward;
  msg: string;
begin
  r := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := clAppBg;
  Canvas.FillRect(r);
  Canvas.Brush.Color := ThemeFieldColor;
  if Focused then
    Canvas.Pen.Color := clAccent
  else
    Canvas.Pen.Color := BlendColor(clAppFg, clAppBg, 30);
  Canvas.RoundRect(r.Left, r.Top, r.Right, r.Bottom, 6, 6);

  Canvas.Font := Font;
  th := Canvas.TextHeight('Ag');
  rh := RowH;
  hh := HeaderH;
  ColumnX(xOn, xPort, xDest, xNote);

  // en-tete
  Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 10);
  Canvas.FillRect(Rect(1, 1, r.Right - 1, hh));
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clTextSecondary;
  y := (hh - th) div 2;
  Canvas.TextOut(xOn - 2, y, 'On');
  Canvas.TextOut(xPort, y, 'Local port');
  Canvas.TextOut(xDest, y, 'Destination');
  Canvas.TextOut(xNote, y, 'Note');

  if Length(FItems) = 0 then
  begin
    msg := 'No tunnel yet. Fill in the fields below, then click Add.';
    Canvas.Font.Color := clTextSecondary;
    Canvas.TextOut((r.Width - Canvas.TextWidth(msg)) div 2,
      hh + (r.Height - hh - th) div 2, msg);
    Canvas.Brush.Style := bsSolid;
    Exit;
  end;

  for i := FTop to High(FItems) do
  begin
    y := hh + (i - FTop) * rh;
    if y + rh > r.Bottom - 1 then Break;
    it := FItems[i];
    cell := Rect(1, y, r.Right - 1, y + rh);
    Canvas.Brush.Style := bsSolid;
    if i = FSel then
    begin
      if Focused then bg := clSelActive else bg := clSelInactive;
      fg := clSelText;
      fg2 := clSelText;
    end
    else
    begin
      if Odd(i) then
        bg := BlendColor(clAppFg, ThemeFieldColor, 4)
      else
        bg := ThemeFieldColor;
      fg := clAppFg;
      fg2 := clTextSecondary;
    end;
    Canvas.Brush.Color := bg;
    Canvas.FillRect(cell);
    // un tunnel coupe reste lisible, mais en retrait
    if not it.Enabled then
      fg := fg2;

    // case « actif »
    Canvas.Pen.Color := BlendColor(clAppFg, clAppBg, 40);
    if it.Enabled then
      Canvas.Brush.Color := clAccent
    else
      Canvas.Brush.Color := ThemeFieldColor;
    Canvas.RoundRect(xOn, y + (rh - BOX) div 2, xOn + BOX,
      y + (rh - BOX) div 2 + BOX, 3, 3);
    if it.Enabled then
    begin
      Canvas.Pen.Color := ContrastTextColor(clAccent);
      Canvas.Pen.Width := 2;
      Canvas.Line(xOn + 3, y + rh div 2, xOn + 6, y + rh div 2 + 3);
      Canvas.Line(xOn + 6, y + rh div 2 + 3, xOn + 11, y + rh div 2 - 3);
      Canvas.Pen.Width := 1;
    end;

    Canvas.Brush.Style := bsClear;
    Canvas.Font.Color := fg;
    Canvas.TextRect(Rect(xPort, y, xDest - 6, y + rh), xPort,
      y + (rh - th) div 2, IntToStr(it.LocalPort));
    if FClash[i] then
    begin
      Canvas.Font.Color := clScpWarn;
      Canvas.TextOut(xPort + Canvas.TextWidth(IntToStr(it.LocalPort)) + 6,
        y + (rh - th) div 2, '⚠');
      Canvas.Font.Color := fg;
    end;
    Canvas.TextRect(Rect(xDest, y, xNote - 8, y + rh), xDest,
      y + (rh - th) div 2, Fit(Format('%s:%d', [it.DestHost, it.DestPort]),
      xNote - 8 - xDest));
    if i <> FSel then
      Canvas.Font.Color := fg2;
    Canvas.TextRect(Rect(xNote, y, r.Right - PAD, y + rh), xNote,
      y + (rh - th) div 2, Fit(it.Note, r.Right - PAD - xNote));
  end;
  Canvas.Brush.Style := bsSolid;
end;

procedure TForwardListView.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  i, xOn, xPort, xDest, xNote: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
  if Button <> mbLeft then Exit;
  i := RowAt(Y);
  SetSel(i);
  ColumnX(xOn, xPort, xDest, xNote);
  if (i >= 0) and (X < xPort - 4) then
    Toggle(i);
end;

function TForwardListView.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  maxTop: Integer;
begin
  Result := True;
  maxTop := Length(FItems) - VisibleRows;
  if maxTop < 0 then maxTop := 0;
  if WheelDelta > 0 then
    Dec(FTop)
  else
    Inc(FTop);
  if FTop > maxTop then FTop := maxTop;
  if FTop < 0 then FTop := 0;
  Invalidate;
end;

procedure TForwardListView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  case Key of
    VK_UP:
      begin
        if FSel > 0 then SetSel(FSel - 1)
        else if (FSel < 0) and (Length(FItems) > 0) then SetSel(0);
        Key := 0;
      end;
    VK_DOWN:
      begin
        if FSel < High(FItems) then SetSel(FSel + 1);
        Key := 0;
      end;
    VK_SPACE:
      begin
        Toggle(FSel);
        Key := 0;
      end;
    VK_DELETE:
      begin
        if (FSel >= 0) and Assigned(FOnDeleteKey) then
          FOnDeleteKey(Self);
        Key := 0;
      end;
  end;
  if Key <> 0 then
    inherited KeyDown(Key, Shift);
end;

procedure TForwardListView.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TForwardListView.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

end.
