unit uPreferences;

{$mode objfpc}{$H+}

// Preferences locales en INI dans AppDataDir, jamais dans le .rsh: un document
// de connexions se partage, le choix de police de son proprietaire non. Aucun
// mot de passe ici. Fichier = entree non fiable: famille whitelistee, taille bornee.

interface

type
  TLockSessionPolicy = (
    lspAsk,
    lspDisconnect,  // le plus sur, defaut
    lspKeep         // sessions conservees, reconnexion interdite
  );

const
  PREF_TERM_FONT_SIZE_MIN = 8;
  PREF_TERM_FONT_SIZE_MAX = 32;
  PREF_TERM_FONT_SIZE_DEFAULT = 12;

var
  PrefTerminalFontFamily: string = '';  // cle Monaspace; '' = famille par defaut
  PrefTerminalFontSize: Integer = PREF_TERM_FONT_SIZE_DEFAULT;

  PrefLogEnabled: Boolean = False;
  PrefLogDebug: Boolean = False;        // sans effet si le journal est inactif
  PrefLogConfidential: Boolean = False; // masque host/username dans les entrees

  PrefThemeName: string = 'Rotten';

  PrefLockSessionPolicy: TLockSessionPolicy = lspDisconnect;

procedure ApplyLogPreferences;

// Ne leve jamais: une preference illisible ne doit pas empecher de demarrer.
procedure LoadPreferences;
procedure SavePreferences;

procedure ApplyPreferencesToTheme;

function PreferencesFilePath: string;

implementation

uses
  SysUtils, IniFiles, uAppPaths, uFontEmbed, uTheme, uLog;

const
  SECTION_TERM = 'Terminal';
  SECTION_DIAG = 'Diagnostics';
  SECTION_SEC = 'Security';

// Nom en clair, jamais l'ordinal: un ajout au milieu du type relirait de travers.
function PolicyName(APolicy: TLockSessionPolicy): string;
begin
  case APolicy of
    lspAsk: Result := 'ask';
    lspKeep: Result := 'keep';
  else
    Result := 'disconnect';
  end;
end;

function PolicyFromName(const AName: string): TLockSessionPolicy;
begin
  if SameText(Trim(AName), 'ask') then Result := lspAsk
  else if SameText(Trim(AName), 'keep') then Result := lspKeep
  else Result := lspDisconnect;  // inconnu ou absent: le plus sur
end;

procedure ApplyLogPreferences;
var
  lvl: TLogLevel;
begin
  if PrefLogDebug then lvl := llDebug else lvl := llInfo;
  LogConfigure(PrefLogEnabled, lvl, PrefLogConfidential);
end;

function PreferencesFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(AppDataDir) + 'preferences.ini';
end;

function ClampSize(AValue: Integer): Integer;
begin
  Result := AValue;
  if Result < PREF_TERM_FONT_SIZE_MIN then
    Result := PREF_TERM_FONT_SIZE_MIN;
  if Result > PREF_TERM_FONT_SIZE_MAX then
    Result := PREF_TERM_FONT_SIZE_MAX;
end;

procedure ApplyPreferencesToTheme;
var
  resolved: string;
begin
  RSTerminalFontSize := ClampSize(PrefTerminalFontSize);
  resolved := '';
  if PrefTerminalFontFamily <> '' then
    resolved := ResolveMonaspace(PrefTerminalFontFamily);
  if resolved = '' then
  begin
    if MonaspaceAvailable then
      // defaut TERMINAL = Radon, pas Neon: sinon ce fallback ecrase le demarrage
      resolved := MonaspaceTerminalDefaultFamily
    else
      resolved := '';   // fallback widgetset
  end;
  RSTerminalFontName := resolved;
end;

procedure LoadPreferences;
var
  ini: TIniFile;
begin
  try
    if FileExists(PreferencesFilePath) then
    begin
      ini := TIniFile.Create(PreferencesFilePath);
      try
        PrefTerminalFontFamily :=
          Trim(ini.ReadString(SECTION_TERM, 'FontFamily', ''));
        PrefTerminalFontSize := ClampSize(
          ini.ReadInteger(SECTION_TERM, 'FontSize', PREF_TERM_FONT_SIZE_DEFAULT));
        PrefLogEnabled := ini.ReadBool(SECTION_DIAG, 'LogEnabled', False);
        PrefLogDebug := ini.ReadBool(SECTION_DIAG, 'LogDebug', False);
        PrefLogConfidential := ini.ReadBool(SECTION_DIAG, 'LogConfidential', False);
        PrefThemeName := Trim(ini.ReadString('Theme', 'Name', 'Rotten'));
        if PrefThemeName = '' then PrefThemeName := 'Rotten';
        PrefLockSessionPolicy := PolicyFromName(
          ini.ReadString(SECTION_SEC, 'LockSessionPolicy', ''));
      finally
        ini.Free;
      end;
    end;
  except
    on E: Exception do
    begin
      PrefTerminalFontFamily := '';
      PrefTerminalFontSize := PREF_TERM_FONT_SIZE_DEFAULT;
      PrefLogEnabled := False;
      PrefLogDebug := False;
      PrefLogConfidential := False;
      PrefThemeName := 'Rotten';
      PrefLockSessionPolicy := lspDisconnect;
    end;
  end;
  ApplyPreferencesToTheme;
  ApplyLogPreferences;
end;

procedure SavePreferences;
var
  ini: TIniFile;
begin
  try
    ForceDirectories(AppDataDir);
    ini := TIniFile.Create(PreferencesFilePath);
    try
      ini.WriteString(SECTION_TERM, 'FontFamily', PrefTerminalFontFamily);
      ini.WriteInteger(SECTION_TERM, 'FontSize', ClampSize(PrefTerminalFontSize));
      ini.WriteBool(SECTION_DIAG, 'LogEnabled', PrefLogEnabled);
      ini.WriteBool(SECTION_DIAG, 'LogDebug', PrefLogDebug);
      ini.WriteBool(SECTION_DIAG, 'LogConfidential', PrefLogConfidential);
      ini.WriteString('Theme', 'Name', PrefThemeName);
      ini.WriteString(SECTION_SEC, 'LockSessionPolicy',
        PolicyName(PrefLockSessionPolicy));
      ini.UpdateFile;
    finally
      ini.Free;
    end;
  except
    on E: Exception do
      ;   // l'ecriture des preferences ne doit pas casser une session en cours
  end;
end;

end.
