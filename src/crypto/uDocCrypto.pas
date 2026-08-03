unit uDocCrypto;

{$mode objfpc}{$H+}

// Primitives crypto du document: Argon2id -> KEK, DEK aleatoire,
// AEAD XChaCha20-Poly1305 avec AAD canonique par champ, MAC global du
// contenu en clair. Aucun secret dans les messages d'exception.

interface

uses
  SysUtils, uSecureBytes;

type
  EDocCryptoError = class(Exception);

const
  AAD_FIELD_DEK = 'document.dek';

// AAD canonique. Serialisation stable, testee.
function BuildAad(const ADocUuid, AOwnerUuid, AFieldName: string;
  ACryptoVersion: Integer): TBytes;

function GenerateRandomBytes(ACount: Integer): TBytes;
function GenerateDek: TSecureBytes;

// Argon2id. Rejette les parametres hors bornes TCryptoPolicy avant
// toute allocation (anti-DoS).
function DeriveKek(const APassword: RawByteString; const ASalt: TBytes;
  AOps, AMem: Int64): TSecureBytes;

// chiffrement authentifie; nonce aleatoire genere ici
procedure AeadEncrypt(APlain: TSecureBytes; AKey: TSecureBytes;
  const AAad: TBytes; out ANonce, ACipher: TBytes);
// False = authentification echouee (mauvaise cle, donnee alteree ou AAD faux)
function AeadDecrypt(const ACipher, ANonce: TBytes; AKey: TSecureBytes;
  const AAad: TBytes; out APlain: TSecureBytes): Boolean;

procedure WrapDek(ADek, AKek: TSecureBytes; const ADocUuid: string;
  ACryptoVersion: Integer; out ANonce, ACipher: TBytes);
function UnwrapDek(const ACipher, ANonce: TBytes; AKek: TSecureBytes;
  const ADocUuid: string; ACryptoVersion: Integer;
  out ADek: TSecureBytes): Boolean;

// cle dediee a l'enveloppe v2, derivee de la KEK (contexte
// RSSH-env). Une seule passe Argon2id a l'ouverture: la KEK sert a la fois a
// deballer la DEK et, via cette sous-cle, a ouvrir l'enveloppe.
function DeriveEnvelopeKey(AKek: TSecureBytes): TSecureBytes;

// cle dediee au MAC global, derivee de la DEK (contexte RSSH-doc)
function DeriveContentMacKey(ADek: TSecureBytes): TSecureBytes;
// BLAKE2b keye sur la serialisation canonique du contenu
function ComputeKeyedMac(AKey: TSecureBytes; const AData: TBytes): TBytes;
// comparaison a temps constant de deux MAC
function MacEquals(const A, B: TBytes): Boolean;

implementation

uses
  ctypes, uSodiumApi, uCryptoPolicy;

function BuildAad(const ADocUuid, AOwnerUuid, AFieldName: string;
  ACryptoVersion: Integer): TBytes;
var
  s: UTF8String;
begin
  s := 'RottenSSHrimp/v1'#10 +
    'document_uuid=' + ADocUuid + #10 +
    'owner_uuid=' + AOwnerUuid + #10 +
    'field=' + AFieldName + #10 +
    'crypto_version=' + IntToStr(ACryptoVersion);
  Result := nil;
  SetLength(Result, Length(s));
  if Length(s) > 0 then
    Move(s[1], Result[0], Length(s));
end;

function GenerateRandomBytes(ACount: Integer): TBytes;
begin
  SodiumEnsureLoaded;
  Result := nil;
  SetLength(Result, ACount);
  if ACount > 0 then
    randombytes_buf(@Result[0], ACount);
end;

function GenerateDek: TSecureBytes;
begin
  SodiumEnsureLoaded;
  Result := TSecureBytes.Create(AEAD_KEY_BYTES);
  randombytes_buf(Result.Data, AEAD_KEY_BYTES);
end;

function DeriveKek(const APassword: RawByteString; const ASalt: TBytes;
  AOps, AMem: Int64): TSecureBytes;
begin
  SodiumEnsureLoaded;
  if not KdfParamsAcceptable(Length(ASalt), AOps, AMem) then
    raise EDocCryptoError.Create('KDF parameters out of allowed bounds');
  Result := TSecureBytes.Create(AEAD_KEY_BYTES);
  try
    if crypto_pwhash(Result.Data, AEAD_KEY_BYTES,
        PAnsiChar(APassword), Length(APassword), @ASalt[0],
        AOps, AMem, crypto_pwhash_ALG_ARGON2ID13) <> 0 then
      raise EDocCryptoError.Create('crypto_pwhash failed (not enough memory?)');
  except
    Result.Free;
    raise;
  end;
end;

function AadPtr(const AAad: TBytes): PByte; inline;
begin
  if Length(AAad) > 0 then
    Result := @AAad[0]
  else
    Result := nil;
end;

procedure AeadEncrypt(APlain: TSecureBytes; AKey: TSecureBytes;
  const AAad: TBytes; out ANonce, ACipher: TBytes);
var
  clen: cuint64;
begin
  SodiumEnsureLoaded;
  if (AKey = nil) or (AKey.Len <> AEAD_KEY_BYTES) then
    raise EDocCryptoError.Create('invalid AEAD key');
  ANonce := GenerateRandomBytes(AEAD_NONCE_BYTES);
  SetLength(ACipher, APlain.Len + AEAD_TAG_BYTES);
  clen := 0;
  if crypto_aead_xchacha20poly1305_ietf_encrypt(@ACipher[0], @clen,
      APlain.Data, APlain.Len, AadPtr(AAad), Length(AAad),
      nil, @ANonce[0], AKey.Data) <> 0 then
    raise EDocCryptoError.Create('AEAD encryption failed');
  SetLength(ACipher, clen);
end;

function AeadDecrypt(const ACipher, ANonce: TBytes; AKey: TSecureBytes;
  const AAad: TBytes; out APlain: TSecureBytes): Boolean;
var
  mlen: cuint64;
begin
  Result := False;
  APlain := nil;
  SodiumEnsureLoaded;
  if (AKey = nil) or (AKey.Len <> AEAD_KEY_BYTES) then Exit;
  if Length(ANonce) <> AEAD_NONCE_BYTES then Exit;
  if Length(ACipher) < AEAD_TAG_BYTES then Exit;
  if Length(ACipher) > MAX_CIPHERTEXT_BYTES then Exit;
  APlain := TSecureBytes.Create(Length(ACipher) - AEAD_TAG_BYTES);
  mlen := 0;
  if crypto_aead_xchacha20poly1305_ietf_decrypt(APlain.Data, @mlen,
      nil, @ACipher[0], Length(ACipher), AadPtr(AAad), Length(AAad),
      @ANonce[0], AKey.Data) <> 0 then
  begin
    FreeAndNil(APlain);
    Exit;
  end;
  Result := True;
end;

procedure WrapDek(ADek, AKek: TSecureBytes; const ADocUuid: string;
  ACryptoVersion: Integer; out ANonce, ACipher: TBytes);
begin
  AeadEncrypt(ADek, AKek,
    BuildAad(ADocUuid, ADocUuid, AAD_FIELD_DEK, ACryptoVersion),
    ANonce, ACipher);
end;

function UnwrapDek(const ACipher, ANonce: TBytes; AKek: TSecureBytes;
  const ADocUuid: string; ACryptoVersion: Integer;
  out ADek: TSecureBytes): Boolean;
begin
  Result := AeadDecrypt(ACipher, ANonce, AKek,
    BuildAad(ADocUuid, ADocUuid, AAD_FIELD_DEK, ACryptoVersion), ADek);
  if Result and (ADek.Len <> AEAD_KEY_BYTES) then
  begin
    FreeAndNil(ADek);
    Result := False;
  end;
end;

function DeriveEnvelopeKey(AKek: TSecureBytes): TSecureBytes;
begin
  SodiumEnsureLoaded;
  if (AKek = nil) or (AKek.Len <> crypto_kdf_KEYBYTES) then
    raise EDocCryptoError.Create('invalid KEK for key derivation');
  Result := TSecureBytes.Create(AEAD_KEY_BYTES);
  try
    if crypto_kdf_derive_from_key(Result.Data, AEAD_KEY_BYTES,
        ENVELOPE_KDF_SUBKEY_ID, ENVELOPE_KDF_CONTEXT, AKek.Data) <> 0 then
      raise EDocCryptoError.Create('crypto_kdf_derive_from_key failed');
  except
    Result.Free;
    raise;
  end;
end;

function DeriveContentMacKey(ADek: TSecureBytes): TSecureBytes;
begin
  SodiumEnsureLoaded;
  if (ADek = nil) or (ADek.Len <> crypto_kdf_KEYBYTES) then
    raise EDocCryptoError.Create('invalid DEK for key derivation');
  Result := TSecureBytes.Create(CONTENT_MAC_BYTES);
  try
    if crypto_kdf_derive_from_key(Result.Data, CONTENT_MAC_BYTES,
        CONTENT_MAC_KDF_SUBKEY_ID, CONTENT_MAC_KDF_CONTEXT, ADek.Data) <> 0 then
      raise EDocCryptoError.Create('crypto_kdf_derive_from_key failed');
  except
    Result.Free;
    raise;
  end;
end;

function ComputeKeyedMac(AKey: TSecureBytes; const AData: TBytes): TBytes;
var
  p: PByte;
begin
  SodiumEnsureLoaded;
  if (AKey = nil) or (AKey.Len <> crypto_generichash_KEYBYTES) then
    raise EDocCryptoError.Create('invalid MAC key');
  Result := nil;
  SetLength(Result, CONTENT_MAC_BYTES);
  if Length(AData) > 0 then
    p := @AData[0]
  else
    p := nil;
  if crypto_generichash(@Result[0], CONTENT_MAC_BYTES,
      p, Length(AData), AKey.Data, AKey.Len) <> 0 then
    raise EDocCryptoError.Create('crypto_generichash failed');
end;

function MacEquals(const A, B: TBytes): Boolean;
var
  i: Integer;
  diff: Byte;
begin
  Result := False;
  if (Length(A) <> Length(B)) or (Length(A) = 0) then Exit;
  diff := 0;
  for i := 0 to High(A) do
    diff := diff or (A[i] xor B[i]);
  Result := diff = 0;
end;

end.
