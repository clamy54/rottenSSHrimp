unit uOpenArg;

{$mode objfpc}{$H+}

// Chemin de document venu de l'EXTERIEUR: ligne de commande (association .rsh
// de l'installeur Windows, « rottensshrimp doc.rsh ») ou Apple Event « odoc »
// du Finder. Ce n'est PAS l'equivalent du dialogue Ouvrir: l'utilisateur y
// choisit un fichier qu'il voit, alors qu'ici la valeur peut venir d'un
// raccourci prepare, d'une piece jointe ouverte d'un double-clic, d'un
// gestionnaire de fichiers, ou d'un autre programme. On la traite comme une
// entree hostile et on refuse par defaut.
//
// Ce que ce filtre NE fait PAS: il ne dit pas qu'un document est sain. Un .rsh
// hostile reste hostile; il est chiffre et demande un mot de passe, et c'est
// l'ouverture du document qui doit resister. Le filtre limite la surface
// atteignable sans interaction, rien de plus.

interface

// True si l'argument peut etre confie a l'ouverture de document. APath rend le
// chemin NORMALISE (a utiliser a la place de la valeur brute), AReason le motif
// de refus, destine a l'utilisateur.
function ValidateDocumentArg(const ARaw: string; out APath: string;
  out AReason: string): Boolean;

// Premier argument de ligne de commande qui n'est pas une option. '' si aucun.
function CommandLineDocumentArg: string;

implementation

uses
  SysUtils
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

const
  // Un chemin plus long que ca ne vient pas d'un double-clic. MAX_PATH vaut 260
  // sous Windows, PATH_MAX 4096 sous Linux: on borne avant tout traitement pour
  // ne pas promener des megaoctets dans des concatenations.
  MAX_ARG_LEN = 4096;
  DOC_EXT = '.rsh';

function HasControlChars(const S: string): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if S[i] < ' ' then Exit;
  Result := False;
end;

{$IFDEF WINDOWS}
// Un chemin UNC (\\serveur\partage\x.rsh) fait ouvrir une session SMB AVANT
// toute lecture: Windows y presente l'authentification de l'utilisateur, et un
// serveur hostile en recolte le defi NTLM. Un simple raccourci suffirait donc a
// faire fuiter une empreinte de mot de passe, sans que rien ne soit ouvert.
// Meme refus pour les espaces de noms de peripheriques (\\.\ et \\?\), qui
// designent des pipes et des volumes, pas des documents.
function IsUncOrDevice(const S: string): Boolean;
begin
  Result := (Length(S) >= 2) and
    ((S[1] = '\') or (S[1] = '/')) and ((S[2] = '\') or (S[2] = '/'));
end;

// « doc.rsh:cache » designe un FLUX ALTERNATIF (ADS): meme nom de fichier a
// l'ecran, contenu tout autre. Seul le « : » de la lettre de lecteur est admis.
function HasAlternateStream(const S: string): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 1 to Length(S) do
    if (S[i] = ':') and (i <> 2) then Exit;
  Result := False;
end;
{$ENDIF}

// Un FIFO bloquerait l'ouverture indefiniment, un peripherique de caractere
// rendrait un flux infini: le document doit etre un fichier ORDINAIRE. fpStat
// suit les liens, donc un lien symbolique est juge sur sa cible.
function IsRegularFile(const APath: string): Boolean;
{$IFDEF UNIX}
var
  st: stat;
begin
  Result := (FpStat(APath, st) = 0) and fpS_ISREG(st.st_mode);
end;
{$ELSE}
var
  attr: Integer;
begin
  attr := FileGetAttr(APath);
  Result := (attr <> -1) and ((attr and faDirectory) = 0);
end;
{$ENDIF}

function ValidateDocumentArg(const ARaw: string; out APath: string;
  out AReason: string): Boolean;
var
  raw: string;
begin
  Result := False;
  APath := '';
  AReason := '';

  raw := ARaw;
  if raw = '' then Exit;   // pas d'argument: pas un refus a signaler

  if Length(raw) > MAX_ARG_LEN then
  begin
    AReason := 'the path is too long';
    Exit;
  end;
  // Des caracteres de controle dans un nom servent a le maquiller a l'affichage
  // (retour chariot, marques de sens d'ecriture): on ne les nettoie pas, on
  // refuse -- nettoyer donnerait un chemin qui n'est plus celui demande.
  if HasControlChars(raw) then
  begin
    AReason := 'the path contains control characters';
    Exit;
  end;

  {$IFDEF WINDOWS}
  if IsUncOrDevice(raw) then
  begin
    AReason := 'network and device paths are not opened this way';
    Exit;
  end;
  if HasAlternateStream(raw) then
  begin
    AReason := 'the path names an alternate data stream';
    Exit;
  end;
  {$ENDIF}

  // Normalise « .. » et le relatif AVANT tout controle d'existence: ce qui est
  // verifie doit etre exactement ce qui sera ouvert.
  try
    APath := ExpandFileName(raw);
  except
    on E: Exception do
    begin
      APath := '';
      AReason := 'the path cannot be resolved';
      Exit;
    end;
  end;

  {$IFDEF WINDOWS}
  // ExpandFileName d'un chemin relatif peut retomber sur un partage reseau si
  // le repertoire courant en est un: on recontrole apres normalisation.
  if IsUncOrDevice(APath) then
  begin
    AReason := 'network and device paths are not opened this way';
    Exit;
  end;
  {$ENDIF}

  // L'association ne porte que sur .rsh. Refuser le reste ne protege pas d'un
  // .rsh hostile (rien n'empeche de le nommer ainsi), mais evite qu'un lanceur
  // ou un « ouvrir avec » dirige l'application sur un fichier quelconque.
  if not SameText(ExtractFileExt(APath), DOC_EXT) then
  begin
    AReason := 'only ' + DOC_EXT + ' documents can be opened this way';
    Exit;
  end;

  if DirectoryExists(APath) then
  begin
    AReason := 'the path is a directory';
    Exit;
  end;
  if not FileExists(APath) then
  begin
    AReason := 'the file does not exist';
    Exit;
  end;
  if not IsRegularFile(APath) then
  begin
    AReason := 'the path is not a regular file';
    Exit;
  end;

  Result := True;
end;

function CommandLineDocumentArg: string;
var
  i: Integer;
  a: string;
begin
  Result := '';
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if a = '' then Continue;
    // Tout ce qui ressemble a une option est ignore, jamais pris pour un
    // chemin: sinon un « -quelque-chose » glisse dans l'association se
    // retrouverait traite comme un nom de fichier. Un vrai fichier dont le nom
    // commence par un tiret reste ouvrable par « ./-nom.rsh ».
    if a[1] = '-' then Continue;
    // Le premier gagne: l'application n'ouvre qu'un document a la fois, et
    // enchainer les ouvertures sur une liste d'arguments ferait defiler autant
    // de demandes de mot de passe.
    Exit(a);
  end;
end;

end.
