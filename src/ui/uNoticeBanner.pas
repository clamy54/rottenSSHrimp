{ Bandeau d'avis en tete d'un onglet: un titre, des lignes, une croix pour le
  fermer. NON modal par principe: une boite de dialogue ouverte depuis un
  evenement du reseau gele le thread de session sur son Synchronize suivant,
  et au bout de quelques minutes le keepalive declare morte une session bien
  vivante. Le bandeau, lui, attend qu'on le lise sans rien bloquer.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uNoticeBanner;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, Graphics, uTheme;

type
  TNoticeBanner = class(TCustomControl)
  private
    FTitle: string;
    FLines: TStringList;
    FCloseHot: Boolean;
    function CloseRect: TRect;
    function LineHeight: Integer;
    function TextWidthAvail: Integer;
    function Wrap(const S: string): TStringArray;
    function VisualLineCount: Integer;
    procedure Relayout;
  protected
    procedure Paint; override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseLeave; override;
    procedure Resize; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Montre le bandeau s'il etait cache. Une ligne deja presente n'est pas
    // repetee: le meme echec signale deux fois reste une seule ligne.
    procedure AddLine(const ATitle, ALine: string);
    procedure Dismiss;
  end;

implementation

const
  PAD_X = 12;
  PAD_Y = 7;
  STRIPE_W = 4;
  CLOSE_W = 28;
  MAX_LINES = 20;

constructor TNoticeBanner.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLines := TStringList.Create;
  DoubleBuffered := True;
  Visible := False;
  Height := 0;
  ApplyUiFont(Self);
end;

destructor TNoticeBanner.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

// Mesure hors ecran: appelee avant que le controle ait un handle, son propre
// canevas n'aurait pas encore de quoi mesurer.
function TNoticeBanner.LineHeight: Integer;
begin
  Result := UiTextHeight('Ag') + 3;
end;

const
  BULLET_W = 24;

function TNoticeBanner.TextWidthAvail: Integer;
begin
  Result := ClientWidth - (STRIPE_W + PAD_X + BULLET_W) - CLOSE_W - 8;
  if Result < 80 then
    Result := 80;
end;

// Coupe aux espaces pour tenir dans la largeur: un message de tunnel porte
// un hote et une raison, il depasse souvent une ligne d'onglet etroit.
function TNoticeBanner.Wrap(const S: string): TStringArray;
var
  words: TStringArray;
  cur, cand: string;
  i, w: Integer;
begin
  Result := nil;
  w := TextWidthAvail;
  words := S.Split([' ']);
  cur := '';
  for i := 0 to High(words) do
  begin
    if cur = '' then cand := words[i] else cand := cur + ' ' + words[i];
    if (cur <> '') and (UiTextWidth(cand) > w) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := cur;
      cur := words[i];
    end
    else
      cur := cand;
  end;
  if cur <> '' then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := cur;
  end;
end;

function TNoticeBanner.VisualLineCount: Integer;
var
  i: Integer;
begin
  Result := 1;   // titre
  for i := 0 to FLines.Count - 1 do
    Inc(Result, Length(Wrap(FLines[i])));
end;

procedure TNoticeBanner.Relayout;
var
  h: Integer;
begin
  if not Visible then Exit;
  h := PAD_Y * 2 + LineHeight * VisualLineCount;
  if Height <> h then
    Height := h;
  Invalidate;
end;

procedure TNoticeBanner.AddLine(const ATitle, ALine: string);
begin
  FTitle := ATitle;
  if (ALine <> '') and (FLines.IndexOf(ALine) < 0) and
     (FLines.Count < MAX_LINES) then
    FLines.Add(ALine);
  Visible := True;
  Relayout;
end;

procedure TNoticeBanner.Dismiss;
begin
  FLines.Clear;
  FTitle := '';
  Visible := False;
end;

function TNoticeBanner.CloseRect: TRect;
begin
  Result := Rect(ClientWidth - CLOSE_W - 4, PAD_Y - 2,
    ClientWidth - 4, PAD_Y - 2 + CLOSE_W - 6);
end;

// La largeur change le nombre de lignes, donc la hauteur. Relayout ne
// retouche Height que si elle differe: pas de boucle de redimensionnement.
procedure TNoticeBanner.Resize;
begin
  inherited Resize;
  Relayout;
end;

procedure TNoticeBanner.Paint;
var
  r, cr: TRect;
  y, lh, i, j, cx, cy: Integer;
  parts: TStringArray;
begin
  r := ClientRect;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := BlendColor(clScpWarn, clAppBg, 16);
  Canvas.FillRect(r);
  Canvas.Brush.Color := clScpWarn;
  Canvas.FillRect(Rect(0, 0, STRIPE_W, r.Bottom));
  // filet bas: separe du terminal quand les deux fonds se ressemblent
  Canvas.Brush.Color := BlendColor(clScpWarn, clAppBg, 40);
  Canvas.FillRect(Rect(0, r.Bottom - 1, r.Right, r.Bottom));

  Canvas.Font := Font;
  Canvas.Brush.Style := bsClear;
  lh := LineHeight;
  y := PAD_Y;
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Color := clAppFg;
  Canvas.TextRect(Rect(STRIPE_W + PAD_X, y, r.Right - CLOSE_W - 8, y + lh),
    STRIPE_W + PAD_X, y, FTitle);
  Inc(y, lh);
  Canvas.Font.Style := [];
  for i := 0 to FLines.Count - 1 do
  begin
    Canvas.TextOut(STRIPE_W + PAD_X + 10, y, '•');
    parts := Wrap(FLines[i]);
    for j := 0 to High(parts) do
    begin
      Canvas.TextRect(Rect(STRIPE_W + PAD_X + BULLET_W, y,
        r.Right - CLOSE_W - 8, y + lh), STRIPE_W + PAD_X + BULLET_W, y,
        parts[j]);
      Inc(y, lh);
    end;
  end;

  cr := CloseRect;
  cx := (cr.Left + cr.Right) div 2;
  cy := (cr.Top + cr.Bottom) div 2;
  if FCloseHot then
  begin
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := BlendColor(clAppFg, clAppBg, 14);
    Canvas.Pen.Style := psClear;
    Canvas.Ellipse(cx - 10, cy - 10, cx + 10, cy + 10);
  end;
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Width := 2;
  Canvas.Pen.Color := clAppFg;
  Canvas.Line(cx - 4, cy - 4, cx + 5, cy + 5);
  Canvas.Line(cx - 4, cy + 4, cx + 5, cy - 5);
  Canvas.Pen.Width := 1;
  Canvas.Brush.Style := bsSolid;
end;

procedure TNoticeBanner.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  hot: Boolean;
begin
  inherited MouseMove(Shift, X, Y);
  hot := PtInRect(CloseRect, Point(X, Y));
  if hot <> FCloseHot then
  begin
    FCloseHot := hot;
    if hot then Cursor := crHandPoint else Cursor := crDefault;
    Invalidate;
  end;
end;

procedure TNoticeBanner.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and PtInRect(CloseRect, Point(X, Y)) then
    Dismiss;
end;

procedure TNoticeBanner.MouseLeave;
begin
  inherited MouseLeave;
  if FCloseHot then
  begin
    FCloseHot := False;
    Cursor := crDefault;
    Invalidate;
  end;
end;

end.
