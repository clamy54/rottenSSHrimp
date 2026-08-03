unit uSodiumApi;

{$mode objfpc}{$H+}

// Binding dynamique libsodium, charge par chemins absolus controles: repertoire
// applicatif puis emplacements systeme. Jamais le cwd ni PATH.

interface

uses
  SysUtils, ctypes;

const
  crypto_pwhash_ALG_ARGON2ID13 = 2;
  crypto_pwhash_SALTBYTES = 16;
  crypto_pwhash_BYTES_MIN = 16;

  crypto_aead_xchacha20poly1305_ietf_KEYBYTES = 32;
  crypto_aead_xchacha20poly1305_ietf_NPUBBYTES = 24;
  crypto_aead_xchacha20poly1305_ietf_ABYTES = 16;

  crypto_kdf_KEYBYTES = 32;
  crypto_kdf_CONTEXTBYTES = 8;

  crypto_generichash_BYTES = 32;
  crypto_generichash_KEYBYTES = 32;

  crypto_sign_ed25519_PUBLICKEYBYTES = 32;
  crypto_sign_ed25519_SECRETKEYBYTES = 64;   // seed (32) || cle publique (32)

type
  ESodiumError = class(Exception);

  Tsodium_init = function: cint; cdecl;
  Tsodium_version_string = function: PAnsiChar; cdecl;
  Trandombytes_buf = procedure(buf: Pointer; size: csize_t); cdecl;
  Tcrypto_pwhash = function(outp: PByte; outlen: cuint64;
    passwd: PAnsiChar; passwdlen: cuint64; salt: PByte;
    opslimit: cuint64; memlimit: csize_t; alg: cint): cint; cdecl;
  Tcrypto_aead_encrypt = function(c: PByte; clen_p: pcuint64;
    m: PByte; mlen: cuint64; ad: PByte; adlen: cuint64;
    nsec: PByte; npub: PByte; k: PByte): cint; cdecl;
  Tcrypto_aead_decrypt = function(m: PByte; mlen_p: pcuint64;
    nsec: PByte; c: PByte; clen: cuint64; ad: PByte; adlen: cuint64;
    npub: PByte; k: PByte): cint; cdecl;
  Tcrypto_kdf_derive_from_key = function(subkey: PByte; subkey_len: csize_t;
    subkey_id: cuint64; ctx: PAnsiChar; key: PByte): cint; cdecl;
  Tcrypto_generichash = function(outp: PByte; outlen: csize_t;
    inp: PByte; inlen: cuint64; key: PByte; keylen: csize_t): cint; cdecl;
  Tsodium_malloc = function(size: csize_t): Pointer; cdecl;
  Tsodium_free = procedure(ptr: Pointer); cdecl;
  Tsodium_mlock = function(addr: Pointer; len: csize_t): cint; cdecl;
  Tsodium_munlock = function(addr: Pointer; len: csize_t): cint; cdecl;
  Tsodium_memzero = procedure(pnt: Pointer; len: csize_t); cdecl;
  Tcrypto_sign_ed25519_keypair = function(pk: PByte; sk: PByte): cint; cdecl;

var
  sodium_init: Tsodium_init = nil;
  sodium_version_string: Tsodium_version_string = nil;
  randombytes_buf: Trandombytes_buf = nil;
  crypto_pwhash: Tcrypto_pwhash = nil;
  crypto_aead_xchacha20poly1305_ietf_encrypt: Tcrypto_aead_encrypt = nil;
  crypto_aead_xchacha20poly1305_ietf_decrypt: Tcrypto_aead_decrypt = nil;
  crypto_kdf_derive_from_key: Tcrypto_kdf_derive_from_key = nil;
  crypto_generichash: Tcrypto_generichash = nil;
  sodium_malloc: Tsodium_malloc = nil;
  sodium_free: Tsodium_free = nil;
  sodium_mlock: Tsodium_mlock = nil;
  sodium_munlock: Tsodium_munlock = nil;
  sodium_memzero: Tsodium_memzero = nil;
  crypto_sign_ed25519_keypair: Tcrypto_sign_ed25519_keypair = nil;

// Idempotent. Leve ESodiumError si la lib ou un symbole manque: pas d'API partielle.
procedure SodiumEnsureLoaded;
function SodiumIsLoaded: Boolean;

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
  exeDir := ExtractFilePath(ParamStr(0));
  {$IFDEF DARWIN}
  Result := [
    exeDir + '../Frameworks/libsodium.dylib',
    exeDir + 'libsodium.dylib',
    '/opt/homebrew/lib/libsodium.dylib',
    '/usr/local/lib/libsodium.dylib'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/libsodium.so.26',
    exeDir + 'lib/libsodium.so.23',
    exeDir + 'libsodium.so',
    '/usr/lib/x86_64-linux-gnu/libsodium.so.26',
    '/usr/lib/x86_64-linux-gnu/libsodium.so.23',
    '/usr/lib/libsodium.so.26',
    '/usr/lib/libsodium.so.23'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := [exeDir + 'libsodium.dll'];
  {$ENDIF}
end;

function MustSym(const AName: string): Pointer;
begin
  Result := GetProcAddress(GLib, AName);
  if Result = nil then
    raise ESodiumError.CreateFmt('libsodium: missing symbol: %s', [AName]);
end;

procedure SodiumEnsureLoaded;
var
  p: string;
begin
  if GReady then Exit;
  // deux connexions concurrentes ne doivent pas initialiser la lib deux fois
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
    raise ESodiumError.Create('libsodium not found in the expected locations');
  Pointer(sodium_init) := MustSym('sodium_init');
  Pointer(sodium_version_string) := MustSym('sodium_version_string');
  Pointer(randombytes_buf) := MustSym('randombytes_buf');
  Pointer(crypto_pwhash) := MustSym('crypto_pwhash');
  Pointer(crypto_aead_xchacha20poly1305_ietf_encrypt) :=
    MustSym('crypto_aead_xchacha20poly1305_ietf_encrypt');
  Pointer(crypto_aead_xchacha20poly1305_ietf_decrypt) :=
    MustSym('crypto_aead_xchacha20poly1305_ietf_decrypt');
  Pointer(crypto_kdf_derive_from_key) := MustSym('crypto_kdf_derive_from_key');
  Pointer(crypto_generichash) := MustSym('crypto_generichash');
  Pointer(sodium_malloc) := MustSym('sodium_malloc');
  Pointer(sodium_free) := MustSym('sodium_free');
  Pointer(sodium_mlock) := MustSym('sodium_mlock');
  Pointer(sodium_munlock) := MustSym('sodium_munlock');
  Pointer(sodium_memzero) := MustSym('sodium_memzero');
  Pointer(crypto_sign_ed25519_keypair) := MustSym('crypto_sign_ed25519_keypair');
  if sodium_init() < 0 then
    raise ESodiumError.Create('sodium_init failed');
  GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function SodiumIsLoaded: Boolean;
begin
  Result := GReady;
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  DoneCriticalSection(GInitLock);

end.
