unit uPodCmd;

{$mode objfpc}{$H+}

// Composition de la commande kubectl d'un pod. Unite PURE, donc
// testable: c'est ici que se joue la defense contre l'injection.

interface

uses
  uRshModel;

const
  POD_EXIT_NO_KUBECTL = 90;
  POD_EXIT_NO_POD = 91;
  POD_EXIT_NO_CONTAINER = 92;

// Echecs classes par CODE, jamais par texte: kubectl rend celui de la commande
// distante et sa sortie est localisee. Les trois noms DOIVENT etre deja valides.
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
