unit uContainerCmd;

{$mode objfpc}{$H+}

// Composition de la commande distante d'un conteneur. Unite
// PURE, donc testable: c'est ici que se joue la defense contre l'injection.

interface

uses
  uRshModel;

const
  CONTAINER_EXIT_NO_ENGINE = 90;
  CONTAINER_EXIT_NO_CONTAINER = 91;
  CONTAINER_EXIT_NO_SHELL = 92;

function ShQuote(const S: string): string;

// Echecs classes par CODE de sortie: 90 moteur, 91 conteneur, 92 shell.
// AContainerName DOIT etre deja valide (ValidateContainerName).
function BuildContainerCommand(AEngine: TContainerEngine;
  const AContainerName: string; AShell: TContainerShell): string;

implementation

uses
  SysUtils;

function ShQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

function BuildContainerCommand(AEngine: TContainerEngine;
  const AContainerName: string; AShell: TContainerShell): string;
var
  eng, qname, shpath: string;
begin
  eng := CONTAINER_ENGINE_NAMES[AEngine];
  qname := ShQuote(AContainerName);
  Result :=
    'command -v ' + eng + ' >/dev/null 2>&1 || exit ' +
      IntToStr(CONTAINER_EXIT_NO_ENGINE) + '; ' +
    eng + ' inspect --type=container ' + qname + ' >/dev/null 2>&1 || exit ' +
      IntToStr(CONTAINER_EXIT_NO_CONTAINER) + '; ';
  if AShell = csLog then
    Result := Result + 'exec ' + eng + ' logs -f --tail=200 ' + qname
  else
  begin
    shpath := CONTAINER_SHELL_PATHS[AShell];
    Result := Result +
      eng + ' exec ' + qname + ' ' + shpath + ' -c true >/dev/null 2>&1 || exit ' +
        IntToStr(CONTAINER_EXIT_NO_SHELL) + '; ' +
      'exec ' + eng + ' exec -it ' + qname + ' ' + shpath;
  end;
end;

end.
