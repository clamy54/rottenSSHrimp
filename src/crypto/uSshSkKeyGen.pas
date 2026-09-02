unit uSshSkKeyGen;

{$mode objfpc}{$H+}

// Encodage OpenSSH des cles de securite (FIDO2): sk-ssh-ed25519@openssh.com et
// sk-ecdsa-sha2-nistp256@openssh.com.
//
// Ces cles n'ont PAS de partie privee au sens habituel: le secret reste dans le
// token, et le fichier « prive » ne contient qu'un key handle, l'application et
// des drapeaux. Il est neanmoins traite comme un secret (TSecureBytes, scelle
// dans le document): le key handle designe la cle, et qui le detient peut
// demander une signature a un token present.
//
// Formats: PROTOCOL.u2f d'OpenSSH. Le conteneur openssh-key-v1 est celui
// d'uSshKeyGen, dont les briques sont reutilisees telles quelles.

interface

uses
  SysUtils, uSecureBytes, uSshKeyGen;

const
  SK_TYPE_ED25519 = 'sk-ssh-ed25519@openssh.com';
  SK_TYPE_ECDSA_P256 = 'sk-ecdsa-sha2-nistp256@openssh.com';
  SK_CURVE_P256 = 'nistp256';

  // sk-api.h d'OpenSSH. La presence est toujours exigee; la verification (PIN)
  // est un choix de l'utilisateur, fige dans le key handle a l'enrolement.
  SSH_SK_USER_PRESENCE_REQD = $01;
  SSH_SK_USER_VERIFICATION_REQD = $04;
  SSH_SK_RESIDENT_KEY = $20;

  // « application » est le relying party vu du token. La convention OpenSSH
  // veut le prefixe « ssh: »; le suffixe nous distingue des cles creees par
  // ssh-keygen, sans quoi elles se melangeraient sur le meme token.
  SK_APPLICATION = 'ssh:rottensshrimp';

  ED25519_SK_PK_LEN = 32;
  ECDSA_P256_POINT_LEN = 65;   // 0x04 || X(32) || Y(32), SEC1 non compresse
  ECDSA_P256_COORD_LEN = 32;

type
  TSkAlg = (skaEd25519, skaEcdsaP256);

function SkTypeName(AAlg: TSkAlg): string;
// APk: 32 octets (ed25519) ou 65 octets 0x04||X||Y (ecdsa p256).
function EncodeSkPublicLine(AAlg: TSkAlg; const APk: TBytes;
  const AApplication, AComment: string): string;
function EncodeSkPrivatePem(AAlg: TSkAlg; const APk: TBytes;
  const AApplication: string; AFlags: Byte; const AKeyHandle: TBytes;
  const AComment: string; ACheckInt: LongWord): TSecureBytes;

// ECDSA_SIG_VALUE ::= SEQUENCE { r INTEGER, s INTEGER }. Le token rend du DER,
// libssh2 attend deux entiers bruts de meme longueur: on retire le zero de
// tete que le DER ajoute pour les valeurs >= 0x80, puis on rembourre a gauche.
function DecodeEcdsaDerSignature(const ADer: TBytes; ACoordLen: Integer;
  out R, S: TBytes): Boolean;

implementation

function SkTypeName(AAlg: TSkAlg): string;
begin
  if AAlg = skaEd25519 then
    Result := SK_TYPE_ED25519
  else
    Result := SK_TYPE_ECDSA_P256;
end;

procedure CheckPk(AAlg: TSkAlg; const APk: TBytes);
begin
  if AAlg = skaEd25519 then
  begin
    if Length(APk) <> ED25519_SK_PK_LEN then
      raise EArgumentException.CreateFmt(
        'sk-ed25519 public key must be %d bytes, got %d',
        [ED25519_SK_PK_LEN, Length(APk)]);
  end
  else
  begin
    if Length(APk) <> ECDSA_P256_POINT_LEN then
      raise EArgumentException.CreateFmt(
        'sk-ecdsa public point must be %d bytes, got %d',
        [ECDSA_P256_POINT_LEN, Length(APk)]);
    if APk[0] <> $04 then
      raise EArgumentException.Create(
        'sk-ecdsa public point must be uncompressed (0x04 prefix)');
  end;
end;

// Partie publique, commune a la ligne authorized_keys et au conteneur prive.
procedure BuildSkPublicBlob(var B: TBuf; AAlg: TSkAlg; const APk: TBytes;
  const AApplication: string);
begin
  AppendSshStr(B, AnsiString(SkTypeName(AAlg)));
  if AAlg = skaEd25519 then
    AppendSshBytes(B, APk[0], Length(APk))
  else
  begin
    AppendSshStr(B, SK_CURVE_P256);
    AppendSshBytes(B, APk[0], Length(APk));
  end;
  AppendSshStr(B, AnsiString(AApplication));
end;

function EncodeSkPublicLine(AAlg: TSkAlg; const APk: TBytes;
  const AApplication, AComment: string): string;
var
  blob: TBuf;
  cmt: string;
begin
  CheckPk(AAlg, APk);
  cmt := SanitizeComment(AComment);
  BufInit(blob, 256);
  try
    BuildSkPublicBlob(blob, AAlg, APk, AApplication);
    Result := SkTypeName(AAlg) + ' ' + B64Line(blob);
    if cmt <> '' then
      Result := Result + ' ' + cmt;
  finally
    BufWipe(blob);
  end;
end;

function EncodeSkPrivatePem(AAlg: TSkAlg; const APk: TBytes;
  const AApplication: string; AFlags: Byte; const AKeyHandle: TBytes;
  const AComment: string; ACheckInt: LongWord): TSecureBytes;
var
  pub, priv: TBuf;
  cmt: string;
  L: Integer;
begin
  CheckPk(AAlg, APk);
  if Length(AKeyHandle) = 0 then
    raise EArgumentException.Create('sk key handle is empty');
  cmt := SanitizeComment(AComment);
  L := Length(cmt) + Length(AKeyHandle);
  BufInit(pub, 256);
  BufInit(priv, 1024 + 4 * L, True);
  try
    BuildSkPublicBlob(pub, AAlg, APk, AApplication);

    AppendU32(priv, ACheckInt);
    AppendU32(priv, ACheckInt);
    AppendSshStr(priv, AnsiString(SkTypeName(AAlg)));
    if AAlg = skaEd25519 then
      AppendSshBytes(priv, APk[0], Length(APk))
    else
    begin
      AppendSshStr(priv, SK_CURVE_P256);
      AppendSshBytes(priv, APk[0], Length(APk));
    end;
    AppendSshStr(priv, AnsiString(AApplication));
    // uint8 nu, PAS un uint32: les drapeaux ne sont pas une chaine SSH
    AppendRaw(priv, AFlags, 1);
    AppendSshBytes(priv, AKeyHandle[0], Length(AKeyHandle));
    AppendSshStr(priv, '');    // reserved, vide a ce jour
    AppendSshStr(priv, AnsiString(cmt));

    Result := WrapOpenSshPrivatePem(pub, priv);
  finally
    BufWipe(pub);
    BufWipe(priv);
  end;
end;

// Un INTEGER DER est signe: une valeur dont l'octet de poids fort depasse 0x7F
// se voit prefixer d'un 0x00. Les coordonnees SSH, elles, sont des entiers non
// signes de taille fixe.
function TrimAndPad(const ASrc: TBytes; AOfs, ALen, ACoordLen: Integer;
  out ADst: TBytes): Boolean;
var
  i, n: Integer;
begin
  ADst := nil;
  Result := False;
  // zeros de tete
  while (ALen > 1) and (ASrc[AOfs] = 0) do
  begin
    Inc(AOfs);
    Dec(ALen);
  end;
  if (ALen <= 0) or (ALen > ACoordLen) then Exit;
  SetLength(ADst, ACoordLen);
  FillChar(ADst[0], ACoordLen, 0);
  n := ACoordLen - ALen;
  for i := 0 to ALen - 1 do
    ADst[n + i] := ASrc[AOfs + i];
  Result := True;
end;

function DecodeEcdsaDerSignature(const ADer: TBytes; ACoordLen: Integer;
  out R, S: TBytes): Boolean;
var
  p, seqLen, rLen, sLen: Integer;
begin
  Result := False;
  R := nil;
  S := nil;
  if ACoordLen <= 0 then Exit;
  // SEQUENCE, longueur courte (une signature P-256 tient largement sous 128)
  if Length(ADer) < 8 then Exit;
  if ADer[0] <> $30 then Exit;
  seqLen := ADer[1];
  if seqLen > $7F then Exit;
  if seqLen <> Length(ADer) - 2 then Exit;

  p := 2;
  if ADer[p] <> $02 then Exit;
  rLen := ADer[p + 1];
  Inc(p, 2);
  if (rLen <= 0) or (p + rLen > Length(ADer)) then Exit;
  if not TrimAndPad(ADer, p, rLen, ACoordLen, R) then Exit;
  Inc(p, rLen);

  if p + 1 >= Length(ADer) then Exit;
  if ADer[p] <> $02 then Exit;
  sLen := ADer[p + 1];
  Inc(p, 2);
  if (sLen <= 0) or (p + sLen > Length(ADer)) then Exit;
  if not TrimAndPad(ADer, p, sLen, ACoordLen, S) then Exit;
  Inc(p, sLen);

  Result := p = Length(ADer);
end;

end.
