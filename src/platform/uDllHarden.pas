unit uDllHarden;

{$mode objfpc}{$H+}

// Durcissement anti-DLL-hijack applique LE PLUS TOT possible: la section
// initialization de cette unite (sans dependance LCL), placee en tete du uses
// du programme, s'execute AVANT l'initialization des unites LCL. C'est
// necessaire car celles-ci (win32extra et consorts) font des LoadLibrary NON
// qualifies des leur initialization (msimg32, user32, shell32, gdi32,
// comctl32): les faire apres n'aurait rien protege. On restreint la recherche
// de DLL a System32 + dossier de l'exe + repertoires ajoutes explicitement,
// retirant le REPERTOIRE COURANT et le PATH.
//
// cf. PuTTY vuln-indirect-dll-hijack (0.68->0.70), ou le correctif du
// chargement direct laissait les dependances INDIRECTES exploitables. Nos DLL
// primaires sont deja chargees par chemin absolu depuis exeDir; ceci couvre
// leurs dependances transitives et les DLL systeme chargees a la demande.
//
// No-op hors Windows, et si SetDefaultDllDirectories est absent (< Win8 sans
// KB2533623): le chargement par chemin absolu des libs primaires tient de
// toute facon. Resolu dynamiquement.

interface

implementation

{$IFDEF WINDOWS}
uses
  Windows;

procedure HardenDllSearchPath;
const
  DLL_SEARCH_DEFAULT_DIRS = DWORD($00001000);  // LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
type
  TSetDefaultDllDirectories = function(AFlags: DWORD): BOOL; stdcall;
var
  h: HMODULE;
  setDirs: TSetDefaultDllDirectories;
begin
  h := GetModuleHandle('kernel32.dll');
  if h = 0 then Exit;
  Pointer(setDirs) := GetProcAddress(h, 'SetDefaultDllDirectories');
  if Assigned(setDirs) then
    setDirs(DLL_SEARCH_DEFAULT_DIRS);
end;
{$ENDIF}

initialization
{$IFDEF WINDOWS}
  HardenDllSearchPath;
{$ENDIF}

end.
