unit uFido2Api;

{$mode objfpc}{$H+}

// Binding dynamique libfido2 (cles de securite FIDO2/CTAP), charge par chemins
// absolus controles: repertoire applicatif puis emplacements systeme. Jamais le
// cwd ni PATH, comme les autres bindings.
//
// A LA DIFFERENCE des autres, celui-ci ne LEVE JAMAIS: la fonctionnalite est
// optionnelle. Une application sans libfido2 doit demarrer, ouvrir ses
// documents et ouvrir toutes ses sessions -- seuls les identifiants FIDO2 sont
// indisponibles, avec un message qui dit quoi installer. Fido2TryLoad rend
// False et Fido2LoadError explique; le modele est celui du shim RDP
// (bindings/freerdp/uFreeRdpApi.pas): toute anomalie desactive la lib EN
// ENTIER, jamais une lib a moitie liee.

interface

uses
  SysUtils, ctypes;

const
  // fido/err.h. Les negatifs sont internes a libfido2, les positifs viennent
  // du CTAP. USER_PRESENCE_REQUIRED (-8) n'est pas un echec pour nous: c'est la
  // reponse d'un token qui DETIENT la cle mais attend le doigt, donc le signe
  // qu'on a trouve le bon token (cf. uSshFido.SelectDeviceFor).
  FIDO_OK = $00;
  FIDO_ERR_INVALID_PARAMETER = $02;
  FIDO_ERR_INVALID_LENGTH = $03;
  FIDO_ERR_TIMEOUT = $05;
  FIDO_ERR_CHANNEL_BUSY = $06;
  FIDO_ERR_INVALID_CBOR = $12;
  FIDO_ERR_MISSING_PARAMETER = $14;
  FIDO_ERR_UNSUPPORTED_EXTENSION = $16;
  FIDO_ERR_CREDENTIAL_EXCLUDED = $19;
  FIDO_ERR_PROCESSING = $21;
  FIDO_ERR_INVALID_CREDENTIAL = $22;
  FIDO_ERR_USER_ACTION_PENDING = $23;
  FIDO_ERR_OPERATION_PENDING = $24;
  FIDO_ERR_NO_OPERATIONS = $25;
  FIDO_ERR_UNSUPPORTED_ALGORITHM = $26;
  FIDO_ERR_OPERATION_DENIED = $27;
  FIDO_ERR_KEY_STORE_FULL = $28;
  FIDO_ERR_UNSUPPORTED_OPTION = $2B;
  FIDO_ERR_INVALID_OPTION = $2C;
  FIDO_ERR_KEEPALIVE_CANCEL = $2D;
  FIDO_ERR_NO_CREDENTIALS = $2E;
  FIDO_ERR_USER_ACTION_TIMEOUT = $2F;
  FIDO_ERR_NOT_ALLOWED = $30;
  FIDO_ERR_PIN_INVALID = $31;
  FIDO_ERR_PIN_BLOCKED = $32;
  FIDO_ERR_PIN_AUTH_INVALID = $33;
  FIDO_ERR_PIN_AUTH_BLOCKED = $34;
  FIDO_ERR_PIN_NOT_SET = $35;
  FIDO_ERR_PIN_REQUIRED = $36;
  FIDO_ERR_PIN_POLICY_VIOLATION = $37;
  FIDO_ERR_PIN_TOKEN_EXPIRED = $38;
  FIDO_ERR_REQUEST_TOO_LARGE = $39;
  FIDO_ERR_ACTION_TIMEOUT = $3A;
  FIDO_ERR_UP_REQUIRED = $3B;
  FIDO_ERR_UV_BLOCKED = $3C;
  FIDO_ERR_UV_INVALID = $3F;
  FIDO_ERR_UNAUTHORIZED_PERM = $40;
  FIDO_ERR_ERR_OTHER = $7F;

  FIDO_ERR_TX = -1;
  FIDO_ERR_RX = -2;
  FIDO_ERR_RX_NOT_CBOR = -3;
  FIDO_ERR_RX_INVALID_CBOR = -4;
  FIDO_ERR_INVALID_PARAM = -5;
  FIDO_ERR_INVALID_SIG = -6;
  FIDO_ERR_INVALID_ARGUMENT = -7;
  FIDO_ERR_USER_PRESENCE_REQUIRED = -8;
  FIDO_ERR_INTERNAL = -9;
  FIDO_ERR_NOTFOUND = -10;
  FIDO_ERR_COMPRESS = -11;

  // fido_opt_t (fido/types.h)
  FIDO_OPT_OMIT = 0;    // laisser le defaut de l'authentificateur
  FIDO_OPT_FALSE = 1;
  FIDO_OPT_TRUE = 2;

  // COSE, fido/param.h
  COSE_ES256 = -7;
  COSE_EDDSA = -8;

  // credProtect, pour une cle qui exige la verification utilisateur
  FIDO_CRED_PROT_UV_OPTIONAL = 1;
  FIDO_CRED_PROT_UV_OPTIONAL_WITH_ID = 2;
  FIDO_CRED_PROT_UV_REQUIRED = 3;

  // Peripherique virtuel Windows Hello: passe par l'API WebAuthn du systeme,
  // donc PAS de privileges administrateur (l'acces HID direct, lui, en exige
  // sous Windows) et c'est Windows qui affiche « touchez » et demande le PIN.
  FIDO_WINHELLO_PATH = 'windows://hello';

  FIDO_MAX_DEVICES = 16;

type
  Pfido_dev_t = Pointer;
  Pfido_dev_info_t = Pointer;
  Pfido_cred_t = Pointer;
  Pfido_assert_t = Pointer;
  Pfido_cbor_info_t = Pointer;

  Tfido_init = procedure(flags: cint); cdecl;
  Tfido_strerr = function(n: cint): PAnsiChar; cdecl;

  Tfido_dev_info_new = function(n: csize_t): Pfido_dev_info_t; cdecl;
  Tfido_dev_info_free = procedure(p: PPointer; n: csize_t); cdecl;
  Tfido_dev_info_manifest = function(l: Pfido_dev_info_t; ilen: csize_t;
    olen: pcsize_t): cint; cdecl;
  Tfido_dev_info_ptr = function(l: Pfido_dev_info_t;
    i: csize_t): Pfido_dev_info_t; cdecl;
  Tfido_dev_info_str = function(di: Pfido_dev_info_t): PAnsiChar; cdecl;

  Tfido_dev_new = function: Pfido_dev_t; cdecl;
  Tfido_dev_free = procedure(p: PPointer); cdecl;
  Tfido_dev_open = function(d: Pfido_dev_t; path: PAnsiChar): cint; cdecl;
  Tfido_dev_close = function(d: Pfido_dev_t): cint; cdecl;
  Tfido_dev_cancel = function(d: Pfido_dev_t): cint; cdecl;
  Tfido_dev_set_timeout = function(d: Pfido_dev_t; ms: cint): cint; cdecl;
  // bool C = 1 octet: ByteBool, surtout pas LongBool
  Tfido_dev_flag = function(d: Pfido_dev_t): ByteBool; cdecl;

  Tfido_cbor_info_new = function: Pfido_cbor_info_t; cdecl;
  Tfido_cbor_info_free = procedure(p: PPointer); cdecl;
  Tfido_dev_get_cbor_info = function(d: Pfido_dev_t;
    ci: Pfido_cbor_info_t): cint; cdecl;
  Tfido_cbor_info_algorithm_count = function(ci: Pfido_cbor_info_t): csize_t; cdecl;
  Tfido_cbor_info_algorithm_cose = function(ci: Pfido_cbor_info_t;
    idx: csize_t): cint; cdecl;

  Tfido_cred_new = function: Pfido_cred_t; cdecl;
  Tfido_cred_free = procedure(p: PPointer); cdecl;
  Tfido_cred_set_type = function(c: Pfido_cred_t; cose_alg: cint): cint; cdecl;
  Tfido_cred_set_clientdata = function(c: Pfido_cred_t; p: PByte;
    len: csize_t): cint; cdecl;
  Tfido_cred_set_rp = function(c: Pfido_cred_t;
    id, name: PAnsiChar): cint; cdecl;
  Tfido_cred_set_user = function(c: Pfido_cred_t; user_id: PByte;
    user_id_len: csize_t; name, display_name, icon: PAnsiChar): cint; cdecl;
  Tfido_cred_set_opt = function(c: Pfido_cred_t; opt: cint): cint; cdecl;
  Tfido_cred_set_prot = function(c: Pfido_cred_t; prot: cint): cint; cdecl;
  Tfido_cred_bytes_ptr = function(c: Pfido_cred_t): PByte; cdecl;
  Tfido_cred_bytes_len = function(c: Pfido_cred_t): csize_t; cdecl;
  Tfido_cred_type = function(c: Pfido_cred_t): cint; cdecl;
  Tfido_dev_make_cred = function(d: Pfido_dev_t; c: Pfido_cred_t;
    pin: PAnsiChar): cint; cdecl;

  Tfido_assert_new = function: Pfido_assert_t; cdecl;
  Tfido_assert_free = procedure(p: PPointer); cdecl;
  Tfido_assert_set_rp = function(a: Pfido_assert_t; id: PAnsiChar): cint; cdecl;
  Tfido_assert_set_clientdata = function(a: Pfido_assert_t; p: PByte;
    len: csize_t): cint; cdecl;
  Tfido_assert_allow_cred = function(a: Pfido_assert_t; ptr: PByte;
    len: csize_t): cint; cdecl;
  Tfido_assert_set_opt = function(a: Pfido_assert_t; opt: cint): cint; cdecl;
  Tfido_assert_count = function(a: Pfido_assert_t): csize_t; cdecl;
  Tfido_assert_idx_ptr = function(a: Pfido_assert_t; idx: csize_t): PByte; cdecl;
  Tfido_assert_idx_len = function(a: Pfido_assert_t; idx: csize_t): csize_t; cdecl;
  Tfido_assert_flags = function(a: Pfido_assert_t; idx: csize_t): cuint8; cdecl;
  Tfido_assert_sigcount = function(a: Pfido_assert_t; idx: csize_t): cuint32; cdecl;
  Tfido_dev_get_assert = function(d: Pfido_dev_t; a: Pfido_assert_t;
    pin: PAnsiChar): cint; cdecl;

var
  fido_init: Tfido_init = nil;
  fido_strerr: Tfido_strerr = nil;

  fido_dev_info_new: Tfido_dev_info_new = nil;
  fido_dev_info_free: Tfido_dev_info_free = nil;
  fido_dev_info_manifest: Tfido_dev_info_manifest = nil;
  fido_dev_info_ptr: Tfido_dev_info_ptr = nil;
  fido_dev_info_path: Tfido_dev_info_str = nil;
  fido_dev_info_manufacturer_string: Tfido_dev_info_str = nil;
  fido_dev_info_product_string: Tfido_dev_info_str = nil;

  fido_dev_new: Tfido_dev_new = nil;
  fido_dev_free: Tfido_dev_free = nil;
  fido_dev_open: Tfido_dev_open = nil;
  fido_dev_close: Tfido_dev_close = nil;
  fido_dev_cancel: Tfido_dev_cancel = nil;
  fido_dev_set_timeout: Tfido_dev_set_timeout = nil;
  fido_dev_is_fido2: Tfido_dev_flag = nil;
  fido_dev_is_winhello: Tfido_dev_flag = nil;
  fido_dev_has_pin: Tfido_dev_flag = nil;
  fido_dev_has_uv: Tfido_dev_flag = nil;

  fido_cbor_info_new: Tfido_cbor_info_new = nil;
  fido_cbor_info_free: Tfido_cbor_info_free = nil;
  fido_dev_get_cbor_info: Tfido_dev_get_cbor_info = nil;
  fido_cbor_info_algorithm_count: Tfido_cbor_info_algorithm_count = nil;
  fido_cbor_info_algorithm_cose: Tfido_cbor_info_algorithm_cose = nil;

  fido_cred_new: Tfido_cred_new = nil;
  fido_cred_free: Tfido_cred_free = nil;
  fido_cred_set_type: Tfido_cred_set_type = nil;
  fido_cred_set_clientdata: Tfido_cred_set_clientdata = nil;
  fido_cred_set_rp: Tfido_cred_set_rp = nil;
  fido_cred_set_user: Tfido_cred_set_user = nil;
  fido_cred_set_rk: Tfido_cred_set_opt = nil;
  fido_cred_set_uv: Tfido_cred_set_opt = nil;
  fido_cred_set_prot: Tfido_cred_set_prot = nil;
  fido_cred_id_ptr: Tfido_cred_bytes_ptr = nil;
  fido_cred_id_len: Tfido_cred_bytes_len = nil;
  fido_cred_pubkey_ptr: Tfido_cred_bytes_ptr = nil;
  fido_cred_pubkey_len: Tfido_cred_bytes_len = nil;
  fido_cred_type: Tfido_cred_type = nil;
  // AAGUID de l'authentificateur qui a cree la cle: dit SI la cle vit sur un
  // token amovible ou dans la machine (TPM Windows Hello).
  fido_cred_aaguid_ptr: Tfido_cred_bytes_ptr = nil;
  fido_cred_aaguid_len: Tfido_cred_bytes_len = nil;
  fido_dev_make_cred: Tfido_dev_make_cred = nil;

  fido_assert_new: Tfido_assert_new = nil;
  fido_assert_free: Tfido_assert_free = nil;
  fido_assert_set_rp: Tfido_assert_set_rp = nil;
  fido_assert_set_clientdata: Tfido_assert_set_clientdata = nil;
  fido_assert_allow_cred: Tfido_assert_allow_cred = nil;
  fido_assert_set_up: Tfido_assert_set_opt = nil;
  fido_assert_set_uv: Tfido_assert_set_opt = nil;
  fido_assert_count: Tfido_assert_count = nil;
  fido_assert_sig_ptr: Tfido_assert_idx_ptr = nil;
  fido_assert_sig_len: Tfido_assert_idx_len = nil;
  fido_assert_flags: Tfido_assert_flags = nil;
  fido_assert_sigcount: Tfido_assert_sigcount = nil;
  fido_dev_get_assert: Tfido_dev_get_assert = nil;

// Idempotent, silencieux, ne leve jamais. True = tous les symboles sont lies.
function Fido2TryLoad: Boolean;
function Fido2Available: Boolean;
// Vide tant qu'aucune tentative n'a eu lieu; sinon dit CE QUI a manque et OU on
// a cherche -- le message part tel quel dans l'interface.
function Fido2LoadError: string;
function Fido2LoadedPath: string;
// « FIDO_ERR_PIN_REQUIRED (0x36): <texte libfido2> »
function Fido2StrErr(ACode: Integer): string;

implementation

uses
  dynlibs;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GTried: Boolean = False;
  GError: string = '';
  GPath: string = '';
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
    exeDir + '../Frameworks/libfido2.1.dylib',
    exeDir + 'libfido2.1.dylib',
    '/opt/homebrew/opt/libfido2/lib/libfido2.1.dylib',
    '/opt/homebrew/lib/libfido2.1.dylib',
    '/usr/local/opt/libfido2/lib/libfido2.1.dylib',
    '/usr/local/lib/libfido2.1.dylib'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/libfido2.so.1',
    exeDir + 'libfido2.so.1',
    '/usr/lib/aarch64-linux-gnu/libfido2.so.1',
    '/usr/lib/x86_64-linux-gnu/libfido2.so.1',
    '/usr/lib64/libfido2.so.1',
    '/usr/lib/libfido2.so.1'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  // vcpkg nomme la DLL « fido2.dll » (OUTPUT_NAME fido2), pas « libfido2.dll »:
  // les deux sont essayes, l'installateur livre la premiere.
  Result := [exeDir + 'fido2.dll', exeDir + 'libfido2.dll'];
  {$ENDIF}
end;

procedure Reset;
begin
  fido_init := nil; fido_strerr := nil;
  fido_dev_info_new := nil; fido_dev_info_free := nil;
  fido_dev_info_manifest := nil; fido_dev_info_ptr := nil;
  fido_dev_info_path := nil; fido_dev_info_manufacturer_string := nil;
  fido_dev_info_product_string := nil;
  fido_dev_new := nil; fido_dev_free := nil; fido_dev_open := nil;
  fido_dev_close := nil; fido_dev_cancel := nil; fido_dev_set_timeout := nil;
  fido_dev_is_fido2 := nil; fido_dev_is_winhello := nil;
  fido_dev_has_pin := nil; fido_dev_has_uv := nil;
  fido_cbor_info_new := nil; fido_cbor_info_free := nil;
  fido_dev_get_cbor_info := nil; fido_cbor_info_algorithm_count := nil;
  fido_cbor_info_algorithm_cose := nil;
  fido_cred_new := nil; fido_cred_free := nil; fido_cred_set_type := nil;
  fido_cred_set_clientdata := nil; fido_cred_set_rp := nil;
  fido_cred_set_user := nil; fido_cred_set_rk := nil; fido_cred_set_uv := nil;
  fido_cred_set_prot := nil; fido_cred_id_ptr := nil; fido_cred_id_len := nil;
  fido_cred_pubkey_ptr := nil; fido_cred_pubkey_len := nil;
  fido_cred_type := nil; fido_dev_make_cred := nil;
  fido_cred_aaguid_ptr := nil; fido_cred_aaguid_len := nil;
  fido_assert_new := nil; fido_assert_free := nil; fido_assert_set_rp := nil;
  fido_assert_set_clientdata := nil; fido_assert_allow_cred := nil;
  fido_assert_set_up := nil; fido_assert_set_uv := nil;
  fido_assert_count := nil; fido_assert_sig_ptr := nil;
  fido_assert_sig_len := nil; fido_assert_flags := nil;
  fido_assert_sigcount := nil; fido_dev_get_assert := nil;
end;

function Fido2TryLoad: Boolean;
var
  p, missing: string;
  tried: string;

  // Toute anomalie desactive la lib en entier: on note le premier symbole
  // manquant et on n'appellera rien.
  function Sym(const AName: string): Pointer;
  begin
    Result := GetProcAddress(GLib, AName);
    if (Result = nil) and (missing = '') then
      missing := AName;
  end;

begin
  if GReady then Exit(True);
  EnterCriticalSection(GInitLock);
  try
    if GReady then Exit(True);
    if GTried then Exit(False);   // un echec ne se retente pas a chaque session
    GTried := True;
    tried := '';
    for p in CandidatePaths do
    begin
      if not AbsCandidate(p) then Continue;
      if tried <> '' then tried := tried + ', ';
      tried := tried + p;
      if not FileExists(p) then Continue;
      GLib := LoadLibrary(p);
      if GLib <> NilHandle then
      begin
        GPath := p;
        Break;
      end;
    end;
    if GLib = NilHandle then
    begin
      GError := 'libfido2 not found (looked in: ' + tried + ')';
      Exit(False);
    end;

    missing := '';
    Pointer(fido_init) := Sym('fido_init');
    Pointer(fido_strerr) := Sym('fido_strerr');

    Pointer(fido_dev_info_new) := Sym('fido_dev_info_new');
    Pointer(fido_dev_info_free) := Sym('fido_dev_info_free');
    Pointer(fido_dev_info_manifest) := Sym('fido_dev_info_manifest');
    Pointer(fido_dev_info_ptr) := Sym('fido_dev_info_ptr');
    Pointer(fido_dev_info_path) := Sym('fido_dev_info_path');
    Pointer(fido_dev_info_manufacturer_string) :=
      Sym('fido_dev_info_manufacturer_string');
    Pointer(fido_dev_info_product_string) := Sym('fido_dev_info_product_string');

    Pointer(fido_dev_new) := Sym('fido_dev_new');
    Pointer(fido_dev_free) := Sym('fido_dev_free');
    Pointer(fido_dev_open) := Sym('fido_dev_open');
    Pointer(fido_dev_close) := Sym('fido_dev_close');
    Pointer(fido_dev_cancel) := Sym('fido_dev_cancel');
    Pointer(fido_dev_set_timeout) := Sym('fido_dev_set_timeout');
    Pointer(fido_dev_is_fido2) := Sym('fido_dev_is_fido2');
    Pointer(fido_dev_is_winhello) := Sym('fido_dev_is_winhello');
    Pointer(fido_dev_has_pin) := Sym('fido_dev_has_pin');
    Pointer(fido_dev_has_uv) := Sym('fido_dev_has_uv');

    Pointer(fido_cbor_info_new) := Sym('fido_cbor_info_new');
    Pointer(fido_cbor_info_free) := Sym('fido_cbor_info_free');
    Pointer(fido_dev_get_cbor_info) := Sym('fido_dev_get_cbor_info');
    Pointer(fido_cbor_info_algorithm_count) :=
      Sym('fido_cbor_info_algorithm_count');
    Pointer(fido_cbor_info_algorithm_cose) :=
      Sym('fido_cbor_info_algorithm_cose');

    Pointer(fido_cred_new) := Sym('fido_cred_new');
    Pointer(fido_cred_free) := Sym('fido_cred_free');
    Pointer(fido_cred_set_type) := Sym('fido_cred_set_type');
    Pointer(fido_cred_set_clientdata) := Sym('fido_cred_set_clientdata');
    Pointer(fido_cred_set_rp) := Sym('fido_cred_set_rp');
    Pointer(fido_cred_set_user) := Sym('fido_cred_set_user');
    Pointer(fido_cred_set_rk) := Sym('fido_cred_set_rk');
    Pointer(fido_cred_set_uv) := Sym('fido_cred_set_uv');
    Pointer(fido_cred_set_prot) := Sym('fido_cred_set_prot');
    Pointer(fido_cred_id_ptr) := Sym('fido_cred_id_ptr');
    Pointer(fido_cred_id_len) := Sym('fido_cred_id_len');
    Pointer(fido_cred_pubkey_ptr) := Sym('fido_cred_pubkey_ptr');
    Pointer(fido_cred_pubkey_len) := Sym('fido_cred_pubkey_len');
    Pointer(fido_cred_type) := Sym('fido_cred_type');
    Pointer(fido_cred_aaguid_ptr) := Sym('fido_cred_aaguid_ptr');
    Pointer(fido_cred_aaguid_len) := Sym('fido_cred_aaguid_len');
    Pointer(fido_dev_make_cred) := Sym('fido_dev_make_cred');

    Pointer(fido_assert_new) := Sym('fido_assert_new');
    Pointer(fido_assert_free) := Sym('fido_assert_free');
    Pointer(fido_assert_set_rp) := Sym('fido_assert_set_rp');
    Pointer(fido_assert_set_clientdata) := Sym('fido_assert_set_clientdata');
    Pointer(fido_assert_allow_cred) := Sym('fido_assert_allow_cred');
    Pointer(fido_assert_set_up) := Sym('fido_assert_set_up');
    Pointer(fido_assert_set_uv) := Sym('fido_assert_set_uv');
    Pointer(fido_assert_count) := Sym('fido_assert_count');
    Pointer(fido_assert_sig_ptr) := Sym('fido_assert_sig_ptr');
    Pointer(fido_assert_sig_len) := Sym('fido_assert_sig_len');
    Pointer(fido_assert_flags) := Sym('fido_assert_flags');
    Pointer(fido_assert_sigcount) := Sym('fido_assert_sigcount');
    Pointer(fido_dev_get_assert) := Sym('fido_dev_get_assert');

    if missing <> '' then
    begin
      GError := 'libfido2 at ' + GPath + ' is missing symbol ' + missing +
        ' (version 1.9 or newer required)';
      Reset;
      UnloadLibrary(GLib);
      GLib := NilHandle;
      GPath := '';
      Exit(False);
    end;

    fido_init(0);
    GReady := True;
    Result := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function Fido2Available: Boolean;
begin
  Result := GReady;
end;

function Fido2LoadError: string;
begin
  Result := GError;
end;

function Fido2LoadedPath: string;
begin
  Result := GPath;
end;

function Fido2StrErr(ACode: Integer): string;
var
  s: PAnsiChar;
begin
  Result := '';
  if Assigned(fido_strerr) then
  begin
    s := fido_strerr(ACode);
    if s <> nil then
      Result := string(AnsiString(s));
  end;
  if Result = '' then
    Result := Format('FIDO error %d', [ACode])
  else
    Result := Format('%s (0x%.2x)', [Result, ACode and $FF]);
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  // Ni UnloadLibrary ni fido_dev_close global: une operation peut encore
  // tourner dans un thread de session, comme pour libssh2.
  DoneCriticalSection(GInitLock);

end.
