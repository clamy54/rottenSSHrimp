program rottensshrimp;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  uDllHarden,   // EN PREMIER: durcit la recherche de DLL avant les LoadLibrary de la LCL
  SysUtils, {$IF defined(LINUX) or defined(DARWIN)}Classes, Graphics,{$IFEND} Interfaces, Forms,
  uFrmMain, uTheme, uThemeLoad, uFontEmbed, uVersion, uPreferences, uLog,
  uAppPaths;

{$R *.res}

{$IF defined(LINUX) or defined(DARWIN)}
// gtk2 corrompt le MAINICON au-dela de 16x16, macOS le degrade: PNG 256 a la place.
procedure LoadHiResAppIcon;
var
  rs: TResourceStream;
  png: TPortableNetworkGraphic;
begin
  try
    rs := TResourceStream.Create(HInstance, 'APPICON_PNG', RT_RCDATA);
    try
      png := TPortableNetworkGraphic.Create;
      try
        png.LoadFromStream(rs);
        Application.Icon.Assign(png);
      finally
        png.Free;
      end;
    finally
      rs.Free;
    end;
  except
    // l'icone liee fera l'affaire
  end;
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  // SIGPIPE tue le process par defaut; ignore, send() rend EPIPE et on gere.
  FpSignal(SigPipe, SignalHandler(SIG_IGN));
  {$ENDIF}
  Application.Title := RSSH_APP_NAME;
  Application.Scaled := True;
  Application.Initialize;
  EmbeddedFontManager.RegisterFonts;
  ApplyDefaultFonts; // avant la fenetre: lu a la creation des controles
  LoadPreferences;
  ThemesUserDir := AppDataDir + PathDelim + 'themes';
  ThemesEmbedded := False;
  PrefUiFontSize := 0;
  InitThemes(PrefThemeName);
  LogInfo('application demarree, version ' + RSSH_VERSION);
  {$IF defined(LINUX) or defined(DARWIN)}
  LoadHiResAppIcon;
  {$ENDIF}
  Application.CreateForm(TfrmMain, frmMain);
  frmMain.Show;
  Application.Run;
  LogInfo('application arretee');
  ReleaseInstanceRecovery;
  LogShutdown;
end.
