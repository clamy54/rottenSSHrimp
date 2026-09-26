{ Separateur deplacable, peint aux couleurs du theme, et qui repeint tout de
  suite ce qu'il vient de redimensionner.

  Deux raisons de ne pas utiliser TSplitter tel quel:

  - sans OnPaint, la LCL y dessine le motif du systeme. Celui-ci reste clair
    en theme sombre, et le separateur devient invisible -- on ne sait plus
    qu'il y a quelque chose a attraper;
  - les panneaux suivent la souris pendant le glissement, mais les WM_PAINT
    passent APRES les messages de souris. Chaque largeur intermediaire reste
    a l'ecran et les panneaux se couvrent de trainees. Repeindre de force a
    chaque pas ne laisse rien derriere, au prix d'un repeint par mouvement.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uThemedSplitter;

{$mode objfpc}{$H+}

interface

uses
  Classes, Controls, Graphics, ExtCtrls, uTheme;

const
  // Assez epais pour se voir et s'attraper a la souris sans etre une
  // bordure: c'est une poignee, pas une decoration.
  SPLITTER_THICKNESS = 7;

type
  TThemedSplitter = class(TSplitter)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure MoveSplitter(AOffset: Integer); override;
  end;

implementation

// Invalide ET repeint, en descendant: Update ne vaut que pour la fenetre a
// laquelle il s'adresse, les filles ont la leur.
procedure RepaintNow(AControl: TWinControl);
var
  i: Integer;
begin
  if (AControl = nil) or (not AControl.HandleAllocated) then Exit;
  AControl.Invalidate;
  AControl.Update;
  for i := 0 to AControl.ControlCount - 1 do
    if AControl.Controls[i] is TWinControl then
      RepaintNow(TWinControl(AControl.Controls[i]));
end;

constructor TThemedSplitter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Beveled := False;
  // PIEGE AutoSnap (vrai par defaut): sous MinSize, la LCL ne bloque pas le
  // geste, elle REPLIE le volet redimensionne a 1 px -- il semble disparu.
  // Et seulement de ce cote-la: l'autre volet est protege par le calcul du
  // maximum. Sans AutoSnap, le glissement s'arrete a MinSize, des deux cotes.
  AutoSnap := False;
  Width := SPLITTER_THICKNESS;
  Height := SPLITTER_THICKNESS;
end;

procedure TThemedSplitter.Paint;
var
  r: TRect;
  i, cx, cy: Integer;
  vertical: Boolean;
begin
  r := ClientRect;
  Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 30);
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(r);

  // Trois points au milieu: ce qui dit qu'une barre se prend a la souris.
  vertical := Align in [alLeft, alRight];
  cx := (r.Left + r.Right) div 2;
  cy := (r.Top + r.Bottom) div 2;
  Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 70);
  for i := -1 to 1 do
    if vertical then
      Canvas.FillRect(Rect(cx - 1, cy + i * 8 - 1, cx + 1, cy + i * 8 + 1))
    else
      Canvas.FillRect(Rect(cx + i * 8 - 1, cy - 1, cx + i * 8 + 1, cy + 1));
  Canvas.Brush.Style := bsClear;
end;

procedure TThemedSplitter.MoveSplitter(AOffset: Integer);
begin
  inherited MoveSplitter(AOffset);
  RepaintNow(Parent);
end;

end.
