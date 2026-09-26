unit uCryptoPolicy;

{$mode objfpc}{$H+}

// Garde-barrieres crypto et limites. Dans le binaire, JAMAIS lues du document.

interface

const
  RSH_FORMAT_NAME = 'RottenSSHrimp';
  // v2: base SQLite dans une enveloppe opaque. Pas de migration v1: jamais diffuse.
  RSH_FORMAT_VERSION = 2;
  RSH_CRYPTO_VERSION = 1;
  RSH_APPLICATION_ID = 1381192520;  // 'RSSH' 0x52535348
  RSH_SCHEMA_VERSION = 13;          // PRAGMA user_version (v13: tunnels SSH)

  // Argon2id: profil libsodium MODERATE
  KDF_OPSLIMIT_DEFAULT = 3;
  KDF_MEMLIMIT_DEFAULT = 256 * 1024 * 1024;

  // bornes d'acceptation d'un document (anti-DoS)
  KDF_SALT_BYTES = 16;
  KDF_OPSLIMIT_MIN = 1;
  KDF_OPSLIMIT_MAX = 32;
  KDF_MEMLIMIT_MIN = 8 * 1024 * 1024;
  KDF_MEMLIMIT_MAX = 1024 * 1024 * 1024;

  AEAD_KEY_BYTES = 32;
  AEAD_NONCE_BYTES = 24;
  AEAD_TAG_BYTES = 16;

  CONTENT_MAC_KDF_CONTEXT = 'RSSH-doc';  // exactement 8 octets
  CONTENT_MAC_KDF_SUBKEY_ID = 1;
  CONTENT_MAC_BYTES = 32;

  // Contexte DIFFERENT du MAC: une sous-cle par usage.
  ENVELOPE_KDF_CONTEXT = 'RSSH-env';     // exactement 8 octets
  ENVELOPE_KDF_SUBKEY_ID = 1;

  MAX_DOCUMENT_BYTES = 512 * 1024 * 1024;
  MAX_NODES = 100000;
  MAX_TREE_DEPTH = 64;
  MAX_NAME_CHARS = 256;
  MAX_HOSTNAME_CHARS = 253;
  MAX_DESCRIPTION_BYTES = 64 * 1024;
  MAX_CIPHERTEXT_BYTES = 16 * 1024 * 1024;

function KdfParamsAcceptable(ASaltLen: Integer; AOps, AMem: Int64): Boolean;

implementation

function KdfParamsAcceptable(ASaltLen: Integer; AOps, AMem: Int64): Boolean;
begin
  Result := (ASaltLen = KDF_SALT_BYTES)
    and (AOps >= KDF_OPSLIMIT_MIN) and (AOps <= KDF_OPSLIMIT_MAX)
    and (AMem >= KDF_MEMLIMIT_MIN) and (AMem <= KDF_MEMLIMIT_MAX);
end;

end.
