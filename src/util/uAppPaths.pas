unit uAppPaths;

{$mode objfpc}{$H+}

// Repertoires applicatifs par plateforme. Le dossier recovery accueille les
// copies de travail: permissions privees, un sous-dossier par processus.

interface

function AppDataDir: string;
function RecoveryRootDir: string;
function InstanceRecoveryDir: string;
function InstanceDirName: string;
function InstanceDirIsDead(const ADir: string): Boolean;
procedure ReleaseInstanceRecovery;
// Verrou CONSULTATIF sur un temoin de <app-data>/locks, pas sur le .rsh (la RTL
// flock deja tout fichier ouvert). -1 sans AHeldByOther: on passe outre.
function TryLockDocument(const APath: string; out AHeldByOther: Boolean): THandle;
function DocumentLockPath(const APath: string): string;
procedure UnlockFile(AHandle: THandle);
// Windows seulement: effacer un temoin tenu par flock casserait l'exclusion.
procedure PurgeStaleDocumentLocks;

implementation

uses
  SysUtils, sha1, uVersion, uSafeSave, uRsUtil
  {$IFDEF UNIX}, BaseUnix, ctypes{$ENDIF};

{$IF DEFINED(UNIX) AND NOT DEFINED(DARWIN)}
// BaseUnix/Linux ne transcrit pas les types de verrou de <fcntl.h>, Darwin si.
type
  TFlock = BaseUnix.FLock;
const
  F_WRLCK = 1;
{$ENDIF}

{$IFDEF WINDOWS}
const
  // les deux seules erreurs qui valent « verrou detenu ailleurs »
  ERROR_SHARING_VIOLATION_ = 32;
  ERROR_LOCK_VIOLATION_ = 33;

function GetLastError: LongWord; stdcall; external 'kernel32.dll';
{$ENDIF}

var
  GInstanceUuid: string = '';
  GInstanceLock: THandle = THandle(-1);

const
  INSTANCE_LOCK_NAME = '.lock';

function AppDataDir: string;
{$IFDEF DARWIN}
begin
  Result := GetEnvironmentVariable('HOME') +
    '/Library/Application Support/' + RSSH_APP_NAME;
end;
{$ELSE}
{$IFDEF WINDOWS}
begin
  Result := GetEnvironmentVariable('APPDATA') + '\' + RSSH_APP_NAME;
end;
{$ELSE}
var
  base: string;
begin
  base := GetEnvironmentVariable('XDG_DATA_HOME');
  if base = '' then
    base := GetEnvironmentVariable('HOME') + '/.local/share';
  Result := base + '/' + RSSH_APP_NAME;
end;
{$ENDIF}
{$ENDIF}

procedure EnsurePrivateDir(const APath: string);
begin
  if not DirectoryExists(APath) then
    if not ForceDirectories(APath) then
      raise Exception.Create('cannot create directory: ' + APath);
  MakePrivateDir(APath);
end;

function RecoveryRootDir: string;
begin
  Result := AppDataDir + PathDelim + 'recovery';
  EnsurePrivateDir(AppDataDir);
  EnsurePrivateDir(Result);
end;

function TryLockFile(const APath: string): THandle;
{$IFDEF UNIX}
var
  fd: cint;
  fl: TFlock;
begin
  Result := THandle(-1);
  fd := FpOpen(APath, O_RDWR or O_CREAT, &600);
  if fd < 0 then Exit;
  // le noyau relache a la mort du processus: un crash rend le dossier « mort »
  FillChar(fl, SizeOf(fl), 0);
  fl.l_type := F_WRLCK;
  fl.l_whence := SEEK_SET;
  fl.l_start := 0;
  fl.l_len := 0;
  if FpFcntl(fd, F_SETLK, fl) <> -1 then
    Result := THandle(fd)
  else
    FpClose(fd);
end;
{$ELSE}
begin
  Result := FileOpen(APath, fmOpenReadWrite or fmShareExclusive);
  if Result = THandle(-1) then
    Result := FileCreate(APath, fmShareExclusive, &600);
end;
{$ENDIF}

{$IFDEF UNIX}
const
  LOCK_EX_ = 2;
  LOCK_NB_ = 4;

function c_flock(fd, operation: cint): cint; cdecl; external 'c' name 'flock';

// Sous Linux la RTL FPC tient son propre errno: fpgeterrno rend du perime ici.
{$IFDEF LINUX}
function __errno_location: pcint; cdecl; external 'c' name '__errno_location';
function CLibErrno: cint; inline;
begin
  Result := __errno_location^;
end;
{$ELSE}
function CLibErrno: cint; inline;
begin
  Result := fpgeterrno;
end;
{$ENDIF}
{$ENDIF}

function DocumentLockPath(const APath: string): string;
var
  canon, dir: string;
begin
  Result := '';
  if APath = '' then Exit;
  try
    canon := ExpandFileName(ResolveLink(ExpandFileName(APath)));
  except
    on E: Exception do
      canon := ExpandFileName(APath);
  end;
  {$IFDEF WINDOWS}
  canon := LowerCase(canon);
  {$ENDIF}
  try
    dir := AppDataDir + PathDelim + 'locks';
    EnsurePrivateDir(AppDataDir);
    EnsurePrivateDir(dir);
  except
    on E: Exception do
      Exit('');
  end;
  Result := dir + PathDelim + SHA1Print(SHA1String(canon)) + '.lock';
end;

function TryLockDocument(const APath: string; out AHeldByOther: Boolean): THandle;
{$IFDEF UNIX}
var
  fd: cint;
  lockPath: string;
begin
  Result := THandle(-1);
  AHeldByOther := False;
  lockPath := DocumentLockPath(APath);
  if lockPath = '' then Exit;
  fd := FpOpen(lockPath, O_RDWR or O_CREAT, &600);
  if fd < 0 then Exit;
  // flock et NON fcntl: un verrou POSIX tombe au premier fd ferme sur le fichier
  if c_flock(fd, LOCK_EX_ or LOCK_NB_) = 0 then
    Result := THandle(fd)
  else
  begin
    AHeldByOther := (CLibErrno = ESysEWOULDBLOCK) or (CLibErrno = ESysEAGAIN);
    FpClose(fd);
  end;
end;
{$ELSE}
var
  lockPath: string;
  err: LongWord;
begin
  Result := THandle(-1);
  AHeldByOther := False;
  lockPath := DocumentLockPath(APath);
  if lockPath = '' then Exit;
  if not FileExists(lockPath) then
  begin
    Result := FileCreate(lockPath, fmShareExclusive, &600);
    if Result <> THandle(-1) then Exit;
  end;
  Result := FileOpen(lockPath, fmOpenReadWrite or fmShareExclusive);
  // fail-OPEN: un antivirus sur le temoin ne doit pas bloquer tous les documents
  if Result = THandle(-1) then
  begin
    err := GetLastError;
    AHeldByOther := (err = ERROR_SHARING_VIOLATION_) or
                    (err = ERROR_LOCK_VIOLATION_);
  end;
end;
{$ENDIF}

procedure UnlockFile(AHandle: THandle);
begin
  if AHandle = THandle(-1) then Exit;
  {$IFDEF UNIX}
  FpClose(AHandle);
  {$ELSE}
  FileClose(AHandle);
  {$ENDIF}
end;

procedure PurgeStaleDocumentLocks;
{$IFDEF WINDOWS}
var
  dir: string;
  sr: TSearchRec;
begin
  try
    dir := AppDataDir + PathDelim + 'locks';
  except
    Exit;
  end;
  if not DirectoryExists(dir) then Exit;
  if FindFirst(dir + PathDelim + '*.lock', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) = 0 then
        // echoue en silence sur un temoin detenu: seuls les orphelins partent
        DeleteFile(dir + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

function InstanceRecoveryDir: string;
begin
  if GInstanceUuid = '' then
    GInstanceUuid := NewUuid;
  Result := RecoveryRootDir + PathDelim + GInstanceUuid;
  EnsurePrivateDir(Result);
  if GInstanceLock = THandle(-1) then
  begin
    GInstanceLock := TryLockFile(Result + PathDelim + INSTANCE_LOCK_NAME);
    MakePrivateFile(Result + PathDelim + INSTANCE_LOCK_NAME);
  end;
end;

function InstanceDirName: string;
begin
  if GInstanceUuid = '' then
    GInstanceUuid := NewUuid;
  Result := GInstanceUuid;
end;

function InstanceDirIsDead(const ADir: string): Boolean;
var
  lockPath: string;
  h: THandle;
begin
  lockPath := ExcludeTrailingPathDelimiter(ADir) + PathDelim + INSTANCE_LOCK_NAME;
  if not FileExists(lockPath) then Exit(True);
  h := TryLockFile(lockPath);
  if h = THandle(-1) then
    Result := False   // verrou pris: un processus vit encore
  else
  begin
    Result := True;
    UnlockFile(h);
  end;
end;

procedure ReleaseInstanceRecovery;
var
  dir, lockPath: string;
begin
  if GInstanceUuid = '' then Exit;
  dir := RecoveryRootDir + PathDelim + GInstanceUuid;
  lockPath := dir + PathDelim + INSTANCE_LOCK_NAME;
  if GInstanceLock <> THandle(-1) then
  begin
    UnlockFile(GInstanceLock);
    GInstanceLock := THandle(-1);
  end;
  if FileExists(lockPath) then
    DeleteFile(lockPath);
  RemoveDir(dir);   // ne retire que s'il est vide
end;

end.
