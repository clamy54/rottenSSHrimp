unit uSshFido;

{$mode objfpc}{$H+}

// Dialogue avec une cle de securite FIDO2: enrolement d'une nouvelle cle SSH et
// signature d'un defi. AUCUNE dependance a la LCL -- les evenements sont
// appeles sur le thread appelant (thread de session, ou worker d'enrolement),
// c'est a l'appelant de les faire remonter a l'interface.
//
// Un seul token, une seule operation a la fois: un verrou global serialise tout
// (une connexion par rebond en demande deux, un cluster en demande N). Sans lui,
// deux threads se disputeraient le meme peripherique USB.
//
// La bibliotheque est OPTIONNELLE: rien ici ne suppose qu'elle est chargee, et
// FidoAvailable doit etre teste avant de proposer quoi que ce soit.

interface

uses
  SysUtils, SyncObjs, uSecureBytes, uSshSkKeyGen;

type
  // AActive=True a l'entree dans l'attente du geste, False a la sortie. Le nom
  // sert a designer le peripherique quand il y en a plusieurs.
  TFidoTouchEvent = procedure(AActive: Boolean; const ADeviceName: string) of object;
  // False = l'utilisateur a renonce. APin appartient a l'appele apres retour.
  TFidoPinEvent = function(const AReason: string; out APin: TSecureBytes): Boolean of object;

  TFidoEnrollment = record
    Alg: TSkAlg;
    PublicKey: TBytes;    // 32 o (ed25519) ou 65 o 0x04||X||Y (ecdsa p256)
    KeyHandle: TBytes;
    Flags: Byte;
    DeviceName: string;
    // True = la cle a ete creee DANS la machine (TPM Windows Hello) et non sur
    // un token amovible: elle ne suivra pas le document sur un autre poste.
    PlatformBound: Boolean;
  end;

  TFidoSignature = record
    Alg: TSkAlg;
    R: TBytes;            // ed25519: la signature entiere (64 o)
    S: TBytes;            // ecdsa seulement
    Flags: Byte;
    Counter: LongWord;
  end;

  TFidoOperation = class
  private
    FDev: Pointer;
    FDevLock: TCriticalSection;
    FCancelled: Boolean;
    FOnTouch: TFidoTouchEvent;
    FOnPin: TFidoPinEvent;
    FDeviceName: string;
    procedure SetDev(ADev: Pointer);
    procedure Touch(AActive: Boolean);
    // Rend False si l'utilisateur renonce; APinBuf est NUL-terminee.
    function AskPin(ACode: Integer; out APinBuf: TSecureBytes): Boolean;
    function DescribeDevice(ADevInfo: Pointer): string;
    // AKeyHandle vide = enrolement (premier token FIDO2 venu).
    function OpenDevice(const AApplication: string; const AKeyHandle: TBytes;
      out AErr: string): Boolean;
    procedure CloseDevice;
    procedure PreferredAlg(out AAlg: TSkAlg);
  public
    constructor Create;
    destructor Destroy; override;
    // Interrompt l'operation en cours, depuis n'importe quel thread.
    procedure Cancel;
    function Enroll(const AApplication, AUserName: string; ARequireUv: Boolean;
      out AResult: TFidoEnrollment; out AErr: string): Boolean;
    function Sign(const AApplication: string; const AKeyHandle: TBytes;
      AFlags: Byte; AData: PByte; ALen: NativeUInt; AAlg: TSkAlg;
      out ASig: TFidoSignature; out AErr: string): Boolean;
    property OnTouch: TFidoTouchEvent read FOnTouch write FOnTouch;
    property OnPin: TFidoPinEvent read FOnPin write FOnPin;
    property DeviceName: string read FDeviceName;
  end;

// True si libfido2 est chargeable. Ne leve jamais.
function FidoAvailable: Boolean;
// Message pret a afficher quand elle ne l'est pas: dit quoi installer.
function FidoUnavailableMessage: string;
// Traduit un code libfido2 en phrase utile a quelqu'un qui tient la cle.
function FidoDescribeError(ACode: Integer; const AContext: string): string;

implementation

uses
  ctypes, uFido2Api, uSodiumApi;

const
  // Le token attend le doigt: large, c'est l'utilisateur qui decide. Le budget
  // reseau de la session est re-arme apres le geste, il ne compte pas ici.
  FIDO_TIMEOUT_MS = 60000;
  MAX_PIN_TRIES = 3;
  CHALLENGE_LEN = 32;
  USER_ID_LEN = 32;
  ED25519_SIG_LEN = 64;

var
  // Un token physique, une operation: tout le monde fait la queue.
  GFidoLock: TCriticalSection;

function FidoAvailable: Boolean;
begin
  Result := Fido2TryLoad;
end;

function FidoUnavailableMessage: string;
begin
  Result := 'FIDO2 security keys are unavailable: ' + Fido2LoadError + '.' +
    LineEnding + LineEnding + 'Install libfido2 and restart:' + LineEnding +
    {$IFDEF WINDOWS}
    '  place fido2.dll next to the executable (the installer ships it)';
    {$ENDIF}
    {$IFDEF DARWIN}
    '  brew install libfido2';
    {$ENDIF}
    {$IFDEF LINUX}
    '  Debian/Ubuntu: libfido2-1     Arch: libfido2     Fedora: libfido2';
    {$ENDIF}
end;

function FidoDescribeError(ACode: Integer; const AContext: string): string;
var
  s: string;
begin
  case ACode of
    FIDO_ERR_NO_CREDENTIALS:
      s := 'this security key does not hold that credential';
    FIDO_ERR_USER_ACTION_TIMEOUT, FIDO_ERR_ACTION_TIMEOUT, FIDO_ERR_TIMEOUT:
      s := 'the security key was not touched in time';
    FIDO_ERR_KEEPALIVE_CANCEL, FIDO_ERR_OPERATION_DENIED:
      s := 'the request was cancelled on the security key';
    FIDO_ERR_PIN_INVALID, FIDO_ERR_PIN_AUTH_INVALID, FIDO_ERR_UV_INVALID:
      s := 'wrong PIN';
    FIDO_ERR_PIN_AUTH_BLOCKED:
      s := 'too many wrong PINs: unplug the security key and plug it back in';
    FIDO_ERR_PIN_BLOCKED, FIDO_ERR_UV_BLOCKED:
      s := 'the security key PIN is blocked and must be reset';
    FIDO_ERR_PIN_NOT_SET:
      s := 'this credential requires a PIN but the security key has none; ' +
           'set a PIN on the key first';
    FIDO_ERR_PIN_REQUIRED:
      s := 'the security key requires its PIN';
    FIDO_ERR_UNSUPPORTED_ALGORITHM, FIDO_ERR_UNSUPPORTED_OPTION:
      s := 'the security key does not support what this credential needs';
    FIDO_ERR_CREDENTIAL_EXCLUDED:
      s := 'this security key already holds a matching credential';
    FIDO_ERR_KEY_STORE_FULL:
      s := 'the security key is full';
    FIDO_ERR_UP_REQUIRED:
      s := 'the security key needs to be touched';
    FIDO_ERR_TX, FIDO_ERR_RX:
      s := 'lost contact with the security key (was it unplugged?)';
    FIDO_ERR_NOTFOUND:
      s := 'no security key found';
  else
    s := Fido2StrErr(ACode);
  end;
  if AContext = '' then
    Result := s
  else
    Result := AContext + ': ' + s;
end;

// AAGUID des authentificateurs PLATEFORME de Windows: une cle creee par eux vit
// dans le TPM du poste, pas sur la cle de securite. Windows laisse l'utilisateur
// choisir dans sa boite de dialogue et libfido2 ne fixe pas
// dwAuthenticatorAttachment: on ne peut donc que constater apres coup.
function IsPlatformAaguid(AGuid: PByte; ALen: csize_t): Boolean;
const
  // 08987058-cadc-4b81-b6e1-30de50dcbe96  Windows Hello Hardware Authenticator
  // 6028b017-b1d4-4c02-b4b3-afcdafc96bb2  Windows Hello Software Authenticator
  // 9ddd1817-af5a-4672-a2b9-3e3dd95000a9  Windows Hello VBS Hardware
  KNOWN: array[0..2] of array[0..15] of Byte = (
    ($08,$98,$70,$58,$ca,$dc,$4b,$81,$b6,$e1,$30,$de,$50,$dc,$be,$96),
    ($60,$28,$b0,$17,$b1,$d4,$4c,$02,$b4,$b3,$af,$cd,$af,$c9,$6b,$b2),
    ($9d,$dd,$18,$17,$af,$5a,$46,$72,$a2,$b9,$3e,$3d,$d9,$50,$00,$a9));
var
  i, j: Integer;
  ok: Boolean;
begin
  Result := False;
  if (AGuid = nil) or (ALen <> 16) then Exit;
  for i := 0 to High(KNOWN) do
  begin
    ok := True;
    for j := 0 to 15 do
      if (AGuid + j)^ <> KNOWN[i][j] then
      begin
        ok := False;
        Break;
      end;
    if ok then Exit(True);
  end;
end;

constructor TFidoOperation.Create;
begin
  inherited Create;
  FDevLock := TCriticalSection.Create;
end;

destructor TFidoOperation.Destroy;
begin
  CloseDevice;
  FDevLock.Free;
  inherited Destroy;
end;

procedure TFidoOperation.SetDev(ADev: Pointer);
begin
  FDevLock.Acquire;
  try
    FDev := ADev;
  finally
    FDevLock.Release;
  end;
end;

procedure TFidoOperation.Cancel;
var
  d: Pointer;
begin
  FCancelled := True;
  // Sous verrou: le thread de l'operation peut fermer le peripherique au meme
  // instant, et fido_dev_cancel sur un pointeur libere serait fatal.
  FDevLock.Acquire;
  try
    d := FDev;
    if (d <> nil) and Assigned(fido_dev_cancel) then
      fido_dev_cancel(d);
  finally
    FDevLock.Release;
  end;
end;

procedure TFidoOperation.Touch(AActive: Boolean);
begin
  if Assigned(FOnTouch) then
    FOnTouch(AActive, FDeviceName);
end;

function TFidoOperation.AskPin(ACode: Integer; out APinBuf: TSecureBytes): Boolean;
var
  raw: TSecureBytes;
  reason: string;
begin
  Result := False;
  APinBuf := nil;
  if not Assigned(FOnPin) then Exit;
  case ACode of
    FIDO_ERR_PIN_INVALID, FIDO_ERR_PIN_AUTH_INVALID, FIDO_ERR_UV_INVALID:
      reason := 'Wrong PIN. Enter the PIN of your security key:';
  else
    reason := 'Enter the PIN of your security key:';
  end;
  raw := nil;
  if not FOnPin(reason, raw) then
  begin
    raw.Free;
    Exit;
  end;
  try
    if (raw = nil) or (raw.Len = 0) then Exit;
    // libfido2 lit le PIN comme une chaine C et TSecureBytes fait pile la
    // taille demandee (garde sodium juste apres): copie avec un octet de plus.
    APinBuf := TSecureBytes.Create(raw.Len + 1);
    Move(raw.Data^, APinBuf.Data^, raw.Len);
    Result := True;
  finally
    raw.Free;
  end;
end;

function TFidoOperation.DescribeDevice(ADevInfo: Pointer): string;
var
  m, p: PAnsiChar;
  sm, sp: string;
begin
  sm := '';
  sp := '';
  if Assigned(fido_dev_info_manufacturer_string) then
  begin
    m := fido_dev_info_manufacturer_string(ADevInfo);
    if m <> nil then sm := Trim(string(AnsiString(m)));
  end;
  if Assigned(fido_dev_info_product_string) then
  begin
    p := fido_dev_info_product_string(ADevInfo);
    if p <> nil then sp := Trim(string(AnsiString(p)));
  end;
  Result := Trim(sm + ' ' + sp);
  if Result = '' then
    Result := 'security key';
end;

procedure TFidoOperation.CloseDevice;
var
  d: Pointer;
begin
  FDevLock.Acquire;
  try
    d := FDev;
    FDev := nil;
  finally
    FDevLock.Release;
  end;
  if d = nil then Exit;
  if Assigned(fido_dev_close) then fido_dev_close(d);
  if Assigned(fido_dev_free) then fido_dev_free(@d);
end;

// Essai muet: on demande une assertion sans exiger le doigt. Un token qui
// DETIENT la cle repond FIDO_OK ou « il faut toucher / il faut le PIN » -- dans
// tous ces cas c'est le bon. Un token qui ne l'a pas repond NO_CREDENTIALS et
// on passe au suivant, sans l'avoir fait clignoter.
function DeviceHoldsCredential(ADev: Pointer; const AApplication: string;
  const AKeyHandle: TBytes): Boolean;
var
  a: Pfido_assert_t;
  app: AnsiString;
  cd: array[0..CHALLENGE_LEN - 1] of Byte;
  r: cint;
begin
  Result := False;
  a := fido_assert_new();
  if a = nil then Exit;
  try
    app := AnsiString(AApplication);
    FillChar(cd, SizeOf(cd), 0);
    if fido_assert_set_rp(a, PAnsiChar(app)) <> FIDO_OK then Exit;
    if fido_assert_set_clientdata(a, @cd[0], CHALLENGE_LEN) <> FIDO_OK then Exit;
    if fido_assert_allow_cred(a, @AKeyHandle[0], Length(AKeyHandle)) <> FIDO_OK then Exit;
    if fido_assert_set_up(a, FIDO_OPT_FALSE) <> FIDO_OK then Exit;
    r := fido_dev_get_assert(ADev, a, nil);
    Result := (r = FIDO_OK) or (r = FIDO_ERR_USER_PRESENCE_REQUIRED) or
              (r = FIDO_ERR_UP_REQUIRED) or (r = FIDO_ERR_PIN_REQUIRED) or
              (r = FIDO_ERR_UV_INVALID);
  finally
    fido_assert_free(@a);
  end;
end;

function TFidoOperation.OpenDevice(const AApplication: string;
  const AKeyHandle: TBytes; out AErr: string): Boolean;
var
  list: Pfido_dev_info_t;
  di: Pfido_dev_info_t;
  n: csize_t;
  i: Integer;
  path: PAnsiChar;
  dev: Pfido_dev_t;
  spath: string;
  r: cint;
  seen: Integer;
begin
  Result := False;
  AErr := '';
  FDeviceName := '';
  seen := 0;

  list := fido_dev_info_new(FIDO_MAX_DEVICES);
  if list = nil then
  begin
    AErr := 'out of memory listing security keys';
    Exit;
  end;
  try
    n := 0;
    r := fido_dev_info_manifest(list, FIDO_MAX_DEVICES, @n);
    if r <> FIDO_OK then
    begin
      AErr := FidoDescribeError(r, 'cannot list security keys');
      Exit;
    end;
    for i := 0 to Integer(n) - 1 do
    begin
      if FCancelled then Exit;
      di := fido_dev_info_ptr(list, i);
      if di = nil then Continue;
      path := fido_dev_info_path(di);
      if path = nil then Continue;
      spath := string(AnsiString(path));
      {$IFDEF WINDOWS}
      // L'acces HID direct exige les droits administrateur depuis Windows 1903:
      // seul le peripherique virtuel Windows Hello est utilisable tel quel, et
      // c'est lui qui presente la boite « touchez » et demande le PIN.
      if spath <> FIDO_WINHELLO_PATH then Continue;
      {$ENDIF}
      Inc(seen);
      dev := fido_dev_new();
      if dev = nil then Continue;
      if fido_dev_open(dev, path) <> FIDO_OK then
      begin
        fido_dev_free(@dev);
        Continue;
      end;
      if Assigned(fido_dev_set_timeout) then
        fido_dev_set_timeout(dev, FIDO_TIMEOUT_MS);

      if Length(AKeyHandle) = 0 then
      begin
        // Enrolement: n'importe quel token FIDO2 fait l'affaire.
        if fido_dev_is_fido2(dev) then
        begin
          FDeviceName := DescribeDevice(di);
          SetDev(dev);
          Exit(True);
        end;
      end
      // Windows Hello: PAS de sondage. WebAuthn n'a pas d'assertion muette --
      // toute demande passe par la boite systeme et exige l'utilisateur, un
      // essai « sans toucher » y est refuse et ferait croire que la cle n'est
      // pas la. OpenSSH fait pareil: il ouvre windows://hello et laisse Windows
      // trouver la bonne cle a partir de la liste autorisee. Il n'y a de toute
      // facon qu'un seul peripherique de ce cote.
      else if (Assigned(fido_dev_is_winhello) and fido_dev_is_winhello(dev)) or
              DeviceHoldsCredential(dev, AApplication, AKeyHandle) then
      begin
        FDeviceName := DescribeDevice(di);
        SetDev(dev);
        Exit(True);
      end;

      fido_dev_close(dev);
      fido_dev_free(@dev);
    end;
  finally
    fido_dev_info_free(@list, FIDO_MAX_DEVICES);
  end;

  if FCancelled then
    AErr := 'cancelled'
  else if seen = 0 then
    {$IFDEF WINDOWS}
    AErr := 'no security key available. Plug in your security key; ' +
      'Windows handles it through Windows Hello'
    {$ELSE}
    AErr := 'no security key found. Plug it in and try again'
    {$ENDIF}
  else if Length(AKeyHandle) = 0 then
    AErr := 'no FIDO2 security key found (a plain U2F key is not enough)'
  else
    AErr := 'none of the plugged security keys holds this credential. ' +
      'Insert the key this credential was enrolled with';
end;

// EdDSA quand le token l'annonce: cle plus courte et signature brute, sans
// detour par le DER. Windows Hello est ecarte, son support d'EdDSA n'est pas
// fiable et l'enrolement echouerait apres le geste de l'utilisateur.
procedure TFidoOperation.PreferredAlg(out AAlg: TSkAlg);
var
  ci: Pfido_cbor_info_t;
  cnt, i: Integer;
begin
  AAlg := skaEcdsaP256;
  if FDev = nil then Exit;
  {$IFDEF WINDOWS}
  if Assigned(fido_dev_is_winhello) and fido_dev_is_winhello(FDev) then Exit;
  {$ENDIF}
  ci := fido_cbor_info_new();
  if ci = nil then Exit;
  try
    if fido_dev_get_cbor_info(FDev, ci) <> FIDO_OK then Exit;
    cnt := Integer(fido_cbor_info_algorithm_count(ci));
    for i := 0 to cnt - 1 do
      if fido_cbor_info_algorithm_cose(ci, i) = COSE_EDDSA then
      begin
        AAlg := skaEd25519;
        Break;
      end;
  finally
    fido_cbor_info_free(@ci);
  end;
end;

function TFidoOperation.Enroll(const AApplication, AUserName: string;
  ARequireUv: Boolean; out AResult: TFidoEnrollment; out AErr: string): Boolean;
var
  cred: Pfido_cred_t;
  app, uname: AnsiString;
  challenge: array[0..CHALLENGE_LEN - 1] of Byte;
  uid: array[0..USER_ID_LEN - 1] of Byte;
  pin: TSecureBytes;
  pinPtr: PAnsiChar;
  r: cint;
  tries: Integer;
  alg: TSkAlg;
  cose: cint;
  triedEcdsa: Boolean;
  p: PByte;
  L: csize_t;

  function BuildCred: Boolean;
  begin
    Result := False;
    if fido_cred_set_type(cred, cose) <> FIDO_OK then Exit;
    if fido_cred_set_clientdata(cred, @challenge[0], CHALLENGE_LEN) <> FIDO_OK then Exit;
    if fido_cred_set_rp(cred, PAnsiChar(app), 'RottenSSHrimp') <> FIDO_OK then Exit;
    if fido_cred_set_user(cred, @uid[0], USER_ID_LEN, PAnsiChar(uname),
      PAnsiChar(uname), nil) <> FIDO_OK then Exit;
    // Pas de cle residente: le key handle vit dans le document, le token n'a
    // aucune place a consommer et rien a lister s'il est perdu.
    if fido_cred_set_rk(cred, FIDO_OPT_OMIT) <> FIDO_OK then Exit;
    if ARequireUv then
    begin
      if fido_cred_set_uv(cred, FIDO_OPT_TRUE) <> FIDO_OK then Exit;
      // credProtect: le token refusera de s'en servir sans verification, meme
      // si un client oubliait de la demander.
      if Assigned(fido_cred_set_prot) then
        fido_cred_set_prot(cred, FIDO_CRED_PROT_UV_REQUIRED);
    end;
    Result := True;
  end;

begin
  Result := False;
  AErr := '';
  FillChar(AResult, SizeOf(AResult), 0);
  if not Fido2TryLoad then
  begin
    AErr := FidoUnavailableMessage;
    Exit;
  end;

  // FCancelled n'est JAMAIS remis a zero ici: un Cancel recu pendant
  // l'attente du verrou (un autre onglet tient le token) doit compter.
  GFidoLock.Acquire;
  try
    if FCancelled then
    begin
      AErr := 'cancelled';
      Exit;
    end;
    if not OpenDevice(AApplication, nil, AErr) then Exit;
    try
      PreferredAlg(alg);
      triedEcdsa := alg = skaEcdsaP256;
      app := AnsiString(AApplication);
      uname := AnsiString(AUserName);
      if uname = '' then uname := 'rottensshrimp';

      SodiumEnsureLoaded;
      randombytes_buf(@challenge[0], CHALLENGE_LEN);
      randombytes_buf(@uid[0], USER_ID_LEN);

      pin := nil;
      tries := 0;
      try
        while True do
        begin
          if FCancelled then
          begin
            AErr := 'cancelled';
            Exit;
          end;
          if alg = skaEd25519 then cose := COSE_EDDSA else cose := COSE_ES256;
          cred := fido_cred_new();
          if cred = nil then
          begin
            AErr := 'out of memory';
            Exit;
          end;
          try
            if not BuildCred then
            begin
              AErr := 'cannot prepare the enrolment request';
              Exit;
            end;
            if pin <> nil then pinPtr := PAnsiChar(pin.Data) else pinPtr := nil;
            Touch(True);
            try
              r := fido_dev_make_cred(FDev, cred, pinPtr);
            finally
              Touch(False);
            end;

            // Un token dont le PIN est configure l'exige des l'enrolement, meme
            // sans verification demandee.
            if (r = FIDO_ERR_PIN_REQUIRED) or (r = FIDO_ERR_PIN_INVALID) or
               (r = FIDO_ERR_PIN_AUTH_INVALID) or (r = FIDO_ERR_UV_INVALID) then
            begin
              Inc(tries);
              FreeAndNil(pin);
              if tries > MAX_PIN_TRIES then
              begin
                AErr := FidoDescribeError(r, '');
                Exit;
              end;
              if not AskPin(r, pin) then
              begin
                AErr := 'cancelled';
                Exit;
              end;
              Continue;
            end;

            // EdDSA annonce mais refuse: on retombe sur ECDSA plutot que de
            // renvoyer l'utilisateur avec une erreur qu'il ne peut pas corriger.
            if (r <> FIDO_OK) and (not triedEcdsa) and
               ((r = FIDO_ERR_UNSUPPORTED_ALGORITHM) or
                (r = FIDO_ERR_UNSUPPORTED_OPTION) or
                (r = FIDO_ERR_INVALID_ARGUMENT) or
                (r = FIDO_ERR_INVALID_PARAMETER)) then
            begin
              triedEcdsa := True;
              alg := skaEcdsaP256;
              Continue;
            end;

            if r <> FIDO_OK then
            begin
              AErr := FidoDescribeError(r, 'enrolment failed');
              Exit;
            end;

            L := fido_cred_id_len(cred);
            p := fido_cred_id_ptr(cred);
            if (L = 0) or (p = nil) then
            begin
              AErr := 'the security key returned no credential id';
              Exit;
            end;
            SetLength(AResult.KeyHandle, L);
            Move(p^, AResult.KeyHandle[0], L);

            L := fido_cred_pubkey_len(cred);
            p := fido_cred_pubkey_ptr(cred);
            if (L = 0) or (p = nil) then
            begin
              AErr := 'the security key returned no public key';
              Exit;
            end;
            if alg = skaEd25519 then
            begin
              if L <> ED25519_SK_PK_LEN then
              begin
                AErr := Format('unexpected Ed25519 public key length (%d)', [L]);
                Exit;
              end;
              SetLength(AResult.PublicKey, L);
              Move(p^, AResult.PublicKey[0], L);
            end
            else
            begin
              // libfido2 rend X||Y; SSH veut un point SEC1 non compresse.
              if L <> 2 * ECDSA_P256_COORD_LEN then
              begin
                AErr := Format('unexpected ECDSA public key length (%d)', [L]);
                Exit;
              end;
              SetLength(AResult.PublicKey, ECDSA_P256_POINT_LEN);
              AResult.PublicKey[0] := $04;
              Move(p^, AResult.PublicKey[1], L);
            end;

            AResult.Alg := alg;
            AResult.Flags := SSH_SK_USER_PRESENCE_REQD;
            if ARequireUv then
              AResult.Flags := AResult.Flags or SSH_SK_USER_VERIFICATION_REQD;
            AResult.DeviceName := FDeviceName;
            if Assigned(fido_cred_aaguid_ptr) and Assigned(fido_cred_aaguid_len) then
              AResult.PlatformBound := IsPlatformAaguid(
                fido_cred_aaguid_ptr(cred), fido_cred_aaguid_len(cred));
            Result := True;
            Exit;
          finally
            fido_cred_free(@cred);
          end;
        end;
      finally
        pin.Free;
      end;
    finally
      CloseDevice;
    end;
  finally
    GFidoLock.Release;
  end;
end;

function TFidoOperation.Sign(const AApplication: string;
  const AKeyHandle: TBytes; AFlags: Byte; AData: PByte; ALen: NativeUInt;
  AAlg: TSkAlg; out ASig: TFidoSignature; out AErr: string): Boolean;
var
  a: Pfido_assert_t;
  app: AnsiString;
  pin: TSecureBytes;
  pinPtr: PAnsiChar;
  r: cint;
  tries: Integer;
  wantUv, isHello: Boolean;
  p: PByte;
  L: csize_t;
  der: TBytes;
begin
  Result := False;
  AErr := '';
  FillChar(ASig, SizeOf(ASig), 0);
  if (AData = nil) or (ALen = 0) or (Length(AKeyHandle) = 0) then
  begin
    AErr := 'nothing to sign';
    Exit;
  end;
  if not Fido2TryLoad then
  begin
    AErr := FidoUnavailableMessage;
    Exit;
  end;

  GFidoLock.Acquire;
  try
    if FCancelled then
    begin
      AErr := 'cancelled';
      Exit;
    end;
    if not OpenDevice(AApplication, AKeyHandle, AErr) then Exit;
    try
      isHello := Assigned(fido_dev_is_winhello) and fido_dev_is_winhello(FDev);
      wantUv := (AFlags and SSH_SK_USER_VERIFICATION_REQD) <> 0;
      app := AnsiString(AApplication);
      pin := nil;
      tries := 0;
      try
        while True do
        begin
          if FCancelled then
          begin
            AErr := 'cancelled';
            Exit;
          end;
          a := fido_assert_new();
          if a = nil then
          begin
            AErr := 'out of memory';
            Exit;
          end;
          try
            if (fido_assert_set_rp(a, PAnsiChar(app)) <> FIDO_OK) or
               // le message part BRUT: libfido2 en fait le SHA-256 lui-meme
               (fido_assert_set_clientdata(a, AData, ALen) <> FIDO_OK) or
               (fido_assert_allow_cred(a, @AKeyHandle[0], Length(AKeyHandle)) <> FIDO_OK) or
               (fido_assert_set_up(a, FIDO_OPT_TRUE) <> FIDO_OK) then
            begin
              AErr := 'cannot prepare the signature request';
              Exit;
            end;
            // Windows Hello demande la verification de lui-meme: la reclamer en
            // plus ferait echouer la requete.
            if wantUv and (pin = nil) and (not isHello) then
              fido_assert_set_uv(a, FIDO_OPT_TRUE)
            else
              fido_assert_set_uv(a, FIDO_OPT_FALSE);

            if pin <> nil then pinPtr := PAnsiChar(pin.Data) else pinPtr := nil;
            // Windows Hello affiche sa propre boite: la notre ferait doublon.
            if not isHello then Touch(True);
            try
              r := fido_dev_get_assert(FDev, a, pinPtr);
            finally
              if not isHello then Touch(False);
            end;

            if (r = FIDO_ERR_PIN_REQUIRED) or (r = FIDO_ERR_PIN_INVALID) or
               (r = FIDO_ERR_PIN_AUTH_INVALID) or (r = FIDO_ERR_UV_INVALID) then
            begin
              Inc(tries);
              FreeAndNil(pin);
              // Sous Windows Hello, le PIN est saisi dans la boite du systeme:
              // en redemander un ici n'aurait aucun effet.
              if (tries > MAX_PIN_TRIES) or isHello then
              begin
                AErr := FidoDescribeError(r, '');
                Exit;
              end;
              if not AskPin(r, pin) then
              begin
                AErr := 'cancelled';
                Exit;
              end;
              Continue;
            end;

            if r <> FIDO_OK then
            begin
              AErr := FidoDescribeError(r, '');
              Exit;
            end;
            if fido_assert_count(a) < 1 then
            begin
              AErr := 'the security key returned no assertion';
              Exit;
            end;

            L := fido_assert_sig_len(a, 0);
            p := fido_assert_sig_ptr(a, 0);
            if (L = 0) or (p = nil) then
            begin
              AErr := 'the security key returned an empty signature';
              Exit;
            end;
            if AAlg = skaEd25519 then
            begin
              if L <> ED25519_SIG_LEN then
              begin
                AErr := Format('unexpected Ed25519 signature length (%d)', [L]);
                Exit;
              end;
              SetLength(ASig.R, L);
              Move(p^, ASig.R[0], L);
              ASig.S := nil;
            end
            else
            begin
              SetLength(der, L);
              Move(p^, der[0], L);
              if not DecodeEcdsaDerSignature(der, ECDSA_P256_COORD_LEN,
                ASig.R, ASig.S) then
              begin
                AErr := 'the security key returned a malformed ECDSA signature';
                Exit;
              end;
            end;
            ASig.Alg := AAlg;
            ASig.Flags := fido_assert_flags(a, 0);
            ASig.Counter := fido_assert_sigcount(a, 0);
            Result := True;
            Exit;
          finally
            fido_assert_free(@a);
          end;
        end;
      finally
        pin.Free;
      end;
    finally
      CloseDevice;
    end;
  finally
    GFidoLock.Release;
  end;
end;

initialization
  GFidoLock := TCriticalSection.Create;

finalization
  GFidoLock.Free;

end.
