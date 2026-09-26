{ Disque LOCAL de l'onglet Scp. Le cwd du PROCESSUS ne bouge jamais, les
  volumes ne sont pas sondes, les temporaires sont exclusifs et imprevisibles.

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
    Path: string;
    Caption: string;
    Kind: TLocalVolumeKind;
  end;

  TLocalVolumeArray = array of TLocalVolume;

  TLocalFileSystem = class(TScpFileSystem)
  private
    FCancelFlag: LongInt;   // inter-threads: acces atomiques
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
    // ANCREE: enfants retires relativement au dossier ouvert. Un dossier
    // remplace par un lien en route n'y entraine pas le rm. Un lien part seul.
    function RemoveTree(const APath: string; out AErr: TScpError): Boolean;
    function CopyProtectionFrom(const ASourcePath, ATargetPath: string;
      out AErr: TScpError): Boolean; override;
    {$IFDEF WINDOWS}
    function MakeDirFromSource(const ASourcePath, APath: string;
      AMode: LongWord; out AErr: TScpError): Boolean; override;
    function CopyAttributesFrom(ASource, ATarget: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function DeleteTemp(const APath: string;
      out AErr: TScpError): Boolean; override;
    {$ENDIF}
    function Join(const ABase, AName: string): string; override;
    function Parent(const APath: string): string; override;
    function BaseName(const APath: string): string; override;
    function Normalize(const APath: string): string; override;
    function IsUnder(const ARoot, APath: string): Boolean; override;
    function CheckName(const AName: string): TNameVerdict; override;
    function CollisionKey(const AName: string): string; override;
  end;

// SANS sonder: un partage hors ligne ne fige rien ici, il echouera a l'ouverture.
function EnumerateLocalVolumes: TLocalVolumeArray;
function LocalHomePath: string;

implementation

uses
  uSodiumApi;

const
  {$IFDEF WINDOWS}
  // Absents de l'unite Windows de FPC 3.2.
  MOVEFILE_WRITE_THROUGH_ = $00000008;
  FILE_TYPE_DISK_ = $0001;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
  DELETE_ = $00010000;
  READ_CONTROL_ = $00020000;
  WRITE_DAC_ = $00040000;
  SYNCHRONIZE_ = $00100000;
  FILE_READ_ATTRIBUTES_ = $0080;
  FILE_WRITE_ATTRIBUTES_ = $0100;
  FILE_LIST_DIRECTORY_ = $0001;
  FILE_SHARE_DELETE_ = $0004;
  FILE_OPEN_REPARSE_POINT_ = $00200000;
  FILE_OPEN_FOR_BACKUP_INTENT_ = $00004000;
  FILE_SYNCHRONOUS_IO_NONALERT_ = $00000020;
  OBJ_CASE_INSENSITIVE_ = $00000040;
  FileBasicInfo_ = 0;
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
  // renameat2 absent de FPC 3.2. Archi inconnue: reservation exclusive.
  {$IF DEFINED(CPUX86_64)}
  SYSCALL_RENAMEAT2 = 316; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUAARCH64)}
  SYSCALL_RENAMEAT2 = 276; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUI386)}
  SYSCALL_RENAMEAT2 = 353; {$DEFINE RSSH_RENAMEAT2}
  {$ELSEIF DEFINED(CPUARM)}
  SYSCALL_RENAMEAT2 = 382; {$DEFINE RSSH_RENAMEAT2}
  {$ENDIF}
  // utimensat: absent du sysnr x86_64/aarch64 de FPC 3.2.2
  {$IF DEFINED(CPUX86_64)}
  SYSCALL_UTIMENSAT_ = 280;
  {$ELSEIF DEFINED(CPUAARCH64)}
  SYSCALL_UTIMENSAT_ = 88;
  {$ELSEIF DEFINED(CPUI386)}
  SYSCALL_UTIMENSAT_ = 320;
  {$ELSE}
  SYSCALL_UTIMENSAT_ = syscall_nr_utimensat;
  {$ENDIF}
  AT_FDCWD_ = -100;
  RENAME_NOREPLACE_ = 1;
  {$ENDIF}
  {$IFDEF DARWIN}
  RENAME_EXCL_ = 4;   // renamex_np, <sys/stdio.h>
  // absents du BaseUnix Darwin; <sys/fcntl.h>
  O_NOFOLLOW = $100;
  O_DIRECTORY = $100000;
  {$ENDIF}

  TEMP_PREFIX = '.rssh-';
  TEMP_SUFFIX = '.part';
  // imprevisible: personne ne pose de lien sur un nom qu'il ne devine pas
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
  // FILE_BASIC_INFO: une date a zero n'est pas touchee.
  TFileBasicInfo = record
    CreationTime, LastAccessTime, LastWriteTime, ChangeTime: Int64;
    FileAttributes: DWORD;
  end;
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

// NtOpenFile: seul moyen d'ouvrir RELATIVEMENT a une poignee de dossier.
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

// PRIVE = « autres » sans lecture. Pas de groupe sous Windows: donner ses bits
// a tous elargirait, les ignorer ne fait que restreindre.
function ModeIsPrivate(AMode: LongWord): Boolean;
begin
  Result := (AMode and LongWord(&0004)) = 0;
end;

// Utilisateur, SYSTEM, admins, heritage coupe: le 0700 local, root compris. Pose A LA
// CREATION, jamais apres. nil en cas d'echec; LocalFree.
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
// Absents de FPC 3.2: syscall sous Linux, libc ailleurs.
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
  // utimensat sans chemin = futimens
  Result := do_syscall(SYSCALL_UTIMENSAT_, TSysParam(AFd), TSysParam(nil),
    TSysParam(ATimes), TSysParam(0));
end;
{$ELSE}
function openat(dirfd: cint; path: PChar; flags: cint): cint; cdecl; varargs;
  external 'c' name 'openat';
function unlinkat(dirfd: cint; path: PChar; flags: cint): cint; cdecl;
  external 'c' name 'unlinkat';
// prefixe c_: Pascal ignore la casse, fchmod ET FChmod = doublon
function c_fchmod(fd: cint; mode: cuint): cint; cdecl; external 'c' name 'fchmod';
function c_futimens(fd: cint; times: Pointer): cint; cdecl;
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
  Result := c_fchmod(AFd, cuint(AMode));
end;

function FUTimens(AFd: cint; ATimes: Pointer): cint;
begin
  Result := c_futimens(AFd, ATimes);
end;
{$ENDIF}

// Le nom designe-t-il ENCORE le dossier vide? Resserre la fenetre sans la
// fermer: POSIX ne retire pas un dossier par son descripteur.
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
  // Pas Random(): previsible, il rouvrirait la course.
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

// Ni compression, ni chiffrement, ni reparse. 0 s'ecrit NORMAL: FILE_BASIC_INFO
// ignore un zero et garderait les attributs herites.
function CopiedAttributes(AAttrs: DWORD): DWORD;
begin
  Result := AAttrs and (FILE_ATTRIBUTE_READONLY or FILE_ATTRIBUTE_HIDDEN or
    FILE_ATTRIBUTE_SYSTEM or FILE_ATTRIBUTE_ARCHIVE or
    FILE_ATTRIBUTE_NOT_CONTENT_INDEXED_);
  if Result = 0 then Result := FILE_ATTRIBUTE_NORMAL;
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

// Mode Unix SYNTHETISE: n'existe pas ici, mais la colonne ne doit pas mentir.
procedure FillEntryFromAttrs(var AEntry: TScpEntry; AAttrs: LongWord;
  ASizeHigh, ASizeLow: LongWord; const AMTime: TFileTime);
begin
  AEntry.IsDir := (AAttrs and FILE_ATTRIBUTE_DIRECTORY) <> 0;
  AEntry.IsLink := (AAttrs and FILE_ATTRIBUTE_REPARSE_POINT) <> 0;
  // Le point de reanalyse porte la nature de sa cible: pas de second appel.
  if AEntry.IsLink then
  begin
    AEntry.TargetIsDir := AEntry.IsDir;
    AEntry.TargetKnown := True;
  end;
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
  // LEXICALE: resoudre les liens rendrait la barre d'adresse meconnaissable.
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
  // '\' APRES NativeW, qui le mangerait: « C:\dir* » liste le PARENT.
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
      if (name = '.') or (name = '..') or (name = '') then Continue;
      if n >= SCP_MAX_DIR_ENTRIES then
      begin
        AErr := MakeScpError(sekOther, 'Listing', DisplaySafeName(APath),
          Format('more than %d entries', [SCP_MAX_DIR_ENTRIES]));
        Exit(False);
      end;
      if n = Length(AEntries) then
        SetLength(AEntries, ScpListCapacity(n));
      AEntries[n] := Default(TScpEntry);
      AEntries[n].Name := name;
      FillEntryFromAttrs(AEntries[n], fd.dwFileAttributes,
        fd.nFileSizeHigh, fd.nFileSizeLow, fd.ftLastWriteTime);
      Inc(n);
    until not FindNextFileW(h, fd);
    // False aussi sur erreur d'E/S: un dossier lu a moitie n'est pas complet.
    if GetLastError <> ERROR_NO_MORE_FILES then
    begin
      AErr := LastErr('Listing', APath);
      Exit(False);
    end;
  finally
    SetLength(AEntries, n);
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
        // nil a la fin ET sur erreur: seul errno les separe.
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
      if n = Length(AEntries) then
        SetLength(AEntries, ScpListCapacity(n));
      AEntries[n] := Default(TScpEntry);
      AEntries[n].Name := name;
      AEntries[n].Hidden := name[1] = '.';
      if fpLStat(PChar(full), st) = 0 then
        FillEntryFromStat(AEntries[n], st)
      else
      begin
        // Illisible mais VISIBLE: la cacher serait mentir sur le contenu.
        AEntries[n].AttrsUnknown := True;
        AEntries[n].Size := -1;
      end;
      if AEntries[n].IsLink then
      begin
        AEntries[n].LinkTarget := fpReadLink(full);
        // Casse est une reponse, pas une inconnue.
        AEntries[n].TargetKnown := True;
        if fpStat(PChar(full), st) = 0 then
          AEntries[n].TargetIsDir := ModeIsDir(st.st_mode)
        else
          AEntries[n].BrokenLink := True;
      end;
      Inc(n);
    until False;
  finally
    SetLength(AEntries, n);
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
  st: BaseUnix.Stat;   // « Stat » seul designe la methode
  rc: cint;
{$ENDIF}
begin
  AEntry := Default(TScpEntry);
  AErr := NoScpError;
  AEntry.Name := LocalBaseName(APath);
  {$IFDEF WINDOWS}
  // GetFileAttributesEx ne suit pas le reparse: AFollowLink ignore, cote prudent.
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
  // Absent n'est pas illisible: confondre, c'est ecraser a l'aveugle.
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
  // Mode prive: DACL privee a la naissance, ou pas de dossier du tout.
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
    // LocalFree a pu ecraser l'erreur.
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
  // SANS REPLACE_EXISTING: n'ecrase jamais. Ecraser, c'est ReplaceAtomic.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)), 0);
  {$ELSE}
  f := LocalNormalize(AFrom);
  t := LocalNormalize(ATo);
  // rename() ecrase en silence; link() ECHOUE atomiquement si le nom existe.
  if fpLink(PChar(f), PChar(t)) = 0 then
  begin
    // Temporaire orphelin: un dechet, pas une cible fausse. Publie, mais DIT.
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
  // Pas de lien dur (FAT, certains montages): autre primitive qui refuse
  // d'ecraser. JAMAIS « verifier puis renommer ».
  if (code <> ESysEPERM) and (code <> ESysEOPNOTSUPP) and
     (code <> ESysEMLINK) and (code <> ESysEXDEV) and
     (code <> ESysEACCES) then
  begin
    AErr := LastErr('Renaming to', ATo);
    Exit(False);
  end;
  {$IFDEF RSSH_RENAMEAT2}
  // Linux >= 3.15
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
  // macOS >= 10.12, dossiers compris
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
  // Rien qui refuse d'ecraser: on REFUSE. Une reservation puis rename a sa
  // fenetre, et ne sait pas renommer un dossier.
  AErr := MakeScpError(sekUnsupported, 'Renaming to', DisplaySafeName(ATo),
    'this file system offers no rename that refuses to overwrite');
  Result := False;
  {$ENDIF}
  if not Result and (AErr.Kind = sekNone) then
    AErr := LastErr('Renaming to', ATo);
end;

{$IFDEF WINDOWS}
// Etat d'heritage compris. AReading: l'echec vient de la lecture.
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
  // Se tromper ici rouvre l'heritage sur une cible qui l'avait coupe.
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

// Sinon un fichier prive renait avec les droits du dossier.
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

{$IFDEF WINDOWS}
// DACL lue par POIGNEE (reparse refuse): celle du dossier, pas d'une jonction.
// Copie nee VIDE sous les droits du parent, DACL source posee en DERNIER, tout
// par la meme poignee; un residu non retirable est NOMME dans l'erreur.
function TLocalFileSystem.MakeDirFromSource(const ASourcePath, APath: string;
  AMode: LongWord; out AErr: TScpError): Boolean;
var
  h: THandle;
  info, made: TByHandleFileInformation;
  need, code: DWORD;
  sd: array of Byte;
  basic: TFileBasicInfo;
  control: SECURITY_DESCRIPTOR_CONTROL;
  revision: DWORD;
  secInfo: SECURITY_INFORMATION;

  // False = le dossier reste, et le message doit le dire.
  function DropByHandle: Boolean;
  var
    disp: TFileDispositionInfo;
  begin
    disp.DeleteFile := True;
    Result := SetFileInformationByHandle(h, FileDispositionInfo_, @disp,
      SizeOf(disp));
  end;

  function Residue(ADropped: Boolean): string;
  begin
    if ADropped then
      Result := 'the copy was not created'
    else
      Result := 'an empty folder was left behind';
  end;

begin
  Result := False;
  AErr := NoScpError;
  h := CreateFileW(PWideChar(NativeW(ASourcePath)),
    READ_CONTROL_ or FILE_READ_ATTRIBUTES_,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_,
    0);
  if h = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Duplicating', ASourcePath);
    Exit;
  end;
  try
    // Un partage coupe n'est pas « plus un dossier »: code lu AVANT tout appel.
    if not GetFileInformationByHandle(h, info) then
    begin
      AErr := LastErr('Duplicating', ASourcePath);
      Exit;
    end;
    if (info.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
        FILE_ATTRIBUTE_REPARSE_POINT)) <> FILE_ATTRIBUTE_DIRECTORY then
    begin
      AErr := MakeScpError(sekNotADirectory, 'Duplicating',
        DisplaySafeName(ASourcePath), 'the source is not a folder any more');
      Exit;
    end;
    // Le premier appel DOIT echouer faute de place, et pour nulle autre raison.
    need := 0;
    if GetKernelObjectSecurity(h, DACL_SECURITY_INFORMATION, nil, 0, @need)
    then
      code := ERROR_INVALID_DATA
    else
      code := GetLastError;
    if (code = ERROR_INSUFFICIENT_BUFFER) and (need > 0) then
    begin
      SetLength(sd, need);
      if GetKernelObjectSecurity(h, DACL_SECURITY_INFORMATION, @sd[0], need,
         @need) then
        code := ERROR_SUCCESS
      else
        code := GetLastError;
    end
    else if code = ERROR_INSUFFICIENT_BUFFER then
      code := ERROR_INVALID_DATA;
    if code <> ERROR_SUCCESS then
    begin
      AErr := MakeScpError(sekAttrRefused, 'Duplicating',
        DisplaySafeName(ASourcePath),
        Format('the permissions of the source could not be read (Windows ' +
          'error %d); the copy was not created', [code]));
      Exit;
    end;
  finally
    CloseHandle(h);
  end;
  if not CreateDirectoryW(PWideChar(NativeW(APath)), nil) then
  begin
    AErr := LastErr('Creating folder', APath);
    Exit;
  end;
  // Par POIGNEE, pas par nom: tout, retrait compris, vise ce dossier-la.
  h := CreateFileW(PWideChar(NativeW(APath)), DELETE_ or
    FILE_READ_ATTRIBUTES_ or FILE_WRITE_ATTRIBUTES_ or WRITE_DAC_,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_, nil,
    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS or FILE_FLAG_OPEN_REPARSE_POINT_,
    0);
  if h = INVALID_HANDLE_VALUE then
  begin
    code := GetLastError;
    // Vide et a nous; RemoveDirectory ne suivrait pas une jonction.
    if RemoveDirectoryW(PWideChar(NativeW(APath))) then
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the new folder could not be opened ' +
          'to receive the protections of the source (Windows error %d); ' +
          'the copy was not created', [code]))
    else
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the new folder could not be opened ' +
          'to receive the protections of the source (Windows error %d); ' +
          'an empty folder was left behind', [code]));
    Exit;
  end;
  try
    if not GetFileInformationByHandle(h, made) then
    begin
      code := GetLastError;
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the new folder could not be ' +
          'examined (Windows error %d); %s',
          [code, Residue(DropByHandle)]));
      Exit;
    end;
    // Remplace entre-temps: PAS le notre, on n'y touche pas.
    if (made.dwFileAttributes and (FILE_ATTRIBUTE_DIRECTORY or
        FILE_ATTRIBUTE_REPARSE_POINT)) <> FILE_ATTRIBUTE_DIRECTORY then
    begin
      AErr := MakeScpError(sekOutsideRoot, 'Creating folder',
        DisplaySafeName(APath), 'the new folder was replaced before its ' +
        'attributes could be set');
      Exit;
    end;
    basic := Default(TFileBasicInfo);
    basic.FileAttributes := CopiedAttributes(info.dwFileAttributes);
    if not SetFileInformationByHandle(h, FileBasicInfo_, @basic,
       SizeOf(basic)) then
    begin
      code := GetLastError;
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the attributes of the source could ' +
          'not be given to the copy (Windows error %d); %s',
          [code, Residue(DropByHandle)]));
      Exit;
    end;
    // En DERNIER: une DACL sans DELETE pour nous interdirait jusqu'au retrait.
    // Drapeau d'heritage: meme piege que CopyDaclRaw.
    control := 0;
    revision := 0;
    if not GetSecurityDescriptorControl(PSECURITY_DESCRIPTOR(@sd[0]),
       @control, @revision) then
    begin
      code := GetLastError;
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the permissions of the source could ' +
          'not be read back (Windows error %d); %s',
          [code, Residue(DropByHandle)]));
      Exit;
    end;
    if (control and SE_DACL_PROTECTED_) <> 0 then
      secInfo := DACL_SECURITY_INFORMATION or
        PROTECTED_DACL_SECURITY_INFORMATION_
    else
      secInfo := DACL_SECURITY_INFORMATION or
        UNPROTECTED_DACL_SECURITY_INFORMATION_;
    if not SetKernelObjectSecurity(h, secInfo, @sd[0]) then
    begin
      code := GetLastError;
      AErr := MakeScpError(sekAttrRefused, 'Creating folder',
        DisplaySafeName(APath), Format('the permissions of the source could ' +
          'not be given to the copy (Windows error %d); %s',
          [code, Residue(DropByHandle)]));
      Exit;
    end;
  finally
    CloseHandle(h);
  end;
  Result := True;
end;

// Par poignees: la source lue, le temporaire ecrit. Lecture seule comprise:
// DeleteTemp sait la lever.
function TLocalFileSystem.CopyAttributesFrom(ASource, ATarget: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  info: TByHandleFileInformation;
  basic: TFileBasicInfo;
  code: DWORD;
begin
  Result := False;
  AErr := NoScpError;
  if not GetFileInformationByHandle(TLocalHandle(ASource).H, info) then
  begin
    code := GetLastError;
    AErr := MakeScpError(sekAttrRefused, 'Duplicating',
      DisplaySafeName(TLocalHandle(ASource).Path),
      Format('the attributes of the source could not be read (Windows ' +
        'error %d); the copy was not published', [code]));
    Exit;
  end;
  basic := Default(TFileBasicInfo);
  basic.FileAttributes := CopiedAttributes(info.dwFileAttributes);
  if not SetFileInformationByHandle(TLocalHandle(ATarget).H, FileBasicInfo_,
     @basic, SizeOf(basic)) then
  begin
    code := GetLastError;
    AErr := MakeScpError(sekAttrRefused, 'Duplicating',
      DisplaySafeName(TLocalHandle(ASource).Path),
      Format('the attributes of the source could not be given to the copy ' +
        '(Windows error %d); the copy was not published', [code]));
    Exit;
  end;
  Result := True;
end;

// Lecture seule: DeleteFileW refuse. Attribut leve et retrait par une meme
// poignee, sans suivre de lien.
function TLocalFileSystem.DeleteTemp(const APath: string;
  out AErr: TScpError): Boolean;
var
  h: THandle;
  code: DWORD;
  info: TByHandleFileInformation;
  basic: TFileBasicInfo;
  disp: TFileDispositionInfo;
begin
  AErr := NoScpError;
  if DeleteFileW(PWideChar(NativeW(APath))) then Exit(True);
  code := GetLastError;
  AErr := LastErr('Deleting', APath);
  Result := False;
  if code <> ERROR_ACCESS_DENIED then Exit;
  h := CreateFileW(PWideChar(NativeW(APath)), DELETE_ or
    FILE_READ_ATTRIBUTES_ or FILE_WRITE_ATTRIBUTES_,
    FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE_, nil,
    OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h = INVALID_HANDLE_VALUE then Exit;
  try
    if (not GetFileInformationByHandle(h, info)) or
       ((info.dwFileAttributes and (FILE_ATTRIBUTE_READONLY or
         FILE_ATTRIBUTE_DIRECTORY or FILE_ATTRIBUTE_REPARSE_POINT)) <>
         FILE_ATTRIBUTE_READONLY) then
      Exit;
    basic := Default(TFileBasicInfo);
    basic.FileAttributes := CopiedAttributes(info.dwFileAttributes and
      (not FILE_ATTRIBUTE_READONLY));
    disp.DeleteFile := True;
    if SetFileInformationByHandle(h, FileBasicInfo_, @basic, SizeOf(basic))
       and SetFileInformationByHandle(h, FileDispositionInfo_, @disp,
         SizeOf(disp)) then
    begin
      AErr := NoScpError;
      Result := True;
    end;
  finally
    CloseHandle(h);
  end;
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
  Result := True;   // les modes sont poses a la creation
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
  // DACL recopiee AVANT la publication, ou pas de remplacement.
  if not CopyDacl(ATo, AFrom, AErr) then Exit(False);
  // Lecture seule levee le temps du rename; le nouveau contenu la reprend.
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
    // sinon le temporaire ne s'efface plus
    SetFileAttributesW(PWideChar(NativeW(AFrom)), FILE_ATTRIBUTE_NORMAL);
    Exit(False);
  end;
  // WRITE_THROUGH: rend la main une fois SUR LE SUPPORT.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH_);
  if not Result then
  begin
    AErr := LastErr('Replacing', ATo);
    SetFileAttributesW(PWideChar(NativeW(AFrom)), FILE_ATTRIBUTE_NORMAL);
    // Cible intacte mais peut-etre plus en lecture seule: cela se dit.
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
  // SHARE_READ seul: pas de lecture pendant qu'un autre reecrit.
  // OPEN_REPARSE_POINT: un nom devenu lien echoue au lieu de lire ailleurs.
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_READ,
    FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := WithAccessContext(LastErr('Opening', APath), acRead);
    h.Free;
    Exit(False);
  end;
  // On juge ce qui a ete OUVERT, pas le chemin.
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
  // O_NOFOLLOW ne couvre que le DERNIER composant. O_NONBLOCK: une FIFO
  // glissee la attendrait un ecrivain jusqu'a la fin des temps.
  h.Fd := fpOpen(PChar(LocalNormalize(APath)),
    O_RDONLY or O_NOFOLLOW or O_NONBLOCK);
  if h.Fd < 0 then
  begin
    AErr := WithAccessContext(LastErr('Opening', APath), acRead);
    h.Free;
    Exit(False);
  end;
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
  // PRIVE des la naissance; ReplaceAtomic lui donnera la DACL de la cible.
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
    // CREATE_NEW echoue sur QUOI QUE CE SOIT, lien compris.
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
  // Jamais a travers un lien: un partiel devenu lien ferait ecrire ailleurs.
  // Lecture aussi: le prefixe se relit par CETTE poignee.
  {$IFDEF WINDOWS}
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_READ or GENERIC_WRITE,
    0, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Reopening', APath);
    h.Free;
    Exit(False);
  end;
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
  // O_NONBLOCK: contre une FIFO a la place du partiel.
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
  // Tronque: au-dela de l'offset confirme, on ne sait rien.
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
  // Un offset dont les 32 bits bas valent $FFFFFFFF rend la meme valeur.
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
  // Le disque plein se revele souvent ICI, pas a l'ecriture.
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
  // atime: UTIME_OMIT, ni relue ni inventee
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
  // Pas de mode ici: les ACL passent par ReplaceAtomic.
  Result := True;
  {$ELSE}
  h := TLocalHandle(AHandle);
  Result := FChmod(h.Fd, AMode and LongWord(&07777)) = 0;
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the mode of',
      DisplaySafeName(h.Path), Format('errno %d', [fpGetErrno]));
  {$ENDIF}
end;

{$IFDEF WINDOWS}
// Enfants ouverts relativement a la POIGNEE. APath ne sert qu'aux messages.
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
    // Enumerer PUIS supprimer: l'inverse saute des entrees.
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
      // Un lien est ouvert LUI-MEME et part seul. Sans droit de lister, on
      // retente sans: un fichier illisible se supprime quand meme.
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
        // le listing a vieilli
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
// openat/unlinkat: tout DANS le dossier ouvert. Le listing par chemin ne
// fournit que des noms.
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
    // Seul un vrai dossier s'ouvre; le reste (fichier, lien, tube) part par unlink.
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
    // EACCES: fichier illisible, supprime quand meme; un dossier, lui, le dira.
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
  // Un lien part LUI-MEME: y descendre effacerait sa cible.
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
    // Ce qui est OUVERT, pas ce que le lstat a vu.
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
  // Racine aussi RELATIVE a son parent: un rename concurrent ne deroute rien.
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

function LocalHomePath: string;
begin
  {$IFDEF WINDOWS}
  // Qualifie: celui de l'unite Windows masque celui de SysUtils.
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
    // Le TYPE, pas le nom: GetVolumeInformation bloque sur un partage hors ligne.
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
  // /proc/mounts vient du noyau: ne bloque jamais.
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
