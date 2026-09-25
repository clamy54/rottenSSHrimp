unit uRdpTransport;

{$mode objfpc}{$H+}

// Transport RDP: un thread par session, FreeRDP confine avec
// uFreeRdpApi, secrets en memoire seulement, defauts surs.

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, uSecureBytes, uSessionState,
  uRemoteSurface, uRdpClipFiles;

type
  ERdpTransportError = class(Exception);

  TRdpCertDecision = (rcdReject, rcdAcceptOnce, rcdAcceptAndSave);

  TRdpCertInfo = record
    Host: string;
    Port: Integer;
    CommonName: string;
    Subject: string;
    Issuer: string;
    Fingerprint: string;
    OldFingerprint: string;  // selon FreeRDP; la verite reste le magasin du document
    Changed: Boolean;
    Mismatch: Boolean;       // le NOM ne correspond pas
    Gateway: Boolean;
  end;

  TRdpConnectParams = class
  public
    Host: string;
    Port: Integer;
    // Rebond: socket vers le tunnel, certificat sous Host:Port.
    ConnectHost: string;
    ConnectPort: Integer;
    Username: string;
    DomainName: string;
    Password: TSecureBytes;   // possede; efface des la connexion faite
    Width, Height: Integer;
    ColorDepth: Integer;
    VerifyCertificate: Boolean;
    NlaEnabled: Boolean;
    ClipboardText: Boolean;
    DynamicResolution: Boolean;
    AutoReconnect: Boolean;
    MaxReconnectAttempts: Integer;
    GatewayHostname: string;
    GatewayPort: Integer;
    // A renseigner SUR LE THREAD UI: Text Input Services de macOS crashe ailleurs.
    KeyboardKlid: LongWord;
    constructor Create;
    destructor Destroy; override;
    procedure WipeSecrets;
  end;

  TRdpStateEvent = procedure(AState: TRemoteSessionState) of object;
  TRdpErrorEvent = procedure(const AMessage: string) of object;
  TRdpFinishedEvent = procedure of object;
  TRdpPaintEvent = procedure of object;
  TRdpResizeEvent = procedure(AWidth, AHeight: Integer) of object;
  TRdpCertEvent = procedure(const AInfo: TRdpCertInfo;
    var ADecision: TRdpCertDecision) of object;
  // Tous publies sur le thread UI via Queue. AVerdict: 0=inconnu, 1=idem, 2=change.
  TRdpCertLookup = procedure(const AHost: string; APort: Integer;
    const AFingerprint: string; out AVerdict: Integer;
    out AKnownFingerprint: string) of object;
  TRdpCertSave = procedure(const AInfo: TRdpCertInfo) of object;
  TRdpClipboardEvent = procedure(const AText: UnicodeString) of object;
  // Chemins locaux (dossier temporaire) des fichiers arrives du serveur.
  TRdpClipFilesEvent = procedure(const APaths: TStringArray) of object;
  TRdpClipNoteEvent = procedure(const AText: string) of object;
  TRdpReconnectEvent = procedure(const AStatus: string; AActive: Boolean) of object;

  TRdpTransport = class(TThread)
  private
    FParams: TRdpConnectParams;
    FStates: TSessionStateMachine;
    FSurface: TRemoteSurface;

    FContext: Pointer;
    FInstance: Pointer;
    FDisp: Pointer;       // DispClientContext, nil avant negociation du canal
    // Pipeline graphique: le RdpgfxClientContext relie au GDI, et ce que le
    // serveur nous a fait allouer. Les surfaces du bureau sont plafonnees
    // par RemoteSizeAcceptable; ici, le serveur cree autant de surfaces et
    // d'entrees de cache qu'il veut, aux dimensions qu'il veut, et FreeRDP
    // alloue sans compter. On compte, et l'on refuse au-dela d'un budget.
    FGfx: Pointer;
    FGfxGdi: Pointer;   // le rdpGdi relie au pipeline, garde pour le liberer
                        // meme une fois FContext detache par Cleanup
    FGfxOrig: array[0..3] of Pointer;     // rappels d'origine, par slot
    FGfxSurfBytes: array[Word] of Cardinal;  // octets alloues par surfaceId
    FGfxCacheBytes: array[Word] of Cardinal; // octets alloues par cacheSlot
    FGfxSurfTotal, FGfxCacheTotal: Int64;
    FLastSentW, FLastSentH: Integer;

    FCliprdr: Pointer;            // CliprdrClientContext, nil tant qu'absent
    FClipLock: TCriticalSection;  // protege les 3 champs texte + le drapeau
    FClipLocalText: UnicodeString;
    FClipIncoming: UnicodeString;
    FClipAdvertise: Boolean;      // annonce en attente (marshalling UI->worker)
    FClipReqFmt: cuint32;         // format demande au serveur, pour decoder la reponse

    // --- copier-coller de FICHIERS (cliprdr FileContents). Hors annonce et
    // remise a l'UI, tout vit sur les threads du canal, sans verrou.
    FClipFilesFmtId: cuint32;        // id local du format FileGroupDescriptorW
    FClipLocalFiles: TStringArray;   // selection locale annoncee (sous FClipLock)
    FClipServed: TRdpClipFileArray;  // ce que le dernier descripteur a annonce
    FClipServedStream: TFileStream;  // fichier local ouvert cote envoi
    FClipServedIdx: Integer;
    FClipReqIsFiles: Boolean;        // la demande en cours vise le descripteur
    FClipFetch: TRdpClipFileArray;   // rapatriement en cours
    FClipFetchIdx: Integer;
    FClipFetchOff: Int64;
    FClipFetchStream: TFileStream;
    FClipFetchDir: string;           // dossier du lot en cours
    FClipFetchStreamId: cuint32;
    FClipFetchGot: Int64;            // octets recus du lot, pour le plafond
    FClipFetchActive: Boolean;
    FClipTempRoot: string;           // racine temporaire, effacee a la fermeture
    FClipBatchSeq: Integer;
    FClipFetchTops: TStringArray;    // tetes du lot en cours, cote worker
    FClipIncomingFiles: TStringArray;   // remis a l'UI, sous FClipLock
    FClipNotes: TStringList;            // messages vers l'UI, sous FClipLock

    // Reconnexion: drapeaux sous FCtxLock, poses par l'UI, faits par le worker.
    FReconnecting: Boolean;
    FReconnectInhibited: Boolean;  // document verrouille = plus rien
    FWipePwRequested: Boolean;
    FReconnectMsg: string;
    FReconnectActive: Boolean;

    FCertInfo: TRdpCertInfo;
    FCertDecision: TRdpCertDecision;
    FCertEvent: TEvent;
    FCertVerdict: Integer;
    FCertKnownFp: string;

    FErrorMsg: string;
    FStateQ: array of TRemoteSessionState;   // un champ unique sauterait les transitoires
    FStateLock: TCriticalSection;
    FResizeW, FResizeH: Integer;
    FInvalidChainOk: Boolean;   // False = offsets douteux sur CETTE build de FreeRDP
    FLastFullBlitTick: QWord;

    FInputLock: TCriticalSection;
    // Couvre la prise du pointeur et le comptage, PAS l'envoi:
    // freerdp_input_send_* ecrit sur la socket, il part hors lock.
    FCtxLock: TCriticalSection;
    FInputInFlight: Integer;      // sous FCtxLock
    FInputIdle: TEvent;           // signale tant que FInputInFlight = 0
    FPendingResizeW, FPendingResizeH: Integer;
    FResizeWanted: Boolean;
    FResendBudget: Integer;            // nb de renvois restants (protege par FInputLock)
    FLastResendTick: QWord;            // horloge du dernier renvoi (throttle)
    FConfirmedW, FConfirmedH: Integer; // derniere taille confirmee par le serveur

    FOnState: TRdpStateEvent;
    FOnError: TRdpErrorEvent;
    FOnFinished: TRdpFinishedEvent;
    FOnPaint: TRdpPaintEvent;
    FOnResize: TRdpResizeEvent;
    FOnCert: TRdpCertEvent;
    FOnCertLookup: TRdpCertLookup;
    FOnCertSave: TRdpCertSave;
    FOnClipboard: TRdpClipboardEvent;
    FOnClipFiles: TRdpClipFilesEvent;
    FOnClipNote: TRdpClipNoteEvent;
    FOnReconnect: TRdpReconnectEvent;

    procedure PublishState;
    procedure PublishError;
    procedure PublishFinished;
    procedure PublishPaint;
    procedure PublishResize;
    procedure AskCert;
    procedure DoCertLookup;
    procedure DoCertSave;
    procedure PublishClipboard;
    procedure PublishClipboardFiles;
    procedure PublishClipNotes;
    procedure ClipNote(const AText: string);
    procedure ClipServeDescriptor;
    procedure ClipServeFileContents(AMsg: Pointer);
    procedure ClipStartFetch(const AFiles: TRdpClipFileArray);
    procedure ClipFetchAdvance;
    procedure ClipSendRange;
    procedure ClipAbortFetch(const AWhy: string);
    procedure ClipHandleFileResponse(AMsg: Pointer);
    procedure PublishReconnect;
    function TryAutoReconnect: Boolean;
    procedure MaybeWipePassword;
    function InterruptibleWait(AMs: Integer): Boolean;

    procedure ClipAttach(ACliprdr: Pointer);
    procedure ClipMonitorReady;
    procedure ClipDoAdvertise;
    procedure ClipHandleServerFormatList(AMsg: Pointer);
    procedure ClipHandleDataRequest(AFormatId: cuint32);
    procedure ClipHandleServerDataResponse(AMsg: Pointer);

    // TOUJOURS appareille avec EndInput: sinon Cleanup attend un fantome.
    function BeginInput(out AInput: Pointer): Boolean;
    procedure EndInput;

    procedure SetState(ANext: TRemoteSessionState);
    procedure Fail(const AMessage: string);
    function LastErrorText: string;
    function IsAborted: Boolean;   // pour ResolveCancellable (uNetResolve)

    function BuildContext: Boolean;
    procedure ApplySettings;
    function RunSession: Boolean;
    procedure EventLoop;
    procedure FlushGdiPaint;
    procedure BlitFullGdi(AGdi: Pointer);
    procedure NormalizeLayout(AWidth, AHeight: Integer;
      out ASentW, ASentH: Integer);
    procedure GfxAttach(AGdi, AGfx: Pointer);
    procedure GfxDetach;
    procedure SendMonitorLayout(AWidth, AHeight: Integer);
    procedure Cleanup;
  protected
    procedure Execute; override;
  public
    constructor Create(AParams: TRdpConnectParams; ASurface: TRemoteSurface);
    destructor Destroy; override;

    // Tout ce bloc s'appelle depuis le thread UI.
    procedure SendMouse(AFlags: Integer; AX, AY: Integer);
    procedure SendExtendedMouse(AFlags: Integer; AX, AY: Integer);
    procedure SendScancode(AFlags: Integer; ACode: Integer);
    procedure SendUnicode(AFlags: Integer; ACode: Integer);
    procedure SendCtrlAltDel;
    // Etat des verrous (KBD_SYNC_*) du clavier local. Le serveur demarre
    // NumLock eteint et n'apprend rien tout seul: sans cet evenement, le pave
    // numerique envoie Insert, Fin et des fleches, verrou allume ou non.
    procedure SendSynchronize(AFlags: Cardinal);
    procedure RequestResize(AWidth, AHeight: Integer);
    procedure AnnounceLocalClipboard(const AText: UnicodeString);
    procedure AnnounceLocalFiles(const APaths: TStringArray);
    procedure Shutdown;

    function State: TRemoteSessionState;
    function ClipboardTextEnabled: Boolean;

    property Surface: TRemoteSurface read FSurface;
    property OnStateChanged: TRdpStateEvent read FOnState write FOnState;
    property OnError: TRdpErrorEvent read FOnError write FOnError;
    property OnFinished: TRdpFinishedEvent read FOnFinished write FOnFinished;
    property OnPaint: TRdpPaintEvent read FOnPaint write FOnPaint;
    property OnResized: TRdpResizeEvent read FOnResize write FOnResize;
    property OnCertificate: TRdpCertEvent read FOnCert write FOnCert;
    property OnCertLookup: TRdpCertLookup read FOnCertLookup write FOnCertLookup;
    property OnCertSave: TRdpCertSave read FOnCertSave write FOnCertSave;
    property OnClipboardText: TRdpClipboardEvent read FOnClipboard
      write FOnClipboard;
    property OnClipboardFiles: TRdpClipFilesEvent read FOnClipFiles
      write FOnClipFiles;
    property OnClipNote: TRdpClipNoteEvent read FOnClipNote
      write FOnClipNote;
    property OnReconnect: TRdpReconnectEvent read FOnReconnect write FOnReconnect;
    procedure InhibitReconnect;   // definitif, pas de retour en arriere
  end;

implementation

uses
  Math, uFreeRdpApi, uAppPaths, uLog, uNetResolve;

{$IFDEF WINDOWS}
function SetEnvironmentVariableA(lpName, lpValue: PAnsiChar): LongBool;
  stdcall; external 'kernel32.dll';
function crt_putenv_s(const AName, AValue: PAnsiChar): cint; cdecl;
  external 'ucrtbase.dll' name '_putenv_s';
function GetKeyboardLayoutNameA(AName: PAnsiChar): LongBool;
  stdcall; external 'user32.dll';
function GetKeyboardLayout(AThread: LongWord): PtrUInt;
  stdcall; external 'user32.dll';
function RegisterClipboardFormatW(AName: PWideChar): LongWord;
  stdcall; external 'user32.dll';
{$ENDIF}

const
  // Nom OBLIGE du format de fichiers du presse-papiers; l'id, lui, est local.
  CLIP_FILES_FMT: AnsiString = 'FileGroupDescriptorW';
  // Un serveur peut demander la taille qu'il veut: on borne ce qu'on alloue.
  RDPCLIP_SERVE_MAX = 4 * 1024 * 1024;
  FA_SYMLINK_ = $0400;   // faSymLink, sans l'avertissement de portabilite

  FULL_BLIT_MIN_MS = 50;   // plancher entre deux recopies integrales
  EP_BUF_BYTES = 512;   // couvre les deux tailles d'entry points, shim ou non

  EVENT_POLL_MS = 100;
  RESIZE_RESEND_MS = 250;
  RESIZE_RESEND_MAX = 32;   // ~8s, puis repli sur les scrollbars
  CERT_ANSWER_TIMEOUT_MS = 5 * 60 * 1000;

  RECONNECT_BASE_MS = 1500;
  RECONNECT_MAX_MS = 8000;
  RECONNECT_MAX_ATTEMPTS = 3;   // un MAXIMUM, pas un objectif

  // au-dela, Cleanup abandonne le contexte: fuir vaut mieux qu'un use-after-free
  INPUT_DRAIN_MS = 10000;

  MAX_CLIP_INCOMING_BYTES = 4 * 1024 * 1024;

  SC_CTRL = $1D;
  SC_ALT = $38;
  SC_DELETE = $53;

function TransportOf(AContext: Pointer): TRdpTransport;
begin
  if AContext = nil then
    Exit(nil);
  // MEME source de verite que BuildContext, sinon adresse inventee
  Result := TRdpTransport(PPointer(PByte(AContext) + RdpContextSizeBytes)^);
end;

function TransportOfInstance(AInstance: Pointer): TRdpTransport;
begin
  if AInstance = nil then
    Exit(nil);
  Result := TransportOf(RdpContextOf(AInstance));
end;

// Tous les Cb* tournent sur le WORKER et aucune exception ne franchit la frontiere
// C: d'ou les try vides. Cablage dans CbPostConnect, qui rejoue.
function CbBeginPaint(context: PRdpContext): cint; cdecl; forward;
function CbEndPaint(context: PRdpContext): cint; cdecl; forward;
function CbDesktopResize(context: PRdpContext): cint; cdecl; forward;

const
  // Budgets du pipeline graphique, en OCTETS tels que FreeRDP les alloue:
  // deux bureaux au plafond pour les surfaces, autant pour le cache. Un
  // serveur legitime travaille avec une ou deux surfaces de la taille du
  // bureau et un cache de tuiles bien plus petit; au-dela, c'est un serveur
  // qui veut la memoire.
  GFX_SURFACE_BUDGET_BYTES = Int64(2) * REMOTE_MAX_PIXELS * 4;
  GFX_CACHE_BUDGET_BYTES = Int64(2) * REMOTE_MAX_PIXELS * 4;
  CHANNEL_RC_NO_MEMORY = 12;

// Ce que FreeRDP alloue reellement: une surface a ses deux dimensions
// arrondies a 16, une entree de cache a sa ligne arrondie a 16 octets.
// Compter des pixels sous-estimait: 1 x 8192 fait 32 Kio de pixels et
// 128 Kio de lignes.
function GfxSurfaceBytes(AW, AH: Integer): Int64;
begin
  Result := Int64((AW + 15) and (not 15)) * 4 * Int64((AH + 15) and (not 15));
end;

function GfxCacheBytes(AW, AH: Integer): Int64;
begin
  Result := Int64((AW * 4 + 15) and (not 15)) * Int64(AH);
end;

// Une surface n'est pas un bureau: pas de minimum, seulement les plafonds.
function GfxSurfaceSizeAcceptable(AW, AH: Integer): Boolean;
begin
  Result := (AW > 0) and (AH > 0) and (AW <= REMOTE_MAX_WIDTH) and
    (AH <= REMOTE_MAX_HEIGHT) and (Int64(AW) * Int64(AH) <= REMOTE_MAX_PIXELS);
end;

// Les quatre rappels rdpgfx enveloppes. Ils tournent sur le thread du canal
// dynamique, jamais en meme temps que l'init/uninit du pipeline, qui se font
// sur la boucle d'evenements avec le canal ferme.
function GfxTransport(AGfx: Pointer): TRdpTransport;
begin
  Result := TransportOf(GfxRdpContext(AGfx));
end;

// RDPGFX_CREATE_SURFACE_PDU: surfaceId u16, width u16, height u16, format u8
function CbGfxCreateSurface(gfx, pdu: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
  orig: TGfxPduFn;
  id, w, h: Word;
  px, total: Int64;
begin
  Result := CHANNEL_RC_NO_MEMORY;
  try
    t := GfxTransport(gfx);
    if (t = nil) or (pdu = nil) then Exit;
    orig := TGfxPduFn(t.FGfxOrig[GFX_SLOT_CREATE_SURFACE]);
    if orig = nil then Exit;
    id := PWord(pdu)^;
    w := PWord(PByte(pdu) + 2)^;
    h := PWord(PByte(pdu) + 4)^;
    px := GfxSurfaceBytes(w, h);
    total := t.FGfxSurfTotal - t.FGfxSurfBytes[id] + px;
    if (not GfxSurfaceSizeAcceptable(w, h)) or
       (total > GFX_SURFACE_BUDGET_BYTES) then
    begin
      LogError(Format('rdp: surface %d refused (%dx%d, %d MiB already ' +
        'allocated): graphics budget exceeded, session closed',
        [id, w, h, t.FGfxSurfTotal shr 20]));
      Exit;
    end;
    Result := orig(gfx, pdu);
    if Result = CHANNEL_RC_OK then
    begin
      t.FGfxSurfTotal := total;
      t.FGfxSurfBytes[id] := px;
      LogDebug(Format('rdp: surface %d created (%dx%d), %d MiB of surfaces',
        [id, w, h, total shr 20]));
    end;
  except
    Result := CHANNEL_RC_NO_MEMORY;
  end;
end;

// RDPGFX_DELETE_SURFACE_PDU: surfaceId u16
function CbGfxDeleteSurface(gfx, pdu: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
  orig: TGfxPduFn;
  id: Word;
begin
  Result := CHANNEL_RC_NO_MEMORY;
  try
    t := GfxTransport(gfx);
    if (t = nil) or (pdu = nil) then Exit;
    orig := TGfxPduFn(t.FGfxOrig[GFX_SLOT_DELETE_SURFACE]);
    if orig = nil then Exit;
    Result := orig(gfx, pdu);
    id := PWord(pdu)^;
    t.FGfxSurfTotal := t.FGfxSurfTotal - t.FGfxSurfBytes[id];
    t.FGfxSurfBytes[id] := 0;
  except
    Result := CHANNEL_RC_NO_MEMORY;
  end;
end;

// RDPGFX_SURFACE_TO_CACHE_PDU: surfaceId u16, cacheKey u64 (aligne a 8),
// cacheSlot u16, rectSrc {left, top, right, bottom} u16
function CbGfxSurfaceToCache(gfx, pdu: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
  orig: TGfxPduFn;
  slot, l, tp, r, b: Word;
  px, total: Int64;
begin
  Result := CHANNEL_RC_NO_MEMORY;
  try
    t := GfxTransport(gfx);
    if (t = nil) or (pdu = nil) then Exit;
    orig := TGfxPduFn(t.FGfxOrig[GFX_SLOT_SURFACE_TO_CACHE]);
    if orig = nil then Exit;
    slot := PWord(PByte(pdu) + 16)^;
    l := PWord(PByte(pdu) + 18)^;
    tp := PWord(PByte(pdu) + 20)^;
    r := PWord(PByte(pdu) + 22)^;
    b := PWord(PByte(pdu) + 24)^;
    px := 0;
    if (r > l) and (b > tp) then
      px := GfxCacheBytes(r - l, b - tp);
    total := t.FGfxCacheTotal - t.FGfxCacheBytes[slot] + px;
    if total > GFX_CACHE_BUDGET_BYTES then
    begin
      LogError(Format('rdp: cache slot %d refused (%d MiB already cached): ' +
        'graphics budget exceeded, session closed',
        [slot, t.FGfxCacheTotal shr 20]));
      Exit;
    end;
    Result := orig(gfx, pdu);
    if Result = CHANNEL_RC_OK then
    begin
      t.FGfxCacheTotal := total;
      t.FGfxCacheBytes[slot] := px;
    end;
  except
    Result := CHANNEL_RC_NO_MEMORY;
  end;
end;

// RDPGFX_EVICT_CACHE_ENTRY_PDU: cacheSlot u16
function CbGfxEvictCacheEntry(gfx, pdu: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
  orig: TGfxPduFn;
  slot: Word;
begin
  Result := CHANNEL_RC_NO_MEMORY;
  try
    t := GfxTransport(gfx);
    if (t = nil) or (pdu = nil) then Exit;
    orig := TGfxPduFn(t.FGfxOrig[GFX_SLOT_EVICT_CACHE_ENTRY]);
    if orig = nil then Exit;
    Result := orig(gfx, pdu);
    slot := PWord(pdu)^;
    t.FGfxCacheTotal := t.FGfxCacheTotal - t.FGfxCacheBytes[slot];
    t.FGfxCacheBytes[slot] := 0;
  except
    Result := CHANNEL_RC_NO_MEMORY;
  end;
end;

procedure TRdpTransport.GfxAttach(AGdi, AGfx: Pointer);
begin
  if (AGfx = nil) or (AGdi = nil) then Exit;
  if FGfx <> nil then GfxDetach;
  // sans ce pont, un RDS moderne peint dans des surfaces qu'on ne lit pas.
  // Un echec (codecs non prepares) laisse le contexte a moitie monte, verrous
  // compris: rien a publier, rien a liberer plus tard, et la session ne peut
  // pas continuer, le serveur va peindre dans le vide. On l'arrete net.
  if gdi_graphics_pipeline_init(AGdi, AGfx) = 0 then
  begin
    Fail('Cannot initialise the RDP graphics pipeline (codecs), ' +
      'session closed.');
    if FContext <> nil then
      freerdp_abort_connect_context(FContext);
    Exit;
  end;
  FGfx := AGfx;
  FGfxGdi := AGdi;
  FillChar(FGfxSurfBytes, SizeOf(FGfxSurfBytes), 0);
  FillChar(FGfxCacheBytes, SizeOf(FGfxCacheBytes), 0);
  FGfxSurfTotal := 0;
  FGfxCacheTotal := 0;
  // les rappels du GDI restent derriere les notres, qui ne font que compter
  FGfxOrig[GFX_SLOT_CREATE_SURFACE] :=
    Pointer(GfxHandler(AGfx, GFX_SLOT_CREATE_SURFACE));
  FGfxOrig[GFX_SLOT_DELETE_SURFACE] :=
    Pointer(GfxHandler(AGfx, GFX_SLOT_DELETE_SURFACE));
  FGfxOrig[GFX_SLOT_SURFACE_TO_CACHE] :=
    Pointer(GfxHandler(AGfx, GFX_SLOT_SURFACE_TO_CACHE));
  FGfxOrig[GFX_SLOT_EVICT_CACHE_ENTRY] :=
    Pointer(GfxHandler(AGfx, GFX_SLOT_EVICT_CACHE_ENTRY));
  if (FGfxOrig[0] = nil) or (FGfxOrig[1] = nil) or (FGfxOrig[2] = nil) or
     (FGfxOrig[3] = nil) then
  begin
    // pas de rappel a envelopper: on ne saurait pas compter, on ne triche pas
    LogError('rdp: graphics pipeline callbacks not found, no memory guard');
    Exit;
  end;
  GfxSetHandler(AGfx, GFX_SLOT_CREATE_SURFACE, @CbGfxCreateSurface);
  GfxSetHandler(AGfx, GFX_SLOT_DELETE_SURFACE, @CbGfxDeleteSurface);
  GfxSetHandler(AGfx, GFX_SLOT_SURFACE_TO_CACHE, @CbGfxSurfaceToCache);
  GfxSetHandler(AGfx, GFX_SLOT_EVICT_CACHE_ENTRY, @CbGfxEvictCacheEntry);
end;

// A la fermeture du canal comme a la deconnexion: gdi_free ne libere pas ce
// que le pipeline a ouvert (codecs, surfaces, cache, verrous).
// Sur le rdpGdi garde a l'attache, pas sur FContext: Cleanup detache
// FContext AVANT freerdp_disconnect, qui est justement le moment ou le
// canal se ferme et ou cette liberation doit avoir lieu.
procedure TRdpTransport.GfxDetach;
begin
  if FGfx = nil then Exit;
  LogDebug(Format('rdp: graphics pipeline closed (%d MiB of surfaces, ' +
    '%d MiB cached at the end)', [FGfxSurfTotal shr 20,
    FGfxCacheTotal shr 20]));
  if FGfxGdi <> nil then
    gdi_graphics_pipeline_uninit(FGfxGdi, FGfx);
  FGfx := nil;
  FGfxGdi := nil;
  FGfxSurfTotal := 0;
  FGfxCacheTotal := 0;
end;

procedure CbChannelConnected(context: PRdpContext; e: Pointer); cdecl;
var
  t: TRdpTransport;
  name: PAnsiChar;
  nm: string;
begin
  try
    if e = nil then
      Exit;
    name := ChanEvtName(e);
    if name = nil then
      Exit;
    t := TransportOf(context);
    if t = nil then
      Exit;
    nm := string(AnsiString(name));
    if nm = DISP_DVC_NAME then
      t.FDisp := ChanEvtInterface(e)
    else if nm = CLIPRDR_SVC_NAME then
      t.ClipAttach(ChanEvtInterface(e))
    else if nm = RDPGFX_DVC_NAME then
      t.GfxAttach(CtxGdi(context), ChanEvtInterface(e));
  except
  end;
end;

// ChannelDisconnectedEventArgs a la meme forme (name, pInterface).
procedure CbChannelDisconnected(context: PRdpContext; e: Pointer); cdecl;
var
  t: TRdpTransport;
  name: PAnsiChar;
  nm: string;
begin
  try
    if e = nil then
      Exit;
    name := ChanEvtName(e);
    if name = nil then
      Exit;
    t := TransportOf(context);
    if t = nil then
      Exit;
    nm := string(AnsiString(name));
    if nm = DISP_DVC_NAME then
      t.FDisp := nil
    else if nm = RDPGFX_DVC_NAME then
      t.GfxDetach;
  except
  end;
end;

function CbPreConnect(instance: PFreeRdp): cint; cdecl;
var
  ctx, pubSub: Pointer;
begin
  Result := 1;
  try
    ctx := RdpContextOf(instance);
    pubSub := CtxPubSub(ctx);
    if pubSub <> nil then
    begin
      PubSub_Subscribe(pubSub, 'ChannelConnected',
        Pointer(@CbChannelConnected));
      PubSub_Subscribe(pubSub, 'ChannelDisconnected',
        Pointer(@CbChannelDisconnected));
    end;
    if Assigned(freerdp_client_load_addins) then
      freerdp_client_load_addins(CtxChannels(ctx), CtxSettings(ctx));
  except
  end;
end;

function CbPostConnect(instance: PFreeRdp): cint; cdecl;
var
  t: TRdpTransport;
  ctx: Pointer;
  gdi: Pointer;
  upd: Pointer;
begin
  Result := 0;
  try
    t := TransportOfInstance(instance);
    if t = nil then
      Exit;
    ctx := RdpContextOf(instance);
    // taille du SERVEUR, controlee AVANT gdi_init qui allouerait ses w*h*4
    if not RemoteSizeAcceptable(
         Integer(freerdp_settings_get_uint32(CtxSettings(ctx),
           FreeRDP_DesktopWidth)),
         Integer(freerdp_settings_get_uint32(CtxSettings(ctx),
           FreeRDP_DesktopHeight))) then
    begin
      t.Fail('RDP: the negotiated desktop size is out of bounds.');
      Exit;
    end;
    if gdi_init(instance, PIXEL_FORMAT_BGRX32) = 0 then
      Exit;
    gdi := CtxGdi(ctx);
    if gdi = nil then
      Exit;
    if not GdiLayoutValid(gdi,
         Integer(freerdp_settings_get_uint32(CtxSettings(ctx),
           FreeRDP_DesktopWidth)),
         Integer(freerdp_settings_get_uint32(CtxSettings(ctx),
           FreeRDP_DesktopHeight))) then
    begin
      t.Fail('FreeRDP: unexpected memory layout (GDI), RDP disabled. ' +
        'Report this with your distribution and FreeRDP version.');
      Exit;
    end;
    t.FSurface.Resize(GdiWidth(gdi), GdiHeight(gdi));
    t.FResizeW := GdiWidth(gdi);
    t.FResizeH := GdiHeight(gdi);
    t.Queue(@t.PublishResize);
    t.FInvalidChainOk := GdiInvalidChainValid(gdi);
    if not t.FInvalidChainOk then
      LogError('rdp: invalid-region layout not recognised, ' +
        'falling back to full-frame copy (slower but correct)');
    upd := CtxUpdate(ctx);
    if UpdateLayoutValid(ctx, upd) then   // on va y ECRIRE des pointeurs de fonction
    begin
      if t.FInvalidChainOk then
        UpdSetBeginPaint(upd, @CbBeginPaint);
      UpdSetEndPaint(upd, @CbEndPaint);
      UpdSetDesktopResize(upd, @CbDesktopResize);
    end
    else
      LogError('rdp: unexpected memory layout (update), ' +
        'paint callbacks not installed');
    Result := 1;
  except
    Result := 0;
  end;
end;

procedure CbPostDisconnect(instance: PFreeRdp); cdecl;
var
  ctx: Pointer;
  t: TRdpTransport;
begin
  try
    if instance = nil then
      Exit;
    ctx := RdpContextOf(instance);
    // le pipeline avant le GDI: l'inverse laisserait ses codecs derriere
    t := TransportOf(ctx);
    if t <> nil then
      t.GfxDetach;
    if (ctx <> nil) and (CtxGdi(ctx) <> nil) then
      gdi_free(instance);
  except
  end;
end;

function CbBeginPaint(context: PRdpContext): cint; cdecl;
begin
  Result := 1;
  try
    GdiResetInvalid(CtxGdi(context));   // on remplace gdi_begin_paint
  except
  end;
end;

function CbEndPaint(context: PRdpContext): cint; cdecl;
var
  t: TRdpTransport;
  gdi: Pointer;
  x, y, w, h: Integer;
begin
  Result := 1;
  try
    t := TransportOf(context);
    if t = nil then
      Exit;
    gdi := CtxGdi(context);
    if gdi = nil then
      Exit;
    if t.FInvalidChainOk then
    begin
      if not GdiTakeInvalid(gdi, x, y, w, h) then
        Exit;
      t.FSurface.BlitFrom(GdiPrimaryBuffer(gdi), GdiStride(gdi), x, y, w, h);
    end
    else
      t.BlitFullGdi(gdi);
    t.Queue(@t.PublishPaint);
  except
  end;
end;

function CbDesktopResize(context: PRdpContext): cint; cdecl;
var
  t: TRdpTransport;
  gdi: Pointer;
  w, h: cuint32;
begin
  Result := 0;
  try
    t := TransportOf(context);
    if t = nil then
      Exit;
    w := freerdp_settings_get_uint32(CtxSettings(context), FreeRDP_DesktopWidth);
    h := freerdp_settings_get_uint32(CtxSettings(context), FreeRDP_DesktopHeight);
    LogDebug(Format('rdp desktop resize recu: %dx%d', [w, h]));
    // meme garde avant gdi_resize: ecreter PUIS le predicat,
    // 8192x8192 passe l'ecretage et pese encore 256 Mio
    if w > cuint32(REMOTE_MAX_WIDTH) then w := REMOTE_MAX_WIDTH;
    if h > cuint32(REMOTE_MAX_HEIGHT) then h := REMOTE_MAX_HEIGHT;
    if not RemoteSizeAcceptable(Integer(w), Integer(h)) then
    begin
      LogError(Format('rdp: desktop resize refuse: %dx%d', [w, h]));
      Exit;
    end;
    gdi := CtxGdi(context);
    if gdi = nil then
      Exit;
    if gdi_resize(gdi, w, h) = 0 then
      Exit;
    t.FSurface.Resize(w, h);
    t.FResizeW := w;
    t.FResizeH := h;
    t.FConfirmedW := w;   // meme thread que la boucle: pas de verrou
    t.FConfirmedH := h;
    t.Queue(@t.PublishResize);
    Result := 1;
  except
    Result := 0;
  end;
end;

function DoVerifyCertificate(instance: PFreeRdp; host: PAnsiChar;
  port: cuint16; common_name, subject, issuer, fingerprint: PAnsiChar;
  const AOldFingerprint: string; flags: cuint32): cuint32;
var
  t: TRdpTransport;
  waited: Integer;
begin
  Result := CERT_REJECT;
  try
    t := TransportOfInstance(instance);
    if t = nil then
      Exit;

    t.FCertInfo := Default(TRdpCertInfo);
    if t.FParams.ConnectHost <> '' then
    begin
      t.FCertInfo.Host := t.FParams.Host;
      t.FCertInfo.Port := t.FParams.Port;
    end
    else
    begin
      t.FCertInfo.Host := string(AnsiString(host));
      t.FCertInfo.Port := port;
    end;
    t.FCertInfo.CommonName := string(AnsiString(common_name));
    t.FCertInfo.Subject := string(AnsiString(subject));
    t.FCertInfo.Issuer := string(AnsiString(issuer));
    t.FCertInfo.Fingerprint := string(AnsiString(fingerprint));
    t.FCertInfo.OldFingerprint := AOldFingerprint;
    t.FCertInfo.Mismatch := (flags and VERIFY_CERT_FLAG_MISMATCH) <> 0;
    t.FCertInfo.Gateway := (flags and VERIFY_CERT_FLAG_GATEWAY) <> 0;

    t.FCertVerdict := 0;
    t.FCertKnownFp := '';
    t.Synchronize(@t.DoCertLookup);

    if t.FCertVerdict = 1 then
    begin
      Exit(CERT_ACCEPT_TEMPORARY);
    end;

    t.FCertInfo.Changed := t.FCertVerdict = 2;

    t.FCertDecision := rcdReject;
    t.FCertEvent.ResetEvent;
    t.Queue(@t.AskCert);
    waited := 0;
    while (t.FCertEvent.WaitFor(200) = wrTimeout) and (not t.Terminated) do
    begin
      Inc(waited, 200);
      if waited >= CERT_ANSWER_TIMEOUT_MS then
        Break;
    end;
    if t.Terminated then
      Exit(CERT_REJECT);

    case t.FCertDecision of
      rcdAcceptOnce:
        Result := CERT_ACCEPT_TEMPORARY;
      rcdAcceptAndSave:
        begin
          t.Synchronize(@t.DoCertSave);
          Result := CERT_ACCEPT_TEMPORARY;   // NOTRE magasin persiste, pas celui de FreeRDP
        end;
    else
      Result := CERT_REJECT;
    end;
  except
    Result := CERT_REJECT;
  end;
end;

function CbVerifyCertificateEx(instance: PFreeRdp; host: PAnsiChar;
  port: cuint16; common_name, subject, issuer, fingerprint: PAnsiChar;
  flags: cuint32): cuint32; cdecl;
begin
  Result := DoVerifyCertificate(instance, host, port, common_name, subject,
    issuer, fingerprint, '', flags);
end;

// ONZE arguments: FreeRDP glisse old_subject/old_issuer/old_fingerprint avant flags.
function CbVerifyChangedCertificateEx(instance: PFreeRdp; host: PAnsiChar;
  port: cuint16; common_name, subject, issuer, new_fingerprint, old_subject,
  old_issuer, old_fingerprint: PAnsiChar; flags: cuint32): cuint32; cdecl;
begin
  Result := DoVerifyCertificate(instance, host, port, common_name, subject,
    issuer, new_fingerprint, string(AnsiString(old_fingerprint)), flags);
end;

function CbClientNew(instance: PFreeRdp; context: PRdpContext): cint; cdecl;
begin
  // vide expres: appele avant qu'aucun offset ait pu etre valide, BuildContext suit
  Result := 1;
end;

procedure CbClientFree(instance: PFreeRdp; context: PRdpContext); cdecl;
begin
end;

// cliprdr serveur->client, worker; toujours CHANNEL_RC_OK ou FreeRDP demonte le canal.

function CbClipMonitorReady(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
begin
  Result := CHANNEL_RC_OK;
  try
    t := TRdpTransport(CliprdrCustom(context));
    if t <> nil then
      t.ClipMonitorReady;
  except
  end;
end;

function CbClipServerCaps(context: Pointer; msg: Pointer): cuint32; cdecl;
begin
  Result := CHANNEL_RC_OK;
end;

function CbClipServerFormatList(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
begin
  Result := CHANNEL_RC_OK;
  try
    t := TRdpTransport(CliprdrCustom(context));
    if t <> nil then
      t.ClipHandleServerFormatList(msg);
  except
  end;
end;

function CbClipServerFormatListResp(context: Pointer; msg: Pointer): cuint32; cdecl;
begin
  Result := CHANNEL_RC_OK;
end;

function CbClipServerDataRequest(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
  req: PCliprdrFormatDataRequest;
begin
  Result := CHANNEL_RC_OK;
  try
    t := TRdpTransport(CliprdrCustom(context));
    if (t <> nil) and (msg <> nil) then
    begin
      req := PCliprdrFormatDataRequest(msg);
      t.ClipHandleDataRequest(req^.requestedFormatId);
    end;
  except
  end;
end;

function CbClipServerFileReq(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
begin
  Result := 0;   // CHANNEL_RC_OK, toujours: une erreur demonterait le canal
  try
    t := TRdpTransport(CliprdrCustom(context));
    if (t <> nil) and (msg <> nil) then
      t.ClipServeFileContents(msg);
  except
  end;
end;

function CbClipServerFileResp(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
begin
  Result := 0;
  try
    t := TRdpTransport(CliprdrCustom(context));
    if (t <> nil) and (msg <> nil) then
      t.ClipHandleFileResponse(msg);
  except
  end;
end;

function CbClipServerDataResponse(context: Pointer; msg: Pointer): cuint32; cdecl;
var
  t: TRdpTransport;
begin
  Result := CHANNEL_RC_OK;
  try
    t := TRdpTransport(CliprdrCustom(context));
    if t <> nil then
      t.ClipHandleServerDataResponse(msg);
  except
  end;
end;

{ TRdpConnectParams }

constructor TRdpConnectParams.Create;
begin
  inherited Create;
  Port := 3389;
  Width := 1280;
  Height := 800;
  ColorDepth := 32;
  // disques, imprimantes et audio n'ont meme pas de champ. Pas de
  // champ, pas d'activation par megarde.
  VerifyCertificate := True;
  NlaEnabled := True;
  ClipboardText := True;
  DynamicResolution := True;
  AutoReconnect := True;
  MaxReconnectAttempts := 3;
  GatewayPort := 443;
end;

procedure TRdpConnectParams.WipeSecrets;
begin
  FreeAndNil(Password);
end;

destructor TRdpConnectParams.Destroy;
begin
  WipeSecrets;
  inherited Destroy;
end;

{ TRdpTransport }

constructor TRdpTransport.Create(AParams: TRdpConnectParams;
  ASurface: TRemoteSurface);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FParams := AParams;
  FSurface := ASurface;
  FStates := TSessionStateMachine.Create;
  FInputLock := TCriticalSection.Create;
  FCtxLock := TCriticalSection.Create;
  FStateLock := TCriticalSection.Create;
  FClipLock := TCriticalSection.Create;
  FCertEvent := TEvent.Create(nil, True, False, '');
  FInputIdle := TEvent.Create(nil, True, True, '');   // manuel, SIGNALE au depart
  FClipNotes := TStringList.Create;
  FClipServedIdx := -1;
end;

// Efface un arbre A NOUS (temporaire du presse-papiers) sans jamais suivre un
// lien: un lien part seul, sa cible reste.
procedure ClipRemoveTree(const APath: string);
var
  sr: TSearchRec;
begin
  if FindFirst(APath + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    try
      repeat
        if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = '') then
          Continue;
        if (sr.Attr and FA_SYMLINK_) <> 0 then
        begin
          if (sr.Attr and faDirectory) <> 0 then
            RemoveDir(APath + PathDelim + sr.Name)
          else
            SysUtils.DeleteFile(APath + PathDelim + sr.Name);
        end
        else if (sr.Attr and faDirectory) <> 0 then
          ClipRemoveTree(APath + PathDelim + sr.Name)
        else
          SysUtils.DeleteFile(APath + PathDelim + sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
  end;
  RemoveDir(APath);
end;

destructor TRdpTransport.Destroy;
begin
  inherited Destroy;   // joint le thread (donc Cleanup a deja draine)
  FreeAndNil(FClipFetchStream);
  FreeAndNil(FClipServedStream);
  // Les fichiers rapatries meurent avec l'onglet: un collage doit se faire
  // pendant que la session existe, comme le texte.
  if FClipTempRoot <> '' then
    ClipRemoveTree(FClipTempRoot);
  FClipNotes.Free;
  FInputIdle.Free;
  FCertEvent.Free;
  FClipLock.Free;
  FStateLock.Free;
  FCtxLock.Free;
  FInputLock.Free;
  FStates.Free;
  FParams.Free;
end;

function TRdpTransport.State: TRemoteSessionState;
begin
  Result := FStates.State;
end;

function TRdpTransport.ClipboardTextEnabled: Boolean;
begin
  Result := (FParams <> nil) and FParams.ClipboardText;   // fixe: lecture UI sans verrou
end;

procedure TRdpTransport.SetState(ANext: TRemoteSessionState);
begin
  if not FStates.TryTransitionTo(ANext) then
    Exit;
  if not Assigned(FOnState) then
    Exit;
  FStateLock.Acquire;
  try
    SetLength(FStateQ, Length(FStateQ) + 1);
    FStateQ[High(FStateQ)] := ANext;
  finally
    FStateLock.Release;
  end;
  Queue(@PublishState);
end;

procedure TRdpTransport.PublishState;
var
  st: TRemoteSessionState;
  has: Boolean;
begin
  FStateLock.Acquire;
  try
    has := Length(FStateQ) > 0;
    if has then
    begin
      st := FStateQ[0];
      Delete(FStateQ, 0, 1);   // une entree par Queue, dans l'ordre
    end;
  finally
    FStateLock.Release;
  end;
  if has and Assigned(FOnState) then
    FOnState(st);
end;

procedure TRdpTransport.PublishError;
var
  msg: string;
begin
  // instantane sous verrou: chaine MANAGEE, son refcount ne se touche pas a deux
  FCtxLock.Acquire;
  try
    msg := FErrorMsg;
  finally
    FCtxLock.Release;
  end;
  if Assigned(FOnError) then
    FOnError(msg);
end;

procedure TRdpTransport.PublishFinished;
begin
  if Assigned(FOnFinished) then
    FOnFinished();
end;

procedure TRdpTransport.PublishPaint;
begin
  if Assigned(FOnPaint) then
    FOnPaint();
end;

procedure TRdpTransport.PublishResize;
begin
  if Assigned(FOnResize) then
    FOnResize(FResizeW, FResizeH);
end;

// FOnCert doit rester MODAL: sa boucle imbriquee vide QueueAsyncCall, sinon le
// SetEvent plus bas tombe sur un FCertEvent deja libere.
procedure TRdpTransport.AskCert;
begin
  try
    if Assigned(FOnCert) then
      FOnCert(FCertInfo, FCertDecision)
    else
      FCertDecision := rcdReject;
  finally
    FCertEvent.SetEvent;
  end;
end;

procedure TRdpTransport.DoCertLookup;
begin
  if Assigned(FOnCertLookup) then
    FOnCertLookup(FCertInfo.Host, FCertInfo.Port, FCertInfo.Fingerprint,
      FCertVerdict, FCertKnownFp);
end;

procedure TRdpTransport.DoCertSave;
begin
  if Assigned(FOnCertSave) then
    FOnCertSave(FCertInfo);
end;

procedure TRdpTransport.PublishClipboard;
var
  s: UnicodeString;
begin
  FClipLock.Acquire;
  try
    s := FClipIncoming;
  finally
    FClipLock.Release;
  end;
  if (s <> '') and Assigned(FOnClipboard) then
    FOnClipboard(s);
end;

procedure TRdpTransport.PublishReconnect;
var
  msg: string;
  active: Boolean;
begin
  FCtxLock.Acquire;
  try
    msg := FReconnectMsg;
    active := FReconnectActive;
  finally
    FCtxLock.Release;
  end;
  if Assigned(FOnReconnect) then
    FOnReconnect(msg, active);
end;

function TRdpTransport.InterruptibleWait(AMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while waited < AMs do
  begin
    if Terminated then Exit(False);
    Sleep(100);
    Inc(waited, 100);
  end;
  Result := not Terminated;
end;

procedure TRdpTransport.InhibitReconnect;
begin
  FCtxLock.Acquire;
  try
    FReconnectInhibited := True;
    // on DEMANDE le wipe, seul le worker touche aux settings
    FWipePwRequested := True;
  finally
    FCtxLock.Release;
  end;
end;

procedure TRdpTransport.MaybeWipePassword;
begin
  FCtxLock.Acquire;   // worker seulement: FreeRDP lit ces memes settings
  try
    if FWipePwRequested and (FContext <> nil) then
    begin
      freerdp_settings_set_string(CtxSettings(FContext), FreeRDP_Password,
        PAnsiChar(AnsiString('')));
      FWipePwRequested := False;
    end;
  finally
    FCtxLock.Release;
  end;
end;

function TRdpTransport.TryAutoReconnect: Boolean;
var
  attempt, backoff, shift, maxAttempts: Integer;
  ok, inhibited: Boolean;
begin
  Result := False;
  FCtxLock.Acquire;
  try
    inhibited := FReconnectInhibited;
  finally
    FCtxLock.Release;
  end;
  if inhibited then Exit;
  if (FParams = nil) or (not FParams.AutoReconnect) or
     (FParams.MaxReconnectAttempts <= 0) then
    Exit;
  maxAttempts := Min(FParams.MaxReconnectAttempts, RECONNECT_MAX_ATTEMPTS);
  attempt := 0;
  try
    while (not Terminated) and (attempt < maxAttempts) do
    begin
      Inc(attempt);
      FCtxLock.Acquire;
      try
        FReconnectMsg := Format('Reconnecting %d/%d...',
          [attempt, maxAttempts]);
        FReconnectActive := True;
      finally
        FCtxLock.Release;
      end;
      Queue(@PublishReconnect);

      shift := attempt - 1;
      if shift > 20 then shift := 20;
      backoff := Min(RECONNECT_BASE_MS shl shift, RECONNECT_MAX_MS);
      if not InterruptibleWait(backoff) then
        Exit;   // Terminate pendant l'attente

      // relire juste avant l'appel reseau: le document a pu etre verrouille
      FCtxLock.Acquire;
      try
        inhibited := FReconnectInhibited;
      finally
        FCtxLock.Release;
      end;
      if inhibited then Exit;

      FCtxLock.Acquire;
      try
        FReconnecting := True;
      finally
        FCtxLock.Release;
      end;
      ok := (FInstance <> nil) and (freerdp_reconnect(FInstance) <> 0);
      FCtxLock.Acquire;
      try
        FReconnecting := False;
      finally
        FCtxLock.Release;
      end;

      if ok then
      begin
        FCtxLock.Acquire;   // le verrouillage a pu tomber PENDANT le reconnect
        try
          inhibited := FReconnectInhibited;
          if inhibited and (FContext <> nil) then
            freerdp_abort_connect_context(FContext);
        finally
          FCtxLock.Release;
        end;
        if inhibited then Exit(False);

        FCtxLock.Acquire;
        try
          FReconnectMsg := '';
          FReconnectActive := False;
        finally
          FCtxLock.Release;
        end;
        Queue(@PublishReconnect);
        FConfirmedW := 0;   // GDI reconstruit: realigner le bureau sur la fenetre
        FConfirmedH := 0;
        Result := True;
        Exit;
      end;
    end;
  finally
    if not Result then
    begin
      FCtxLock.Acquire;
      try
        FReconnectMsg := '';
        FReconnectActive := False;
      finally
        FCtxLock.Release;
      end;
      Queue(@PublishReconnect);
    end;
  end;
end;

// cliprdr: tout ce bloc tourne sur le worker, seul PublishClipboard
// passe par l'UI.

procedure TRdpTransport.ClipAttach(ACliprdr: Pointer);
begin
  if ACliprdr = nil then
    Exit;
  FCliprdr := ACliprdr;
  CliprdrSetCustom(ACliprdr, Self);   // lien retour lu par les callbacks C
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_MONITOR_READY, @CbClipMonitorReady);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_CAPABILITIES, @CbClipServerCaps);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FORMAT_LIST,
    @CbClipServerFormatList);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FORMAT_LIST_RESPONSE,
    @CbClipServerFormatListResp);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FORMAT_DATA_REQUEST,
    @CbClipServerDataRequest);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FORMAT_DATA_RESPONSE,
    @CbClipServerDataResponse);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FILECONTENTS_REQUEST,
    @CbClipServerFileReq);
  CliprdrSetHandler(ACliprdr, CLIPRDR_OFF_SERVER_FILECONTENTS_RESPONSE,
    @CbClipServerFileResp);
  {$IFDEF WINDOWS}
  // L'id LOCAL du format nomme: le serveur le redonne dans ses demandes.
  FClipFilesFmtId := cuint32(RegisterClipboardFormatW('FileGroupDescriptorW'));
  if FClipFilesFmtId = 0 then
    FClipFilesFmtId := $C004;
  {$ELSE}
  FClipFilesFmtId := $C004;
  {$ENDIF}
end;

procedure TRdpTransport.ClipMonitorReady;
var
  caps: TCliprdrCapabilities;
  genSet: TCliprdrGeneralCapabilitySet;
  fn: TCliprdrFn;
begin
  if FCliprdr = nil then
    Exit;
  FillChar(caps, SizeOf(caps), 0);
  FillChar(genSet, SizeOf(genSet), 0);
  genSet.capabilitySetType := CB_CAPSTYPE_GENERAL;
  genSet.capabilitySetLength := 12;
  genSet.version := CB_CAPS_VERSION_2;
  // FILECLIP_NO_FILE_PATHS: les contenus passent en FLUX, jamais par un
  // chemin CF_HDROP que l'autre bout lirait lui-meme.
  genSet.generalFlags := CB_USE_LONG_FORMAT_NAMES or
    CB_STREAM_FILECLIP_ENABLED or CB_FILECLIP_NO_FILE_PATHS;
  caps.common.msgType := CB_CLIP_CAPS;
  caps.cCapabilitiesSets := 1;
  caps.capabilitySets := @genSet;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_CAPABILITIES);
  if fn <> nil then
    fn(FCliprdr, @caps);
  ClipDoAdvertise;   // annonce ce que l'UI a pu pousser avant la connexion
end;

procedure TRdpTransport.ClipDoAdvertise;
var
  list: TCliprdrFormatList;
  fmts: array[0..0] of TCliprdrFormat;
  hasText, hasFiles: Boolean;
  n: cuint32;
  fn: TCliprdrFn;
begin
  if FCliprdr = nil then
    Exit;
  FClipLock.Acquire;
  try
    hasText := FClipLocalText <> '';
    hasFiles := Length(FClipLocalFiles) > 0;
  finally
    FClipLock.Release;
  end;
  FillChar(fmts, SizeOf(fmts), 0);
  FillChar(list, SizeOf(list), 0);
  n := 0;
  if hasFiles then
  begin
    fmts[0].formatId := FClipFilesFmtId;
    fmts[0].formatName := PAnsiChar(CLIP_FILES_FMT);
    n := 1;
    list.formats := @fmts[0];
  end
  else if hasText then
  begin
    fmts[0].formatId := CF_UNICODETEXT;
    fmts[0].formatName := nil;
    n := 1;
    list.formats := @fmts[0];
  end;
  list.common.msgType := CB_FORMAT_LIST;
  list.numFormats := n;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_LIST);
  if fn <> nil then
    fn(FCliprdr, @list);
end;

procedure TRdpTransport.ClipHandleServerFormatList(AMsg: Pointer);
var
  list: PCliprdrFormatList;
  fmt: PCliprdrFormat;
  i, count: Integer;
  id, chosen: cuint32;
  found, isFiles: Boolean;
  resp: TCliprdrFormatListResponse;
  req: TCliprdrFormatDataRequest;
  fnResp, fnReq: TCliprdrFn;
begin
  if (FCliprdr = nil) or (AMsg = nil) then
    Exit;
  list := PCliprdrFormatList(AMsg);
  // Le serveur a recopie autre chose: ce qui restait a rapatrier est mort.
  if FClipFetchActive then
    ClipAbortFetch('the remote clipboard changed while files were coming ' +
      'over');
  count := list^.numFormats;
  chosen := 0;
  found := False;
  isFiles := False;
  if list^.formats <> nil then
    for i := 0 to count - 1 do
    begin
      fmt := PCliprdrFormat(PByte(list^.formats) + i * SizeOf(TCliprdrFormat));
      id := fmt^.formatId;
      // Des fichiers d'abord: une copie de fichiers annonce souvent AUSSI du
      // texte (les noms), et coller les noms a la place des fichiers surprend.
      if (fmt^.formatName <> nil) and
         SameText(string(AnsiString(fmt^.formatName)),
           string(CLIP_FILES_FMT)) then
      begin
        chosen := id;
        found := True;
        isFiles := True;
        Break;
      end;
      if id = CF_UNICODETEXT then
      begin
        chosen := CF_UNICODETEXT;
        found := True;
      end
      else if (id = CF_TEXT) or (id = CF_OEMTEXT) then
        if not found then
        begin
          chosen := id;
          found := True;
        end;
    end;
  FillChar(resp, SizeOf(resp), 0);
  resp.common.msgType := CB_FORMAT_LIST_RESPONSE;
  resp.common.msgFlags := CB_RESPONSE_OK;
  fnResp := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_LIST_RESPONSE);
  if fnResp <> nil then
    fnResp(FCliprdr, @resp);
  if not found then
    Exit;   // rien d'exploitable: on ne tire pas le contenu
  FClipReqFmt := chosen;   // memorise pour decoder la reponse
  FClipReqIsFiles := isFiles;
  FillChar(req, SizeOf(req), 0);
  req.common.msgType := CB_FORMAT_DATA_REQUEST;
  req.requestedFormatId := chosen;
  fnReq := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_DATA_REQUEST);
  if fnReq <> nil then
    fnReq(FCliprdr, @req);
end;

procedure TRdpTransport.ClipHandleDataRequest(AFormatId: cuint32);
var
  txt: UnicodeString;
  ansi: RawByteString;
  buf: TBytes;
  resp: TCliprdrFormatDataResponse;
  fn: TCliprdrFn;
  isText: Boolean;
begin
  if FCliprdr = nil then
    Exit;
  if AFormatId = FClipFilesFmtId then
  begin
    ClipServeDescriptor;
    Exit;
  end;
  FClipLock.Acquire;
  try
    txt := FClipLocalText;
  finally
    FClipLock.Release;
  end;
  isText := (AFormatId = CF_UNICODETEXT) or (AFormatId = CF_TEXT) or
    (AFormatId = CF_OEMTEXT);
  FillChar(resp, SizeOf(resp), 0);
  resp.common.msgType := CB_FORMAT_DATA_RESPONSE;
  buf := nil;
  if (txt <> '') and isText then
  begin
    if AFormatId = CF_UNICODETEXT then
    begin
      SetLength(buf, (Length(txt) + 1) * 2);   // UTF-16LE + NUL final
      Move(txt[1], buf[0], Length(txt) * 2);
    end
    else
    begin
      ansi := AnsiString(txt);
      SetLength(buf, Length(ansi) + 1);
      if Length(ansi) > 0 then
        Move(ansi[1], buf[0], Length(ansi));
    end;
    resp.common.msgFlags := CB_RESPONSE_OK;
    resp.common.dataLen := Length(buf);
    resp.requestedFormatData := @buf[0];
  end
  else
    resp.common.msgFlags := CB_RESPONSE_FAIL;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE);
  if fn <> nil then
    fn(FCliprdr, @resp);   // buf reste vivant jusqu'ici (serialise dans l'appel)
end;

procedure TRdpTransport.ClipHandleServerDataResponse(AMsg: Pointer);
var
  resp: PCliprdrFormatDataResponse;
  flags: cuint16;
  len: cuint32;
  data: PByte;
  u: UnicodeString;
  a: RawByteString;
  p: Integer;
  wasFiles: Boolean;
  files: TRdpClipFileArray;
  why: string;
begin
  if AMsg = nil then
    Exit;
  resp := PCliprdrFormatDataResponse(AMsg);
  flags := resp^.common.msgFlags;
  len := resp^.common.dataLen;
  data := resp^.requestedFormatData;
  // Remis a zero AVANT les sorties: un refus laisserait le drapeau arme, et
  // la reponse TEXTE suivante serait lue comme un descripteur.
  wasFiles := FClipReqIsFiles;
  FClipReqIsFiles := False;
  if (flags and CB_RESPONSE_OK) = 0 then
    Exit;   // le serveur a refuse
  if (data = nil) or (len = 0) then
    Exit;
  if wasFiles then
  begin
    // Le tronquer fabriquerait un descripteur menteur: refus au-dela du plus
    // grand descripteur legal.
    if len > 4 + LongWord(RDPCLIP_MAX_FILES) * FILEDESC_W_SIZE then
    begin
      ClipNote(Format('The remote file list was refused: more than %d files.',
        [RDPCLIP_MAX_FILES]));
      Exit;
    end;
    if not ParseFileGroupDescriptor(data, len, files, why) then
    begin
      ClipNote('The remote file list was refused: ' + why + '.');
      Exit;
    end;
    ClipStartFetch(files);
    Exit;
  end;
  // dataLen vient du serveur: on tronque au lieu d'allouer sa demande
  if len > MAX_CLIP_INCOMING_BYTES then
    len := MAX_CLIP_INCOMING_BYTES;
  if FClipReqFmt = CF_UNICODETEXT then
  begin
    SetLength(u, len div 2);
    if Length(u) > 0 then
      Move(data^, u[1], Length(u) * 2);
  end
  else
  begin
    SetLength(a, len);
    Move(data^, a[1], len);
    u := UnicodeString(a);
  end;
  p := Pos(#0, u);   // formats texte Windows: NUL-termines
  if p > 0 then
    SetLength(u, p - 1);
  if u = '' then
    Exit;
  FClipLock.Acquire;
  try
    FClipIncoming := u;
  finally
    FClipLock.Release;
  end;
  Queue(@PublishClipboard);
end;

procedure TRdpTransport.PublishClipboardFiles;
var
  paths: TStringArray;
begin
  FClipLock.Acquire;
  try
    paths := FClipIncomingFiles;
    FClipIncomingFiles := nil;
  finally
    FClipLock.Release;
  end;
  if (Length(paths) > 0) and Assigned(FOnClipFiles) then
    FOnClipFiles(paths);
end;

procedure TRdpTransport.PublishClipNotes;
var
  msgs: TStringArray;
  i: Integer;
begin
  FClipLock.Acquire;
  try
    SetLength(msgs{%H-}, FClipNotes.Count);
    for i := 0 to FClipNotes.Count - 1 do
      msgs[i] := FClipNotes[i];
    FClipNotes.Clear;
  finally
    FClipLock.Release;
  end;
  if Assigned(FOnClipNote) then
    for i := 0 to High(msgs) do
      FOnClipNote(msgs[i]);
end;

procedure TRdpTransport.ClipNote(const AText: string);
begin
  FClipLock.Acquire;
  try
    FClipNotes.Add(AText);
  finally
    FClipLock.Release;
  end;
  Queue(@PublishClipNotes);
end;

// Le serveur demande le descripteur: la selection locale s'enumere ICI, au
// moment ou il la veut, et c'est CE tableau -- indices compris -- qui fait
// foi pour toutes les demandes de contenu qui suivent.
procedure TRdpTransport.ClipServeDescriptor;
var
  roots: TStringArray;
  buf: TBytes;
  resp: TCliprdrFormatDataResponse;
  fn: TCliprdrFn;
  why: string;
  ok: Boolean;
begin
  if FCliprdr = nil then
    Exit;
  FClipLock.Acquire;
  try
    roots := FClipLocalFiles;
  finally
    FClipLock.Release;
  end;
  FreeAndNil(FClipServedStream);
  FClipServedIdx := -1;
  buf := nil;
  ok := Length(roots) > 0;
  if ok then
  begin
    ok := EnumerateLocalTree(roots, FClipServed, why);
    if not ok then
    begin
      SetLength(FClipServed, 0);
      ClipNote('The local files could not be offered to the remote ' +
        'desktop: ' + why + '.');
    end;
  end;
  if ok then
    try
      buf := BuildFileGroupDescriptor(FClipServed);
    except
      on EConvertError do
        ok := False;
    end;
  FillChar(resp, SizeOf(resp), 0);
  resp.common.msgType := CB_FORMAT_DATA_RESPONSE;
  if ok then
  begin
    resp.common.msgFlags := CB_RESPONSE_OK;
    resp.common.dataLen := Length(buf);
    resp.requestedFormatData := @buf[0];
  end
  else
    resp.common.msgFlags := CB_RESPONSE_FAIL;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE);
  if fn <> nil then
    fn(FCliprdr, @resp);
end;

// Le serveur veut la taille ou un morceau d'un fichier ANNONCE: seul l'index
// dans le tableau servi designe un fichier, jamais un chemin venu du fil.
procedure TRdpTransport.ClipServeFileContents(AMsg: Pointer);
var
  req: PCliprdrFileContentsRequest;
  buf: TBytes;
  got: Integer;
  size, pos: Int64;
  want: cuint32;

  procedure Respond(AOk: Boolean; ALen: cuint32);
  var
    r: TCliprdrFileContentsResponse;
    fn: TCliprdrFn;
  begin
    FillChar(r, SizeOf(r), 0);
    r.common.msgType := CB_FILECONTENTS_RESPONSE;
    if AOk then
      r.common.msgFlags := CB_RESPONSE_OK
    else
      r.common.msgFlags := CB_RESPONSE_FAIL;
    r.streamId := req^.streamId;
    r.cbRequested := ALen;
    if ALen > 0 then
      r.requestedData := @buf[0];
    fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FILECONTENTS_RESPONSE);
    if fn <> nil then
      fn(FCliprdr, @r);
  end;

begin
  if FCliprdr = nil then
    Exit;
  req := PCliprdrFileContentsRequest(AMsg);
  buf := nil;
  if (Length(FClipServed) = 0) or
     (req^.listIndex >= cuint32(Length(FClipServed))) or
     FClipServed[req^.listIndex].IsDir then
  begin
    Respond(False, 0);
    Exit;
  end;
  try
    if (FClipServedStream = nil) or
       (FClipServedIdx <> Integer(req^.listIndex)) then
    begin
      FreeAndNil(FClipServedStream);
      FClipServedIdx := -1;
      // DenyNone: l'utilisateur garde la main sur ses propres fichiers.
      FClipServedStream := TFileStream.Create(
        FClipServed[req^.listIndex].LocalPath, fmOpenRead or fmShareDenyNone);
      FClipServedIdx := Integer(req^.listIndex);
    end;
    if (req^.dwFlags and FILECONTENTS_SIZE) <> 0 then
    begin
      size := FClipServedStream.Size;
      SetLength(buf, 8);
      PInt64(@buf[0])^ := size;
      Respond(True, 8);
      Exit;
    end;
    if (req^.dwFlags and FILECONTENTS_RANGE) = 0 then
    begin
      Respond(False, 0);
      Exit;
    end;
    pos := (Int64(req^.nPositionHigh) shl 32) or Int64(req^.nPositionLow);
    want := req^.cbRequested;
    if want > RDPCLIP_SERVE_MAX then
      want := RDPCLIP_SERVE_MAX;
    size := FClipServedStream.Size;
    if pos >= size then
    begin
      Respond(True, 0);   // au-dela de la fin: zero octet, pas une erreur
      Exit;
    end;
    if Int64(want) > size - pos then
      want := cuint32(size - pos);
    SetLength(buf, want);
    FClipServedStream.Position := pos;
    got := FClipServedStream.Read(buf[0], Integer(want));
    if got < 0 then
      got := 0;
    Respond(True, cuint32(got));
  except
    FreeAndNil(FClipServedStream);
    FClipServedIdx := -1;
    Respond(False, 0);
  end;
end;

// Le lot est TIRE a la copie, pas au collage: attendre le collage exigerait
// un IDataObject OLE et ses flux differes. Plafond en octets, dossier
// temporaire de la session, et l'UI ne recoit les chemins qu'une fois le lot
// COMPLET: jamais un demi-lot collable.
procedure TRdpTransport.ClipStartFetch(const AFiles: TRdpClipFileArray);
var
  i, files: Integer;
  total: Int64;
begin
  total := 0;
  files := 0;
  for i := 0 to High(AFiles) do
    if not AFiles[i].IsDir then
    begin
      Inc(files);
      if AFiles[i].SizeKnown then
        Inc(total, AFiles[i].Size);
    end;
  if total > RDPCLIP_MAX_TOTAL_BYTES then
  begin
    ClipNote(Format('The remote clipboard holds %d MB of files; only up to ' +
      '%d MB come over automatically.',
      [total div (1024 * 1024), RDPCLIP_MAX_TOTAL_BYTES div (1024 * 1024)]));
    Exit;
  end;
  try
    if FClipTempRoot = '' then
    begin
      FClipTempRoot := IncludeTrailingPathDelimiter(GetTempDir) +
        'rssh-rdpclip-' + IntToStr(GetProcessID) + '-' +
        IntToStr(Random(1000000));
      if not ForceDirectories(FClipTempRoot) then
        raise EInOutError.Create('temp folder refused');
    end;
    // Le lot precedent meurt: le presse-papiers local ne designe de toute
    // facon que le dernier, et deux lots empiles grossiraient sans fin.
    if FClipFetchDir <> '' then
      ClipRemoveTree(FClipFetchDir);
    Inc(FClipBatchSeq);
    FClipFetchDir := FClipTempRoot + PathDelim + 'b' + IntToStr(FClipBatchSeq);
    if not ForceDirectories(FClipFetchDir) then
      raise EInOutError.Create('temp folder refused');
    for i := 0 to High(AFiles) do
      if AFiles[i].IsDir then
        if not ForceDirectories(FClipFetchDir + PathDelim +
           AFiles[i].LocalRel) then
          raise EInOutError.Create('temp folder refused');
  except
    on E: Exception do
    begin
      ClipNote('No room for the remote files locally: ' + E.Message + '.');
      Exit;
    end;
  end;
  FClipFetch := AFiles;
  FClipFetchIdx := -1;
  FClipFetchGot := 0;
  FClipFetchActive := True;
  // Seules les tetes de lot iront au presse-papiers local: leurs dossiers
  // portent leur contenu. Remises a l'UI a la FIN seulement: posees ici, une
  // publication en retard d'un lot precedent offrirait un lot incomplet.
  SetLength(FClipFetchTops, 0);
  for i := 0 to High(AFiles) do
    if Pos(PathDelim, AFiles[i].LocalRel) = 0 then
    begin
      SetLength(FClipFetchTops, Length(FClipFetchTops) + 1);
      FClipFetchTops[High(FClipFetchTops)] :=
        FClipFetchDir + PathDelim + AFiles[i].LocalRel;
    end;
  if total > 0 then
    ClipNote(Format('Copying %d file(s) (%d KB) from the remote desktop...',
      [files, (total + 1023) div 1024]))
  else
    ClipNote(Format('Copying %d file(s) from the remote desktop...', [files]));
  ClipFetchAdvance;
end;

procedure TRdpTransport.ClipFetchAdvance;
var
  path: string;
begin
  FreeAndNil(FClipFetchStream);
  if not FClipFetchActive then
    Exit;
  repeat
    Inc(FClipFetchIdx);
    if FClipFetchIdx > High(FClipFetch) then
    begin
      // Lot complet: l'UI ne recoit les chemins que maintenant.
      FClipFetchActive := False;
      SetLength(FClipFetch, 0);
      FClipLock.Acquire;
      try
        FClipIncomingFiles := FClipFetchTops;
      finally
        FClipLock.Release;
      end;
      FClipFetchTops := nil;
      Queue(@PublishClipboardFiles);
      ClipNote('The remote files are ready to paste.');
      Exit;
    end;
    if FClipFetch[FClipFetchIdx].IsDir then
      Continue;
    path := FClipFetchDir + PathDelim + FClipFetch[FClipFetchIdx].LocalRel;
    try
      ForceDirectories(ExtractFileDir(path));
      FClipFetchStream := TFileStream.Create(path, fmCreate);
    except
      on E: Exception do
      begin
        ClipAbortFetch(E.Message);
        Exit;
      end;
    end;
    FClipFetchOff := 0;
    // Un fichier annonce vide est deja complet.
    if FClipFetch[FClipFetchIdx].SizeKnown and
       (FClipFetch[FClipFetchIdx].Size = 0) then
    begin
      FreeAndNil(FClipFetchStream);
      Continue;
    end;
    ClipSendRange;
    Exit;
  until False;
end;

procedure TRdpTransport.ClipSendRange;
var
  req: TCliprdrFileContentsRequest;
  fn: TCliprdrFn;
begin
  Inc(FClipFetchStreamId);
  FillChar(req, SizeOf(req), 0);
  req.common.msgType := CB_FILECONTENTS_REQUEST;
  req.streamId := FClipFetchStreamId;
  req.listIndex := cuint32(FClipFetchIdx);
  req.dwFlags := FILECONTENTS_RANGE;
  req.nPositionLow := cuint32(FClipFetchOff);
  req.nPositionHigh := cuint32(FClipFetchOff shr 32);
  req.cbRequested := RDPCLIP_CHUNK_BYTES;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FILECONTENTS_REQUEST);
  if fn = nil then
    ClipAbortFetch('this build cannot request file contents')
  else
    fn(FCliprdr, @req);
end;

procedure TRdpTransport.ClipAbortFetch(const AWhy: string);
begin
  if not FClipFetchActive then
    Exit;
  FClipFetchActive := False;
  FreeAndNil(FClipFetchStream);
  SetLength(FClipFetch, 0);
  FClipFetchTops := nil;
  // Un demi-lot collable serait un mensonge: tout le lot part.
  if FClipFetchDir <> '' then
  begin
    ClipRemoveTree(FClipFetchDir);
    FClipFetchDir := '';
  end;
  if AWhy <> '' then
    ClipNote('Remote file copy abandoned: ' + AWhy + '.');
end;

// Reponse du serveur a NOTRE demande de morceau. Plus court que demande =
// fin du fichier, comme mstsc; un refus emporte le lot entier.
procedure TRdpTransport.ClipHandleFileResponse(AMsg: Pointer);
var
  resp: PCliprdrFileContentsResponse;
  got: cuint32;
begin
  if (not FClipFetchActive) or (FClipFetchStream = nil) then
    Exit;
  resp := PCliprdrFileContentsResponse(AMsg);
  if resp^.streamId <> FClipFetchStreamId then
    Exit;   // reponse d'une demande abandonnee
  if (resp^.common.msgFlags and CB_RESPONSE_OK) = 0 then
  begin
    ClipAbortFetch('the server refused the file data');
    Exit;
  end;
  got := resp^.cbRequested;
  if got > RDPCLIP_CHUNK_BYTES then
    got := RDPCLIP_CHUNK_BYTES;   // jamais plus qu'on n'a demande
  if (got > 0) and (resp^.requestedData = nil) then
  begin
    ClipAbortFetch('the server sent an empty buffer');
    Exit;
  end;
  Inc(FClipFetchGot, got);
  // Les tailles annoncees ne font pas foi: le plafond se juge sur ce qui
  // arrive vraiment.
  if FClipFetchGot > RDPCLIP_MAX_TOTAL_BYTES then
  begin
    ClipAbortFetch(Format('more than %d MB of file data',
      [RDPCLIP_MAX_TOTAL_BYTES div (1024 * 1024)]));
    Exit;
  end;
  try
    if got > 0 then
      FClipFetchStream.WriteBuffer(resp^.requestedData^, got);
  except
    on E: Exception do
    begin
      ClipAbortFetch(E.Message);
      Exit;
    end;
  end;
  Inc(FClipFetchOff, got);
  if (got < RDPCLIP_CHUNK_BYTES) or
     (FClipFetch[FClipFetchIdx].SizeKnown and
      (FClipFetchOff >= FClipFetch[FClipFetchIdx].Size)) then
    ClipFetchAdvance
  else
    ClipSendRange;
end;

procedure TRdpTransport.AnnounceLocalClipboard(const AText: UnicodeString);
var
  t: UnicodeString;
begin
  t := AText;   // div 2: la borne est en octets, ici des unites UTF-16
  if Length(t) > MAX_CLIP_INCOMING_BYTES div 2 then
    SetLength(t, MAX_CLIP_INCOMING_BYTES div 2);
  FClipLock.Acquire;
  try
    FClipLocalText := t;
    // Un presse-papiers n'a qu'un contenu: du texte remplace des fichiers.
    SetLength(FClipLocalFiles, 0);
    FClipAdvertise := True;
  finally
    FClipLock.Release;
  end;
end;

procedure TRdpTransport.AnnounceLocalFiles(const APaths: TStringArray);
var
  i: Integer;
begin
  FClipLock.Acquire;
  try
    SetLength(FClipLocalFiles, Length(APaths));
    for i := 0 to High(APaths) do
      FClipLocalFiles[i] := APaths[i];
    FClipLocalText := '';
    FClipAdvertise := True;
  finally
    FClipLock.Release;
  end;
end;

procedure TRdpTransport.Fail(const AMessage: string);
begin
  FCtxLock.Acquire;
  try
    FErrorMsg := AMessage;
  finally
    FCtxLock.Release;
  end;
  // Pas de secret mais des IDENTIFIANTS: masquer cote UI arriverait tard.
  if LogIsConfidential then
    LogError('rdp: error (details hidden in confidential mode)')
  else
    LogError('rdp: ' + AMessage);
  SetState(rssFailed);
  if Assigned(FOnError) then
    Queue(@PublishError);
end;

function TRdpTransport.IsAborted: Boolean;
begin
  Result := Terminated;
end;

function TRdpTransport.LastErrorText: string;
var
  code: cuint32;
  s: PAnsiChar;
begin
  Result := '';
  if FContext = nil then
    Exit;
  code := freerdp_get_last_error(FContext);
  if code = 0 then
    Exit;
  s := freerdp_get_last_error_string(code);
  if s <> nil then
    Result := string(AnsiString(s))
  else
    Result := Format('FreeRDP error 0x%.8x', [code]);
end;

procedure TRdpTransport.Shutdown;
begin
  Terminate;
  FCertDecision := rcdReject;
  FCertEvent.SetEvent;
  FCtxLock.Acquire;   // debloque un connect en cours, sous verrou
  try
    if FContext <> nil then
      freerdp_abort_connect_context(FContext);
  finally
    FCtxLock.Release;
  end;
end;

function TRdpTransport.BeginInput(out AInput: Pointer): Boolean;
begin
  Result := False;
  AInput := nil;
  FCtxLock.Acquire;
  try
    if (FContext = nil) or FReconnecting or (FStates.State <> rssConnected) then
      Exit;
    AInput := CtxInput(FContext);
    if AInput = nil then
      Exit;
    Inc(FInputInFlight);
    if FInputInFlight = 1 then
      FInputIdle.ResetEvent;
    Result := True;
  finally
    FCtxLock.Release;
  end;
end;

procedure TRdpTransport.EndInput;
begin
  FCtxLock.Acquire;
  try
    Dec(FInputInFlight);
    if FInputInFlight <= 0 then
    begin
      FInputInFlight := 0;
      FInputIdle.SetEvent;
    end;
  finally
    FCtxLock.Release;
  end;
end;

procedure TRdpTransport.SendMouse(AFlags: Integer; AX, AY: Integer);
var
  inp: Pointer;
begin
  if not BeginInput(inp) then Exit;
  try
    freerdp_input_send_mouse_event(inp, AFlags, AX, AY);
  finally
    EndInput;
  end;
end;

procedure TRdpTransport.SendExtendedMouse(AFlags: Integer; AX, AY: Integer);
var
  inp: Pointer;
begin
  if not BeginInput(inp) then Exit;
  try
    freerdp_input_send_extended_mouse_event(inp, AFlags, AX, AY);
  finally
    EndInput;
  end;
end;

procedure TRdpTransport.SendScancode(AFlags: Integer; ACode: Integer);
var
  inp: Pointer;
begin
  if not BeginInput(inp) then Exit;
  try
    freerdp_input_send_keyboard_event(inp, AFlags, ACode);
  finally
    EndInput;
  end;
end;

procedure TRdpTransport.SendUnicode(AFlags: Integer; ACode: Integer);
var
  inp: Pointer;
begin
  if not BeginInput(inp) then Exit;
  try
    freerdp_input_send_unicode_keyboard_event(inp, AFlags, ACode);
  finally
    EndInput;
  end;
end;

procedure TRdpTransport.SendSynchronize(AFlags: Cardinal);
var
  inp: Pointer;
begin
  if not BeginInput(inp) then Exit;
  try
    freerdp_input_send_synchronize_event(inp, AFlags);
  finally
    EndInput;
  end;
end;

procedure TRdpTransport.SendCtrlAltDel;
begin
  SendScancode(KBD_FLAGS_DOWN, SC_CTRL);
  SendScancode(KBD_FLAGS_DOWN, SC_ALT);
  SendScancode(KBD_FLAGS_DOWN or KBD_FLAGS_EXTENDED, SC_DELETE);
  SendScancode(KBD_FLAGS_RELEASE or KBD_FLAGS_EXTENDED, SC_DELETE);
  SendScancode(KBD_FLAGS_RELEASE, SC_ALT);
  SendScancode(KBD_FLAGS_RELEASE, SC_CTRL);
end;

procedure TRdpTransport.RequestResize(AWidth, AHeight: Integer);
begin
  FInputLock.Acquire;
  try
    FPendingResizeW := AWidth;
    FPendingResizeH := AHeight;
    FResizeWanted := True;
    // display-control ignore le layout avant l'echange de capacites: on renvoie
    FResendBudget := RESIZE_RESEND_MAX;
  finally
    FInputLock.Release;
  end;
end;

function TRdpTransport.BuildContext: Boolean;
var
  ep: array[0..EP_BUF_BYTES - 1] of Byte;
  ctxSize, selfOff: PtrUInt;
begin
  Result := False;
  FillChar(ep, SizeOf(ep), 0);
  // le shim fait AUTORITE: sous-estimer sizeof(rdpContext) ferait ecrire FreeRDP
  // par-dessus notre pointeur de retour, un refus n'autorise donc aucun repli
  selfOff := RdpContextSizeBytes;
  ctxSize := selfOff + SizeOf(Pointer);
  if RdpShimActive then
  begin
    if not RdpEpInit(@ep[0], SizeOf(ep), ctxSize) then
    begin
      Fail('FreeRDP: incompatible entry points layout');
      Exit;
    end;
  end
  else
  begin
    pcuint32(@ep[EP_OFF_SIZE])^ := EP_SIZE;
    pcuint32(@ep[EP_OFF_VERSION])^ := RDP_CLIENT_INTERFACE_VERSION;
    PPtrUInt(@ep[EP_OFF_CONTEXTSIZE])^ := ctxSize;
  end;
  if not (RdpEpSetClientNew(@ep[0], SizeOf(ep), @CbClientNew)
          and RdpEpSetClientFree(@ep[0], SizeOf(ep), @CbClientFree)) then
  begin
    Fail('FreeRDP: cannot set the entry point callbacks');
    Exit;
  end;

  FContext := freerdp_client_context_new(@ep[0]);
  if FContext = nil then
  begin
    Fail('Cannot create the FreeRDP context');
    Exit;
  end;
  PPointer(PByte(FContext) + selfOff)^ := Self;   // lien retour, juste apres le rdpContext
  FInstance := CtxInstance(FContext);
  if FInstance = nil then
  begin
    Fail('FreeRDP instance missing from the context');
    Exit;
  end;
  // seul endroit ou l'ABI est PROUVEE: les pointeurs de fonction ne se posent qu'ici
  if not RdpInstanceLayoutValid(FInstance, FContext, ctxSize) then
  begin
    Fail('FreeRDP: unexpected instance memory layout');
    Exit;
  end;
  RdpSetPreConnect(FInstance, @CbPreConnect);
  RdpSetPostConnect(FInstance, @CbPostConnect);
  RdpSetPostDisconnect(FInstance, @CbPostDisconnect);
  RdpSetVerifyCertificateEx(FInstance, @CbVerifyCertificateEx);
  RdpSetVerifyChangedCertificateEx(FInstance, @CbVerifyChangedCertificateEx);
  Result := True;
end;

procedure TRdpTransport.ApplySettings;
var
  s: Pointer;
  pwd: AnsiString;
  cfgDir: string;
  {$IFDEF WINDOWS}
  klName: array[0..15] of AnsiChar;
  {$ENDIF}
  klid: LongWord;

  procedure B(AId: Integer; AVal: Boolean);
  begin
    freerdp_settings_set_bool(s, AId, Ord(AVal));
  end;

begin
  s := CtxSettings(FContext);

  if FParams.ConnectHost <> '' then
  begin
    freerdp_settings_set_string(s, FreeRDP_ServerHostname,
      PAnsiChar(AnsiString(FParams.ConnectHost)));
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, FParams.ConnectPort);
    // sinon FreeRDP compare le CN a 127.0.0.1 et forge un SPN TERMSRV/127.0.0.1
    freerdp_settings_set_string(s, FreeRDP_CertificateName,
      PAnsiChar(AnsiString(FParams.Host)));
    freerdp_settings_set_string(s, FreeRDP_UserSpecifiedServerName,
      PAnsiChar(AnsiString(FParams.Host)));
  end
  else
  begin
    freerdp_settings_set_string(s, FreeRDP_ServerHostname,
      PAnsiChar(AnsiString(FParams.Host)));
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, FParams.Port);
  end;
  freerdp_settings_set_string(s, FreeRDP_Username,
    PAnsiChar(AnsiString(FParams.Username)));
  if FParams.DomainName <> '' then
    freerdp_settings_set_string(s, FreeRDP_Domain,
      PAnsiChar(AnsiString(FParams.DomainName)));

  // copie NUL-terminee le temps de l'appel, effacee dans la foulee
  if (FParams.Password <> nil) and (FParams.Password.Len > 0) then
  begin
    SetLength(pwd, FParams.Password.Len);
    Move(FParams.Password.Data^, pwd[1], FParams.Password.Len);
    try
      freerdp_settings_set_string(s, FreeRDP_Password, PAnsiChar(pwd));
    finally
      FillChar(pwd[1], Length(pwd), 0);
      pwd := '';
    end;
  end;

  freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, FParams.Width);
  freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, FParams.Height);
  freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, FParams.ColorDepth);

  B(FreeRDP_SoftwareGdi, True);   // c'est lui qui nous donne un framebuffer

  B(FreeRDP_NlaSecurity, FParams.NlaEnabled);
  B(FreeRDP_TlsSecurity, True);
  B(FreeRDP_RdpSecurity, not FParams.NlaEnabled);   // historique: si NLA est coupe
  B(FreeRDP_UseRdpSecurityLayer, False);

  // aucune acceptation globale: la decision passe par CbVerifyCertificateEx
  B(FreeRDP_IgnoreCertificate, False);
  B(FreeRDP_AutoAcceptCertificate, False);
  B(FreeRDP_ExternalCertificateManagement, False);

  // magasin interne deroute vers un dossier vide: notre TOFU reste seul juge
  cfgDir := IncludeTrailingPathDelimiter(AppDataDir) + 'freerdp-nostore';
  ForceDirectories(cfgDir);
  freerdp_settings_set_string(s, FreeRDP_ConfigPath,
    PAnsiChar(AnsiString(cfgDir)));

  B(FreeRDP_RedirectDrives, False);
  B(FreeRDP_RedirectPrinters, False);
  B(FreeRDP_RedirectSmartCards, False);
  B(FreeRDP_RedirectSerialPorts, False);
  B(FreeRDP_RedirectParallelPorts, False);
  B(FreeRDP_AudioPlayback, False);
  B(FreeRDP_AudioCapture, False);

  // Un seul reglage pour le presse-papiers entier: texte, et fichiers la ou
  // la plateforme les porte.
  B(FreeRDP_RedirectClipboard, FParams.ClipboardText);

  B(FreeRDP_DynamicResolutionUpdate, FParams.DynamicResolution);
  B(FreeRDP_SupportDisplayControl, FParams.DynamicResolution);
  B(FreeRDP_SupportDynamicChannels, True);
  // Pipeline graphique (canal rdpgfx). FreeRDP le laisse a FALSE cote client,
  // c'est la ligne de commande de xfreerdp qui l'allume, pas la bibliotheque.
  // Sans lui, un Windows 11 retombe sur les mises a jour bitmap d'autrefois
  // et les sert par rafales espacees de plusieurs secondes: une souris qui
  // met 6 a 13 s a produire une image. Le pont vers le GDI, lui, etait deja
  // branche a la connexion du canal (CbChannelConnected).
  B(FreeRDP_SupportGraphicsPipeline, True);
  B(FreeRDP_FastPathInput, True);
  B(FreeRDP_FastPathOutput, True);

  {$IFDEF WINDOWS}
  klid := 0;
  FillChar(klName, SizeOf(klName), 0);
  if GetKeyboardLayoutNameA(@klName[0]) then
    klid := StrToDWordDef('$' + string(PAnsiChar(@klName[0])), 0);
  if klid = 0 then
    klid := (GetKeyboardLayout(0) shr 16) and $FFFF;
  if klid <> 0 then
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, klid);
  {$ENDIF}

  {$IFDEF UNIX}
  // sans KLID annonce, le serveur suppose QWERTY US et l'azerty tape faux
  klid := FParams.KeyboardKlid;
  if klid = 0 then
    if Assigned(freerdp_detect_keyboard_layout_from_system_locale) then
      if freerdp_detect_keyboard_layout_from_system_locale(@klid) <> 0 then
        klid := 0;
  if klid <> 0 then
    freerdp_settings_set_uint32(s, FreeRDP_KeyboardLayout, klid);
  {$ENDIF}

  B(FreeRDP_AutoReconnectionEnabled, FParams.AutoReconnect);
  freerdp_settings_set_uint32(s, FreeRDP_AutoReconnectMaxRetries,
    FParams.MaxReconnectAttempts);

  if FParams.GatewayHostname <> '' then
  begin
    B(FreeRDP_GatewayEnabled, True);
    freerdp_settings_set_string(s, FreeRDP_GatewayHostname,
      PAnsiChar(AnsiString(FParams.GatewayHostname)));
    freerdp_settings_set_uint32(s, FreeRDP_GatewayPort, FParams.GatewayPort);
    B(FreeRDP_GatewayUseSameCredentials, True);   // pas de second jeu a saisir
  end;
end;

procedure TRdpTransport.BlitFullGdi(AGdi: Pointer);
begin
  if AGdi = nil then Exit;
  FSurface.BlitFrom(GdiPrimaryBuffer(AGdi), GdiStride(AGdi),
    0, 0, GdiWidth(AGdi), GdiHeight(AGdi));
  FLastFullBlitTick := GetTickCount64;
end;

procedure TRdpTransport.FlushGdiPaint;
var
  gdi: Pointer;
  x, y, w, h: Integer;
begin
  if FContext = nil then Exit;
  gdi := CtxGdi(FContext);
  if gdi = nil then Exit;
  if not FInvalidChainOk then
  begin
    // sans region lisible, on ne sait pas s'il y a du nouveau: d'ou la borne
    if GetTickCount64 - FLastFullBlitTick < FULL_BLIT_MIN_MS then Exit;
    BlitFullGdi(gdi);
    Queue(@PublishPaint);
    Exit;
  end;
  if not GdiTakeInvalid(gdi, x, y, w, h) then Exit;
  FSurface.BlitFrom(GdiPrimaryBuffer(gdi), GdiStride(gdi), x, y, w, h);
  GdiResetInvalid(gdi);
  Queue(@PublishPaint);
end;

procedure TRdpTransport.EventLoop;
var
  handles: array[0..MAX_EVENT_HANDLES - 1] of Pointer;
  n, rc: cuint32;
  cols, rows, sentW, sentH, budget: Integer;
  doResize, doAdvertise: Boolean;
begin
  while not Terminated do
  begin
    MaybeWipePassword;   // le seul point sur pour toucher aux settings

    if freerdp_shall_disconnect_context(FContext) <> 0 then
      Break;

    n := freerdp_get_event_handles(FContext, @handles[0], MAX_EVENT_HANDLES);
    if n = 0 then
    begin
      Fail('Cannot retrieve the event handles');
      Exit;
    end;

    rc := WaitForMultipleObjects(n, @handles[0], 0, EVENT_POLL_MS);
    if rc = WAIT_FAILED then
    begin
      Fail('Failed to wait for events');
      Exit;
    end;

    if freerdp_check_event_handles(FContext) = 0 then
    begin
      if freerdp_shall_disconnect_context(FContext) <> 0 then
        Break;   // fin normale demandee par le serveur
      if TryAutoReconnect then
        Continue;
      Fail('Connection lost: ' + LastErrorText);
      Exit;
    end;

    FlushGdiPaint;

    FInputLock.Acquire;
    try
      doResize := FResizeWanted;
      cols := FPendingResizeW;
      rows := FPendingResizeH;
      budget := FResendBudget;
    finally
      FInputLock.Release;
    end;
    if doResize and FParams.DynamicResolution and (cols > 0) and (rows > 0)
      and (FDisp <> nil) then
    begin
      // Comparer a ce qui a ete ENVOYE, pas a ce que l'onglet a demande: le
      // layout part arrondi et borne, et une taille hors de ces bornes ne
      // pouvait jamais etre « confirmee ». Pas de raccourci « le serveur a
      // repondu depuis l'envoi »: en pipeline graphique, il remet plusieurs
      // fois l'ancienne taille au demarrage, et ce raccourci prenait ces
      // remises a zero pour sa reponse, laissant le bureau a 1280x800.
      NormalizeLayout(cols, rows, sentW, sentH);
      if (FConfirmedW = sentW) and (FConfirmedH = sentH) then
      begin
        FInputLock.Acquire;
        try
          if (FPendingResizeW = cols) and (FPendingResizeH = rows) then
            FResizeWanted := False;   // confirme: on arrete
        finally
          FInputLock.Release;
        end;
      end
      else if (budget > 0) and
              (GetTickCount64 - FLastResendTick >= RESIZE_RESEND_MS) then
      begin
        SendMonitorLayout(cols, rows);
        FLastResendTick := GetTickCount64;
        FInputLock.Acquire;
        try
          if (FPendingResizeW = cols) and (FPendingResizeH = rows) then
            Dec(FResendBudget);
        finally
          FInputLock.Release;
        end;
      end
      else if budget <= 0 then
      begin
        FInputLock.Acquire;   // plafond atteint: repli scrollbars
        try
          if (FPendingResizeW = cols) and (FPendingResizeH = rows) then
            FResizeWanted := False;
        finally
          FInputLock.Release;
        end;
      end;
    end;

    FClipLock.Acquire;   // annonce armee par l'UI, envoyee ici par le worker
    try
      doAdvertise := FClipAdvertise;
      FClipAdvertise := False;
    finally
      FClipLock.Release;
    end;
    if doAdvertise and (FCliprdr <> nil) then
      ClipDoAdvertise;
  end;
end;

// Ce que le canal display-control accepte: dimensions paires, bornees.
procedure TRdpTransport.NormalizeLayout(AWidth, AHeight: Integer;
  out ASentW, ASentH: Integer);
begin
  ASentW := AWidth and (not 1);   // RDP veut des dimensions paires
  ASentH := AHeight and (not 1);
  if ASentW < 200 then ASentW := 200;
  if ASentH < 200 then ASentH := 200;
  if ASentW > 8192 then ASentW := 8192;
  if ASentH > 8192 then ASentH := 8192;
end;

procedure TRdpTransport.SendMonitorLayout(AWidth, AHeight: Integer);
var
  fn: Tdisp_send_layout;
  mon: TDisplayControlMonitorLayout;
begin
  if FDisp = nil then
    Exit;   // le serveur ne supporte pas la resolution dynamique
  NormalizeLayout(AWidth, AHeight, AWidth, AHeight);
  fn := DispSendLayoutFn(FDisp);
  if fn = nil then
    Exit;
  FillChar(mon, SizeOf(mon), 0);
  mon.Flags := DISPLAY_CONTROL_MONITOR_PRIMARY;
  mon.Width := AWidth;
  mon.Height := AHeight;
  if fn(FDisp, 1, @mon) = 0 then
  begin
    FLastSentW := AWidth;
    FLastSentH := AHeight;
  end;
end;

{$IFDEF WINDOWS}
// NTLM (donc NLA) exige MD4 et RC4, exiles dans le provider legacy d'OpenSSL 3
// dont le chemin fige par vcpkg ne pointe plus nulle part: sans ca, LOGON_FAILURE.
procedure EnsureOpenSslModulesPath;
var
  dir: AnsiString;
begin
  dir := AnsiString(ExcludeTrailingPathDelimiter(
    ExtractFilePath(ExpandFileName(ParamStr(0)))));
  crt_putenv_s('OPENSSL_MODULES', PAnsiChar(dir));
  SetEnvironmentVariableA('OPENSSL_MODULES', PAnsiChar(dir));
end;

{$ENDIF}

function TRdpTransport.RunSession: Boolean;
var
  rhost, rport, resErr: string;
  res: Paddrinfo;
begin
  Result := False;
  if not BuildContext then
    Exit;
  ApplySettings;

  // Pre-resolution ANNULABLE du PREMIER SAUT (rebond et passerelle resolvent la
  // cible eux-memes): celle de freerdp_connect bloque sans abandon possible.
  if FParams.ConnectHost <> '' then
  begin
    rhost := FParams.ConnectHost;
    rport := IntToStr(FParams.ConnectPort);
  end
  else if FParams.GatewayHostname <> '' then
  begin
    rhost := FParams.GatewayHostname;
    rport := IntToStr(FParams.GatewayPort);
  end
  else
  begin
    rhost := FParams.Host;
    rport := IntToStr(FParams.Port);
  end;
  res := nil;
  if not ResolveCancellable(AnsiString(rhost), AnsiString(rport),
       @IsAborted, res, resErr) then
  begin
    if resErr <> '' then   // resErr vide = arret demande: rien a signaler
      Fail(resErr);
    Exit;
  end;
  freeaddrinfo(res);   // on ne valide que le nom: freerdp_connect resout a nouveau

  SetState(rssAuthenticating);
  if freerdp_connect(FInstance) = 0 then
  begin
    if Terminated then
      Exit;
    Fail('RDP connection refused: ' + LastErrorText);
    Exit;
  end;

  // nos secrets ne servent plus. FreeRDP garde les siens, ou
  // freerdp_reconnect ira les rechercher.
  FParams.WipeSecrets;

  SetState(rssConnected);
  FSurface.InvalidateAll;
  Queue(@PublishPaint);

  EventLoop;
  Result := True;
end;

procedure TRdpTransport.Cleanup;
var
  ctx, inst: Pointer;
begin
  // freerdp_disconnect prend des secondes sur un lien mort et
  // gelerait l'UI. On ne tient le verrou que pour detacher les pointeurs.
  FCtxLock.Acquire;
  try
    ctx := FContext;
    inst := FInstance;
    FContext := nil;
    FInstance := nil;
  finally
    FCtxLock.Release;
  end;
  if ctx = nil then Exit;
  // detacher bloque les NOUVEAUX envois, pas ceux deja en vol: on les attend
  if FInputIdle.WaitFor(INPUT_DRAIN_MS) <> wrSignaled then
  begin
    // Un envoi campe sur un pair mort: liberer tirerait le contexte sous ses
    // pieds. On l'abandonne -- fuite bornee a la session, jamais en silence.
    LogError('rdp: envoi d''entree encore en vol apres ' +
      IntToStr(INPUT_DRAIN_MS div 1000) +
      ' s (pair bloque): contexte FreeRDP abandonne au lieu d''etre libere');
    Exit;
  end;
  try
    if inst <> nil then
      freerdp_disconnect(inst);
  except
  end;
  try
    freerdp_client_context_free(ctx);
  except
  end;
end;

procedure TRdpTransport.Execute;
begin
  try
    try
      {$IFDEF WINDOWS}
      EnsureOpenSslModulesPath;   // AVANT les DLL: winpr3 initialise OpenSSL
      {$ENDIF}
      FreeRdpEnsureLoaded;
      SetState(rssConnecting);
      if Terminated then
        Exit;
      RunSession;
      SetState(rssDisconnecting);
    except
      on E: Exception do
        Fail(E.Message);
    end;
  finally
    FParams.WipeSecrets;
    try
      Cleanup;
    except
    end;
    FStates.TryTransitionTo(rssDisconnecting);
    FStates.TryTransitionTo(rssDisconnected);
    if Assigned(FOnFinished) then
      Queue(@PublishFinished);
  end;
end;

end.
