unit uThemeLoad;

{$mode objfpc}{$H+}

// Themes integres + JSON externes de <app-data>/themes. Appliquer un theme =
// repartir des defauts compiles puis ecrire les cles fournies. Le parse va
// dans un tampon local avant commit: un JSON pourri ne casse rien.

interface

// nom inconnu ou vide: repli sur "Rotten"
procedure InitThemes(const APreferredName: string);

function ThemeCount: Integer;
function ThemeName(AIndex: Integer): string;
function CurrentThemeIndex: Integer;
function CurrentThemeName: string;

function ApplyThemeIndex(AIndex: Integer): Boolean;
function ApplyThemeByName(const AName: string): Boolean;

implementation

uses
  Classes, SysUtils, Graphics, fpjson, jsonparser, uTheme, uAppPaths;

type
  TRegEntry = record
    Key: string;
    P: PColor;
    Def: TColor;   // defaut compile, capture au demarrage
  end;

  TPair = record
    Key: string;
    Value: TColor;
  end;

  TThemeDef = record
    Name: string;
    FromFile: string;      // '' pour un theme integre
    Pairs: array of TPair;
  end;

var
  GReg: array of TRegEntry;
  GThemes: array of TThemeDef;
  GCurrent: Integer = 0;

procedure Reg(const AKey: string; AP: PColor);
begin
  SetLength(GReg, Length(GReg) + 1);
  GReg[High(GReg)].Key := AKey;
  GReg[High(GReg)].P := AP;
  GReg[High(GReg)].Def := AP^;
end;

procedure BuildRegistry;
begin
  GReg := nil;
  Reg('appBg', @clAppBg);
  Reg('appFg', @clAppFg);
  Reg('accent', @clAccent);
  Reg('border', @clBorder);
  Reg('sideBg', @clSideBg);
  Reg('sideText', @clSideText);
  Reg('sideTextHi', @clSideTextHi);
  Reg('sideSel', @clSideSel);
  Reg('sideHover', @clSideHover);
  Reg('sideActive', @clSideActive);
  Reg('statusBg', @clStatusBg);
  Reg('statusText', @clStatusText);
  Reg('menuBg', @clMenuBg);
  Reg('menuText', @clMenuText);
  Reg('menuHover', @clMenuHover);
  Reg('menuPopupBg', @clMenuPopupBg);
  Reg('menuDisabled', @clMenuDisabled);
  Reg('menuSep', @clMenuSep);
  Reg('tabStrip', @clTabStrip);
  Reg('tabActive', @clTabActive);
  Reg('tabInactive', @clTabInactive);
  Reg('tabHover', @clTabHover);
  Reg('tabActiveText', @clTabActiveText);
  Reg('tabInactiveText', @clTabInactiveText);
  Reg('tabIcon', @clTabIcon);
  Reg('tabIconHi', @clTabIconHi);
  Reg('termBg', @clTermBg);
  Reg('termFg', @clTermFg);
end;

function P(const AKey: string; ARgb: Cardinal): TPair;
begin
  Result.Key := AKey;
  Result.Value := RgbHexToColor(ARgb);
end;

procedure AddTheme(const AName, AFromFile: string; const APairs: array of TPair);
var
  i: Integer;
begin
  SetLength(GThemes, Length(GThemes) + 1);
  GThemes[High(GThemes)].Name := AName;
  GThemes[High(GThemes)].FromFile := AFromFile;
  SetLength(GThemes[High(GThemes)].Pairs, Length(APairs));
  for i := 0 to High(APairs) do
    GThemes[High(GThemes)].Pairs[i] := APairs[i];
end;

// #RRGGBB strict -> True + couleur; sinon False (cle ignoree)
function ParseColorStr(const S: string; out AColor: TColor): Boolean;
var
  v: Integer;
begin
  Result := False;
  if (Length(S) <> 7) or (S[1] <> '#') then Exit;
  if not TryStrToInt('$' + Copy(S, 2, 6), v) then Exit;
  AColor := RgbHexToColor(Cardinal(v));
  Result := True;
end;

procedure BuildBuiltins;
begin
  GThemes := nil;
  // "Rotten" = les defauts compiles, aucune surcharge
  AddTheme('Rotten', '', []);

  AddTheme('Light', '', [
    P('appBg', $F3F3F3), P('appFg', $1E1E1E), P('accent', $C05A1E),
    P('border', $C8C8C8),
    P('sideBg', $ECECEC), P('sideText', $2B2B2B), P('sideTextHi', $000000),
    P('sideSel', $CFE3FA), P('sideHover', $E0E0E0), P('sideActive', $1F7A1F),
    P('statusBg', $E0E0E0), P('statusText', $404040),
    P('menuBg', $F3F3F3), P('menuText', $1E1E1E), P('menuHover', $CFE3FA),
    P('menuPopupBg', $FFFFFF), P('menuDisabled', $9A9A9A), P('menuSep', $D7D7D7),
    P('tabStrip', $E4E4E4), P('tabActive', $FFFFFF), P('tabInactive', $DADADA),
    P('tabHover', $EDEDED), P('tabActiveText', $1E1E1E),
    P('tabInactiveText', $6A6A6A), P('tabIcon', $4E8A3A), P('tabIconHi', $3D7A2D),
    P('termBg', $FBFBFB), P('termFg', $2B2B2B)]);

  AddTheme('Nord', '', [
    P('appBg', $2E3440), P('appFg', $D8DEE9), P('accent', $88C0D0),
    P('border', $232831),
    P('sideBg', $2B303B), P('sideText', $D8DEE9), P('sideTextHi', $ECEFF4),
    P('sideSel', $434C5E), P('sideHover', $3B4252), P('sideActive', $A3BE8C),
    P('statusBg', $2B303B), P('statusText', $A6B0C0),
    P('menuBg', $2B303B), P('menuText', $D8DEE9), P('menuHover', $434C5E),
    P('menuPopupBg', $353B49), P('menuDisabled', $7B8497), P('menuSep', $434C5E),
    P('tabStrip', $2B303B), P('tabActive', $3B4252), P('tabInactive', $2E3440),
    P('tabHover', $353B49), P('tabActiveText', $ECEFF4),
    P('tabInactiveText', $8893A5), P('tabIcon', $A3BE8C), P('tabIconHi', $B7CE9F),
    P('termBg', $2E3440), P('termFg', $D8DEE9)]);
end;

function ThemesDir: string;
begin
  Result := AppDataDir + PathDelim + 'themes';
end;

// whitelist de cles + bornes: un fichier fautif est saute, pas fatal
procedure ScanExternal;
var
  sr: TSearchRec;
  path, raw, name, key: string;
  sl: TStringList;
  data: TJSONData;
  obj: TJSONObject;
  i: Integer;
  col: TColor;
  pairs: array of TPair;
begin
  if not DirectoryExists(ThemesDir) then Exit;
  if FindFirst(ThemesDir + PathDelim + '*.json', faAnyFile, sr) <> 0 then Exit;
  try
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      if sr.Size > 256 * 1024 then Continue;
      if Length(GThemes) >= 64 then Break;
      path := ThemesDir + PathDelim + sr.Name;
      sl := TStringList.Create;
      try
        try
          sl.LoadFromFile(path);
          raw := sl.Text;
        except
          Continue;
        end;
      finally
        sl.Free;
      end;
      data := nil;
      try
        try
          data := GetJSON(raw);
        except
          data := nil;
        end;
        if not (data is TJSONObject) then Continue;
        obj := TJSONObject(data);
        name := ChangeFileExt(sr.Name, '');
        if obj.IndexOfName('name') >= 0 then
          name := obj.Get('name', name);
        pairs := nil;
        for i := 0 to High(GReg) do
        begin
          key := GReg[i].Key;
          if obj.IndexOfName(key) < 0 then Continue;
          if ParseColorStr(obj.Get(key, ''), col) then
          begin
            SetLength(pairs, Length(pairs) + 1);
            pairs[High(pairs)].Key := key;
            pairs[High(pairs)].Value := col;
          end;
        end;
        AddTheme(name, sr.Name, pairs);
      finally
        data.Free;
      end;
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
end;

function ApplyThemeIndex(AIndex: Integer): Boolean;
var
  i, j: Integer;
begin
  Result := False;
  if (AIndex < 0) or (AIndex > High(GThemes)) then Exit;
  // repartir des defauts: un theme partiel ne doit pas heriter du precedent
  for i := 0 to High(GReg) do
    GReg[i].P^ := GReg[i].Def;
  for i := 0 to High(GThemes[AIndex].Pairs) do
    for j := 0 to High(GReg) do
      if GReg[j].Key = GThemes[AIndex].Pairs[i].Key then
      begin
        GReg[j].P^ := GThemes[AIndex].Pairs[i].Value;
        Break;
      end;
  GCurrent := AIndex;
  Result := True;
end;

function ApplyThemeByName(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to High(GThemes) do
    if SameText(GThemes[i].Name, AName) then
      Exit(ApplyThemeIndex(i));
end;

procedure InitThemes(const APreferredName: string);
begin
  BuildRegistry;
  BuildBuiltins;
  ScanExternal;
  if (APreferredName = '') or (not ApplyThemeByName(APreferredName)) then
    ApplyThemeByName('Rotten');
end;

function ThemeCount: Integer;
begin
  Result := Length(GThemes);
end;

function ThemeName(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex <= High(GThemes)) then
    Result := GThemes[AIndex].Name
  else
    Result := '';
end;

function CurrentThemeIndex: Integer;
begin
  Result := GCurrent;
end;

function CurrentThemeName: string;
begin
  Result := ThemeName(GCurrent);
end;

end.
