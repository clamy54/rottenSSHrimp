unit uSafeSave;

{$mode objfpc}{$H+}

// Ecriture de fichiers sans fenetre de troncature, sans TOCTOU, sans casser
// les liens. Repris de RottenText.

interface

uses
  Classes, SysUtils{$IFDEF UNIX}, BaseUnix, Unix{$ENDIF}; // Unix: fpfsync

type
  TOwnedHandleStream = class(THandleStream)
  public
    destructor Destroy; override;
  end;

function HasHardLinks(const APath: string): Boolean;
// Couple volume/inode: change a tout rename, meme a taille et date identiques.
function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
// echoue AVANT toute ecriture plutot que de rendre un chemin encore lie:
// l'appelant renommerait par-dessus le LIEN
function ResolveLink(const APath: string): string;
// Chemin canonique pour servir de CLE (verrou d'instance): resout liens et
// jonctions de TOUS les segments, pas seulement du dernier -- deux chemins
// vers le meme document doivent donner la meme cle, sinon deux instances
// l'ouvrent chacune sous son verrou. Repli: le chemin absolu tel quel.
function CanonicalPathKey(const APath: string): string;
function CreateTempIn(const ADest: string; out ATmpName: string): TOwnedHandleStream;
// Contenu rendu durable AVANT le rename: fsync sous Unix, FlushFileBuffers
// sous Windows. False = le disque n'a pas confirme, la sauvegarde ne l'est pas.
function FlushToDisk(AHandle: THandle): Boolean;
function ReplaceByRename(const ATmp, ADest: string): Boolean;
// Variantes « privees »: 0600/0700 quel que soit l'umask; no-op sous Windows.
function ReplaceByRenamePrivate(const ATmp, ADest: string): Boolean;
procedure MakePrivateFile(const APath: string);
procedure MakePrivateDir(const APath: string);
// Mieux que « SaveToFile puis MakePrivateFile »: pas de fenetre ou un umask
// permissif expose le contenu a tout le monde.
procedure SavePrivateFile(const APath, AData: string);
procedure SavePrivateStream(const APath: string; ASrc: TStream);
procedure WriteInPlaceKeepLinks(const APath, AData: string);
// WriteBuffer prend un Count Longint: au-dela de 2 Gio la taille wrappe en
// silence ({$R-}) = copie tronquee
procedure WriteAllBuf(ASt: TStream; const AData: string);

implementation

procedure WriteAllBuf(ASt: TStream; const AData: string);
const
  CHUNK = 64 * 1024 * 1024;
var
  p, n: SizeInt;
begin
  p := 1;
  while p <= Length(AData) do
  begin
    n := Length(AData) - p + 1;
    if n > CHUNK then n := CHUNK;
    ASt.WriteBuffer(AData[p], n);
    Inc(p, n);
  end;
end;

destructor TOwnedHandleStream.Destroy;
begin
  if Handle <> THandle(-1) then
    FileClose(Handle);
  inherited Destroy;
end;

{$IFDEF WINDOWS}
const
  GENERIC_WRITE_W   = $40000000;
  CREATE_NEW_W      = 1;
  OPEN_EXISTING_W   = 3;
  FILE_ATTR_NORMAL  = $80;
  FILE_ATTR_REPARSE = $400;
  SHARE_ALL         = 7; // read + write + delete
  MOVEFILE_REPLACE_EXISTING = 1;
  MOVEFILE_COPY_ALLOWED     = 2;
  DACL_SECURITY_INFO = 4;
  FILE_FLAG_BACKUP_SEM = $02000000; // requis pour ouvrir un DOSSIER

type
  TByHandleInfo = record
    dwFileAttributes: LongWord;
    ftCreation, ftAccess, ftWrite: array[0..1] of LongWord;
    dwVolumeSerial, nSizeHigh, nSizeLow: LongWord;
    nNumberOfLinks: LongWord;
    nIndexHigh, nIndexLow: LongWord;
  end;

function CreateFileW(lpFileName: PWideChar; dwAccess, dwShare: LongWord;
  lpSec: Pointer; dwDisp, dwFlags: LongWord; hTemplate: THandle): THandle;
  stdcall; external 'kernel32.dll';
function CloseHandle(h: THandle): LongBool; stdcall; external 'kernel32.dll';
function GetFileAttributesW(lpFileName: PWideChar): LongWord;
  stdcall; external 'kernel32.dll';
function GetFileInformationByHandle(h: THandle; out AInfo: TByHandleInfo): LongBool;
  stdcall; external 'kernel32.dll';
function GetFinalPathNameByHandleW(h: THandle; lpszFilePath: PWideChar;
  cchFilePath, dwFlags: LongWord): LongWord; stdcall; external 'kernel32.dll';
function MoveFileExW(lpExisting, lpNew: PWideChar; dwFlags: LongWord): LongBool;
  stdcall; external 'kernel32.dll';
function FlushFileBuffers(h: THandle): LongBool; stdcall; external 'kernel32.dll';
function ReplaceFileW(lpReplaced, lpReplacement, lpBackup: PWideChar;
  dwFlags: LongWord; lpExclude, lpReserved: Pointer): LongBool;
  stdcall; external 'kernel32.dll';
function GetFileSecurityW(lpFileName: PWideChar; ARequested: LongWord;
  ADescriptor: Pointer; ALength: LongWord; var ANeeded: LongWord): LongBool;
  stdcall; external 'advapi32.dll';
function SetFileSecurityW(lpFileName: PWideChar; AInformation: LongWord;
  ADescriptor: Pointer): LongBool; stdcall; external 'advapi32.dll';

function HasHardLinks(const APath: string): Boolean;
var
  h: THandle;
  info: TByHandleInfo;
begin
  Result := False;
  // sans FLAG_OPEN_REPARSE_POINT, CreateFileW suit les symlinks: on teste la cible
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0);
  if h = THandle(-1) then Exit;
  if GetFileInformationByHandle(h, info) then
    Result := info.nNumberOfLinks > 1;
  CloseHandle(h);
end;

function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
var
  h: THandle;
  info: TByHandleInfo;
begin
  ADev := 0;
  AIno := 0;
  Result := False;
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0);
  if h = THandle(-1) then Exit;
  if GetFileInformationByHandle(h, info) then
  begin
    ADev := Int64(info.dwVolumeSerial);
    AIno := (Int64(info.nIndexHigh) shl 32) or Int64(info.nIndexLow);
    Result := True;
  end;
  CloseHandle(h);
end;

function FinalPathOfHandle(h: THandle; out APath: string): Boolean;
var
  n: LongWord;
  buf: array[0..4095] of WideChar;
  s: UnicodeString;
begin
  Result := False;
  APath := '';
  n := GetFinalPathNameByHandleW(h, @buf[0], Length(buf), 0);
  if (n = 0) or (n >= LongWord(Length(buf))) then Exit;
  SetString(s, PWideChar(@buf[0]), n);
  // GetFinalPathNameByHandle prefixe en \\?\ (ou \\?\UNC\ pour le reseau)
  if Copy(s, 1, 8) = '\\?\UNC\' then
    s := '\\' + Copy(s, 9, MaxInt)
  else if Copy(s, 1, 4) = '\\?\' then
    s := Copy(s, 5, MaxInt);
  APath := UTF8Encode(s);
  Result := True;
end;

function ResolveLink(const APath: string): string;
var
  attrs: LongWord;
  h: THandle;
begin
  Result := APath;
  // UTF8Decode explicite: ne pas dependre de DefaultSystemCodePage
  attrs := GetFileAttributesW(PWideChar(UTF8Decode(APath)));
  if (attrs = $FFFFFFFF) or ((attrs and FILE_ATTR_REPARSE) = 0) then
    Exit; // inexistant ou pas un lien: tel quel
  h := CreateFileW(PWideChar(UTF8Decode(APath)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, 0, 0); // suit le lien
  if h = THandle(-1) then
    raise EStreamError.CreateFmt('Cannot resolve link %s', [APath]);
  if not FinalPathOfHandle(h, Result) then
  begin
    CloseHandle(h);
    raise EStreamError.CreateFmt('Cannot resolve link %s', [APath]);
  end;
  CloseHandle(h);
end;

function CanonicalPathKey(const APath: string): string;
var
  h: THandle;
  dir, name, s: string;
begin
  Result := ExpandFileName(APath);
  // le handle du fichier resout liens ET jonctions des dossiers parents
  h := CreateFileW(PWideChar(UTF8Decode(Result)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, FILE_FLAG_BACKUP_SEM, 0);
  if h <> THandle(-1) then
  begin
    if FinalPathOfHandle(h, s) then
      Result := s;
    CloseHandle(h);
    Exit;
  end;
  // fichier a creer: canoniser le DOSSIER parent, garder le nom
  dir := ExcludeTrailingPathDelimiter(ExtractFilePath(Result));
  name := ExtractFileName(Result);
  if (dir = '') or (name = '') then Exit;
  h := CreateFileW(PWideChar(UTF8Decode(dir)), 0, SHARE_ALL, nil,
    OPEN_EXISTING_W, FILE_FLAG_BACKUP_SEM, 0);
  if h <> THandle(-1) then
  begin
    if FinalPathOfHandle(h, s) then
      Result := IncludeTrailingPathDelimiter(s) + name;
    CloseHandle(h);
  end;
end;

function ExclusiveCreate(const AName: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(AName)), GENERIC_WRITE_W, 0,
    nil, CREATE_NEW_W, FILE_ATTR_NORMAL, 0);
end;

function FlushToDisk(AHandle: THandle): Boolean;
begin
  Result := FlushFileBuffers(AHandle);
end;

// Reporte la DACL de l'original sur le temporaire, pour un rename qui ne la
// preserverait pas. False = droits non garantis: ne pas publier.
function CopyDacl(const AFrom, ATo: string): Boolean;
var
  needed: LongWord;
  buf: array of Byte;
begin
  Result := False;
  needed := 0;
  GetFileSecurityW(PWideChar(UTF8Decode(AFrom)), DACL_SECURITY_INFO, nil, 0,
    needed);
  if needed = 0 then Exit;
  SetLength(buf, needed);
  if not GetFileSecurityW(PWideChar(UTF8Decode(AFrom)), DACL_SECURITY_INFO,
       @buf[0], needed, needed) then Exit;
  Result := SetFileSecurityW(PWideChar(UTF8Decode(ATo)), DACL_SECURITY_INFO,
    @buf[0]);
end;

function ReplaceByRename(const ATmp, ADest: string): Boolean;
begin
  if FileExists(ADest) then
  begin
    // SANS le drapeau IGNORE_MERGE_ERRORS: avec lui, ReplaceFileW peut
    // reussir sans reporter l'ACL de la cible, et un document protege par
    // des droits particuliers ressortirait en silence avec ceux du dossier.
    if ReplaceFileW(PWideChar(UTF8Decode(ADest)), PWideChar(UTF8Decode(ATmp)),
        nil, 0, nil, nil) then
      Exit(True);
    // Repli MoveFileExW (montages sans ReplaceFile): seulement une fois la
    // DACL de la cible posee sur le temporaire, sinon echec FRANC plutot
    // qu'une protection perdue. PIEGE: un ReplaceFileW interrompu peut avoir
    // deja supprime la cible; il ne reste alors rien a preserver et refuser
    // laisserait le document SANS fichier -- le rename doit conclure.
    if (not CopyDacl(ADest, ATmp)) and FileExists(ADest) then
      Exit(False);
  end;
  Result := MoveFileExW(PWideChar(UTF8Decode(ATmp)),
    PWideChar(UTF8Decode(ADest)),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_COPY_ALLOWED);
end;

{$ELSE}

function HasHardLinks(const APath: string): Boolean;
var
  st: Stat;
begin
  // fpStat suit les symlinks: on teste la cible reelle
  Result := (fpStat(PChar(APath), st) = 0) and (st.st_nlink > 1);
end;

function FileIdentity(const APath: string; out ADev, AIno: Int64): Boolean;
var
  st: Stat;
begin
  ADev := 0;
  AIno := 0;
  Result := fpStat(PChar(APath), st) = 0;
  if Result then
  begin
    ADev := Int64(st.st_dev);
    AIno := Int64(st.st_ino);
  end;
end;

function ResolveLink(const APath: string): string;
var
  st: Stat;
  lnk: string;
  i: Integer;
begin
  Result := APath;
  for i := 1 to 8 do // chaines de liens bornees
  begin
    if fpLStat(PChar(Result), st) <> 0 then
      Exit; // n'existe pas (encore): cible de creation legitime
    if not fpS_ISLNK(st.st_mode) then
      Exit;
    lnk := fpReadLink(Result);
    if lnk = '' then
      raise EStreamError.CreateFmt('Cannot resolve link %s', [Result]);
    if lnk[1] <> '/' then
      lnk := ExpandFileName(ExtractFilePath(Result) + lnk); // lien relatif
    Result := lnk;
  end;
  if (fpLStat(PChar(Result), st) = 0) and fpS_ISLNK(st.st_mode) then
    raise EStreamError.CreateFmt('Too many symlink levels resolving %s', [APath]);
end;

// realpath(3): la libc resout tous les segments, ce que fpReadLink sur le
// dernier ne fait pas. Tampon >= PATH_MAX partout (4096 Linux, 1024 macOS).
function c_realpath(AName, AResolved: PChar): PChar; cdecl;
  external 'c' name 'realpath';

function CanonicalPathKey(const APath: string): string;
var
  buf: array[0..4096] of Char;
  dir, name: string;
begin
  Result := ExpandFileName(APath);
  if c_realpath(PChar(Result), @buf[0]) <> nil then
    Exit(string(PChar(@buf[0])));
  // fichier a creer: realpath echoue sur un segment absent, mais le dossier
  // parent, lui, existe -- canoniser le dossier et garder le nom
  dir := ExcludeTrailingPathDelimiter(ExtractFilePath(Result));
  name := ExtractFileName(Result);
  if (dir <> '') and (name <> '') and
     (c_realpath(PChar(dir), @buf[0]) <> nil) then
    Result := IncludeTrailingPathDelimiter(string(PChar(@buf[0]))) + name;
end;

function FlushToDisk(AHandle: THandle): Boolean;
begin
  Result := fpfsync(cint(AHandle)) = 0;
end;

function ExclusiveCreate(const AName: string): THandle;
begin
  Result := THandle(FpOpen(PChar(AName), O_WRONLY or O_CREAT or O_EXCL, &600));
end;

function ReplaceByRename(const ATmp, ADest: string): Boolean;
var
  st: Stat;
  hasMeta: Boolean;
  um: TMode;
begin
  hasMeta := fpStat(PChar(ADest), st) = 0; // metadonnees de l'original
  Result := RenameFile(ATmp, ADest);       // rename POSIX = atomique
  if not Result then Exit;
  if hasMeta then
  begin
    // chown PUIS chmod: un chown efface setuid/setgid sur la plupart des systemes
    fpChown(PChar(ADest), st.st_uid, st.st_gid);
    fpChmod(PChar(ADest), st.st_mode and $0FFF);
  end
  else
  begin
    // fichier neuf: le temp est ne en 0600, on finit en creation normale
    um := fpUmask(0);
    fpUmask(um); // lire l'umask oblige a l'ecraser: on le remet aussitot
    fpChmod(PChar(ADest), TMode(&666) and not um);
  end;
end;

{$ENDIF}

function ReplaceByRenamePrivate(const ATmp, ADest: string): Boolean;
begin
  {$IFDEF UNIX}
  // aucune preservation de mode: un 0644 herite ne survit pas a la reecriture
  Result := RenameFile(ATmp, ADest);
  if Result then
    fpChmod(PChar(ADest), &600);
  {$ELSE}
  Result := ReplaceByRename(ATmp, ADest);
  {$ENDIF}
end;

procedure MakePrivateFile(const APath: string);
begin
  if APath = '' then Exit;
  {$IFDEF UNIX}
  fpChmod(PChar(APath), &600); // rattrapage best effort
  {$ENDIF}
end;

procedure MakePrivateDir(const APath: string);
begin
  if APath = '' then Exit;
  {$IFDEF UNIX}
  fpChmod(PChar(ExcludeTrailingPathDelimiter(APath)), &700);
  {$ENDIF}
end;

procedure WriteInPlaceKeepLinks(const APath, AData: string);
var
  net: TOwnedHandleStream;
  fs: TFileStream;
  tmp: string;
begin
  // filet: contenu complet ecrit d'abord dans un temp, conserve et remonte
  // dans l'erreur si l'ecriture sur place echoue
  net := CreateTempIn(APath, tmp);
  try
    try
      if AData <> '' then
        WriteAllBuf(net, AData);
    finally
      net.Free;
    end;
  except
    DeleteFile(tmp);
    raise;
  end;
  try
    // fmCreate tronquerait la cible avant reecriture: une coupure laisserait tous
    // les hardlinks vides. On reecrit en place, la taille est posee en dernier.
    fs := TFileStream.Create(APath, fmOpenReadWrite);
    try
      if AData <> '' then
        WriteAllBuf(fs, AData);
      fs.Size := Length(AData);
    finally
      fs.Free;
    end;
  except
    on E: Exception do
      raise EStreamError.CreateFmt(
        'Writing %s failed (%s).' + LineEnding +
        'The target may be PARTIALLY WRITTEN; your full content was preserved in:' +
        LineEnding + '%s', [APath, E.Message, tmp]);
  end;
  DeleteFile(tmp);
end;

procedure SavePrivateFile(const APath, AData: string);
var
  net: TOwnedHandleStream;
  tmp: string;
begin
  net := CreateTempIn(APath, tmp);
  try
    try
      if AData <> '' then
        WriteAllBuf(net, AData);
    finally
      net.Free;
    end;
    if not ReplaceByRenamePrivate(tmp, APath) then
      raise EStreamError.CreateFmt('Cannot replace %s', [APath]);
  except
    DeleteFile(tmp);
    raise;
  end;
end;

procedure SavePrivateStream(const APath: string; ASrc: TStream);
var
  net: TOwnedHandleStream;
  tmp: string;
begin
  net := CreateTempIn(APath, tmp);
  try
    try
      // CopyFrom a 0: FPC repart du debut de la source
      if ASrc.Size > 0 then
        net.CopyFrom(ASrc, 0);
    finally
      net.Free;
    end;
    if not ReplaceByRenamePrivate(tmp, APath) then
      raise EStreamError.CreateFmt('Cannot replace %s', [APath]);
  except
    DeleteFile(tmp);
    raise;
  end;
end;

function CreateTempIn(const ADest: string; out ATmpName: string): TOwnedHandleStream;
var
  i: Integer;
  h: THandle;
begin
  for i := 1 to 20 do
  begin
    ATmpName := Format('%s.rssh%.8x%.4x.tmp',
      [ADest, LongWord(GetTickCount64), Random($10000)]);
    h := ExclusiveCreate(ATmpName);
    if h <> THandle(-1) then
      Exit(TOwnedHandleStream.Create(h));
  end;
  ATmpName := '';
  raise EStreamError.CreateFmt('Cannot create temp file near %s', [ADest]);
end;

initialization
  Randomize;

end.
