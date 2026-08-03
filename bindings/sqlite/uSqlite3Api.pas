unit uSqlite3Api;

{$mode objfpc}{$H+}

// Binding dynamique SQLite, chemins absolus controles. sqlite3_db_config est
// variadique: cdecl varargs impose, l'ABI arm64 Darwin les traite a part.

interface

uses
  SysUtils, ctypes;

const
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;

  SQLITE_OPEN_READONLY = $0001;
  SQLITE_OPEN_READWRITE = $0002;
  SQLITE_OPEN_CREATE = $0004;

  SQLITE_INTEGER = 1;
  SQLITE_FLOAT = 2;
  SQLITE_TEXT = 3;
  SQLITE_BLOB = 4;
  SQLITE_NULL = 5;

  SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003;
  SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION = 1005;
  SQLITE_DBCONFIG_DEFENSIVE = 1010;
  SQLITE_DBCONFIG_ENABLE_VIEW = 1015;
  SQLITE_DBCONFIG_TRUSTED_SCHEMA = 1017;

  SQLITE_LIMIT_LENGTH = 0;
  SQLITE_LIMIT_SQL_LENGTH = 1;
  SQLITE_LIMIT_COLUMN = 2;
  SQLITE_LIMIT_EXPR_DEPTH = 3;
  SQLITE_LIMIT_COMPOUND_SELECT = 4;
  SQLITE_LIMIT_VDBE_OP = 5;
  SQLITE_LIMIT_FUNCTION_ARG = 6;
  SQLITE_LIMIT_ATTACHED = 7;
  SQLITE_LIMIT_LIKE_PATTERN_LENGTH = 8;
  SQLITE_LIMIT_VARIABLE_NUMBER = 9;
  SQLITE_LIMIT_TRIGGER_DEPTH = 10;

  // 3.26 introduit DEFENSIVE et trusted_schema
  SQLITE_MIN_VERSION_NUMBER = 3026000;

type
  ESqliteApiError = class(Exception);

  Psqlite3 = Pointer;
  Psqlite3_stmt = Pointer;
  Psqlite3_backup = Pointer;

  Tsqlite3_libversion_number = function: cint; cdecl;
  Tsqlite3_open_v2 = function(filename: PAnsiChar; out db: Psqlite3;
    flags: cint; vfs: PAnsiChar): cint; cdecl;
  Tsqlite3_close = function(db: Psqlite3): cint; cdecl;
  Tsqlite3_errmsg = function(db: Psqlite3): PAnsiChar; cdecl;
  Tsqlite3_extended_errcode = function(db: Psqlite3): cint; cdecl;
  Tsqlite3_prepare_v2 = function(db: Psqlite3; zSql: PAnsiChar; nByte: cint;
    out stmt: Psqlite3_stmt; out zTail: PAnsiChar): cint; cdecl;
  Tsqlite3_step = function(stmt: Psqlite3_stmt): cint; cdecl;
  Tsqlite3_finalize = function(stmt: Psqlite3_stmt): cint; cdecl;
  Tsqlite3_reset = function(stmt: Psqlite3_stmt): cint; cdecl;
  Tsqlite3_bind_int64 = function(stmt: Psqlite3_stmt; idx: cint;
    v: cint64): cint; cdecl;
  Tsqlite3_bind_text = function(stmt: Psqlite3_stmt; idx: cint;
    v: PAnsiChar; n: cint; destr: Pointer): cint; cdecl;
  Tsqlite3_bind_blob = function(stmt: Psqlite3_stmt; idx: cint;
    v: Pointer; n: cint; destr: Pointer): cint; cdecl;
  Tsqlite3_bind_null = function(stmt: Psqlite3_stmt; idx: cint): cint; cdecl;
  Tsqlite3_column_count = function(stmt: Psqlite3_stmt): cint; cdecl;
  Tsqlite3_column_type = function(stmt: Psqlite3_stmt; col: cint): cint; cdecl;
  Tsqlite3_column_int64 = function(stmt: Psqlite3_stmt; col: cint): cint64; cdecl;
  Tsqlite3_column_text = function(stmt: Psqlite3_stmt; col: cint): PAnsiChar; cdecl;
  Tsqlite3_column_blob = function(stmt: Psqlite3_stmt; col: cint): Pointer; cdecl;
  Tsqlite3_column_bytes = function(stmt: Psqlite3_stmt; col: cint): cint; cdecl;
  Tsqlite3_column_name = function(stmt: Psqlite3_stmt; col: cint): PAnsiChar; cdecl;
  Tsqlite3_changes = function(db: Psqlite3): cint; cdecl;
  Tsqlite3_busy_timeout = function(db: Psqlite3; ms: cint): cint; cdecl;
  Tsqlite3_limit = function(db: Psqlite3; id, newVal: cint): cint; cdecl;
  Tsqlite3_db_config = function(db: Psqlite3; op: cint): cint; cdecl; varargs;
  Tsqlite3_backup_init = function(dest: Psqlite3; destName: PAnsiChar;
    source: Psqlite3; sourceName: PAnsiChar): Psqlite3_backup; cdecl;
  Tsqlite3_backup_step = function(bk: Psqlite3_backup; nPage: cint): cint; cdecl;
  Tsqlite3_backup_finish = function(bk: Psqlite3_backup): cint; cdecl;

var
  sqlite3_libversion_number: Tsqlite3_libversion_number = nil;
  sqlite3_open_v2: Tsqlite3_open_v2 = nil;
  sqlite3_close: Tsqlite3_close = nil;
  sqlite3_errmsg: Tsqlite3_errmsg = nil;
  sqlite3_extended_errcode: Tsqlite3_extended_errcode = nil;
  sqlite3_prepare_v2: Tsqlite3_prepare_v2 = nil;
  sqlite3_step: Tsqlite3_step = nil;
  sqlite3_finalize: Tsqlite3_finalize = nil;
  sqlite3_reset: Tsqlite3_reset = nil;
  sqlite3_bind_int64: Tsqlite3_bind_int64 = nil;
  sqlite3_bind_text: Tsqlite3_bind_text = nil;
  sqlite3_bind_blob: Tsqlite3_bind_blob = nil;
  sqlite3_bind_null: Tsqlite3_bind_null = nil;
  sqlite3_column_count: Tsqlite3_column_count = nil;
  sqlite3_column_type: Tsqlite3_column_type = nil;
  sqlite3_column_int64: Tsqlite3_column_int64 = nil;
  sqlite3_column_text: Tsqlite3_column_text = nil;
  sqlite3_column_blob: Tsqlite3_column_blob = nil;
  sqlite3_column_bytes: Tsqlite3_column_bytes = nil;
  sqlite3_column_name: Tsqlite3_column_name = nil;
  sqlite3_changes: Tsqlite3_changes = nil;
  sqlite3_busy_timeout: Tsqlite3_busy_timeout = nil;
  sqlite3_limit: Tsqlite3_limit = nil;
  sqlite3_db_config: Tsqlite3_db_config = nil;
  sqlite3_backup_init: Tsqlite3_backup_init = nil;
  sqlite3_backup_step: Tsqlite3_backup_step = nil;
  sqlite3_backup_finish: Tsqlite3_backup_finish = nil;

// pseudo-destructeur: SQLite copie la valeur liee
function SQLITE_TRANSIENT: Pointer; inline;

procedure SqliteEnsureLoaded;
function SqliteIsLoaded: Boolean;
// False sous SQLITE_OMIT_LOAD_EXTENSION (SQLite d'Apple): db_config 1005 y repond SQLITE_MISUSE
function SqliteHasLoadExtension: Boolean;

implementation

uses
  dynlibs;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GHasLoadExtension: Boolean = False;
  GInitLock: TRTLCriticalSection;

function AbsCandidate(const P: string): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := ((Length(P) >= 3) and (P[2] = ':') and
             ((P[3] = '\') or (P[3] = '/'))) or
            ((Length(P) >= 2) and (P[1] = '\') and (P[2] = '\'));
  {$ELSE}
  Result := (Length(P) >= 1) and (P[1] = '/');
  {$ENDIF}
end;

function SQLITE_TRANSIENT: Pointer; inline;
begin
  Result := {%H-}Pointer(PtrInt(-1));
end;

function CandidatePaths: TStringArray;
var
  exeDir: string;
begin
  exeDir := ExtractFilePath(ParamStr(0));
  {$IFDEF DARWIN}
  Result := [
    exeDir + '../Frameworks/libsqlite3.dylib',
    exeDir + 'libsqlite3.dylib',
    '/usr/lib/libsqlite3.dylib'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/libsqlite3.so.0',
    exeDir + 'libsqlite3.so.0',
    '/usr/lib/x86_64-linux-gnu/libsqlite3.so.0',
    '/usr/lib/libsqlite3.so.0'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := [exeDir + 'sqlite3.dll'];
  {$ENDIF}
end;

function MustSym(const AName: string): Pointer;
begin
  Result := GetProcAddress(GLib, AName);
  if Result = nil then
    raise ESqliteApiError.CreateFmt('sqlite3: missing symbol: %s', [AName]);
end;

procedure SqliteEnsureLoaded;
var
  p: string;
begin
  if GReady then Exit;
  EnterCriticalSection(GInitLock);
  try
  if GReady then Exit;
  for p in CandidatePaths do
    // /usr/lib sous macOS: la dylib vit dans le cache dyld, pas sur disque
    if AbsCandidate(p) and (FileExists(p) or (Pos('/usr/lib/', p) = 1)) then
    begin
      GLib := LoadLibrary(p);
      if GLib <> NilHandle then Break;
    end;
  if GLib = NilHandle then
    raise ESqliteApiError.Create('libsqlite3 not found in the expected locations');
  Pointer(sqlite3_libversion_number) := MustSym('sqlite3_libversion_number');
  if sqlite3_libversion_number() < SQLITE_MIN_VERSION_NUMBER then
    raise ESqliteApiError.CreateFmt('SQLite is too old (%d < %d)',
      [sqlite3_libversion_number(), SQLITE_MIN_VERSION_NUMBER]);
  Pointer(sqlite3_open_v2) := MustSym('sqlite3_open_v2');
  Pointer(sqlite3_close) := MustSym('sqlite3_close');
  Pointer(sqlite3_errmsg) := MustSym('sqlite3_errmsg');
  Pointer(sqlite3_extended_errcode) := MustSym('sqlite3_extended_errcode');
  Pointer(sqlite3_prepare_v2) := MustSym('sqlite3_prepare_v2');
  Pointer(sqlite3_step) := MustSym('sqlite3_step');
  Pointer(sqlite3_finalize) := MustSym('sqlite3_finalize');
  Pointer(sqlite3_reset) := MustSym('sqlite3_reset');
  Pointer(sqlite3_bind_int64) := MustSym('sqlite3_bind_int64');
  Pointer(sqlite3_bind_text) := MustSym('sqlite3_bind_text');
  Pointer(sqlite3_bind_blob) := MustSym('sqlite3_bind_blob');
  Pointer(sqlite3_bind_null) := MustSym('sqlite3_bind_null');
  Pointer(sqlite3_column_count) := MustSym('sqlite3_column_count');
  Pointer(sqlite3_column_type) := MustSym('sqlite3_column_type');
  Pointer(sqlite3_column_int64) := MustSym('sqlite3_column_int64');
  Pointer(sqlite3_column_text) := MustSym('sqlite3_column_text');
  Pointer(sqlite3_column_blob) := MustSym('sqlite3_column_blob');
  Pointer(sqlite3_column_bytes) := MustSym('sqlite3_column_bytes');
  Pointer(sqlite3_column_name) := MustSym('sqlite3_column_name');
  Pointer(sqlite3_changes) := MustSym('sqlite3_changes');
  Pointer(sqlite3_busy_timeout) := MustSym('sqlite3_busy_timeout');
  Pointer(sqlite3_limit) := MustSym('sqlite3_limit');
  Pointer(sqlite3_db_config) := MustSym('sqlite3_db_config');
  Pointer(sqlite3_backup_init) := MustSym('sqlite3_backup_init');
  Pointer(sqlite3_backup_step) := MustSym('sqlite3_backup_step');
  Pointer(sqlite3_backup_finish) := MustSym('sqlite3_backup_finish');
  GHasLoadExtension :=
    GetProcAddress(GLib, 'sqlite3_enable_load_extension') <> nil;
  GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function SqliteHasLoadExtension: Boolean;
begin
  Result := GHasLoadExtension;
end;

function SqliteIsLoaded: Boolean;
begin
  Result := GReady;
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  DoneCriticalSection(GInitLock);

end.
