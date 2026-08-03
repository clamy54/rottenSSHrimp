unit uTheme;

{$mode objfpc}{$H+}

// Polices et couleurs en globales, remplacables a chaud (uThemeLoad les
// ecrit). Chaque control les relit a son dessin: appliquer un theme = ecrire
// les globales puis repeindre.

interface

uses
  Graphics, Controls;

var
  // '' / 0 = defauts du widgetset (Monaspace absente, taille systeme)
  RSUiFontName: string = '';
  RSUiFontSize: Integer = 0;
  RSTerminalFontName: string = '';
  RSTerminalFontSize: Integer = 12;

  clAppBg: TColor;
  clAppFg: TColor;
  clAccent: TColor;
  clBorder: TColor;

  clSideBg: TColor;
  clSideText: TColor;
  clSideTextHi: TColor;
  clSideSel: TColor;
  clSideHover: TColor;
  clSideActive: TColor;   // host avec au moins une session ouverte

  clStatusBg: TColor;
  clStatusText: TColor;

  // barre custom Windows/Linux seulement: macOS garde le menu global natif et
  // ignore ces couleurs
  clMenuBg: TColor;
  clMenuText: TColor;
  clMenuHover: TColor;
  clMenuPopupBg: TColor;
  clMenuDisabled: TColor;
  clMenuSep: TColor;

  clTabStrip: TColor;
  clTabActive: TColor;
  clTabInactive: TColor;
  clTabHover: TColor;
  clTabActiveText: TColor;
  clTabInactiveText: TColor;
  clTabIcon: TColor;
  clTabIconHi: TColor;
  clTabDead: TColor;       // flux log rompu, onglet garde ouvert

  clTermBg: TColor;
  clTermFg: TColor;

// a appeler apres LoadEmbeddedFonts, avant la creation des fenetres
procedure ApplyDefaultFonts;

// recursif sur les enfants; les composants natifs (menu global macOS,
// dialogues systeme) n'y passent pas
procedure ApplyUiFont(AControl: TControl);

// RGB 0xRRGGBB (comme dans les themes) -> TColor (0xBBGGRR)
function RgbHexToColor(ARgb: Cardinal): TColor;

// APct % de A, le reste de B
function BlendColor(A, B: TColor; APct: Integer): TColor;

implementation

uses
  uFontEmbed;

function BlendColor(A, B: TColor; APct: Integer): TColor;
var
  ca, cb: LongInt;
  r, g, bl: Integer;
begin
  ca := ColorToRGB(A);
  cb := ColorToRGB(B);
  r  := ((ca and $FF) * APct + (cb and $FF) * (100 - APct)) div 100;
  g  := (((ca shr 8) and $FF) * APct + ((cb shr 8) and $FF) * (100 - APct)) div 100;
  bl := (((ca shr 16) and $FF) * APct + ((cb shr 16) and $FF) * (100 - APct)) div 100;
  Result := TColor(r or (g shl 8) or (bl shl 16));
end;

function RgbHexToColor(ARgb: Cardinal): TColor;
begin
  Result := RGBToColor((ARgb shr 16) and $FF, (ARgb shr 8) and $FF, ARgb and $FF);
end;

procedure ApplyDefaultFonts;
begin
  if MonaspaceAvailable then
  begin
    RSUiFontName := MonaspaceDefaultFamily;
    RSTerminalFontName := MonaspaceTerminalDefaultFamily;
  end
  else
  begin
    RSUiFontName := '';
    RSTerminalFontName := '';
  end;
end;

procedure ApplyUiFont(AControl: TControl);
var
  i: Integer;
  wc: TWinControl;
begin
  if AControl = nil then Exit;
  if RSUiFontName <> '' then
    AControl.Font.Name := RSUiFontName;
  if RSUiFontSize > 0 then
    AControl.Font.Size := RSUiFontSize;
  if AControl is TWinControl then
  begin
    wc := TWinControl(AControl);
    for i := 0 to wc.ControlCount - 1 do
      ApplyUiFont(wc.Controls[i]);
  end;
end;

initialization
  // defauts compiles = theme "rotten" (voir aussi themes/rotten.json)
  clAppBg          := RgbHexToColor($1E1E1E);
  clAppFg          := RgbHexToColor($D4D4D4);
  clAccent         := RgbHexToColor($FB9E6B);
  clBorder         := RgbHexToColor($161616);
  clSideBg         := RgbHexToColor($252526);
  clSideText       := RgbHexToColor($CCCCCC);
  clSideTextHi     := RgbHexToColor($FFFFFF);
  clSideSel        := RgbHexToColor($37414F);
  clSideHover      := RgbHexToColor($2D2D30);
  clSideActive     := RgbHexToColor($8FB84E);
  clStatusBg       := RgbHexToColor($252526);
  clStatusText     := RgbHexToColor($9D9D9D);
  clMenuBg         := RgbHexToColor($252526);
  clMenuText       := RgbHexToColor($CCCCCC);
  clMenuHover      := RgbHexToColor($37414F);
  clMenuPopupBg    := RgbHexToColor($2D2D30);
  clMenuDisabled   := RgbHexToColor($808080);
  clMenuSep        := RgbHexToColor($454549);
  clTabStrip       := RgbHexToColor($3A3A3D);
  clTabActive      := RgbHexToColor($646469);
  clTabInactive    := RgbHexToColor($4C4C50);
  clTabHover       := RgbHexToColor($59595E);
  clTabActiveText  := RgbHexToColor($FFFFFF);
  clTabInactiveText := RgbHexToColor($D2D2D2);
  clTabIcon        := RgbHexToColor($6A9955);
  clTabIconHi      := RgbHexToColor($7AB069);
  clTabDead        := RgbHexToColor($F14C4C);
  clTermBg         := RgbHexToColor($1E1E1E);
  clTermFg         := RgbHexToColor($D4D4D4);

end.
