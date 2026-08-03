unit uLibssh2Api;

{$mode objfpc}{$H+}

// Binding dynamique libssh2, charge par chemins absolus controles: repertoire
// applicatif puis emplacements systeme. Jamais le cwd ni PATH.

interface

uses
  SysUtils, ctypes;

const
  LIBSSH2_MIN_VERSION_NUM = $010B00;
  LIBSSH2_MIN_VERSION_STR = '1.11.0';

  LIBSSH2_ERROR_NONE = 0;
  LIBSSH2_ERROR_SOCKET_SEND = -7;
  LIBSSH2_ERROR_TIMEOUT = -9;
  LIBSSH2_ERROR_SOCKET_DISCONNECT = -13;
  LIBSSH2_ERROR_PROTO = -14;
  LIBSSH2_ERROR_AUTHENTICATION_FAILED = -18;
  LIBSSH2_ERROR_CHANNEL_CLOSED = -26;
  LIBSSH2_ERROR_SOCKET_TIMEOUT = -30;
  LIBSSH2_ERROR_EAGAIN = -37;

  LIBSSH2_SESSION_BLOCK_INBOUND = $0001;
  LIBSSH2_SESSION_BLOCK_OUTBOUND = $0002;

  LIBSSH2_HOSTKEY_HASH_SHA256 = 3;

  LIBSSH2_HOSTKEY_TYPE_UNKNOWN = 0;
  LIBSSH2_HOSTKEY_TYPE_RSA = 1;
  LIBSSH2_HOSTKEY_TYPE_DSS = 2;
  LIBSSH2_HOSTKEY_TYPE_ECDSA_256 = 3;
  LIBSSH2_HOSTKEY_TYPE_ECDSA_384 = 4;
  LIBSSH2_HOSTKEY_TYPE_ECDSA_521 = 5;
  LIBSSH2_HOSTKEY_TYPE_ED25519 = 6;

  LIBSSH2_METHOD_KEX = 0;
  LIBSSH2_METHOD_HOSTKEY = 1;
  LIBSSH2_METHOD_CRYPT_CS = 2;
  LIBSSH2_METHOD_CRYPT_SC = 3;
  LIBSSH2_METHOD_MAC_CS = 4;
  LIBSSH2_METHOD_MAC_SC = 5;

  LIBSSH2_CHANNEL_WINDOW_DEFAULT = 2 * 1024 * 1024;
  LIBSSH2_CHANNEL_PACKET_DEFAULT = 32768;

  SSH_DISCONNECT_BY_APPLICATION = 11;

  SSH_EXTENDED_DATA_STDERR = 1;
  LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE = 2;

type
  ELibssh2Error = class(Exception);

  PLIBSSH2_SESSION = Pointer;
  PLIBSSH2_CHANNEL = Pointer;
  PLIBSSH2_AGENT = Pointer;

  libssh2_socket_t = cint;
  cssize_t = PtrInt;

  // layout a l'octet pres de libssh2.h: la lib alloue, on ne fait que lire
  Plibssh2_agent_publickey = ^libssh2_agent_publickey;
  libssh2_agent_publickey = record
    magic: cuint;
    node: Pointer;
    blob: PByte;
    blob_len: csize_t;
    comment: PAnsiChar;
  end;

  Tlibssh2_init = function(flags: cint): cint; cdecl;
  Tlibssh2_exit = procedure; cdecl;
  Tlibssh2_version = function(req_version_num: cint): PAnsiChar; cdecl;

  Tlibssh2_session_init_ex = function(my_alloc, my_free, my_realloc,
    abstract_: Pointer): PLIBSSH2_SESSION; cdecl;
  Tlibssh2_session_free = function(session: PLIBSSH2_SESSION): cint; cdecl;
  Tlibssh2_session_handshake = function(session: PLIBSSH2_SESSION;
    sock: libssh2_socket_t): cint; cdecl;
  Tlibssh2_session_disconnect_ex = function(session: PLIBSSH2_SESSION;
    reason: cint; description, lang: PAnsiChar): cint; cdecl;
  Tlibssh2_session_set_blocking = procedure(session: PLIBSSH2_SESSION;
    blocking: cint); cdecl;
  Tlibssh2_session_set_timeout = procedure(session: PLIBSSH2_SESSION;
    timeout: clong); cdecl;
  Tlibssh2_session_last_errno = function(session: PLIBSSH2_SESSION): cint; cdecl;
  Tlibssh2_session_last_error = function(session: PLIBSSH2_SESSION;
    errmsg: PPAnsiChar; errmsg_len: pcint; want_buf: cint): cint; cdecl;
  Tlibssh2_session_block_directions = function(
    session: PLIBSSH2_SESSION): cint; cdecl;
  Tlibssh2_session_hostkey = function(session: PLIBSSH2_SESSION;
    len: pcsize_t; typ: pcint): PAnsiChar; cdecl;
  Tlibssh2_hostkey_hash = function(session: PLIBSSH2_SESSION;
    hash_type: cint): PAnsiChar; cdecl;
  Tlibssh2_session_method_pref = function(session: PLIBSSH2_SESSION;
    method_type: cint; prefs: PAnsiChar): cint; cdecl;
  Tlibssh2_session_methods = function(session: PLIBSSH2_SESSION;
    method_type: cint): PAnsiChar; cdecl;

  Tlibssh2_userauth_list = function(session: PLIBSSH2_SESSION;
    username: PAnsiChar; username_len: cuint): PAnsiChar; cdecl;
  Tlibssh2_userauth_authenticated = function(
    session: PLIBSSH2_SESSION): cint; cdecl;
  Tlibssh2_userauth_password_ex = function(session: PLIBSSH2_SESSION;
    username: PAnsiChar; username_len: cuint;
    password: PAnsiChar; password_len: cuint;
    passwd_change_cb: Pointer): cint; cdecl;
  Tlibssh2_userauth_publickey_frommemory = function(session: PLIBSSH2_SESSION;
    username: PAnsiChar; username_len: csize_t;
    publickeydata: PAnsiChar; publickeydata_len: csize_t;
    privatekeydata: PAnsiChar; privatekeydata_len: csize_t;
    passphrase: PAnsiChar): cint; cdecl;

  Tlibssh2_agent_init = function(session: PLIBSSH2_SESSION): PLIBSSH2_AGENT; cdecl;
  Tlibssh2_agent_connect = function(agent: PLIBSSH2_AGENT): cint; cdecl;
  Tlibssh2_agent_list_identities = function(agent: PLIBSSH2_AGENT): cint; cdecl;
  Tlibssh2_agent_get_identity = function(agent: PLIBSSH2_AGENT;
    store: PPointer; prev: Pointer): cint; cdecl;
  Tlibssh2_agent_userauth = function(agent: PLIBSSH2_AGENT;
    username: PAnsiChar; identity: Pointer): cint; cdecl;
  Tlibssh2_agent_disconnect = function(agent: PLIBSSH2_AGENT): cint; cdecl;
  Tlibssh2_agent_free = procedure(agent: PLIBSSH2_AGENT); cdecl;

  Tlibssh2_channel_open_ex = function(session: PLIBSSH2_SESSION;
    channel_type: PAnsiChar; channel_type_len: cuint;
    window_size, packet_size: cuint;
    message: PAnsiChar; message_len: cuint): PLIBSSH2_CHANNEL; cdecl;
  // port-forwarding local: en non bloquant, EAGAIN veut dire "reessayer"
  Tlibssh2_channel_direct_tcpip_ex = function(session: PLIBSSH2_SESSION;
    host: PAnsiChar; port: cint; shost: PAnsiChar; sport: cint): PLIBSSH2_CHANNEL; cdecl;
  Tlibssh2_channel_request_pty_ex = function(channel: PLIBSSH2_CHANNEL;
    term: PAnsiChar; term_len: cuint; modes: PAnsiChar; modes_len: cuint;
    width, height, width_px, height_px: cint): cint; cdecl;
  Tlibssh2_channel_request_pty_size_ex = function(channel: PLIBSSH2_CHANNEL;
    width, height, width_px, height_px: cint): cint; cdecl;
  Tlibssh2_channel_process_startup = function(channel: PLIBSSH2_CHANNEL;
    request: PAnsiChar; request_len: cuint;
    message: PAnsiChar; message_len: cuint): cint; cdecl;
  Tlibssh2_channel_read_ex = function(channel: PLIBSSH2_CHANNEL;
    stream_id: cint; buf: PAnsiChar; buflen: csize_t): cssize_t; cdecl;
  Tlibssh2_channel_write_ex = function(channel: PLIBSSH2_CHANNEL;
    stream_id: cint; buf: PAnsiChar; buflen: csize_t): cssize_t; cdecl;
  Tlibssh2_channel_handle_extended_data2 = function(channel: PLIBSSH2_CHANNEL;
    ignore_mode: cint): cint; cdecl;
  Tlibssh2_channel_send_eof = function(channel: PLIBSSH2_CHANNEL): cint; cdecl;
  Tlibssh2_channel_eof = function(channel: PLIBSSH2_CHANNEL): cint; cdecl;
  Tlibssh2_channel_close = function(channel: PLIBSSH2_CHANNEL): cint; cdecl;
  Tlibssh2_channel_free = function(channel: PLIBSSH2_CHANNEL): cint; cdecl;
  Tlibssh2_channel_get_exit_status = function(
    channel: PLIBSSH2_CHANNEL): cint; cdecl;

  Tlibssh2_keepalive_config = procedure(session: PLIBSSH2_SESSION;
    want_reply: cint; interval: cuint); cdecl;
  Tlibssh2_keepalive_send = function(session: PLIBSSH2_SESSION;
    seconds_to_next: pcint): cint; cdecl;

var
  libssh2_init: Tlibssh2_init = nil;
  libssh2_exit: Tlibssh2_exit = nil;
  libssh2_version: Tlibssh2_version = nil;
  libssh2_session_init_ex: Tlibssh2_session_init_ex = nil;
  libssh2_session_free: Tlibssh2_session_free = nil;
  libssh2_session_handshake: Tlibssh2_session_handshake = nil;
  libssh2_session_disconnect_ex: Tlibssh2_session_disconnect_ex = nil;
  libssh2_session_set_blocking: Tlibssh2_session_set_blocking = nil;
  libssh2_session_set_timeout: Tlibssh2_session_set_timeout = nil;
  libssh2_session_last_errno: Tlibssh2_session_last_errno = nil;
  libssh2_session_last_error: Tlibssh2_session_last_error = nil;
  libssh2_session_block_directions: Tlibssh2_session_block_directions = nil;
  libssh2_session_hostkey: Tlibssh2_session_hostkey = nil;
  libssh2_hostkey_hash: Tlibssh2_hostkey_hash = nil;
  libssh2_session_method_pref: Tlibssh2_session_method_pref = nil;
  libssh2_session_methods: Tlibssh2_session_methods = nil;
  libssh2_userauth_list: Tlibssh2_userauth_list = nil;
  libssh2_userauth_authenticated: Tlibssh2_userauth_authenticated = nil;
  libssh2_userauth_password_ex: Tlibssh2_userauth_password_ex = nil;
  libssh2_userauth_publickey_frommemory: Tlibssh2_userauth_publickey_frommemory = nil;
  libssh2_agent_init: Tlibssh2_agent_init = nil;
  libssh2_agent_connect: Tlibssh2_agent_connect = nil;
  libssh2_agent_list_identities: Tlibssh2_agent_list_identities = nil;
  libssh2_agent_get_identity: Tlibssh2_agent_get_identity = nil;
  libssh2_agent_userauth: Tlibssh2_agent_userauth = nil;
  libssh2_agent_disconnect: Tlibssh2_agent_disconnect = nil;
  libssh2_agent_free: Tlibssh2_agent_free = nil;
  libssh2_channel_open_ex: Tlibssh2_channel_open_ex = nil;
  libssh2_channel_direct_tcpip_ex: Tlibssh2_channel_direct_tcpip_ex = nil;
  libssh2_channel_request_pty_ex: Tlibssh2_channel_request_pty_ex = nil;
  libssh2_channel_request_pty_size_ex: Tlibssh2_channel_request_pty_size_ex = nil;
  libssh2_channel_process_startup: Tlibssh2_channel_process_startup = nil;
  libssh2_channel_read_ex: Tlibssh2_channel_read_ex = nil;
  libssh2_channel_write_ex: Tlibssh2_channel_write_ex = nil;
  libssh2_channel_handle_extended_data2: Tlibssh2_channel_handle_extended_data2 = nil;
  libssh2_channel_send_eof: Tlibssh2_channel_send_eof = nil;
  libssh2_channel_eof: Tlibssh2_channel_eof = nil;
  libssh2_channel_close: Tlibssh2_channel_close = nil;
  libssh2_channel_free: Tlibssh2_channel_free = nil;
  libssh2_channel_get_exit_status: Tlibssh2_channel_get_exit_status = nil;
  libssh2_keepalive_config: Tlibssh2_keepalive_config = nil;
  libssh2_keepalive_send: Tlibssh2_keepalive_send = nil;

// Idempotent. Leve ELibssh2Error si la lib manque, est trop ancienne ou incomplete.
procedure Libssh2EnsureLoaded;
function Libssh2IsLoaded: Boolean;
function Libssh2VersionString: string;
function Libssh2HostKeyTypeName(AType: Integer): string;

// Une cle RSA epinglee doit offrir rsa-sha2-512, rsa-sha2-256 ET ssh-rsa: meme
// cle, trois signatures. Epingler ssh-rsa seul casse contre OpenSSH >= 8.8.
function Libssh2HostKeyPref(const ATypes: array of string): string;

implementation

uses
  dynlibs;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GInitLock: TRTLCriticalSection;

function AbsCandidate(const P: string): Boolean;
begin
  {$IFDEF WINDOWS}
  // 'C:chemin' est relatif au repertoire courant du lecteur: exiger 'C:\' ou UNC
  Result := ((Length(P) >= 3) and (P[2] = ':') and
             ((P[3] = '\') or (P[3] = '/'))) or
            ((Length(P) >= 2) and (P[1] = '\') and (P[2] = '\'));
  {$ELSE}
  Result := (Length(P) >= 1) and (P[1] = '/');
  {$ENDIF}
end;

function CandidatePaths: TStringArray;
var
  exeDir: string;
begin
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  {$IFDEF DARWIN}
  Result := [
    exeDir + '../Frameworks/libssh2.1.dylib',
    exeDir + 'libssh2.1.dylib',
    '/opt/homebrew/opt/libssh2/lib/libssh2.1.dylib',
    '/opt/homebrew/lib/libssh2.1.dylib',
    '/usr/local/opt/libssh2/lib/libssh2.1.dylib',
    '/usr/local/lib/libssh2.1.dylib'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/libssh2.so.1',
    exeDir + 'libssh2.so.1',
    '/usr/lib/aarch64-linux-gnu/libssh2.so.1',
    '/usr/lib/x86_64-linux-gnu/libssh2.so.1',
    '/usr/lib64/libssh2.so.1',
    '/usr/lib/libssh2.so.1'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := [exeDir + 'libssh2.dll'];
  {$ENDIF}
end;

function MustSym(const AName: string): Pointer;
begin
  Result := GetProcAddress(GLib, AName);
  if Result = nil then
    raise ELibssh2Error.CreateFmt('libssh2: missing symbol: %s', [AName]);
end;

procedure BindSymbols;
begin
  Pointer(libssh2_init) := MustSym('libssh2_init');
  Pointer(libssh2_exit) := MustSym('libssh2_exit');
  Pointer(libssh2_version) := MustSym('libssh2_version');
  Pointer(libssh2_session_init_ex) := MustSym('libssh2_session_init_ex');
  Pointer(libssh2_session_free) := MustSym('libssh2_session_free');
  Pointer(libssh2_session_handshake) := MustSym('libssh2_session_handshake');
  Pointer(libssh2_session_disconnect_ex) :=
    MustSym('libssh2_session_disconnect_ex');
  Pointer(libssh2_session_set_blocking) :=
    MustSym('libssh2_session_set_blocking');
  Pointer(libssh2_session_set_timeout) := MustSym('libssh2_session_set_timeout');
  Pointer(libssh2_session_last_errno) := MustSym('libssh2_session_last_errno');
  Pointer(libssh2_session_last_error) := MustSym('libssh2_session_last_error');
  Pointer(libssh2_session_block_directions) :=
    MustSym('libssh2_session_block_directions');
  Pointer(libssh2_session_hostkey) := MustSym('libssh2_session_hostkey');
  Pointer(libssh2_hostkey_hash) := MustSym('libssh2_hostkey_hash');
  Pointer(libssh2_session_method_pref) := MustSym('libssh2_session_method_pref');
  Pointer(libssh2_session_methods) := MustSym('libssh2_session_methods');
  Pointer(libssh2_userauth_list) := MustSym('libssh2_userauth_list');
  Pointer(libssh2_userauth_authenticated) :=
    MustSym('libssh2_userauth_authenticated');
  Pointer(libssh2_userauth_password_ex) :=
    MustSym('libssh2_userauth_password_ex');
  Pointer(libssh2_userauth_publickey_frommemory) :=
    MustSym('libssh2_userauth_publickey_frommemory');
  Pointer(libssh2_agent_init) := MustSym('libssh2_agent_init');
  Pointer(libssh2_agent_connect) := MustSym('libssh2_agent_connect');
  Pointer(libssh2_agent_list_identities) :=
    MustSym('libssh2_agent_list_identities');
  Pointer(libssh2_agent_get_identity) := MustSym('libssh2_agent_get_identity');
  Pointer(libssh2_agent_userauth) := MustSym('libssh2_agent_userauth');
  Pointer(libssh2_agent_disconnect) := MustSym('libssh2_agent_disconnect');
  Pointer(libssh2_agent_free) := MustSym('libssh2_agent_free');
  Pointer(libssh2_channel_open_ex) := MustSym('libssh2_channel_open_ex');
  Pointer(libssh2_channel_direct_tcpip_ex) :=
    MustSym('libssh2_channel_direct_tcpip_ex');
  Pointer(libssh2_channel_request_pty_ex) :=
    MustSym('libssh2_channel_request_pty_ex');
  Pointer(libssh2_channel_request_pty_size_ex) :=
    MustSym('libssh2_channel_request_pty_size_ex');
  Pointer(libssh2_channel_process_startup) :=
    MustSym('libssh2_channel_process_startup');
  Pointer(libssh2_channel_read_ex) := MustSym('libssh2_channel_read_ex');
  Pointer(libssh2_channel_write_ex) := MustSym('libssh2_channel_write_ex');
  Pointer(libssh2_channel_handle_extended_data2) :=
    MustSym('libssh2_channel_handle_extended_data2');
  Pointer(libssh2_channel_send_eof) := MustSym('libssh2_channel_send_eof');
  Pointer(libssh2_channel_eof) := MustSym('libssh2_channel_eof');
  Pointer(libssh2_channel_close) := MustSym('libssh2_channel_close');
  Pointer(libssh2_channel_free) := MustSym('libssh2_channel_free');
  Pointer(libssh2_channel_get_exit_status) :=
    MustSym('libssh2_channel_get_exit_status');
  Pointer(libssh2_keepalive_config) := MustSym('libssh2_keepalive_config');
  Pointer(libssh2_keepalive_send) := MustSym('libssh2_keepalive_send');
end;

procedure Libssh2EnsureLoaded;
var
  p: string;
  ver: PAnsiChar;
begin
  if GReady then Exit;
  EnterCriticalSection(GInitLock);
  try
  if GReady then Exit;
  for p in CandidatePaths do
    if AbsCandidate(p) and FileExists(p) then
    begin
      GLib := LoadLibrary(p);
      if GLib <> NilHandle then Break;
    end;
  if GLib = NilHandle then
    raise ELibssh2Error.Create(
      'libssh2 not found in the expected locations');
  BindSymbols;
  // libssh2_version(n) rend NULL si la lib est plus ancienne que n
  ver := libssh2_version(LIBSSH2_MIN_VERSION_NUM);
  if ver = nil then
  begin
    UnloadLibrary(GLib);
    GLib := NilHandle;
    raise ELibssh2Error.CreateFmt('libssh2: version < %s requise',
      [LIBSSH2_MIN_VERSION_STR]);
  end;
  if libssh2_init(0) <> 0 then
  begin
    UnloadLibrary(GLib);
    GLib := NilHandle;
    raise ELibssh2Error.Create('libssh2_init failed');
  end;
  GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function Libssh2IsLoaded: Boolean;
begin
  Result := GReady;
end;

function Libssh2VersionString: string;
begin
  if not GReady then
    Result := ''
  else
    Result := string(AnsiString(libssh2_version(0)));
end;

function Libssh2HostKeyTypeName(AType: Integer): string;
begin
  case AType of
    LIBSSH2_HOSTKEY_TYPE_RSA: Result := 'ssh-rsa';
    LIBSSH2_HOSTKEY_TYPE_DSS: Result := 'ssh-dss';
    LIBSSH2_HOSTKEY_TYPE_ECDSA_256: Result := 'ecdsa-sha2-nistp256';
    LIBSSH2_HOSTKEY_TYPE_ECDSA_384: Result := 'ecdsa-sha2-nistp384';
    LIBSSH2_HOSTKEY_TYPE_ECDSA_521: Result := 'ecdsa-sha2-nistp521';
    LIBSSH2_HOSTKEY_TYPE_ED25519: Result := 'ssh-ed25519';
  else
    Result := 'unknown';
  end;
end;

function Libssh2HostKeyPref(const ATypes: array of string): string;
var
  i: Integer;

  procedure Add(const AAlg: string);
  begin
    if Pos(',' + AAlg + ',', ',' + Result + ',') > 0 then
      Exit;
    if Result <> '' then
      Result := Result + ',';
    Result := Result + AAlg;
  end;

begin
  Result := '';
  for i := 0 to High(ATypes) do
    if SameText(ATypes[i], 'ssh-rsa') or
       SameText(ATypes[i], 'rsa-sha2-256') or
       SameText(ATypes[i], 'rsa-sha2-512') then
    begin
      Add('rsa-sha2-512');
      Add('rsa-sha2-256');
      Add('ssh-rsa');
    end
    else
      Add(ATypes[i]);
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  // ni libssh2_exit ni UnloadLibrary: un thread de session peut encore tourner
  DoneCriticalSection(GInitLock);
end.
