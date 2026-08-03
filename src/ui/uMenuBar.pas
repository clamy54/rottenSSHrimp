unit uMenuBar;

{$mode objfpc}{$H+}

// Barre de menu custom Windows/Linux: titres peints aux couleurs du theme,
// une racine = un TPopupMenu owner-draw. macOS n'utilise PAS cette unite, son
// TMainMenu part au menu global natif.
//
// La barre ADOPTE le TMainMenu de uFrmMain: les enfants de chaque racine sont
// DEPLACES (pas clones, les FMiXxx du formulaire doivent rester valides) dans
// le popup correspondant.

interface

uses
  Classes, SysUtils, Controls, Graphics, Menus, LCLType, LCLProc, LMessages,
  Types, uTheme;

type
  TRSMenuBar = class(TCustomControl)
  private
    FMenus: array of TPopupMenu;
    FTitles: array of string;
    FRootClicks: array of TNotifyEvent;
    FRects: array of TRect;
    FHover: Integer;
    FOpen: Integer;
    procedure BuildLabels;
    procedure PopupOpening(Sender: TObject);
    procedure PopupClosed(Sender: TObject);
    procedure OpenAt(AIndex: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure AdoptMainMenu(AMenu: TMainMenu);
    function MenuCount: Integer;
    function MenuRoot(AIndex: Integer): TMenuItem;
    // les popups ne sont pas rattaches au Menu du formulaire: la LCL ne les
    // interroge jamais. A appeler depuis IsShortcut du form, sinon zero
    // raccourci ne marche.
    function DispatchShortcut(var AMessage: TLMKey): Boolean;
    procedure RefreshTheme;
  end;

procedure ThemePopupMenu(APopup: TPopupMenu);
// a rappeler sur les items crees dynamiquement, ils naissent sans handler
procedure ThemeMenuItems(AItem: TMenuItem);

implementation

const
  LBL_PAD = 9;
  ITEM_H  = 24;
  SEP_H   = 9;
  MENU_FONT_SIZE = 10;

type
  // TMenuItem exige des methodes d'objet: il faut bien un porteur
  TRSMenuRenderer = class
    procedure DrawItem(Sender: TObject; ACanvas: TCanvas; ARect: TRect;
      AState: TOwnerDrawState);
    procedure MeasureItem(Sender: TObject; ACanvas: TCanvas;
      var AWidth, AHeight: Integer);
  end;

var
  GRenderer: TRSMenuRenderer;

procedure SetMenuFont(AFont: TFont);
begin
  if RSUiFontName <> '' then
    AFont.Name := RSUiFontName;
  AFont.Size := MENU_FONT_SIZE;
  AFont.Quality := fqCleartype;
  AFont.Style := [];
end;

function StripAmp(const S: string): string;
begin
  Result := StringReplace(S, '&', '', [rfReplaceAll]);
end;

procedure ThemeMenuItems(AItem: TMenuItem);
var
  i: Integer;
begin
  if AItem = nil then Exit;
  AItem.OnDrawItem := @GRenderer.DrawItem;
  AItem.OnMeasureItem := @GRenderer.MeasureItem;
  for i := 0 to AItem.Count - 1 do
    ThemeMenuItems(AItem.Items[i]);
end;

procedure ThemePopupMenu(APopup: TPopupMenu);
var
  i: Integer;
begin
  if APopup = nil then Exit;
  APopup.OwnerDraw := True;
  for i := 0 to APopup.Items.Count - 1 do
    ThemeMenuItems(APopup.Items[i]);
end;

{ TRSMenuRenderer }

procedure TRSMenuRenderer.MeasureItem(Sender: TObject; ACanvas: TCanvas;
  var AWidth, AHeight: Integer);
var
  mi: TMenuItem;
  scw: Integer;
begin
  mi := TMenuItem(Sender);
  SetMenuFont(ACanvas.Font);
  if mi.Caption = '-' then
  begin
    AHeight := SEP_H;
    Exit;
  end;
  scw := 0;
  if mi.ShortCut <> 0 then
    scw := ACanvas.TextWidth(ShortCutToText(mi.ShortCut)) + 24;
  AWidth := 28 + ACanvas.TextWidth(StripAmp(mi.Caption)) + 30 + scw + 16;
  AHeight := ITEM_H;
end;

procedure TRSMenuRenderer.DrawItem(Sender: TObject; ACanvas: TCanvas;
  ARect: TRect; AState: TOwnerDrawState);
var
  mi: TMenuItem;
  ty: Integer;
  sc: string;
begin
  mi := TMenuItem(Sender);
  SetMenuFont(ACanvas.Font);

  if mi.Caption = '-' then
  begin
    ACanvas.Brush.Color := clMenuPopupBg;
    ACanvas.FillRect(ARect);
    ACanvas.Pen.Color := clMenuSep;
    ACanvas.Line(ARect.Left + 8, (ARect.Top + ARect.Bottom) div 2,
      ARect.Right - 8, (ARect.Top + ARect.Bottom) div 2);
    Exit;
  end;

  if odSelected in AState then
    ACanvas.Brush.Color := clMenuHover
  else
    ACanvas.Brush.Color := clMenuPopupBg;
  ACanvas.FillRect(ARect);

  ty := ARect.Top + (ARect.Bottom - ARect.Top - ACanvas.TextHeight('Ag')) div 2;
  ACanvas.Brush.Style := bsClear;
  if not mi.Enabled then
    ACanvas.Font.Color := clMenuDisabled
  else
    ACanvas.Font.Color := clMenuText;

  if mi.Checked then
  begin
    if mi.RadioItem then
      ACanvas.TextOut(ARect.Left + 10, ty, #$E2#$80#$A2)   // puce (radio)
    else
      ACanvas.TextOut(ARect.Left + 10, ty, #$E2#$9C#$93);  // coche
  end;
  ACanvas.TextOut(ARect.Left + 28, ty, StripAmp(mi.Caption));

  if mi.ShortCut <> 0 then
  begin
    sc := ShortCutToText(mi.ShortCut);
    ACanvas.Font.Color := clMenuDisabled;
    ACanvas.TextOut(ARect.Right - ACanvas.TextWidth(sc) - 16, ty, sc);
  end;
  ACanvas.Brush.Style := bsSolid;
end;

{ TRSMenuBar }

constructor TRSMenuBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHover := -1;
  FOpen := -1;
  SetMenuFont(Font);
end;

procedure TRSMenuBar.AdoptMainMenu(AMenu: TMainMenu);
var
  i: Integer;
  root, child: TMenuItem;
  pm: TPopupMenu;
begin
  SetLength(FMenus, AMenu.Items.Count);
  SetLength(FTitles, AMenu.Items.Count);
  SetLength(FRootClicks, AMenu.Items.Count);
  for i := 0 to AMenu.Items.Count - 1 do
  begin
    root := AMenu.Items[i];
    pm := TPopupMenu.Create(Self);
    pm.OwnerDraw := True;
    pm.OnPopup := @PopupOpening;
    pm.OnClose := @PopupClosed;
    FMenus[i] := pm;
    FTitles[i] := StripAmp(root.Caption);
    FRootClicks[i] := root.OnClick;
    while root.Count > 0 do
    begin
      child := root.Items[0];
      root.Delete(0);
      pm.Items.Add(child);
    end;
    ThemeMenuItems(pm.Items);
  end;
  Invalidate;
end;

function TRSMenuBar.MenuCount: Integer;
begin
  Result := Length(FMenus);
end;

function TRSMenuBar.MenuRoot(AIndex: Integer): TMenuItem;
begin
  Result := FMenus[AIndex].Items;
end;

function TRSMenuBar.DispatchShortcut(var AMessage: TLMKey): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(FMenus) do
    if FMenus[i].IsShortcut(AMessage) then
      Exit(True);
end;

procedure TRSMenuBar.RefreshTheme;
begin
  SetMenuFont(Font);
  Invalidate;
end;

procedure TRSMenuBar.BuildLabels;
var
  i, x, w: Integer;
begin
  Canvas.Font := Font;
  SetLength(FRects, Length(FTitles));
  x := 6;
  for i := 0 to High(FTitles) do
  begin
    w := Canvas.TextWidth(FTitles[i]) + LBL_PAD * 2;
    FRects[i] := Rect(x, 0, x + w, ClientHeight);
    Inc(x, w);
  end;
end;

procedure TRSMenuBar.Paint;
var
  i, ty: Integer;
begin
  BuildLabels;
  Canvas.Brush.Color := clMenuBg;
  Canvas.FillRect(ClientRect);
  Canvas.Brush.Style := bsClear;
  ty := (ClientHeight - Canvas.TextHeight('Ag')) div 2;
  for i := 0 to High(FTitles) do
  begin
    if (i = FHover) or (i = FOpen) then
    begin
      Canvas.Brush.Style := bsSolid;
      Canvas.Brush.Color := clMenuHover;
      Canvas.FillRect(FRects[i]);
      Canvas.Brush.Style := bsClear;
    end;
    Canvas.Font.Color := clMenuText;
    Canvas.TextOut(FRects[i].Left + LBL_PAD, ty, FTitles[i]);
  end;
  Canvas.Brush.Style := bsSolid;
end;

procedure TRSMenuBar.OpenAt(AIndex: Integer);
var
  p: TPoint;
begin
  if (AIndex < 0) or (AIndex > High(FMenus)) then Exit;
  FOpen := AIndex;
  Invalidate;
  p := ClientToScreen(Point(FRects[AIndex].Left, ClientHeight));
  FMenus[AIndex].PopUp(p.X, p.Y);
end;

procedure TRSMenuBar.PopupOpening(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FMenus) do
    if FMenus[i] = Sender then
    begin
      // rejouer le OnClick de la racine d'origine (Favorites/Recent se
      // reconstruisent la), PUIS habiller ce qu'il vient de creer
      if Assigned(FRootClicks[i]) then
        FRootClicks[i](Sender);
      ThemeMenuItems(FMenus[i].Items);
      Exit;
    end;
end;

procedure TRSMenuBar.PopupClosed(Sender: TObject);
begin
  FOpen := -1;
  Invalidate;
end;

procedure TRSMenuBar.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  for i := 0 to High(FRects) do
    if (X >= FRects[i].Left) and (X < FRects[i].Right) then
    begin
      OpenAt(i);
      Exit;
    end;
end;

procedure TRSMenuBar.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i, old: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  old := FHover;
  FHover := -1;
  for i := 0 to High(FRects) do
    if (X >= FRects[i].Left) and (X < FRects[i].Right) then
    begin
      FHover := i;
      Break;
    end;
  if old <> FHover then Invalidate;
end;

procedure TRSMenuBar.MouseLeave;
begin
  inherited MouseLeave;
  if FHover <> -1 then
  begin
    FHover := -1;
    Invalidate;
  end;
end;

initialization
  GRenderer := TRSMenuRenderer.Create;

finalization
  GRenderer.Free;

end.
