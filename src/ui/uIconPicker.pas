unit uIconPicker;

{$mode objfpc}{$H+}

// Choix d'icone d'arborescence: grille defilante, le catalogue est trop fourni
// pour un sous-menu. Peinte sur clSideBg, le fond de l'arbre, pour que
// l'apercu soit le rendu final (c'est ce fond qui decide de la variante).

interface

uses
  Classes, SysUtils, Controls, Forms, Graphics, ExtCtrls, StdCtrls;

function ChooseTreeIcon(AOwner: TComponent; const ACurrentId: string;
  out ANewId: string): Boolean;

implementation

uses
  uTreeIcons, uTheme, uFontEmbed;

const
  ICON_SIZE = 48;
  CELL_PAD  = 14;
  CELL      = ICON_SIZE + 2 * CELL_PAD;
  MARGIN    = 16;
  COLS      = 5;
  VIEW_H    = 430;         // hauteur visible de la grille, le reste defile

type
  TIconPickerForm = class(TForm)
  private
    FScroll: TScrollBox;
    FGrid: TPaintBox;
    FImages: TImageList;
    FSelected: Integer;
    procedure GridPaint(Sender: TObject);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure GridDblClick(Sender: TObject);
    function IndexAt(X, Y: Integer): Integer;
    procedure ScrollToSelected;
  public
    constructor CreateFor(AOwner: TComponent; const ACurrentId: string);
    property Selected: Integer read FSelected;
  end;

constructor TIconPickerForm.CreateFor(AOwner: TComponent;
  const ACurrentId: string);
var
  bar: TPanel;
  bOk, bCancel: TButton;
  rows, contentW, contentH: Integer;
begin
  inherited CreateNew(AOwner);
  FSelected := TreeIconIndex(ACurrentId);
  FImages := BuildTreeImageListSized(Self, ICON_SIZE);

  rows := (TreeIconCount + COLS - 1) div COLS;
  contentW := 2 * MARGIN + COLS * CELL;
  contentH := 2 * MARGIN + rows * CELL;

  Caption := 'Change Icon';
  BorderStyle := bsDialog;
  Position := poMainFormCenter;
  Color := clAppBg;
  ClientWidth := contentW + 20;    // + gouttiere de l'ascenseur
  ClientHeight := VIEW_H + 52;     // + barre de boutons

  bar := TPanel.Create(Self);
  bar.Parent := Self;
  bar.Align := alBottom;
  bar.Height := 52;
  bar.BevelOuter := bvNone;
  bar.Color := clAppBg;
  bar.ParentColor := False;

  bCancel := TButton.Create(Self);
  bCancel.Parent := bar;
  bCancel.Caption := 'Cancel';
  bCancel.ModalResult := mrCancel;
  bCancel.Cancel := True;
  bCancel.SetBounds(bar.Width - 200, 12, 88, 28);
  bCancel.Anchors := [akTop, akRight];

  bOk := TButton.Create(Self);
  bOk.Parent := bar;
  bOk.Caption := 'OK';
  bOk.ModalResult := mrOk;
  bOk.Default := True;
  bOk.SetBounds(bar.Width - 104, 12, 88, 28);
  bOk.Anchors := [akTop, akRight];

  FScroll := TScrollBox.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alClient;
  FScroll.BorderStyle := bsNone;
  FScroll.Color := clSideBg;
  FScroll.ParentColor := False;
  FScroll.HorzScrollBar.Visible := False;
  FScroll.VertScrollBar.Tracking := True;

  FGrid := TPaintBox.Create(Self);
  FGrid.Parent := FScroll;
  FGrid.SetBounds(0, 0, contentW, contentH);
  FGrid.OnPaint := @GridPaint;
  FGrid.OnMouseDown := @GridMouseDown;
  FGrid.OnDblClick := @GridDblClick;

  ApplyUiFont(Self);
  ScrollToSelected;
end;

// coin haut-gauche de l'ICONE, pas de la cellule
procedure CellOrigin(AIndex: Integer; out X, Y: Integer);
begin
  X := MARGIN + (AIndex mod COLS) * CELL + CELL_PAD;
  Y := MARGIN + (AIndex div COLS) * CELL + CELL_PAD;
end;

procedure TIconPickerForm.GridPaint(Sender: TObject);
var
  i, x, y: Integer;
begin
  FGrid.Canvas.Brush.Color := clSideBg;
  FGrid.Canvas.Brush.Style := bsSolid;
  FGrid.Canvas.FillRect(0, 0, FGrid.Width, FGrid.Height);
  for i := 0 to TreeIconCount - 1 do
  begin
    CellOrigin(i, x, y);
    if i = FSelected then
    begin
      FGrid.Canvas.Brush.Color := clSideSel;
      FGrid.Canvas.FillRect(x - CELL_PAD div 2, y - CELL_PAD div 2,
        x + ICON_SIZE + CELL_PAD div 2, y + ICON_SIZE + CELL_PAD div 2);
      FGrid.Canvas.Brush.Style := bsClear;
      FGrid.Canvas.Pen.Color := clSideActive;
      FGrid.Canvas.Pen.Width := 2;
      FGrid.Canvas.Rectangle(x - CELL_PAD div 2, y - CELL_PAD div 2,
        x + ICON_SIZE + CELL_PAD div 2, y + ICON_SIZE + CELL_PAD div 2);
      FGrid.Canvas.Pen.Width := 1;
      FGrid.Canvas.Brush.Style := bsSolid;
      FGrid.Canvas.Brush.Color := clSideBg;
    end;
    FImages.Draw(FGrid.Canvas, x, y, i);
  end;
end;

function TIconPickerForm.IndexAt(X, Y: Integer): Integer;
var
  col, row: Integer;
begin
  Result := -1;
  if (X < MARGIN) or (Y < MARGIN) then Exit;
  col := (X - MARGIN) div CELL;
  row := (Y - MARGIN) div CELL;
  if (col < 0) or (col >= COLS) then Exit;
  Result := row * COLS + col;
  if (Result < 0) or (Result >= TreeIconCount) then
    Result := -1;
end;

procedure TIconPickerForm.GridMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  idx: Integer;
begin
  idx := IndexAt(X, Y);
  if idx < 0 then Exit;
  FSelected := idx;
  FGrid.Invalidate;
end;

procedure TIconPickerForm.GridDblClick(Sender: TObject);
begin
  if FSelected >= 0 then
    ModalResult := mrOk;
end;

// sinon une icone choisie en bas de catalogue s'ouvre hors champ
procedure TIconPickerForm.ScrollToSelected;
var
  x, y: Integer;
begin
  if FSelected <= 0 then Exit;
  CellOrigin(FSelected, x, y);
  if y + CELL > VIEW_H then
    FScroll.VertScrollBar.Position := y - VIEW_H div 2;
end;

function ChooseTreeIcon(AOwner: TComponent; const ACurrentId: string;
  out ANewId: string): Boolean;
var
  f: TIconPickerForm;
begin
  Result := False;
  ANewId := '';
  f := TIconPickerForm.CreateFor(AOwner, ACurrentId);
  try
    if f.ShowModal = mrOk then
    begin
      ANewId := TreeIconIdAt(f.Selected);
      Result := ANewId <> '';
    end;
  finally
    f.Free;
  end;
end;

end.
