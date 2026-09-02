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
// Relit les drapeaux (0x01 presence, 0x04 PIN) dans une cle privee sk telle que
// nous l'encodons; False si ce n'est pas une cle sk lisible. Sert a la rotation:
// une cle qui exigeait le PIN doit etre remplacee par une cle qui l'exige.
function DecodeSkPrivateFlags(const APem: PByte; ALen: NativeUInt;
  out AFlags: Byte): Boolean;
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

// Decodage base64 sur octets (lignes, CR/LF toleres): pas de string, le
// resultat porte un key handle et doit pouvoir etre efface.
function B64DecodeBytes(const P: PByte; ACount: NativeUInt): TBytes;
const
  ALPH: AnsiString = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  i: NativeUInt;
  v, acc, bits, n: Integer;
  c: Byte;
begin
  Result := nil;
  SetLength(Result, (ACount * 3) div 4 + 3);
  n := 0; acc := 0; bits := 0;
  for i := 0 to ACount - 1 do
  begin
    c := P[i];
    if c = Ord('=') then Break;
    v := Pos(AnsiChar(c), ALPH) - 1;
    if v < 0 then Continue;
    acc := ((acc shl 6) or v) and $FFFFFF;
    Inc(bits, 6);
    if bits >= 8 then
    begin
      Dec(bits, 8);
      Result[n] := (acc shr bits) and $FF;
      Inc(n);
    end;
  end;
  SetLength(Result, n);
end;

procedure WipeBytes(var B: TBytes);
begin
  if B <> nil then
    FillChar(B[0], Length(B), 0);
  B := nil;
end;

function DecodeSkPrivateFlags(const APem: PByte; ALen: NativeUInt;
  out AFlags: Byte): Boolean;
const
  MAGIC: AnsiString = 'openssh-key-v1'#0;
var
  b64, blob: TBytes;
  i, n: NativeUInt;
  lineStart: Boolean;
  p, limit, L: Integer;
  ktype: AnsiString;   // le nom du type n'est pas un secret

  // Longueur d'un « string » SSH en APos, borne par ALimit. Controles
  // soustractifs: la longueur vient du fichier, elle n'est jamais additionnee
  // avant d'avoir ete comparee, un 0x80000000 ne peut donc pas rendre p negatif.
  function StrLen(APos, ALimit: Integer; out AL: Integer): Boolean;
  var
    u: LongWord;
  begin
    Result := False;
    AL := 0;
    if (APos < 0) or (ALimit - APos < 4) then Exit;
    u := (LongWord(blob[APos]) shl 24) or (LongWord(blob[APos + 1]) shl 16)
      or (LongWord(blob[APos + 2]) shl 8) or LongWord(blob[APos + 3]);
    if u > LongWord(ALimit - APos - 4) then Exit;
    AL := Integer(u);
    Result := True;
  end;

  function SkipStr(var APos: Integer; ALimit: Integer): Boolean;
  var
    sl: Integer;
  begin
    Result := StrLen(APos, ALimit, sl);
    if Result then
      APos := APos + 4 + sl;
  end;

  function StrIs(APos, ALimit: Integer; const AValue: AnsiString): Boolean;
  var
    sl: Integer;
  begin
    Result := StrLen(APos, ALimit, sl) and (sl = Length(AValue)) and
      ((sl = 0) or CompareMem(@blob[APos + 4], PAnsiChar(AValue), sl));
  end;

begin
  Result := False;
  AFlags := 0;
  if (APem = nil) or (ALen < 5) then Exit;
  if not CompareMem(APem, PAnsiChar('-----'), 5) then Exit;
  // Le corps base64, sans les lignes d'armure: on ne passe par aucune string,
  // tout ce qui a touche le contenu prive est efface a la sortie.
  b64 := nil;
  SetLength(b64, ALen);
  n := 0;
  lineStart := True;
  i := 0;
  while i < ALen do
  begin
    if lineStart and (APem[i] = Ord('-')) then
    begin
      while (i < ALen) and (APem[i] <> 10) do Inc(i);
      lineStart := True;
    end
    else
    begin
      lineStart := APem[i] = 10;
      if APem[i] > 32 then
      begin
        b64[n] := APem[i];
        Inc(n);
      end;
    end;
    Inc(i);
  end;
  blob := nil;
  try
    if n > 0 then
      blob := B64DecodeBytes(@b64[0], n);
    WipeBytes(b64);
    // openssh-key-v1\0 (15) | string cipher | string kdf | string kdfopts |
    // u32 nkeys | string pub | string priv
    limit := Length(blob);
    if limit < 15 then Exit;
    if not CompareMem(@blob[0], PAnsiChar(MAGIC), 15) then Exit;
    p := 15;
    if not StrIs(p, limit, 'none') then Exit;   // cipher: nous n'en posons pas
    if not SkipStr(p, limit) then Exit;
    if not StrIs(p, limit, 'none') then Exit;   // kdf
    if not SkipStr(p, limit) then Exit;
    if not SkipStr(p, limit) then Exit;         // kdfopts
    if limit - p < 4 then Exit;
    if (blob[p] <> 0) or (blob[p + 1] <> 0) or (blob[p + 2] <> 0)
      or (blob[p + 3] <> 1) then Exit;          // nkeys = 1
    Inc(p, 4);
    if not SkipStr(p, limit) then Exit;         // pub
    if not StrLen(p, limit, L) then Exit;       // priv
    Inc(p, 4);
    limit := p + L;   // la lecture ne sort plus de la section privee
    // section privee: checkint x2 | string type | [string pk | string curve,
    // string Q] | string application | u8 flags | ...
    if limit - p < 8 then Exit;
    Inc(p, 8);
    if not StrLen(p, limit, L) then Exit;
    SetString(ktype, PAnsiChar(@blob[p + 4]), L);
    if (ktype <> SK_TYPE_ED25519) and (ktype <> SK_TYPE_ECDSA_P256) then Exit;
    Inc(p, 4 + L);                              // type
    if ktype = SK_TYPE_ECDSA_P256 then
      if not SkipStr(p, limit) then Exit;       // courbe
    if not SkipStr(p, limit) then Exit;         // pk / Q
    if not SkipStr(p, limit) then Exit;         // application
    if p >= limit then Exit;
    AFlags := blob[p];
    Result := True;
  finally
    WipeBytes(b64);
    WipeBytes(blob);
  end;
end;

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
