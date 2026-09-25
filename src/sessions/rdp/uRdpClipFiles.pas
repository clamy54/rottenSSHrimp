{ Descripteurs de fichiers du canal cliprdr (MS-RDPECLIP), cotes lecture et
  ecriture, et la desinfection des chemins relatifs recus du serveur. Unite
  PURE: aucune dependance FreeRDP, testable a sec.

  Le format « FileGroupDescriptorW » est un FILEGROUPDESCRIPTORW brut: un
  compte, puis 592 octets par entree, chemin relatif en UTF-16 separe par des
  '\'. Tout ce qui en vient est HOSTILE: chaque chemin est rejoue composant
  par composant avant de designer quoi que ce soit sur le disque, et un seul
  chemin refuse ecarte le lot entier -- un collage partiel serait un mensonge.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uRdpClipFiles;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes;

const
  // Bornes contre un serveur hostile ou un exces involontaire: des REFUS.
  RDPCLIP_MAX_FILES = 4096;
  RDPCLIP_MAX_TOTAL_BYTES = Int64(256) * 1024 * 1024;
  RDPCLIP_MAX_DEPTH = 32;
  // La descente se fait morceau par morceau: assez gros pour le debit, assez
  // petit pour que l'annulation et la progression restent reactives.
  RDPCLIP_CHUNK_BYTES = 512 * 1024;

  // FILEDESCRIPTORW.dwFlags: quels champs sont renseignes.
  FD_ATTRIBUTES = $0004;
  FD_WRITESTIME = $0020;
  FD_FILESIZE = $0040;
  FD_PROGRESSUI = $4000;
  FILE_ATTRIBUTE_DIRECTORY_ = $10;
  // faSymLink de SysUtils, sans l'avertissement de portabilite: la valeur est
  // la meme partout, et ici elle ne sert qu'a NE PAS suivre.
  FA_SYMLINK_ = $0400;
  FILE_ATTRIBUTE_NORMAL_ = $80;
  // 4 + 16 + 8 + 8 + 4 + 3*8 + 4 + 4 + 260*2: tous les champs s'alignent
  // naturellement, aucun bourrage.
  FILEDESC_W_SIZE = 592;
  // cFileName fait 260 WCHAR, NUL final compris.
  FILEDESC_NAME_MAX = 259;

type
  // Identite d'un fichier local: volume et numero de fichier, captures a
  // l'ENUMERATION. C'est elle que le service verifie avant d'envoyer, pas le
  // chemin, qu'un lien ou une jonction poses entre-temps feraient mentir.
  TRdpFileId = record
    Known: Boolean;
    Volume, IdHigh, IdLow: LongWord;
  end;

  TRdpClipFile = record
    RelPath: UnicodeString;  // tel que sur le fil, separateurs '\'
    LocalRel: string;        // le meme, rejoue et valide pour CE poste
    IsDir: Boolean;
    SizeKnown: Boolean;
    Size: Int64;
    WriteTime: Int64;        // FILETIME (100 ns depuis 1601), 0 = inconnue
    LocalPath: string;       // cote envoi seulement: le fichier reel
    Id: TRdpFileId;          // cote envoi seulement: capturee a l'enumeration
  end;
  TRdpClipFileArray = array of TRdpClipFile;

// FILEGROUPDESCRIPTORW pret a partir sur le fil. Une entree au chemin trop
// long pour le format leve EConvertError en amont: l'appelant enumere avec
// les memes bornes.
function BuildFileGroupDescriptor(const AFiles: TRdpClipFileArray): TBytes;

// Descripteur recu du serveur. False + AWhy des la premiere entree invalide:
// compte menteur, nom sans NUL, chemin hostile. AFiles est alors vide.
function ParseFileGroupDescriptor(AData: PByte; ALen: SizeUInt;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;

// Chemin relatif du fil -> chemin relatif local, ou refus motive. Refuse
// l'absolu, les lecteurs, '.', '..', les caracteres interdits, les noms
// reserves de Windows, point ou espace final, et la profondeur excessive.
function RdpClipSafeRelPath(const ARel: UnicodeString; out ALocalRel: string;
  out AWhy: string): Boolean;

// Fichiers et dossiers sous ARoots, en pre-ordre (un dossier precede son
// contenu), chemins relatifs au parent de chaque racine. Les liens et points
// de reanalyse ne sont JAMAIS suivis: un cycle de jonctions enumererait sans
// fin, et une jonction vers C:\ enverrait le disque entier. Chaque dossier
// s'enumere PAR SA POIGNEE et la descente reverifie l'identite (volume +
// numero) que le parent vient de lister: une jonction glissee sous un nom
// deja controle ne detourne rien, elle fait refuser. Hors Windows: refus
// franc, le pont de fichiers est Windows<->Windows.
function EnumerateLocalTree(const ARoots: array of string;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;

// Cree APath en EXCLUSIF (echec si le nom existe deja: c'est LA garantie) et,
// sous Windows, avec une DACL proprietaire seul heritee par les descendants:
// les fichiers rapatries n'appartiennent qu'a la session, et personne d'autre
// ne pose quoi que ce soit dans l'arbre avant sa suppression.
function RdpClipMakeDirOwnerOnly(const APath: string): Boolean;

// Efface un arbre A NOUS (temporaires du presse-papiers). Le sort de chaque
// entree se decide d'apres une poignee ouverte SANS suivre les points de
// reanalyse: un lien part seul, meme pose en pleine course, sa cible reste.
procedure RdpClipRemoveTree(const APath: string);

// Capture l'identite du fichier a APath. False = impossible de l'ouvrir, et
// il ne faut alors PAS l'annoncer: on ne saurait pas verifier qu'on sert bien
// lui. Hors Windows: Known reste faux, rien ne se sert.
function CaptureLocalFileId(const APath: string; out AId: TRdpFileId): Boolean;

// La poignee ouverte designe-t-elle le fichier capture? Refus par defaut:
// une identite inconnue ne se sert pas.
function HandleMatchesId(AHandle: THandle; const AId: TRdpFileId): Boolean;

implementation

{$IFDEF WINDOWS}
type
  // BY_HANDLE_FILE_INFORMATION: champs de 4 octets et FILETIME de 2 x 4,
  // aucun bourrage.
  TByHandleInfo_ = record
    dwFileAttributes: LongWord;
    ftCreation, ftAccess, ftWrite: array[0..1] of LongWord;
    dwVolumeSerialNumber, nFileSizeHigh, nFileSizeLow, nNumberOfLinks,
    nFileIndexHigh, nFileIndexLow: LongWord;
  end;

const
  FILE_READ_ATTRIBUTES_ = $0080;
  FILE_LIST_DIRECTORY_ = 1;   // sur un fichier, le meme bit = READ_DATA
  FILE_SHARE_ALL_ = 7;   // read + write + delete: on ne bloque personne
  OPEN_EXISTING_ = 3;
  FILE_FLAG_BACKUP_SEMANTICS_ = $02000000;
  // Ne PAS suivre un point de reanalyse en bout de chemin: la poignee designe
  // alors le lien lui-meme, et ses attributs le disent.
  FILE_FLAG_OPEN_REPARSE_POINT_ = $00200000;
  ERROR_NO_MORE_FILES_ = 18;
  // Classe GetFileInformationByHandleEx: les entrees d'un dossier, lues par
  // sa POIGNEE, avec le numero de fichier de chacune.
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

  // Une entree relue depuis la poignee du parent: nom, attributs, taille et
  // IDENTITE font foi -- aucun chemin n'a ete re-resolu pour les obtenir.
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

// Ouvre APath sans suivre un eventuel lien FINAL. Les composants
// intermediaires, eux, se re-resolvent: c'est pour cela que l'appelant
// verifie ensuite l'identite de ce que la poignee designe.
function OpenNoFollow(const APath: string): THandle;
begin
  Result := CreateFileW(PWideChar(UTF8Decode(APath)),
    FILE_READ_ATTRIBUTES_ or FILE_LIST_DIRECTORY_, FILE_SHARE_ALL_, nil,
    OPEN_EXISTING_, FILE_FLAG_BACKUP_SEMANTICS_ or
    FILE_FLAG_OPEN_REPARSE_POINT_, 0);
end;

// Toutes les entrees d'un dossier, lues PAR SA POIGNEE ('.', '..' filtres).
// False = listing coupe (code Windows dans ACode) et AEntries VIDE: un
// partiel qui passerait pour complet ferait annoncer une copie a laquelle il
// manque des fichiers.
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
  // Proprietaire seul (« OW » = droits du proprietaire de chaque objet,
  // herite tel quel), SYSTEM en plus (antivirus, indexation), heritage du
  // parent COUPE (D:P): personne d'autre ne lit les fichiers rapatries ni ne
  // pose quoi que ce soit dans l'arbre avant sa suppression.
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
    // CreateDirectoryW echoue si le nom existe deja: jamais de reutilisation
    // d'un dossier (ou d'une jonction) pose la par un autre.
    Result := CreateDirectoryW(PWideChar(UTF8Decode(APath)), @sa);
  finally
    LocalFree(sd);
  end;
end;

procedure RdpClipRemoveTree(const APath: string);

  procedure RemoveLevel(const ADir: string; ADepth: Integer);
  var
    h: THandle;
    info: TByHandleInfo_;
    entries: TDirEntryArray_;
    code: LongWord;
    e: Integer;
    sub: string;
  begin
    // Au pire, du temporaire reste sur place: on ne suit rien d'anormal.
    if ADepth > RDPCLIP_MAX_DEPTH * 2 then
      Exit;
    h := OpenNoFollow(ADir);
    if h = THandle(-1) then
      Exit;
    try
      info := Default(TByHandleInfo_);
      // Le sort de l'entree se decide d'apres sa POIGNEE, pas son chemin: un
      // lien pose sous ce nom entre-temps se voit ici, et on ne descend pas.
      // L'appelant efface alors le lien SEUL, sa cible reste.
      if (not GetFileInformationByHandle(h, info)) or
         ((info.dwFileAttributes and FA_SYMLINK_) <> 0) or
         ((info.dwFileAttributes and FILE_ATTRIBUTE_DIRECTORY_) = 0) then
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
          RemoveLevel(sub, ADepth + 1);
          RemoveDir(sub);
        end
        else
          SysUtils.DeleteFile(sub);
      end;
    finally
      CloseHandle(h);
    end;
  end;

begin
  if APath = '' then
    Exit;
  RemoveLevel(APath, 0);
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
{$ELSE}
function CaptureLocalFileId(const APath: string; out AId: TRdpFileId): Boolean;
begin
  AId := Default(TRdpFileId);
  Result := True;
end;

function HandleMatchesId(AHandle: THandle; const AId: TRdpFileId): Boolean;
begin
  Result := False;
end;

function RdpClipMakeDirOwnerOnly(const APath: string): Boolean;
begin
  Result := CreateDir(APath);   // exclusif aussi: echec si le nom existe
end;

// Ici pas de poignees: le pont de fichiers n'alimente pas ces plateformes,
// il ne reste qu'a balayer un reliquat eventuel sans suivre les liens.
procedure RdpClipRemoveTree(const APath: string);
var
  sr: TSearchRec;
begin
  if APath = '' then
    Exit;
  if FindFirst(APath + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = '') then
          Continue;
        if (sr.Attr and FA_SYMLINK_) <> 0 then
        begin
          if (sr.Attr and faDirectory) <> 0 then
            RemoveDir(APath + PathDelim + sr.Name)
          else
            SysUtils.DeleteFile(APath + PathDelim + sr.Name);
        end
        else if (sr.Attr and faDirectory) <> 0 then
          RdpClipRemoveTree(APath + PathDelim + sr.Name)
        else
          SysUtils.DeleteFile(APath + PathDelim + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  RemoveDir(APath);
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
    // Tronquer changerait la cible du collage: l'enumeration a deja refuse.
    if Length(AFiles[i].RelPath) > FILEDESC_NAME_MAX then
      raise EConvertError.Create('relative path too long for the descriptor');
    for j := 1 to Length(AFiles[i].RelPath) do
      PWord(@Result[base + 72 + (j - 1) * 2])^ := Word(AFiles[i].RelPath[j]);
  end;
end;

function RdpClipSafeRelPath(const ARel: UnicodeString; out ALocalRel: string;
  out AWhy: string): Boolean;
const
  BAD_CHARS: UnicodeString = '<>:"/|?*';
var
  comp: UnicodeString;
  i, start, depth, p: Integer;
  c: WideChar;
  stem: string;

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
    if (comp = '.') or (comp = '..') then
      Exit(Refuse('"." and ".." are not file names'));
    for k := 1 to Length(comp) do
    begin
      c := comp[k];
      if (Ord(c) < 32) or (Pos(c, BAD_CHARS) > 0) or (c = '\') then
        Exit(Refuse('forbidden character in a file name'));
    end;
    // Windows retire lui-meme point et espace finaux: le nom cree ne serait
    // plus celui annonce, et deux entrees pourraient viser le meme fichier.
    c := comp[Length(comp)];
    if (c = '.') or (c = ' ') then
      Exit(Refuse('a file name may not end with a dot or a space'));
    stem := UpperCase(string(comp));
    p := Pos('.', stem);
    if p > 1 then
      stem := Copy(stem, 1, p - 1);
    if (stem = 'CON') or (stem = 'PRN') or (stem = 'AUX') or (stem = 'NUL') or
       (((Copy(stem, 1, 3) = 'COM') or (Copy(stem, 1, 3) = 'LPT')) and
        (Length(stem) = 4) and (stem[4] in ['1'..'9'])) then
      Exit(Refuse('reserved device name'));
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
  // Borne AVANT la multiplication: un compte menteur ne fait rien allouer.
  if count > RDPCLIP_MAX_FILES then
    Exit(Refuse(Format('more than %d files', [RDPCLIP_MAX_FILES])));
  if ALen < 4 + SizeUInt(count) * FILEDESC_W_SIZE then
    Exit(Refuse('descriptor shorter than its own count'));
  SetLength(AFiles, count);
  // Sur ce disque, deux noms qui ne different que par la casse designent le
  // MEME fichier: le second ecraserait le premier en silence.
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
      // Bit de signe du mot haut: la taille deviendrait NEGATIVE en Int64, et
      // « position >= taille » declarerait complet un fichier tronque.
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
    // Un nom sans NUL dans ses 260 WCHAR n'est pas un descripteur valide.
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
    // L'identite vient du LISTING DU PARENT (par poignee), pas d'une seconde
    // resolution du chemin: c'est elle que le service reverifiera avant
    // d'envoyer le premier octet.
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
    // Enumeration par la POIGNEE: rien a re-resoudre. Un listing coupe (refus
    // d'acces, E/S qui casse) refuse tout: une copie « reussie » a laquelle
    // il manque des fichiers serait un mensonge. Un dossier vide, lui, rend
    // simplement zero entree.
    if not ListDirByHandle(AHandle, entries, code) then
      Exit(Refuse(Format('"%s" could not be listed (Windows error %d)',
        [ExtractFileName(ADir), code])));
    for e := 0 to High(entries) do
    begin
      // Un lien n'est ni suivi ni annonce: sa cible n'est pas la.
      if (entries[e].Attrs and FA_SYMLINK_) <> 0 then
        Continue;
      sub := ADir + PathDelim + UTF8Encode(entries[e].Name);
      if (entries[e].Attrs and FILE_ATTRIBUTE_DIRECTORY_) <> 0 then
      begin
        if not AddEntry(ARel + '\' + entries[e].Name, sub, True, 0,
           entries[e].WriteTime, entries[e].IdHigh, entries[e].IdLow) then
          Exit;
        // Descendre oblige a rouvrir un chemin; la poignee obtenue doit etre
        // LE dossier que le parent vient de lister: meme volume, meme numero,
        // pas un point de reanalyse. Une jonction glissee entre le listing et
        // la descente ne correspond plus -- refus, plutot qu'enumerer sa
        // cible et faire sortir la selection du dossier copie.
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
      // La racine s'enumere par la poignee DEJA verifiee: aucun retour au
      // chemin, donc rien a re-verifier pour elle.
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
function EnumerateLocalTree(const ARoots: array of string;
  out AFiles: TRdpClipFileArray; out AWhy: string): Boolean;
begin
  SetLength(AFiles, 0);
  // Refus FRANC plutot qu'un FindFirst dont l'echec ne se distingue pas d'un
  // dossier vide: le pont de fichiers est Windows<->Windows, sans CF_HDROP
  // local on promettrait un envoi qu'on ne sait pas tenir.
  AWhy := 'copying files works between Windows machines only';
  Result := False;
end;
{$ENDIF}

end.
