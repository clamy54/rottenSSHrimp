unit uRdpTransport;

{$mode objfpc}{$H+}

// Un thread par session, FreeRDP confine derriere uFreeRdpApi.

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, uSecureBytes, uSessionState,
  uRemoteSurface, uRdpClipFiles, uClipSnapshot;

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
    OldFingerprint: string;  // selon FreeRDP; seul le magasin du document fait foi
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
    Password: TSecureBytes;   // possede
    Width, Height: Integer;
    // 200 sur Retina: Width/Height en pixels physiques, Windows met son interface a l'echelle
    ScalePercent: Integer;
    ColorDepth: Integer;
    VerifyCertificate: Boolean;
    NlaEnabled: Boolean;
    ClipboardText: Boolean;
    DynamicResolution: Boolean;
    AutoReconnect: Boolean;
    MaxReconnectAttempts: Integer;
    GatewayHostname: string;
    GatewayPort: Integer;
    // SUR LE THREAD UI: Text Input Services de macOS crashe ailleurs.
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
  // Tous sur le thread UI. AVerdict: 0=inconnu, 1=idem, 2=change.
  TRdpCertLookup = procedure(const AHost: string; APort: Integer;
    const AFingerprint: string; out AVerdict: Integer;
    out AKnownFingerprint: string) of object;
  TRdpCertSave = procedure(const AInfo: TRdpCertInfo) of object;
  TRdpClipboardEvent = procedure(const ASnap: TClipSnapshot) of object;
  TRdpClipFilesEvent = procedure(const APaths: TStringArray) of object;
  TRdpClipNoteEvent = procedure(const AText: string) of object;
  TRdpReconnectEvent = procedure(const AStatus: string; AActive: Boolean) of object;
  TRdpCursorEvent = procedure(const ACursor: TRemoteCursor) of object;

  TRdpClipKind = (rcFiles, rcText, rcHtml, rcRtf, rcPng, rcDib);
  TRdpClipWant = record
    Id: cuint32;
    Kind: TRdpClipKind;
  end;
  TRdpClipWants = array of TRdpClipWant;

  TRdpTransport = class(TThread)
  private
    FParams: TRdpConnectParams;
    FStates: TSessionStateMachine;
    FSurface: TRemoteSurface;

    FContext: Pointer;
    FInstance: Pointer;
    FDisp: Pointer;       // nil avant negociation du canal
    // rdpgfx: le serveur cree ce qu'il veut, FreeRDP alloue sans compter.
    // Nous, on compte.
    FGfx: Pointer;
    FGfxGdi: Pointer;   // survit au detachement de FContext, pour le liberer
    FGfxOrig: array[0..3] of Pointer;     // rappels d'origine, par slot
    FGfxSurfBytes: array[Word] of Cardinal;  // par surfaceId
    FGfxCacheBytes: array[Word] of Cardinal; // par cacheSlot
    FGfxSurfTotal, FGfxCacheTotal: Int64;
    FLastSentW, FLastSentH: Integer;

    FCliprdr: Pointer;
    FClipLock: TCriticalSection;  // les deux instantanes + le drapeau
    FClipLocal: TClipSnapshot;
    FClipLocalGen: Cardinal;      // une conversion d'image ne s'applique qu'a SON instantane
    FClipIncoming: TClipSnapshot;
    FClipAdvertise: Boolean;
    FClipHtmlId, FClipRtfId, FClipPngId: cuint32;   // ids LOCAUX, comme celui des fichiers

    // Demandes au serveur, une a la fois: une reponse ne dit pas a QUELLE
    // demande elle repond. Thread du canal, sans verrou.
    FClipWant: TRdpClipWants;
    FClipWantPos: Integer;
    FClipGot: TClipSnapshot;
    FClipBusy: Boolean;
    FClipNext: TRdpClipWants;
    FClipNextPending: Boolean;

    // Fichiers: hors annonce et remise a l'UI, threads du canal, sans verrou.
    FClipFilesFmtId: cuint32;        // id LOCAL de FileGroupDescriptorW
    FClipLocalFiles: TStringArray;   // sous FClipLock
    FClipServed: TRdpClipFileArray;
    FClipServedStream: THandleStream;
    FClipServedIdx: Integer;
    FClipFetch: TRdpClipFileArray;
    FClipFetchIdx: Integer;
    FClipFetchOff: Int64;
    FClipFetchStream: TFileStream;
    FClipFetchDir: string;
    // Lots COMPLETS (sous FClipLock). Survivent: le plus recent, le dernier
    // remis a l'onglet (qui l'ecrit, ou le garde tant qu'il est cache), et
    // celui que l'onglet dit avoir pose sur le presse-papiers. Le reste part.
    FClipDoneDirs: TStringArray;
    FClipHeldDir: string;
    FClipPlacedDir: string;
    FClipFetchStreamId: cuint32;
    FClipFetchGot: Int64;            // pour le plafond
    FClipFetchTotal: Int64;          // annonce, 0 = inconnu: pour la progression
    FClipFetchQuarter: Integer;
    FClipFetchActive: Boolean;
    FClipTempRoot: string;
    FClipBatchSeq: Integer;
    FClipFetchTops: TStringArray;
    FClipIncomingFiles: TStringArray;   // sous FClipLock
    FClipNotes: TStringList;            // sous FClipLock

    // le dernier curseur demande; l'UI saute les intermediaires
    FCursorLock: TCriticalSection;
    FCursorNext: TRemoteCursor;
    FCursorQueued: Boolean;

    // sous FCtxLock: poses par l'UI, executes par le worker
    FReconnecting: Boolean;
    FReconnectInhibited: Boolean;  // document verrouille
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
    FInvalidChainOk: Boolean;   // False: offsets douteux sur CETTE build de FreeRDP
    FLastFullBlitTick: QWord;

    FInputLock: TCriticalSection;
    // Prise du pointeur et comptage, PAS l'envoi: il ecrit sur la socket.
    FCtxLock: TCriticalSection;
    FInputInFlight: Integer;      // sous FCtxLock
    FInputIdle: TEvent;           // signale tant que FInputInFlight = 0
    FPendingResizeW, FPendingResizeH: Integer;
    FResizeWanted: Boolean;
    FResendBudget: Integer;            // sous FInputLock
    FLastResendTick: QWord;
    FConfirmedW, FConfirmedH: Integer;

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
    FOnCursor: TRdpCursorEvent;

    procedure PostCursor(AKind: TRemoteCursorKind; AShape: Pointer);
    procedure PublishCursor;
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
    procedure ClipPruneBatches;
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
    procedure ClipStartWants(const AWants: TRdpClipWants);
    procedure ClipRequestNext;
    procedure ClipStoreReply(const AWant: TRdpClipWant; AData: PByte; ALen: cuint32);
    procedure ClipKeepImage(const AImg: TClipImage);
    function ClipLocalImage(const ASnap: TClipSnapshot; AGen: Cardinal;
      APng: Boolean): RawByteString;

    // TOUJOURS appareille avec EndInput: sinon Cleanup attend un fantome.
    function BeginInput(out AInput: Pointer): Boolean;
    procedure EndInput;

    procedure SetState(ANext: TRemoteSessionState);
    procedure Fail(const AMessage: string);
    function LastErrorText: string;
    function IsAborted: Boolean;   // pour ResolveCancellable

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

    // Thread UI.
    procedure SendMouse(AFlags: Integer; AX, AY: Integer);
    procedure SendExtendedMouse(AFlags: Integer; AX, AY: Integer);
    procedure SendScancode(AFlags: Integer; ACode: Integer);
    procedure SendUnicode(AFlags: Integer; ACode: Integer);
    procedure SendCtrlAltDel;
    // KBD_SYNC_*. Le serveur demarre NumLock eteint et ne devine rien: sans
    // ca, le pave numerique tape des fleches.
    procedure SendSynchronize(AFlags: Cardinal);
    procedure RequestResize(AWidth, AHeight: Integer);
    procedure AnnounceLocalSnapshot(const ASnap: TClipSnapshot);
    procedure AnnounceLocalFiles(const APaths: TStringArray);
    // Thread UI: ces chemins (d'un lot recu) sont maintenant sur le presse-papiers.
    procedure ClipFilesPlaced(const APath: string);
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
    property OnCursor: TRdpCursorEvent read FOnCursor write FOnCursor;
    procedure InhibitReconnect;   // definitif
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
  // Nom OBLIGE; l'id, lui, est local.
  CLIP_FILES_FMT: AnsiString = 'FileGroupDescriptorW';
  CLIP_HTML_FMT: AnsiString = 'HTML Format';
  CLIP_RTF_FMT: AnsiString = 'Rich Text Format';
  CLIP_PNG_FMT: AnsiString = 'PNG';
  RDP_CF_DIB = 8;
  RDP_CF_DIBV5 = 17;

  // le serveur demande la taille qu'il veut, on alloue celle qu'on veut
  RDPCLIP_SERVE_MAX = 4 * 1024 * 1024;

  FULL_BLIT_MIN_MS = 50;
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
  // MEME offset que BuildContext, sinon adresse inventee
  Result := TRdpTransport(PPointer(PByte(AContext) + RdpContextSizeBytes)^);
end;

function TransportOfInstance(AInstance: Pointer): TRdpTransport;
begin
  if AInstance = nil then
    Exit(nil);
  Result := TransportOf(RdpContextOf(AInstance));
end;

// Cb*: sur le WORKER, et aucune exception ne traverse le C (d'ou les try
// vides). Cablage dans CbPostConnect.
function CbBeginPaint(context: PRdpContext): cint; cdecl; forward;
function CbEndPaint(context: PRdpContext): cint; cdecl; forward;
function CbDesktopResize(context: PRdpContext): cint; cdecl; forward;

const
  // OCTETS, deux bureaux au plafond chacun. Un serveur honnete en use bien
  // moins; au-dela, il veut la memoire.
  GFX_SURFACE_BUDGET_BYTES = Int64(2) * REMOTE_MAX_PIXELS * 4;
  GFX_CACHE_BUDGET_BYTES = Int64(2) * REMOTE_MAX_PIXELS * 4;
  CHANNEL_RC_NO_MEMORY = 12;

// Comme FreeRDP alloue: dimensions (ou ligne de cache) arrondies a 16.
// 1 x 8192 = 32 Kio de pixels, 128 Kio reels.
function GfxSurfaceBytes(AW, AH: Integer): Int64;
begin
  Result := Int64((AW + 15) and (not 15)) * 4 * Int64((AH + 15) and (not 15));
end;

function GfxCacheBytes(AW, AH: Integer): Int64;
begin
  Result := Int64((AW * 4 + 15) and (not 15)) * Int64(AH);
end;

// pas de minimum: une surface n'est pas un bureau
function GfxSurfaceSizeAcceptable(AW, AH: Integer): Boolean;
begin
  Result := (AW > 0) and (AH > 0) and (AW <= REMOTE_MAX_WIDTH) and
    (AH <= REMOTE_MAX_HEIGHT) and (Int64(AW) * Int64(AH) <= REMOTE_MAX_PIXELS);
end;

// Rappels rdpgfx: thread du canal dynamique, jamais pendant init/uninit
// (canal ferme a ce moment-la).
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
  // Sans ce pont, un RDS moderne peint dans le vide. Echec = contexte a
  // moitie monte: on arrete net, rien a liberer.
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
  // les notres comptent, puis passent la main a ceux du GDI
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
    LogError('rdp: graphics pipeline callbacks not found, no memory guard');
    Exit;
  end;
  GfxSetHandler(AGfx, GFX_SLOT_CREATE_SURFACE, @CbGfxCreateSurface);
  GfxSetHandler(AGfx, GFX_SLOT_DELETE_SURFACE, @CbGfxDeleteSurface);
  GfxSetHandler(AGfx, GFX_SLOT_SURFACE_TO_CACHE, @CbGfxSurfaceToCache);
  GfxSetHandler(AGfx, GFX_SLOT_EVICT_CACHE_ENTRY, @CbGfxEvictCacheEntry);
end;

// gdi_free ne libere pas le pipeline. Via FGfxGdi, pas FContext: Cleanup
// detache FContext AVANT freerdp_disconnect, donc avant la fermeture du canal.
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

// Curseur: un FALSE ici et FreeRDP coupe la session pour une fleche. Toute
// forme illisible devient donc la fleche par defaut, en silence.
function CbPointerNew(context: PRdpContext; pointer: Pointer): cint; cdecl;
var
  info: TRdpPointerInfo;
  shape: PRemoteCursor;
  pal: Pointer;
begin
  Result := 1;
  try
    PointerSetUser(pointer, nil);
    if not PointerInfo(pointer, info) then Exit;
    if (info.Width = 0) or (info.Height = 0) or
       (info.Width > REMOTE_CURSOR_MAX) or (info.Height > REMOTE_CURSOR_MAX) then
      Exit;
    pal := GdiPalette(CtxGdi(context));
    if (info.XorBpp = 8) and (pal = nil) then Exit;
    New(shape);
    shape^.Kind := rckShape;
    shape^.Width := info.Width;
    shape^.Height := info.Height;
    shape^.HotX := Integer(Min(Int64(info.XPos), Int64(info.Width) - 1));
    shape^.HotY := Integer(Min(Int64(info.YPos), Int64(info.Height) - 1));
    SetLength(shape^.Pixels, info.Width * info.Height);
    if freerdp_image_copy_from_pointer_data(@shape^.Pixels[0],
         PIXEL_FORMAT_BGRA32, info.Width * 4, 0, 0, info.Width, info.Height,
         info.XorMask, info.XorLength, info.AndMask, info.AndLength,
         info.XorBpp, pal) = 0 then
    begin
      Dispose(shape);
      Exit;
    end;
    if not PointerSetUser(pointer, shape) then
      Dispose(shape);
  except
  end;
end;

procedure CbPointerFree(context: PRdpContext; pointer: Pointer); cdecl;
var
  shape: PRemoteCursor;
begin
  try
    shape := PointerUser(pointer);
    if shape = nil then Exit;
    PointerSetUser(pointer, nil);
    Dispose(shape);
  except
  end;
end;

function CbPointerSet(context: PRdpContext; pointer: Pointer): cint; cdecl;
var
  t: TRdpTransport;
  shape: Pointer;
begin
  Result := 1;
  try
    t := TransportOf(context);
    if t = nil then Exit;
    shape := PointerUser(pointer);
    if shape <> nil then
      t.PostCursor(rckShape, shape)
    else
      t.PostCursor(rckDefault, nil);
  except
  end;
end;

function CbPointerSetNull(context: PRdpContext): cint; cdecl;
var
  t: TRdpTransport;
begin
  Result := 1;
  try
    t := TransportOf(context);
    if t <> nil then
      t.PostCursor(rckHidden, nil);
  except
  end;
end;

function CbPointerSetDefault(context: PRdpContext): cint; cdecl;
var
  t: TRdpTransport;
begin
  Result := 1;
  try
    t := TransportOf(context);
    if t <> nil then
      t.PostCursor(rckDefault, nil);
  except
  end;
end;

// le serveur ne deplace pas la souris du poste
function CbPointerSetPosition(context: PRdpContext;
  x, y: cuint32): cint; cdecl;
begin
  Result := 1;
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
    if UpdateLayoutValid(ctx, upd) then   // on y ECRIT des pointeurs de fonction
    begin
      if t.FInvalidChainOk then
        UpdSetBeginPaint(upd, @CbBeginPaint);
      UpdSetEndPaint(upd, @CbEndPaint);
      UpdSetDesktopResize(upd, @CbDesktopResize);
    end
    else
      LogError('rdp: unexpected memory layout (update), ' +
        'paint callbacks not installed');
    if RdpPointerSupported then
    begin
      if not RdpRegisterPointer(ctx, @CbPointerNew, @CbPointerFree,
           @CbPointerSet, @CbPointerSetNull, @CbPointerSetDefault,
           @CbPointerSetPosition) then
        LogError('rdp: server cursor not wired, local arrow only');
    end
    else
      LogDebug('rdp: no shim pointer support, local arrow only');
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
    // ecreter PUIS le predicat: 8192x8192 passe l'ecretage et pese 256 Mio
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
          Result := CERT_ACCEPT_TEMPORARY;   // NOTRE magasin persiste, pas FreeRDP
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
  // vide expres: aucun offset n'est encore valide ici
  Result := 1;
end;

procedure CbClientFree(instance: PFreeRdp; context: PRdpContext); cdecl;
begin
end;

// cliprdr: toujours CHANNEL_RC_OK, sinon FreeRDP demonte le canal.

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
  Result := 0;   // CHANNEL_RC_OK
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

constructor TRdpConnectParams.Create;
begin
  inherited Create;
  Port := 3389;
  Width := 1280;
  Height := 800;
  ScalePercent := 100;
  ColorDepth := 32;
  // disques, imprimantes, audio: pas de champ, pas d'activation par megarde
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
  FCursorLock := TCriticalSection.Create;
  FCertEvent := TEvent.Create(nil, True, False, '');
  FInputIdle := TEvent.Create(nil, True, True, '');   // manuel, SIGNALE au depart
  FClipNotes := TStringList.Create;
  FClipServedIdx := -1;
  // noms temporaires; la vraie garantie reste la creation EXCLUSIVE
  Randomize;
end;

// Dossier NEUF, jamais reutilise: jamais la jonction posee par un autre.
function ClipMakeFreshDir(const APrefix: string; out ADir: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to 8 do
  begin
    ADir := APrefix + IntToHex(Int64(GetTickCount64 and $FFFFFF), 6) +
      IntToHex(Random($1000000), 6);
    if RdpClipMakeDirOwnerOnly(ADir) then
      Exit(True);
  end;
  ADir := '';
end;

destructor TRdpTransport.Destroy;
begin
  inherited Destroy;   // joint le thread: Cleanup a deja draine
  FreeAndNil(FClipFetchStream);
  FreeAndNil(FClipServedStream);
  // les fichiers rapatries meurent avec l'onglet
  if FClipTempRoot <> '' then
    RdpClipRemoveTree(FClipTempRoot);
  FClipNotes.Free;
  FInputIdle.Free;
  FCertEvent.Free;
  FClipLock.Free;
  FCursorLock.Free;
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
  // chaine MANAGEE: son refcount ne se touche pas a deux
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

// Worker. AShape: PRemoteCursor ou nil. Les pixels ne bougent plus une fois
// convertis, le compteur du tableau dynamique suffit au partage.
procedure TRdpTransport.PostCursor(AKind: TRemoteCursorKind; AShape: Pointer);
var
  post: Boolean;
begin
  FCursorLock.Acquire;
  try
    if AShape <> nil then
      FCursorNext := PRemoteCursor(AShape)^
    else
    begin
      FCursorNext := Default(TRemoteCursor);
      FCursorNext.Kind := AKind;
    end;
    post := not FCursorQueued;
    FCursorQueued := True;
  finally
    FCursorLock.Release;
  end;
  if post then
    Queue(@PublishCursor);
end;

procedure TRdpTransport.PublishCursor;
var
  c: TRemoteCursor;
begin
  FCursorLock.Acquire;
  try
    c := FCursorNext;
    FCursorQueued := False;
  finally
    FCursorLock.Release;
  end;
  if Assigned(FOnCursor) then
    FOnCursor(c);
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
  snap: TClipSnapshot;
begin
  FClipLock.Acquire;
  try
    snap := FClipIncoming;
    FClipIncoming := Default(TClipSnapshot);
  finally
    FClipLock.Release;
  end;
  if not ClipSnapshotEmpty(snap) and Assigned(FOnClipboard) then
    FOnClipboard(snap);
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

      // relire: le document a pu etre verrouille pendant l'attente
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

procedure TRdpTransport.ClipAttach(ACliprdr: Pointer);
begin
  if ACliprdr = nil then
    Exit;
  FCliprdr := ACliprdr;
  // canal neuf (reconnexion comprise): la reponse attendue ne viendra plus
  FClipBusy := False;
  FClipNextPending := False;
  FClipNext := nil;
  FClipWant := nil;
  FClipWantPos := 0;
  FClipGot := Default(TClipSnapshot);
  CliprdrSetCustom(ACliprdr, Self);
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
  // id LOCAL: le serveur le redonne dans ses demandes
  FClipFilesFmtId := cuint32(RegisterClipboardFormatW('FileGroupDescriptorW'));
  if FClipFilesFmtId = 0 then
    FClipFilesFmtId := $C004;
  FClipHtmlId := cuint32(RegisterClipboardFormatW('HTML Format'));
  FClipRtfId := cuint32(RegisterClipboardFormatW('Rich Text Format'));
  FClipPngId := cuint32(RegisterClipboardFormatW('PNG'));
  {$ELSE}
  FClipFilesFmtId := $C004;
  FClipHtmlId := 0;
  FClipRtfId := 0;
  FClipPngId := 0;
  {$ENDIF}
  if FClipHtmlId = 0 then FClipHtmlId := $C010;
  if FClipRtfId = 0 then FClipRtfId := $C011;
  if FClipPngId = 0 then FClipPngId := $C012;
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
  // Fichiers en FLUX, jamais par chemin.
  genSet.generalFlags := CB_USE_LONG_FORMAT_NAMES
    or CB_STREAM_FILECLIP_ENABLED or CB_FILECLIP_NO_FILE_PATHS;
  caps.common.msgType := CB_CLIP_CAPS;
  caps.cCapabilitiesSets := 1;
  caps.capabilitySets := @genSet;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_CAPABILITIES);
  if fn <> nil then
    fn(FCliprdr, @caps);
  ClipDoAdvertise;   // ce que l'UI a pu pousser avant la connexion
end;

procedure TRdpTransport.ClipDoAdvertise;
var
  list: TCliprdrFormatList;
  fmts: array[0..4] of TCliprdrFormat;
  snap: TClipSnapshot;
  hasFiles: Boolean;
  n: Integer;
  fn: TCliprdrFn;

  procedure Add(AId: cuint32; AName: PAnsiChar);
  begin
    fmts[n].formatId := AId;
    fmts[n].formatName := AName;
    Inc(n);
  end;

begin
  if FCliprdr = nil then
    Exit;
  FClipLock.Acquire;
  try
    snap := FClipLocal;
    hasFiles := Length(FClipLocalFiles) > 0;
  finally
    FClipLock.Release;
  end;
  FillChar(fmts, SizeOf(fmts), 0);
  FillChar(list, SizeOf(list), 0);
  n := 0;
  if hasFiles then
    Add(FClipFilesFmtId, PAnsiChar(CLIP_FILES_FMT))
  else
  begin
    if snap.Text <> '' then
      Add(CF_UNICODETEXT, nil);
    if snap.Html <> '' then
      Add(FClipHtmlId, PAnsiChar(CLIP_HTML_FMT));
    if snap.Rtf <> '' then
      Add(FClipRtfId, PAnsiChar(CLIP_RTF_FMT));
    if ClipSnapshotHasImage(snap) then
    begin
      Add(RDP_CF_DIB, nil);
      Add(FClipPngId, PAnsiChar(CLIP_PNG_FMT));
    end;
  end;
  if n > 0 then
    list.formats := @fmts[0];
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
  id, filesId, textId, htmlId, rtfId, pngId, dibId: cuint32;
  name: string;
  resp: TCliprdrFormatListResponse;
  fnResp: TCliprdrFn;
  wants: TRdpClipWants;

  procedure Want(AId: cuint32; AKind: TRdpClipKind);
  begin
    SetLength(wants, Length(wants) + 1);
    wants[High(wants)].Id := AId;
    wants[High(wants)].Kind := AKind;
  end;

begin
  if (FCliprdr = nil) or (AMsg = nil) then
    Exit;
  list := PCliprdrFormatList(AMsg);
  if FClipFetchActive then
    ClipAbortFetch('the remote clipboard changed while files were coming ' +
      'over');
  count := list^.numFormats;
  filesId := 0; textId := 0; htmlId := 0; rtfId := 0; pngId := 0; dibId := 0;
  if list^.formats <> nil then
    for i := 0 to count - 1 do
    begin
      fmt := PCliprdrFormat(PByte(list^.formats) + i * SizeOf(TCliprdrFormat));
      id := fmt^.formatId;
      name := '';
      if fmt^.formatName <> nil then
        name := string(AnsiString(fmt^.formatName));
      if name <> '' then
      begin
        if SameText(name, string(CLIP_FILES_FMT)) then filesId := id
        else if SameText(name, string(CLIP_HTML_FMT)) then htmlId := id
        else if SameText(name, string(CLIP_RTF_FMT)) then rtfId := id
        else if SameText(name, string(CLIP_PNG_FMT)) then pngId := id;
      end
      else if id = CF_UNICODETEXT then
        textId := id
      else if ((id = CF_TEXT) or (id = CF_OEMTEXT)) and (textId = 0) then
        textId := id
      else if id = RDP_CF_DIBV5 then
        dibId := id
      else if (id = RDP_CF_DIB) and (dibId = 0) then
        dibId := id;
    end;
  FillChar(resp, SizeOf(resp), 0);
  resp.common.msgType := CB_FORMAT_LIST_RESPONSE;
  resp.common.msgFlags := CB_RESPONSE_OK;
  fnResp := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_LIST_RESPONSE);
  if fnResp <> nil then
    fnResp(FCliprdr, @resp);
  wants := nil;
  // Fichiers d'abord, et seuls: une copie de fichiers annonce AUSSI leurs
  // noms en texte, et une icone en image.
  if filesId <> 0 then
    Want(filesId, rcFiles)
  else
  begin
    if textId <> 0 then Want(textId, rcText);
    if htmlId <> 0 then Want(htmlId, rcHtml);
    if rtfId <> 0 then Want(rtfId, rcRtf);
    // PNG d'abord: plus leger sur le fil, reencode de toute facon
    if pngId <> 0 then Want(pngId, rcPng)
    else if dibId <> 0 then Want(dibId, rcDib);
  end;
  ClipStartWants(wants);
end;

procedure TRdpTransport.ClipStartWants(const AWants: TRdpClipWants);
begin
  // Demande en vol: sa reponse viendra quand meme, et passerait pour la
  // premiere de la nouvelle liste. On attend qu'elle tombe, sans delai de
  // grace: un serveur muet fige son presse-papiers, il ne melange rien.
  if FClipBusy then
  begin
    FClipNext := Copy(AWants);
    FClipNextPending := True;
    Exit;
  end;
  FClipNextPending := False;
  FClipNext := nil;
  FClipBusy := False;
  FClipWant := Copy(AWants);
  FClipWantPos := 0;
  FClipGot := Default(TClipSnapshot);
  ClipRequestNext;
end;

procedure TRdpTransport.ClipRequestNext;
var
  req: TCliprdrFormatDataRequest;
  fn: TCliprdrFn;
begin
  if FClipWantPos >= Length(FClipWant) then
  begin
    FClipWant := nil;
    if not ClipSnapshotEmpty(FClipGot) then
    begin
      FClipLock.Acquire;
      try
        FClipIncoming := FClipGot;
      finally
        FClipLock.Release;
      end;
      Queue(@PublishClipboard);
    end;
    FClipGot := Default(TClipSnapshot);
    Exit;
  end;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_DATA_REQUEST);
  if fn = nil then
  begin
    FClipWant := nil;
    Exit;
  end;
  FillChar(req, SizeOf(req), 0);
  req.common.msgType := CB_FORMAT_DATA_REQUEST;
  req.requestedFormatId := FClipWant[FClipWantPos].Id;
  FClipBusy := True;
  fn(FCliprdr, @req);
end;

procedure TRdpTransport.ClipHandleDataRequest(AFormatId: cuint32);
var
  snap: TClipSnapshot;
  gen: Cardinal;
  ansi: RawByteString;
  buf: RawByteString;
  resp: TCliprdrFormatDataResponse;
  fn: TCliprdrFn;
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
    snap := FClipLocal;
    gen := FClipLocalGen;
  finally
    FClipLock.Release;
  end;
  buf := '';
  if snap.Text <> '' then
  begin
    if AFormatId = CF_UNICODETEXT then
    begin
      SetLength(buf, (Length(snap.Text) + 1) * 2);   // UTF-16LE + NUL final
      Move(snap.Text[1], buf[1], Length(snap.Text) * 2);
      buf[Length(buf) - 1] := #0;
      buf[Length(buf)] := #0;
    end
    else if (AFormatId = CF_TEXT) or (AFormatId = CF_OEMTEXT) then
    begin
      ansi := AnsiString(snap.Text);
      buf := ansi + #0;
    end;
  end;
  if (buf = '') and (AFormatId = FClipHtmlId) and (snap.Html <> '') then
    buf := CfHtmlWrap(snap.Html) + #0
  else if (buf = '') and (AFormatId = FClipRtfId) and (snap.Rtf <> '') then
    buf := snap.Rtf + #0
  else if (buf = '') and ClipSnapshotHasImage(snap) and
          ((AFormatId = RDP_CF_DIB) or (AFormatId = FClipPngId)) then
    buf := ClipLocalImage(snap, gen, AFormatId = FClipPngId);
  FillChar(resp, SizeOf(resp), 0);
  resp.common.msgType := CB_FORMAT_DATA_RESPONSE;
  if buf <> '' then
  begin
    resp.common.msgFlags := CB_RESPONSE_OK;
    resp.common.dataLen := Length(buf);
    resp.requestedFormatData := @buf[1];
  end
  else
    resp.common.msgFlags := CB_RESPONSE_FAIL;
  fn := CliprdrCall(FCliprdr, CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE);
  if fn <> nil then
    fn(FCliprdr, @resp);   // buf doit vivre jusqu'ici
end;

// L'image locale est servie dans le format demande; la conversion ne vaut
// que pour l'instantane qui l'a vue naitre.
function TRdpTransport.ClipLocalImage(const ASnap: TClipSnapshot;
  AGen: Cardinal; APng: Boolean): RawByteString;
var
  img: TClipImage;
  why: string;
  ok: Boolean;
begin
  if APng and (ASnap.Png <> '') then
    Exit(ASnap.Png);
  if (not APng) and (ASnap.Dib <> '') then
    Exit(ASnap.Dib);
  Result := '';
  try
    if ASnap.Png <> '' then
      ok := PngDecode(ASnap.Png, img, why)
    else
      ok := DibDecode(PByte(@ASnap.Dib[1]), Length(ASnap.Dib), img, why);
    if not ok then
    begin
      ClipNote('The local image was not offered: ' + why + '.');
      Exit;
    end;
    if APng then
      Result := PngEncode(img)
    else
      Result := DibEncode(img);
  except
    Result := '';
  end;
  if Result = '' then
    Exit;
  FClipLock.Acquire;
  try
    if FClipLocalGen = AGen then
      if APng then
        FClipLocal.Png := Result
      else
        FClipLocal.Dib := Result;
  finally
    FClipLock.Release;
  end;
end;

procedure TRdpTransport.ClipHandleServerDataResponse(AMsg: Pointer);
var
  resp: PCliprdrFormatDataResponse;
  w: TRdpClipWant;
  next: TRdpClipWants;
  ok: Boolean;
begin
  if AMsg = nil then
    Exit;
  resp := PCliprdrFormatDataResponse(AMsg);
  FClipBusy := False;
  if FClipNextPending then
  begin
    // reponse a l'ancienne liste: jetee sans etre lue
    next := FClipNext;
    ClipStartWants(next);
    Exit;
  end;
  if FClipWantPos >= Length(FClipWant) then
    Exit;   // personne ne l'a demandee
  w := FClipWant[FClipWantPos];
  ok := ((resp^.common.msgFlags and CB_RESPONSE_OK) <> 0) and
    (resp^.requestedFormatData <> nil) and (resp^.common.dataLen > 0);
  if ok then
    ClipStoreReply(w, resp^.requestedFormatData, resp^.common.dataLen);
  Inc(FClipWantPos);
  ClipRequestNext;
end;

// dataLen vient du serveur: chaque format a son plafond, et un refus motive
// vaut mieux qu'une troncature qui ment.
procedure TRdpTransport.ClipStoreReply(const AWant: TRdpClipWant; AData: PByte;
  ALen: cuint32);
var
  u: UnicodeString;
  raw, html: RawByteString;
  files: TRdpClipFileArray;
  img: TClipImage;
  why: string;
  p: Integer;
  len: cuint32;
begin
  case AWant.Kind of
    rcFiles:
      begin
        if ALen > 4 + LongWord(RDPCLIP_MAX_FILES) * FILEDESC_W_SIZE then
        begin
          ClipNote(Format('The remote file list was refused: more than %d files.',
            [RDPCLIP_MAX_FILES]));
          Exit;
        end;
        if not ParseFileGroupDescriptor(AData, ALen, files, why) then
        begin
          ClipNote('The remote file list was refused: ' + why + '.');
          Exit;
        end;
        ClipStartFetch(files);
      end;
    rcText:
      begin
        len := ALen;
        if len > MAX_CLIP_INCOMING_BYTES then
          len := MAX_CLIP_INCOMING_BYTES;
        if AWant.Id = CF_UNICODETEXT then
        begin
          SetLength(u, len div 2);
          if Length(u) > 0 then
            Move(AData^, u[1], Length(u) * 2);
        end
        else
        begin
          SetString(raw, PAnsiChar(AData), len);
          u := UnicodeString(raw);
        end;
        p := Pos(#0, u);   // formats texte Windows: NUL-termines
        if p > 0 then
          SetLength(u, p - 1);
        FClipGot.Text := u;
      end;
    rcHtml, rcRtf:
      begin
        if ALen > CLIP_RICH_MAX_BYTES then
        begin
          ClipNote('The remote formatted text was too large; plain text only.');
          Exit;
        end;
        SetString(raw, PAnsiChar(AData), ALen);
        if AWant.Kind = rcRtf then
          RtfSane(raw, FClipGot.Rtf)
        else if CfHtmlUnwrap(raw, html) then
          FClipGot.Html := HtmlSane(html);
      end;
    rcPng, rcDib:
      begin
        if ALen > CLIP_IMAGE_MAX_BYTES then
        begin
          ClipNote('The remote image was refused: too large.');
          Exit;
        end;
        if AWant.Kind = rcPng then
        begin
          SetString(raw, PAnsiChar(AData), ALen);
          if not PngDecode(raw, img, why) then
          begin
            ClipNote('The remote image was refused: ' + why + '.');
            Exit;
          end;
        end
        else if not DibDecode(AData, ALen, img, why) then
        begin
          ClipNote('The remote image was refused: ' + why + '.');
          Exit;
        end;
        ClipKeepImage(img);
      end;
  end;
end;

// Seuls des pixels traversent: rien du fichier d'origine n'atteint un lecteur local.
procedure TRdpTransport.ClipKeepImage(const AImg: TClipImage);
begin
  try
    FClipGot.Png := PngEncode(AImg);
    {$IFDEF WINDOWS}
    FClipGot.Dib := DibEncode(AImg);
    {$ENDIF}
  except
    FClipGot.Png := '';
    FClipGot.Dib := '';
    ClipNote('The remote image could not be converted.');
  end;
end;

procedure TRdpTransport.PublishClipboardFiles;
var
  paths: TStringArray;
  i: Integer;
begin
  FClipLock.Acquire;
  try
    paths := FClipIncomingFiles;
    FClipIncomingFiles := nil;
    if Length(paths) > 0 then
      for i := 0 to High(FClipDoneDirs) do
        if Copy(paths[0], 1, Length(FClipDoneDirs[i]) + 1) =
           FClipDoneDirs[i] + PathDelim then
          FClipHeldDir := FClipDoneDirs[i];
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

// Enumere ICI, a la demande; CE tableau (indices compris) fait foi ensuite.
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

// Seul l'index designe un fichier, jamais un chemin venu du fil.
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
      FClipServedStream := RdpClipOpenServed(
        FClipServed[req^.listIndex].LocalPath);
      // La POIGNEE, pas le chemin: une jonction posee depuis enverrait autre chose.
      if not HandleMatchesId(FClipServedStream.Handle,
         FClipServed[req^.listIndex].Id) then
      begin
        FreeAndNil(FClipServedStream);
        ClipNote(Format('"%s" is not the file that was copied any more; it ' +
          'was not sent.',
          [ExtractFileName(FClipServed[req^.listIndex].LocalPath)]));
        Respond(False, 0);
        Exit;
      end;
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
      Respond(True, 0);   // au-dela de la fin: zero octet, pas d'erreur
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

// TIRE a la copie: attendre le collage exigerait un IDataObject OLE. L'UI
// n'a les chemins qu'une fois le lot COMPLET.
procedure TRdpTransport.ClipStartFetch(const AFiles: TRdpClipFileArray);
var
  i, files: Integer;
  total, avail: Int64;
begin
  total := 0;
  files := 0;
  for i := 0 to High(AFiles) do
    if not AFiles[i].IsDir then
    begin
      Inc(files);
      // bornee AVANT la somme: un total qui deborde passe sous le plafond
      if AFiles[i].SizeKnown then
      begin
        if AFiles[i].Size > RDPCLIP_MAX_TOTAL_BYTES then
          total := RDPCLIP_MAX_TOTAL_BYTES + 1
        else
          Inc(total, AFiles[i].Size);
      end;
      if total > RDPCLIP_MAX_TOTAL_BYTES then
        Break;
    end;
  if total > RDPCLIP_MAX_TOTAL_BYTES then
  begin
    ClipNote(Format('The remote clipboard holds %d MB of files; only up to ' +
      '%d MB come over automatically. Copy them in smaller batches.',
      [total div (1024 * 1024), RDPCLIP_MAX_TOTAL_BYTES div (1024 * 1024)]));
    Exit;
  end;
  try
    if FClipTempRoot = '' then
      if not ClipMakeFreshDir(IncludeTrailingPathDelimiter(GetTempDir) +
         'rssh-rdpclip-' + IntToStr(GetProcessID) + '-', FClipTempRoot) then
        raise EInOutError.Create('temp folder refused');
    // remplir le disque pour un collage qui n'aura peut-etre jamais lieu: non
    avail := RdpClipFreeBytes(FClipTempRoot);
    if (avail >= 0) and (avail < total + RDPCLIP_DISK_RESERVE) then
    begin
      ClipNote(Format('The remote files (%d MB) were not copied: only %d MB ' +
        'free on the local disk.', [total div (1024 * 1024),
        avail div (1024 * 1024)]));
      Exit;
    end;
    // un lot inacheve ne sert a personne
    if FClipFetchDir <> '' then
      RdpClipRemoveTree(FClipFetchDir);
    Inc(FClipBatchSeq);
    // CreateDir: dans NOTRE racine, un nom deja pris vient d'un autre. Les
    // descendants heritent de la DACL proprietaire seul.
    FClipFetchDir := FClipTempRoot + PathDelim + 'b' + IntToStr(FClipBatchSeq);
    if not CreateDir(FClipFetchDir) then
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
  FClipFetchTotal := total;
  FClipFetchQuarter := 0;
  FClipFetchActive := True;
  // Tetes de lot, remises a l'UI a la FIN seulement: une publication en
  // retard du lot precedent offrirait sinon celui-ci incomplet.
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
      FClipFetchActive := False;
      SetLength(FClipFetch, 0);
      FClipLock.Acquire;
      try
        SetLength(FClipDoneDirs, Length(FClipDoneDirs) + 1);
        FClipDoneDirs[High(FClipDoneDirs)] := FClipFetchDir;
        FClipIncomingFiles := FClipFetchTops;
      finally
        FClipLock.Release;
      end;
      FClipFetchTops := nil;
      FClipFetchDir := '';
      ClipPruneBatches;
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
  // pas de demi-lot collable
  if FClipFetchDir <> '' then
  begin
    RdpClipRemoveTree(FClipFetchDir);
    FClipFetchDir := '';
  end;
  if AWhy <> '' then
    ClipNote('Remote file copy abandoned: ' + AWhy + '.');
end;

// Plus court que demande = fin du fichier (comme mstsc).
procedure TRdpTransport.ClipHandleFileResponse(AMsg: Pointer);
var
  resp: PCliprdrFileContentsResponse;
  got: cuint32;
  avail: Int64;
begin
  if (not FClipFetchActive) or (FClipFetchStream = nil) then
    Exit;
  resp := PCliprdrFileContentsResponse(AMsg);
  if resp^.streamId <> FClipFetchStreamId then
    Exit;   // demande abandonnee
  if (resp^.common.msgFlags and CB_RESPONSE_OK) = 0 then
  begin
    ClipAbortFetch('the server refused the file data');
    Exit;
  end;
  got := resp^.cbRequested;
  // plus que demande: le surplus n'est pas a nous de le jeter en silence
  if got > RDPCLIP_CHUNK_BYTES then
  begin
    ClipAbortFetch('the server sent more file data than requested');
    Exit;
  end;
  if (got > 0) and (resp^.requestedData = nil) then
  begin
    ClipAbortFetch('the server sent an empty buffer');
    Exit;
  end;
  Inc(FClipFetchGot, got);
  // plafond sur ce qui arrive, pas sur ce qui est annonce
  if FClipFetchGot > RDPCLIP_MAX_TOTAL_BYTES then
  begin
    ClipAbortFetch(Format('more than %d MB of file data',
      [RDPCLIP_MAX_TOTAL_BYTES div (1024 * 1024)]));
    Exit;
  end;
  // le disque a pu se remplir d'autre chose entre-temps: on regarde tous
  // les 64 Mo, a la frontiere franchie
  if (FClipFetchGot shr 26) <> ((FClipFetchGot - got) shr 26) then
  begin
    avail := RdpClipFreeBytes(FClipFetchDir);
    if (avail >= 0) and (avail < RDPCLIP_DISK_RESERVE) then
    begin
      ClipAbortFetch('the local disk is almost full');
      Exit;
    end;
  end;
  // un lot de plusieurs Go sans nouvelles, c'est un logiciel qu'on croit gele
  if (FClipFetchTotal >= Int64(256) * 1024 * 1024) and
     (FClipFetchGot * 4 div FClipFetchTotal > FClipFetchQuarter) and
     (FClipFetchQuarter < 3) then
  begin
    FClipFetchQuarter := FClipFetchGot * 4 div FClipFetchTotal;
    if FClipFetchQuarter > 3 then FClipFetchQuarter := 3;
    ClipNote(Format('Remote files: %d%% of %d MB copied...',
      [FClipFetchQuarter * 25, FClipFetchTotal div (1024 * 1024)]));
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
  // Taille annoncee: un bloc court n'est pas une fin de fichier, on demande
  // la suite; le fichier n'est livre qu'a sa taille exacte. Rien du tout,
  // en revanche, c'est un serveur qui ne donnera plus rien.
  if FClipFetch[FClipFetchIdx].SizeKnown then
  begin
    if FClipFetchOff > FClipFetch[FClipFetchIdx].Size then
      ClipAbortFetch('a remote file is larger than announced')
    else if FClipFetchOff = FClipFetch[FClipFetchIdx].Size then
      ClipFetchAdvance
    else if got = 0 then
      ClipAbortFetch('a remote file came over truncated')
    else
      ClipSendRange;
  end
  else if got < RDPCLIP_CHUNK_BYTES then
    ClipFetchAdvance
  else
    ClipSendRange;
end;

// Supprime hors verrou ce que le verrou a designe: deux threads peuvent
// elaguer, jamais le meme dossier deux fois.
procedure TRdpTransport.ClipPruneBatches;
var
  doomed, keep: TStringArray;
  i: Integer;
begin
  doomed := nil;
  keep := nil;
  FClipLock.Acquire;
  try
    for i := 0 to High(FClipDoneDirs) do
      if (i = High(FClipDoneDirs)) or (FClipDoneDirs[i] = FClipPlacedDir) or
         (FClipDoneDirs[i] = FClipHeldDir) then
      begin
        SetLength(keep, Length(keep) + 1);
        keep[High(keep)] := FClipDoneDirs[i];
      end
      else
      begin
        SetLength(doomed, Length(doomed) + 1);
        doomed[High(doomed)] := FClipDoneDirs[i];
      end;
    FClipDoneDirs := keep;
  finally
    FClipLock.Release;
  end;
  for i := 0 to High(doomed) do
    RdpClipRemoveTree(doomed[i]);
end;

procedure TRdpTransport.ClipFilesPlaced(const APath: string);
var
  i: Integer;
begin
  FClipLock.Acquire;
  try
    for i := 0 to High(FClipDoneDirs) do
      if Copy(APath, 1, Length(FClipDoneDirs[i]) + 1) =
         FClipDoneDirs[i] + PathDelim then
        FClipPlacedDir := FClipDoneDirs[i];
  finally
    FClipLock.Release;
  end;
  ClipPruneBatches;
end;

procedure TRdpTransport.AnnounceLocalSnapshot(const ASnap: TClipSnapshot);
var
  snap: TClipSnapshot;
begin
  snap := ASnap;   // div 2: borne en octets, longueur en UTF-16
  if Length(snap.Text) > MAX_CLIP_INCOMING_BYTES div 2 then
    SetLength(snap.Text, MAX_CLIP_INCOMING_BYTES div 2);
  if Length(snap.Html) > CLIP_RICH_MAX_BYTES then
    snap.Html := '';
  if Length(snap.Rtf) > CLIP_RICH_MAX_BYTES then
    snap.Rtf := '';
  if (Length(snap.Png) > CLIP_IMAGE_MAX_BYTES) or
     (Length(snap.Dib) > CLIP_IMAGE_MAX_BYTES) then
  begin
    snap.Png := '';
    snap.Dib := '';
  end;
  FClipLock.Acquire;
  try
    FClipLocal := snap;
    Inc(FClipLocalGen);
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
    FClipLocal := Default(TClipSnapshot);
    Inc(FClipLocalGen);
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
  // pas de secret, mais des IDENTIFIANTS
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
  FCtxLock.Acquire;   // debloque un connect en cours
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
    // display-control ignore le layout avant l'echange de capacites: renvois
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
  // le shim fait AUTORITE: un contexte sous-estime = FreeRDP ecrase notre
  // pointeur de retour. Refus = pas de repli.
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
  PPointer(PByte(FContext) + selfOff)^ := Self;   // juste apres le rdpClientContext
  FInstance := CtxInstance(FContext);
  if FInstance = nil then
  begin
    Fail('FreeRDP instance missing from the context');
    Exit;
  end;
  // ABI PROUVEE ici seulement: pointeurs de fonction poses apres, jamais avant
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
  if FParams.ScalePercent > 100 then
  begin
    freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, FParams.ScalePercent);
    freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, 100);
  end;
  freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, FParams.ColorDepth);

  B(FreeRDP_SoftwareGdi, True);   // notre framebuffer

  B(FreeRDP_NlaSecurity, FParams.NlaEnabled);
  B(FreeRDP_TlsSecurity, True);
  B(FreeRDP_RdpSecurity, not FParams.NlaEnabled);
  B(FreeRDP_UseRdpSecurityLayer, False);

  // aucune acceptation globale: tout passe par CbVerifyCertificateEx
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

  // texte ET fichiers: un seul reglage
  B(FreeRDP_RedirectClipboard, FParams.ClipboardText);

  B(FreeRDP_DynamicResolutionUpdate, FParams.DynamicResolution);
  B(FreeRDP_SupportDisplayControl, FParams.DynamicResolution);
  B(FreeRDP_SupportDynamicChannels, True);
  // FALSE par defaut dans la lib (c'est xfreerdp qui l'allume). Sans lui,
  // Windows 11 sert des bitmaps par rafales: 6 a 13 s par image.
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
    B(FreeRDP_GatewayUseSameCredentials, True);
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
    // sans region lisible, on recopie tout: au plus toutes les 50 ms
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
    MaybeWipePassword;   // seul point sur pour toucher aux settings

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
        Break;   // fin demandee par le serveur
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
      // Comparer a l'ENVOYE (arrondi, borne), pas au demande. Et pas de
      // raccourci « il a repondu »: en rdpgfx il ressert l'ancienne taille
      // au demarrage, bureau colle a 1280x800.
      NormalizeLayout(cols, rows, sentW, sentH);
      if (FConfirmedW = sentW) and (FConfirmedH = sentH) then
      begin
        FInputLock.Acquire;
        try
          if (FPendingResizeW = cols) and (FPendingResizeH = rows) then
            FResizeWanted := False;
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

    FClipLock.Acquire;   // armee par l'UI, envoyee par le worker
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

// display-control: dimensions paires, bornees
procedure TRdpTransport.NormalizeLayout(AWidth, AHeight: Integer;
  out ASentW, ASentH: Integer);
begin
  ASentW := AWidth and (not 1);
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
    Exit;
  NormalizeLayout(AWidth, AHeight, AWidth, AHeight);
  fn := DispSendLayoutFn(FDisp);
  if fn = nil then
    Exit;
  FillChar(mon, SizeOf(mon), 0);
  mon.Flags := DISPLAY_CONTROL_MONITOR_PRIMARY;
  mon.Width := AWidth;
  mon.Height := AHeight;
  // a chaque layout: sans facteur, le serveur retombe a 100 % au premier redimensionnement
  if FParams.ScalePercent > 100 then
  begin
    mon.DesktopScaleFactor := FParams.ScalePercent;
    mon.DeviceScaleFactor := 100;
  end;
  if fn(FDisp, 1, @mon) = 0 then
  begin
    FLastSentW := AWidth;
    FLastSentH := AHeight;
  end;
end;

{$IFDEF WINDOWS}
// NTLM veut MD4/RC4, exiles dans le provider legacy d'OpenSSL 3, au chemin
// fige par vcpkg vers nulle part. Sans ca: LOGON_FAILURE.
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

{$IFDEF DARWIN}
function c_setenv(AName, AValue: PAnsiChar; AOverwrite: cint): cint; cdecl;
  external 'c' name 'setenv';

// Meme exil sous macOS: le chemin fige est le Cellar Homebrew de la machine
// de build. Sans ca, hors de cette machine: « transport layer failed ».
// Bundle seulement (legacy.dylib embarque): un build de dev garde son Homebrew.
procedure EnsureOpenSslModulesPath;
var
  dir: AnsiString;
begin
  dir := AnsiString(ExcludeTrailingPathDelimiter(ExpandFileName(
    ExtractFilePath(ParamStr(0)) + '../Frameworks/')));
  if FileExists(string(dir) + '/legacy.dylib') then
    c_setenv('OPENSSL_MODULES', PAnsiChar(dir), 1);
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

  // Premier saut resolu ici, ANNULABLE: celle de freerdp_connect ne l'est pas.
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
    if resErr <> '' then   // vide: arret demande
      Fail(resErr);
    Exit;
  end;
  freeaddrinfo(res);   // nom valide; freerdp_connect resout a nouveau

  SetState(rssAuthenticating);
  if freerdp_connect(FInstance) = 0 then
  begin
    if Terminated then
      Exit;
    Fail('RDP connection refused: ' + LastErrorText);
    Exit;
  end;

  // FreeRDP garde sa copie pour freerdp_reconnect
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
  // verrou pour detacher seulement: freerdp_disconnect prend des secondes
  // sur un lien mort
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
  // les envois deja en vol, eux, s'attendent
  if FInputIdle.WaitFor(INPUT_DRAIN_MS) <> wrSignaled then
  begin
    // Envoi campe sur un pair mort: on fuit le contexte, en le disant.
    // Mieux qu'un use-after-free discret.
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

{$IFDEF DARWIN}
initialization
  // au demarrage, sur le fil principal: setenv ne supporte pas la concurrence
  EnsureOpenSslModulesPath;
{$ENDIF}

end.
