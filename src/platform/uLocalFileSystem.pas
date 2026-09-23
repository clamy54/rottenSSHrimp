{ Systeme de fichiers LOCAL de l'onglet Scp, derriere le contrat uScpBackend.

  Il repond aux particularites qui font trebucher ce genre d'outil: API W et
  prefixe \\?\ sous Windows, repertoire courant du PROCESSUS jamais deplace,
  volumes enumeres SANS etre sondes, temporaires crees en exclusif sous un nom
  imprevisible, et remplacement atomique reel.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uLocalFileSystem;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, uScpBackend, uScpErrors, uScpPaths
  {$IFDEF WINDOWS}, Windows{$ELSE}, BaseUnix, Unix{$ENDIF}
  {$IFDEF LINUX}, Syscall{$ENDIF};

type
  TLocalVolumeKind = (lvkFixed, lvkRemovable, lvkNetwork, lvkOptical,
    lvkRamDisk, lvkHome, lvkRoot, lvkOther);

  TLocalVolume = record
    Path: string;        // racine a ouvrir
    Caption: string;     // ce qui s'affiche dans le selecteur
    Kind: TLocalVolumeKind;
  end;

  TLocalVolumeArray = array of TLocalVolume;

  TLocalFileSystem = class(TScpFileSystem)
  private
    // Ecrit par le fil qui annule, lu par celui qui travaille: acces atomiques.
    FCancelFlag: LongInt;
    {$IFDEF WINDOWS}
    function EmptyDirByHandle(ADir: THandle; const APath: string;
      ADepth: Integer; out AErr: TScpError): Boolean;
    {$ELSE}
    function EmptyDirByFd(ADir: cint; const APath: string; ADepth: Integer;
      out AErr: TScpError): Boolean;
    {$ENDIF}
  public
    function IsRemote: Boolean; override;
    function DisplayName: string; override;
    function Canceled: Boolean; override;
    procedure Cancel;
    procedure ResetCancel;

    function HomeDir(out APath: string; out AErr: TScpError): Boolean; override;
    function RealPath(const APath: string; out AResolved: string;
      out AErr: TScpError): Boolean; override;
    function List(const APath: string; out AEntries: TScpEntryArray;
      out AErr: TScpError): Boolean; override;
    function Stat(const APath: string; AFollowLink: Boolean;
      out AEntry: TScpEntry; out AErr: TScpError): Boolean; override;
    function Exists(const APath: string; out AFound: Boolean;
      out AErr: TScpError): Boolean; override;
    function MakeDir(const APath: string; AMode: LongWord;
      out AErr: TScpError): Boolean; override;
    function Rename(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; override;
    function ReplaceAtomic(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; override;
    function DeleteFile(const APath: string;
      out AErr: TScpError): Boolean; override;
    function DeleteDir(const APath: string;
      out AErr: TScpError): Boolean; override;
    function OpenRead(const APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function CreateTemp(const ADir: string; AMode: LongWord;
      out APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function OpenAppend(const APath: string; AOffset: Int64;
      out AHandle: TScpFileHandle; out AErr: TScpError): Boolean; override;
    function Read(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out AGot: Integer; out AErr: TScpError): Boolean; override;
    function Write(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out APut: Integer; out AErr: TScpError): Boolean; override;
    function Seek(AHandle: TScpFileHandle; AOffset: Int64;
      out AErr: TScpError): Boolean; override;
    function Flush(AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function Close(AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function SetMTime(AHandle: TScpFileHandle; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; override;
    function SetMode(AHandle: TScpFileHandle; AMode: LongWord;
      out AErr: TScpError): Boolean; override;
    // Suppression recursive ANCREE: une fois le dossier ouvert, ses enfants sont
    // ouverts et retires relativement a lui. Un dossier remplace par un lien en
    // cours de route n'envoie pas la suppression dans sa cible. Un lien, meme
    // vers un dossier, part seul.
    function RemoveTree(const APath: string; out AErr: TScpError): Boolean;
    function CopyProtectionFrom(const ASourcePath, ATargetPath: string;
      out AErr: TScpError): Boolean; override;
    function Join(const ABase, AName: string): string; override;
    function Parent(const APath: string): string; override;
    function BaseName(const APath: string): string; override;
    function Normalize(const APath: string): string; override;
    function IsUnder(const ARoot, APath: string): Boolean; override;
    function CheckName(const AName: string): TNameVerdict; override;
    function CollisionKey(const AName: string): string; override;
  end;

// Lecteurs et volumes, SANS interroger le moindre peripherique. Un partage
// hors ligne y figure avec son type et ne fige rien: c'est a l'ouverture que
// l'erreur survient.
function EnumerateLocalVolumes: TLocalVolumeArray;
function LocalHomePath: string;

implementation

uses
  uSodiumApi;

const
  {$IFDEF WINDOWS}
  // Absent de l'unite Windows de FPC 3.2, valeur de winbase.h: l'appel n'aboutit
  // qu'une fois l'operation SUR LE SUPPORT, ce qui la fait survivre a une coupure.
  MOVEFILE_WRITE_THROUGH_ = $00000008;
  FILE_TYPE_DISK_ = $0001;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
  // Ouvertures relatives a un dossier (ntdll) et suppression par poignee.
  DELETE_ = $00010000;
  SYNCHRONIZE_ = $00100000;
  FILE_READ_ATTRIBUTES_ = $0080;
  FILE_LIST_DIRECTORY_ = $0001;
  FILE_SHARE_DELETE_ = $0004;
  FILE_OPEN_REPARSE_POINT_ = $00200000;
  FILE_OPEN_FOR_BACKUP_INTENT_ = $00004000;
  FILE_SYNCHRONOUS_IO_NONALERT_ = $00000020;
  OBJ_CASE_INSENSITIVE_ = $00000040;
  FileDispositionInfo_ = 4;
  FileIdBothDirectoryInfo_ = 10;
  FileIdBothDirectoryRestartInfo_ = 11;
  PROTECTED_DACL_SECURITY_INFORMATION_ = $80000000;
  UNPROTECTED_DACL_SECURITY_INFORMATION_ = $20000000;
  SE_DACL_PROTECTED_ = $1000;
  FILE_ATTRIBUTE_NOT_CONTENT_INDEXED_ = $2000;
  LOCAL_MAX_RM_DEPTH = 64;
  {$ELSE}
  LOCAL_MAX_RM_DEPTH = 64;
  {$IFDEF LINUX}
  O_CLOEXEC_ = $80000;
  AT_REMOVEDIR_ = $200;
  UTIME_OMIT_ = (1 shl 30) - 2;
  {$ELSE}
  O_CLOEXEC_ = $1000000;
  AT_REMOVEDIR_ = $80;
  UTIME_OMIT_ = -2;
  {$ENDIF}
  {$ENDIF}
  {$IFDEF LINUX}
  // renameat2 n'est pas enveloppe par FPC 3.2: numero d'appel par architecture.
  // Sans numero connu, la reservation exclusive prend le relais.
  {$IF DEFINED(CPUX86_64)}
  SYSCALL_RENAMEAT2 = 316; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUAARCH64)}
  SYSCALL_RENAMEAT2 = 276; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUI386)}
  SYSCALL_RENAMEAT2 = 353; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUARM)}
  SYSCALL_RENAMEAT2 = 382; {$DEFINE RSSH_RENAMEAT2}
  {$ENDIF}
  AT_FDCWD_ = -100;
  RENAME_NOREPLACE_ = 1;
  {$ENDIF}
  {$IFDEF DARWIN}
  // renamex_np n'est pas enveloppe par FPC 3.2: drapeau de <sys/stdio.h>.
  RENAME_EXCL_ = 4;
  {$ENDIF}

  // Prefixe des temporaires, reconnaissable a l'oeil: un partiel laisse par un
  // plantage doit se comprendre sans explication.
  TEMP_PREFIX = '.rssh-';
  TEMP_SUFFIX = '.part';
  // Assez d'aleas pour que le nom soit imprevisible, donc impossible a devancer
  // par un lien.
  TEMP_RANDOM_BYTES = 12;

type
  TLocalHandle = class(TScpFileHandle)
    {$IFDEF WINDOWS}
    H: Windows.THandle;
    {$ELSE}
    Fd: cint;
    {$ENDIF}
    Path: string;
  end;

{$IFDEF WINDOWS}
{$PACKRECORDS C}
type
  TNtUnicodeString = record
    Length, MaximumLength: Word;
    Buffer: PWideChar;
  end;
  PNtUnicodeString = ^TNtUnicodeString;
  TNtObjectAttributes = record
    Length: ULONG;
    RootDirectory: THandle;
    ObjectName: PNtUnicodeString;
    Attributes: ULONG;
    SecurityDescriptor: Pointer;
    SecurityQualityOfService: Pointer;
  end;
  TNtIoStatusBlock = record
    Status: PtrInt;
    Information: PtrUInt;
  end;
  TFileDispositionInfo = record
    DeleteFile: ByteBool;
  end;
  // FILE_ID_BOTH_DIR_INFO de winbase.h.
  TFileIdBothDirInfo = record
    NextEntryOffset: DWORD;
    FileIndex: DWORD;
    CreationTime, LastAccessTime, LastWriteTime, ChangeTime: Int64;
    EndOfFile, AllocationSize: Int64;
    FileAttributes: DWORD;
    FileNameLength: DWORD;
    EaSize: DWORD;
    ShortNameLength: Byte;
    ShortName: array[0..11] of WideChar;
    FileId: Int64;
    FileName: array[0..0] of WideChar;
  end;
  PFileIdBothDirInfo = ^TFileIdBothDirInfo;
{$PACKRECORDS DEFAULT}

// Absents de l'unite Windows de FPC 3.2. NtOpenFile est le seul moyen d'ouvrir
// un nom RELATIVEMENT a une poignee de dossier.
function NtOpenFile(FileHandle: PHandle; DesiredAccess: DWORD;
  ObjectAttributes: Pointer; IoStatusBlock: Pointer; ShareAccess: ULONG;
  OpenOptions: ULONG): LongInt; stdcall; external 'ntdll' name 'NtOpenFile';
function RtlNtStatusToDosError(Status: LongInt): ULONG; stdcall;
  external 'ntdll' name 'RtlNtStatusToDosError';
function GetFileInformationByHandleEx(hFile: THandle;
  FileInformationClass: DWORD; lpFileInformation: Pointer;
  dwBufferSize: DWORD): BOOL; stdcall;
  external 'kernel32' name 'GetFileInformationByHandleEx';
function SetFileInformationByHandle(hFile: THandle;
  FileInformationClass: DWORD; lpFileInformation: Pointer;
  dwBufferSize: DWORD): BOOL; stdcall;
  external 'kernel32' name 'SetFileInformationByHandle';
function ConvertSidToStringSidW(Sid: Pointer; var StringSid: PWideChar): BOOL;
  stdcall; external 'advapi32' name 'ConvertSidToStringSidW';
function ConvertStringSecurityDescriptorToSecurityDescriptorW(
  StringSecurityDescriptor: PWideChar; StringSDRevision: DWORD;
  var SecurityDescriptor: Pointer; SecurityDescriptorSize: PULONG): BOOL;
  stdcall; external 'advapi32'
  name 'ConvertStringSecurityDescriptorToSecurityDescriptorW';

const
  SDDL_REVISION_1_ = 1;

// Un mode que les « autres » ne peuvent pas lire est PRIVE. Windows n'a pas de
// groupe a qui donner les bits du milieu: les donner a tous elargirait, les
// retirer ne fait que restreindre.
function ModeIsPrivate(AMode: LongWord): Boolean;
begin
  Result := (AMode and LongWord(&0004)) = 0;
end;

// Descripteur d'un fichier ou d'un dossier PRIVE: l'utilisateur courant,
// SYSTEM et les administrateurs, heritage du parent coupe -- le plus proche
// d'un 0700, root compris. Pose A LA CREATION, par CreateFileW ou
// CreateDirectoryW: pas d'instant ou le parent decide. nil s'il n'a pas pu
// etre construit; a liberer par LocalFree.
function PrivateSecurityDescriptor(AInheritable: Boolean): Pointer;
var
  token: THandle;
  need: DWORD;
  buf: array of Byte;
  sidText: PWideChar;
  flags, sddl: UnicodeString;
begin
  Result := nil;
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, token) then Exit;
  try
    need := 0;
    GetTokenInformation(token, TokenUser, nil, 0, need);
    if need = 0 then Exit;
    SetLength(buf, need);
    if not GetTokenInformation(token, TokenUser, @buf[0], need, need) then
      Exit;
  finally
    CloseHandle(token);
  end;
  sidText := nil;
  // TOKEN_USER commence par le pointeur vers le SID.
  if not ConvertSidToStringSidW(PPointer(@buf[0])^, sidText) then Exit;
  try
    if AInheritable then flags := 'OICI' else flags := '';
    sddl := 'D:P(A;' + flags + ';FA;;;' + UnicodeString(sidText) + ')' +
      '(A;' + flags + ';FA;;;SY)(A;' + flags + ';FA;;;BA)';
  finally
    LocalFree(HLOCAL(sidText));
  end;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorW(
     PWideChar(sddl), SDDL_REVISION_1_, Result, nil) then
    Result := nil;
end;
{$ELSE}
// Non enveloppes par FPC 3.2: appel direct sous Linux, libc ailleurs.
{$IFDEF LINUX}
function OpenDirAt(ADir: cint; const AName: string): cint;
begin
  Result := do_syscall(syscall_nr_openat, TSysParam(ADir),
    TSysParam(PChar(AName)),
    TSysParam(O_RDONLY or O_NOFOLLOW or O_DIRECTORY or O_CLOEXEC_),
    TSysParam(0));
end;

function UnlinkAt(ADir: cint; const AName: string; AIsDir: Boolean): cint;
var
  flags: cint;
begin
  flags := 0;
  if AIsDir then flags := AT_REMOVEDIR_;
  Result := do_syscall(syscall_nr_unlinkat, TSysParam(ADir),
    TSysParam(PChar(AName)), TSysParam(flags));
end;

function FChmod(AFd: cint; AMode: LongWord): cint;
begin
  Result := do_syscall(syscall_nr_fchmod, TSysParam(AFd), TSysParam(AMode));
end;

function FUTimens(AFd: cint; ATimes: Pointer): cint;
begin
  // utimensat sans chemin agit sur le descripteur: c'est futimens.
  Result := do_syscall(syscall_nr_utimensat, TSysParam(AFd), TSysParam(nil),
    TSysParam(ATimes), TSysParam(0));
end;
{$ELSE}
function openat(dirfd: cint; path: PChar; flags: cint): cint; cdecl; varargs;
  external 'c' name 'openat';
function unlinkat(dirfd: cint; path: PChar; flags: cint): cint; cdecl;
  external 'c' name 'unlinkat';
function fchmod(fd: cint; mode: cuint): cint; cdecl; external 'c' name 'fchmod';
function futimens(fd: cint; times: Pointer): cint; cdecl;
  external 'c' name 'futimens';

function OpenDirAt(ADir: cint; const AName: string): cint;
begin
  Result := openat(ADir, PChar(AName),
    O_RDONLY or O_NOFOLLOW or O_DIRECTORY or O_CLOEXEC_);
end;

function UnlinkAt(ADir: cint; const AName: string; AIsDir: Boolean): cint;
var
  flags: cint;
begin
  flags := 0;
  if AIsDir then flags := AT_REMOVEDIR_;
  Result := unlinkat(ADir, PChar(AName), flags);
end;

function FChmod(AFd: cint; AMode: LongWord): cint;
begin
  Result := fchmod(AFd, cuint(AMode));
end;

function FUTimens(AFd: cint; ATimes: Pointer): cint;
begin
  Result := futimens(AFd, ATimes);
end;
{$ENDIF}

// Le nom designe-t-il ENCORE le dossier qu'on a vide? Rouvert et compare par
// peripherique et inode juste avant unlinkat: un dossier vide glisse a sa
// place serait sinon supprime. Cela resserre la fenetre sans la fermer --
// POSIX ne retire pas un dossier par son descripteur, contrairement a la
// suppression par poignee de Windows.
function SameDirAt(ADir: cint; const AName: string; const AWant: Stat): Boolean;
var
  fd: cint;
  st: Stat;
begin
  fd := OpenDirAt(ADir, AName);
  if fd < 0 then Exit(False);
  try
    Result := (fpFStat(fd, st) = 0) and (st.st_dev = AWant.st_dev) and
      (st.st_ino = AWant.st_ino);
  finally
    fpClose(fd);
  end;
end;
{$ENDIF}

function RandomSuffix: string;
const
  HexD: array[0..15] of Char = '0123456789abcdef';
var
  b: array[0..TEMP_RANDOM_BYTES - 1] of Byte;
  i: Integer;
begin
  // Le generateur du projet: un Random() de la RTL rouvrirait la course.
  SodiumEnsureLoaded;
  randombytes_buf(@b[0], TEMP_RANDOM_BYTES);
  SetLength(Result, TEMP_RANDOM_BYTES * 2);
  for i := 0 to TEMP_RANDOM_BYTES - 1 do
  begin
    Result[i * 2 + 1] := HexD[b[i] shr 4];
    Result[i * 2 + 2] := HexD[b[i] and $0F];
  end;
end;

{$IFDEF WINDOWS}

function W(const S: string): UnicodeString; inline;
begin
  Result := UTF8Decode(S);
end;

function U(const S: UnicodeString): string; inline;
begin
  Result := UTF8Encode(S);
end;

function NativeW(const APath: string): UnicodeString; inline;
begin
  Result := W(LocalNativePath(APath));
end;

function LastErr(const AOp, ASubject: string): TScpError;
var
  code: Integer;
begin
  code := Integer(GetLastError);
  Result := MakeScpError(OsErrorToKind(code), AOp, DisplaySafeName(ASubject),
    Format('Windows error %d', [code]));
end;

function FileTimeToUnix(const AFt: TFileTime): Int64;
const
  EPOCH_DIFF = Int64(11644473600);
  UNITS_PER_SEC = Int64(10000000);
var
  v: Int64;
begin
  v := (Int64(AFt.dwHighDateTime) shl 32) or Int64(LongWord(AFt.dwLowDateTime));
  Result := (v div UNITS_PER_SEC) - EPOCH_DIFF;
end;

function UnixToFileTime(AUnix: Int64): TFileTime;
const
  EPOCH_DIFF = Int64(11644473600);
  UNITS_PER_SEC = Int64(10000000);
var
  v: Int64;
begin
  v := (AUnix + EPOCH_DIFF) * UNITS_PER_SEC;
  Result.dwLowDateTime := LongWord(v and $FFFFFFFF);
  Result.dwHighDateTime := LongWord(v shr 32);
end;

// Attributs Win32 -> entree. Le mode Unix est SYNTHETISE: il n'existe pas ici,
// mais la colonne doit dire quelque chose de vrai.
procedure FillEntryFromAttrs(var AEntry: TScpEntry; AAttrs: LongWord;
  ASizeHigh, ASizeLow: LongWord; const AMTime: TFileTime);
begin
  AEntry.IsDir := (AAttrs and FILE_ATTRIBUTE_DIRECTORY) <> 0;
  AEntry.IsLink := (AAttrs and FILE_ATTRIBUTE_REPARSE_POINT) <> 0;
  AEntry.Hidden := (AAttrs and FILE_ATTRIBUTE_HIDDEN) <> 0;
  AEntry.ReadOnly := (AAttrs and FILE_ATTRIBUTE_READONLY) <> 0;
  AEntry.IsSpecial := False;
  if AEntry.IsDir then
    AEntry.Size := -1
  else
    AEntry.Size := (Int64(ASizeHigh) shl 32) or Int64(ASizeLow);
  AEntry.MTimeUtc := FileTimeToUnix(AMTime);
  if AEntry.IsDir then
    AEntry.Mode := &0040000 or &0755
  else if AEntry.ReadOnly then
    AEntry.Mode := &0100000 or &0444
  else
    AEntry.Mode := &0100000 or &0644;
  if AEntry.IsLink then
    AEntry.Mode := (AEntry.Mode and not LongWord(&0170000)) or &0120000;
  AEntry.ModeKnown := True;
end;

{$ELSE}

function LastErr(const AOp, ASubject: string): TScpError;
var
  code: Integer;
begin
  code := fpGetErrno;
  Result := MakeScpError(OsErrorToKind(code), AOp, DisplaySafeName(ASubject),
    Format('errno %d', [code]));
end;

procedure FillEntryFromStat(var AEntry: TScpEntry; const ASt: Stat);
begin
  AEntry.Mode := ASt.st_mode;
  AEntry.ModeKnown := True;
  AEntry.IsDir := ModeIsDir(ASt.st_mode);
  AEntry.IsLink := ModeIsLink(ASt.st_mode);
  AEntry.IsSpecial := ModeIsSpecial(ASt.st_mode);
  if AEntry.IsDir then
    AEntry.Size := -1
  else
    AEntry.Size := ASt.st_size;
  AEntry.MTimeUtc := ASt.st_mtime;
  AEntry.ReadOnly := (ASt.st_mode and &0200) = 0;
end;

{$ENDIF}

{ TLocalFileSystem }

function TLocalFileSystem.IsRemote: Boolean;
begin
  Result := False;
end;

function TLocalFileSystem.DisplayName: string;
begin
  Result := 'local';
end;

function TLocalFileSystem.Canceled: Boolean;
begin
  Result := InterlockedExchangeAdd(FCancelFlag, 0) <> 0;
end;

procedure TLocalFileSystem.Cancel;
begin
  InterlockedExchange(FCancelFlag, 1);
end;

procedure TLocalFileSystem.ResetCancel;
begin
  InterlockedExchange(FCancelFlag, 0);
end;

function TLocalFileSystem.HomeDir(out APath: string;
  out AErr: TScpError): Boolean;
begin
  APath := LocalHomePath;
  AErr := NoScpError;
  Result := APath <> '';
  if not Result then
    AErr := MakeScpError(sekNotFound, 'Locating', 'the home folder', '');
end;

function TLocalFileSystem.RealPath(const APath: string; out AResolved: string;
  out AErr: TScpError): Boolean;
begin
  // Resolution LEXICALE seulement: resoudre les liens donnerait un chemin
  // meconnaissable dans la barre d'adresse, et le confinement suit la jointure.
  AResolved := LocalNormalize(APath);
  AErr := NoScpError;
  Result := True;
end;

function TLocalFileSystem.List(const APath: string;
  out AEntries: TScpEntryArray; out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  fd: TWin32FindDataW;
  h: Windows.THandle;
  n: Integer;
  name: string;
  pattern: UnicodeString;
{$ELSE}
var
  d: pDir;
  de: pDirent;
  n: Integer;
  name, full: string;
  st: Stat;
{$ENDIF}
begin
  SetLength(AEntries, 0);
  AErr := NoScpError;
  n := 0;
  {$IFDEF WINDOWS}
  // Separateur ajoute APRES la conversion native, qui retirerait un separateur
  // final pose avant: le motif devenait « C:\dir* » et FindFirstFile listait le
  // PARENT, le dossier devenant son propre enfant.
  pattern := NativeW(APath);
  if (pattern <> '') and (pattern[Length(pattern)] <> '\') then
    pattern := pattern + '\';
  pattern := pattern + '*';
  h := FindFirstFileW(PWideChar(pattern), fd);
  if h = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Listing', APath);
    if AErr.Kind = sekAccessDeniedWrite then
      AErr.Kind := sekAccessDeniedDir;
    Exit(False);
  end;
  try
    repeat
      if Canceled then
      begin
        AErr := MakeScpError(sekCanceled, 'Listing', APath, '');
        Exit(False);
      end;
      name := U(UnicodeString(PWideChar(@fd.cFileName[0])));
      // '.' et '..' ne doivent jamais devenir manipulables.
      if (name = '.') or (name = '..') or (name = '') then Continue;
      if n >= SCP_MAX_DIR_ENTRIES then
      begin
        AErr := MakeScpError(sekOther, 'Listing', DisplaySafeName(APath),
          Format('more than %d entries', [SCP_MAX_DIR_ENTRIES]));
        Exit(False);
      end;
      SetLength(AEntries, n + 1);
      AEntries[n] := Default(TScpEntry);
      AEntries[n].Name := name;
      FillEntryFromAttrs(AEntries[n], fd.dwFileAttributes,
        fd.nFileSizeHigh, fd.nFileSizeLow, fd.ftLastWriteTime);
      Inc(n);
    until not FindNextFileW(h, fd);
    // FindNextFile rend aussi False sur une erreur d'E/S: sans ce test, un
    // dossier lu a moitie passerait pour complet.
    if GetLastError <> ERROR_NO_MORE_FILES then
    begin
      AErr := LastErr('Listing', APath);
      Exit(False);
    end;
  finally
    Windows.FindClose(h);
  end;
  {$ELSE}
  d := fpOpenDir(PChar(LocalNormalize(APath)));
  if d = nil then
  begin
    AErr := LastErr('Listing', APath);
    if AErr.Kind in [sekAccessDeniedWrite, sekAccessDeniedRead] then
      AErr.Kind := sekAccessDeniedDir;
    Exit(False);
  end;
  try
    repeat
      fpSetErrno(0);
      de := fpReadDir(d^);
      if de = nil then
      begin
        // readdir rend nil a la fin ET sur une erreur: seul errno les separe.
        if fpGetErrno <> 0 then
        begin
          AErr := LastErr('Listing', APath);
          Exit(False);
        end;
        Break;
      end;
      if Canceled then
      begin
        AErr := MakeScpError(sekCanceled, 'Listing', APath, '');
        Exit(False);
      end;
      name := string(de^.d_name);
      if (name = '.') or (name = '..') or (name = '') then Continue;
      if n >= SCP_MAX_DIR_ENTRIES then
      begin
        AErr := MakeScpError(sekOther, 'Listing', DisplaySafeName(APath),
          Format('more than %d entries', [SCP_MAX_DIR_ENTRIES]));
        Exit(False);
      end;
      full := LocalJoin(APath, name);
      SetLength(AEntries, n + 1);
      AEntries[n] := Default(TScpEntry);
      AEntries[n].Name := name;
      AEntries[n].Hidden := name[1] = '.';
      if fpLStat(PChar(full), st) = 0 then
        FillEntryFromStat(AEntries[n], st)
      else
      begin
        // Une entree aux attributs illisibles reste VISIBLE et marquee: l'effacer
        // serait mentir sur le contenu.
        AEntries[n].AttrsUnknown := True;
        AEntries[n].Size := -1;
      end;
      if AEntries[n].IsLink then
      begin
        AEntries[n].LinkTarget := fpReadLink(full);
        if fpStat(PChar(full), st) = 0 then
          AEntries[n].TargetIsDir := ModeIsDir(st.st_mode)
        else
          AEntries[n].BrokenLink := True;
      end;
      Inc(n);
    until False;
  finally
    fpCloseDir(d^);
  end;
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Stat(const APath: string; AFollowLink: Boolean;
  out AEntry: TScpEntry; out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  fad: TWin32FileAttributeData;
{$ELSE}
var
  st: Stat;
  rc: cint;
{$ENDIF}
begin
  AEntry := Default(TScpEntry);
  AErr := NoScpError;
  AEntry.Name := LocalBaseName(APath);
  {$IFDEF WINDOWS}
  // Win32 n'a pas de lstat, mais GetFileAttributesEx ne suit pas un point de
  // reparse pour l'attribut lui-meme. AFollowLink est donc sans effet, du cote
  // prudent: on ne suit jamais.
  if not GetFileAttributesExW(PWideChar(NativeW(APath)),
     GetFileExInfoStandard, @fad) then
  begin
    AErr := WithAccessContext(LastErr('Reading attributes of', APath), acDir);
    Exit(False);
  end;
  FillEntryFromAttrs(AEntry, fad.dwFileAttributes, fad.nFileSizeHigh,
    fad.nFileSizeLow, fad.ftLastWriteTime);
  {$ELSE}
  if AFollowLink then
    rc := fpStat(PChar(LocalNormalize(APath)), st)
  else
    rc := fpLStat(PChar(LocalNormalize(APath)), st);
  if rc <> 0 then
  begin
    AErr := WithAccessContext(LastErr('Reading attributes of', APath), acDir);
    Exit(False);
  end;
  FillEntryFromStat(AEntry, st);
  if AEntry.IsLink then
    AEntry.LinkTarget := fpReadLink(LocalNormalize(APath));
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Exists(const APath: string; out AFound: Boolean;
  out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  attrs: LongWord;
  code: Integer;
{$ELSE}
var
  st: Stat;
  code: Integer;
{$ENDIF}
begin
  AErr := NoScpError;
  AFound := False;
  {$IFDEF WINDOWS}
  attrs := GetFileAttributesW(PWideChar(NativeW(APath)));
  if attrs <> INVALID_FILE_ATTRIBUTES then
  begin
    AFound := True;
    Exit(True);
  end;
  code := Integer(GetLastError);
  // « Absent » est une reponse, pas une panne: les confondre ferait ecraser une
  // cible qu'on n'a pas su lire.
  if (code = 2) or (code = 3) then Exit(True);
  AErr := MakeScpError(OsErrorToKind(code), 'Checking',
    DisplaySafeName(APath), Format('Windows error %d', [code]));
  Result := False;
  {$ELSE}
  if fpLStat(PChar(LocalNormalize(APath)), st) = 0 then
  begin
    AFound := True;
    Exit(True);
  end;
  code := fpGetErrno;
  if (code = ESysENOENT) or (code = ESysENOTDIR) then Exit(True);
  AErr := MakeScpError(OsErrorToKind(code), 'Checking',
    DisplaySafeName(APath), Format('errno %d', [code]));
  Result := False;
  {$ENDIF}
end;

function TLocalFileSystem.MakeDir(const APath: string; AMode: LongWord;
  out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  sa: TSecurityAttributes;
  code: DWORD;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // Un mode ouvert herite de l'ACL du parent, comme tout dossier neuf ici; un
  // mode prive nait avec une DACL privee. Sans elle on ne cree pas.
  if not ModeIsPrivate(AMode) then
    Result := CreateDirectoryW(PWideChar(NativeW(APath)), nil)
  else
  begin
    sa.nLength := SizeOf(sa);
    sa.bInheritHandle := False;
    sa.lpSecurityDescriptor := PrivateSecurityDescriptor(True);
    if sa.lpSecurityDescriptor = nil then
    begin
      AErr := MakeScpError(sekOther, 'Creating folder', DisplaySafeName(APath),
        Format('private permissions could not be prepared (Windows error %d)',
          [GetLastError]));
      Exit(False);
    end;
    code := 0;
    try
      Result := CreateDirectoryW(PWideChar(NativeW(APath)), @sa);
      if not Result then code := GetLastError;
    finally
      LocalFree(HLOCAL(sa.lpSecurityDescriptor));
    end;
    // LocalFree a pu ecraser l'erreur que LastErr va lire.
    if not Result then SetLastError(code);
  end;
  {$ELSE}
  Result := fpMkdir(PChar(LocalNormalize(APath)), AMode and LongWord(&0777)) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Creating folder', APath);
end;

{$IFDEF DARWIN}
function renamex_np(AFrom, ATo: PChar; AFlags: cuint): cint; cdecl;
  external 'c' name 'renamex_np';
{$ENDIF}

function TLocalFileSystem.Rename(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
{$IFNDEF WINDOWS}
var
  code: Integer;
  f, t: string;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // SANS MOVEFILE_REPLACE_EXISTING: ce Rename n'ecrase jamais. Le remplacement
  // est ReplaceAtomic, demande explicitement.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)), 0);
  {$ELSE}
  f := LocalNormalize(AFrom);
  t := LocalNormalize(ATo);
  // rename() POSIX ecrase en silence, et verifier avant laisse une course.
  // link() ECHOUE atomiquement si le nom existe: c'est le « ne pas ecraser »
  // qu'on veut. Temporaire et cible sont dans le meme dossier, ce qu'il exige.
  if fpLink(PChar(f), PChar(t)) = 0 then
  begin
    // La cible EST ce fichier; le temporaire n'en est qu'un second nom. Si son
    // retrait echoue, c'est un dechet, pas une cible fausse: publie, mais DIT,
    // pour que l'appelant garde ce nom a nettoyer.
    if fpUnlink(PChar(f)) <> 0 then
      AErr := MakeScpError(sekAttrRefused, 'Renaming to', DisplaySafeName(ATo),
        'the temporary name could not be removed and was left behind');
    Exit(True);
  end;
  code := fpGetErrno;
  if code = ESysEEXIST then
  begin
    AErr := MakeScpError(sekAlreadyExists, 'Renaming to',
      DisplaySafeName(ATo), '');
    Exit(False);
  end;
  // FAT et certains montages reseau ne font pas de lien dur. Alors seulement on
  // cherche une autre primitive qui refuse d'ecraser -- jamais « verifier puis
  // renommer », dont la fenetre ecraserait une cible apparue entre les deux.
  if (code <> ESysEPERM) and (code <> ESysEOPNOTSUPP) and
     (code <> ESysEMLINK) and (code <> ESysEXDEV) and
     (code <> ESysEACCES) then
  begin
    AErr := LastErr('Renaming to', ATo);
    Exit(False);
  end;
  {$IFDEF RSSH_RENAMEAT2}
  // renameat2(RENAME_NOREPLACE): le rename qui refuse d'ecraser, tenu par le
  // noyau depuis Linux 3.15. FPC 3.2 ne l'enveloppe pas: appel direct.
  code := do_syscall(SYSCALL_RENAMEAT2, TSysParam(AT_FDCWD_),
    TSysParam(PChar(f)), TSysParam(AT_FDCWD_), TSysParam(PChar(t)),
    TSysParam(RENAME_NOREPLACE_));
  if code = 0 then Exit(True);
  code := fpGetErrno;
  if code = ESysEEXIST then
  begin
    AErr := MakeScpError(sekAlreadyExists, 'Renaming to',
      DisplaySafeName(ATo), '');
    Exit(False);
  end;
  if (code <> ESysENOSYS) and (code <> ESysEINVAL) then
  begin
    AErr := LastErr('Renaming to', ATo);
    Exit(False);
  end;
  {$ENDIF}
  {$IFDEF DARWIN}
  // renamex_np(RENAME_EXCL): le rename qui refuse d'ecraser, depuis macOS
  // 10.12, dossiers compris. Non enveloppe par FPC 3.2: appel direct.
  if renamex_np(PChar(f), PChar(t), RENAME_EXCL_) = 0 then Exit(True);
  code := fpGetErrno;
  if code = ESysEEXIST then
  begin
    AErr := MakeScpError(sekAlreadyExists, 'Renaming to',
      DisplaySafeName(ATo), '');
    Exit(False);
  end;
  if (code <> ESysENOTSUP) and (code <> ESysEINVAL) then
  begin
    AErr := LastErr('Renaming to', ATo);
    Exit(False);
  end;
  {$ENDIF}
  // Sans primitive qui refuse d'ecraser, on REFUSE. Reserver le nom par une
  // creation exclusive puis renommer par-dessus laissait une fenetre, entre
  // les deux, ou un autre processus remplace la reservation -- et ne savait de
  // toute facon pas renommer un dossier.
  AErr := MakeScpError(sekUnsupported, 'Renaming to', DisplaySafeName(ATo),
    'this file system offers no rename that refuses to overwrite');
  Result := False;
  {$ENDIF}
  if not Result and (AErr.Kind = sekNone) then
    AErr := LastErr('Renaming to', ATo);
end;

{$IFDEF WINDOWS}
// Donne a ATo la DACL de AFrom, protection contre l'heritage comprise. False:
// ACode dit l'erreur Windows, AReading si elle vient de la lecture.
function CopyDaclRaw(const AFrom, ATo: string; out ACode: DWORD;
  out AReading: Boolean): Boolean;
var
  need: DWORD;
  sd: array of Byte;
  control: SECURITY_DESCRIPTOR_CONTROL;
  revision: DWORD;
  info: SECURITY_INFORMATION;
begin
  Result := False;
  ACode := 0;
  AReading := True;
  need := 0;
  GetFileSecurityW(PWideChar(NativeW(AFrom)), DACL_SECURITY_INFORMATION, nil,
    0, @need);
  if need = 0 then
  begin
    ACode := GetLastError;
    Exit;
  end;
  SetLength(sd, need);
  if not GetFileSecurityW(PWideChar(NativeW(AFrom)), DACL_SECURITY_INFORMATION,
     PSECURITY_DESCRIPTOR(@sd[0]), need, @need) then
  begin
    ACode := GetLastError;
    Exit;
  end;
  control := 0;
  revision := 0;
  // Se tromper ici reactiverait l'heritage sur une cible qui l'avait coupe.
  if not GetSecurityDescriptorControl(PSECURITY_DESCRIPTOR(@sd[0]), @control,
     @revision) then
  begin
    ACode := GetLastError;
    Exit;
  end;
  if (control and SE_DACL_PROTECTED_) <> 0 then
    info := DACL_SECURITY_INFORMATION or PROTECTED_DACL_SECURITY_INFORMATION_
  else
    info := DACL_SECURITY_INFORMATION or UNPROTECTED_DACL_SECURITY_INFORMATION_;
  AReading := False;
  if not SetFileSecurityW(PWideChar(NativeW(ATo)), info,
     PSECURITY_DESCRIPTOR(@sd[0])) then
  begin
    ACode := GetLastError;
    Exit;
  end;
  Result := True;
end;

// Un fichier prive remplace par un temporaire ne aux droits du dossier
// deviendrait sinon lisible par tout ce que le dossier autorise.
function CopyDacl(const AFrom, ATo: string; out AErr: TScpError): Boolean;
var
  code: DWORD;
  reading: Boolean;
begin
  AErr := NoScpError;
  Result := CopyDaclRaw(AFrom, ATo, code, reading);
  if Result then Exit;
  if reading then
    AErr := MakeScpError(sekAttrRefused, 'Replacing', DisplaySafeName(ATo),
      Format('the permissions of the existing file could not be read ' +
        '(Windows error %d); the existing file was left untouched', [code]))
  else
    AErr := MakeScpError(sekAttrRefused, 'Replacing', DisplaySafeName(ATo),
      Format('the permissions of the existing file could not be applied to ' +
        'the new content (Windows error %d); the existing file was left ' +
        'untouched', [code]));
end;
{$ENDIF}

function TLocalFileSystem.CopyProtectionFrom(const ASourcePath,
  ATargetPath: string; out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  code: DWORD;
  reading: Boolean;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  Result := CopyDaclRaw(ASourcePath, ATargetPath, code, reading);
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Duplicating',
      DisplaySafeName(ATargetPath),
      Format('the permissions of the source could not be given to the copy ' +
        '(Windows error %d)', [code]));
  {$ELSE}
  // Les modes suffisent: le moteur les a deja poses a la creation.
  Result := True;
  {$ENDIF}
end;

function TLocalFileSystem.ReplaceAtomic(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  tattrs, keep, code: DWORD;
  readOnly: Boolean;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // Le mode POSIX n'existe pas ici: « garde ses droits » veut dire garder la
  // DACL, recopiee sur le temporaire AVANT qu'il prenne la place. Sans elle,
  // la cible n'est pas remplacee.
  if not CopyDacl(ATo, AFrom, AErr) then Exit(False);
  // Les attributs aussi: cache, systeme, lecture seule. Une cible en lecture
  // seule refuse d'etre remplacee; on lui retire le temps du rename, et le
  // nouveau contenu le porte a son tour.
  tattrs := GetFileAttributesW(PWideChar(NativeW(ATo)));
  if tattrs = INVALID_FILE_ATTRIBUTES then
  begin
    code := GetLastError;
    AErr := MakeScpError(sekAttrRefused, 'Replacing', DisplaySafeName(ATo),
      Format('the attributes of the existing file could not be read ' +
        '(Windows error %d); the existing file was left untouched', [code]));
    Exit(False);
  end;
  readOnly := (tattrs and FILE_ATTRIBUTE_READONLY) <> 0;
  keep := tattrs and (FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_HIDDEN or
    FILE_ATTRIBUTE_SYSTEM or FILE_ATTRIBUTE_ARCHIVE or
    FILE_ATTRIBUTE_NOT_CONTENT_INDEXED_);
  if keep = 0 then keep := FILE_ATTRIBUTE_NORMAL;
  // Chaque refus arrete AVANT la publication: le nouveau contenu ne prend
  // pas la place de l'ancien sans ses attributs.
  if not SetFileAttributesW(PWideChar(NativeW(AFrom)), keep) then
  begin
    code := GetLastError;
    AErr := MakeScpError(sekAttrRefused, 'Replacing', DisplaySafeName(ATo),
      Format('the attributes of the existing file could not be applied to ' +
        'the new content (Windows error %d); the existing file was left ' +
        'untouched', [code]));
    Exit(False);
  end;
  if readOnly and (not SetFileAttributesW(PWideChar(NativeW(ATo)),
     tattrs and (not FILE_ATTRIBUTE_READONLY))) then
  begin
    code := GetLastError;
    AErr := MakeScpError(sekReadOnlyTarget, 'Replacing',
      DisplaySafeName(ATo),
      Format('the existing file is read-only and the attribute could not ' +
        'be lifted (Windows error %d); it was left untouched', [code]));
    // En lecture seule, le temporaire ne s'effacerait plus.
    SetFileAttributesW(PWideChar(NativeW(AFrom)), FILE_ATTRIBUTE_NORMAL);
    Exit(False);
  end;
  // MOVEFILE_REPLACE_EXISTING sur un meme volume NTFS: pas d'etat
  // intermediaire. WRITE_THROUGH attend le support avant de rendre la main.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH_);
  if not Result then
  begin
    AErr := LastErr('Replacing', ATo);
    SetFileAttributesW(PWideChar(NativeW(AFrom)), FILE_ATTRIBUTE_NORMAL);
    // La cible est restee, mais sans sa lecture seule si on ne peut la
    // lui rendre: cela se dit.
    if readOnly and (not SetFileAttributesW(PWideChar(NativeW(ATo)), tattrs))
    then
      AErr.Detail := AErr.Detail + Format('; the existing file could not ' +
        'be made read-only again (Windows error %d)', [GetLastError]);
    Exit;
  end;
  {$ELSE}
  Result := fpRename(PChar(LocalNormalize(AFrom)),
    PChar(LocalNormalize(ATo))) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Replacing', ATo);
end;

function TLocalFileSystem.DeleteFile(const APath: string;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  Result := DeleteFileW(PWideChar(NativeW(APath)));
  {$ELSE}
  Result := fpUnlink(PChar(LocalNormalize(APath))) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Deleting', APath);
end;

function TLocalFileSystem.DeleteDir(const APath: string;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  Result := RemoveDirectoryW(PWideChar(NativeW(APath)));
  {$ELSE}
  Result := fpRmdir(PChar(LocalNormalize(APath))) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Deleting folder', APath);
end;

function TLocalFileSystem.OpenRead(const APath: string;
  out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  {$IFDEF WINDOWS}
  info: TByHandleFileInformation;
  {$ELSE}
  st: Stat;
  flags: cint;
  {$ENDIF}
begin
  AHandle := nil;
  AErr := NoScpError;
  h := TLocalHandle.Create;
  h.Path := APath;
  {$IFDEF WINDOWS}
  // FILE_SHARE_READ seul: ne pas lire ce qu'un autre processus reecrit.
  // FILE_FLAG_OPEN_REPARSE_POINT: le lstat du moteur repondait avant cette
  // ouverture, et le nom a pu changer de fichier entre les deux. Ouvrir le
  // point de reanalyse LUI-MEME fait echouer au lieu de lire ailleurs.
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_READ,
    FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := WithAccessContext(LastErr('Opening', APath), acRead);
    h.Free;
    Exit(False);
  end;
  // Ce qui a ete OUVERT est-il ordinaire? Le lstat repondait pour un chemin,
  // ceci repond pour la poignee: un tube ou un peripherique glisse a la place
  // ne se lit pas comme un fichier.
  if (GetFileType(h.H) <> FILE_TYPE_DISK_) or
     (not GetFileInformationByHandle(h.H, info)) or
     ((info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
       FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
  begin
    CloseHandle(h.H);
    h.Free;
    AErr := MakeScpError(sekIsSpecialFile, 'Opening', DisplaySafeName(APath),
      'what was opened is not a regular file');
    Exit(False);
  end;
  {$ELSE}
  // O_NOFOLLOW: seule l'ouverture peut refuser un lien sans course, et elle ne
  // protege que le DERNIER composant. O_NONBLOCK: un tube nomme a la place du
  // fichier ferait attendre un ecrivain, donc pour toujours.
  h.Fd := fpOpen(PChar(LocalNormalize(APath)),
    O_RDONLY or O_NOFOLLOW or O_NONBLOCK);
  if h.Fd < 0 then
  begin
    AErr := WithAccessContext(LastErr('Opening', APath), acRead);
    h.Free;
    Exit(False);
  end;
  // fstat sur la poignee: on juge ce qui a ete ouvert, pas le chemin.
  if (fpFStat(h.Fd, st) <> 0) or (not fpS_ISREG(st.st_mode)) then
  begin
    fpClose(h.Fd);
    h.Free;
    AErr := MakeScpError(sekIsSpecialFile, 'Opening', DisplaySafeName(APath),
      'what was opened is not a regular file');
    Exit(False);
  end;
  flags := fpFcntl(h.Fd, F_GETFL);
  if flags >= 0 then
    fpFcntl(h.Fd, F_SETFL, flags and (not O_NONBLOCK));
  {$ENDIF}
  AHandle := h;
  Result := True;
end;

function TLocalFileSystem.CreateTemp(const ADir: string; AMode: LongWord;
  out APath: string; out AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  attempt: Integer;
  candidate: string;
  {$IFDEF WINDOWS}
  sa: TSecurityAttributes;
  psa: PSecurityAttributes;
  {$ENDIF}
begin
  AHandle := nil;
  APath := '';
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // Un temporaire PRIVE le reste pendant la copie et apres une interruption:
  // sa DACL nait avec lui. Celui qui remplace une cible (demande en 0600)
  // recoit la DACL de la cible juste avant de prendre sa place.
  psa := nil;
  sa.lpSecurityDescriptor := nil;
  if ModeIsPrivate(AMode) then
  begin
    sa.nLength := SizeOf(sa);
    sa.bInheritHandle := False;
    sa.lpSecurityDescriptor := PrivateSecurityDescriptor(False);
    if sa.lpSecurityDescriptor = nil then
    begin
      AErr := MakeScpError(sekOther, 'Creating a temporary file in',
        DisplaySafeName(ADir),
        Format('private permissions could not be prepared (Windows error %d)',
          [GetLastError]));
      Exit(False);
    end;
    psa := @sa;
  end;
  try
  {$ENDIF}
  for attempt := 1 to 8 do
  begin
    candidate := LocalJoin(ADir, TEMP_PREFIX + RandomSuffix + TEMP_SUFFIX);
    h := TLocalHandle.Create;
    h.Path := candidate;
    {$IFDEF WINDOWS}
    // CREATE_NEW echoue si QUOI QUE CE SOIT existe sous ce nom, lien compris:
    // c'est ce qui interdit d'ecrire a travers un lien pose d'avance.
    h.H := CreateFileW(PWideChar(NativeW(candidate)), GENERIC_WRITE,
      0, psa, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if h.H <> INVALID_HANDLE_VALUE then
    begin
      APath := candidate;
      AHandle := h;
      Exit(True);
    end;
    AErr := LastErr('Creating a temporary file in', ADir);
    h.Free;
    if AErr.Kind <> sekAlreadyExists then Exit(False);
    {$ELSE}
    // Le mode demande passe par l'umask: seul moment ou le systeme le restreint.
    h.Fd := fpOpen(PChar(LocalNormalize(candidate)),
      O_WRONLY or O_CREAT or O_EXCL, AMode and LongWord(&0777));
    if h.Fd >= 0 then
    begin
      APath := candidate;
      AHandle := h;
      Exit(True);
    end;
    AErr := LastErr('Creating a temporary file in', ADir);
    h.Free;
    if AErr.Kind <> sekAlreadyExists then Exit(False);
    {$ENDIF}
  end;
  AErr := MakeScpError(sekOther, 'Creating a temporary file in',
    DisplaySafeName(ADir), 'eight unpredictable names all collided');
  Result := False;
  {$IFDEF WINDOWS}
  finally
    if sa.lpSecurityDescriptor <> nil then
      LocalFree(HLOCAL(sa.lpSecurityDescriptor));
  end;
  {$ENDIF}
end;

function TLocalFileSystem.OpenAppend(const APath: string; AOffset: Int64;
  out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  err: TScpError;
  {$IFDEF WINDOWS}
  info: TByHandleFileInformation;
  {$ELSE}
  st: Stat;
  flags: cint;
  {$ENDIF}
begin
  AHandle := nil;
  AErr := NoScpError;
  h := TLocalHandle.Create;
  h.Path := APath;
  // Jamais a travers un lien: un partiel devenu lien entre la coupure et la
  // reprise ferait ecrire ailleurs. Lecture ET ecriture, parce que le moteur
  // relit le prefixe par cette poignee, ce qui lie la verification au FICHIER.
  {$IFDEF WINDOWS}
  // FILE_FLAG_OPEN_REPARSE_POINT: sur un lien, l'ecriture echoue au lieu de
  // traverser.
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Reopening', APath);
    h.Free;
    Exit(False);
  end;
  // Meme controle qu'a l'ouverture en lecture: ce qui a ete OUVERT est-il un
  // fichier ordinaire? Le lstat du moteur repondait pour un chemin.
  if (GetFileType(h.H) <> FILE_TYPE_DISK_) or
     (not GetFileInformationByHandle(h.H, info)) or
     ((info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
       FILE_ATTRIBUTE_REPARSE_POINT)) <> 0) then
  begin
    CloseHandle(h.H);
    h.Free;
    AErr := MakeScpError(sekIsSpecialFile, 'Reopening',
      DisplaySafeName(APath), 'what was opened is not a regular file');
    Exit(False);
  end;
  {$ELSE}
  // O_NONBLOCK: un tube nomme a la place du partiel bloquerait l'ouverture.
  h.Fd := fpOpen(PChar(LocalNormalize(APath)),
    O_RDWR or O_NOFOLLOW or O_NONBLOCK);
  if h.Fd < 0 then
  begin
    AErr := LastErr('Reopening', APath);
    h.Free;
    Exit(False);
  end;
  if (fpFStat(h.Fd, st) <> 0) or (not fpS_ISREG(st.st_mode)) then
  begin
    fpClose(h.Fd);
    h.Free;
    AErr := MakeScpError(sekIsSpecialFile, 'Reopening',
      DisplaySafeName(APath), 'what was opened is not a regular file');
    Exit(False);
  end;
  flags := fpFcntl(h.Fd, F_GETFL);
  if flags >= 0 then
    fpFcntl(h.Fd, F_SETFL, flags and (not O_NONBLOCK));
  {$ENDIF}
  AHandle := h;
  // Offset confirme ET troncature: des octets non confirmes sont des octets
  // dont on ne sait rien.
  if not Seek(h, AOffset, AErr) then
  begin
    Close(h, err);
    AHandle := nil;
    Exit(False);
  end;
  {$IFDEF WINDOWS}
  if not SetEndOfFile(h.H) then
  begin
    AErr := LastErr('Truncating', APath);
    Close(h, err);
    AHandle := nil;
    Exit(False);
  end;
  {$ELSE}
  if fpFTruncate(h.Fd, AOffset) <> 0 then
  begin
    AErr := LastErr('Truncating', APath);
    Close(h, err);
    AHandle := nil;
    Exit(False);
  end;
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Read(AHandle: TScpFileHandle; ABuf: PByte;
  ACount: Integer; out AGot: Integer; out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  {$IFDEF WINDOWS}
  n: LongWord;
  {$ELSE}
  n: TsSize;
  {$ENDIF}
begin
  AGot := 0;
  AErr := NoScpError;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  n := 0;
  if not ReadFile(h.H, ABuf^, LongWord(ACount), n, nil) then
  begin
    AErr := WithAccessContext(LastErr('Reading', h.Path), acRead);
    Exit(False);
  end;
  AGot := Integer(n);
  {$ELSE}
  repeat
    n := fpRead(h.Fd, ABuf^, ACount);
  until (n >= 0) or (fpGetErrno <> ESysEINTR);
  if n < 0 then
  begin
    AErr := WithAccessContext(LastErr('Reading', h.Path), acRead);
    Exit(False);
  end;
  AGot := Integer(n);
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Write(AHandle: TScpFileHandle; ABuf: PByte;
  ACount: Integer; out APut: Integer; out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  {$IFDEF WINDOWS}
  n: LongWord;
  {$ELSE}
  n: TsSize;
  {$ENDIF}
begin
  APut := 0;
  AErr := NoScpError;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  n := 0;
  if not WriteFile(h.H, ABuf^, LongWord(ACount), n, nil) then
  begin
    AErr := LastErr('Writing', h.Path);
    Exit(False);
  end;
  APut := Integer(n);
  {$ELSE}
  repeat
    n := fpWrite(h.Fd, ABuf^, ACount);
  until (n >= 0) or (fpGetErrno <> ESysEINTR);
  if n < 0 then
  begin
    AErr := LastErr('Writing', h.Path);
    Exit(False);
  end;
  APut := Integer(n);
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Seek(AHandle: TScpFileHandle; AOffset: Int64;
  out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  {$IFDEF WINDOWS}
  lo: LongInt;
  hi: LongInt;
  rc: LongWord;
  {$ENDIF}
begin
  AErr := NoScpError;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  lo := LongInt(AOffset and $FFFFFFFF);
  hi := LongInt(AOffset shr 32);
  rc := SetFilePointer(h.H, lo, @hi, FILE_BEGIN);
  // INVALID_SET_FILE_POINTER n'est un echec que si GetLastError le confirme:
  // un offset dont les 32 bits bas valent 0xFFFFFFFF rend la meme valeur.
  if (rc = INVALID_SET_FILE_POINTER) and (GetLastError <> NO_ERROR) then
  begin
    AErr := LastErr('Seeking in', h.Path);
    Exit(False);
  end;
  {$ELSE}
  if fpLSeek(h.Fd, AOffset, SEEK_SET) < 0 then
  begin
    AErr := LastErr('Seeking in', h.Path);
    Exit(False);
  end;
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Flush(AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
begin
  AErr := NoScpError;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  // Un disque plein se revele souvent ICI et pas a l'ecriture: conclure sans
  // vider remplacerait une cible valide par un fichier tronque.
  Result := FlushFileBuffers(h.H);
  {$ELSE}
  Result := fpfsync(h.Fd) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Flushing', h.Path);
end;

function TLocalFileSystem.Close(AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
begin
  AErr := NoScpError;
  Result := True;
  if AHandle = nil then Exit;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  if h.H <> INVALID_HANDLE_VALUE then
    Result := CloseHandle(h.H);
  h.H := INVALID_HANDLE_VALUE;
  {$ELSE}
  if h.Fd >= 0 then
    Result := fpClose(h.Fd) = 0;
  h.Fd := -1;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Closing', h.Path);
  h.Free;
end;

function TLocalFileSystem.SetMTime(AHandle: TScpFileHandle; AMTimeUtc: Int64;
  out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  {$IFDEF WINDOWS}
  ft: TFileTime;
  {$ELSE}
  times: array[0..1] of TTimeSpec;
  {$ENDIF}
begin
  AErr := NoScpError;
  h := TLocalHandle(AHandle);
  {$IFDEF WINDOWS}
  ft := UnixToFileTime(AMTimeUtc);
  Result := SetFileTime(h.H, nil, nil, @ft);
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the timestamp of',
      DisplaySafeName(h.Path), Format('Windows error %d', [GetLastError]));
  {$ELSE}
  // La date d'ACCES n'est pas touchee: UTIME_OMIT la laisse telle quelle,
  // sans avoir a la relire ni a l'inventer.
  times[0].tv_sec := 0;
  times[0].tv_nsec := UTIME_OMIT_;
  times[1].tv_sec := AMTimeUtc;
  times[1].tv_nsec := 0;
  Result := FUTimens(h.Fd, @times[0]) = 0;
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the timestamp of',
      DisplaySafeName(h.Path), Format('errno %d', [fpGetErrno]));
  {$ENDIF}
end;

function TLocalFileSystem.SetMode(AHandle: TScpFileHandle; AMode: LongWord;
  out AErr: TScpError): Boolean;
{$IFNDEF WINDOWS}
var
  h: TLocalHandle;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // Aucun mode POSIX a poser. Les ACL, elles, sont recopiees par ReplaceAtomic,
  // le seul moment ou l'on sait de quel fichier elles viennent.
  Result := True;
  {$ELSE}
  h := TLocalHandle(AHandle);
  Result := FChmod(h.Fd, AMode and LongWord(&07777)) = 0;
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the mode of',
      DisplaySafeName(h.Path), Format('errno %d', [fpGetErrno]));
  {$ENDIF}
end;

// --- Suppression recursive ------------------------------------------------

{$IFDEF WINDOWS}
// Vide un dossier par sa POIGNEE: chaque enfant est ouvert relativement a
// elle, jamais par un chemin que ce dossier, devenu lien entre-temps, ferait
// resoudre ailleurs. Le chemin ne sert qu'aux messages.
function TLocalFileSystem.EmptyDirByHandle(ADir: THandle; const APath: string;
  ADepth: Integer; out AErr: TScpError): Boolean;
var
  buf: array of Byte;
  info: PFileIdBothDirInfo;
  names: TStringList;
  first: Boolean;
  cls: DWORD;
  i: Integer;
  name: string;
  wname: UnicodeString;
  child: THandle;
  st: LongInt;
  us: TNtUnicodeString;
  oa: TNtObjectAttributes;
  iosb: TNtIoStatusBlock;
  attrs: TByHandleFileInformation;
  disp: TFileDispositionInfo;
  code: DWORD;
begin
  Result := False;
  AErr := NoScpError;
  if ADepth > LOCAL_MAX_RM_DEPTH then
  begin
    AErr := MakeScpError(sekOther, 'Deleting', DisplaySafeName(APath),
      Format('maximum depth of %d reached', [LOCAL_MAX_RM_DEPTH]));
    Exit;
  end;
  SetLength(buf, 64 * 1024);
  names := TStringList.Create;
  try
    // Les noms d'abord, les suppressions ensuite: retirer pendant qu'on enumere
    // fait sauter des entrees.
    first := True;
    while True do
    begin
      if first then
        cls := FileIdBothDirectoryRestartInfo_
      else
        cls := FileIdBothDirectoryInfo_;
      first := False;
      if not GetFileInformationByHandleEx(ADir, cls, @buf[0], Length(buf))
      then
      begin
        code := GetLastError;
        if code = ERROR_NO_MORE_FILES then Break;
        AErr := MakeScpError(OsErrorToKind(Integer(code)), 'Listing',
          DisplaySafeName(APath), Format('Windows error %d', [code]));
        Exit;
      end;
      info := PFileIdBothDirInfo(@buf[0]);
      while True do
      begin
        SetLength(wname, info^.FileNameLength div 2);
        if Length(wname) > 0 then
          Move(info^.FileName[0], wname[1], info^.FileNameLength);
        name := U(wname);
        if (name <> '.') and (name <> '..') and (name <> '') then
          names.Add(name);
        if info^.NextEntryOffset = 0 then Break;
        info := PFileIdBothDirInfo(PByte(info) + info^.NextEntryOffset);
      end;
      if names.Count > SCP_MAX_DIR_ENTRIES then
      begin
        AErr := MakeScpError(sekOther, 'Listing', DisplaySafeName(APath),
          Format('more than %d entries', [SCP_MAX_DIR_ENTRIES]));
        Exit;
      end;
    end;
    for i := 0 to names.Count - 1 do
    begin
      if Canceled then
      begin
        AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath),
          '');
        Exit;
      end;
      name := names[i];
      if CheckLocalName(name) <> nvOk then
      begin
        AErr := MakeScpError(sekInvalidName, 'Deleting',
          DisplaySafeName(name), '');
        Exit;
      end;
      wname := W(name);
      us.Buffer := PWideChar(wname);
      us.Length := Length(wname) * 2;
      us.MaximumLength := us.Length;
      FillChar(oa, SizeOf(oa), 0);
      oa.Length := SizeOf(oa);
      oa.RootDirectory := ADir;
      oa.ObjectName := @us;
      oa.Attributes := OBJ_CASE_INSENSITIVE_;
      child := 0;
      // FILE_OPEN_REPARSE_POINT: un lien ou une jonction est ouvert LUI-MEME,
      // et n'a alors aucun contenu a nos yeux; il partira seul. Le droit de
      // lister n'est demande que s'il est accorde: un fichier illisible se
      // supprime quand meme, par son dossier.
      st := NtOpenFile(@child, DELETE_ or SYNCHRONIZE_ or
        FILE_READ_ATTRIBUTES_ or FILE_LIST_DIRECTORY_, @oa, @iosb,
        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_,
        FILE_OPEN_REPARSE_POINT_ or FILE_OPEN_FOR_BACKUP_INTENT_ or
        FILE_SYNCHRONOUS_IO_NONALERT_);
      if (st < 0) and (RtlNtStatusToDosError(st) = ERROR_ACCESS_DENIED) then
        st := NtOpenFile(@child, DELETE_ or SYNCHRONIZE_ or
          FILE_READ_ATTRIBUTES_, @oa, @iosb,
          FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_,
          FILE_OPEN_REPARSE_POINT_ or FILE_OPEN_FOR_BACKUP_INTENT_ or
          FILE_SYNCHRONOUS_IO_NONALERT_);
      if st < 0 then
      begin
        code := RtlNtStatusToDosError(st);
        // Le listing a vieilli: une entree partie entre-temps n'est pas un echec.
        if (code = ERROR_FILE_NOT_FOUND) or (code = ERROR_PATH_NOT_FOUND) then
          Continue;
        AErr := MakeScpError(OsErrorToKind(Integer(code)), 'Deleting',
          DisplaySafeName(name), Format('Windows error %d', [code]));
        Exit;
      end;
      try
        if not GetFileInformationByHandle(child, attrs) then
        begin
          AErr := LastErr('Reading attributes of', name);
          Exit;
        end;
        if ((attrs.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
           ((attrs.dwFileAttributes and FILE_ATTRIBUTE_REPARSE_POINT) = 0) then
          if not EmptyDirByHandle(child, LocalJoin(APath, name), ADepth + 1,
             AErr) then
            Exit;
        disp.DeleteFile := True;
        if not SetFileInformationByHandle(child, FileDispositionInfo_, @disp,
           SizeOf(disp)) then
        begin
          AErr := LastErr('Deleting', LocalJoin(APath, name));
          Exit;
        end;
      finally
        CloseHandle(child);
      end;
    end;
  finally
    names.Free;
  end;
  Result := True;
end;
{$ELSE}
// Meme principe par descripteur: openat et unlinkat n'agissent que DANS le
// dossier ouvert. Le listing par chemin ne fournit que des noms.
function TLocalFileSystem.EmptyDirByFd(ADir: cint; const APath: string;
  ADepth: Integer; out AErr: TScpError): Boolean;
var
  entries: TScpEntryArray;
  i: Integer;
  name: string;
  child: cint;
  code: Integer;
  cst: Stat;
begin
  Result := False;
  AErr := NoScpError;
  if ADepth > LOCAL_MAX_RM_DEPTH then
  begin
    AErr := MakeScpError(sekOther, 'Deleting', DisplaySafeName(APath),
      Format('maximum depth of %d reached', [LOCAL_MAX_RM_DEPTH]));
    Exit;
  end;
  if not List(APath, entries, AErr) then Exit;
  for i := 0 to High(entries) do
  begin
    if Canceled then
    begin
      AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath),
        '');
      Exit;
    end;
    name := entries[i].Name;
    if CheckLocalName(name) <> nvOk then
    begin
      AErr := MakeScpError(sekInvalidName, 'Deleting', DisplaySafeName(name),
        '');
      Exit;
    end;
    // O_DIRECTORY et O_NOFOLLOW: un dossier s'ouvre, tout le reste -- fichier,
    // lien, tube -- est refuse avec un errno qui dit lequel, et part par unlink.
    child := OpenDirAt(ADir, name);
    if child >= 0 then
    begin
      try
        if fpFStat(child, cst) <> 0 then
        begin
          AErr := LastErr('Deleting folder', LocalJoin(APath, name));
          Exit;
        end;
        if not EmptyDirByFd(child, LocalJoin(APath, name), ADepth + 1, AErr)
        then
          Exit;
      finally
        fpClose(child);
      end;
      if not SameDirAt(ADir, name, cst) then
      begin
        AErr := MakeScpError(sekOutsideRoot, 'Deleting folder',
          DisplaySafeName(LocalJoin(APath, name)),
          'the folder changed while it was being deleted');
        Exit;
      end;
      if UnlinkAt(ADir, name, True) <> 0 then
      begin
        AErr := LastErr('Deleting folder', LocalJoin(APath, name));
        Exit;
      end;
      Continue;
    end;
    code := fpGetErrno;
    if code = ESysENOENT then Continue;       // le listing a vieilli
    // EACCES: un fichier qu'on ne peut pas lire se supprime quand meme, par
    // son dossier; un dossier qu'on ne peut pas lire, lui, reste et le dit.
    if (code <> ESysENOTDIR) and (code <> ESysELOOP) and (code <> ESysEACCES)
    then
    begin
      AErr := LastErr('Deleting', LocalJoin(APath, name));
      Exit;
    end;
    if (UnlinkAt(ADir, name, False) <> 0) and (fpGetErrno <> ESysENOENT) then
    begin
      AErr := LastErr('Deleting', LocalJoin(APath, name));
      Exit;
    end;
  end;
  Result := True;
end;
{$ENDIF}

function TLocalFileSystem.RemoveTree(const APath: string;
  out AErr: TScpError): Boolean;
var
  e: TScpEntry;
  {$IFDEF WINDOWS}
  h: THandle;
  attrs: TByHandleFileInformation;
  disp: TFileDispositionInfo;
  {$ELSE}
  fd, parentFd: cint;
  st: Stat;
  base: string;
  {$ENDIF}
begin
  Result := False;
  if not Stat(APath, False, e, AErr) then Exit;
  // Un lien vers un dossier se supprime LUI: y descendre effacerait sa cible.
  // Sous Windows une jonction est un dossier, et part comme tel.
  if e.IsLink and e.IsDir then Exit(DeleteDir(APath, AErr));
  if e.IsLink or (not e.IsDir) then Exit(DeleteFile(APath, AErr));
  {$IFDEF WINDOWS}
  h := CreateFileW(PWideChar(NativeW(APath)), DELETE_ or SYNCHRONIZE_ or
    FILE_READ_ATTRIBUTES_ or FILE_LIST_DIRECTORY_,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_,
    0);
  if h = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Deleting folder', APath);
    Exit;
  end;
  try
    // Ce qui est OUVERT est-il encore un dossier, et pas un lien? La poignee
    // repond pour elle-meme, la ou le lstat repondait pour un chemin.
    if (not GetFileInformationByHandle(h, attrs)) or
       ((attrs.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
         FILE_ATTRIBUTE_REPARSE_POINT)) <> FILE_ATTRIBUTE_DIRECTORY) then
    begin
      AErr := MakeScpError(sekOutsideRoot, 'Deleting folder',
        DisplaySafeName(APath), 'the folder changed while it was being deleted');
      Exit;
    end;
    if not EmptyDirByHandle(h, APath, 0, AErr) then Exit;
    disp.DeleteFile := True;
    if not SetFileInformationByHandle(h, FileDispositionInfo_, @disp,
       SizeOf(disp)) then
    begin
      AErr := LastErr('Deleting folder', APath);
      Exit;
    end;
  finally
    CloseHandle(h);
  end;
  {$ELSE}
  // La racine aussi est ouverte et retiree RELATIVEMENT a son parent: un
  // renommage concurrent ne fait pas viser un autre dossier.
  base := LocalBaseName(APath);
  parentFd := fpOpen(PChar(LocalNormalize(LocalParent(APath))),
    O_RDONLY or O_DIRECTORY or O_CLOEXEC_);
  if parentFd < 0 then
  begin
    AErr := LastErr('Deleting folder', APath);
    Exit;
  end;
  try
    fd := OpenDirAt(parentFd, base);
    if fd < 0 then
    begin
      AErr := LastErr('Deleting folder', APath);
      Exit;
    end;
    try
      if (fpFStat(fd, st) <> 0) or (not fpS_ISDIR(st.st_mode)) then
      begin
        AErr := MakeScpError(sekOutsideRoot, 'Deleting folder',
          DisplaySafeName(APath),
          'the folder changed while it was being deleted');
        Exit;
      end;
      if not EmptyDirByFd(fd, APath, 0, AErr) then Exit;
    finally
      fpClose(fd);
    end;
    if not SameDirAt(parentFd, base, st) then
    begin
      AErr := MakeScpError(sekOutsideRoot, 'Deleting folder',
        DisplaySafeName(APath), 'the folder changed while it was being deleted');
      Exit;
    end;
    if UnlinkAt(parentFd, base, True) <> 0 then
    begin
      AErr := LastErr('Deleting folder', APath);
      Exit;
    end;
  finally
    fpClose(parentFd);
  end;
  {$ENDIF}
  Result := True;
end;

function TLocalFileSystem.Join(const ABase, AName: string): string;
begin
  Result := LocalJoin(ABase, AName);
end;

function TLocalFileSystem.Parent(const APath: string): string;
begin
  Result := LocalParent(APath);
end;

function TLocalFileSystem.BaseName(const APath: string): string;
begin
  Result := LocalBaseName(APath);
end;

function TLocalFileSystem.Normalize(const APath: string): string;
begin
  Result := LocalNormalize(APath);
end;

function TLocalFileSystem.IsUnder(const ARoot, APath: string): Boolean;
begin
  Result := LocalIsUnder(ARoot, APath);
end;

function TLocalFileSystem.CheckName(const AName: string): TNameVerdict;
begin
  Result := CheckLocalName(AName);
end;

function TLocalFileSystem.CollisionKey(const AName: string): string;
begin
  Result := LocalCollisionKey(AName);
end;

// --- Volumes --------------------------------------------------------------

function LocalHomePath: string;
begin
  {$IFDEF WINDOWS}
  // Qualifie: l'unite Windows en expose un autre, qui masque celui de SysUtils.
  Result := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if Result = '' then
    Result := SysUtils.GetEnvironmentVariable('HOMEDRIVE') +
      SysUtils.GetEnvironmentVariable('HOMEPATH');
  {$ELSE}
  Result := SysUtils.GetEnvironmentVariable('HOME');
  {$ENDIF}
  if Result <> '' then
    Result := LocalNormalize(Result);
end;

{$IFDEF WINDOWS}
function EnumerateLocalVolumes: TLocalVolumeArray;
var
  mask: LongWord;
  i, n: Integer;
  root: string;
  dt: LongWord;
  kind: TLocalVolumeKind;
  typeName: string;
begin
  Result := nil;
  n := 0;
  mask := GetLogicalDrives;
  for i := 0 to 25 do
  begin
    if (mask and (LongWord(1) shl i)) = 0 then Continue;
    root := Chr(Ord('A') + i) + ':\';
    // GetDriveType lit une table en memoire; GetVolumeInformation interroge le
    // volume et bloque sur un partage hors ligne. D'ou le TYPE et pas le nom.
    dt := GetDriveTypeW(PWideChar(UnicodeString(root)));
    case dt of
      DRIVE_REMOVABLE: begin kind := lvkRemovable; typeName := 'Removable'; end;
      DRIVE_FIXED: begin kind := lvkFixed; typeName := 'Local Disk'; end;
      DRIVE_REMOTE: begin kind := lvkNetwork; typeName := 'Network'; end;
      DRIVE_CDROM: begin kind := lvkOptical; typeName := 'Optical'; end;
      DRIVE_RAMDISK: begin kind := lvkRamDisk; typeName := 'RAM Disk'; end;
      1: Continue;
    else
      begin kind := lvkOther; typeName := 'Drive'; end;
    end;
    SetLength(Result, n + 1);
    Result[n].Path := root;
    Result[n].Caption := Format('%s: (%s)', [Chr(Ord('A') + i), typeName]);
    Result[n].Kind := kind;
    Inc(n);
  end;
  if LocalHomePath <> '' then
  begin
    SetLength(Result, n + 1);
    for i := n downto 1 do
      Result[i] := Result[i - 1];
    Result[0].Path := LocalHomePath;
    Result[0].Caption := 'Home';
    Result[0].Kind := lvkHome;
  end;
end;
{$ELSE}
function EnumerateLocalVolumes: TLocalVolumeArray;
var
  n: Integer;

  procedure AddVol(const APath, ACaption: string; AKind: TLocalVolumeKind);
  var
    i: Integer;
  begin
    if APath = '' then Exit;
    if not DirectoryExists(APath) then Exit;
    for i := 0 to n - 1 do
      if Result[i].Path = APath then Exit;
    SetLength(Result, n + 1);
    Result[n].Path := APath;
    Result[n].Caption := ACaption;
    Result[n].Kind := AKind;
    Inc(n);
  end;

  {$IFDEF LINUX}
  // /proc/mounts vient du noyau: aucune entree/sortie, aucun blocage.
  procedure ScanProcMounts;
  var
    sl: TStringList;
    i, p1, p2: Integer;
    line, fsType, mountPoint: string;
  begin
    if not FileExists('/proc/mounts') then Exit;
    sl := TStringList.Create;
    try
      try
        sl.LoadFromFile('/proc/mounts');
      except
        Exit;
      end;
      for i := 0 to sl.Count - 1 do
      begin
        line := sl[i];
        p1 := Pos(' ', line);
        if p1 <= 0 then Continue;
        line := Copy(line, p1 + 1, Length(line) - p1);
        p1 := Pos(' ', line);
        if p1 <= 0 then Continue;
        mountPoint := Copy(line, 1, p1 - 1);
        line := Copy(line, p1 + 1, Length(line) - p1);
        p2 := Pos(' ', line);
        if p2 <= 0 then Continue;
        fsType := Copy(line, 1, p2 - 1);
        if (fsType = 'proc') or (fsType = 'sysfs') or (fsType = 'devtmpfs') or
           (fsType = 'devpts') or (fsType = 'cgroup') or
           (fsType = 'cgroup2') or (fsType = 'securityfs') or
           (fsType = 'debugfs') or (fsType = 'tracefs') or
           (fsType = 'pstore') or (fsType = 'bpf') or
           (fsType = 'configfs') or (fsType = 'fusectl') or
           (fsType = 'mqueue') or (fsType = 'hugetlbfs') or
           (fsType = 'autofs') or (fsType = 'binfmt_misc') or
           (fsType = 'efivarfs') or (fsType = 'squashfs') then
          Continue;
        if mountPoint = '/' then Continue;
        if (Pos('/sys/', mountPoint) = 1) or (Pos('/proc/', mountPoint) = 1) or
           (Pos('/dev/', mountPoint) = 1) or (Pos('/run/', mountPoint) = 1) then
          Continue;
        mountPoint := StringReplace(mountPoint, '\040', ' ', [rfReplaceAll]);
        AddVol(mountPoint, mountPoint, lvkOther);
      end;
    finally
      sl.Free;
    end;
  end;
  {$ENDIF}

  {$IFDEF DARWIN}
  procedure ScanVolumes;
  var
    sr: TSearchRec;
  begin
    if FindFirst('/Volumes/*', faDirectory, sr) <> 0 then Exit;
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') then Continue;
        if (sr.Attr and faDirectory) = 0 then Continue;
        AddVol('/Volumes/' + sr.Name, sr.Name, lvkOther);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  {$ENDIF}

begin
  Result := nil;
  n := 0;
  AddVol(LocalHomePath, 'Home', lvkHome);
  AddVol('/', 'Root (/)', lvkRoot);
  {$IFDEF LINUX}
  ScanProcMounts;
  {$ENDIF}
  {$IFDEF DARWIN}
  ScanVolumes;
  {$ENDIF}
end;
{$ENDIF}

end.
