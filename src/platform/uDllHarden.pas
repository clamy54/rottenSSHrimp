unit uDllHarden;

{$mode objfpc}{$H+}

// Anti DLL-hijack: EN TETE du uses du programme, avant les unites LCL qui font
// des LoadLibrary non qualifies des leur initialization. Plus de cwd ni de PATH.
// cf. PuTTY vuln-indirect-dll-hijack: ce sont les dependances INDIRECTES.
// Absent avant Win8 sans KB2533623: on s'en passe, les DLL primaires sont en absolu.

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
