unit uLibssh2Api;

{$mode objfpc}{$H+}

// Chemins absolus: dossier de l'appli puis systeme. JAMAIS le cwd ni PATH.

interface

uses
  SysUtils, ctypes;

const
  LIBSSH2_MIN_VERSION_NUM = $010B00;
  LIBSSH2_MIN_VERSION_STR = '1.11.0';

  LIBSSH2_ERROR_NONE = 0;
  LIBSSH2_ERROR_INVALID_MAC = -4;
  LIBSSH2_ERROR_SOCKET_SEND = -7;
  LIBSSH2_ERROR_TIMEOUT = -9;
  LIBSSH2_ERROR_DECRYPT = -12;
  LIBSSH2_ERROR_SOCKET_DISCONNECT = -13;
  LIBSSH2_ERROR_PROTO = -14;
  // cle sk illisible: backend sans cles de securite (libgcrypt)
  LIBSSH2_ERROR_FILE = -16;
  LIBSSH2_ERROR_AUTHENTICATION_FAILED = -18;
  LIBSSH2_ERROR_CHANNEL_CLOSED = -26;
  LIBSSH2_ERROR_CHANNEL_EOF_SENT = -27;
  LIBSSH2_ERROR_SOCKET_TIMEOUT = -30;
  LIBSSH2_ERROR_EAGAIN = -37;
  LIBSSH2_ERROR_SOCKET_RECV = -43;
  LIBSSH2_ERROR_BAD_SOCKET = -45;
  // le vrai code est dans libssh2_sftp_last_error
  LIBSSH2_ERROR_SFTP_PROTOCOL = -31;

  // sk-*: presence toujours posee, PIN optionnel
  LIBSSH2_SK_PRESENCE_REQUIRED = $01;
  LIBSSH2_SK_VERIFICATION_REQUIRED = $04;

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

  LIBSSH2_FXF_READ = $00000001;
  LIBSSH2_FXF_WRITE = $00000002;
  LIBSSH2_FXF_APPEND = $00000004;
  LIBSSH2_FXF_CREAT = $00000008;
  LIBSSH2_FXF_TRUNC = $00000010;
  LIBSSH2_FXF_EXCL = $00000020;

  LIBSSH2_SFTP_OPENFILE = 0;
  LIBSSH2_SFTP_OPENDIR = 1;

  // DECORATIFS: SFTP v3 les ignore et le rename echoue si la cible existe.
  // L'atomique passe par posix-rename@openssh.com.
  LIBSSH2_SFTP_RENAME_OVERWRITE = $00000001;
  LIBSSH2_SFTP_RENAME_ATOMIC = $00000002;
  LIBSSH2_SFTP_RENAME_NATIVE = $00000004;

  LIBSSH2_SFTP_STAT = 0;
  LIBSSH2_SFTP_LSTAT = 1;
  LIBSSH2_SFTP_SETSTAT = 2;

  LIBSSH2_SFTP_SYMLINK = 0;
  LIBSSH2_SFTP_READLINK = 1;
  LIBSSH2_SFTP_REALPATH = 2;

  // Bit absent = champ jamais envoye: le lire, c'est lire du vent.
  LIBSSH2_SFTP_ATTR_SIZE = $00000001;
  LIBSSH2_SFTP_ATTR_UIDGID = $00000002;
  LIBSSH2_SFTP_ATTR_PERMISSIONS = $00000004;
  LIBSSH2_SFTP_ATTR_ACMODTIME = $00000008;
  LIBSSH2_SFTP_ATTR_EXTENDED = $80000000;

  // S_IFMT, dans les bits hauts de permissions
  LIBSSH2_SFTP_S_IFMT = &0170000;
  LIBSSH2_SFTP_S_IFIFO = &0010000;
  LIBSSH2_SFTP_S_IFCHR = &0020000;
  LIBSSH2_SFTP_S_IFDIR = &0040000;
  LIBSSH2_SFTP_S_IFBLK = &0060000;
  LIBSSH2_SFTP_S_IFREG = &0100000;
  LIBSSH2_SFTP_S_IFLNK = &0120000;
  LIBSSH2_SFTP_S_IFSOCK = &0140000;

  // libssh2_sftp_last_error
  LIBSSH2_FX_OK = 0;
  LIBSSH2_FX_EOF = 1;
  LIBSSH2_FX_NO_SUCH_FILE = 2;
  LIBSSH2_FX_PERMISSION_DENIED = 3;
  LIBSSH2_FX_FAILURE = 4;
  LIBSSH2_FX_BAD_MESSAGE = 5;
  LIBSSH2_FX_NO_CONNECTION = 6;
  LIBSSH2_FX_CONNECTION_LOST = 7;
  LIBSSH2_FX_OP_UNSUPPORTED = 8;
  LIBSSH2_FX_INVALID_HANDLE = 9;
  LIBSSH2_FX_NO_SUCH_PATH = 10;
  LIBSSH2_FX_FILE_ALREADY_EXISTS = 11;
  LIBSSH2_FX_WRITE_PROTECT = 12;
  LIBSSH2_FX_NO_MEDIA = 13;
  LIBSSH2_FX_NO_SPACE_ON_FILESYSTEM = 14;
  LIBSSH2_FX_QUOTA_EXCEEDED = 15;
  LIBSSH2_FX_UNKNOWN_PRINCIPAL = 16;
  LIBSSH2_FX_LOCK_CONFLICT = 17;
  LIBSSH2_FX_DIR_NOT_EMPTY = 18;
  LIBSSH2_FX_NOT_A_DIRECTORY = 19;
  LIBSSH2_FX_INVALID_FILENAME = 20;
  LIBSSH2_FX_LINK_LOOP = 21;

  SSH_EXTENDED_DATA_STDERR = 1;
  LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE = 2;

type
  ELibssh2Error = class(Exception);

  PLIBSSH2_SESSION = Pointer;
  PLIBSSH2_CHANNEL = Pointer;
  PLIBSSH2_AGENT = Pointer;
  PLIBSSH2_SFTP = Pointer;
  PLIBSSH2_SFTP_HANDLE = Pointer;

  libssh2_socket_t = cint;
  cssize_t = PtrInt;
  libssh2_uint64_t = cuint64;
  libssh2_int64_t = cint64;

  // libssh2.h a l'octet pres; la lib alloue, on ne fait que lire
  Plibssh2_agent_publickey = ^libssh2_agent_publickey;
  libssh2_agent_publickey = record
    magic: cuint;
    node: Pointer;
    blob: PByte;
    blob_len: csize_t;
    comment: PAnsiChar;
  end;

  // Rempli par nous, libere par libssh2 avec le free() de SON runtime C:
  // sig_r/sig_s viennent du malloc C, JAMAIS de GetMem.
  PLIBSSH2_SK_SIG_INFO = ^LIBSSH2_SK_SIG_INFO;
  LIBSSH2_SK_SIG_INFO = record
    flags: cuint8;
    counter: cuint32;
    sig_r: PByte;
    sig_r_len: csize_t;
    sig_s: PByte;      // nil pour ed25519
    sig_s_len: csize_t;
  end;

  // Thread de l'auth, une fois par tentative. « data » brut, PAS hache.
  TLibssh2SkSignFunc = function(session: PLIBSSH2_SESSION;
    sig_info: PLIBSSH2_SK_SIG_INFO; data: PByte; data_len: csize_t;
    algorithm: cint; flags: cuint8; application: PAnsiChar;
    key_handle: PByte; handle_len: csize_t; abstract_: PPointer): cint; cdecl;

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

  // libssh2 lit le key handle et nous rappelle pour signer. pubkeydata: nil permis.
  Tlibssh2_userauth_publickey_sk = function(session: PLIBSSH2_SESSION;
    username: PAnsiChar; username_len: csize_t;
    pubkeydata: PByte; pubkeydata_len: csize_t;
    privatekeydata: PAnsiChar; privatekeydata_len: csize_t;
    passphrase: PAnsiChar; sign_callback: TLibssh2SkSignFunc;
    abstract_: PPointer): cint; cdecl;

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
  // non bloquant: EAGAIN = reessayer, pas echouer
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

  // unsigned long = 4 octets sous Win64 (LLP64), 8 ailleurs: culong, JAMAIS
  // cuint32. PACKRECORDS C pour le bourrage entre flags et filesize.
  {$PACKRECORDS C}
  PLIBSSH2_SFTP_ATTRIBUTES = ^LIBSSH2_SFTP_ATTRIBUTES;
  LIBSSH2_SFTP_ATTRIBUTES = record
    flags: culong;            // LIBSSH2_SFTP_ATTR_*
    filesize: libssh2_uint64_t;
    uid, gid: culong;
    permissions: culong;      // S_IFMT compris
    atime, mtime: culong;     // epoque Unix, secondes
  end;
  {$PACKRECORDS DEFAULT}

  // statvfs@openssh.com: tout en uint64, pas de piege LLP64.
  {$PACKRECORDS C}
  // Renomme: Pascal ne distingue pas la casse, le type heurterait la fonction.
  PLibssh2SftpStatVfs = ^TLibssh2SftpStatVfs;
  TLibssh2SftpStatVfs = record
    f_bsize: libssh2_uint64_t;
    f_frsize: libssh2_uint64_t;    // unite des compteurs de blocs
    f_blocks: libssh2_uint64_t;
    f_bfree: libssh2_uint64_t;
    f_bavail: libssh2_uint64_t;    // pour un non-root
    f_files: libssh2_uint64_t;
    f_ffree: libssh2_uint64_t;
    f_favail: libssh2_uint64_t;
    f_fsid: libssh2_uint64_t;
    f_flag: libssh2_uint64_t;
    f_namemax: libssh2_uint64_t;
  end;
  {$PACKRECORDS DEFAULT}

  // Extension serveur OPTIONNELLE: aucune decision de transfert n'en depend.
  Tlibssh2_sftp_statvfs = function(sftp: PLIBSSH2_SFTP;
    path: PAnsiChar; path_len: csize_t;
    st: PLibssh2SftpStatVfs): cint; cdecl;

  Tlibssh2_sftp_init = function(session: PLIBSSH2_SESSION): PLIBSSH2_SFTP; cdecl;
  Tlibssh2_sftp_shutdown = function(sftp: PLIBSSH2_SFTP): cint; cdecl;
  // Sens UNIQUEMENT apres un LIBSSH2_ERROR_SFTP_PROTOCOL.
  Tlibssh2_sftp_last_error = function(sftp: PLIBSSH2_SFTP): culong; cdecl;
  Tlibssh2_sftp_get_channel = function(
    sftp: PLIBSSH2_SFTP): PLIBSSH2_CHANNEL; cdecl;

  Tlibssh2_sftp_open_ex = function(sftp: PLIBSSH2_SFTP;
    filename: PAnsiChar; filename_len: cuint; flags: culong; mode: clong;
    open_type: cint): PLIBSSH2_SFTP_HANDLE; cdecl;
  Tlibssh2_sftp_close_handle = function(
    handle: PLIBSSH2_SFTP_HANDLE): cint; cdecl;
  // Lecture courte: NI erreur NI fin. Seul 0 est la fin.
  Tlibssh2_sftp_read = function(handle: PLIBSSH2_SFTP_HANDLE;
    buffer: PAnsiChar; buffer_maxlen: csize_t): cssize_t; cdecl;
  Tlibssh2_sftp_write = function(handle: PLIBSSH2_SFTP_HANDLE;
    buffer: PAnsiChar; count: csize_t): cssize_t; cdecl;
  Tlibssh2_sftp_seek64 = procedure(handle: PLIBSSH2_SFTP_HANDLE;
    offset: libssh2_uint64_t); cdecl;
  Tlibssh2_sftp_tell64 = function(
    handle: PLIBSSH2_SFTP_HANDLE): libssh2_uint64_t; cdecl;
  Tlibssh2_sftp_fsync = function(handle: PLIBSSH2_SFTP_HANDLE): cint; cdecl;
  // 0 = fin, negatif = erreur
  Tlibssh2_sftp_readdir_ex = function(handle: PLIBSSH2_SFTP_HANDLE;
    buffer: PAnsiChar; buffer_maxlen: csize_t;
    longentry: PAnsiChar; longentry_maxlen: csize_t;
    attrs: PLIBSSH2_SFTP_ATTRIBUTES): cint; cdecl;
  Tlibssh2_sftp_fstat_ex = function(handle: PLIBSSH2_SFTP_HANDLE;
    attrs: PLIBSSH2_SFTP_ATTRIBUTES; setstat: cint): cint; cdecl;

  Tlibssh2_sftp_stat_ex = function(sftp: PLIBSSH2_SFTP;
    path: PAnsiChar; path_len: cuint; stat_type: cint;
    attrs: PLIBSSH2_SFTP_ATTRIBUTES): cint; cdecl;
  Tlibssh2_sftp_rename_ex = function(sftp: PLIBSSH2_SFTP;
    source: PAnsiChar; source_len: cuint;
    dest: PAnsiChar; dest_len: cuint; flags: clong): cint; cdecl;
  // SEUL remplacement atomique en SFTP v3. Absent avant libssh2 1.11, et le
  // serveur peut le refuser.
  Tlibssh2_sftp_posix_rename_ex = function(sftp: PLIBSSH2_SFTP;
    source: PAnsiChar; source_len: csize_t;
    dest: PAnsiChar; dest_len: csize_t): cint; cdecl;
  Tlibssh2_sftp_unlink_ex = function(sftp: PLIBSSH2_SFTP;
    filename: PAnsiChar; filename_len: cuint): cint; cdecl;
  Tlibssh2_sftp_mkdir_ex = function(sftp: PLIBSSH2_SFTP;
    path: PAnsiChar; path_len: cuint; mode: clong): cint; cdecl;
  Tlibssh2_sftp_rmdir_ex = function(sftp: PLIBSSH2_SFTP;
    path: PAnsiChar; path_len: cuint): cint; cdecl;
  Tlibssh2_sftp_symlink_ex = function(sftp: PLIBSSH2_SFTP;
    path: PAnsiChar; path_len: cuint;
    target: PAnsiChar; target_len: cuint; link_type: cint): cint; cdecl;

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
  // OPTIONNEL: Libssh2HasSkAuth d'abord.
  libssh2_userauth_publickey_sk: Tlibssh2_userauth_publickey_sk = nil;
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

  libssh2_sftp_init: Tlibssh2_sftp_init = nil;
  libssh2_sftp_shutdown: Tlibssh2_sftp_shutdown = nil;
  libssh2_sftp_last_error: Tlibssh2_sftp_last_error = nil;
  libssh2_sftp_get_channel: Tlibssh2_sftp_get_channel = nil;
  libssh2_sftp_open_ex: Tlibssh2_sftp_open_ex = nil;
  libssh2_sftp_close_handle: Tlibssh2_sftp_close_handle = nil;
  libssh2_sftp_read: Tlibssh2_sftp_read = nil;
  libssh2_sftp_write: Tlibssh2_sftp_write = nil;
  libssh2_sftp_seek64: Tlibssh2_sftp_seek64 = nil;
  libssh2_sftp_tell64: Tlibssh2_sftp_tell64 = nil;
  libssh2_sftp_fsync: Tlibssh2_sftp_fsync = nil;
  libssh2_sftp_readdir_ex: Tlibssh2_sftp_readdir_ex = nil;
  libssh2_sftp_fstat_ex: Tlibssh2_sftp_fstat_ex = nil;
  libssh2_sftp_stat_ex: Tlibssh2_sftp_stat_ex = nil;
  libssh2_sftp_rename_ex: Tlibssh2_sftp_rename_ex = nil;
  // OPTIONNEL: Libssh2HasPosixRename d'abord.
  libssh2_sftp_posix_rename_ex: Tlibssh2_sftp_posix_rename_ex = nil;
  libssh2_sftp_unlink_ex: Tlibssh2_sftp_unlink_ex = nil;
  libssh2_sftp_mkdir_ex: Tlibssh2_sftp_mkdir_ex = nil;
  libssh2_sftp_rmdir_ex: Tlibssh2_sftp_rmdir_ex = nil;
  libssh2_sftp_symlink_ex: Tlibssh2_sftp_symlink_ex = nil;
  libssh2_sftp_statvfs: Tlibssh2_sftp_statvfs = nil;

// Idempotent. Leve si la lib manque, est trop vieille ou incomplete.
procedure Libssh2EnsureLoaded;
function Libssh2IsLoaded: Boolean;
// Backend OpenSSL seulement: libgcrypt exporte le symbole et rend
// LIBSSH2_ERROR_FILE, le mensonge par omission.
function Libssh2HasSkAuth: Boolean;
// Cote CLIENT seulement: le refus du serveur ne se decouvre qu'a l'appel.
function Libssh2HasPosixRename: Boolean;
function Libssh2VersionString: string;
function Libssh2HostKeyTypeName(AType: Integer): string;

// RSA epinglee = rsa-sha2-512, rsa-sha2-256 ET ssh-rsa. ssh-rsa seul casse
// contre OpenSSH >= 8.8.
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

// Absent: la fonctionnalite saute, pas toute la lib.
function OptSym(const AName: string): Pointer;
begin
  Result := GetProcAddress(GLib, AName);
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
  Pointer(libssh2_userauth_publickey_sk) :=
    OptSym('libssh2_userauth_publickey_sk');
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

  Pointer(libssh2_sftp_init) := MustSym('libssh2_sftp_init');
  Pointer(libssh2_sftp_shutdown) := MustSym('libssh2_sftp_shutdown');
  Pointer(libssh2_sftp_last_error) := MustSym('libssh2_sftp_last_error');
  Pointer(libssh2_sftp_get_channel) := MustSym('libssh2_sftp_get_channel');
  Pointer(libssh2_sftp_open_ex) := MustSym('libssh2_sftp_open_ex');
  Pointer(libssh2_sftp_close_handle) := MustSym('libssh2_sftp_close_handle');
  Pointer(libssh2_sftp_read) := MustSym('libssh2_sftp_read');
  Pointer(libssh2_sftp_write) := MustSym('libssh2_sftp_write');
  Pointer(libssh2_sftp_seek64) := MustSym('libssh2_sftp_seek64');
  Pointer(libssh2_sftp_tell64) := MustSym('libssh2_sftp_tell64');
  Pointer(libssh2_sftp_fsync) := MustSym('libssh2_sftp_fsync');
  Pointer(libssh2_sftp_readdir_ex) := MustSym('libssh2_sftp_readdir_ex');
  Pointer(libssh2_sftp_fstat_ex) := MustSym('libssh2_sftp_fstat_ex');
  Pointer(libssh2_sftp_stat_ex) := MustSym('libssh2_sftp_stat_ex');
  Pointer(libssh2_sftp_rename_ex) := MustSym('libssh2_sftp_rename_ex');
  Pointer(libssh2_sftp_posix_rename_ex) :=
    OptSym('libssh2_sftp_posix_rename_ex');
  Pointer(libssh2_sftp_unlink_ex) := MustSym('libssh2_sftp_unlink_ex');
  Pointer(libssh2_sftp_mkdir_ex) := MustSym('libssh2_sftp_mkdir_ex');
  Pointer(libssh2_sftp_rmdir_ex) := MustSym('libssh2_sftp_rmdir_ex');
  Pointer(libssh2_sftp_symlink_ex) := MustSym('libssh2_sftp_symlink_ex');
  Pointer(libssh2_sftp_statvfs) := OptSym('libssh2_sftp_statvfs');
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
  // NULL si la lib est plus ancienne que n
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

function Libssh2HasSkAuth: Boolean;
begin
  Result := GReady and Assigned(libssh2_userauth_publickey_sk);
end;

function Libssh2HasPosixRename: Boolean;
begin
  Result := GReady and Assigned(libssh2_sftp_posix_rename_ex);
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
