unit uSshKeyGen;

{$mode objfpc}{$H+}

// Paires Ed25519 « gerees », encodees aux formats OpenSSH. La
// cle privee ne touche jamais le disque: TSecureBytes, scellee dans le
// document, remise a libssh2 par publickey_frommemory.

interface

uses
  SysUtils, uSecureBytes;

const
  ED25519_PK_LEN = 32;
  ED25519_SK_LEN = 64;   // seed (32) || cle publique (32), convention libsodium

procedure GenerateEd25519KeyPair(const AComment: string;
  out APrivatePem: TSecureBytes; out APublicLine: string);

function EncodeEd25519PublicLine(const APk: array of Byte;
  const AComment: string): string;
function EncodeEd25519PrivatePem(const APk, ASk: array of Byte;
  const AComment: string; ACheckInt: LongWord): TSecureBytes;

implementation

uses
  uSodiumApi;

const
  B64_ALPHABET: array[0..63] of Char =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  KEY_TYPE = 'ssh-ed25519';
  PEM_HEADER = '-----BEGIN OPENSSH PRIVATE KEY-----';
  PEM_FOOTER = '-----END OPENSSH PRIVATE KEY-----';
  PEM_LINE_LEN = 70;

type
  TBuf = record
    Data: TBytes;
    Len: Integer;
    Locked: Boolean;   // mlock: le tampon porte du secret
  end;

procedure SecureZero(P: Pointer; ALen: Integer);
begin
  if ALen <= 0 then Exit;
  if Assigned(sodium_memzero) then
    sodium_memzero(P, ALen)
  else
    FillChar(P^, ALen, 0);
end;

// Le commentaire part dans l'authorized_keys distant: un CR/LF y ferait ligne.
function SanitizeComment(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if (Ord(S[i]) >= $20) and (Ord(S[i]) <> $7F) then
      Result := Result + S[i];
end;

procedure BufInit(out B: TBuf; ACapacity: Integer; ALock: Boolean = False);
begin
  B.Data := nil;
  SetLength(B.Data, ACapacity);
  B.Len := 0;
  B.Locked := ALock and Assigned(sodium_mlock);
  if B.Locked then
    sodium_mlock(@B.Data[0], Length(B.Data));
end;

procedure BufWipe(var B: TBuf);
begin
  if Length(B.Data) > 0 then
  begin
    if B.Locked and Assigned(sodium_munlock) then
      sodium_munlock(@B.Data[0], Length(B.Data))
    else
      SecureZero(@B.Data[0], Length(B.Data));
  end;
  B.Data := nil;
  B.Len := 0;
  B.Locked := False;
end;

// La croissance efface l'ancien bloc: SetLength nu laisserait le secret intact
// dans le tas libere.
procedure AppendRaw(var B: TBuf; const AData; ACount: Integer);
var
  need, oldLen: Integer;
  grown: TBytes;
begin
  need := B.Len + ACount;
  if need > Length(B.Data) then
  begin
    grown := nil;
    SetLength(grown, need * 2);
    if B.Len > 0 then
      Move(B.Data[0], grown[0], B.Len);
    oldLen := Length(B.Data);
    if oldLen > 0 then
    begin
      if B.Locked and Assigned(sodium_munlock) then
        sodium_munlock(@B.Data[0], oldLen)
      else
        SecureZero(@B.Data[0], oldLen);
    end;
    B.Data := grown;
    if B.Locked and Assigned(sodium_mlock) then
      sodium_mlock(@B.Data[0], Length(B.Data));
  end;
  if ACount > 0 then
    Move(AData, B.Data[B.Len], ACount);
  Inc(B.Len, ACount);
end;

procedure AppendU32(var B: TBuf; V: LongWord);
var
  raw: array[0..3] of Byte;
begin
  raw[0] := (V shr 24) and $FF;
  raw[1] := (V shr 16) and $FF;
  raw[2] := (V shr 8) and $FF;
  raw[3] := V and $FF;
  AppendRaw(B, raw[0], 4);
end;

procedure AppendSshBytes(var B: TBuf; const AData; ACount: Integer);
begin
  AppendU32(B, LongWord(ACount));
  AppendRaw(B, AData, ACount);
end;

procedure AppendSshStr(var B: TBuf; const S: AnsiString);
begin
  AppendU32(B, LongWord(Length(S)));
  if S <> '' then
    AppendRaw(B, S[1], Length(S));
end;

procedure B64Append(var Dst: TBuf; const Src: TBytes; SrcLen: Integer);
var
  i: Integer;
  b0, b1, b2: Byte;
  quad: array[0..3] of Char;
begin
  i := 0;
  while i + 2 < SrcLen do
  begin
    b0 := Src[i]; b1 := Src[i + 1]; b2 := Src[i + 2];
    quad[0] := B64_ALPHABET[b0 shr 2];
    quad[1] := B64_ALPHABET[((b0 and $03) shl 4) or (b1 shr 4)];
    quad[2] := B64_ALPHABET[((b1 and $0F) shl 2) or (b2 shr 6)];
    quad[3] := B64_ALPHABET[b2 and $3F];
    AppendRaw(Dst, quad[0], 4);
    Inc(i, 3);
  end;
  case SrcLen - i of
    1:
      begin
        b0 := Src[i];
        quad[0] := B64_ALPHABET[b0 shr 2];
        quad[1] := B64_ALPHABET[(b0 and $03) shl 4];
        quad[2] := '='; quad[3] := '=';
        AppendRaw(Dst, quad[0], 4);
      end;
    2:
      begin
        b0 := Src[i]; b1 := Src[i + 1];
        quad[0] := B64_ALPHABET[b0 shr 2];
        quad[1] := B64_ALPHABET[((b0 and $03) shl 4) or (b1 shr 4)];
        quad[2] := B64_ALPHABET[(b1 and $0F) shl 2];
        quad[3] := '=';
        AppendRaw(Dst, quad[0], 4);
      end;
  end;
end;

procedure BuildPublicBlob(var B: TBuf; const APk: array of Byte);
begin
  AppendSshStr(B, KEY_TYPE);
  AppendSshBytes(B, APk[0], Length(APk));
end;

function EncodeEd25519PublicLine(const APk: array of Byte;
  const AComment: string): string;
var
  blob, b64: TBuf;
  s, cmt: string;
begin
  if Length(APk) <> ED25519_PK_LEN then
    raise EArgumentException.Create('Ed25519 public key must be 32 bytes');
  cmt := SanitizeComment(AComment);
  BufInit(blob, 64);
  BufInit(b64, 96);
  try
    BuildPublicBlob(blob, APk);
    B64Append(b64, blob.Data, blob.Len);
    SetString(s, PAnsiChar(@b64.Data[0]), b64.Len);
    Result := KEY_TYPE + ' ' + s;
    if cmt <> '' then
      Result := Result + ' ' + cmt;
  finally
    BufWipe(blob);
    BufWipe(b64);
  end;
end;

function EncodeEd25519PrivatePem(const APk, ASk: array of Byte;
  const AComment: string; ACheckInt: LongWord): TSecureBytes;
var
  pub, priv, blob, b64, pem: TBuf;
  i, pad, col, L: Integer;
  lf: Byte;
  cmt: string;
begin
  if Length(APk) <> ED25519_PK_LEN then
    raise EArgumentException.Create('Ed25519 public key must be 32 bytes');
  if Length(ASk) <> ED25519_SK_LEN then
    raise EArgumentException.Create('Ed25519 private key must be 64 bytes');
  cmt := SanitizeComment(AComment);
  L := Length(cmt);
  // Surdimensionne pour ne jamais croitre: mlock stable, pas de cle en clair
  // dans le swap. pub ne porte que du public.
  BufInit(pub, 64);
  BufInit(priv, 512 + 4 * L, True);
  BufInit(blob, 1024 + 4 * L, True);
  BufInit(b64, 2048 + 8 * L, True);
  BufInit(pem, 3072 + 8 * L, True);
  try
    BuildPublicBlob(pub, APk);

    // checkint repete et bourrage 1,2,3...: OpenSSH verifie meme sans chiffre
    AppendU32(priv, ACheckInt);
    AppendU32(priv, ACheckInt);
    AppendSshStr(priv, KEY_TYPE);
    AppendSshBytes(priv, APk[0], Length(APk));
    AppendSshBytes(priv, ASk[0], Length(ASk));
    AppendSshStr(priv, cmt);
    pad := 1;
    while (priv.Len mod 8) <> 0 do
    begin
      AppendRaw(priv, pad, 1);
      Inc(pad);
    end;

    AppendRaw(blob, AnsiString('openssh-key-v1'#0)[1], 15);
    AppendSshStr(blob, 'none');
    AppendSshStr(blob, 'none');
    AppendSshStr(blob, '');
    AppendU32(blob, 1);
    AppendSshBytes(blob, pub.Data[0], pub.Len);
    AppendSshBytes(blob, priv.Data[0], priv.Len);

    B64Append(b64, blob.Data, blob.Len);

    // LF meme sous Windows: convention OpenSSH sur toutes les plateformes.
    lf := 10;
    AppendRaw(pem, AnsiString(PEM_HEADER)[1], Length(PEM_HEADER));
    AppendRaw(pem, lf, 1);
    i := 0;
    while i < b64.Len do
    begin
      col := b64.Len - i;
      if col > PEM_LINE_LEN then col := PEM_LINE_LEN;
      AppendRaw(pem, b64.Data[i], col);
      AppendRaw(pem, lf, 1);
      Inc(i, col);
    end;
    AppendRaw(pem, AnsiString(PEM_FOOTER)[1], Length(PEM_FOOTER));
    AppendRaw(pem, lf, 1);

    Result := TSecureBytes.CreateFrom(pem.Data[0], pem.Len);
  finally
    BufWipe(pub);
    BufWipe(priv);
    BufWipe(blob);
    BufWipe(b64);
    BufWipe(pem);
  end;
end;

procedure GenerateEd25519KeyPair(const AComment: string;
  out APrivatePem: TSecureBytes; out APublicLine: string);
var
  pk: array[0..ED25519_PK_LEN - 1] of Byte;
  sk: array[0..ED25519_SK_LEN - 1] of Byte;
  check: LongWord;
begin
  SodiumEnsureLoaded;
  if crypto_sign_ed25519_keypair(@pk[0], @sk[0]) <> 0 then
    raise ESodiumError.Create('Ed25519 key generation failed');
  try
    randombytes_buf(@check, SizeOf(check));
    APublicLine := EncodeEd25519PublicLine(pk, AComment);
    APrivatePem := EncodeEd25519PrivatePem(pk, sk, AComment, check);
  finally
    sodium_memzero(@sk[0], SizeOf(sk));
    sodium_memzero(@pk[0], SizeOf(pk));
  end;
end;

end.
