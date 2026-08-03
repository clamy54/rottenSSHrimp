unit uFontEmbed;

{$mode objfpc}{$H+}

// Polices Monaspace Frozen enregistrees pour ce seul process: ressources RCDATA
// du binaire, repli sur fonts/ a cote de l'exe. Aucune dependance LCL.

interface

type
  IEmbeddedFontManager = interface
    ['{5B0C8F3A-2D71-4E86-9AE4-7C51D20B93F4}']
    procedure RegisterFonts;
    procedure UnregisterFonts;
    function UiFontName: UnicodeString;
    function TerminalFontName: UnicodeString;
    function IsFallbackActive: Boolean;
  end;

function EmbeddedFontManager: IEmbeddedFontManager;

procedure LoadEmbeddedFonts;

function MonaspaceAvailable: Boolean;
function MonaspaceFamilyCount: Integer;
function MonaspaceFamilyKey(AIndex: Integer): string;   // 'Neon', 'Argon'...
function MonaspaceDefaultFamily: string;                // 'Monaspace Neon Frozen'
function MonaspaceTerminalDefaultFamily: string;        // 'Monaspace Radon Frozen'
function ResolveMonaspace(const AValue: string): string;

implementation

uses
  Classes, SysUtils,
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  {$IFDEF LINUX}dynlibs,{$ENDIF}
  {$IFDEF DARWIN}MacOSAll,{$ENDIF}
  {$IF DEFINED(LINUX) OR DEFINED(DARWIN)}BaseUnix,{$ENDIF}
  uSafeSave;

const
  FontRes: array[0..19] of string = (
    'NEON_REGULAR', 'NEON_BOLD', 'NEON_ITALIC', 'NEON_BOLDITALIC',
    'ARGON_REGULAR', 'ARGON_BOLD', 'ARGON_ITALIC', 'ARGON_BOLDITALIC',
    'XENON_REGULAR', 'XENON_BOLD', 'XENON_ITALIC', 'XENON_BOLDITALIC',
    'RADON_REGULAR', 'RADON_BOLD', 'RADON_ITALIC', 'RADON_BOLDITALIC',
    'KRYPTON_REGULAR', 'KRYPTON_BOLD', 'KRYPTON_ITALIC', 'KRYPTON_BOLDITALIC');
  FontFamily = 'Monaspace Neon Frozen';

  // whitelist: seules ces familles sont acceptees d'un theme
  FamKeys: array[0..4] of string =
    ('Neon', 'Argon', 'Xenon', 'Radon', 'Krypton');
  FamFull: array[0..4] of string = (
    'Monaspace Neon Frozen', 'Monaspace Argon Frozen', 'Monaspace Xenon Frozen',
    'Monaspace Radon Frozen', 'Monaspace Krypton Frozen');
  StyleSuffix: array[0..3] of string = ('Regular', 'Bold', 'Italic', 'BoldItalic');

var
  FamStyleLoaded: array[0..4, 0..3] of Boolean;
  FontsLoaded: Boolean;

// Famille incomplete: CreateFont par nom fallbackerait en silence ailleurs.
function FamComplete(AFam: Integer): Boolean;
var
  s: Integer;
begin
  Result := False;
  if (AFam < 0) or (AFam > High(FamKeys)) then Exit;
  for s := 0 to 3 do
    if not FamStyleLoaded[AFam, s] then Exit;
  Result := True;
end;

procedure MarkRes(AResIdx: Integer);
begin
  if (AResIdx >= 0) and (AResIdx <= High(FontRes)) then
    FamStyleLoaded[AResIdx div 4, AResIdx mod 4] := True;
end;

function ResIndexOfFile(const AName: string): Integer;
var
  f, s: Integer;
begin
  Result := -1;
  for f := 0 to High(FamKeys) do
    for s := 0 to 3 do
      if SameText(AName, 'Monaspace' + FamKeys[f] + 'Frozen-' + StyleSuffix[s] + '.ttf') then
        Exit(f * 4 + s);
end;

function MonaspaceAvailable: Boolean;
begin
  Result := FamComplete(0); // Neon = police de base
end;

function MonaspaceFamilyCount: Integer;
begin
  Result := Length(FamKeys);
end;

function MonaspaceFamilyKey(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex <= High(FamKeys)) then
    Result := FamKeys[AIndex]
  else
    Result := '';
end;

function MonaspaceDefaultFamily: string;
begin
  Result := FontFamily;
end;

function MonaspaceTerminalDefaultFamily: string;
begin
  Result := ResolveMonaspace('Radon');
  if Result = '' then
    Result := FontFamily;
end;

function ResolveMonaspace(const AValue: string): string;
var
  i: Integer;
  v: string;
begin
  Result := '';
  v := Trim(AValue);
  for i := 0 to High(FamKeys) do
    if SameText(v, FamKeys[i]) or SameText(v, FamFull[i]) then
    begin
      if FamComplete(i) then Result := FamFull[i];
      Exit;
    end;
end;

function OpenFontRes(const AName: string): TResourceStream;
begin
  try
    Result := TResourceStream.Create(HINSTANCE, AName, PChar(PtrUInt(10))); // RT_RCDATA
  except
    on EResNotFound do Result := nil;
  end;
end;

{$IF DEFINED(WINDOWS)}

const
  FR_PRIVATE = $10;

function AddFontResourceExW(lpszFilename: PWideChar; fl: DWORD; pdv: Pointer): LongInt;
  stdcall; external 'gdi32.dll' name 'AddFontResourceExW';
function AddFontMemResourceEx(pbFont: Pointer; cbFont: DWORD; pdv: Pointer;
  pcFonts: PDWORD): THandle; stdcall; external 'gdi32.dll' name 'AddFontMemResourceEx';

function AddFontFile(const APath: string): Boolean;
begin
  Result := AddFontResourceExW(PWideChar(UTF8Decode(APath)), FR_PRIVATE, nil) > 0;
end;

function LoadFromResources: Boolean;
var
  i: Integer;
  rs: TResourceStream;
  n: DWORD;
begin
  Result := False;
  for i := 0 to High(FontRes) do
  begin
    rs := OpenFontRes(FontRes[i]);
    if rs = nil then Continue;
    try
      n := 0;
      if AddFontMemResourceEx(rs.Memory, DWORD(rs.Size), nil, @n) <> 0 then
      begin
        MarkRes(i);
        Result := True;
      end;
    finally
      rs.Free;
    end;
  end;
end;

{$ELSEIF DEFINED(LINUX) OR DEFINED(DARWIN)}

{$IFDEF LINUX}
function AddFontFile(const APath: string): Boolean;
type
  TFcAppFontAddFile = function(config: Pointer; fname: PAnsiChar): LongInt; cdecl;
var
  lib: TLibHandle;
  fn: TFcAppFontAddFile;
begin
  Result := False;
  lib := LoadLibrary('libfontconfig.so.1');
  if lib = NilHandle then Exit;
  fn := TFcAppFontAddFile(GetProcedureAddress(lib, 'FcConfigAppFontAddFile'));
  if fn <> nil then
    Result := fn(nil, PAnsiChar(APath)) <> 0;
end;

// Pango fige ses familles avant notre main: sans ca, la police reste invisible
// et le texte sort en systeme, sans une erreur.
procedure NotifyFontconfigChanged;
type
  TGetDefaultMap = function: Pointer; cdecl;
  TConfigChanged = procedure(fontmap: Pointer); cdecl;
var
  pc, ft: TLibHandle;
  getmap: TGetDefaultMap;
  changed: TConfigChanged;
  fm: Pointer;
begin
  pc := LoadLibrary('libpangocairo-1.0.so.0');
  ft := LoadLibrary('libpangoft2-1.0.so.0');
  if (pc = NilHandle) or (ft = NilHandle) then Exit;
  getmap := TGetDefaultMap(GetProcedureAddress(pc, 'pango_cairo_font_map_get_default'));
  changed := TConfigChanged(GetProcedureAddress(ft, 'pango_fc_font_map_config_changed'));
  if (getmap = nil) or (changed = nil) then Exit;
  fm := getmap();
  if fm <> nil then changed(fm);
end;
{$ENDIF}

{$IFDEF DARWIN}
{$linkframework CoreFoundation}
{$linkframework CoreText}

function AddFontFile(const APath: string): Boolean;
const
  kCTFontManagerScopeProcess = 1;
var
  url: CFURLRef;
  err: CFErrorRef;
begin
  Result := False;
  url := CFURLCreateFromFileSystemRepresentation(nil, PAnsiChar(APath),
    Length(APath), False);
  if url = nil then Exit;
  // 3e param = var CFErrorRef, pas un pointeur nullable: variable dediee
  err := nil;
  Result := CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, err) <> 0;
  if (not Result) and (err <> nil) then CFRelease(err);
  CFRelease(url);
end;
{$ENDIF}

function Elevated: Boolean;
begin
  Result := (FpGetEUid = 0) or (FpGetEUid <> FpGetUid) or (FpGetEGid <> FpGetGid);
end;

function PrivateDirOK(const ADir: string): Boolean;
var
  st: Stat;
begin
  Result := False;
  if fpLstat(PChar(ADir), st) <> 0 then Exit;
  if fpS_ISLNK(st.st_mode) or not fpS_ISDIR(st.st_mode) then Exit;
  if st.st_uid <> FpGetEUid then Exit;
  Result := fpChmod(PChar(ADir), &700) = 0;
end;

// Le cache n'est jamais cru: reecrit a chaque lancement, un .ttf depose la par
// un tiers est ecrase avant lecture.
function LoadFromResources: Boolean;
var
  i: Integer;
  rs: TResourceStream;
  st: TOwnedHandleStream;
  dir, path, tmp: string;
begin
  Result := False;
  dir := GetAppConfigDir(False) + 'fonts' + PathDelim;
  if not ForceDirectories(dir) then Exit;
  if not PrivateDirOK(ExcludeTrailingPathDelimiter(dir)) then Exit;
  for i := 0 to High(FontRes) do
  begin
    rs := OpenFontRes(FontRes[i]);
    if rs = nil then Continue;
    try
      try
        path := dir + FontRes[i] + '.ttf';
        tmp := '';
        st := CreateTempIn(path, tmp);
        try
          st.CopyFrom(rs, 0);
        finally
          st.Free;
        end;
        if ReplaceByRename(tmp, path) then
        begin
          if AddFontFile(path) then
          begin
            MarkRes(i);
            Result := True;
          end;
        end
        else
          DeleteFile(tmp);
      except
        if tmp <> '' then DeleteFile(tmp); // pas de temp orphelin
      end;
    finally
      rs.Free;
    end;
  end;
end;

{$ELSE}

function AddFontFile(const APath: string): Boolean;
begin
  Result := False;
end;

function LoadFromResources: Boolean;
begin
  Result := False;
end;

{$ENDIF}

// Un .ttf inconnu n'atteint jamais le parseur de fontes.
function LoadFromFiles: Boolean;
var
  dir: string;
  sr: TSearchRec;
  idx: Integer;
begin
  Result := False;
  dir := ExtractFilePath(ParamStr(0)) + 'fonts' + PathDelim;
  if not DirectoryExists(dir) then Exit;
  if FindFirst(dir + '*.ttf', faAnyFile, sr) = 0 then
  begin
    repeat
      idx := ResIndexOfFile(sr.Name);
      if idx < 0 then Continue;
      if FamStyleLoaded[idx div 4, idx mod 4] then Continue;
      if AddFontFile(dir + sr.Name) then
      begin
        Result := True;
        MarkRes(idx);
      end;
    until FindNext(sr) <> 0;
    SysUtils.FindClose(sr);
  end;
end;

procedure LoadEmbeddedFonts;
begin
  if FontsLoaded then Exit;
  FontsLoaded := True;
  {$IF DEFINED(LINUX) OR DEFINED(DARWIN)}
  // process eleve: rien du disque, le parseur de fontes est la surface
  if Elevated then Exit;
  {$ENDIF}
  LoadFromResources;
  LoadFromFiles;
  {$IFDEF LINUX}
  NotifyFontconfigChanged;
  {$ENDIF}
end;

type
  TEmbeddedFontManager = class(TInterfacedObject, IEmbeddedFontManager)
  public
    procedure RegisterFonts;
    procedure UnregisterFonts;
    function UiFontName: UnicodeString;
    function TerminalFontName: UnicodeString;
    function IsFallbackActive: Boolean;
  end;

procedure TEmbeddedFontManager.RegisterFonts;
begin
  LoadEmbeddedFonts;
end;

procedure TEmbeddedFontManager.UnregisterFonts;
begin
end;

function TEmbeddedFontManager.UiFontName: UnicodeString;
begin
  if MonaspaceAvailable then
    Result := UnicodeString(FontFamily)
  else
    Result := ''; // l'appelant garde la police par defaut du widgetset
end;

function TEmbeddedFontManager.TerminalFontName: UnicodeString;
begin
  Result := UiFontName; // meme famille dans le MVP
end;

function TEmbeddedFontManager.IsFallbackActive: Boolean;
begin
  Result := not MonaspaceAvailable;
end;

var
  GFontManager: IEmbeddedFontManager;

function EmbeddedFontManager: IEmbeddedFontManager;
begin
  if GFontManager = nil then
    GFontManager := TEmbeddedFontManager.Create;
  Result := GFontManager;
end;

end.
