program rottensshrimp;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  uDllHarden,   // en tete du uses: son initialization durcit la recherche de
                // DLL AVANT l'init des unites LCL (qui font des LoadLibrary)
  SysUtils, {$IF defined(LINUX) or defined(DARWIN)}Classes, Graphics,{$IFEND} Interfaces, Forms,
  uFrmMain, uTheme, uThemeLoad, uFontEmbed, uVersion, uPreferences, uLog,
  uAppPaths;

{$R *.res}

{$IF defined(LINUX) or defined(DARWIN)}
// gtk2 corrompt le MAINICON au-dela de 16x16, macOS y retombe en basse
// resolution: le meme dessin en PNG 256 passe intact. Windows ne s'en soucie pas.
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
    // ressource absente ou illisible: l'icone liee fera l'affaire
  end;
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  // ecrire vers un pair qui a ferme leverait SIGPIPE, qui TUE le process par
  // defaut: ignore, les send() rendent EPIPE et c'est gere localement
  FpSignal(SigPipe, SignalHandler(SIG_IGN));
  {$ENDIF}
  Application.Title := RSSH_APP_NAME;
  Application.Scaled := True;
  Application.Initialize;
  EmbeddedFontManager.RegisterFonts;
  ApplyDefaultFonts; // avant la fenetre: les controles lisent les valeurs a la creation
  LoadPreferences;
  InitThemes(PrefThemeName);
  LogInfo('application demarree, version ' + RSSH_VERSION);
  {$IF defined(LINUX) or defined(DARWIN)}
  LoadHiResAppIcon;
  {$ENDIF}
  Application.CreateForm(TfrmMain, frmMain);
  frmMain.Show;
  Application.Run;
  LogInfo('application arretee');
  // un arret normal ne doit pas laisser d'orphelin a proposer au prochain demarrage
  ReleaseInstanceRecovery;
  LogShutdown;
end.
