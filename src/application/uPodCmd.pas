unit uPodCmd;

{$mode objfpc}{$H+}

// Unite PURE: toute la defense contre l'injection shell se joue ici.

interface

uses
  uRshModel;

const
  POD_EXIT_NO_KUBECTL = 90;
  POD_EXIT_NO_POD = 91;
  POD_EXIT_NO_CONTAINER = 92;

// Echec lu au CODE de sortie: le texte de kubectl est localise. Les trois noms
// DOIVENT etre deja valides.
function BuildPodCommand(const ANamespace, APodName, AContainerName: string;
  AShell: TContainerShell): string;

implementation

uses
  SysUtils, uContainerCmd;

function NsArg(const ANamespace: string): string;
begin
  if ANamespace <> '' then
    Result := ' -n ' + ShQuote(ANamespace)
  else
    Result := '';
end;

function ContArg(const AContainerName: string): string;
begin
  if AContainerName <> '' then
    Result := ' -c ' + ShQuote(AContainerName)
  else
    Result := '';
end;

function BuildPodCommand(const ANamespace, APodName, AContainerName: string;
  AShell: TContainerShell): string;
var
  ns, cont, qpod, shpath: string;
begin
  ns := NsArg(ANamespace);
  cont := ContArg(AContainerName);
  qpod := ShQuote(APodName);
  Result :=
    'command -v kubectl >/dev/null 2>&1 || exit ' +
      IntToStr(POD_EXIT_NO_KUBECTL) + '; ' +
    'kubectl get pod' + ns + ' ' + qpod + ' >/dev/null 2>&1 || exit ' +
      IntToStr(POD_EXIT_NO_POD) + '; ';
  if AShell = csLog then
    Result := Result + 'exec kubectl logs -f --tail=200' + ns + ' ' + qpod +
      cont
  else
  begin
    shpath := CONTAINER_SHELL_PATHS[AShell];
    Result := Result +
      'kubectl exec' + ns + ' ' + qpod + cont + ' -- ' + shpath +
        ' -c true >/dev/null 2>&1 || exit ' +
        IntToStr(POD_EXIT_NO_CONTAINER) + '; ' +
      'exec kubectl exec -it' + ns + ' ' + qpod + cont + ' -- ' + shpath;
  end;
end;

end.
