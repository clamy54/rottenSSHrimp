unit uSafeSave;

{$mode objfpc}{$H+}

// Ecriture de fichiers sans fenetre de troncature, sans TOCTOU, sans casser
// les liens. Repris de RottenText.

interface

uses
  Classes, SysUtils{$IFDEF UNIX}, BaseUnix{$ENDIF};

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
function CreateTempIn(const ADest: string; out ATmpName: string): TOwnedHandleStream;
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
  REPLACEFILE_IGNORE_MERGE_ERRORS = 2;
  MOVEFILE_REPLACE_EXISTING = 1;
  MOVEFILE_COPY_ALLOWED     = 2;

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
function ReplaceFileW(lpReplaced, lpReplacement, lpBackup: PWideChar;
  dwFlags: LongWord; lpExclude, lpReserved: Pointer): LongBool;
  stdcall; external 'kernel32.dll';

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

function ResolveLink(const APath: string): string;
var
  attrs, n: LongWord;
  h: THandle;
  buf: array[0..4095] of WideChar;
  s: UnicodeString;
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
  n := GetFinalPathNameByHandleW(h, @buf[0], Length(buf), 0);
  CloseHandle(h);
  if (n = 0) or (n >= LongWord(Length(buf))) then
    raise EStreamError.CreateFmt('Cannot resolve link %s', [APath]);
  SetString(s, PWideChar(@buf[0]), n);
  // GetFinalPathNameByHandle prefixe en \\?\ (ou \\?\UNC\ pour le reseau)
  if Copy(s, 1, 8) = '\\?\UNC\' then
    s := '\\' + Copy(s, 9, MaxInt)
  else if Copy(s, 1, 4) = '\\?\' then
    s := Copy(s, 5, MaxInt);
  Result := UTF8Encode(s);
end;

function ExclusiveCreate(const AName: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(AName)), GENERIC_WRITE_W, 0,
    nil, CREATE_NEW_W, FILE_ATTR_NORMAL, 0);
end;

function ReplaceByRename(const ATmp, ADest: string): Boolean;
begin
  // ReplaceFileW preserve attributs/ACL de la cible mais exige qu'elle existe
  if FileExists(ADest) then
    if ReplaceFileW(PWideChar(UTF8Decode(ADest)), PWideChar(UTF8Decode(ATmp)),
        nil, REPLACEFILE_IGNORE_MERGE_ERRORS, nil, nil) then
      Exit(True);
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
