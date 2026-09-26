{ TSplitter nu: motif systeme clair, invisible en theme sombre. Et les
  WM_PAINT passent APRES la souris: sans repeint force, trainees garanties.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uThemedSplitter;

{$mode objfpc}{$H+}

interface

uses
  Classes, Controls, Graphics, ExtCtrls, uTheme;

const
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

// En descendant: Update ne repeint que sa propre fenetre, pas les filles.
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
  // PIEGE AutoSnap: sous MinSize, la LCL replie le volet a 1 px au lieu de
  // bloquer. Sans lui, le glissement bute sur MinSize.
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
