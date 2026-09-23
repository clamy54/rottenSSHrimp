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
  {$IFDEF WINDOWS}, Windows{$ELSE}, BaseUnix, Unix{$ENDIF};

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
    FCanceled: Boolean;
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
    function MakeDir(const APath: string;
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
    function SetMTime(const APath: string; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; override;
    function SetMode(const APath: string; AMode: LongWord;
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
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
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
  Result := FCanceled;
end;

procedure TLocalFileSystem.Cancel;
begin
  FCanceled := True;
end;

procedure TLocalFileSystem.ResetCancel;
begin
  FCanceled := False;
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
      if FCanceled then
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
      de := fpReadDir(d^);
      if de = nil then Break;
      if FCanceled then
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
    AErr := LastErr('Reading attributes of', APath);
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
    AErr := LastErr('Reading attributes of', APath);
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

function TLocalFileSystem.MakeDir(const APath: string;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  Result := CreateDirectoryW(PWideChar(NativeW(APath)), nil);
  {$ELSE}
  Result := fpMkdir(PChar(LocalNormalize(APath)), &0755) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Creating folder', APath);
end;

function TLocalFileSystem.Rename(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
{$IFNDEF WINDOWS}
var
  found: Boolean;
  chkErr: TScpError;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // SANS MOVEFILE_REPLACE_EXISTING: ce Rename n'ecrase jamais. Le remplacement
  // est ReplaceAtomic, demande explicitement.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)), 0);
  {$ELSE}
  // rename() POSIX ecrase la cible en silence. Ce n'est pas ce que promet
  // cette methode: on verifie d'abord, en assumant la course residuelle --
  // l'appelant ne passe ici que pour une cible qu'il a vue absente.
  if not Exists(ATo, found, chkErr) then
  begin
    AErr := chkErr;
    Exit(False);
  end;
  if found then
  begin
    AErr := MakeScpError(sekAlreadyExists, 'Renaming to',
      DisplaySafeName(ATo), '');
    Exit(False);
  end;
  Result := fpRename(PChar(LocalNormalize(AFrom)),
    PChar(LocalNormalize(ATo))) = 0;
  {$ENDIF}
  if not Result then
    AErr := LastErr('Renaming to', ATo);
end;

function TLocalFileSystem.ReplaceAtomic(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // MOVEFILE_REPLACE_EXISTING sur un meme volume NTFS: pas d'etat
  // intermediaire. WRITE_THROUGH attend le support avant de rendre la main.
  Result := MoveFileExW(PWideChar(NativeW(AFrom)), PWideChar(NativeW(ATo)),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH_);
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
begin
  AHandle := nil;
  AErr := NoScpError;
  h := TLocalHandle.Create;
  h.Path := APath;
  {$IFDEF WINDOWS}
  // FILE_SHARE_READ seulement: on ne veut pas lire un fichier qu'un autre
  // processus est en train de reecrire.
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_READ,
    FILE_SHARE_READ, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Opening', APath);
    h.Free;
    Exit(False);
  end;
  {$ELSE}
  h.Fd := fpOpen(PChar(LocalNormalize(APath)), O_RDONLY);
  if h.Fd < 0 then
  begin
    AErr := LastErr('Opening', APath);
    h.Free;
    Exit(False);
  end;
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
begin
  AHandle := nil;
  APath := '';
  AErr := NoScpError;
  for attempt := 1 to 8 do
  begin
    candidate := LocalJoin(ADir, TEMP_PREFIX + RandomSuffix + TEMP_SUFFIX);
    h := TLocalHandle.Create;
    h.Path := candidate;
    {$IFDEF WINDOWS}
    // CREATE_NEW echoue si QUOI QUE CE SOIT existe sous ce nom, lien compris:
    // c'est ce qui interdit d'ecrire a travers un lien pose d'avance.
    h.H := CreateFileW(PWideChar(NativeW(candidate)), GENERIC_WRITE,
      0, nil, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
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
end;

function TLocalFileSystem.OpenAppend(const APath: string; AOffset: Int64;
  out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
var
  h: TLocalHandle;
  err: TScpError;
begin
  AHandle := nil;
  AErr := NoScpError;
  h := TLocalHandle.Create;
  h.Path := APath;
  // Jamais a travers un lien: un partiel remplace par un lien entre la
  // coupure et la reprise ferait ecrire la suite dans un autre fichier. Le
  // moteur l'a deja verifie par lstat; l'ouverture le garantit sans course.
  {$IFDEF WINDOWS}
  // FILE_FLAG_OPEN_REPARSE_POINT: sur un lien, l'ecriture echoue au lieu de
  // traverser.
  h.H := CreateFileW(PWideChar(NativeW(APath)), GENERIC_WRITE,
    0, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OPEN_REPARSE_POINT_, 0);
  if h.H = INVALID_HANDLE_VALUE then
  begin
    AErr := LastErr('Reopening', APath);
    h.Free;
    Exit(False);
  end;
  {$ELSE}
  h.Fd := fpOpen(PChar(LocalNormalize(APath)), O_WRONLY or O_NOFOLLOW);
  if h.Fd < 0 then
  begin
    AErr := LastErr('Reopening', APath);
    h.Free;
    Exit(False);
  end;
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
    AErr := LastErr('Reading', h.Path);
    Exit(False);
  end;
  AGot := Integer(n);
  {$ELSE}
  repeat
    n := fpRead(h.Fd, ABuf^, ACount);
  until (n >= 0) or (fpGetErrno <> ESysEINTR);
  if n < 0 then
  begin
    AErr := LastErr('Reading', h.Path);
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

function TLocalFileSystem.SetMTime(const APath: string; AMTimeUtc: Int64;
  out AErr: TScpError): Boolean;
{$IFDEF WINDOWS}
var
  hnd: Windows.THandle;
  ft: TFileTime;
{$ELSE}
var
  tb: TUTimBuf;
  st: Stat;
{$ENDIF}
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  hnd := CreateFileW(PWideChar(NativeW(APath)), FILE_WRITE_ATTRIBUTES,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_FLAG_BACKUP_SEMANTICS, 0);
  if hnd = INVALID_HANDLE_VALUE then
  begin
    AErr := MakeScpError(sekAttrRefused, 'Setting the timestamp of',
      DisplaySafeName(APath), Format('Windows error %d', [GetLastError]));
    Exit(False);
  end;
  try
    ft := UnixToFileTime(AMTimeUtc);
    Result := SetFileTime(hnd, nil, nil, @ft);
    if not Result then
      AErr := MakeScpError(sekAttrRefused, 'Setting the timestamp of',
        DisplaySafeName(APath), Format('Windows error %d', [GetLastError]));
  finally
    CloseHandle(hnd);
  end;
  {$ELSE}
  // Garder la date d'ACCES: la remplacer serait une alteration non demandee.
  if fpStat(PChar(LocalNormalize(APath)), st) = 0 then
    tb.actime := st.st_atime
  else
    tb.actime := AMTimeUtc;
  tb.modtime := AMTimeUtc;
  Result := fpUTime(PChar(LocalNormalize(APath)), @tb) = 0;
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the timestamp of',
      DisplaySafeName(APath), Format('errno %d', [fpGetErrno]));
  {$ENDIF}
end;

function TLocalFileSystem.SetMode(const APath: string; AMode: LongWord;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  {$IFDEF WINDOWS}
  // Aucun mode POSIX a poser, et surtout pas d'ACL: rien de transposable.
  // Silence volontaire, pas oubli.
  Result := True;
  {$ELSE}
  Result := fpChmod(PChar(LocalNormalize(APath)), AMode) = 0;
  if not Result then
    AErr := MakeScpError(sekAttrRefused, 'Setting the mode of',
      DisplaySafeName(APath), Format('errno %d', [fpGetErrno]));
  {$ENDIF}
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
