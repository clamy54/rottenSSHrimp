unit uRshSchema;

{$mode objfpc}{$H+}

// Schema .rsh, validation stricte du texte DDL de sqlite_master,
// migrations embarquees a checksum. Nous creons ces
// fichiers: toute divergence est un tampering ou une version inconnue.

interface

uses
  SysUtils, uSqliteDb;

type
  TSchemaObjKind = (soTable, soIndex);

  TSchemaObj = record
    Kind: TSchemaObjKind;
    Name: string;
    Ddl: string;
  end;

function ExpectedSchema: specialize TArray<TSchemaObj>;
// un document v(N) se valide contre le schema v(N): le courant le declarerait falsifie
function ExpectedSchemaFor(AVersion: Integer): specialize TArray<TSchemaObj>;

procedure UpgradeSchema(ADb: TSqliteDb; AFromVersion: Integer);

// Une migration, une transaction. Expose pour la montee pas a pas: chaque
// palier scelle le content_mac avec SA version (voir TRshDocument.LoadAndUnlock).
procedure ApplyMigration(ADb: TSqliteDb; AVersion: Integer);

function MigrationDdl(AVersion: Integer): string;
// checksum BLAKE2b (hex) du script tel qu'embarque
function MigrationChecksumHex(AVersion: Integer): string;

procedure InitializeSchema(ADb: TSqliteDb);

function ValidateSchema(ADb: TSqliteDb; out AErr: string): Boolean;
function ValidateSchemaFor(ADb: TSqliteDb; AVersion: Integer;
  out AErr: string): Boolean;

// les migrations enregistrees doivent correspondre aux scripts du binaire
function VerifyMigrationLedger(ADb: TSqliteDb; out AErr: string): Boolean;

implementation

uses
  ctypes, uSodiumApi, uCryptoPolicy, uRsUtil;

const
  // Texte DDL fige: ne jamais editer apres release, creer une migration.
  DDL_DOCUMENT_META =
    'CREATE TABLE document_meta (' +
    ' key TEXT PRIMARY KEY,' +
    ' value_text TEXT,' +
    ' value_int INTEGER,' +
    ' value_blob BLOB,' +
    ' CHECK ( (value_text IS NOT NULL) + (value_int IS NOT NULL)' +
    ' + (value_blob IS NOT NULL) = 1 ))';

  DDL_NODES =
    'CREATE TABLE nodes (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' parent_uuid TEXT REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' node_type TEXT NOT NULL CHECK (node_type IN (''group'', ''connection'')),' +
    ' display_name TEXT NOT NULL,' +
    ' description TEXT NOT NULL DEFAULT '''',' +
    ' icon_id TEXT NOT NULL,' +
    ' sort_order INTEGER NOT NULL DEFAULT 0,' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL )';

  DDL_IDX_NODES =
    'CREATE INDEX idx_nodes_parent_sort' +
    ' ON nodes(parent_uuid, sort_order, display_name)';

  DDL_CREDENTIALS =
    'CREATE TABLE credentials (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' auth_type TEXT NOT NULL CHECK (' +
    ' auth_type IN (''password'', ''ssh_key'', ''ssh_agent'', ''prompt'') ),' +
    ' username TEXT NOT NULL DEFAULT '''',' +
    ' domain_name TEXT NOT NULL DEFAULT '''',' +
    ' encrypted_password_id TEXT,' +
    ' encrypted_key_id TEXT,' +
    ' encrypted_key_pass_id TEXT,' +
    ' key_path_hint TEXT NOT NULL DEFAULT '''',' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL )';

  // v9: + `managed`; 1 = partage, survit sans reference; 0 = purge si orphelin
  DDL_CREDENTIALS_V9 =
    'CREATE TABLE credentials (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' auth_type TEXT NOT NULL CHECK (' +
    ' auth_type IN (''password'', ''ssh_key'', ''ssh_agent'', ''prompt'') ),' +
    ' username TEXT NOT NULL DEFAULT '''',' +
    ' domain_name TEXT NOT NULL DEFAULT '''',' +
    ' encrypted_password_id TEXT,' +
    ' encrypted_key_id TEXT,' +
    ' encrypted_key_pass_id TEXT,' +
    ' key_path_hint TEXT NOT NULL DEFAULT '''',' +
    ' managed INTEGER NOT NULL DEFAULT 0,' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL )';

  // v10: + ''managed_key'' et `public_key` en clair (deja sous enveloppe)
  DDL_CREDENTIALS_V10 =
    'CREATE TABLE credentials (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' auth_type TEXT NOT NULL CHECK (' +
    ' auth_type IN (''password'', ''ssh_key'', ''ssh_agent'', ''prompt'',' +
    ' ''managed_key'') ),' +
    ' username TEXT NOT NULL DEFAULT '''',' +
    ' domain_name TEXT NOT NULL DEFAULT '''',' +
    ' encrypted_password_id TEXT,' +
    ' encrypted_key_id TEXT,' +
    ' encrypted_key_pass_id TEXT,' +
    ' key_path_hint TEXT NOT NULL DEFAULT '''',' +
    ' managed INTEGER NOT NULL DEFAULT 0,' +
    ' public_key TEXT NOT NULL DEFAULT '''',' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL )';

  DDL_ENCRYPTED_VALUES =
    'CREATE TABLE encrypted_values (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' owner_uuid TEXT NOT NULL,' +
    ' field_name TEXT NOT NULL,' +
    ' crypto_version INTEGER NOT NULL,' +
    ' nonce BLOB NOT NULL,' +
    ' ciphertext BLOB NOT NULL,' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL,' +
    ' UNIQUE(owner_uuid, field_name) )';

  DDL_CONNECTIONS_V1 =
    'CREATE TABLE connections (' +
    ' node_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'')),' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),' +
    ' credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' inherit_settings INTEGER NOT NULL DEFAULT 1 CHECK (inherit_settings IN (0, 1)),' +
    ' connect_timeout_s INTEGER NOT NULL DEFAULT 15 CHECK (' +
    ' connect_timeout_s BETWEEN 1 AND 300 ))';

  DDL_CONNECTIONS_V2 =
    'CREATE TABLE connections (' +
    ' node_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'', ''vnc'')),' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),' +
    ' credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' inherit_settings INTEGER NOT NULL DEFAULT 1 CHECK (inherit_settings IN (0, 1)),' +
    ' connect_timeout_s INTEGER NOT NULL DEFAULT 15 CHECK (' +
    ' connect_timeout_s BETWEEN 1 AND 300 ))';

  // v4: + inherit_credential (resolution en remontant les dossiers)
  DDL_CONNECTIONS =
    'CREATE TABLE connections (' +
    ' node_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'', ''vnc'')),' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),' +
    ' credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' inherit_settings INTEGER NOT NULL DEFAULT 1 CHECK (inherit_settings IN (0, 1)),' +
    ' connect_timeout_s INTEGER NOT NULL DEFAULT 15 CHECK (' +
    ' connect_timeout_s BETWEEN 1 AND 300 ),' +
    ' inherit_credential INTEGER NOT NULL DEFAULT 0 CHECK (' +
    ' inherit_credential IN (0, 1) ))';

  DDL_FOLDER_CREDENTIALS =
    'CREATE TABLE folder_credentials (' +
    ' folder_uuid TEXT NOT NULL REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'', ''vnc'')),' +
    ' credential_uuid TEXT NOT NULL REFERENCES credentials(uuid) ON DELETE CASCADE,' +
    ' PRIMARY KEY (folder_uuid, protocol) )';

  // v5 (, jump host): un cycle se refuse a la resolution, pas ici
  DDL_CONNECTION_JUMP =
    'CREATE TABLE connection_jump (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' jump_via_uuid TEXT NOT NULL REFERENCES nodes(uuid) ON DELETE CASCADE )';

  // v6: presence = "proposer dans Connect via". PIEGE: connections(node_uuid)
  // porte 9 FK entrantes; une reconstruction recopie TOUT, node_uuid preserve.
  DDL_JUMP_HOST_OFFERS =
    'CREATE TABLE jump_host_offers (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE )';

  DDL_CONNECTIONS_V7 =
    'CREATE TABLE connections (' +
    ' node_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'', ''vnc'', ''container'')),' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),' +
    ' credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' inherit_settings INTEGER NOT NULL DEFAULT 1 CHECK (inherit_settings IN (0, 1)),' +
    ' connect_timeout_s INTEGER NOT NULL DEFAULT 15 CHECK (' +
    ' connect_timeout_s BETWEEN 1 AND 300 ),' +
    ' inherit_credential INTEGER NOT NULL DEFAULT 0 CHECK (' +
    ' inherit_credential IN (0, 1) ))';

  // v7: session SSH du parent + commande forcee; hostname/port placeholders
  DDL_CONNECTION_CONTAINER =
    'CREATE TABLE connection_container (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' parent_uuid TEXT NOT NULL REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' engine TEXT NOT NULL CHECK (engine IN (''docker'', ''podman'')),' +
    ' container_name TEXT NOT NULL,' +
    ' shell_mode TEXT NOT NULL CHECK (shell_mode IN (''sh'', ''bash'', ''log'')) )';

  DDL_CONNECTIONS_V8 =
    'CREATE TABLE connections (' +
    ' node_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' protocol TEXT NOT NULL CHECK (protocol IN (''ssh'', ''rdp'', ''vnc'', ''container'', ''pod'')),' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),' +
    ' credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' inherit_settings INTEGER NOT NULL DEFAULT 1 CHECK (inherit_settings IN (0, 1)),' +
    ' connect_timeout_s INTEGER NOT NULL DEFAULT 15 CHECK (' +
    ' connect_timeout_s BETWEEN 1 AND 300 ),' +
    ' inherit_credential INTEGER NOT NULL DEFAULT 0 CHECK (' +
    ' inherit_credential IN (0, 1) ))';

  // v8: conteneur via kubectl; namespace/container vides = defauts
  DDL_CONNECTION_POD =
    'CREATE TABLE connection_pod (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' parent_uuid TEXT NOT NULL REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' namespace TEXT NOT NULL DEFAULT '''',' +
    ' pod_name TEXT NOT NULL,' +
    ' container_name TEXT NOT NULL DEFAULT '''',' +
    ' shell_mode TEXT NOT NULL CHECK (shell_mode IN (''sh'', ''bash'', ''log'')) )';

  // FIGE: inerte depuis 0007, supprimee par la migration 4; ne sert qu'aux v1-v3.
  DDL_GROUP_DEFAULTS =
    'CREATE TABLE group_defaults (' +
    ' group_uuid TEXT PRIMARY KEY REFERENCES nodes(uuid) ON DELETE CASCADE,' +
    ' default_credential_uuid TEXT REFERENCES credentials(uuid) ON DELETE SET NULL,' +
    ' default_ssh_profile_uuid TEXT,' +
    ' default_rdp_profile_uuid TEXT )';

  DDL_SSH_PROFILES =
    'CREATE TABLE ssh_profiles (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' terminal_type TEXT NOT NULL DEFAULT ''xterm-256color'',' +
    ' encoding_name TEXT NOT NULL DEFAULT ''UTF-8'',' +
    ' keepalive_interval_s INTEGER NOT NULL DEFAULT 30,' +
    ' keepalive_max_failures INTEGER NOT NULL DEFAULT 3,' +
    ' request_compression INTEGER NOT NULL DEFAULT 0,' +
    ' use_agent INTEGER NOT NULL DEFAULT 0,' +
    ' agent_forwarding INTEGER NOT NULL DEFAULT 0,' +
    ' strict_host_key_checking INTEGER NOT NULL DEFAULT 1,' +
    ' legacy_algorithms INTEGER NOT NULL DEFAULT 0 )';

  DDL_SSH_CONNECTION_SETTINGS =
    'CREATE TABLE ssh_connection_settings (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' profile_uuid TEXT REFERENCES ssh_profiles(uuid) ON DELETE SET NULL,' +
    ' jump_connection_uuid TEXT REFERENCES connections(node_uuid) ON DELETE SET NULL,' +
    ' startup_command TEXT NOT NULL DEFAULT '''' )';

  DDL_SSH_KNOWN_HOSTS =
    'CREATE TABLE ssh_known_hosts (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL,' +
    ' key_type TEXT NOT NULL,' +
    ' fingerprint_sha256 TEXT NOT NULL,' +
    ' public_key_blob BLOB,' +
    ' first_seen_ms INTEGER NOT NULL,' +
    ' last_seen_ms INTEGER NOT NULL,' +
    ' UNIQUE(hostname, port, key_type) )';

  DDL_RDP_PROFILES =
    'CREATE TABLE rdp_profiles (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' color_depth INTEGER NOT NULL DEFAULT 32,' +
    ' dynamic_resolution INTEGER NOT NULL DEFAULT 1,' +
    ' clipboard_text_enabled INTEGER NOT NULL DEFAULT 1,' +
    ' audio_mode TEXT NOT NULL DEFAULT ''off''' +
    ' CHECK (audio_mode IN (''off'', ''local'', ''remote'')),' +
    ' verify_certificate INTEGER NOT NULL DEFAULT 1,' +
    ' nla_enabled INTEGER NOT NULL DEFAULT 1,' +
    ' auto_reconnect INTEGER NOT NULL DEFAULT 1,' +
    ' max_reconnect_attempts INTEGER NOT NULL DEFAULT 3 )';

  DDL_RDP_CONNECTION_SETTINGS =
    'CREATE TABLE rdp_connection_settings (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' profile_uuid TEXT REFERENCES rdp_profiles(uuid) ON DELETE SET NULL,' +
    ' desktop_width INTEGER,' +
    ' desktop_height INTEGER,' +
    ' gateway_hostname TEXT NOT NULL DEFAULT '''',' +
    ' gateway_port INTEGER )';

  DDL_VNC_PROFILES =
    'CREATE TABLE vnc_profiles (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' compress_level INTEGER NOT NULL DEFAULT 3 CHECK (' +
    ' compress_level BETWEEN 0 AND 9),' +
    ' quality_level INTEGER NOT NULL DEFAULT 5 CHECK (' +
    ' quality_level BETWEEN 0 AND 9),' +
    ' view_only INTEGER NOT NULL DEFAULT 0 CHECK (view_only IN (0, 1)),' +
    ' shared_session INTEGER NOT NULL DEFAULT 1 CHECK (shared_session IN (0, 1)),' +
    ' clipboard_text_enabled INTEGER NOT NULL DEFAULT 1 CHECK (' +
    ' clipboard_text_enabled IN (0, 1)),' +
    ' auto_reconnect INTEGER NOT NULL DEFAULT 1 CHECK (auto_reconnect IN (0, 1)),' +
    ' max_reconnect_attempts INTEGER NOT NULL DEFAULT 3 )';

  DDL_VNC_CONNECTION_SETTINGS_V2 =
    'CREATE TABLE vnc_connection_settings (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' profile_uuid TEXT REFERENCES vnc_profiles(uuid) ON DELETE SET NULL )';

  // v3: + view_actual_size. Pas d'ALTER ADD COLUMN: SQLite reecrirait le DDL stocke
  DDL_VNC_CONNECTION_SETTINGS =
    'CREATE TABLE vnc_connection_settings (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' profile_uuid TEXT REFERENCES vnc_profiles(uuid) ON DELETE SET NULL,' +
    ' view_actual_size INTEGER NOT NULL DEFAULT 0 CHECK (view_actual_size IN (0, 1)) )';

  DDL_DOCUMENT_SETTINGS =
    'CREATE TABLE document_settings (' +
    ' key TEXT PRIMARY KEY,' +
    ' value_json TEXT NOT NULL )';

  DDL_RECENT_SESSIONS =
    'CREATE TABLE recent_sessions (' +
    ' connection_uuid TEXT PRIMARY KEY REFERENCES connections(node_uuid) ON DELETE CASCADE,' +
    ' last_connected_ms INTEGER NOT NULL,' +
    ' last_result TEXT NOT NULL )';

  DDL_SCHEMA_MIGRATIONS =
    'CREATE TABLE schema_migrations (' +
    ' version INTEGER PRIMARY KEY,' +
    ' applied_at_ms INTEGER NOT NULL,' +
    ' checksum TEXT NOT NULL )';

function Obj(AKind: TSchemaObjKind; const AName, ADdl: string): TSchemaObj;
begin
  Result.Kind := AKind;
  Result.Name := AName;
  Result.Ddl := ADdl;
end;

// v1 publie, FIGE: ne sert qu'a rejouer la migration 1 pour son checksum.
function SchemaObjectsV1: specialize TArray<TSchemaObj>;
begin
  Result := [
    Obj(soTable, 'document_meta', DDL_DOCUMENT_META),
    Obj(soTable, 'nodes', DDL_NODES),
    Obj(soIndex, 'idx_nodes_parent_sort', DDL_IDX_NODES),
    Obj(soTable, 'credentials', DDL_CREDENTIALS),
    Obj(soTable, 'encrypted_values', DDL_ENCRYPTED_VALUES),
    Obj(soTable, 'connections', DDL_CONNECTIONS_V1),
    Obj(soTable, 'group_defaults', DDL_GROUP_DEFAULTS),
    Obj(soTable, 'ssh_profiles', DDL_SSH_PROFILES),
    Obj(soTable, 'ssh_connection_settings', DDL_SSH_CONNECTION_SETTINGS),
    Obj(soTable, 'ssh_known_hosts', DDL_SSH_KNOWN_HOSTS),
    Obj(soTable, 'rdp_profiles', DDL_RDP_PROFILES),
    Obj(soTable, 'rdp_connection_settings', DDL_RDP_CONNECTION_SETTINGS),
    Obj(soTable, 'document_settings', DDL_DOCUMENT_SETTINGS),
    Obj(soTable, 'recent_sessions', DDL_RECENT_SESSIONS),
    Obj(soTable, 'schema_migrations', DDL_SCHEMA_MIGRATIONS)
  ];
end;

function SchemaObjectsV3: specialize TArray<TSchemaObj>;
begin
  Result := [
    Obj(soTable, 'document_meta', DDL_DOCUMENT_META),
    Obj(soTable, 'nodes', DDL_NODES),
    Obj(soIndex, 'idx_nodes_parent_sort', DDL_IDX_NODES),
    Obj(soTable, 'credentials', DDL_CREDENTIALS),
    Obj(soTable, 'encrypted_values', DDL_ENCRYPTED_VALUES),
    Obj(soTable, 'connections', DDL_CONNECTIONS_V2),
    Obj(soTable, 'group_defaults', DDL_GROUP_DEFAULTS),
    Obj(soTable, 'ssh_profiles', DDL_SSH_PROFILES),
    Obj(soTable, 'ssh_connection_settings', DDL_SSH_CONNECTION_SETTINGS),
    Obj(soTable, 'ssh_known_hosts', DDL_SSH_KNOWN_HOSTS),
    Obj(soTable, 'rdp_profiles', DDL_RDP_PROFILES),
    Obj(soTable, 'rdp_connection_settings', DDL_RDP_CONNECTION_SETTINGS),
    Obj(soTable, 'vnc_profiles', DDL_VNC_PROFILES),
    Obj(soTable, 'vnc_connection_settings', DDL_VNC_CONNECTION_SETTINGS),
    Obj(soTable, 'document_settings', DDL_DOCUMENT_SETTINGS),
    Obj(soTable, 'recent_sessions', DDL_RECENT_SESSIONS),
    Obj(soTable, 'schema_migrations', DDL_SCHEMA_MIGRATIONS)
  ];
end;

function SchemaObjectsV2: specialize TArray<TSchemaObj>;
var
  i: Integer;
begin
  Result := SchemaObjectsV3;
  for i := 0 to High(Result) do
    if Result[i].Name = 'vnc_connection_settings' then
      Result[i].Ddl := DDL_VNC_CONNECTION_SETTINGS_V2;
end;

function SchemaObjectsV4: specialize TArray<TSchemaObj>;
begin
  Result := [
    Obj(soTable, 'document_meta', DDL_DOCUMENT_META),
    Obj(soTable, 'nodes', DDL_NODES),
    Obj(soIndex, 'idx_nodes_parent_sort', DDL_IDX_NODES),
    Obj(soTable, 'credentials', DDL_CREDENTIALS),
    Obj(soTable, 'encrypted_values', DDL_ENCRYPTED_VALUES),
    Obj(soTable, 'connections', DDL_CONNECTIONS),
    Obj(soTable, 'folder_credentials', DDL_FOLDER_CREDENTIALS),
    Obj(soTable, 'ssh_profiles', DDL_SSH_PROFILES),
    Obj(soTable, 'ssh_connection_settings', DDL_SSH_CONNECTION_SETTINGS),
    Obj(soTable, 'ssh_known_hosts', DDL_SSH_KNOWN_HOSTS),
    Obj(soTable, 'rdp_profiles', DDL_RDP_PROFILES),
    Obj(soTable, 'rdp_connection_settings', DDL_RDP_CONNECTION_SETTINGS),
    Obj(soTable, 'vnc_profiles', DDL_VNC_PROFILES),
    Obj(soTable, 'vnc_connection_settings', DDL_VNC_CONNECTION_SETTINGS),
    Obj(soTable, 'document_settings', DDL_DOCUMENT_SETTINGS),
    Obj(soTable, 'recent_sessions', DDL_RECENT_SESSIONS),
    Obj(soTable, 'schema_migrations', DDL_SCHEMA_MIGRATIONS)
  ];
end;

function SchemaObjectsV5: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV4;
  SetLength(Result, Length(base) + 1);
  for i := 0 to High(base) do
    Result[i] := base[i];
  Result[High(Result)] := Obj(soTable, 'connection_jump', DDL_CONNECTION_JUMP);
end;

function SchemaObjectsV6: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV5;
  SetLength(Result, Length(base) + 1);
  for i := 0 to High(base) do
    Result[i] := base[i];
  Result[High(Result)] :=
    Obj(soTable, 'jump_host_offers', DDL_JUMP_HOST_OFFERS);
end;

function SchemaObjectsV7: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV6;
  SetLength(Result, Length(base) + 1);
  for i := 0 to High(base) do
  begin
    Result[i] := base[i];
    if Result[i].Name = 'connections' then
      Result[i].Ddl := DDL_CONNECTIONS_V7;
  end;
  Result[High(Result)] :=
    Obj(soTable, 'connection_container', DDL_CONNECTION_CONTAINER);
end;

function SchemaObjectsV8: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV7;
  SetLength(Result, Length(base) + 1);
  for i := 0 to High(base) do
  begin
    Result[i] := base[i];
    if Result[i].Name = 'connections' then
      Result[i].Ddl := DDL_CONNECTIONS_V8;
  end;
  Result[High(Result)] :=
    Obj(soTable, 'connection_pod', DDL_CONNECTION_POD);
end;

function SchemaObjectsV9: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV8;
  SetLength(Result, Length(base));
  for i := 0 to High(base) do
  begin
    Result[i] := base[i];
    if Result[i].Name = 'credentials' then
      Result[i].Ddl := DDL_CREDENTIALS_V9;
  end;
end;

function ExpectedSchemaFor(AVersion: Integer): specialize TArray<TSchemaObj>;
begin
  case AVersion of
    1: Result := SchemaObjectsV1;
    2: Result := SchemaObjectsV2;
    3: Result := SchemaObjectsV3;
    4: Result := SchemaObjectsV4;
    5: Result := SchemaObjectsV5;
    6: Result := SchemaObjectsV6;
    7: Result := SchemaObjectsV7;
    8: Result := SchemaObjectsV8;
    9: Result := SchemaObjectsV9;
    10: Result := ExpectedSchema;
  else
    raise Exception.CreateFmt('unknown schema version: %d', [AVersion]);
  end;
end;

function ExpectedSchema: specialize TArray<TSchemaObj>;
var
  base: specialize TArray<TSchemaObj>;
  i: Integer;
begin
  base := SchemaObjectsV9;
  SetLength(Result, Length(base));
  for i := 0 to High(base) do
  begin
    Result[i] := base[i];
    if Result[i].Name = 'credentials' then
      Result[i].Ddl := DDL_CREDENTIALS_V10;
  end;
end;

// Listes FIGEES (entrent dans le texte des migrations, couvert par checksum).
// Recopie par liste explicite, jamais SELECT *; colonne absente = son DEFAULT.
const
  CONNECTIONS_COLUMNS =
    'node_uuid, protocol, hostname, port, credential_uuid,' +
    ' inherit_settings, connect_timeout_s';

  CONNECTIONS_COLUMNS_V4 = CONNECTIONS_COLUMNS + ', inherit_credential';

  CREDENTIALS_COLUMNS =
    'uuid, display_name, auth_type, username, domain_name,' +
    ' encrypted_password_id, encrypted_key_id, encrypted_key_pass_id,' +
    ' key_path_hint, created_at_ms, updated_at_ms';

  CREDENTIALS_COLUMNS_V9 =
    'uuid, display_name, auth_type, username, domain_name,' +
    ' encrypted_password_id, encrypted_key_id, encrypted_key_pass_id,' +
    ' key_path_hint, managed, created_at_ms, updated_at_ms';

// Un CHECK ne s'altere pas: reconstruction. Pas de RENAME -- SQLite reecrirait
// le DDL stocke, que ValidateSchema compare au texte.
function MigrationDdl2: string;
begin
  Result :=
    'CREATE TABLE connections_mig2 (' +
    ' node_uuid TEXT PRIMARY KEY,' +
    ' protocol TEXT NOT NULL,' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL,' +
    ' credential_uuid TEXT,' +
    ' inherit_settings INTEGER NOT NULL,' +
    ' connect_timeout_s INTEGER NOT NULL );' +
    'INSERT INTO connections_mig2 (' + CONNECTIONS_COLUMNS + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS + ' FROM connections;' +
    'DROP TABLE connections;' +
    DDL_CONNECTIONS_V2 + ';' +
    'INSERT INTO connections (' + CONNECTIONS_COLUMNS + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS + ' FROM connections_mig2;' +
    'DROP TABLE connections_mig2;' +
    DDL_VNC_PROFILES + ';' +
    DDL_VNC_CONNECTION_SETTINGS_V2 + ';';
end;

function MigrationDdl3: string;
begin
  Result :=
    'CREATE TABLE vnc_settings_mig3 (' +
    ' connection_uuid TEXT PRIMARY KEY,' +
    ' profile_uuid TEXT );' +
    'INSERT INTO vnc_settings_mig3 (connection_uuid, profile_uuid)' +
    ' SELECT connection_uuid, profile_uuid FROM vnc_connection_settings;' +
    'DROP TABLE vnc_connection_settings;' +
    DDL_VNC_CONNECTION_SETTINGS + ';' +
    'INSERT INTO vnc_connection_settings (connection_uuid, profile_uuid)' +
    ' SELECT connection_uuid, profile_uuid FROM vnc_settings_mig3;' +
    'DROP TABLE vnc_settings_mig3;';
end;

function MigrationDdl4: string;
begin
  Result :=
    'CREATE TABLE connections_mig4 (' +
    ' node_uuid TEXT PRIMARY KEY,' +
    ' protocol TEXT NOT NULL,' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL,' +
    ' credential_uuid TEXT,' +
    ' inherit_settings INTEGER NOT NULL,' +
    ' connect_timeout_s INTEGER NOT NULL );' +
    'INSERT INTO connections_mig4 (' + CONNECTIONS_COLUMNS + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS + ' FROM connections;' +
    'DROP TABLE connections;' +
    DDL_CONNECTIONS + ';' +
    'INSERT INTO connections (' + CONNECTIONS_COLUMNS + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS + ' FROM connections_mig4;' +
    'DROP TABLE connections_mig4;' +
    'DROP TABLE group_defaults;' +
    DDL_FOLDER_CREDENTIALS + ';';
end;

function MigrationDdl5: string;
begin
  Result := DDL_CONNECTION_JUMP + ';';
end;

// amorce avec les rebonds deja en service, sinon ils sortiraient de Connect via
function MigrationDdl6: string;
begin
  Result := DDL_JUMP_HOST_OFFERS + ';' +
    'INSERT OR IGNORE INTO jump_host_offers (connection_uuid)' +
    ' SELECT DISTINCT jump_via_uuid FROM connection_jump' +
    ' WHERE jump_via_uuid IN (SELECT node_uuid FROM connections);';
end;

function MigrationDdl7: string;
begin
  Result :=
    'CREATE TABLE connections_mig7 (' +
    ' node_uuid TEXT PRIMARY KEY,' +
    ' protocol TEXT NOT NULL,' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL,' +
    ' credential_uuid TEXT,' +
    ' inherit_settings INTEGER NOT NULL,' +
    ' connect_timeout_s INTEGER NOT NULL,' +
    ' inherit_credential INTEGER NOT NULL );' +
    'INSERT INTO connections_mig7 (' + CONNECTIONS_COLUMNS_V4 + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS_V4 + ' FROM connections;' +
    'DROP TABLE connections;' +
    DDL_CONNECTIONS_V7 + ';' +
    'INSERT INTO connections (' + CONNECTIONS_COLUMNS_V4 + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS_V4 + ' FROM connections_mig7;' +
    'DROP TABLE connections_mig7;' +
    DDL_CONNECTION_CONTAINER + ';';
end;

function MigrationDdl8: string;
begin
  Result :=
    'CREATE TABLE connections_mig8 (' +
    ' node_uuid TEXT PRIMARY KEY,' +
    ' protocol TEXT NOT NULL,' +
    ' hostname TEXT NOT NULL,' +
    ' port INTEGER NOT NULL,' +
    ' credential_uuid TEXT,' +
    ' inherit_settings INTEGER NOT NULL,' +
    ' connect_timeout_s INTEGER NOT NULL,' +
    ' inherit_credential INTEGER NOT NULL );' +
    'INSERT INTO connections_mig8 (' + CONNECTIONS_COLUMNS_V4 + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS_V4 + ' FROM connections;' +
    'DROP TABLE connections;' +
    DDL_CONNECTIONS_V8 + ';' +
    'INSERT INTO connections (' + CONNECTIONS_COLUMNS_V4 + ')' +
    ' SELECT ' + CONNECTIONS_COLUMNS_V4 + ' FROM connections_mig8;' +
    'DROP TABLE connections_mig8;' +
    DDL_CONNECTION_POD + ';';
end;

function MigrationDdl9: string;
begin
  Result :=
    'CREATE TABLE credentials_mig9 (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' auth_type TEXT NOT NULL,' +
    ' username TEXT NOT NULL DEFAULT '''',' +
    ' domain_name TEXT NOT NULL DEFAULT '''',' +
    ' encrypted_password_id TEXT,' +
    ' encrypted_key_id TEXT,' +
    ' encrypted_key_pass_id TEXT,' +
    ' key_path_hint TEXT NOT NULL DEFAULT '''',' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL );' +
    'INSERT INTO credentials_mig9 (' + CREDENTIALS_COLUMNS + ')' +
    ' SELECT ' + CREDENTIALS_COLUMNS + ' FROM credentials;' +
    'DROP TABLE credentials;' +
    DDL_CREDENTIALS_V9 + ';' +
    'INSERT INTO credentials (' + CREDENTIALS_COLUMNS + ')' +
    ' SELECT ' + CREDENTIALS_COLUMNS + ' FROM credentials_mig9;' +
    'DROP TABLE credentials_mig9;';
end;

function MigrationDdl10: string;
begin
  Result :=
    'CREATE TABLE credentials_mig10 (' +
    ' uuid TEXT PRIMARY KEY,' +
    ' display_name TEXT NOT NULL,' +
    ' auth_type TEXT NOT NULL,' +
    ' username TEXT NOT NULL DEFAULT '''',' +
    ' domain_name TEXT NOT NULL DEFAULT '''',' +
    ' encrypted_password_id TEXT,' +
    ' encrypted_key_id TEXT,' +
    ' encrypted_key_pass_id TEXT,' +
    ' key_path_hint TEXT NOT NULL DEFAULT '''',' +
    ' managed INTEGER NOT NULL DEFAULT 0,' +
    ' created_at_ms INTEGER NOT NULL,' +
    ' updated_at_ms INTEGER NOT NULL );' +
    'INSERT INTO credentials_mig10 (' + CREDENTIALS_COLUMNS_V9 + ')' +
    ' SELECT ' + CREDENTIALS_COLUMNS_V9 + ' FROM credentials;' +
    'DROP TABLE credentials;' +
    DDL_CREDENTIALS_V10 + ';' +
    'INSERT INTO credentials (' + CREDENTIALS_COLUMNS_V9 + ')' +
    ' SELECT ' + CREDENTIALS_COLUMNS_V9 + ' FROM credentials_mig10;' +
    'DROP TABLE credentials_mig10;';
end;

function MigrationDdl(AVersion: Integer): string;
var
  o: TSchemaObj;
begin
  case AVersion of
    1:
      begin
        Result := '';
        for o in SchemaObjectsV1 do
          Result := Result + o.Ddl + ';';
      end;
    2: Result := MigrationDdl2;
    3: Result := MigrationDdl3;
    4: Result := MigrationDdl4;
    5: Result := MigrationDdl5;
    6: Result := MigrationDdl6;
    7: Result := MigrationDdl7;
    8: Result := MigrationDdl8;
    9: Result := MigrationDdl9;
    10: Result := MigrationDdl10;
  else
    raise Exception.CreateFmt('unknown migration: %d', [AVersion]);
  end;
end;

function MigrationChecksumHex(AVersion: Integer): string;
var
  ddl: string;
  h: TBytes;
begin
  SodiumEnsureLoaded;
  ddl := MigrationDdl(AVersion);
  SetLength(h, crypto_generichash_BYTES);
  if crypto_generichash(@h[0], crypto_generichash_BYTES,
      PByte(PAnsiChar(ddl)), Length(ddl), nil, 0) <> 0 then
    raise Exception.Create('crypto_generichash failed');
  Result := BytesToHex(h);
end;

procedure RecordMigration(ADb: TSqliteDb; AVersion: Integer);
var
  st: TSqliteStmt;
begin
  st := ADb.Prepare(
    'INSERT INTO schema_migrations(version, applied_at_ms, checksum)' +
    ' VALUES(?,?,?);');
  try
    st.BindInt64(1, AVersion);
    st.BindInt64(2, NowUtcMs);
    st.BindText(3, MigrationChecksumHex(AVersion));
    st.Step;
  finally
    st.Free;
  end;
end;

// FK coupees HORS transaction (dedans, PRAGMA foreign_keys est un no-op muet):
// DROP TABLE avec foreign_keys=ON cascade sur les tables filles. Verifie, pas theorique.
procedure ApplyMigration(ADb: TSqliteDb; AVersion: Integer);
var
  needsFkOff: Boolean;
begin
  needsFkOff := AVersion >= 2;   // 2 reconstruit `connections`
  if needsFkOff then
    ADb.ExecScript('PRAGMA foreign_keys=OFF;');
  try
    ADb.BeginImmediate;
    try
      ADb.ExecScript(MigrationDdl(AVersion));
      RecordMigration(ADb, AVersion);
      ADb.SetUserVersion(AVersion);
      ADb.Commit;
    except
      ADb.Rollback;
      raise;
    end;
  finally
    if needsFkOff then
      ADb.ExecScript('PRAGMA foreign_keys=ON;');
  end;
end;

procedure UpgradeSchema(ADb: TSqliteDb; AFromVersion: Integer);
var
  v: Integer;
begin
  for v := AFromVersion + 1 to RSH_SCHEMA_VERSION do
    ApplyMigration(ADb, v);
end;

procedure InitializeSchema(ADb: TSqliteDb);
var
  v: Integer;
begin
  // une base neuve rejoue tout l'historique: un seul registre, une seule verite
  ADb.BeginImmediate;
  try
    ADb.ExecScript(MigrationDdl(1));
    RecordMigration(ADb, 1);
    ADb.SetApplicationId(RSH_APPLICATION_ID);
    ADb.SetUserVersion(1);
    ADb.Commit;
  except
    ADb.Rollback;
    raise;
  end;
  for v := 2 to RSH_SCHEMA_VERSION do
    ApplyMigration(ADb, v);
end;

// espaces -> simple, sans ';' final: robuste au formatage, pas au contenu
function NormalizeSql(const S: string): string;
var
  i: Integer;
  inSpace: Boolean;
  c: Char;
begin
  Result := '';
  inSpace := False;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c in [#9, #10, #13, ' '] then
      inSpace := True
    else
    begin
      if inSpace and (Result <> '') then
        Result := Result + ' ';
      inSpace := False;
      Result := Result + c;
    end;
  end;
  while (Result <> '') and (Result[Length(Result)] = ';') do
    SetLength(Result, Length(Result) - 1);
end;

function ValidateSchema(ADb: TSqliteDb; out AErr: string): Boolean;
begin
  Result := ValidateSchemaFor(ADb, RSH_SCHEMA_VERSION, AErr);
end;

function ValidateSchemaFor(ADb: TSqliteDb; AVersion: Integer;
  out AErr: string): Boolean;
var
  st: TSqliteStmt;
  expected: specialize TArray<TSchemaObj>;
  seen: array of Boolean;
  typ, name, sql: string;
  i, found: Integer;
  isAutoIndex: Boolean;
begin
  Result := False;
  AErr := '';
  expected := ExpectedSchemaFor(AVersion);
  SetLength(seen, Length(expected));
  for i := 0 to High(seen) do
    seen[i] := False;

  st := ADb.Prepare(
    'SELECT type, name, COALESCE(sql, '''') FROM sqlite_master;');
  try
    while st.Step do
    begin
      typ := st.ColText(0);
      name := st.ColText(1);
      sql := st.ColText(2);
      if (typ <> 'table') and (typ <> 'index') then
      begin
        AErr := Format('objet interdit dans le schema: %s %s', [typ, name]);
        Exit;
      end;
      isAutoIndex := (typ = 'index') and (Pos('sqlite_autoindex_', name) = 1)
        and (sql = '');
      if isAutoIndex then
        Continue;
      found := -1;
      for i := 0 to High(expected) do
        if (expected[i].Name = name) and
           (((typ = 'table') and (expected[i].Kind = soTable)) or
            ((typ = 'index') and (expected[i].Kind = soIndex))) then
        begin
          found := i;
          Break;
        end;
      if found < 0 then
      begin
        AErr := Format('objet inattendu: %s %s', [typ, name]);
        Exit;
      end;
      if seen[found] then
      begin
        AErr := Format('objet duplique: %s', [name]);
        Exit;
      end;
      if NormalizeSql(sql) <> NormalizeSql(expected[found].Ddl) then
      begin
        AErr := Format('definition modifiee: %s', [name]);
        Exit;
      end;
      seen[found] := True;
    end;
  finally
    st.Free;
  end;

  for i := 0 to High(expected) do
    if not seen[i] then
    begin
      AErr := Format('objet manquant: %s', [expected[i].Name]);
      Exit;
    end;
  Result := True;
end;

function VerifyMigrationLedger(ADb: TSqliteDb; out AErr: string): Boolean;
var
  st: TSqliteStmt;
  ver: Int64;
  sum: string;
begin
  Result := False;
  AErr := '';
  st := ADb.Prepare(
    'SELECT version, checksum FROM schema_migrations ORDER BY version;');
  try
    while st.Step do
    begin
      ver := st.ColInt64(0);
      sum := st.ColText(1);
      if (ver < 1) or (ver > RSH_SCHEMA_VERSION) then
      begin
        AErr := Format('migration hors plage: %d', [ver]);
        Exit;
      end;
      if sum <> MigrationChecksumHex(ver) then
      begin
        AErr := Format('checksum de migration invalide: version %d', [ver]);
        Exit;
      end;
    end;
  finally
    st.Free;
  end;
  Result := True;
end;

end.
