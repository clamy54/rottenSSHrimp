unit uOpenArg;

{$mode objfpc}{$H+}

// Chemin venu de l'EXTERIEUR (ligne de commande, Apple Event « odoc »): entree
// hostile, refus par defaut. Ne dit PAS qu'un .rsh est sain: borne seulement ce
// qu'on atteint sans que l'utilisateur ait rien choisi.

interface

// Utiliser APath (normalise), jamais ARaw. AReason s'affiche tel quel.
function ValidateDocumentArg(const ARaw: string; out APath: string;
  out AReason: string): Boolean;

function CommandLineDocumentArg: string;

implementation

uses
  SysUtils
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

const
  // PATH_MAX Linux; au-dela, ca ne vient pas d'un double-clic
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
// UNC: Windows ouvre la session SMB AVANT de lire, et offre le defi NTLM au
// serveur d'en face. \\.\ et \\?\: des pipes et des volumes, pas des documents.
function IsUncOrDevice(const S: string): Boolean;
begin
  Result := (Length(S) >= 2) and
    ((S[1] = '\') or (S[1] = '/')) and ((S[2] = '\') or (S[2] = '/'));
end;

// « doc.rsh:cache » est un flux ADS: meme nom a l'ecran, autre contenu.
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

// FIFO: bloque pour toujours. /dev/zero: ne finit jamais. Lien: juge sur sa cible.
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
  if raw = '' then Exit;   // AReason vide: rien a signaler

  if Length(raw) > MAX_ARG_LEN then
  begin
    AReason := 'the path is too long';
    Exit;
  end;
  // Refuser, pas nettoyer: le chemin nettoye n'est plus celui demande.
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

  // AVANT les controles: on verifie ce qui sera ouvert, pas autre chose.
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
  // Relatif + cwd sur un partage = UNC apres coup.
  if IsUncOrDevice(APath) then
  begin
    AReason := 'network and device paths are not opened this way';
    Exit;
  end;
  {$ENDIF}

  // Ne protege pas d'un .rsh hostile, juste d'un « ouvrir avec » sur n'importe quoi.
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
    // Jamais un chemin; un vrai « -nom.rsh » s'ouvre par « ./-nom.rsh ».
    if a[1] = '-' then Continue;
    // Le premier seulement: sinon, une rafale de demandes de mot de passe.
    Exit(a);
  end;
end;

end.
