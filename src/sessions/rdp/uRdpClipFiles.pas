{ FILEGROUPDESCRIPTORW de cliprdr (MS-RDPECLIP), sans FreeRDP. Tout ce qui
  vient du serveur est HOSTILE: un seul chemin refuse ecarte le lot entier,
  un collage partiel serait un mensonge.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uRdpClipFiles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  // Depasser = REFUS, pas troncature.
  RDPCLIP_MAX_FILES = 4096;
  RDPCLIP_MAX_TOTAL_BYTES = Int64(256) * 1024 * 1024;
  RDPCLIP_MAX_DEPTH = 32;
  // assez petit pour que l'annulation reste reactive
  RDPCLIP_CHUNK_BYTES = 512 * 1024;

  // FILEDESCRIPTORW.dwFlags
  FD_ATTRIBUTES = $0004;
  FD_WRITESTIME = $0020;
  FD_FILESIZE = $0040;
  FD_PROGRESSUI = $4000;
  FILE_ATTRIBUTE_DIRECTORY_ = $10;
  // faSymLink sans l'avertissement de portabilite
  FA_SYMLINK_ = $0400;
  FILE_ATTRIBUTE_NORMAL_ = $80;
  // 4 + 16 + 8 + 8 + 4 + 3*8 + 4 + 4 + 260*2, aucun bourrage
  FILEDESC_W_SIZE = 592;
  // cFileName: 260 WCHAR, NUL compris
  FILEDESC_NAME_MAX = 259;

type
  // Capturee a l'ENUMERATION et reverifiee avant envoi: le chemin, lui, une
  // jonction posee entre-temps le ferait mentir.
  TRdpFileId = record
    Known: Boolean;
    {$IFDEF WINDOWS}
    Volume, IdHigh, IdLow: LongWord;
    {$ELSE}
    Dev, Ino: QWord;
    {$ENDIF}
  end;

  TRdpClipFile = record
    RelPath: UnicodeString;  // tel que sur le fil, separateurs '\'
    LocalRel: string;        // valide pour CE poste
    IsDir: Boolean;
    SizeKnown: Boolean;
    Size: Int64;
    WriteTime: Int64;        // FILETIME (100 ns depuis 1601), 0 = inconnue
    LocalPath: string;       // envoi seulement
    Id: TRdpFileId;          // envoi seulement
  end;
  TRdpClipFileArray = array of TRdpClipFile;

// Chemin trop long: EConvertError (l'enumeration l'a deja refuse).
function BuildFileGroupDescriptor(const AFiles: TRdpClipFileArray): TBytes;

// Premiere entree invalide: False, AFiles vide.
function ParseFileGroupDescriptor(AData: PByte; ALen: SizeUInt;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;

function RdpClipSafeRelPath(const ARel: UnicodeString; out ALocalRel: string;
  out AWhy: string): Boolean;

// Pre-ordre. Liens JAMAIS suivis: une jonction vers C:\ enverrait le disque
// entier. Enumeration par poignee, identite reverifiee a chaque descente.
function EnumerateLocalTree(const ARoots: array of string;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;

// EXCLUSIF: echouer si le nom existe, c'est LA garantie.
function RdpClipMakeDirOwnerOnly(const APath: string): Boolean;

// Un lien part seul, meme pose en pleine course; sa cible reste.
procedure RdpClipRemoveTree(const APath: string);

// False: ne PAS l'annoncer, on ne saurait pas verifier ce qu'on sert.
function CaptureLocalFileId(const APath: string; out AId: TRdpFileId): Boolean;

// Identite inconnue: False.
function HandleMatchesId(AHandle: THandle; const AId: TRdpFileId): Boolean;

// Ouvre un fichier a servir; echec = EFOpenError. Unix: O_NOFOLLOW et
// O_NONBLOCK, un tube pose a la place du fichier ne fige pas le transport.
function RdpClipOpenServed(const APath: string): THandleStream;

implementation

{$IFNDEF WINDOWS}
uses
  BaseUnix{$IFDEF LINUX}, Syscall{$ENDIF}, uRshSafeSave;
{$ENDIF}

{$IFDEF WINDOWS}
type
  // BY_HANDLE_FILE_INFORMATION, aucun bourrage
  TByHandleInfo_ = record
    dwFileAttributes: LongWord;
    ftCreation, ftAccess, ftWrite: array[0..1] of LongWord;
    dwVolumeSerialNumber, nFileSizeHigh, nFileSizeLow, nNumberOfLinks,
    nFileIndexHigh, nFileIndexLow: LongWord;
  end;

const
  FILE_READ_ATTRIBUTES_ = $0080;
  FILE_LIST_DIRECTORY_ = 1;   // sur un fichier, le meme bit = READ_DATA
  FILE_SHARE_ALL_ = 7;   // read + write + delete
  OPEN_EXISTING_ = 3;
  FILE_FLAG_BACKUP_SEMANTICS_ = $02000000;
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
  ERROR_NO_MORE_FILES_ = 18;
  // classe GetFileInformationByHandleEx
  FILE_ID_BOTH_DIR_INFO_ = 10;

type
  // FILE_ID_BOTH_DIR_INFO, bourrage EXPLICITE: ShortName commence a 70,
  // FileId se realigne a 96, le nom (non termine) suit a 104.
  TIdBothDirInfo_ = packed record
    NextEntryOffset, FileIndex: LongWord;
    CreationTime, LastAccessTime, LastWriteTime, ChangeTime: Int64;
    EndOfFile, AllocationSize: Int64;
    FileAttributes, FileNameLength, EaSize: LongWord;
    ShortNameLength, Pad1: Byte;
    ShortName: array[0..11] of WideChar;
    Pad2: Word;
    FileId: Int64;
    FileName: array[0..0] of WideChar;
  end;
  PIdBothDirInfo_ = ^TIdBothDirInfo_;

  TDirEntry_ = record
    Name: UnicodeString;
    Attrs: LongWord;
    Size, WriteTime: Int64;
    IdHigh, IdLow: LongWord;
  end;
  TDirEntryArray_ = array of TDirEntry_;

function CreateFileW(AName: PWideChar; AAccess, AShare: LongWord;
  ASecurity: Pointer; ADisposition, AFlags: LongWord;
  ATemplate: THandle): THandle; stdcall; external 'kernel32.dll';
function CloseHandle(AHandle: THandle): LongBool; stdcall;
  external 'kernel32.dll';
function GetFileInformationByHandle(AHandle: THandle;
  var AInfo: TByHandleInfo_): LongBool; stdcall; external 'kernel32.dll';
function GetFileInformationByHandleEx(AHandle: THandle; AClass: LongWord;
  AInfo: Pointer; ASize: LongWord): LongBool; stdcall;
  external 'kernel32.dll';
function CreateDirectoryW(APath: PWideChar; ASecurity: Pointer): LongBool;
  stdcall; external 'kernel32.dll';
function ConvertStringSecurityDescriptorToSecurityDescriptorW(
  AText: PWideChar; ARevision: LongWord; out ASd: Pointer;
  ASize: PLongWord): LongBool; stdcall; external 'advapi32.dll';
function LocalFree(AMem: Pointer): Pointer; stdcall; external 'kernel32.dll';

// Seul le lien FINAL n'est pas suivi: l'appelant verifie l'identite.
function OpenNoFollow(const APath: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(APath)),
    FILE_READ_ATTRIBUTES_ or FILE_LIST_DIRECTORY_, FILE_SHARE_ALL_, nil,
    OPEN_EXISTING_, FILE_FLAG_BACKUP_SEMANTICS_ or
    FILE_FLAG_OPEN_REPARSE_POINT_, 0);
end;

// Listing coupe: False et AEntries VIDE, jamais un partiel qui se croit complet.
function ListDirByHandle(AHandle: THandle; out AEntries: TDirEntryArray_;
  out ACode: LongWord): Boolean;
var
  buf: array of Byte;
  p: PIdBothDirInfo_;
  off: LongWord;
  n: Integer;
  name: UnicodeString;
begin
  Result := False;
  AEntries := nil;
  ACode := 0;
  n := 0;
  buf := nil;
  SetLength(buf, 64 * 1024);
  while True do
  begin
    if not GetFileInformationByHandleEx(AHandle, FILE_ID_BOTH_DIR_INFO_,
       @buf[0], Length(buf)) then
    begin
      ACode := GetLastOSError;
      if ACode = ERROR_NO_MORE_FILES_ then
        Break;
      SetLength(AEntries, 0);
      Exit;
    end;
    off := 0;
    repeat
      p := PIdBothDirInfo_(@buf[off]);
      name := '';
      SetLength(name, p^.FileNameLength div 2);
      if name <> '' then
        Move(p^.FileName[0], name[1], p^.FileNameLength);
      if (name <> '.') and (name <> '..') and (name <> '') then
      begin
        if n = Length(AEntries) then
          SetLength(AEntries, 16 + n * 2);
        AEntries[n].Name := name;
        AEntries[n].Attrs := p^.FileAttributes;
        AEntries[n].Size := p^.EndOfFile;
        AEntries[n].WriteTime := p^.LastWriteTime;
        AEntries[n].IdHigh := LongWord(p^.FileId shr 32);
        AEntries[n].IdLow := LongWord(p^.FileId);
        Inc(n);
      end;
      if p^.NextEntryOffset = 0 then
        Break;
      Inc(off, p^.NextEntryOffset);
    until False;
  end;
  SetLength(AEntries, n);
  ACode := 0;
  Result := True;
end;

const
  // OW = proprietaire de chaque objet, SY pour antivirus et indexation,
  // D:P coupe l'heritage du parent.
  CLIP_DIR_SDDL: WideString = 'D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)';

function RdpClipMakeDirOwnerOnly(const APath: string): Boolean;
type
  TSecAttrs_ = record
    nLength: LongWord;
    lpSd: Pointer;
    bInherit: LongBool;
  end;
var
  sd: Pointer;
  sa: TSecAttrs_;
begin
  Result := False;
  sd := nil;
  if not ConvertStringSecurityDescriptorToSecurityDescriptorW(
     PWideChar(CLIP_DIR_SDDL), 1, sd, nil) then
    Exit;
  try
    sa.nLength := SizeOf(sa);
    sa.lpSd := sd;
    sa.bInherit := False;
    // echoue si le nom existe: jamais la jonction posee par un autre
    Result := CreateDirectoryW(PWideChar(UTF8Decode(APath)), @sa);
  finally
    LocalFree(sd);
  end;
end;

procedure RdpClipRemoveTree(const APath: string);

  procedure RemoveLevel(const ADir: string; ADepth: Integer;
    const AWant: TRdpFileId);
  var
    h: THandle;
    info: TByHandleInfo_;
    entries: TDirEntryArray_;
    want: TRdpFileId;
    code: LongWord;
    e: Integer;
    sub: string;
  begin
    // au pire du temporaire reste: mieux qu'effacer a l'aveugle
    if ADepth > RDPCLIP_MAX_DEPTH * 2 then
      Exit;
    h := OpenNoFollow(ADir);
    if h = THandle(-1) then
      Exit;
    try
      info := Default(TByHandleInfo_);
      // Juge sur la POIGNEE: un lien pose entre-temps se voit ici.
      if (not GetFileInformationByHandle(h, info)) or
         ((info.dwFileAttributes and FA_SYMLINK_) <> 0) or
         ((info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY_) = 0) then
        Exit;
      // LE dossier liste par le parent; un substitut, meme vrai, reste intact.
      if AWant.Known and
         ((info.dwVolumeSerialNumber <> AWant.Volume) or
          (info.nFileIndexHigh <> AWant.IdHigh) or
          (info.nFileIndexLow <> AWant.IdLow)) then
        Exit;
      if not ListDirByHandle(h, entries, code) then
        Exit;
      for e := 0 to High(entries) do
      begin
        sub := ADir + PathDelim + UTF8Encode(entries[e].Name);
        if (entries[e].Attrs and FA_SYMLINK_) <> 0 then
        begin
          if (entries[e].Attrs and FILE_ATTRIBUTE_DIRECTORY_) <> 0 then
            RemoveDir(sub)
          else
            SysUtils.DeleteFile(sub);
        end
        else if (entries[e].Attrs and FILE_ATTRIBUTE_DIRECTORY_) <> 0 then
        begin
          want.Known := True;
          want.Volume := info.dwVolumeSerialNumber;
          want.IdHigh := entries[e].IdHigh;
          want.IdLow := entries[e].IdLow;
          RemoveLevel(sub, ADepth + 1, want);
          RemoveDir(sub);
        end
        else
          SysUtils.DeleteFile(sub);
      end;
    finally
      CloseHandle(h);
    end;
  end;

var
  noWant: TRdpFileId;
begin
  if APath = '' then
    Exit;
  // racine sans identite attendue: creee par nous, en exclusif
  noWant := Default(TRdpFileId);
  RemoveLevel(APath, 0, noWant);
  RemoveDir(APath);
end;

function CaptureLocalFileId(const APath: string; out AId: TRdpFileId): Boolean;
var
  h: THandle;
  info: TByHandleInfo_;
begin
  AId := Default(TRdpFileId);
  Result := False;
  h := CreateFileW(PWideChar(UTF8Decode(APath)), FILE_READ_ATTRIBUTES_,
    FILE_SHARE_ALL_, nil, OPEN_EXISTING_, FILE_FLAG_BACKUP_SEMANTICS_, 0);
  if h = THandle(-1) then
    Exit;
  try
    info := Default(TByHandleInfo_);
    if not GetFileInformationByHandle(h, info) then
      Exit;
    AId.Known := True;
    AId.Volume := info.dwVolumeSerialNumber;
    AId.IdHigh := info.nFileIndexHigh;
    AId.IdLow := info.nFileIndexLow;
    Result := True;
  finally
    CloseHandle(h);
  end;
end;

function HandleMatchesId(AHandle: THandle; const AId: TRdpFileId): Boolean;
var
  info: TByHandleInfo_;
begin
  Result := False;
  if not AId.Known then
    Exit;
  info := Default(TByHandleInfo_);
  if not GetFileInformationByHandle(AHandle, info) then
    Exit;
  Result := (info.dwVolumeSerialNumber = AId.Volume) and
    (info.nFileIndexHigh = AId.IdHigh) and (info.nFileIndexLow = AId.IdLow);
end;

function RdpClipOpenServed(const APath: string): THandleStream;
begin
  Result := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
end;
{$ELSE}
const
  {$IFDEF LINUX}
  O_CLOEXEC_ = $80000;
  AT_SYMLINK_NOFOLLOW_ = $100;
  AT_REMOVEDIR_ = $200;
    {$IF DEFINED(CPUX86_64)}
    SYSCALL_FSTATAT_ = 262; {$DEFINE RSSH_FSTATAT}   // newfstatat
    SYSCALL_GETDENTS64_ = 217; {$DEFINE RSSH_LISTFD}
    {$ELSEIF DEFINED(CPUAARCH64)}
    SYSCALL_FSTATAT_ = 79; {$DEFINE RSSH_FSTATAT}
    SYSCALL_GETDENTS64_ = 61; {$DEFINE RSSH_LISTFD}
    {$ELSEIF DEFINED(CPUI386)}
    SYSCALL_FSTATAT_ = 300; {$DEFINE RSSH_FSTATAT}   // fstatat64, Stat FPC = stat64
    SYSCALL_GETDENTS64_ = 220; {$DEFINE RSSH_LISTFD}
    {$ENDIF}
  {$ELSE}
  // absents du BaseUnix Darwin; <sys/fcntl.h>
  O_NOFOLLOW = $100;
  O_DIRECTORY = $100000;
  O_CLOEXEC_ = $1000000;
  AT_SYMLINK_NOFOLLOW_ = $20;
  AT_REMOVEDIR_ = $80;
    {$IF DEFINED(CPUAARCH64)}
    {$DEFINE RSSH_FSTATAT}   // arm64: fstatat EST la variante inode 64 bits
    {$DEFINE RSSH_LISTFD}
    {$ELSEIF DEFINED(CPUX86_64)}
    {$DEFINE RSSH_LISTFD}   // via les symboles $INODE64
    {$ENDIF}
  {$ENDIF}

{$IFDEF LINUX}
function OpenAtNoFollow(ADir: cint; const AName: string; AFlags: cint): cint;
begin
  Result := do_syscall(syscall_nr_openat, TSysParam(ADir),
    TSysParam(PChar(AName)),
    TSysParam(O_RDONLY or O_NOFOLLOW or AFlags or O_CLOEXEC_), TSysParam(0));
end;

{$IFDEF RSSH_FSTATAT}
function FStatAtNoFollow(ADir: cint; const ADirPath, AName: string;
  out ASt: Stat): Boolean;
begin
  ASt := Default(Stat);
  Result := do_syscall(SYSCALL_FSTATAT_, TSysParam(ADir),
    TSysParam(PChar(AName)), TSysParam(@ASt),
    TSysParam(AT_SYMLINK_NOFOLLOW_)) = 0;
end;
{$ENDIF}

function UnlinkAt_(ADir: cint; const AName: string; AIsDir: Boolean): cint;
var
  flags: cint;
begin
  flags := 0;
  if AIsDir then flags := AT_REMOVEDIR_;
  Result := do_syscall(syscall_nr_unlinkat, TSysParam(ADir),
    TSysParam(PChar(AName)), TSysParam(flags));
end;

{$IFDEF RSSH_LISTFD}
function ListDirFd(AFd: cint; const ADirPath: string;
  out ANames: TStringArray): Boolean;
var
  buf: array[0..16383] of Byte;
  got, off, n: PtrInt;
  reclen: Word;
  name: string;
begin
  Result := False;
  ANames := nil;
  n := 0;
  repeat
    got := PtrInt(do_syscall(SYSCALL_GETDENTS64_, TSysParam(AFd),
      TSysParam(@buf[0]), TSysParam(SizeOf(buf))));
    if got < 0 then
      Exit;
    off := 0;
    // linux_dirent64: ino 8, off 8, reclen 2, type 1, nom
    while off < got do
    begin
      reclen := PWord(@buf[off + 16])^;
      if reclen = 0 then
        Exit;
      name := StrPas(PChar(@buf[off + 19]));
      Inc(off, reclen);
      if (name = '.') or (name = '..') then
        Continue;
      if n = Length(ANames) then
        SetLength(ANames, 16 + n * 2);
      ANames[n] := name;
      Inc(n);
    end;
  until got = 0;
  SetLength(ANames, n);
  Result := True;
end;
{$ENDIF}
{$ELSE}
function c_openat(dirfd: cint; path: PChar; flags: cint): cint; cdecl;
  external 'c' name 'openat';
function c_unlinkat(dirfd: cint; path: PChar; flags: cint): cint; cdecl;
  external 'c' name 'unlinkat';
{$IFDEF RSSH_LISTFD}
{$IFDEF CPUX86_64}
function c_fdopendir(fd: cint): Pointer; cdecl;
  external 'c' name 'fdopendir$INODE64';
function c_readdir(d: Pointer): PByte; cdecl;
  external 'c' name 'readdir$INODE64';
{$ELSE}
function c_fdopendir(fd: cint): Pointer; cdecl; external 'c' name 'fdopendir';
function c_readdir(d: Pointer): PByte; cdecl; external 'c' name 'readdir';
{$ENDIF}
function c_closedir(d: Pointer): cint; cdecl; external 'c' name 'closedir';
function c_errno: pcint; cdecl; external 'c' name '__error';

function ListDirFd(AFd: cint; const ADirPath: string;
  out ANames: TStringArray): Boolean;
var
  dup: cint;
  d: Pointer;
  e: PByte;
  n: Integer;
  name: string;
begin
  Result := False;
  ANames := nil;
  n := 0;
  // fdopendir garde le fd et closedir le ferme: on lui donne une copie
  dup := FpDup(AFd);
  if dup < 0 then
    Exit;
  d := c_fdopendir(dup);
  if d = nil then
  begin
    FpClose(dup);
    Exit;
  end;
  try
    repeat
      // readdir rend nil a la fin ET sur erreur: seul errno tranche
      c_errno^ := 0;
      e := c_readdir(d);
      if e = nil then
        Break;
      // dirent inode 64: ino 8, seekoff 8, reclen 2, namlen 2, type 1, nom
      SetString(name, PChar(e + 21), PWord(e + 18)^);
      if (name = '.') or (name = '..') then
        Continue;
      if n = Length(ANames) then
        SetLength(ANames, 16 + n * 2);
      ANames[n] := name;
      Inc(n);
    until False;
    Result := c_errno^ = 0;
  finally
    c_closedir(d);
  end;
  SetLength(ANames, n);
  if not Result then
    ANames := nil;
end;
{$ENDIF}

function UnlinkAt_(ADir: cint; const AName: string; AIsDir: Boolean): cint;
var
  flags: cint;
begin
  flags := 0;
  if AIsDir then flags := AT_REMOVEDIR_;
  Result := c_unlinkat(ADir, PChar(AName), flags);
end;
{$IFDEF RSSH_FSTATAT}
function c_fstatat(dirfd: cint; path: PChar; var st: Stat;
  flags: cint): cint; cdecl; external 'c' name 'fstatat';
{$ENDIF}

function OpenAtNoFollow(ADir: cint; const AName: string; AFlags: cint): cint;
begin
  Result := c_openat(ADir, PChar(AName),
    O_RDONLY or O_NOFOLLOW or AFlags or O_CLOEXEC_);
end;

{$IFDEF RSSH_FSTATAT}
function FStatAtNoFollow(ADir: cint; const ADirPath, AName: string;
  out ASt: Stat): Boolean;
begin
  ASt := Default(Stat);
  Result := c_fstatat(ADir, PChar(AName), ASt, AT_SYMLINK_NOFOLLOW_) = 0;
end;
{$ENDIF}
{$ENDIF}

{$IFNDEF RSSH_FSTATAT}
// Archi sans fstatat connu: lstat par chemin. La descente reste ancree (le
// fd enfant est compare), seule la capture des metadonnees perd l'ancrage.
function FStatAtNoFollow(ADir: cint; const ADirPath, AName: string;
  out ASt: Stat): Boolean;
begin
  ASt := Default(Stat);
  Result := fpLStat(PChar(ADirPath + '/' + AName), ASt) = 0;
end;
{$ENDIF}

{$IFNDEF RSSH_LISTFD}
// Archi sans listing par fd: noms par chemin, gardes seulement si le chemin
// designe encore le fd avant ET apres. Un echec de FindFirst en est un: « . »
// est toujours la.
function ListDirFd(AFd: cint; const ADirPath: string;
  out ANames: TStringArray): Boolean;

  function PathIsFd: Boolean;
  var
    ps, fs: Stat;
  begin
    Result := (fpLStat(PChar(ADirPath), ps) = 0) and
      (not fpS_ISLNK(ps.st_mode)) and (fpFStat(AFd, fs) = 0) and
      (ps.st_dev = fs.st_dev) and (ps.st_ino = fs.st_ino);
  end;

var
  sr: TSearchRec;
  n: Integer;
begin
  Result := False;
  ANames := nil;
  n := 0;
  if not PathIsFd then
    Exit;
  if FindFirst(ADirPath + '/*', faAnyFile, sr) <> 0 then
    Exit;
  try
    repeat
      if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = '') then
        Continue;
      if n = Length(ANames) then
        SetLength(ANames, 16 + n * 2);
      ANames[n] := sr.Name;
      Inc(n);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  SetLength(ANames, n);
  Result := PathIsFd;
  if not Result then
    ANames := nil;
end;
{$ENDIF}

function CaptureLocalFileId(const APath: string; out AId: TRdpFileId): Boolean;
var
  st: Stat;
begin
  AId := Default(TRdpFileId);
  Result := False;
  if fpLStat(PChar(APath), st) <> 0 then
    Exit;
  if fpS_ISLNK(st.st_mode) then
    Exit;
  AId.Known := True;
  AId.Dev := QWord(st.st_dev);
  AId.Ino := QWord(st.st_ino);
  Result := True;
end;

function HandleMatchesId(AHandle: THandle; const AId: TRdpFileId): Boolean;
var
  st: Stat;
begin
  Result := False;
  if not AId.Known then
    Exit;
  if fpFStat(cint(AHandle), st) <> 0 then
    Exit;
  Result := (QWord(st.st_dev) = AId.Dev) and (QWord(st.st_ino) = AId.Ino);
end;

function RdpClipMakeDirOwnerOnly(const APath: string): Boolean;
begin
  // mkdir echoue si le nom existe: jamais le lien pose par un autre
  Result := FpMkdir(PChar(APath), &700) = 0;
end;

procedure RdpClipRemoveTree(const APath: string);

  // Tout relatif au fd: un lien glisse en route part lui-meme, sa cible
  // reste ou elle est.
  procedure EmptyFd(ADir: cint; const ADirPath: string; ADepth: Integer);
  var
    names: TStringArray;
    i: Integer;
    child: cint;
  begin
    // au pire du temporaire reste: mieux qu'effacer a l'aveugle
    if ADepth > RDPCLIP_MAX_DEPTH * 2 then
      Exit;
    if not ListDirFd(ADir, ADirPath, names) then
      Exit;
    for i := 0 to High(names) do
    begin
      child := OpenAtNoFollow(ADir, names[i], O_DIRECTORY);
      if child >= 0 then
      begin
        try
          EmptyFd(child, ADirPath + '/' + names[i], ADepth + 1);
        finally
          FpClose(child);
        end;
        UnlinkAt_(ADir, names[i], True);
      end
      else
        UnlinkAt_(ADir, names[i], False);
    end;
  end;

var
  root: string;
  fd: cint;
begin
  if APath = '' then
    Exit;
  root := ExcludeTrailingPathDelimiter(APath);
  fd := FpOpen(PChar(root), O_RDONLY or O_NOFOLLOW or O_DIRECTORY
    or O_CLOEXEC_);
  if fd < 0 then
    Exit;   // lien ou disparu: plus rien a nous
  try
    EmptyFd(fd, root, 0);
  finally
    FpClose(fd);
  end;
  FpRmdir(PChar(root));   // rmdir refuse un lien
end;

function RdpClipOpenServed(const APath: string): THandleStream;
var
  fd: cint;
  st: Stat;
begin
  // O_NONBLOCK: inoffensif sur un fichier regulier, vital si un tube a pris
  // sa place; l'identite (dev/ino) est reverifiee ensuite par l'appelant.
  fd := FpOpen(PChar(APath), O_RDONLY or O_NOFOLLOW or O_NONBLOCK
    or O_CLOEXEC_);
  if fd < 0 then
    raise EFOpenError.CreateFmt('Cannot open %s', [APath]);
  if (fpFStat(fd, st) <> 0) or (not fpS_ISREG(st.st_mode)) then
  begin
    FpClose(fd);
    raise EFOpenError.CreateFmt('%s is not a regular file', [APath]);
  end;
  Result := TOwnedHandleStream.Create(fd);
end;
{$ENDIF}

function BuildFileGroupDescriptor(const AFiles: TRdpClipFileArray): TBytes;
var
  i, base, j: Integer;
  flags, attrs: LongWord;
begin
  Result := nil;
  SetLength(Result, 4 + Length(AFiles) * FILEDESC_W_SIZE);
  FillChar(Result[0], Length(Result), 0);
  PLongWord(@Result[0])^ := LongWord(Length(AFiles));
  for i := 0 to High(AFiles) do
  begin
    base := 4 + i * FILEDESC_W_SIZE;
    flags := FD_ATTRIBUTES or FD_PROGRESSUI;
    if AFiles[i].IsDir then
      attrs := FILE_ATTRIBUTE_DIRECTORY_
    else
      attrs := FILE_ATTRIBUTE_NORMAL_;
    if (not AFiles[i].IsDir) and AFiles[i].SizeKnown then
      flags := flags or FD_FILESIZE;
    if AFiles[i].WriteTime <> 0 then
      flags := flags or FD_WRITESTIME;
    PLongWord(@Result[base])^ := flags;
    PLongWord(@Result[base + 36])^ := attrs;
    PInt64(@Result[base + 56])^ := AFiles[i].WriteTime;
    if (flags and FD_FILESIZE) <> 0 then
    begin
      PLongWord(@Result[base + 64])^ := LongWord(AFiles[i].Size shr 32);
      PLongWord(@Result[base + 68])^ := LongWord(AFiles[i].Size);
    end;
    // Tronquer changerait la cible du collage.
    if Length(AFiles[i].RelPath) > FILEDESC_NAME_MAX then
      raise EConvertError.Create('relative path too long for the descriptor');
    for j := 1 to Length(AFiles[i].RelPath) do
      PWord(@Result[base + 72 + (j - 1) * 2])^ := Word(AFiles[i].RelPath[j]);
  end;
end;

// Regles du FIL (MS-RDPECLIP vise un collage Windows): un nom qui les casse
// est refuse a l'entree comme a la sortie.
function WireComponentOk(const AComp: UnicodeString; out AWhy: string): Boolean;
const
  BAD_CHARS: UnicodeString = '<>:"/|?*';
var
  k, p: Integer;
  c: WideChar;
  stem: string;

  function Refuse(const AReason: string): Boolean;
  begin
    AWhy := AReason;
    Result := False;
  end;

begin
  AWhy := '';
  Result := False;
  if AComp = '' then Exit(Refuse('empty path component'));
  if (AComp = '.') or (AComp = '..') then
    Exit(Refuse('"." and ".." are not file names'));
  for k := 1 to Length(AComp) do
  begin
    c := AComp[k];
    if (Ord(c) < 32) or (Pos(c, BAD_CHARS) > 0) or (c = '\') then
      Exit(Refuse('forbidden character in a file name'));
  end;
  // Windows mange point et espace finaux: deux entrees, un seul fichier.
  c := AComp[Length(AComp)];
  if (c = '.') or (c = ' ') then
    Exit(Refuse('a file name may not end with a dot or a space'));
  stem := UpperCase(string(AComp));
  p := Pos('.', stem);
  if p > 1 then
    stem := Copy(stem, 1, p - 1);
  if (stem = 'CON') or (stem = 'PRN') or (stem = 'AUX') or (stem = 'NUL') or
     (((Copy(stem, 1, 3) = 'COM') or (Copy(stem, 1, 3) = 'LPT')) and
      (Length(stem) = 4) and (stem[4] in ['1'..'9'])) then
    Exit(Refuse('reserved device name'));
  Result := True;
end;

function RdpClipSafeRelPath(const ARel: UnicodeString; out ALocalRel: string;
  out AWhy: string): Boolean;
var
  comp: UnicodeString;
  i, start, depth: Integer;
  why: string;

  function Refuse(const AReason: string): Boolean;
  begin
    ALocalRel := '';
    AWhy := AReason;
    Result := False;
  end;

  function TakeComponent(AFrom, ATo: Integer): Boolean;
  var
    k: Integer;
  begin
    Result := False;
    if ATo < AFrom then Exit(Refuse('empty path component'));
    SetLength(comp, ATo - AFrom + 1);
    for k := AFrom to ATo do
      comp[k - AFrom + 1] := ARel[k];
    if not WireComponentOk(comp, why) then
      Exit(Refuse(why));
    Result := True;
  end;

begin
  Result := False;
  ALocalRel := '';
  AWhy := '';
  if ARel = '' then Exit(Refuse('empty path'));
  if Length(ARel) > FILEDESC_NAME_MAX then Exit(Refuse('path too long'));
  depth := 0;
  start := 1;
  for i := 1 to Length(ARel) + 1 do
    if (i > Length(ARel)) or (ARel[i] = '\') then
    begin
      if not TakeComponent(start, i - 1) then Exit;
      Inc(depth);
      if depth > RDPCLIP_MAX_DEPTH then Exit(Refuse('path too deep'));
      if ALocalRel <> '' then
        ALocalRel := ALocalRel + PathDelim;
      ALocalRel := ALocalRel + Utf8Encode(comp);
      start := i + 1;
    end;
  Result := True;
end;

function ParseFileGroupDescriptor(AData: PByte; ALen: SizeUInt;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;
var
  count, sizeHi: LongWord;
  i, j, nameLen: Integer;
  base: SizeUInt;
  flags, attrs: LongWord;
  name: UnicodeString;
  w: Word;
  seen: TStringList;

  function Refuse(const AReason: string): Boolean;
  begin
    SetLength(AFiles, 0);
    AWhy := AReason;
    Result := False;
  end;

begin
  Result := False;
  SetLength(AFiles, 0);
  AWhy := '';
  if (AData = nil) or (ALen < 4) then Exit(Refuse('descriptor too short'));
  count := PLongWord(AData)^;
  if count = 0 then Exit(Refuse('empty descriptor'));
  // Borne AVANT d'allouer: le compte peut mentir.
  if count > RDPCLIP_MAX_FILES then
    Exit(Refuse(Format('more than %d files', [RDPCLIP_MAX_FILES])));
  if ALen < 4 + SizeUInt(count) * FILEDESC_W_SIZE then
    Exit(Refuse('descriptor shorter than its own count'));
  SetLength(AFiles, count);
  // Insensible a la casse: sinon le second ecrase le premier en silence.
  seen := TStringList.Create;
  seen.Sorted := True;
  seen.CaseSensitive := False;
  try
  for i := 0 to Integer(count) - 1 do
  begin
    base := 4 + SizeUInt(i) * FILEDESC_W_SIZE;
    flags := PLongWord(AData + base)^;
    attrs := 0;
    if (flags and FD_ATTRIBUTES) <> 0 then
      attrs := PLongWord(AData + base + 36)^;
    AFiles[i] := Default(TRdpClipFile);
    AFiles[i].IsDir := (attrs and FILE_ATTRIBUTE_DIRECTORY_) <> 0;
    AFiles[i].SizeKnown := (not AFiles[i].IsDir) and
      ((flags and FD_FILESIZE) <> 0);
    if AFiles[i].SizeKnown then
    begin
      sizeHi := PLongWord(AData + base + 64)^;
      // Taille negative en Int64: « position >= taille » dirait complet un
      // fichier tronque.
      if (sizeHi and $80000000) <> 0 then
        Exit(Refuse('a file size beyond what a signed 64-bit count holds'));
      AFiles[i].Size := (Int64(sizeHi) shl 32) or
        Int64(PLongWord(AData + base + 68)^);
    end;
    if (flags and FD_WRITESTIME) <> 0 then
      AFiles[i].WriteTime := PInt64(AData + base + 56)^;
    nameLen := -1;
    for j := 0 to FILEDESC_NAME_MAX do
    begin
      w := PWord(AData + base + 72 + SizeUInt(j) * 2)^;
      if w = 0 then
      begin
        nameLen := j;
        Break;
      end;
    end;
    if nameLen < 0 then Exit(Refuse('file name without terminator'));
    name := '';
    SetLength(name, nameLen);
    for j := 1 to nameLen do
      name[j] := WideChar(PWord(AData + base + 72 + SizeUInt(j - 1) * 2)^);
    AFiles[i].RelPath := name;
    if not RdpClipSafeRelPath(name, AFiles[i].LocalRel, AWhy) then
      Exit(Refuse(AWhy));
    if seen.IndexOf(AFiles[i].LocalRel) >= 0 then
      Exit(Refuse(Format('two entries resolve to the same local name "%s"',
        [AFiles[i].LocalRel])));
    seen.Add(AFiles[i].LocalRel);
  end;
  finally
    seen.Free;
  end;
  Result := True;
end;

{$IFDEF WINDOWS}
function EnumerateLocalTree(const ARoots: array of string;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;
var
  n: Integer;
  rootVol: LongWord;

  function Refuse(const AReason: string): Boolean;
  begin
    SetLength(AFiles, 0);
    AWhy := AReason;
    Result := False;
  end;

  function AddEntry(const ARel: UnicodeString; const ALocal: string;
    AIsDir: Boolean; ASize, AWTime: Int64;
    AIdHigh, AIdLow: LongWord): Boolean;
  begin
    if Length(ARel) > FILEDESC_NAME_MAX then
      Exit(Refuse(Format('the relative path of "%s" does not fit the ' +
        'clipboard format (260 characters)', [ALocal])));
    if n >= RDPCLIP_MAX_FILES then
      Exit(Refuse(Format('more than %d files', [RDPCLIP_MAX_FILES])));
    if n = Length(AFiles) then
      SetLength(AFiles, 16 + n * 2);
    AFiles[n] := Default(TRdpClipFile);
    AFiles[n].RelPath := ARel;
    AFiles[n].LocalPath := ALocal;
    AFiles[n].IsDir := AIsDir;
    AFiles[n].SizeKnown := not AIsDir;
    AFiles[n].Size := ASize;
    AFiles[n].WriteTime := AWTime;
    // Identite du LISTING DU PARENT, pas d'une seconde resolution du chemin.
    AFiles[n].Id.Known := True;
    AFiles[n].Id.Volume := rootVol;
    AFiles[n].Id.IdHigh := AIdHigh;
    AFiles[n].Id.IdLow := AIdLow;
    Inc(n);
    Result := True;
  end;

  function WalkHandle(AHandle: THandle; const ADir: string;
    const ARel: UnicodeString; ADepth: Integer): Boolean;
  var
    entries: TDirEntryArray_;
    code: LongWord;
    e: Integer;
    sub: string;
    child: THandle;
    info: TByHandleInfo_;
    ok: Boolean;
  begin
    Result := False;
    if ADepth > RDPCLIP_MAX_DEPTH then
      Exit(Refuse('folder tree too deep'));
    // Listing coupe: tout refuser plutot qu'une copie « reussie » a trous.
    if not ListDirByHandle(AHandle, entries, code) then
      Exit(Refuse(Format('"%s" could not be listed (Windows error %d)',
        [ExtractFileName(ADir), code])));
    for e := 0 to High(entries) do
    begin
      // lien: ni suivi ni annonce
      if (entries[e].Attrs and FA_SYMLINK_) <> 0 then
        Continue;
      sub := ADir + PathDelim + UTF8Encode(entries[e].Name);
      if (entries[e].Attrs and FILE_ATTRIBUTE_DIRECTORY_) <> 0 then
      begin
        if not AddEntry(ARel + '\' + entries[e].Name, sub, True, 0,
           entries[e].WriteTime, entries[e].IdHigh, entries[e].IdLow) then
          Exit;
        // Rouvrir un chemin: la poignee doit etre LE dossier liste. Une
        // jonction glissee entre-temps fait refuser, pas sortir de l'arbre.
        child := OpenNoFollow(sub);
        if child = THandle(-1) then
          Exit(Refuse(Format('"%s" could not be opened to walk into it',
            [entries[e].Name])));
        try
          info := Default(TByHandleInfo_);
          ok := GetFileInformationByHandle(child, info) and
            ((info.dwFileAttributes and FA_SYMLINK_) = 0) and
            ((info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY_) <> 0) and
            (info.dwVolumeSerialNumber = rootVol) and
            (info.nFileIndexHigh = entries[e].IdHigh) and
            (info.nFileIndexLow = entries[e].IdLow);
          if not ok then
            Exit(Refuse(Format('"%s" changed while it was being listed; ' +
              'nothing was sent', [entries[e].Name])));
          if not WalkHandle(child, sub, ARel + '\' + entries[e].Name,
             ADepth + 1) then
            Exit;
        finally
          CloseHandle(child);
        end;
      end
      else if not AddEntry(ARel + '\' + entries[e].Name, sub, False,
         entries[e].Size, entries[e].WriteTime, entries[e].IdHigh,
         entries[e].IdLow) then
        Exit;
    end;
    Result := True;
  end;

var
  i: Integer;
  root, base: string;
  h: THandle;
  info: TByHandleInfo_;
  isDir: Boolean;
begin
  Result := False;
  SetLength(AFiles, 0);
  AWhy := '';
  n := 0;
  rootVol := 0;
  for i := 0 to High(ARoots) do
  begin
    root := ExcludeTrailingPathDelimiter(ARoots[i]);
    base := ExtractFileName(root);
    if base = '' then
      Exit(Refuse('a drive root cannot be copied whole'));
    h := OpenNoFollow(root);
    if h = THandle(-1) then
      Exit(Refuse(Format('"%s" is not there any more', [base])));
    try
      info := Default(TByHandleInfo_);
      if not GetFileInformationByHandle(h, info) then
        Exit(Refuse(Format('"%s" could not be identified', [base])));
      if (info.dwFileAttributes and FA_SYMLINK_) <> 0 then
        Exit(Refuse(Format('"%s" is a link, and links are not carried',
          [base])));
      rootVol := info.dwVolumeSerialNumber;
      isDir := (info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY_) <> 0;
      if not AddEntry(UnicodeString(base), root, isDir,
         (Int64(info.nFileSizeHigh) shl 32) or Int64(info.nFileSizeLow),
         (Int64(info.ftWrite[1]) shl 32) or Int64(info.ftWrite[0]),
         info.nFileIndexHigh, info.nFileIndexLow) then
        Exit;
      if isDir then
        if not WalkHandle(h, root, UnicodeString(base), 1) then
          Exit;
    finally
      CloseHandle(h);
    end;
  end;
  if n = 0 then Exit(Refuse('nothing to copy'));
  SetLength(AFiles, n);
  Result := True;
end;
{$ELSE}
// Meme modele que Windows: identite capturee a l'enumeration, descente par
// openat ancre au parent, reverification fstat. Un lien est saute, tout le
// reste d'inclassable (tube, socket, device) fait refuser le lot.
function EnumerateLocalTree(const ARoots: array of string;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;
const
  // secondes Unix -> FILETIME (100 ns depuis 1601)
  EPOCH_1601 = Int64(116444736000000000);
var
  n: Integer;

  function Refuse(const AReason: string): Boolean;
  begin
    SetLength(AFiles, 0);
    AWhy := AReason;
    Result := False;
  end;

  function WireTime(const ASt: Stat): Int64;
  begin
    Result := Int64(ASt.st_mtime) * 10000000 + EPOCH_1601;
  end;

  // Le nom doit survivre au fil: UTF-8 valide et regles Windows.
  function WireName(const AName: string; out AWide: UnicodeString): Boolean;
  var
    why: string;
  begin
    Result := False;
    AWide := UTF8Decode(AName);
    if UTF8Encode(AWide) <> AName then
    begin
      Refuse(Format('"%s" is not valid text; it cannot cross the clipboard',
        [AName]));
      Exit;
    end;
    if not WireComponentOk(AWide, why) then
    begin
      Refuse(Format('"%s": %s', [AName, why]));
      Exit;
    end;
    Result := True;
  end;

  function AddEntry(const ARel: UnicodeString; const ALocal: string;
    AIsDir: Boolean; const ASt: Stat): Boolean;
  begin
    if Length(ARel) > FILEDESC_NAME_MAX then
      Exit(Refuse(Format('the relative path of "%s" does not fit the ' +
        'clipboard format (260 characters)', [ALocal])));
    if n >= RDPCLIP_MAX_FILES then
      Exit(Refuse(Format('more than %d files', [RDPCLIP_MAX_FILES])));
    if n = Length(AFiles) then
      SetLength(AFiles, 16 + n * 2);
    AFiles[n] := Default(TRdpClipFile);
    AFiles[n].RelPath := ARel;
    AFiles[n].LocalPath := ALocal;
    AFiles[n].IsDir := AIsDir;
    AFiles[n].SizeKnown := not AIsDir;
    AFiles[n].Size := ASt.st_size;
    AFiles[n].WriteTime := WireTime(ASt);
    AFiles[n].Id.Known := True;
    AFiles[n].Id.Dev := QWord(ASt.st_dev);
    AFiles[n].Id.Ino := QWord(ASt.st_ino);
    Inc(n);
    Result := True;
  end;

  function WalkFd(AFd: cint; const ADir: string; const ARel: UnicodeString;
    ADepth: Integer): Boolean;
  var
    names: TStringArray;
    e: Integer;
    st, cst: Stat;
    sub: string;
    wide: UnicodeString;
    child: cint;
  begin
    Result := False;
    if ADepth > RDPCLIP_MAX_DEPTH then
      Exit(Refuse('folder tree too deep'));
    // Liste illisible = refus: un dossier annonce vide est un collage ampute
    // que personne ne remarquera avant d'en avoir besoin.
    if not ListDirFd(AFd, ADir, names) then
      Exit(Refuse(Format('"%s" could not be listed; nothing was sent',
        [ExtractFileName(ADir)])));
    for e := 0 to High(names) do
    begin
      if not FStatAtNoFollow(AFd, ADir, names[e], st) then
        Exit(Refuse(Format('"%s" changed while it was being listed; ' +
          'nothing was sent', [names[e]])));
      // lien: ni suivi ni annonce
      if fpS_ISLNK(st.st_mode) then
        Continue;
      if not WireName(names[e], wide) then
        Exit;
      sub := ADir + '/' + names[e];
      if fpS_ISDIR(st.st_mode) then
      begin
        if not AddEntry(ARel + '\' + wide, sub, True, st) then
          Exit;
        child := OpenAtNoFollow(AFd, names[e], O_DIRECTORY);
        if child < 0 then
          Exit(Refuse(Format('"%s" could not be opened to walk into it',
            [names[e]])));
        try
          // La POIGNEE doit etre l'entree listee; un substitut fait refuser.
          if (fpFStat(child, cst) <> 0) or
             (QWord(cst.st_dev) <> QWord(st.st_dev)) or
             (QWord(cst.st_ino) <> QWord(st.st_ino)) then
            Exit(Refuse(Format('"%s" changed while it was being listed; ' +
              'nothing was sent', [names[e]])));
          if not WalkFd(child, sub, ARel + '\' + wide, ADepth + 1) then
            Exit;
        finally
          FpClose(child);
        end;
      end
      else if fpS_ISREG(st.st_mode) then
      begin
        if not AddEntry(ARel + '\' + wide, sub, False, st) then
          Exit;
      end
      else
        Exit(Refuse(Format('"%s" is neither a file nor a folder',
          [names[e]])));
    end;
    Result := True;
  end;

var
  i: Integer;
  root, base: string;
  wide: UnicodeString;
  st, fst: Stat;
  fd: cint;
begin
  Result := False;
  SetLength(AFiles, 0);
  AWhy := '';
  n := 0;
  for i := 0 to High(ARoots) do
  begin
    root := ExcludeTrailingPathDelimiter(ARoots[i]);
    base := ExtractFileName(root);
    if base = '' then
      Exit(Refuse('a filesystem root cannot be copied whole'));
    if fpLStat(PChar(root), st) <> 0 then
      Exit(Refuse(Format('"%s" is not there any more', [base])));
    if fpS_ISLNK(st.st_mode) then
      Exit(Refuse(Format('"%s" is a link, and links are not carried',
        [base])));
    if not WireName(base, wide) then
      Exit;
    if fpS_ISDIR(st.st_mode) then
    begin
      fd := FpOpen(PChar(root), O_RDONLY or O_NOFOLLOW or O_DIRECTORY
        or O_CLOEXEC_);
      if fd < 0 then
        Exit(Refuse(Format('"%s" could not be opened', [base])));
      try
        if (fpFStat(fd, fst) <> 0) or
           (QWord(fst.st_dev) <> QWord(st.st_dev)) or
           (QWord(fst.st_ino) <> QWord(st.st_ino)) then
          Exit(Refuse(Format('"%s" changed while it was being listed; ' +
            'nothing was sent', [base])));
        if not AddEntry(wide, root, True, st) then
          Exit;
        if not WalkFd(fd, root, wide, 1) then
          Exit;
      finally
        FpClose(fd);
      end;
    end
    else if fpS_ISREG(st.st_mode) then
    begin
      if not AddEntry(wide, root, False, st) then
        Exit;
    end
    else
      Exit(Refuse(Format('"%s" is neither a file nor a folder', [base])));
  end;
  if n = 0 then Exit(Refuse('nothing to copy'));
  SetLength(AFiles, n);
  Result := True;
end;
{$ENDIF}

end.
