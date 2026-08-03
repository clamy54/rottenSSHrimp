unit uRshDocument;

{$mode objfpc}{$H+}

// Cycle de vie du document .rsh: prevalidation, copie de travail
// privee, remplacement atomique, MAC global du contenu en clair.

interface

uses
  SysUtils, Classes, uSqliteDb, uSecureBytes, uCryptoPolicy;

type
  TDocErrorCode = (
    decNone,
    decNotFound,
    decTooLarge,
    decNotRsh,
    decFutureVersion,
    decCorrupt,
    decBadPasswordOrCorrupt, // mdp faux OU fichier altere: indistinguable
    decTampered,
    decConflict,
    decLocked,
    decReadOnly,
    decIo
  );

  TDocError = record
    Code: TDocErrorCode;
    UserMessage: string;
    TechnicalMessage: string;  // sanitize, jamais de secret
  end;

  TRshDocument = class
  private
    FSourcePath: string;
    FWorkingPath: string;
    FDb: TSqliteDb;
    FDek: TSecureBytes;
    FMacKey: TSecureBytes;
    FEnvKey: TSecureBytes;
    FPendingKek: TSecureBytes;
    FPendingSalt: TBytes;
    FPendingOps: Int64;
    FPendingMem: Int64;
    // un document non migre se verifie avec le jeu de requetes de SA version
    FSchemaVersion: Integer;
    FDocumentUuid: string;
    FCryptoVersion: Integer;
    FDirty: Boolean;
    FRecoveredUnsaved: Boolean;
    FSrcSize: Int64;
    FSrcMTime: TDateTime;
    FSrcCanonical: string;
    FSrcDev: Int64;
    FSrcIno: Int64;
    FSourceLock: THandle;
    FLockPath: string;
    FReadOnly: Boolean;
    FLocked: Boolean;
    procedure RecordSourceIdentity;
    function SourceChangedExternally: Boolean;
    function SourceTargetChanged: Boolean;
    function AcquireSourceLock(const ATarget: string): Boolean;
    procedure ReleaseSourceLock;
    function LoadWorkingCopy(const APassword: RawByteString;
      out AErr: TDocError): Boolean;
    function UnlockCrypto(const APassword: RawByteString;
      out AErr: TDocError): Boolean;
    function UpgradeSchemaIfNeeded(out AErr: TDocError): Boolean;
    procedure MetaSetText(const AKey, AValue: string);
    procedure MetaSetInt(const AKey: string; AValue: Int64);
    procedure MetaSetBlob(const AKey: string; const AValue: TBytes);
    function MetaGetText(const AKey: string; out AValue: string): Boolean;
    function MetaGetInt(const AKey: string; out AValue: Int64): Boolean;
    function MetaGetBlob(const AKey: string; out AValue: TBytes): Boolean;
    function CanonicalContentBytes: TBytes;
    function ComputeContentMac: TBytes;
    // callback de pre-commit du FDb: re-scelle dans la transaction courante
    procedure SealContent;
    function SaveTo(const ATarget: string; ACheckConflict: Boolean;
      out AErr: TDocError): Boolean;
  public
    class function NewDocument(const APath: string;
      const APassword: RawByteString; out ADoc: TRshDocument;
      out AErr: TDocError; AOps: Int64 = KDF_OPSLIMIT_DEFAULT;
      AMem: Int64 = KDF_MEMLIMIT_DEFAULT): Boolean;
    // AReadOnly: pas de verrou, Save refuse; sinon decLocked si deja ouvert
    class function OpenDocument(const APath: string;
      const APassword: RawByteString; out ADoc: TRshDocument;
      out AErr: TDocError; AReadOnly: Boolean = False): Boolean;
    // copie orpheline: sans chemin source, Save As est obligatoire
    class function RecoverDocument(const AWorkingPath: string;
      const APassword: RawByteString; out ADoc: TRshDocument;
      out AOriginHint: string; out AErr: TDocError): Boolean;
    constructor Create;
    destructor Destroy; override;

    function Save(out AErr: TDocError): Boolean;
    // n'ecrase qu'APRES un decConflict confirme par l'utilisateur
    function SaveOverwrite(out AErr: TDocError): Boolean;
    function SaveAs(const ANewPath: string; out AErr: TDocError): Boolean;
    // nouveau sel, nouvelle KEK, DEK rechiffree, secrets intacts
    function ChangeMasterPassword(const AOldPassword,
      ANewPassword: RawByteString; out AErr: TDocError;
      AOps: Int64 = KDF_OPSLIMIT_DEFAULT;
      AMem: Int64 = KDF_MEMLIMIT_DEFAULT): Boolean;

    // AAD canonique: une valeur deplacee ne se dechiffre plus
    procedure EncryptFieldValue(const AOwnerUuid, AFieldName: string;
      APlain: TSecureBytes; out ANonce, ACipher: TBytes);
    function DecryptFieldValue(const AOwnerUuid, AFieldName: string;
      const ANonce, ACipher: TBytes; out APlain: TSecureBytes): Boolean;

    procedure MarkDirty;

    // efface DEK, cle MAC et cle d'enveloppe (document inutilisable)
    procedure Lock;
    function Unlock(const APassword: RawByteString;
      out AErr: TDocError): Boolean;
    property Locked: Boolean read FLocked;

    // deballe la DEK puis efface tout: aucun etat touche, une passe Argon2id
    function VerifyPassword(const APassword: RawByteString): Boolean;

    property SourcePath: string read FSourcePath;
    property WorkingPath: string read FWorkingPath;
    property DocumentUuid: string read FDocumentUuid;
    property Dirty: Boolean read FDirty;
    property ReadOnly: Boolean read FReadOnly;
    property RecoveredUnsaved: Boolean read FRecoveredUnsaved;
    property Db: TSqliteDb read FDb;
  end;

// magic, versions, bornes KDF -- sans deriver ni dechiffrer
function PrevalidateRshFile(const APath: string; out AErr: TDocError): Boolean;
function PrevalidateWorkingSqlite(const APath: string;
  out AErr: TDocError): Boolean;

function DocErr(ACode: TDocErrorCode; const AUser, ATech: string): TDocError;
function BadPasswordError(const ATech: string): TDocError;

implementation

uses
  {$IFDEF UNIX}BaseUnix, Unix,{$ENDIF}
  uSqlite3Api, uSodiumApi, uDocCrypto, uRshSchema, uRshEnvelope,
  uRsUtil, uAppPaths, uSafeSave, uLog;

const
  MSG_BAD_PASSWORD_OR_CORRUPT =
    'Cannot open the document.'#10 +
    'The password is incorrect or the file is damaged.';
  MSG_TAMPERED =
    'The document was modified outside RottenSSHrimp.';
  MSG_FUTURE =
    'This document was created by a newer RottenSSHrimp version.';
  MSG_NOT_RSH =
    'This file is not a valid RottenSSHrimp document.';
  MSG_CORRUPT =
    'The document is damaged.';
  MSG_CONFLICT =
    'The file was modified by another program since it was opened.';
  MSG_LOCKED =
    'This document seems to be already open in another RottenSSHrimp instance.';
  MSG_READONLY =
    'This document is open in read-only mode.'#10 +
    'Use Save As to save a copy.';

  META_FORMAT_NAME = 'format_name';
  META_FORMAT_VERSION = 'format_version';
  META_DOCUMENT_UUID = 'document_uuid';
  META_CREATED_AT = 'created_at_ms';
  META_UPDATED_AT = 'updated_at_ms';
  META_CRYPTO_VERSION = 'crypto_version';
  META_KDF_ALGORITHM = 'kdf_algorithm';
  META_KDF_SALT = 'kdf_salt';
  META_KDF_OPSLIMIT = 'kdf_opslimit';
  META_KDF_MEMLIMIT = 'kdf_memlimit';
  META_DEK_NONCE = 'dek_nonce';
  META_ENCRYPTED_DEK = 'encrypted_dek';
  META_CONTENT_MAC = 'content_mac';

  KDF_ALGORITHM_NAME = 'argon2id13';

  // Tables du MAC global, un jeu FIGE PAR VERSION (le MAC couvre le TEXTE des
  // requetes). Une table absente d'un jeu se modifie sans detection.
  CANONICAL_QUERIES_V1: array[0..14] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM group_defaults ORDER BY group_uuid;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V2: array[0..16] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM group_defaults ORDER BY group_uuid;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V4: array[0..16] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM folder_credentials ORDER BY folder_uuid, protocol;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V5: array[0..17] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM folder_credentials ORDER BY folder_uuid, protocol;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM connection_jump ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V6: array[0..18] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM folder_credentials ORDER BY folder_uuid, protocol;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM connection_jump ORDER BY connection_uuid;',
    'SELECT * FROM jump_host_offers ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V7: array[0..19] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM folder_credentials ORDER BY folder_uuid, protocol;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM connection_jump ORDER BY connection_uuid;',
    'SELECT * FROM jump_host_offers ORDER BY connection_uuid;',
    'SELECT * FROM connection_container ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

  CANONICAL_QUERIES_V8: array[0..20] of string = (
    'SELECT * FROM document_meta WHERE key <> ''content_mac'' ORDER BY key;',
    'SELECT * FROM nodes ORDER BY uuid;',
    'SELECT * FROM credentials ORDER BY uuid;',
    'SELECT * FROM encrypted_values ORDER BY uuid;',
    'SELECT * FROM connections ORDER BY node_uuid;',
    'SELECT * FROM folder_credentials ORDER BY folder_uuid, protocol;',
    'SELECT * FROM ssh_profiles ORDER BY uuid;',
    'SELECT * FROM ssh_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM ssh_known_hosts ORDER BY uuid;',
    'SELECT * FROM rdp_profiles ORDER BY uuid;',
    'SELECT * FROM rdp_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM vnc_profiles ORDER BY uuid;',
    'SELECT * FROM vnc_connection_settings ORDER BY connection_uuid;',
    'SELECT * FROM connection_jump ORDER BY connection_uuid;',
    'SELECT * FROM jump_host_offers ORDER BY connection_uuid;',
    'SELECT * FROM connection_container ORDER BY connection_uuid;',
    'SELECT * FROM connection_pod ORDER BY connection_uuid;',
    'SELECT * FROM document_settings ORDER BY key;',
    'SELECT * FROM recent_sessions ORDER BY connection_uuid;',
    'SELECT * FROM schema_migrations ORDER BY version;',
    'SELECT * FROM sqlite_master WHERE 0;'
  );

function CanonicalQueriesFor(AVersion: Integer): specialize TArray<string>;
var
  i: Integer;
begin
  case AVersion of
    1:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V1));
        for i := 0 to High(CANONICAL_QUERIES_V1) do
          Result[i] := CANONICAL_QUERIES_V1[i];
      end;
    2, 3:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V2));
        for i := 0 to High(CANONICAL_QUERIES_V2) do
          Result[i] := CANONICAL_QUERIES_V2[i];
      end;
    4:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V4));
        for i := 0 to High(CANONICAL_QUERIES_V4) do
          Result[i] := CANONICAL_QUERIES_V4[i];
      end;
    5:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V5));
        for i := 0 to High(CANONICAL_QUERIES_V5) do
          Result[i] := CANONICAL_QUERIES_V5[i];
      end;
    6:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V6));
        for i := 0 to High(CANONICAL_QUERIES_V6) do
          Result[i] := CANONICAL_QUERIES_V6[i];
      end;
    7:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V7));
        for i := 0 to High(CANONICAL_QUERIES_V7) do
          Result[i] := CANONICAL_QUERIES_V7[i];
      end;
    8, 9, 10:
      begin
        SetLength(Result, Length(CANONICAL_QUERIES_V8));
        for i := 0 to High(CANONICAL_QUERIES_V8) do
          Result[i] := CANONICAL_QUERIES_V8[i];
      end;
  else
    raise Exception.CreateFmt('unknown schema version: %d', [AVersion]);
  end;
end;

function DocErr(ACode: TDocErrorCode; const AUser, ATech: string): TDocError;
begin
  Result.Code := ACode;
  Result.UserMessage := AUser;
  Result.TechnicalMessage := ATech;
end;

function NoErr: TDocError;
begin
  Result := DocErr(decNone, '', '');
end;

function BadPasswordError(const ATech: string): TDocError;
begin
  Result := DocErr(decBadPasswordOrCorrupt, MSG_BAD_PASSWORD_OR_CORRUPT, ATech);
end;

{$IFDEF UNIX}
procedure FsyncDir(const ADir: string);
var
  fd: cint;
begin
  fd := FpOpen(PChar(ADir), O_RDONLY);
  if fd >= 0 then
  begin
    fpfsync(fd);
    FpClose(fd);
  end;
end;
{$ENDIF}

function ReadBigEndian32(const ABuf: array of Byte; AOffset: Integer): LongWord;
begin
  Result := (LongWord(ABuf[AOffset]) shl 24) or
    (LongWord(ABuf[AOffset + 1]) shl 16) or
    (LongWord(ABuf[AOffset + 2]) shl 8) or
    LongWord(ABuf[AOffset + 3]);
end;

function ReadFileHead(const APath: string; out AHdr: TBytes; out ASize: Int64;
  out AErr: TDocError): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  AErr := NoErr;
  AHdr := nil;
  ASize := 0;
  if not FileExists(APath) then
  begin
    AErr := DocErr(decNotFound, 'File not found.', 'absent: chemin donne');
    Exit;
  end;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: Exception do
    begin
      AErr := DocErr(decIo, 'Cannot read the file.', E.ClassName);
      Exit;
    end;
  end;
  try
    ASize := fs.Size;
    if ASize > MAX_DOCUMENT_BYTES then
    begin
      AErr := DocErr(decTooLarge, 'The file exceeds the maximum allowed size.',
        Format('taille=%d max=%d', [ASize, MAX_DOCUMENT_BYTES]));
      Exit;
    end;
    SetLength(AHdr, 100);
    if ASize >= 100 then
      fs.ReadBuffer(AHdr[0], 100)
    else if ASize > 0 then
      fs.ReadBuffer(AHdr[0], ASize);
  finally
    fs.Free;
  end;
  Result := True;
end;

function PrevalidateRshFile(const APath: string; out AErr: TDocError): Boolean;
var
  hdr, salt: TBytes;
  size, ops, mem: Int64;
  tech: string;
begin
  Result := False;
  if not ReadFileHead(APath, hdr, size, AErr) then Exit;
  if size < ENVELOPE_MIN_BYTES then
  begin
    AErr := DocErr(decNotRsh, MSG_NOT_RSH, 'fichier trop court');
    Exit;
  end;
  if not EnvelopeParseHeader(hdr, salt, ops, mem, tech) then
  begin
    if EnvelopeMagicMatches(hdr) and (Pos('format_version', tech) = 1) then
      AErr := DocErr(decFutureVersion, MSG_FUTURE, tech)
    else if EnvelopeMagicMatches(hdr) then
      AErr := DocErr(decTampered, MSG_TAMPERED, tech)
    else
      AErr := DocErr(decNotRsh, MSG_NOT_RSH, tech);
    Exit;
  end;
  Result := True;
end;

function PrevalidateWorkingSqlite(const APath: string;
  out AErr: TDocError): Boolean;
const
  SQLITE_MAGIC: AnsiString = 'SQLite format 3'#0;
var
  hdr: TBytes;
  size: Int64;
  i: Integer;
  userVersion, appId: LongWord;
begin
  Result := False;
  if not ReadFileHead(APath, hdr, size, AErr) then Exit;
  if size < 512 then
  begin
    AErr := DocErr(decNotRsh, MSG_NOT_RSH, 'fichier trop court');
    Exit;
  end;
  for i := 0 to 15 do
    if hdr[i] <> Byte(SQLITE_MAGIC[i + 1]) then
    begin
      AErr := DocErr(decNotRsh, MSG_NOT_RSH, 'en-tete SQLite absent');
      Exit;
    end;
  appId := ReadBigEndian32(hdr, 68);
  if appId <> LongWord(RSH_APPLICATION_ID) then
  begin
    AErr := DocErr(decNotRsh, MSG_NOT_RSH,
      Format('application_id=%d attendu=%d', [appId, RSH_APPLICATION_ID]));
    Exit;
  end;
  userVersion := ReadBigEndian32(hdr, 60);
  if userVersion > RSH_SCHEMA_VERSION then
  begin
    AErr := DocErr(decFutureVersion, MSG_FUTURE,
      Format('user_version=%d supporte=%d', [userVersion, RSH_SCHEMA_VERSION]));
    Exit;
  end;
  if userVersion < 1 then
  begin
    AErr := DocErr(decNotRsh, MSG_NOT_RSH, 'user_version=0');
    Exit;
  end;
  Result := True;
end;

function ReadFileBytes(const APath: string; AMaxBytes: Int64): TBytes;
var
  fs: TFileStream;
  n: Int64;
begin
  Result := nil;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    // taille figee UNE fois: la relire pendant la lecture ferait deborder le buffer
    n := fs.Size;
    if (AMaxBytes > 0) and (n > AMaxBytes) then
      raise EReadError.CreateFmt('file too large: %d > %d', [n, AMaxBytes]);
    SetLength(Result, n);
    if n > 0 then
      fs.ReadBuffer(Result[0], n);
  finally
    fs.Free;
  end;
end;

procedure WriteFileBytesPrivate(const APath: string; const ABytes: TBytes);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(APath, fmCreate);
  try
    if Length(ABytes) > 0 then
      fs.WriteBuffer(ABytes[0], Length(ABytes));
  finally
    fs.Free;
  end;
  MakePrivateFile(APath);
end;

procedure CopyFilePrivate(const ASrc, ADest: string);
var
  src, dst: TFileStream;
begin
  src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyNone);
  try
    dst := TFileStream.Create(ADest, fmCreate);
    try
      dst.CopyFrom(src, src.Size);
    finally
      dst.Free;
    end;
  finally
    src.Free;
  end;
  MakePrivateFile(ADest);
end;

function OriginSidecarPath(const AWorkingPath: string): string;
begin
  Result := AWorkingPath + '.origin';
end;

procedure WriteOriginSidecar(const AWorkingPath, AOrigin: string);
var
  sl: TStringList;
begin
  if AOrigin = '' then Exit;
  sl := TStringList.Create;
  try
    sl.Add(AOrigin);
    try
      sl.SaveToFile(OriginSidecarPath(AWorkingPath));
      MakePrivateFile(OriginSidecarPath(AWorkingPath));
    except
    end;
  finally
    sl.Free;
  end;
end;

function ReadOriginSidecar(const AWorkingPath: string): string;
var
  sl: TStringList;
begin
  Result := '';
  if not FileExists(OriginSidecarPath(AWorkingPath)) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(OriginSidecarPath(AWorkingPath));
      if sl.Count > 0 then
        Result := Trim(sl[0]);
    except
      Result := '';
    end;
  finally
    sl.Free;
  end;
end;

procedure CopyWorkingTrio(const ASrc, ADest: string);
begin
  CopyFilePrivate(ASrc, ADest);
  if FileExists(ASrc + '-wal') then
    CopyFilePrivate(ASrc + '-wal', ADest + '-wal');
  if FileExists(ASrc + '-shm') then
    CopyFilePrivate(ASrc + '-shm', ADest + '-shm');
end;

procedure DeleteWorkingArtifacts(const AWorkingPath: string);
begin
  if AWorkingPath = '' then Exit;
  if FileExists(AWorkingPath) then DeleteFile(AWorkingPath);
  if FileExists(AWorkingPath + '-wal') then DeleteFile(AWorkingPath + '-wal');
  if FileExists(AWorkingPath + '-shm') then DeleteFile(AWorkingPath + '-shm');
  if FileExists(OriginSidecarPath(AWorkingPath)) then
    DeleteFile(OriginSidecarPath(AWorkingPath));
end;

{ TRshDocument }

constructor TRshDocument.Create;
begin
  inherited Create;
  // 0 est un descripteur valide (stdin): l'absence de verrou doit etre -1
  FSourceLock := THandle(-1);
  FSchemaVersion := RSH_SCHEMA_VERSION;
end;

destructor TRshDocument.Destroy;
begin
  ReleaseSourceLock;
  FreeAndNil(FDb);
  // -wal/-shm survivent a la fermeture: laisses la, un arret propre passe pour un crash
  DeleteWorkingArtifacts(FWorkingPath);
  FreeAndNil(FDek);
  FreeAndNil(FMacKey);
  FreeAndNil(FEnvKey);
  FreeAndNil(FPendingKek);
  inherited Destroy;
end;

function CanonicalOf(const APath: string): string;
begin
  Result := '';
  if APath = '' then Exit;
  try
    Result := ExpandFileName(ResolveLink(ExpandFileName(APath)));
  except
    on E: Exception do
      Result := '';
  end;
end;

procedure TRshDocument.RecordSourceIdentity;
var
  sr: TSearchRec;
begin
  FSrcSize := -1;
  FSrcMTime := 0;
  FSrcDev := 0;
  FSrcIno := 0;
  FSrcCanonical := CanonicalOf(FSourcePath);
  if FindFirst(FSourcePath, faAnyFile, sr) = 0 then
  begin
    FSrcSize := sr.Size;
    FSrcMTime := sr.TimeStamp;
    FindClose(sr);
    FileIdentity(FSourcePath, FSrcDev, FSrcIno);
  end;
end;

// un ecrasement confirme accepte de perdre un contenu, pas d'ecrire ailleurs
function TRshDocument.SourceTargetChanged: Boolean;
begin
  Result := (FSrcCanonical <> '')
    and (CanonicalOf(FSourcePath) <> FSrcCanonical);
end;

function TRshDocument.SourceChangedExternally: Boolean;
var
  sr: TSearchRec;
  dev, ino: Int64;
begin
  Result := False;
  if FSrcSize < 0 then Exit;

  if SourceTargetChanged then
    Exit(True);

  if FindFirst(FSourcePath, faAnyFile, sr) <> 0 then
    Exit(True);
  Result := (sr.Size <> FSrcSize) or (sr.TimeStamp <> FSrcMTime);
  FindClose(sr);
  if Result then Exit;

  // taille et date se recopient a l'identique; l'inode change a tout rename
  if FileIdentity(FSourcePath, dev, ino) then
    Result := (dev <> FSrcDev) or (ino <> FSrcIno)
  else
    Result := True;
end;

function TRshDocument.AcquireSourceLock(const ATarget: string): Boolean;
var
  h: THandle;
  held: Boolean;
  p: string;
begin
  if ATarget = '' then Exit(True);
  // flock refuserait un second verrou du meme processus sur le meme temoin
  p := DocumentLockPath(ATarget);
  if (p <> '') and (p = FLockPath) and (FSourceLock <> THandle(-1)) then
    Exit(True);
  h := TryLockDocument(ATarget, held);
  // verrou consultatif: seul « detenu par un autre » echoue, pas l'echec a poser
  if held then
    Exit(False);
  ReleaseSourceLock;
  FSourceLock := h;
  FLockPath := p;
  Result := True;
end;

procedure TRshDocument.ReleaseSourceLock;
begin
  if FSourceLock <> THandle(-1) then
  begin
    UnlockFile(FSourceLock);
    FSourceLock := THandle(-1);
    {$IFDEF WINDOWS}
    // Windows seul: DeleteFile echoue si une autre instance a repris le temoin.
    // Sous Unix, supprimer un temoin sous flock casserait l'exclusion.
    if FLockPath <> '' then
      DeleteFile(FLockPath);
    {$ENDIF}
  end;
  FLockPath := '';
end;

procedure TRshDocument.MetaSetText(const AKey, AValue: string);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('INSERT OR REPLACE INTO document_meta(key, value_text)' +
    ' VALUES(?,?);');
  try
    st.BindText(1, AKey);
    st.BindText(2, AValue);
    st.Step;
  finally
    st.Free;
  end;
end;

procedure TRshDocument.MetaSetInt(const AKey: string; AValue: Int64);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('INSERT OR REPLACE INTO document_meta(key, value_int)' +
    ' VALUES(?,?);');
  try
    st.BindText(1, AKey);
    st.BindInt64(2, AValue);
    st.Step;
  finally
    st.Free;
  end;
end;

procedure TRshDocument.MetaSetBlob(const AKey: string; const AValue: TBytes);
var
  st: TSqliteStmt;
begin
  st := FDb.Prepare('INSERT OR REPLACE INTO document_meta(key, value_blob)' +
    ' VALUES(?,?);');
  try
    st.BindText(1, AKey);
    st.BindBlob(2, AValue);
    st.Step;
  finally
    st.Free;
  end;
end;

function TRshDocument.MetaGetText(const AKey: string; out AValue: string): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  AValue := '';
  st := FDb.Prepare('SELECT value_text FROM document_meta WHERE key=?;');
  try
    st.BindText(1, AKey);
    if st.Step and not st.ColIsNull(0) then
    begin
      AValue := st.ColText(0);
      Result := True;
    end;
  finally
    st.Free;
  end;
end;

function TRshDocument.MetaGetInt(const AKey: string; out AValue: Int64): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  AValue := 0;
  st := FDb.Prepare('SELECT value_int FROM document_meta WHERE key=?;');
  try
    st.BindText(1, AKey);
    if st.Step and not st.ColIsNull(0) then
    begin
      AValue := st.ColInt64(0);
      Result := True;
    end;
  finally
    st.Free;
  end;
end;

function TRshDocument.MetaGetBlob(const AKey: string; out AValue: TBytes): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  AValue := nil;
  st := FDb.Prepare('SELECT value_blob FROM document_meta WHERE key=?;');
  try
    st.BindText(1, AKey);
    if st.Step and not st.ColIsNull(0) then
    begin
      AValue := st.ColBlob(0);
      Result := True;
    end;
  finally
    st.Free;
  end;
end;

function TRshDocument.CanonicalContentBytes: TBytes;
var
  buf: TMemoryStream;
  st: TSqliteStmt;
  q: string;
  col, n: Integer;
  b: TBytes;
  s: string;
  v: Int64;

  procedure PutByte(AB: Byte);
  begin
    buf.WriteBuffer(AB, 1);
  end;

  procedure PutLen(ALen: LongWord);
  var
    be: array[0..3] of Byte;
  begin
    be[0] := (ALen shr 24) and $FF;
    be[1] := (ALen shr 16) and $FF;
    be[2] := (ALen shr 8) and $FF;
    be[3] := ALen and $FF;
    buf.WriteBuffer(be[0], 4);
  end;

  procedure PutInt64BE(AV: Int64);
  var
    be: array[0..7] of Byte;
    i: Integer;
  begin
    for i := 0 to 7 do
      be[i] := (QWord(AV) shr (8 * (7 - i))) and $FF;
    buf.WriteBuffer(be[0], 8);
  end;

begin
  buf := TMemoryStream.Create;
  try
    for q in CanonicalQueriesFor(FSchemaVersion) do
    begin
      PutByte(Ord('Q'));
      PutLen(Length(q));
      if Length(q) > 0 then
        buf.WriteBuffer(q[1], Length(q));
      st := FDb.Prepare(q);
      try
        while st.Step do
        begin
          PutByte(Ord('R'));
          for col := 0 to st.ColCount - 1 do
            case st.ColType(col) of
              SQLITE_NULL:
                PutByte(Ord('N'));
              SQLITE_INTEGER:
                begin
                  PutByte(Ord('I'));
                  v := st.ColInt64(col);
                  PutInt64BE(v);
                end;
              SQLITE_TEXT:
                begin
                  PutByte(Ord('T'));
                  s := st.ColText(col);
                  PutLen(Length(s));
                  if Length(s) > 0 then
                    buf.WriteBuffer(s[1], Length(s));
                end;
              SQLITE_BLOB:
                begin
                  PutByte(Ord('B'));
                  b := st.ColBlob(col);
                  PutLen(Length(b));
                  if Length(b) > 0 then
                    buf.WriteBuffer(b[0], Length(b));
                end;
            else
              raise ESqliteDbError.CreateRc(0, 'unexpected column type');
            end;
        end;
      finally
        st.Free;
      end;
    end;
    Result := nil;
    n := buf.Size;
    SetLength(Result, n);
    if n > 0 then
      Move(buf.Memory^, Result[0], n);
  finally
    buf.Free;
  end;
end;

function TRshDocument.ComputeContentMac: TBytes;
begin
  Result := ComputeKeyedMac(FMacKey, CanonicalContentBytes);
end;

procedure TRshDocument.SealContent;
begin
  if FMacKey = nil then
    Exit;
  MetaSetInt(META_UPDATED_AT, NowUtcMs);
  MetaSetBlob(META_CONTENT_MAC, ComputeContentMac);
end;

class function TRshDocument.NewDocument(const APath: string;
  const APassword: RawByteString; out ADoc: TRshDocument;
  out AErr: TDocError; AOps: Int64; AMem: Int64): Boolean;
var
  doc: TRshDocument;
  kek: TSecureBytes;
  salt, dekNonce, encDek: TBytes;
  nowMs: Int64;
begin
  Result := False;
  ADoc := nil;
  AErr := NoErr;
  if APassword = '' then
  begin
    AErr := DocErr(decIo, 'The password cannot be empty.', 'mdp vide');
    Exit;
  end;
  SodiumEnsureLoaded;
  doc := TRshDocument.Create;
  try
    doc.FSourcePath := APath;
    if not doc.AcquireSourceLock(APath) then
    begin
      AErr := DocErr(decLocked, MSG_LOCKED, 'cible verrouillee par une autre instance');
      doc.Free;
      Exit;
    end;
    doc.FDocumentUuid := NewUuid;
    doc.FCryptoVersion := RSH_CRYPTO_VERSION;
    doc.FWorkingPath := InstanceRecoveryDir + PathDelim + NewUuid +
      '.working.rsh';

    doc.FDb := TSqliteDb.Open(doc.FWorkingPath, False, True);
    MakePrivateFile(doc.FWorkingPath);
    WriteOriginSidecar(doc.FWorkingPath, APath);
    doc.FDb.Harden;
    doc.FDb.ExecScript('PRAGMA journal_mode=WAL;');
    InitializeSchema(doc.FDb);

    salt := GenerateRandomBytes(KDF_SALT_BYTES);
    doc.FDek := GenerateDek;
    kek := DeriveKek(APassword, salt, AOps, AMem);
    try
      WrapDek(doc.FDek, kek, doc.FDocumentUuid, doc.FCryptoVersion,
        dekNonce, encDek);
      doc.FEnvKey := DeriveEnvelopeKey(kek);
    finally
      kek.Free;
    end;
    doc.FMacKey := DeriveContentMacKey(doc.FDek);
    doc.FDb.BeforeCommit := @doc.SealContent;

    nowMs := NowUtcMs;
    doc.FDb.BeginImmediate;
    try
      doc.MetaSetText(META_FORMAT_NAME, RSH_FORMAT_NAME);
      doc.MetaSetInt(META_FORMAT_VERSION, RSH_FORMAT_VERSION);
      doc.MetaSetText(META_DOCUMENT_UUID, doc.FDocumentUuid);
      doc.MetaSetInt(META_CREATED_AT, nowMs);
      doc.MetaSetInt(META_UPDATED_AT, nowMs);
      doc.MetaSetInt(META_CRYPTO_VERSION, doc.FCryptoVersion);
      doc.MetaSetText(META_KDF_ALGORITHM, KDF_ALGORITHM_NAME);
      doc.MetaSetBlob(META_KDF_SALT, salt);
      doc.MetaSetInt(META_KDF_OPSLIMIT, AOps);
      doc.MetaSetInt(META_KDF_MEMLIMIT, AMem);
      doc.MetaSetBlob(META_DEK_NONCE, dekNonce);
      doc.MetaSetBlob(META_ENCRYPTED_DEK, encDek);
      doc.FDb.Commit;
    except
      doc.FDb.Rollback;
      raise;
    end;

    if not doc.SaveTo(APath, False, AErr) then
    begin
      doc.Free;
      Exit;
    end;
    ADoc := doc;
    Result := True;
  except
    on E: Exception do
    begin
      doc.Free;
      AErr := DocErr(decIo, 'Failed to create the document.', E.Message);
    end;
  end;
end;

function TRshDocument.LoadWorkingCopy(const APassword: RawByteString;
  out AErr: TDocError): Boolean;
var
  sErr: string;
begin
  Result := False;
  AErr := NoErr;

  FDb := TSqliteDb.Open(FWorkingPath, False, False);
  FDb.Harden;
  if not FDb.QuickCheckOk then
  begin
    AErr := DocErr(decCorrupt, MSG_CORRUPT, 'quick_check en echec');
    Exit;
  end;
  FSchemaVersion := FDb.GetUserVersion;
  if (FSchemaVersion < 1) or (FSchemaVersion > RSH_SCHEMA_VERSION) then
  begin
    AErr := DocErr(decTampered, MSG_TAMPERED,
      Format('user_version=%d hors bornes', [FSchemaVersion]));
    Exit;
  end;
  if not ValidateSchemaFor(FDb, FSchemaVersion, sErr) then
  begin
    AErr := DocErr(decTampered, MSG_TAMPERED, sErr);
    Exit;
  end;
  if not VerifyMigrationLedger(FDb, sErr) then
  begin
    AErr := DocErr(decTampered, MSG_TAMPERED, sErr);
    Exit;
  end;
  FDb.ExecScript('PRAGMA journal_mode=WAL;');
  if not UnlockCrypto(APassword, AErr) then
    Exit;

  // migrer APRES le content_mac: on ne migre que ce qu'on a authentifie
  if not UpgradeSchemaIfNeeded(AErr) then
    Exit(False);
  Result := True;
end;

function TRshDocument.UpgradeSchemaIfNeeded(out AErr: TDocError): Boolean;
begin
  AErr := NoErr;
  Result := True;
  if FReadOnly or (FSchemaVersion >= RSH_SCHEMA_VERSION) then
    Exit;
  try
    // FSchemaVersion avancee AVANT: le sceau doit prendre le jeu qu'il committe
    while FSchemaVersion < RSH_SCHEMA_VERSION do
    begin
      FSchemaVersion := FSchemaVersion + 1;
      ApplyMigration(FDb, FSchemaVersion);
    end;
  except
    on E: Exception do
    begin
      FSchemaVersion := FDb.GetUserVersion;
      Result := False;
      AErr := DocErr(decIo, MSG_CORRUPT,
        'migration de schema en echec: ' + E.Message);
    end;
  end;
end;

// derive en locales, n'installe qu'apres validation du content_mac
function TRshDocument.UnlockCrypto(const APassword: RawByteString;
  out AErr: TDocError): Boolean;
var
  kek, dek, envKey, macKey: TSecureBytes;
  sErr, kdfAlg, metaUuid: string;
  salt, dekNonce, encDek, storedMac, computedMac: TBytes;
  ops, mem, iv: Int64;
begin
  Result := False;
  AErr := NoErr;

  if not (MetaGetText(META_FORMAT_NAME, sErr) and (sErr = RSH_FORMAT_NAME)
    and MetaGetInt(META_FORMAT_VERSION, iv) and (iv = RSH_FORMAT_VERSION)
    and MetaGetText(META_DOCUMENT_UUID, metaUuid)
    and IsCanonicalUuid(metaUuid)
    and MetaGetInt(META_CRYPTO_VERSION, iv) and (iv = RSH_CRYPTO_VERSION)
    and MetaGetText(META_KDF_ALGORITHM, kdfAlg)
    and (kdfAlg = KDF_ALGORITHM_NAME)
    and MetaGetBlob(META_KDF_SALT, salt)
    and MetaGetInt(META_KDF_OPSLIMIT, ops)
    and MetaGetInt(META_KDF_MEMLIMIT, mem)
    and MetaGetBlob(META_DEK_NONCE, dekNonce)
    and MetaGetBlob(META_ENCRYPTED_DEK, encDek)
    and MetaGetBlob(META_CONTENT_MAC, storedMac)) then
  begin
    AErr := DocErr(decCorrupt, MSG_CORRUPT, 'document_meta incomplet');
    Exit;
  end;
  FDocumentUuid := metaUuid;
  FCryptoVersion := RSH_CRYPTO_VERSION;
  if not KdfParamsAcceptable(Length(salt), ops, mem) then
  begin
    AErr := DocErr(decTampered, MSG_TAMPERED, 'parametres KDF hors bornes');
    Exit;
  end;

  if FPendingKek <> nil then
  begin
    if (ops <> FPendingOps) or (mem <> FPendingMem)
      or (Length(salt) <> Length(FPendingSalt))
      or ((Length(salt) > 0) and
          not CompareMem(@salt[0], @FPendingSalt[0], Length(salt))) then
    begin
      FreeAndNil(FPendingKek);
      AErr := DocErr(decTampered, MSG_TAMPERED,
        'parametres KDF internes differents de l''en-tete d''enveloppe');
      Exit;
    end;
    kek := FPendingKek;
    FPendingKek := nil;
  end
  else
    kek := DeriveKek(APassword, salt, ops, mem);
  dek := nil;
  envKey := nil;
  macKey := nil;
  try
    try
      if not UnwrapDek(encDek, dekNonce, kek, FDocumentUuid,
        FCryptoVersion, dek) then
      begin
        AErr := DocErr(decBadPasswordOrCorrupt, MSG_BAD_PASSWORD_OR_CORRUPT,
          'authentification DEK en echec');
        Exit;
      end;
      envKey := DeriveEnvelopeKey(kek);
    finally
      kek.Free;
    end;

    macKey := DeriveContentMacKey(dek);
    computedMac := ComputeKeyedMac(macKey, CanonicalContentBytes);
    if not MacEquals(computedMac, storedMac) then
    begin
      // re-scelle a chaque mutation: un MAC invalide n'est jamais perime
      AErr := DocErr(decTampered, MSG_TAMPERED, 'content_mac invalide');
      Exit;
    end;

    FreeAndNil(FDek);
    FDek := dek;
    dek := nil;
    FreeAndNil(FEnvKey);
    FEnvKey := envKey;
    envKey := nil;
    FreeAndNil(FMacKey);
    FMacKey := macKey;
    macKey := nil;
  finally
    dek.Free;
    envKey.Free;
    macKey.Free;
  end;

  FDb.BeforeCommit := @SealContent;
  Result := True;
end;

class function TRshDocument.OpenDocument(const APath: string;
  const APassword: RawByteString; out ADoc: TRshDocument;
  out AErr: TDocError; AReadOnly: Boolean): Boolean;
var
  doc: TRshDocument;
  envBytes, payload, salt: TBytes;
  ops, mem: Int64;
  tech: string;
  kek, envKey: TSecureBytes;
begin
  Result := False;
  ADoc := nil;
  if not PrevalidateRshFile(APath, AErr) then Exit;
  SodiumEnsureLoaded;

  doc := TRshDocument.Create;
  try
    doc.FSourcePath := APath;
    doc.FReadOnly := AReadOnly;
    if not AReadOnly then
      if not doc.AcquireSourceLock(APath) then
      begin
        AErr := DocErr(decLocked, MSG_LOCKED,
          'verrou de document deja detenu');
        doc.Free;
        Exit;
      end;
    doc.RecordSourceIdentity;
    doc.FWorkingPath := InstanceRecoveryDir + PathDelim + NewUuid +
      '.working.rsh';

    // une seule passe Argon2id, la KEK part par FPendingKek
    try
      envBytes := ReadFileBytes(APath, MAX_DOCUMENT_BYTES);
    except
      on E: Exception do
      begin
        AErr := DocErr(decIo, 'Cannot read the file.', E.ClassName);
        doc.Free;
        Exit;
      end;
    end;
    if not EnvelopeParseHeader(envBytes, salt, ops, mem, tech) then
    begin
      AErr := DocErr(decTampered, MSG_TAMPERED, tech);
      doc.Free;
      Exit;
    end;
    kek := DeriveKek(APassword, salt, ops, mem);
    try
      envKey := DeriveEnvelopeKey(kek);
      try
        if not EnvelopeOpen(envBytes, envKey, payload) then
        begin
          AErr := DocErr(decBadPasswordOrCorrupt, MSG_BAD_PASSWORD_OR_CORRUPT,
            'authentification de l''enveloppe en echec');
          FreeAndNil(kek);
          doc.Free;
          Exit;
        end;
      finally
        envKey.Free;
      end;
    except
      FreeAndNil(kek);
      raise;
    end;
    envBytes := nil;
    doc.FPendingKek := kek;
    doc.FPendingSalt := salt;
    doc.FPendingOps := ops;
    doc.FPendingMem := mem;

    try
      WriteFileBytesPrivate(doc.FWorkingPath, payload);
    except
      on E: Exception do
      begin
        AErr := DocErr(decIo, 'Cannot create the working copy.',
          E.ClassName);
        doc.Free;
        Exit;
      end;
    end;
    payload := nil;
    if not PrevalidateWorkingSqlite(doc.FWorkingPath, AErr) then
    begin
      doc.Free;
      Exit;
    end;
    WriteOriginSidecar(doc.FWorkingPath, APath);

    if not doc.LoadWorkingCopy(APassword, AErr) then
    begin
      doc.Free;
      Exit;
    end;

    ADoc := doc;
    AErr := NoErr;
    Result := True;
  except
    on E: ESqliteDbError do
    begin
      doc.Free;
      AErr := DocErr(decCorrupt, MSG_CORRUPT, E.Message);
    end;
    on E: Exception do
    begin
      doc.Free;
      AErr := DocErr(decIo, 'Failed to open the document.', E.Message);
    end;
  end;
end;

class function TRshDocument.RecoverDocument(const AWorkingPath: string;
  const APassword: RawByteString; out ADoc: TRshDocument;
  out AOriginHint: string; out AErr: TDocError): Boolean;
var
  doc: TRshDocument;
begin
  Result := False;
  ADoc := nil;
  AOriginHint := ReadOriginSidecar(AWorkingPath);
  if not PrevalidateWorkingSqlite(AWorkingPath, AErr) then Exit;
  SodiumEnsureLoaded;

  doc := TRshDocument.Create;
  try
    doc.FSourcePath := '';
    doc.FSrcSize := -1;
    doc.FWorkingPath := InstanceRecoveryDir + PathDelim + NewUuid +
      '.working.rsh';
    try
      CopyWorkingTrio(AWorkingPath, doc.FWorkingPath);
    except
      on E: Exception do
      begin
        AErr := DocErr(decIo, 'Cannot copy the recovery data.',
          E.ClassName);
        doc.Free;
        Exit;
      end;
    end;
    WriteOriginSidecar(doc.FWorkingPath, AOriginHint);

    if not doc.LoadWorkingCopy(APassword, AErr) then
    begin
      doc.Free;
      Exit;
    end;
    doc.FRecoveredUnsaved := True;
    doc.FDirty := True;

    ADoc := doc;
    AErr := NoErr;
    Result := True;
  except
    on E: ESqliteDbError do
    begin
      doc.Free;
      AErr := DocErr(decCorrupt, MSG_CORRUPT, E.Message);
    end;
    on E: Exception do
    begin
      doc.Free;
      AErr := DocErr(decIo, 'Recovery failed.', E.Message);
    end;
  end;
end;

function TRshDocument.SaveTo(const ATarget: string; ACheckConflict: Boolean;
  out AErr: TDocError): Boolean;
var
  tmpStream: TStream;
  tmpName, realTarget, plainTmp: string;
  destDb: TSqliteDb;
  salt, payload, sealed: TBytes;
  ops, mem: Int64;
begin
  Result := False;
  AErr := NoErr;
  if not FDb.QuickCheckOk then
  begin
    AErr := DocErr(decCorrupt, MSG_CORRUPT, 'quick_check avant sauvegarde');
    Exit;
  end;
  // un document verrouille ne s'enregistre pas (FLocked fait foi, pas la cle)
  if FLocked or (FEnvKey = nil) then
  begin
    AErr := DocErr(decIo,
      'The document is locked: unlock it before saving.',
      'document verrouille ou cle d''enveloppe absente');
    Exit;
  end;
  // on ecrit dans la cible REELLE, pas dans le nom. CAPTUREE ici,
  // validee ici: re-resoudre plus tard rouvrirait la fenetre de substitution.
  realTarget := CanonicalOf(ATarget);
  if realTarget = '' then
    realTarget := ATarget;
  if (ATarget = FSourcePath) and (FSrcCanonical <> '')
    and (realTarget <> FSrcCanonical) then
  begin
    AErr := DocErr(decConflict, MSG_CONFLICT,
      'la cible ne designe plus le meme fichier (lien substitue ?)');
    Exit;
  end;
  if ACheckConflict and SourceChangedExternally then
  begin
    AErr := DocErr(decConflict, MSG_CONFLICT, 'identite du fichier cible modifiee');
    Exit;
  end;
  // le rename detache l'inode: les autres liens garderaient l'ancienne version
  if HasHardLinks(realTarget) then
  begin
    AErr := DocErr(decIo,
      'The target has other hard links that would keep the old content. ' +
      'Save under a new name instead.',
      'cible a liens physiques multiples');
    Exit;
  end;
  if not (MetaGetBlob(META_KDF_SALT, salt)
    and MetaGetInt(META_KDF_OPSLIMIT, ops)
    and MetaGetInt(META_KDF_MEMLIMIT, mem)) then
  begin
    AErr := DocErr(decCorrupt, MSG_CORRUPT, 'document_meta incomplet (KDF)');
    Exit;
  end;

  FDb.ExecScript('PRAGMA wal_checkpoint(TRUNCATE);');

  // le temporaire, document entier EN CLAIR, ne quitte pas le repertoire prive
  plainTmp := InstanceRecoveryDir + PathDelim + NewUuid + '.seal.tmp';
  tmpName := '';
  try
    destDb := TSqliteDb.Open(plainTmp, False, True);
    try
      MakePrivateFile(plainTmp);
      destDb.ExecScript('PRAGMA journal_mode=DELETE;PRAGMA synchronous=FULL;');
      FDb.BackupTo(destDb);
    finally
      destDb.Free;
    end;
    try
      payload := ReadFileBytes(plainTmp, MAX_DOCUMENT_BYTES);
    except
      on E: Exception do
      begin
        AErr := DocErr(decTooLarge,
          'The document exceeds the maximum allowed size.', E.Message);
        Exit;
      end;
    end;
    sealed := EnvelopeSeal(payload, FEnvKey, salt, ops, mem);
    payload := nil;

    if Length(sealed) > MAX_DOCUMENT_BYTES then
    begin
      AErr := DocErr(decTooLarge,
        'The document exceeds the maximum allowed size.',
        Format('scelle=%d max=%d', [Length(sealed), MAX_DOCUMENT_BYTES]));
      Exit;
    end;

    tmpStream := CreateTempIn(realTarget, tmpName);
    try
      if Length(sealed) > 0 then
        tmpStream.WriteBuffer(sealed[0], Length(sealed));
      {$IFDEF UNIX}
      // le fsync du repertoire ne rend durable que le NOM, pas le contenu
      if fpfsync(THandleStream(tmpStream).Handle) <> 0 then
      begin
        AErr := DocErr(decIo, 'Disk write not confirmed (fsync).',
          Format('errno=%d', [fpGetErrno]));
        Exit;
      end;
      {$ENDIF}
    finally
      tmpStream.Free;
    end;
    if (ATarget = FSourcePath) and SourceTargetChanged then
    begin
      AErr := DocErr(decConflict, MSG_CONFLICT,
        'la cible ne designe plus le meme fichier (lien substitue ?)');
      Exit;
    end;
    if ACheckConflict and SourceChangedExternally then
    begin
      AErr := DocErr(decConflict, MSG_CONFLICT,
        'cible modifiee pendant la sauvegarde');
      Exit;
    end;
    // un lien cree entre-temps garderait l'ancien inode apres le rename
    if HasHardLinks(realTarget) then
    begin
      AErr := DocErr(decIo,
        'The target has other hard links that would keep the old content. ' +
        'Save under a new name instead.',
        'lien physique cree pendant la sauvegarde');
      Exit;
    end;
    if not ReplaceByRenamePrivate(tmpName, realTarget) then
    begin
      AErr := DocErr(decIo, 'Cannot replace the target file.',
        'rename en echec');
      Exit;
    end;
    tmpName := '';
    {$IFDEF UNIX}
    FsyncDir(ExtractFileDir(realTarget));
    {$ENDIF}
  finally
    if (tmpName <> '') and FileExists(tmpName) then
      DeleteFile(tmpName);
    if FileExists(plainTmp) then
      DeleteFile(plainTmp);
  end;

  FSourcePath := ATarget;
  RecordSourceIdentity;
  FDirty := False;
  Result := True;
end;

function TRshDocument.Save(out AErr: TDocError): Boolean;
begin
  if FReadOnly then
  begin
    AErr := DocErr(decReadOnly, MSG_READONLY, 'document en lecture seule');
    Exit(False);
  end;
  Result := SaveTo(FSourcePath, True, AErr);
end;

procedure TRshDocument.Lock;
begin
  if FLocked then Exit;
  // couper le sceau AVANT d'effacer la cle: sinon une mutation passe et laisse
  // un content_mac perime, donc un document refuse a la reouverture
  if FDb <> nil then
  begin
    FDb.BeforeCommit := nil;
    FDb.MutationsBlocked := True;
  end;
  FreeAndNil(FMacKey);
  FreeAndNil(FDek);
  // FEnvKey AUSSI: elle ouvre l'enveloppe, donc toute la cartographie du parc
  FreeAndNil(FEnvKey);
  FLocked := True;
end;

function TRshDocument.VerifyPassword(const APassword: RawByteString): Boolean;
var
  kek, dek: TSecureBytes;
  salt, dekNonce, encDek: TBytes;
  ops, mem: Int64;
  uuid: string;
begin
  Result := False;
  if FDb = nil then Exit;
  // memes bornes qu'a l'ouverture: hors bornes, on ne derive rien
  if not (MetaGetText(META_DOCUMENT_UUID, uuid)
    and MetaGetBlob(META_KDF_SALT, salt)
    and MetaGetInt(META_KDF_OPSLIMIT, ops)
    and MetaGetInt(META_KDF_MEMLIMIT, mem)
    and MetaGetBlob(META_DEK_NONCE, dekNonce)
    and MetaGetBlob(META_ENCRYPTED_DEK, encDek)) then Exit;
  if not KdfParamsAcceptable(Length(salt), ops, mem) then Exit;
  try
    kek := DeriveKek(APassword, salt, ops, mem);
  except
    Exit;
  end;
  try
    dek := nil;
    Result := UnwrapDek(encDek, dekNonce, kek, uuid, FCryptoVersion, dek);
    // la DEK deballee ici ne survit pas a la question posee
    FreeAndNil(dek);
  finally
    kek.Free;
  end;
end;

function TRshDocument.Unlock(const APassword: RawByteString;
  out AErr: TDocError): Boolean;
begin
  AErr := NoErr;
  if not FLocked then Exit(True);
  Result := UnlockCrypto(APassword, AErr);
  if Result then
  begin
    FLocked := False;
    if FDb <> nil then
      FDb.MutationsBlocked := False;
  end
  else
  begin
    // defense en profondeur: « verrouille = aucune cle »
    FreeAndNil(FMacKey);
    FreeAndNil(FDek);
    FreeAndNil(FEnvKey);
    if FDb <> nil then
      FDb.BeforeCommit := nil;
  end;
end;

function TRshDocument.SaveOverwrite(out AErr: TDocError): Boolean;
begin
  if FReadOnly then
  begin
    AErr := DocErr(decReadOnly, MSG_READONLY, 'document en lecture seule');
    Exit(False);
  end;
  Result := SaveTo(FSourcePath, False, AErr);
end;

function TRshDocument.SaveAs(const ANewPath: string; out AErr: TDocError): Boolean;
var
  newPath: string;
  newLock: THandle;
  held, wasReadOnly: Boolean;
begin
  Result := False;
  newPath := DocumentLockPath(ANewPath);
  // inscriptible le temps de migrer NOTRE copie; le mode revient sur echec
  wasReadOnly := FReadOnly;

  if (newPath <> '') and (newPath = FLockPath) and
     (FSourceLock <> THandle(-1)) then
  begin
    try
      // migrer AVANT d'ecrire, un echec preserve l'ancien fichier
      FReadOnly := False;
      if not UpgradeSchemaIfNeeded(AErr) then Exit;
      Result := SaveTo(ANewPath, False, AErr);
    finally
      if not Result then
        FReadOnly := wasReadOnly;
    end;
    Exit;
  end;

  // verrou de la NOUVELLE cible sans lacher l'ancien: sur echec on doit encore
  // tenir l'original pour continuer a l'editer
  newLock := TryLockDocument(ANewPath, held);
  if held then
  begin
    AErr := DocErr(decLocked, MSG_LOCKED, 'cible verrouillee par une autre instance');
    Exit;
  end;

  try
    FReadOnly := False;
    if not UpgradeSchemaIfNeeded(AErr) then Exit;
    Result := SaveTo(ANewPath, False, AErr);
  finally
    // SaveTo peut LEVER: sans ce finally, newLock resterait detenu a jamais
    if not Result then
    begin
      FReadOnly := wasReadOnly;
      if newLock <> THandle(-1) then
        UnlockFile(newLock);
    end;
  end;

  if Result then
  begin
    ReleaseSourceLock;
    FSourceLock := newLock;
    FLockPath := newPath;
  end;
end;

function TRshDocument.ChangeMasterPassword(const AOldPassword,
  ANewPassword: RawByteString; out AErr: TDocError;
  AOps: Int64; AMem: Int64): Boolean;
var
  kek, dekCheck: TSecureBytes;
  salt, dekNonce, encDek: TBytes;
  ops, mem: Int64;
  oldSalt, oldDekNonce, oldEncDek: TBytes;
  oldOps, oldMem: Int64;
  committed: Boolean;
  oldEnvKey, newEnvKey: TSecureBytes;

  procedure RestoreEnvKey;
  begin
    if oldEnvKey <> nil then
    begin
      FreeAndNil(FEnvKey);
      FEnvKey := oldEnvKey;
      oldEnvKey := nil;
    end;
  end;

  procedure RestoreKdfMeta;
  begin
    try
      // meta d'abord, cle ENSUITE: l'ordre inverse laisserait, sur un commit
      // rate, un document que ni l'ancien ni le nouveau mot de passe n'ouvre
      FDb.BeginImmediate;
      try
        MetaSetBlob(META_KDF_SALT, oldSalt);
        MetaSetInt(META_KDF_OPSLIMIT, oldOps);
        MetaSetInt(META_KDF_MEMLIMIT, oldMem);
        MetaSetBlob(META_DEK_NONCE, oldDekNonce);
        MetaSetBlob(META_ENCRYPTED_DEK, oldEncDek);
        FDb.Commit;
      except
        FDb.Rollback;
        raise;
      end;
      RestoreEnvKey;
    except
      // RestoreEnvKey n'a pas eu lieu: oldEnvKey vit encore, la liberer wipe
      on E: Exception do
      begin
        FreeAndNil(oldEnvKey);
        LogError('ChangeMasterPassword: cannot restore KDF metadata: '
          + E.Message);
      end;
    end;
  end;

begin
  Result := False;
  AErr := NoErr;
  committed := False;
  oldEnvKey := nil;
  // meme regle que Save: en lecture seule, RIEN ne reecrit le fichier source
  if FReadOnly then
  begin
    AErr := DocErr(decReadOnly, MSG_READONLY,
      'ChangeMasterPassword refuse: read-only');
    Exit;
  end;
  if ANewPassword = '' then
  begin
    AErr := DocErr(decIo, 'The password cannot be empty.', 'mdp vide');
    Exit;
  end;
  try
    if not (MetaGetBlob(META_KDF_SALT, salt)
      and MetaGetInt(META_KDF_OPSLIMIT, ops)
      and MetaGetInt(META_KDF_MEMLIMIT, mem)
      and MetaGetBlob(META_DEK_NONCE, dekNonce)
      and MetaGetBlob(META_ENCRYPTED_DEK, encDek)) then
    begin
      AErr := DocErr(decCorrupt, MSG_CORRUPT, 'document_meta incomplet');
      Exit;
    end;
    oldSalt := Copy(salt);
    oldOps := ops;
    oldMem := mem;
    oldDekNonce := Copy(dekNonce);
    oldEncDek := Copy(encDek);

    kek := DeriveKek(AOldPassword, salt, ops, mem);
    try
      if not UnwrapDek(encDek, dekNonce, kek, FDocumentUuid,
        FCryptoVersion, dekCheck) then
      begin
        AErr := DocErr(decBadPasswordOrCorrupt, MSG_BAD_PASSWORD_OR_CORRUPT,
          'ancien mot de passe refuse');
        Exit;
      end;
      dekCheck.Free;
    finally
      kek.Free;
    end;

    salt := GenerateRandomBytes(KDF_SALT_BYTES);
    kek := DeriveKek(ANewPassword, salt, AOps, AMem);
    try
      WrapDek(FDek, kek, FDocumentUuid, FCryptoVersion, dekNonce, encDek);
      // deriver AVANT d'echanger: sinon oldEnvKey alias FEnvKey, double free
      newEnvKey := DeriveEnvelopeKey(kek);
      oldEnvKey := FEnvKey;
      FEnvKey := newEnvKey;
    finally
      kek.Free;
    end;

    FDb.BeginImmediate;
    try
      MetaSetBlob(META_KDF_SALT, salt);
      MetaSetInt(META_KDF_OPSLIMIT, AOps);
      MetaSetInt(META_KDF_MEMLIMIT, AMem);
      MetaSetBlob(META_DEK_NONCE, dekNonce);
      MetaSetBlob(META_ENCRYPTED_DEK, encDek);
      FDb.Commit;
      committed := True;
    except
      FDb.Rollback;
      raise;
    end;

    if not SaveTo(FSourcePath, True, AErr) then
    begin
      RestoreKdfMeta;
      Exit;
    end;
    FreeAndNil(oldEnvKey);
    Result := True;
  except
    on E: Exception do
    begin
      if committed then
        RestoreKdfMeta
      else
        RestoreEnvKey;
      AErr := DocErr(decIo, 'Failed to change the master password.',
        E.Message);
      Exit;
    end;
  end;
end;

procedure TRshDocument.EncryptFieldValue(const AOwnerUuid, AFieldName: string;
  APlain: TSecureBytes; out ANonce, ACipher: TBytes);
begin
  // filet: l'UI barre deja tout quand le document est verrouille
  if FLocked then
    raise EDocCryptoError.Create('document locked: no DEK available');
  AeadEncrypt(APlain, FDek,
    BuildAad(FDocumentUuid, AOwnerUuid, AFieldName, FCryptoVersion),
    ANonce, ACipher);
end;

function TRshDocument.DecryptFieldValue(const AOwnerUuid, AFieldName: string;
  const ANonce, ACipher: TBytes; out APlain: TSecureBytes): Boolean;
begin
  if FLocked then
    raise EDocCryptoError.Create('document locked: no DEK available');
  Result := AeadDecrypt(ACipher, ANonce, FDek,
    BuildAad(FDocumentUuid, AOwnerUuid, AFieldName, FCryptoVersion), APlain);
end;

procedure TRshDocument.MarkDirty;
begin
  FDirty := True;
end;

end.
