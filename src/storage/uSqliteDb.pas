unit uSqliteDb;

{$mode objfpc}{$H+}

// Wrappers RAII SQLite + durcissement.
// Un .rsh est une entree non fiable: Harden doit etre appele avant
// toute requete sur une base venant de l'exterieur.

interface

uses
  SysUtils, uSqlite3Api;

type
  ESqliteDbError = class(Exception)
  private
    FResultCode: Integer;
  public
    constructor CreateRc(ARc: Integer; const AMsg: string);
    property ResultCode: Integer read FResultCode;
  end;

  TSqliteDb = class;

  // appele dans Commit avant le COMMIT SQL, meme transaction; jamais Commit/Rollback
  TDbBeforeCommit = procedure of object;

  TSqliteStmt = class
  private
    FStmt: Psqlite3_stmt;
    FDb: TSqliteDb;
  public
    constructor Create(ADb: TSqliteDb; AStmt: Psqlite3_stmt);
    destructor Destroy; override;
    procedure BindText(AIdx: Integer; const AValue: string);
    procedure BindBlob(AIdx: Integer; const AValue: TBytes);
    procedure BindInt64(AIdx: Integer; AValue: Int64);
    procedure BindNull(AIdx: Integer);
    function Step: Boolean;
    procedure Reset;
    function ColCount: Integer;
    function ColType(ACol: Integer): Integer;
    function ColInt64(ACol: Integer): Int64;
    function ColText(ACol: Integer): string;
    function ColBlob(ACol: Integer): TBytes;
    function ColIsNull(ACol: Integer): Boolean;
  end;

  TSqliteDb = class
  private
    FDb: Psqlite3;
    FPath: string;
    FBeforeCommit: TDbBeforeCommit;
    FInBeforeCommit: Boolean;
    FTxDepth: Integer;
    FMutationsBlocked: Boolean;
    procedure Check(ARc: Integer; const AContext: string);
  public
    constructor Open(const APath: string; AReadOnly, ACreate: Boolean);
    destructor Destroy; override;

    procedure Harden;

    function Prepare(const ASql: string): TSqliteStmt;
    // execute une suite d'instructions constantes du binaire (DDL, PRAGMA)
    procedure ExecScript(const ASql: string);
    function ExecScalarInt(const ASql: string): Int64;
    function ExecScalarText(const ASql: string): string;

    procedure BeginImmediate;
    procedure Commit;
    procedure Rollback;
    property BeforeCommit: TDbBeforeCommit read FBeforeCommit write FBeforeCommit;
    // vrai = ecriture refusee: sans crypto, le MAC ne se re-scelle plus
    property MutationsBlocked: Boolean read FMutationsBlocked
      write FMutationsBlocked;

    function QuickCheckOk: Boolean;
    function IntegrityCheckOk: Boolean;

    function GetUserVersion: Int64;
    procedure SetUserVersion(AValue: Int64);
    function GetApplicationId: Int64;
    procedure SetApplicationId(AValue: Int64);

    procedure BackupTo(ADest: TSqliteDb);

    property Handle: Psqlite3 read FDb;
    property Path: string read FPath;
  end;

implementation

uses
  ctypes;

constructor ESqliteDbError.CreateRc(ARc: Integer; const AMsg: string);
begin
  inherited Create(AMsg);
  FResultCode := ARc;
end;

constructor TSqliteStmt.Create(ADb: TSqliteDb; AStmt: Psqlite3_stmt);
begin
  inherited Create;
  FDb := ADb;
  FStmt := AStmt;
end;

destructor TSqliteStmt.Destroy;
begin
  if FStmt <> nil then
    sqlite3_finalize(FStmt);
  inherited Destroy;
end;

procedure TSqliteStmt.BindText(AIdx: Integer; const AValue: string);
begin
  FDb.Check(sqlite3_bind_text(FStmt, AIdx, PAnsiChar(AValue),
    Length(AValue), SQLITE_TRANSIENT), 'bind_text');
end;

procedure TSqliteStmt.BindBlob(AIdx: Integer; const AValue: TBytes);
var
  p: Pointer;
begin
  if Length(AValue) > 0 then
    p := @AValue[0]
  else
    p := PAnsiChar('');
  FDb.Check(sqlite3_bind_blob(FStmt, AIdx, p, Length(AValue),
    SQLITE_TRANSIENT), 'bind_blob');
end;

procedure TSqliteStmt.BindInt64(AIdx: Integer; AValue: Int64);
begin
  FDb.Check(sqlite3_bind_int64(FStmt, AIdx, AValue), 'bind_int64');
end;

procedure TSqliteStmt.BindNull(AIdx: Integer);
begin
  FDb.Check(sqlite3_bind_null(FStmt, AIdx), 'bind_null');
end;

function TSqliteStmt.Step: Boolean;
var
  rc: Integer;
begin
  rc := sqlite3_step(FStmt);
  case rc of
    SQLITE_ROW: Result := True;
    SQLITE_DONE: Result := False;
  else
    begin
      Result := False;
      FDb.Check(rc, 'step');
    end;
  end;
end;

procedure TSqliteStmt.Reset;
begin
  FDb.Check(sqlite3_reset(FStmt), 'reset');
end;

function TSqliteStmt.ColCount: Integer;
begin
  Result := sqlite3_column_count(FStmt);
end;

function TSqliteStmt.ColType(ACol: Integer): Integer;
begin
  Result := sqlite3_column_type(FStmt, ACol);
end;

function TSqliteStmt.ColInt64(ACol: Integer): Int64;
begin
  Result := sqlite3_column_int64(FStmt, ACol);
end;

function TSqliteStmt.ColText(ACol: Integer): string;
var
  p: PAnsiChar;
  n: Integer;
begin
  p := sqlite3_column_text(FStmt, ACol);
  n := sqlite3_column_bytes(FStmt, ACol);
  SetLength(Result, n);
  if n > 0 then
    Move(p^, Result[1], n);
end;

function TSqliteStmt.ColBlob(ACol: Integer): TBytes;
var
  p: Pointer;
  n: Integer;
begin
  Result := nil;
  p := sqlite3_column_blob(FStmt, ACol);
  n := sqlite3_column_bytes(FStmt, ACol);
  SetLength(Result, n);
  if n > 0 then
    Move(p^, Result[0], n);
end;

function TSqliteStmt.ColIsNull(ACol: Integer): Boolean;
begin
  Result := sqlite3_column_type(FStmt, ACol) = SQLITE_NULL;
end;

procedure TSqliteDb.Check(ARc: Integer; const AContext: string);
var
  msg: string;
begin
  if ARc = SQLITE_OK then Exit;
  if FDb <> nil then
    msg := string(sqlite3_errmsg(FDb))
  else
    msg := 'SQLite error';
  raise ESqliteDbError.CreateRc(ARc,
    Format('SQLite [%s] rc=%d: %s', [AContext, ARc, msg]));
end;

constructor TSqliteDb.Open(const APath: string; AReadOnly, ACreate: Boolean);
var
  flags, rc: Integer;
begin
  inherited Create;
  SqliteEnsureLoaded;
  FPath := APath;
  if AReadOnly then
    flags := SQLITE_OPEN_READONLY
  else if ACreate then
    flags := SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE
  else
    flags := SQLITE_OPEN_READWRITE;
  rc := sqlite3_open_v2(PAnsiChar(APath), FDb, flags, nil);
  if rc <> SQLITE_OK then
  begin
    if FDb <> nil then
    begin
      sqlite3_close(FDb);
      FDb := nil;
    end;
    raise ESqliteDbError.CreateRc(rc,
      Format('cannot open the database (rc=%d)', [rc]));
  end;
end;

destructor TSqliteDb.Destroy;
begin
  if FDb <> nil then
    sqlite3_close(FDb);
  inherited Destroy;
end;

procedure TSqliteDb.Harden;
begin
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_DEFENSIVE, cint(1), nil),
    'defensive');
  if SqliteHasLoadExtension then
    Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION,
      cint(0), nil), 'no_load_extension');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_TRIGGER, cint(0), nil),
    'no_trigger');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_ENABLE_VIEW, cint(0), nil),
    'no_view');
  Check(sqlite3_db_config(FDb, SQLITE_DBCONFIG_TRUSTED_SCHEMA, cint(0), nil),
    'no_trusted_schema');
  ExecScript(
    'PRAGMA trusted_schema=OFF;' +
    'PRAGMA foreign_keys=ON;' +
    'PRAGMA recursive_triggers=OFF;' +
    'PRAGMA writable_schema=OFF;');
  sqlite3_limit(FDb, SQLITE_LIMIT_ATTACHED, 0);
  // ciphertext credential max 16 Mio + marge
  sqlite3_limit(FDb, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024);
  sqlite3_limit(FDb, SQLITE_LIMIT_SQL_LENGTH, 256 * 1024);
  sqlite3_limit(FDb, SQLITE_LIMIT_COLUMN, 64);
  sqlite3_limit(FDb, SQLITE_LIMIT_EXPR_DEPTH, 100);
  sqlite3_limit(FDb, SQLITE_LIMIT_COMPOUND_SELECT, 8);
  sqlite3_limit(FDb, SQLITE_LIMIT_VDBE_OP, 250000);
  sqlite3_limit(FDb, SQLITE_LIMIT_FUNCTION_ARG, 8);
  sqlite3_limit(FDb, SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 128);
  sqlite3_limit(FDb, SQLITE_LIMIT_VARIABLE_NUMBER, 64);
  // ON DELETE CASCADE compte comme recursion de trigger: profondeur d'arbre (64) + marge
  sqlite3_limit(FDb, SQLITE_LIMIT_TRIGGER_DEPTH, 128);
  sqlite3_busy_timeout(FDb, 5000);
end;

function TSqliteDb.Prepare(const ASql: string): TSqliteStmt;
var
  stmt: Psqlite3_stmt;
  tail: PAnsiChar;
begin
  Check(sqlite3_prepare_v2(FDb, PAnsiChar(ASql), Length(ASql), stmt, tail),
    'prepare');
  Result := TSqliteStmt.Create(Self, stmt);
end;

procedure TSqliteDb.ExecScript(const ASql: string);
var
  stmt: Psqlite3_stmt;
  cur, tail: PAnsiChar;
  remaining, rc: Integer;
begin
  cur := PAnsiChar(ASql);
  remaining := Length(ASql);
  while remaining > 0 do
  begin
    Check(sqlite3_prepare_v2(FDb, cur, remaining, stmt, tail), 'prepare');
    if stmt <> nil then
    begin
      repeat
        rc := sqlite3_step(stmt);
      until rc <> SQLITE_ROW;
      sqlite3_finalize(stmt);
      if rc <> SQLITE_DONE then
        Check(rc, 'exec');
    end;
    remaining := remaining - (tail - cur);
    cur := tail;
  end;
end;

function TSqliteDb.ExecScalarInt(const ASql: string): Int64;
var
  st: TSqliteStmt;
begin
  st := Prepare(ASql);
  try
    if not st.Step then
      raise ESqliteDbError.CreateRc(0, 'expected a scalar result: ' + ASql);
    Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

function TSqliteDb.ExecScalarText(const ASql: string): string;
var
  st: TSqliteStmt;
begin
  st := Prepare(ASql);
  try
    if not st.Step then
      raise ESqliteDbError.CreateRc(0, 'expected a scalar result: ' + ASql);
    Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

// Imbrication: niveau externe = vraie transaction, internes = SAVEPOINT; le
// scellage BeforeCommit ne part qu'au commit externe.
procedure TSqliteDb.BeginImmediate;
begin
  if FMutationsBlocked then
    raise ESqliteDbError.CreateRc(0, 'document locked: write refused');
  if FTxDepth = 0 then
    ExecScript('BEGIN IMMEDIATE;')
  else
    ExecScript('SAVEPOINT rsh_sp' + IntToStr(FTxDepth) + ';');
  Inc(FTxDepth);
end;

procedure TSqliteDb.Commit;
begin
  if FTxDepth <= 0 then
    Exit;
  // decrementer APRES succes seulement: sinon le Rollback de l'appelant verrait
  // zero, ne ferait rien, et la transaction SQLite restante empoisonnerait la base
  if FTxDepth = 1 then
  begin
    try
      if Assigned(FBeforeCommit) and (not FInBeforeCommit) then
      begin
        FInBeforeCommit := True;
        try
          FBeforeCommit();
        finally
          FInBeforeCommit := False;
        end;
      end;
      ExecScript('COMMIT;');
    except
      try
        ExecScript('ROLLBACK;');
      except
      end;
      FTxDepth := 0;
      raise;
    end;
    FTxDepth := 0;
  end
  else
  begin
    try
      ExecScript('RELEASE rsh_sp' + IntToStr(FTxDepth - 1) + ';');
    except
      try
        ExecScript('ROLLBACK TO rsh_sp' + IntToStr(FTxDepth - 1) + ';');
      except
      end;
      raise;   // profondeur inchangee: le Rollback de l'appelant fera le reste
    end;
    Dec(FTxDepth);
  end;
end;

procedure TSqliteDb.Rollback;
begin
  if FTxDepth <= 0 then
    Exit;
  Dec(FTxDepth);
  if FTxDepth = 0 then
    ExecScript('ROLLBACK;')
  else
    ExecScript('ROLLBACK TO rsh_sp' + IntToStr(FTxDepth) +
      '; RELEASE rsh_sp' + IntToStr(FTxDepth) + ';');
end;

function TSqliteDb.QuickCheckOk: Boolean;
begin
  try
    Result := SameText(ExecScalarText('PRAGMA quick_check(1);'), 'ok');
  except
    on ESqliteDbError do Result := False;
  end;
end;

function TSqliteDb.IntegrityCheckOk: Boolean;
begin
  try
    Result := SameText(ExecScalarText('PRAGMA integrity_check(1);'), 'ok');
  except
    on ESqliteDbError do Result := False;
  end;
end;

function TSqliteDb.GetUserVersion: Int64;
begin
  Result := ExecScalarInt('PRAGMA user_version;');
end;

procedure TSqliteDb.SetUserVersion(AValue: Int64);
begin
  ExecScript(Format('PRAGMA user_version=%d;', [AValue]));
end;

function TSqliteDb.GetApplicationId: Int64;
begin
  Result := ExecScalarInt('PRAGMA application_id;');
end;

procedure TSqliteDb.SetApplicationId(AValue: Int64);
begin
  ExecScript(Format('PRAGMA application_id=%d;', [AValue]));
end;

procedure TSqliteDb.BackupTo(ADest: TSqliteDb);
var
  bk: Psqlite3_backup;
  rc: Integer;
begin
  bk := sqlite3_backup_init(ADest.FDb, 'main', FDb, 'main');
  if bk = nil then
  begin
    // extended_errcode peut valoir 0: Check ne leverait pas, bk = nil filerait a
    // backup_step -- deref nul sans SQLITE_ENABLE_API_ARMOR. On leve TOUJOURS.
    ADest.Check(sqlite3_extended_errcode(ADest.FDb), 'backup_init');
    raise ESqliteDbError.CreateRc(0, 'SQLite [backup_init]: initialisation ' +
      'de la copie refusee');
  end;
  rc := sqlite3_backup_step(bk, -1);
  sqlite3_backup_finish(bk);
  if rc <> SQLITE_DONE then
    ADest.Check(rc, 'backup_step');
end;

end.
