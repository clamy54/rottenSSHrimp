unit uRshEnvelope;

{$mode objfpc}{$H+}

// Enveloppe .rsh v2 : en-tete fixe en clair de 72 octets
// (magic, versions, sel/parametres KDF, nonce) servant d'AAD, puis AEAD
// XChaCha20-Poly1305 sur la base SQLite complete. Cle = sous-cle de la KEK.

interface

uses
  SysUtils, uSecureBytes;

const
  ENVELOPE_MAGIC: array[0..7] of AnsiChar = 'RSSHDOC2';
  ENVELOPE_HEADER_BYTES = 72;
  // plus petite base SQLite valide = une page de 512 octets
  ENVELOPE_MIN_BYTES = ENVELOPE_HEADER_BYTES + 16 + 512;

function EnvelopeMagicMatches(const ABytes: TBytes): Boolean;

// magic, versions, bornes KDF sur le seul en-tete, sans rien deriver
function EnvelopeParseHeader(const ABytes: TBytes; out ASalt: TBytes;
  out AOps, AMem: Int64; out ATech: string): Boolean;

// ASalt/AOps/AMem doivent etre ceux dont AEnvKey derive
function EnvelopeSeal(const APayload: TBytes; AEnvKey: TSecureBytes;
  const ASalt: TBytes; AOps, AMem: Int64): TBytes;

// False = mdp faux, fichier altere ou tronque -- indistinguables
function EnvelopeOpen(const ABytes: TBytes; AEnvKey: TSecureBytes;
  out APayload: TBytes): Boolean;

// pour les tests: une passe Argon2id complete par appel
function EnvelopeSealWithPassword(const APayload: TBytes;
  const APassword: RawByteString; AOps, AMem: Int64): TBytes;
function EnvelopeOpenWithPassword(const ABytes: TBytes;
  const APassword: RawByteString; out APayload: TBytes): Boolean;

implementation

uses
  ctypes, uSodiumApi, uDocCrypto, uCryptoPolicy;

procedure PutU32(var ABuf: TBytes; AOffset: Integer; AValue: LongWord);
begin
  ABuf[AOffset]     := Byte(AValue);
  ABuf[AOffset + 1] := Byte(AValue shr 8);
  ABuf[AOffset + 2] := Byte(AValue shr 16);
  ABuf[AOffset + 3] := Byte(AValue shr 24);
end;

function GetU32(const ABuf: TBytes; AOffset: Integer): LongWord;
begin
  Result := LongWord(ABuf[AOffset])
    or (LongWord(ABuf[AOffset + 1]) shl 8)
    or (LongWord(ABuf[AOffset + 2]) shl 16)
    or (LongWord(ABuf[AOffset + 3]) shl 24);
end;

procedure PutI64(var ABuf: TBytes; AOffset: Integer; AValue: Int64);
var
  i: Integer;
begin
  for i := 0 to 7 do
    ABuf[AOffset + i] := Byte(AValue shr (8 * i));
end;

function GetI64(const ABuf: TBytes; AOffset: Integer): Int64;
var
  i: Integer;
begin
  Result := 0;
  for i := 7 downto 0 do
    Result := (Result shl 8) or Int64(ABuf[AOffset + i]);
end;

function EnvelopeMagicMatches(const ABytes: TBytes): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(ABytes) < Length(ENVELOPE_MAGIC) then Exit;
  for i := 0 to High(ENVELOPE_MAGIC) do
    if ABytes[i] <> Byte(ENVELOPE_MAGIC[i]) then Exit;
  Result := True;
end;

function EnvelopeParseHeader(const ABytes: TBytes; out ASalt: TBytes;
  out AOps, AMem: Int64; out ATech: string): Boolean;
begin
  Result := False;
  ASalt := nil;
  AOps := 0;
  AMem := 0;
  ATech := '';
  if Length(ABytes) < ENVELOPE_HEADER_BYTES then
  begin
    ATech := 'enveloppe trop courte';
    Exit;
  end;
  if not EnvelopeMagicMatches(ABytes) then
  begin
    ATech := 'magic RSSHDOC2 absent';
    Exit;
  end;
  if GetU32(ABytes, 8) <> LongWord(RSH_FORMAT_VERSION) then
  begin
    ATech := Format('format_version=%d supporte=%d',
      [GetU32(ABytes, 8), RSH_FORMAT_VERSION]);
    Exit;
  end;
  if GetU32(ABytes, 12) <> LongWord(RSH_CRYPTO_VERSION) then
  begin
    ATech := Format('crypto_version=%d supporte=%d',
      [GetU32(ABytes, 12), RSH_CRYPTO_VERSION]);
    Exit;
  end;
  SetLength(ASalt, KDF_SALT_BYTES);
  Move(ABytes[16], ASalt[0], KDF_SALT_BYTES);
  AOps := GetI64(ABytes, 32);
  AMem := GetI64(ABytes, 40);
  // bornes avant derivation: un memlimit gonfle n'atteint jamais Argon2id
  if not KdfParamsAcceptable(Length(ASalt), AOps, AMem) then
  begin
    ATech := 'parametres KDF hors bornes';
    Exit;
  end;
  Result := True;
end;

function EnvelopeSeal(const APayload: TBytes; AEnvKey: TSecureBytes;
  const ASalt: TBytes; AOps, AMem: Int64): TBytes;
var
  nonce: TBytes;
  clen: cuint64;
begin
  SodiumEnsureLoaded;
  if (AEnvKey = nil) or (AEnvKey.Len <> AEAD_KEY_BYTES) then
    raise EDocCryptoError.Create('invalid envelope key');
  if Length(ASalt) <> KDF_SALT_BYTES then
    raise EDocCryptoError.Create('invalid envelope salt');
  if Length(APayload) = 0 then
    raise EDocCryptoError.Create('envelope: empty content');

  nonce := GenerateRandomBytes(AEAD_NONCE_BYTES);
  Result := nil;
  SetLength(Result, ENVELOPE_HEADER_BYTES + Length(APayload) + AEAD_TAG_BYTES);
  Move(ENVELOPE_MAGIC[0], Result[0], Length(ENVELOPE_MAGIC));
  PutU32(Result, 8, LongWord(RSH_FORMAT_VERSION));
  PutU32(Result, 12, LongWord(RSH_CRYPTO_VERSION));
  Move(ASalt[0], Result[16], KDF_SALT_BYTES);
  PutI64(Result, 32, AOps);
  PutI64(Result, 40, AMem);
  Move(nonce[0], Result[48], AEAD_NONCE_BYTES);

  clen := 0;
  // AAD = l'en-tete complet: versions et parametres KDF sont authentifies.
  if crypto_aead_xchacha20poly1305_ietf_encrypt(
      @Result[ENVELOPE_HEADER_BYTES], @clen,
      @APayload[0], Length(APayload),
      @Result[0], ENVELOPE_HEADER_BYTES,
      nil, @nonce[0], AEnvKey.Data) <> 0 then
    raise EDocCryptoError.Create('envelope encryption failed');
  SetLength(Result, ENVELOPE_HEADER_BYTES + clen);
end;

function EnvelopeOpen(const ABytes: TBytes; AEnvKey: TSecureBytes;
  out APayload: TBytes): Boolean;
var
  mlen: cuint64;
  clen: Int64;
begin
  Result := False;
  APayload := nil;
  SodiumEnsureLoaded;
  if (AEnvKey = nil) or (AEnvKey.Len <> AEAD_KEY_BYTES) then Exit;
  if Length(ABytes) < ENVELOPE_MIN_BYTES then Exit;
  clen := Length(ABytes) - ENVELOPE_HEADER_BYTES;
  SetLength(APayload, clen - AEAD_TAG_BYTES);
  mlen := 0;
  if crypto_aead_xchacha20poly1305_ietf_decrypt(
      @APayload[0], @mlen, nil,
      @ABytes[ENVELOPE_HEADER_BYTES], clen,
      @ABytes[0], ENVELOPE_HEADER_BYTES,
      @ABytes[48], AEnvKey.Data) <> 0 then
  begin
    APayload := nil;
    Exit;
  end;
  SetLength(APayload, mlen);
  Result := True;
end;

function EnvelopeSealWithPassword(const APayload: TBytes;
  const APassword: RawByteString; AOps, AMem: Int64): TBytes;
var
  salt: TBytes;
  kek, envKey: TSecureBytes;
begin
  salt := GenerateRandomBytes(KDF_SALT_BYTES);
  kek := DeriveKek(APassword, salt, AOps, AMem);
  try
    envKey := DeriveEnvelopeKey(kek);
    try
      Result := EnvelopeSeal(APayload, envKey, salt, AOps, AMem);
    finally
      envKey.Free;
    end;
  finally
    kek.Free;
  end;
end;

function EnvelopeOpenWithPassword(const ABytes: TBytes;
  const APassword: RawByteString; out APayload: TBytes): Boolean;
var
  salt: TBytes;
  ops, mem: Int64;
  tech: string;
  kek, envKey: TSecureBytes;
begin
  Result := False;
  APayload := nil;
  if not EnvelopeParseHeader(ABytes, salt, ops, mem, tech) then Exit;
  kek := DeriveKek(APassword, salt, ops, mem);
  try
    envKey := DeriveEnvelopeKey(kek);
    try
      Result := EnvelopeOpen(ABytes, envKey, APayload);
    finally
      envKey.Free;
    end;
  finally
    kek.Free;
  end;
end;

end.
