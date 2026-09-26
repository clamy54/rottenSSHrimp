{ PNG embarques = MASQUES: l'encre porte un sens (lien, special, selection).
  Composition logicielle sur le fond reel; l'alpha des bitmaps, chaque
  widgetset l'interprete a sa facon.
  Traces a la main: grille Tabler de 24, trait de 2.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpIcons;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Types, Graphics;

type
  TScpIcon = (
    siNone,
    siFolder,
    siFolderOpen,
    siFile,
    siLink,
    siLinkBroken,
    siSpecial,       // socket, tube, peripherique
    siDrive,
    siNetworkDrive,
    siHome,
    siParent,
    siBack,
    siForward,
    siRefresh,
    siNewFolder,
    siRename,
    siDelete,
    siUpload,
    siDownload,
    siPause,
    siPlay,
    siCancel,
    siCheck,
    siWarning,
    siError,
    siCopy,
    siServer,
    siSettings,
    siReveal,
    siSortAsc,
    siSortDesc);

// ABg = ce que l'appelant vient de peindre SOUS ARect: un fond faux se voit
// en lisere autour du trait.
procedure DrawScpIcon(ACanvas: TCanvas; const ARect: TRect;
  AIcon: TScpIcon; AColor, ABg: TColor);

implementation

uses
  LCLType, IntfGraphics, FPImage;

{$I uScpIconCatalog.inc}

type
  TPt = record
    X, Y: Double;
  end;

function P(AX, AY: Double): TPt; inline;
begin
  Result.X := AX;
  Result.Y := AY;
end;

type
  TIconPen = record
    Canvas: TCanvas;
    OX, OY: Double;
    S: Double;         // echelle
    W: Integer;        // trait, pixels entiers
  end;

function MapX(const A: TIconPen; AX: Double): Integer; inline;
begin
  Result := Round(A.OX + AX * A.S);
end;

function MapY(const A: TIconPen; AY: Double): Integer; inline;
begin
  Result := Round(A.OY + AY * A.S);
end;

procedure Line(const A: TIconPen; AX1, AY1, AX2, AY2: Double);
begin
  A.Canvas.Line(MapX(A, AX1), MapY(A, AY1), MapX(A, AX2), MapY(A, AY2));
end;

procedure Poly(const A: TIconPen; const APts: array of TPt; AClose: Boolean);
var
  pts: array of TPoint;
  i, n: Integer;
begin
  n := Length(APts);
  if n < 2 then Exit;
  if AClose then SetLength(pts, n + 1) else SetLength(pts, n);
  for i := 0 to n - 1 do
  begin
    pts[i].X := MapX(A, APts[i].X);
    pts[i].Y := MapY(A, APts[i].Y);
  end;
  if AClose then pts[n] := pts[0];
  A.Canvas.Polyline(pts);
end;

procedure Box(const A: TIconPen; AX1, AY1, AX2, AY2: Double);
begin
  A.Canvas.Frame(MapX(A, AX1), MapY(A, AY1), MapX(A, AX2), MapY(A, AY2));
end;

procedure Disc(const A: TIconPen; ACX, ACY, AR: Double);
var
  old: TColor;
begin
  old := A.Canvas.Brush.Color;
  A.Canvas.Brush.Color := A.Canvas.Pen.Color;
  A.Canvas.Brush.Style := bsSolid;
  A.Canvas.Ellipse(MapX(A, ACX - AR), MapY(A, ACY - AR),
    MapX(A, ACX + AR), MapY(A, ACY + AR));
  A.Canvas.Brush.Color := old;
  A.Canvas.Brush.Style := bsClear;
end;

procedure Ring(const A: TIconPen; ACX, ACY, AR: Double);
begin
  A.Canvas.Brush.Style := bsClear;
  A.Canvas.Ellipse(MapX(A, ACX - AR), MapY(A, ACY - AR),
    MapX(A, ACX + AR), MapY(A, ACY + AR));
end;

procedure FillPoly(const A: TIconPen; const APts: array of TPt);
var
  pts: array of TPoint;
  i: Integer;
  oldStyle: TBrushStyle;
  oldColor: TColor;
begin
  SetLength(pts, Length(APts));
  for i := 0 to High(APts) do
  begin
    pts[i].X := MapX(A, APts[i].X);
    pts[i].Y := MapY(A, APts[i].Y);
  end;
  oldStyle := A.Canvas.Brush.Style;
  oldColor := A.Canvas.Brush.Color;
  A.Canvas.Brush.Style := bsSolid;
  A.Canvas.Brush.Color := A.Canvas.Pen.Color;
  A.Canvas.Polygon(pts);
  A.Canvas.Brush.Style := oldStyle;
  A.Canvas.Brush.Color := oldColor;
end;

procedure DrawGlyph(const A: TIconPen; AIcon: TScpIcon);
begin
  case AIcon of
    siFolder:
      begin
        Poly(A, [P(3, 19), P(3, 6), P(9, 6), P(11, 8.5), P(21, 8.5),
          P(21, 19)], True);
        Line(A, 3, 8.5, 9, 8.5);
      end;
    siFolderOpen:
      begin
        Poly(A, [P(3, 19), P(3, 6), P(9, 6), P(11, 8.5), P(19, 8.5),
          P(19, 11)], False);
        Poly(A, [P(3, 19), P(6, 11), P(22, 11), P(19, 19)], True);
      end;
    siFile:
      begin
        Poly(A, [P(6, 3), P(14, 3), P(19, 8), P(19, 21), P(6, 21)], True);
        Poly(A, [P(14, 3), P(14, 8), P(19, 8)], False);
      end;
    siLink:
      begin
        Poly(A, [P(10, 14), P(7, 17), P(5, 15), P(9, 11), P(12, 8)], False);
        Poly(A, [P(14, 10), P(17, 7), P(19, 9), P(15, 13), P(12, 16)], False);
        Line(A, 10, 14, 14, 10);
      end;
    siLinkBroken:
      begin
        Poly(A, [P(10, 14), P(7, 17), P(5, 15), P(9, 11)], False);
        Poly(A, [P(15, 9), P(17, 7), P(19, 9), P(15, 13)], False);
        // Le trou au milieu EST le message.
        Line(A, 10, 13, 11.5, 11.5);
        Line(A, 13.5, 11.5, 15, 10);
      end;
    siSpecial:
      begin
        Poly(A, [P(12, 4), P(20, 12), P(12, 20), P(4, 12)], True);
        Line(A, 12, 9, 12, 13);
        Disc(A, 12, 16, 0.9);
      end;
    siDrive:
      begin
        Box(A, 3, 7, 21, 17);
        Line(A, 3, 12, 21, 12);
        Disc(A, 17.5, 14.5, 1);
      end;
    siNetworkDrive:
      begin
        Box(A, 3, 5, 21, 11);
        Disc(A, 17.5, 8, 0.9);
        Line(A, 12, 11, 12, 14);
        Poly(A, [P(6, 20), P(6, 14), P(18, 14), P(18, 20)], False);
        Line(A, 6, 20, 18, 20);
      end;
    siHome:
      begin
        Poly(A, [P(4, 11), P(12, 4), P(20, 11)], False);
        Poly(A, [P(6, 10), P(6, 20), P(18, 20), P(18, 10)], False);
        Box(A, 10, 14, 14, 20);
      end;
    siParent:
      begin
        Line(A, 12, 20, 12, 6);
        FillPoly(A, [P(12, 3.5), P(18, 10), P(6, 10)]);
      end;
    siBack:
      begin
        Line(A, 20, 12, 8, 12);
        FillPoly(A, [P(4.5, 12), P(11, 6), P(11, 18)]);
      end;
    siForward:
      begin
        Line(A, 4, 12, 16, 12);
        FillPoly(A, [P(19.5, 12), P(13, 6), P(13, 18)]);
      end;
    siRefresh:
      begin
        Poly(A, [P(19, 8), P(19, 4)], False);
        Poly(A, [P(19.5, 9.5), P(17.5, 6.8), P(14.3, 5.2), P(11, 5),
          P(7.8, 6), P(5.4, 8.3), P(4.3, 11.4), P(4.7, 14.7),
          P(6.5, 17.5), P(9.3, 19.2), P(12.6, 19.5), P(15.7, 18.4),
          P(18, 16.2)], False);
        FillPoly(A, [P(20, 10.5), P(15.5, 8), P(20.5, 6)]);
      end;
    siNewFolder:
      begin
        Poly(A, [P(3, 19), P(3, 6), P(9, 6), P(11, 8.5), P(21, 8.5),
          P(21, 12)], False);
        Line(A, 3, 19, 13, 19);
        Line(A, 17, 13, 17, 21);
        Line(A, 13, 17, 21, 17);
      end;
    siRename:
      begin
        Poly(A, [P(5, 16), P(15, 6), P(18, 9), P(8, 19), P(4, 20)], True);
        Line(A, 13, 8, 16, 11);
        Line(A, 4, 20, 5, 16);
      end;
    siDelete:
      begin
        Line(A, 4, 7, 20, 7);
        Poly(A, [P(6, 7), P(7, 20), P(17, 20), P(18, 7)], False);
        Poly(A, [P(9, 7), P(9, 4), P(15, 4), P(15, 7)], False);
        Line(A, 10, 11, 10, 17);
        Line(A, 14, 11, 14, 17);
      end;
    siUpload:
      begin
        // Butee: sinon identique a la fleche de navigation de la meme barre.
        Line(A, 20, 5, 20, 19);
        Line(A, 3, 12, 12, 12);
        FillPoly(A, [P(17, 12), P(11, 7), P(11, 17)]);
      end;
    siDownload:
      begin
        Line(A, 4, 5, 4, 19);
        Line(A, 21, 12, 12, 12);
        FillPoly(A, [P(7, 12), P(13, 7), P(13, 17)]);
      end;
    siPause:
      begin
        Line(A, 9, 5, 9, 19);
        Line(A, 15, 5, 15, 19);
      end;
    siPlay:
      FillPoly(A, [P(7, 4.5), P(19, 12), P(7, 19.5)]);
    siCancel:
      begin
        Line(A, 6, 6, 18, 18);
        Line(A, 18, 6, 6, 18);
      end;
    siCheck:
      Poly(A, [P(5, 12.5), P(10, 17.5), P(19, 7)], False);
    siWarning:
      begin
        Poly(A, [P(12, 4), P(21, 19.5), P(3, 19.5)], True);
        Line(A, 12, 10, 12, 14.5);
        Disc(A, 12, 17, 0.9);
      end;
    siError:
      begin
        Ring(A, 12, 12, 8.5);
        Line(A, 8.5, 8.5, 15.5, 15.5);
        Line(A, 15.5, 8.5, 8.5, 15.5);
      end;
    siCopy:
      begin
        Box(A, 8, 3, 21, 16);
        Poly(A, [P(16, 16), P(16, 21), P(3, 21), P(3, 8), P(8, 8)], False);
      end;
    siServer:
      begin
        Box(A, 3, 4, 21, 10);
        Box(A, 3, 14, 21, 20);
        Disc(A, 17.5, 7, 0.9);
        Disc(A, 17.5, 17, 0.9);
        Line(A, 6, 7, 11, 7);
        Line(A, 6, 17, 11, 17);
      end;
    siSettings:
      begin
        Ring(A, 12, 12, 3.2);
        Line(A, 12, 3, 12, 6);
        Line(A, 12, 18, 12, 21);
        Line(A, 3, 12, 6, 12);
        Line(A, 18, 12, 21, 12);
        Line(A, 5.6, 5.6, 7.8, 7.8);
        Line(A, 16.2, 16.2, 18.4, 18.4);
        Line(A, 18.4, 5.6, 16.2, 7.8);
        Line(A, 7.8, 16.2, 5.6, 18.4);
      end;
    siReveal:
      begin
        Poly(A, [P(13, 4), P(4, 4), P(4, 20), P(20, 20), P(20, 11)], False);
        Line(A, 11, 13, 20, 4);
        Poly(A, [P(14, 4), P(20, 4), P(20, 10)], False);
      end;
    siSortAsc:
      begin
        Line(A, 12, 20, 12, 6);
        Poly(A, [P(7, 11), P(12, 6), P(17, 11)], False);
      end;
    siSortDesc:
      begin
        Line(A, 12, 4, 12, 18);
        Poly(A, [P(7, 13), P(12, 18), P(17, 13)], False);
      end;
  end;
end;

type
  TIconCacheItem = class
    Bmp: TBitmap;      // nil = ressource absente, constate une fois
    destructor Destroy; override;
  end;

var
  GCache: TStringList = nil;

destructor TIconCacheItem.Destroy;
begin
  Bmp.Free;
  inherited Destroy;
end;

// '' = icone tracee
function XferIdFor(AIcon: TScpIcon): string;
begin
  case AIcon of
    siFolder:     Result := 'folder';
    siFolderOpen: Result := 'folder-open';
    siFile:       Result := 'file';
    siLink:       Result := 'link';
    siHome:       Result := 'home-2';
    siParent:     Result := 'folder-up';
    siBack:       Result := 'arrow-narrow-left';
    siForward:    Result := 'arrow-narrow-right';
    siRefresh:    Result := 'refresh';
    siNewFolder:  Result := 'folder-plus';
    siCopy:       Result := 'fullpath';
    siUpload:     Result := 'upload';
    siDownload:   Result := 'download';
    siSortAsc:    Result := 'arrow-narrow-up';
    siSortDesc:   Result := 'arrow-narrow-down';
    siLinkBroken: Result := 'link-off';
    siSpecial:    Result := 'file-special';
    siCheck:      Result := 'check';
    siWarning:    Result := 'alert-circle';
    siPause:      Result := 'player-pause';
    siPlay:       Result := 'player-play';
    // L'echec garde sa croix CERCLEE: meme colonne, pas seulement la couleur.
    siCancel:     Result := 'x';
  else
    Result := '';
  end;
end;

// La plus grande qui TIENT, pas la plus proche: elle deborderait sur le texte.
function PickXferSize(ABox: Integer): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := Low(XFER_ICON_SIZES) to High(XFER_ICON_SIZES) do
    if XFER_ICON_SIZES[i] <= ABox then
      Result := XFER_ICON_SIZES[i];
end;

function MixChannel(AInk, ABg: Word; ACoverage: Word): Word; inline;
begin
  Result := Word((QWord(AInk) * ACoverage +
    QWord(ABg) * (65535 - ACoverage)) div 65535);
end;

// nil = ressource absente, l'appelant retombe sur le trace.
function BuildXferIcon(const AId: string; ASize: Integer;
  AInk, ABg: TColor): TBitmap;
var
  res: TResourceStream;
  png: TPortableNetworkGraphic;
  img: TLazIntfImage;
  x, y: Integer;
  c, ink, bg: TFPColor;
  cov: Word;
begin
  Result := nil;
  try
    res := TResourceStream.Create(HInstance,
      'XFER_' + UpperCase(StringReplace(AId, '-', '_', [rfReplaceAll])) +
      '_' + IntToStr(ASize), RT_RCDATA);
  except
    Exit;
  end;
  png := TPortableNetworkGraphic.Create;
  try
    try
      png.LoadFromStream(res);
    finally
      res.Free;
    end;
    ink := TColorToFPColor(ColorToRGB(AInk));
    bg := TColorToFPColor(ColorToRGB(ABg));
    img := png.CreateIntfImage;
    try
      for y := 0 to img.Height - 1 do
        for x := 0 to img.Width - 1 do
        begin
          // Seul l'alpha compte: le blanc de la source ne fait que le porter.
          cov := img.Colors[x, y].Alpha;
          c.Red := MixChannel(ink.Red, bg.Red, cov);
          c.Green := MixChannel(ink.Green, bg.Green, cov);
          c.Blue := MixChannel(ink.Blue, bg.Blue, cov);
          c.Alpha := alphaOpaque;
          img.Colors[x, y] := c;
        end;
      Result := TBitmap.Create;
      try
        Result.LoadFromIntfImage(img);
      except
        FreeAndNil(Result);
      end;
    finally
      img.Free;
    end;
  finally
    png.Free;
  end;
end;

function CachedXferIcon(const AId: string; ASize: Integer;
  AInk, ABg: TColor): TBitmap;
var
  key: string;
  idx: Integer;
  item: TIconCacheItem;
begin
  key := Format('%s|%d|%.8x|%.8x', [AId, ASize, ColorToRGB(AInk),
    ColorToRGB(ABg)]);
  if GCache = nil then
  begin
    GCache := TStringList.Create;
    GCache.Sorted := True;
    GCache.Duplicates := dupIgnore;
    GCache.OwnsObjects := True;
  end;
  idx := GCache.IndexOf(key);
  if idx >= 0 then
    Exit(TIconCacheItem(GCache.Objects[idx]).Bmp);
  // Chaque changement de theme laisse ses entrees orphelines.
  if GCache.Count > 512 then
    GCache.Clear;
  item := TIconCacheItem.Create;
  item.Bmp := BuildXferIcon(AId, ASize, AInk, ABg);
  GCache.AddObject(key, item);
  Result := item.Bmp;
end;

procedure DrawScpIcon(ACanvas: TCanvas; const ARect: TRect;
  AIcon: TScpIcon; AColor, ABg: TColor);
var
  pen: TIconPen;
  side, sz: Integer;
  id: string;
  bmp: TBitmap;
  oldPenColor, oldBrushColor: TColor;
  oldPenWidth: Integer;
  oldBrushStyle: TBrushStyle;
  oldPenStyle: TPenStyle;
begin
  if AIcon = siNone then Exit;
  side := ARect.Right - ARect.Left;
  if (ARect.Bottom - ARect.Top) < side then side := ARect.Bottom - ARect.Top;
  if side < 6 then Exit;

  id := XferIdFor(AIcon);
  if id <> '' then
  begin
    sz := PickXferSize(side);
    if sz > 0 then
    begin
      bmp := CachedXferIcon(id, sz, AColor, ABg);
      if bmp <> nil then
      begin
        ACanvas.Draw(ARect.Left + ((ARect.Right - ARect.Left) - sz) div 2,
          ARect.Top + ((ARect.Bottom - ARect.Top) - sz) div 2, bmp);
        Exit;
      end;
    end;
    // le trace vaut mieux qu'un trou
  end;

  oldPenColor := ACanvas.Pen.Color;
  oldPenWidth := ACanvas.Pen.Width;
  oldPenStyle := ACanvas.Pen.Style;
  oldBrushColor := ACanvas.Brush.Color;
  oldBrushStyle := ACanvas.Brush.Style;
  try
    pen.Canvas := ACanvas;
    pen.S := side / 24;
    pen.OX := ARect.Left + ((ARect.Right - ARect.Left) - side) / 2;
    pen.OY := ARect.Top + ((ARect.Bottom - ARect.Top) - side) / 2;
    // ENTIERE: un trait fractionnaire est flou.
    pen.W := Round(side / 16);
    if pen.W < 1 then pen.W := 1;
    if pen.W > 3 then pen.W := 3;

    ACanvas.Pen.Color := AColor;
    ACanvas.Pen.Width := pen.W;
    ACanvas.Pen.Style := psSolid;
    ACanvas.Brush.Style := bsClear;
    DrawGlyph(pen, AIcon);
  finally
    ACanvas.Pen.Color := oldPenColor;
    ACanvas.Pen.Width := oldPenWidth;
    ACanvas.Pen.Style := oldPenStyle;
    ACanvas.Brush.Color := oldBrushColor;
    ACanvas.Brush.Style := oldBrushStyle;
  end;
end;

finalization
  FreeAndNil(GCache);

end.
