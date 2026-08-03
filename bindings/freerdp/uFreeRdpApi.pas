unit uFreeRdpApi;

{$mode objfpc}{$H+}

// Binding dynamique FreeRDP 3: chemins absolus, symboles
// verifies, structs lues par offset nomme -- releves par offsetof() contre les
// vrais en-tetes, verifies par uRdpTests.

interface

uses
  SysUtils, ctypes;

const
  FREERDP_MIN_VERSION_MAJOR = 3;

  CTX_OFF_INSTANCE = 0;
  CTX_OFF_SERVERMODE = 16;
  CTX_OFF_LASTERROR = 24;
  CTX_OFF_GDI = 264;
  CTX_OFF_CHANNELS = 288;
  CTX_OFF_INPUT = 304;
  CTX_OFF_UPDATE = 312;
  CTX_OFF_SETTINGS = 320;
  CTX_SIZE = 1024;

  RDP_OFF_CONTEXT = 0;
  RDP_OFF_CLIENTENTRYPOINTS = 8;
  RDP_OFF_CONTEXTSIZE = 256;
  RDP_OFF_CONTEXTNEW = 264;
  RDP_OFF_CONTEXTFREE = 272;
  RDP_OFF_PRECONNECT = 384;
  RDP_OFF_POSTCONNECT = 392;
  RDP_OFF_LOGONERRORINFO = 432;
  RDP_OFF_POSTDISCONNECT = 440;
  RDP_OFF_VERIFYCERTIFICATEEX = 528;
  RDP_OFF_VERIFYCHANGEDCERTIFICATEEX = 536;
  RDP_OFF_AUTHENTICATEEX = 552;
  RDP_SIZE = 640;

  GDI_OFF_CONTEXT = 0;
  GDI_OFF_WIDTH = 8;
  GDI_OFF_HEIGHT = 12;
  GDI_OFF_STRIDE = 16;
  GDI_OFF_DSTFORMAT = 20;
  GDI_OFF_HDC = 32;
  GDI_OFF_PRIMARY = 40;
  GDI_OFF_PRIMARY_BUFFER = 64;

  CTX_OFF_PUBSUB = 144;

  DISP_DVC_NAME = 'Microsoft::Windows::RDS::DisplayControl';
  // GFX: a brancher sur la GDI logicielle a sa connexion, sinon ecran noir
  RDPGFX_DVC_NAME = 'Microsoft::Windows::RDS::Graphics';
  CHANEVT_OFF_NAME = 16;         // ChannelConnectedEventArgs.name
  CHANEVT_OFF_INTERFACE = 24;    // .pInterface (le DispClientContext)
  DISP_OFF_SENDLAYOUT = 24;      // DispClientContext.SendMonitorLayout
  DISPLAY_CONTROL_MONITOR_PRIMARY = $01;

  // cliprdr: canal STATIQUE, charge par load_addins au preconnect
  CLIPRDR_SVC_NAME = 'cliprdr';
  CLIPRDR_OFF_CUSTOM = 8;         // ou l'on range le lien retour vers le transport
  CLIPRDR_OFF_SERVER_CAPABILITIES = 16;
  CLIPRDR_OFF_CLIENT_CAPABILITIES = 24;
  CLIPRDR_OFF_MONITOR_READY = 32;
  CLIPRDR_OFF_CLIENT_FORMAT_LIST = 48;
  CLIPRDR_OFF_SERVER_FORMAT_LIST = 56;
  CLIPRDR_OFF_CLIENT_FORMAT_LIST_RESPONSE = 64;
  CLIPRDR_OFF_SERVER_FORMAT_LIST_RESPONSE = 72;
  CLIPRDR_OFF_CLIENT_FORMAT_DATA_REQUEST = 112;
  CLIPRDR_OFF_SERVER_FORMAT_DATA_REQUEST = 120;
  CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE = 128;
  CLIPRDR_OFF_SERVER_FORMAT_DATA_RESPONSE = 136;

  CB_MONITOR_READY = 1;
  CB_FORMAT_LIST = 2;
  CB_FORMAT_LIST_RESPONSE = 3;
  CB_FORMAT_DATA_REQUEST = 4;
  CB_FORMAT_DATA_RESPONSE = 5;
  CB_CLIP_CAPS = 7;
  CB_RESPONSE_OK = 1;
  CB_RESPONSE_FAIL = 2;
  CB_CAPSTYPE_GENERAL = 1;
  CB_CAPS_VERSION_2 = 2;
  CB_USE_LONG_FORMAT_NAMES = 2;

  CF_TEXT = 1;
  CF_OEMTEXT = 7;
  CF_UNICODETEXT = 13;

  CHANNEL_RC_OK = 0;

  UPD_OFF_CONTEXT = 0;
  UPD_OFF_BEGINPAINT = 72;
  UPD_OFF_ENDPAINT = 80;
  UPD_OFF_DESKTOPRESIZE = 104;

  // Region invalidee gdi->primary->hdc->hwnd->invalid: le hdc de
  // primary, pas gdi->hdc. BITMAP_OFF_HDC suit l'ARCHITECTURE, pas la version.
  {$IFDEF DARWIN}
  BITMAP_OFF_HDC = 288;   // macOS arm64
  {$ELSE}
  BITMAP_OFF_HDC = 296;   // Windows + Linux x86_64
  {$ENDIF}
  DC_OFF_HWND = 48;
  WND_OFF_NINVALID = 4;
  WND_OFF_INVALID = 8;
  RGN_OFF_X = 4;
  RGN_OFF_Y = 8;
  RGN_OFF_W = 12;
  RGN_OFF_H = 16;
  RGN_OFF_NULL = 20;

  EP_OFF_SIZE = 0;
  EP_OFF_VERSION = 4;
  EP_OFF_GLOBALINIT = 16;
  EP_OFF_GLOBALUNINIT = 24;
  EP_OFF_CONTEXTSIZE = 32;
  EP_OFF_CLIENTNEW = 40;
  EP_OFF_CLIENTFREE = 48;
  EP_OFF_CLIENTSTART = 56;
  EP_OFF_CLIENTSTOP = 64;
  EP_SIZE = 72;
  EP_CHECK_BUF_BYTES = 512;

  RDP_CLIENT_INTERFACE_VERSION = 1;

  FreeRDP_ServerHostname = 20;
  FreeRDP_ServerPort = 19;
  FreeRDP_Username = 21;
  FreeRDP_Password = 22;
  FreeRDP_Domain = 23;
  // base du SPN Kerberos: ServerHostname=127.0.0.1 (rebond SSH) casserait l'auth
  FreeRDP_UserSpecifiedServerName = 29;
  FreeRDP_DesktopWidth = 129;
  FreeRDP_DesktopHeight = 130;
  FreeRDP_ColorDepth = 131;
  FreeRDP_ClientHostname = 134;
  FreeRDP_ConfigPath = 1793;
  FreeRDP_UseRdpSecurityLayer = 192;
  FreeRDP_AudioPlayback = 714;
  FreeRDP_AudioCapture = 715;
  FreeRDP_AutoReconnectionEnabled = 832;
  FreeRDP_AutoReconnectMaxRetries = 833;
  FreeRDP_TlsSecurity = 1088;
  FreeRDP_NlaSecurity = 1089;
  FreeRDP_RdpSecurity = 1090;
  FreeRDP_IgnoreCertificate = 1408;
  FreeRDP_CertificateName = 1409;
  FreeRDP_ExternalCertificateManagement = 1415;
  FreeRDP_AutoAcceptCertificate = 1419;
  FreeRDP_DynamicResolutionUpdate = 1558;
  FreeRDP_SoftwareGdi = 1601;
  FreeRDP_GatewayPort = 1985;
  FreeRDP_GatewayHostname = 1986;
  FreeRDP_GatewayUseSameCredentials = 1991;
  FreeRDP_GatewayEnabled = 1992;
  FreeRDP_FastPathOutput = 2308;
  FreeRDP_KeyboardLayout = 2624;
  FreeRDP_FastPathInput = 2630;
  FreeRDP_FrameMarkerCommandEnabled = 3521;
  FreeRDP_SupportGraphicsPipeline = 142;
  FreeRDP_SurfaceCommandsEnabled = 3520;
  FreeRDP_RemoteFxCodec = 3649;
  FreeRDP_NSCodec = 3712;
  FreeRDP_GfxThinClient = 3840;
  FreeRDP_GfxH264 = 3844;
  FreeRDP_GfxAVC444 = 3845;
  FreeRDP_GfxAVC444v2 = 3847;
  FreeRDP_RedirectDrives = 4288;
  FreeRDP_RedirectSmartCards = 4416;
  FreeRDP_RedirectPrinters = 4544;
  FreeRDP_RedirectSerialPorts = 4672;
  FreeRDP_RedirectParallelPorts = 4673;
  FreeRDP_RedirectClipboard = 4800;
  FreeRDP_SupportDynamicChannels = 5059;
  FreeRDP_SupportDisplayControl = 5185;

  PIXEL_FORMAT_BGRX32 = 537135240;
  PIXEL_FORMAT_BGRA32 = 537168008;

  PTR_FLAGS_WHEEL_NEGATIVE = $0100;
  PTR_FLAGS_WHEEL = $0200;
  PTR_FLAGS_HWHEEL = $0400;
  PTR_FLAGS_MOVE = $0800;
  PTR_FLAGS_BUTTON1 = $1000;
  PTR_FLAGS_BUTTON2 = $2000;
  PTR_FLAGS_BUTTON3 = $4000;
  PTR_FLAGS_DOWN = $8000;
  PTR_XFLAGS_BUTTON1 = $0001;
  PTR_XFLAGS_BUTTON2 = $0002;
  PTR_XFLAGS_DOWN = $8000;

  KBD_FLAGS_EXTENDED = $0100;
  KBD_FLAGS_DOWN = $4000;
  KBD_FLAGS_RELEASE = $8000;

  VERIFY_CERT_FLAG_NONE = $00;
  VERIFY_CERT_FLAG_LEGACY = $02;
  VERIFY_CERT_FLAG_REDIRECT = $10;
  VERIFY_CERT_FLAG_GATEWAY = $20;
  VERIFY_CERT_FLAG_CHANGED = $40;
  VERIFY_CERT_FLAG_MISMATCH = $80;
  VERIFY_CERT_FLAG_FP_IS_PEM = $200;

  CERT_REJECT = 0;
  CERT_ACCEPT_PERMANENT = 1;
  CERT_ACCEPT_TEMPORARY = 2;

  FREERDP_ERROR_CONNECT_CANCELLED = 131083;

  WAIT_OBJECT_0 = 0;
  WAIT_TIMEOUT = $102;
  WAIT_FAILED = $FFFFFFFF;

  MAX_EVENT_HANDLES = 64;

type
  EFreeRdpError = class(Exception);

  // opaques: jamais dereferences autrement que par offset nomme
  PFreeRdp = Pointer;
  PRdpContext = Pointer;
  PRdpSettings = Pointer;
  PRdpGdi = Pointer;
  PRdpInput = Pointer;
  HANDLE_ = Pointer;

  cssize_t = PtrInt;

  TpRdpGlobalInit = function: cint; cdecl;
  TpRdpGlobalUninit = procedure; cdecl;
  TpRdpClientNew = function(instance: PFreeRdp; context: PRdpContext): cint; cdecl;
  TpRdpClientFree = procedure(instance: PFreeRdp; context: PRdpContext); cdecl;
  TpRdpClientStart = function(context: PRdpContext): cint; cdecl;
  TpRdpClientStop = function(context: PRdpContext): cint; cdecl;
  TpConnectCallback = function(instance: PFreeRdp): cint; cdecl;
  TpPostDisconnect = procedure(instance: PFreeRdp); cdecl;
  // BeginPaint/EndPaint/DesktopResize recoivent le contexte, pas l'instance
  TpContextCallback = function(context: PRdpContext): cint; cdecl;
  TpVerifyCertificateEx = function(instance: PFreeRdp; host: PAnsiChar;
    port: cuint16; common_name, subject, issuer, fingerprint: PAnsiChar;
    flags: cuint32): cuint32; cdecl;
  // trois args de plus AVANT flags: prototype partage = flags poubelle en MITM
  TpVerifyChangedCertificateEx = function(instance: PFreeRdp;
    host: PAnsiChar; port: cuint16; common_name, subject, issuer,
    new_fingerprint, old_subject, old_issuer, old_fingerprint: PAnsiChar;
    flags: cuint32): cuint32; cdecl;
  TpChannelEvent = procedure(context: PRdpContext; e: Pointer); cdecl;

  TDisplayControlMonitorLayout = packed record
    Flags: cuint32;
    Left, Top: cint32;
    Width, Height: cuint32;
    PhysicalWidth, PhysicalHeight: cuint32;
    Orientation: cuint32;
    DesktopScaleFactor, DeviceScaleFactor: cuint32;
  end;
  PDisplayControlMonitorLayout = ^TDisplayControlMonitorLayout;

  Tdisp_send_layout = function(disp: Pointer; numMonitors: cuint32;
    monitors: PDisplayControlMonitorLayout): cuint32; cdecl;

  TCliprdrHeader = packed record
    msgType: cuint16;
    msgFlags: cuint16;
    dataLen: cuint32;
  end;

  TCliprdrGeneralCapabilitySet = packed record
    capabilitySetType: cuint16;
    capabilitySetLength: cuint16;
    version: cuint32;
    generalFlags: cuint32;
  end;

  TCliprdrCapabilities = packed record
    common: TCliprdrHeader;
    cCapabilitiesSets: cuint32;
    pad0: cuint32;
    capabilitySets: Pointer;
  end;

  TCliprdrFormat = packed record
    formatId: cuint32;
    pad0: cuint32;
    formatName: PAnsiChar;
  end;
  PCliprdrFormat = ^TCliprdrFormat;

  TCliprdrFormatList = packed record
    common: TCliprdrHeader;
    numFormats: cuint32;
    pad0: cuint32;
    formats: PCliprdrFormat;
  end;
  PCliprdrFormatList = ^TCliprdrFormatList;

  TCliprdrFormatListResponse = packed record
    common: TCliprdrHeader;
  end;

  TCliprdrFormatDataRequest = packed record
    common: TCliprdrHeader;
    requestedFormatId: cuint32;
  end;
  PCliprdrFormatDataRequest = ^TCliprdrFormatDataRequest;

  TCliprdrFormatDataResponse = packed record
    common: TCliprdrHeader;
    requestedFormatData: PByte;
  end;
  PCliprdrFormatDataResponse = ^TCliprdrFormatDataResponse;

  TCliprdrFn = function(context: Pointer; msg: Pointer): cuint32; cdecl;
  // variadique en C: 'varargs' obligatoire sur arm64 (meme piege que sqlite3)
  TPubSub_Subscribe = function(pubSub: Pointer;
    eventName: PAnsiChar): cint; cdecl; varargs;

  Tfreerdp_connect = function(instance: PFreeRdp): cint; cdecl;
  Tfreerdp_disconnect = function(instance: PFreeRdp): cint; cdecl;
  Tfreerdp_abort_connect_context = function(context: PRdpContext): cint; cdecl;
  Tfreerdp_shall_disconnect_context = function(context: PRdpContext): cint; cdecl;
  Tfreerdp_get_event_handles = function(context: PRdpContext; events: PPointer;
    count: cuint32): cuint32; cdecl;
  Tfreerdp_check_event_handles = function(context: PRdpContext): cint; cdecl;
  Tfreerdp_get_last_error = function(context: PRdpContext): cuint32; cdecl;
  Tfreerdp_get_last_error_string = function(code: cuint32): PAnsiChar; cdecl;
  Tfreerdp_settings_set_string = function(settings: PRdpSettings; id: cint;
    val: PAnsiChar): cint; cdecl;
  Tfreerdp_settings_set_bool = function(settings: PRdpSettings; id: cint;
    val: cint): cint; cdecl;
  Tfreerdp_settings_set_uint32 = function(settings: PRdpSettings; id: cint;
    val: cuint32): cint; cdecl;
  Tfreerdp_settings_get_bool = function(settings: PRdpSettings;
    id: cint): cint; cdecl;
  Tfreerdp_settings_get_uint32 = function(settings: PRdpSettings;
    id: cint): cuint32; cdecl;
  Tfreerdp_input_send_keyboard_event = function(input: PRdpInput;
    flags: cuint16; code: cuint8): cint; cdecl;
  Tfreerdp_input_send_unicode_keyboard_event = function(input: PRdpInput;
    flags: cuint16; code: cuint16): cint; cdecl;
  Tfreerdp_input_send_mouse_event = function(input: PRdpInput; flags: cuint16;
    x, y: cuint16): cint; cdecl;
  Tfreerdp_input_send_extended_mouse_event = function(input: PRdpInput;
    flags: cuint16; x, y: cuint16): cint; cdecl;
  Tgdi_resize = function(gdi: PRdpGdi; width, height: cuint32): cint; cdecl;
  Tgdi_init = function(instance: PFreeRdp; format: cuint32): cint; cdecl;
  Tgdi_free = procedure(instance: PFreeRdp); cdecl;
  Tgdi_graphics_pipeline_init = function(gdi: PRdpGdi; gfx: Pointer): cint; cdecl;
  Tfreerdp_get_version = procedure(major, minor, revision: pcint); cdecl;
  Tfreerdp_get_version_string = function: PAnsiChar; cdecl;
  Tfreerdp_detect_keyboard_layout_from_system_locale =
    function(keyboardLayoutId: pcuint32): cint; cdecl;

  Tfreerdp_reconnect = function(instance: PFreeRdp): cint; cdecl;

  Tfreerdp_client_context_new = function(ep: Pointer): PRdpContext; cdecl;
  Tfreerdp_client_context_free = procedure(context: PRdpContext); cdecl;
  Tfreerdp_client_load_addins = function(channels: Pointer;
    settings: PRdpSettings): cint; cdecl;

  TWaitForMultipleObjects = function(count: cuint32; handles: PPointer;
    waitAll: cint; ms: cuint32): cuint32; cdecl;

var
  freerdp_connect: Tfreerdp_connect = nil;
  freerdp_disconnect: Tfreerdp_disconnect = nil;
  freerdp_abort_connect_context: Tfreerdp_abort_connect_context = nil;
  freerdp_shall_disconnect_context: Tfreerdp_shall_disconnect_context = nil;
  freerdp_get_event_handles: Tfreerdp_get_event_handles = nil;
  freerdp_check_event_handles: Tfreerdp_check_event_handles = nil;
  freerdp_get_last_error: Tfreerdp_get_last_error = nil;
  freerdp_get_last_error_string: Tfreerdp_get_last_error_string = nil;
  freerdp_settings_set_string: Tfreerdp_settings_set_string = nil;
  freerdp_settings_set_bool: Tfreerdp_settings_set_bool = nil;
  freerdp_settings_set_uint32: Tfreerdp_settings_set_uint32 = nil;
  freerdp_settings_get_bool: Tfreerdp_settings_get_bool = nil;
  freerdp_settings_get_uint32: Tfreerdp_settings_get_uint32 = nil;
  // Optionnel (non-fatal si absent): chargement clavier par locale sous Unix.
  freerdp_detect_keyboard_layout_from_system_locale:
    Tfreerdp_detect_keyboard_layout_from_system_locale = nil;
  freerdp_input_send_keyboard_event: Tfreerdp_input_send_keyboard_event = nil;
  freerdp_input_send_unicode_keyboard_event: Tfreerdp_input_send_unicode_keyboard_event = nil;
  freerdp_input_send_mouse_event: Tfreerdp_input_send_mouse_event = nil;
  freerdp_input_send_extended_mouse_event: Tfreerdp_input_send_extended_mouse_event = nil;
  gdi_init: Tgdi_init = nil;
  gdi_resize: Tgdi_resize = nil;
  gdi_free: Tgdi_free = nil;
  gdi_graphics_pipeline_init: Tgdi_graphics_pipeline_init = nil;
  freerdp_reconnect: Tfreerdp_reconnect = nil;
  freerdp_client_context_new: Tfreerdp_client_context_new = nil;
  freerdp_client_context_free: Tfreerdp_client_context_free = nil;
  freerdp_client_load_addins: Tfreerdp_client_load_addins = nil;
  WaitForMultipleObjects: TWaitForMultipleObjects = nil;
  PubSub_Subscribe: TPubSub_Subscribe = nil;

procedure FreeRdpEnsureLoaded;
function FreeRdpIsLoaded: Boolean;
function FreeRdpVersionString: string;

function CtxInstance(AContext: PRdpContext): PFreeRdp; inline;
function CtxGdi(AContext: PRdpContext): PRdpGdi; inline;
function CtxInput(AContext: PRdpContext): PRdpInput; inline;
function CtxSettings(AContext: PRdpContext): PRdpSettings; inline;
function CtxLastError(AContext: PRdpContext): cuint32; inline;
// a valider par UpdateLayoutValid avant toute ECRITURE des rappels de peinture
function CtxUpdate(AContext: PRdpContext): Pointer; inline;

function RdpContextOf(AInstance: PFreeRdp): PRdpContext; inline;
procedure RdpSetContextSize(AInstance: PFreeRdp; ASize: PtrUInt); inline;
procedure RdpSetPreConnect(AInstance: PFreeRdp; ACb: TpConnectCallback); inline;
procedure RdpSetPostConnect(AInstance: PFreeRdp; ACb: TpConnectCallback); inline;
procedure RdpSetPostDisconnect(AInstance: PFreeRdp; ACb: TpPostDisconnect); inline;
procedure RdpSetVerifyCertificateEx(AInstance: PFreeRdp;
  ACb: TpVerifyCertificateEx); inline;
procedure RdpSetVerifyChangedCertificateEx(AInstance: PFreeRdp;
  ACb: TpVerifyChangedCertificateEx); inline;

function GdiWidth(AGdi: PRdpGdi): cint32; inline;
function GdiHeight(AGdi: PRdpGdi): cint32; inline;
function GdiStride(AGdi: PRdpGdi): cuint32; inline;
function GdiDstFormat(AGdi: PRdpGdi): cuint32; inline;
function GdiPrimaryBuffer(AGdi: PRdpGdi): PByte; inline;

function GdiTakeInvalid(AGdi: PRdpGdi; out AX, AY, AW, AH: Integer): Boolean;
// a appeler depuis BeginPaint
procedure GdiResetInvalid(AGdi: PRdpGdi);

// Shim C (bindings/freerdp/shim): compile contre les vrais en-tetes, il PRIME
// sur les offsets; absent, repli sur eux sous la garde des temoins.
function RdpShimActive: Boolean;
// sous-estimer sizeof(rdpContext) ecraserait ce que le transport range apres
function RdpContextSizeBytes: PtrUInt;
function RdpEntryPointsSize: PtrUInt;
// False si shim absent (l'appelant remplit par offsets) ou tampon trop court
function RdpEpInit(ABuf: Pointer; ALen, ACtxSize: PtrUInt): Boolean;
function RdpEpSetClientNew(ABuf: Pointer; ALen: PtrUInt; ACb: Pointer): Boolean;
function RdpEpSetClientFree(ABuf: Pointer; ALen: PtrUInt; ACb: Pointer): Boolean;

// Temoins: la bibliotheque vient de la MACHINE, pas de nos en-tetes. Un offset
// faux en lecture = ecran noir; en ECRITURE il ecrase la memoire d'autrui.

// A verifier AVANT d'ecrire le moindre rappel dans l'instance. Temoins:
// aller-retour instance->context et RELECTURE du ContextSize qu'on a choisi.
function RdpInstanceLayoutValid(AInstance: PFreeRdp; AContext: PRdpContext;
  AExpectedCtxSize: PtrUInt): Boolean;

// aller-retour update->context: exige AVANT d'ecrire les rappels de peinture
function UpdateLayoutValid(AContext: PRdpContext; AUpdate: Pointer): Boolean;
function GdiLayoutValid(AGdi: PRdpGdi; AExpectW, AExpectH: Integer): Boolean;
// des offsets faux traversent cette chaine sans planter: d'ou la vraisemblance
function GdiInvalidChainValid(AGdi: PRdpGdi): Boolean;

procedure UpdSetBeginPaint(AUpdate: Pointer; ACb: TpContextCallback); inline;
procedure UpdSetEndPaint(AUpdate: Pointer; ACb: TpContextCallback); inline;
procedure UpdSetDesktopResize(AUpdate: Pointer; ACb: TpContextCallback); inline;
function UpdContext(AUpdate: Pointer): PRdpContext; inline;
function CtxPubSub(AContext: PRdpContext): Pointer; inline;
function ChanEvtName(AEvt: Pointer): PAnsiChar; inline;
function ChanEvtInterface(AEvt: Pointer): Pointer; inline;
function DispSendLayoutFn(ADisp: Pointer): Tdisp_send_layout; inline;

function CtxChannels(AContext: PRdpContext): Pointer; inline;
procedure CliprdrSetCustom(ACtx, AData: Pointer); inline;
function CliprdrCustom(ACtx: Pointer): Pointer; inline;
procedure CliprdrSetHandler(ACtx: Pointer; AOffset: Integer; ACb: Pointer); inline;
function CliprdrCall(ACtx: Pointer; AOffset: Integer): TCliprdrFn; inline;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  dynlibs, uLog;

var
  GLibRdp: TLibHandle = NilHandle;
  GLibClient: TLibHandle = NilHandle;
  GLibWinpr: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GVersion: string = '';
  GInitLock: TRTLCriticalSection;

// ---- shim ----
const
  // Contrat binding<->shim; autre version = shim ignore, offsets en dur.
  // 2: poseurs rssh_instance_set_*. 3: poseurs rssh_ep_set_client_new/_free.
  RSSH_SHIM_ABI = 3;

type
  Tsh_u32 = function: cuint32; cdecl;
  Tsh_size = function: PtrUInt; cdecl;
  Tsh_ep_init = function(buf: Pointer; buflen, ctxsize: PtrUInt): cint; cdecl;
  Tsh_ptr_of_ptr = function(p: Pointer): Pointer; cdecl;
  Tsh_u32_of_ptr = function(p: Pointer): cuint32; cdecl;
  Tsh_i32_of_ptr = function(p: Pointer): cint32; cdecl;
  Tsh_take_invalid = function(gdi: Pointer; x, y, w, h: pcint32): cint; cdecl;
  Tsh_int_of_ptr = function(p: Pointer): cint; cdecl;
  Tsh_set_cb = function(p, cb: Pointer): cint; cdecl;
  Tsh_set_size = function(p: Pointer; size: PtrUInt): cint; cdecl;
  Tsh_size_of_ptr = function(p: Pointer): PtrUInt; cdecl;
  Tsh_ep_set_cb = function(buf: Pointer; buflen: PtrUInt; cb: Pointer): cint;
    cdecl;
  Tsh_slot_get = function(p: Pointer; slot: cuint32): Pointer; cdecl;
  Tsh_slot_set = function(p: Pointer; slot: cuint32; cb: Pointer): cint; cdecl;

var
  GShim: TLibHandle = NilHandle;
  GShimOk: Boolean = False;
  GShimCtxSize: PtrUInt = 0;
  GShimEpSize: PtrUInt = 0;

  sh_ep_init: Tsh_ep_init = nil;
  sh_inst_set_ctx_size: Tsh_set_size = nil;
  sh_inst_ctx_size: Tsh_size_of_ptr = nil;
  sh_ep_set_client_new: Tsh_ep_set_cb = nil;
  sh_ep_set_client_free: Tsh_ep_set_cb = nil;
  sh_inst_set_pre_connect: Tsh_set_cb = nil;
  sh_inst_set_post_connect: Tsh_set_cb = nil;
  sh_inst_set_post_disconnect: Tsh_set_cb = nil;
  sh_inst_set_verify_cert: Tsh_set_cb = nil;
  sh_inst_set_verify_changed_cert: Tsh_set_cb = nil;
  sh_ctx_instance: Tsh_ptr_of_ptr = nil;
  sh_ctx_gdi: Tsh_ptr_of_ptr = nil;
  sh_ctx_input: Tsh_ptr_of_ptr = nil;
  sh_ctx_settings: Tsh_ptr_of_ptr = nil;
  sh_ctx_update: Tsh_ptr_of_ptr = nil;
  sh_ctx_channels: Tsh_ptr_of_ptr = nil;
  sh_ctx_pubsub: Tsh_ptr_of_ptr = nil;
  sh_ctx_last_error: Tsh_u32_of_ptr = nil;
  sh_instance_context: Tsh_ptr_of_ptr = nil;
  sh_gdi_width: Tsh_i32_of_ptr = nil;
  sh_gdi_height: Tsh_i32_of_ptr = nil;
  sh_gdi_stride: Tsh_u32_of_ptr = nil;
  sh_gdi_dst_format: Tsh_u32_of_ptr = nil;
  sh_gdi_primary_buffer: Tsh_ptr_of_ptr = nil;
  sh_gdi_take_invalid: Tsh_take_invalid = nil;
  sh_gdi_reset_invalid: Tsh_int_of_ptr = nil;
  sh_gdi_chain_ok: Tsh_int_of_ptr = nil;
  sh_update_context: Tsh_ptr_of_ptr = nil;
  sh_update_set_begin_paint: Tsh_set_cb = nil;
  sh_update_set_end_paint: Tsh_set_cb = nil;
  sh_update_set_desktop_resize: Tsh_set_cb = nil;
  sh_chanevt_name: Tsh_ptr_of_ptr = nil;
  sh_chanevt_interface: Tsh_ptr_of_ptr = nil;
  sh_disp_send_layout: Tsh_ptr_of_ptr = nil;
  sh_cliprdr_set_custom: Tsh_set_cb = nil;
  sh_cliprdr_custom: Tsh_ptr_of_ptr = nil;
  sh_cliprdr_set_handler: Tsh_slot_set = nil;
  sh_cliprdr_call: Tsh_slot_get = nil;

// chemin relatif = dylibs cherchees dans le repertoire courant
function AbsCandidateDir(const P: string): Boolean;
begin
  {$IFDEF WINDOWS}
  // 'C:chemin' est relatif au repertoire courant du lecteur
  Result := ((Length(P) >= 3) and (P[2] = ':') and
             ((P[3] = '\') or (P[3] = '/'))) or
            ((Length(P) >= 2) and (P[1] = '\') and (P[2] = '\'));
  {$ELSE}
  Result := (Length(P) >= 1) and (P[1] = '/');
  {$ENDIF}
end;

function CandidateSets: TStringArray;
var
  exeDir: string;
begin
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  {$IFDEF DARWIN}
  Result := [
    exeDir + '../Frameworks/',
    exeDir,
    '/opt/homebrew/opt/freerdp/lib/',
    '/opt/homebrew/lib/',
    '/usr/local/opt/freerdp/lib/',
    '/usr/local/lib/'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/',
    exeDir,
    '/usr/lib/aarch64-linux-gnu/',
    '/usr/lib/x86_64-linux-gnu/',
    '/usr/lib64/',
    '/usr/lib/'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := [exeDir];
  {$ENDIF}
end;

function LibNames: TStringArray;
begin
  {$IFDEF DARWIN}
  Result := ['libfreerdp3.3.dylib', 'libfreerdp-client3.3.dylib',
    'libwinpr3.3.dylib'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libfreerdp3.so.3', 'libfreerdp-client3.so.3', 'libwinpr3.so.3'];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := ['freerdp3.dll', 'freerdp-client3.dll', 'winpr3.dll'];
  {$ENDIF}
end;

function MustSym(ALib: TLibHandle; const AName: string): Pointer;
begin
  Result := GetProcAddress(ALib, AName);
  if Result = nil then
    raise EFreeRdpError.CreateFmt('FreeRDP: missing symbol: %s', [AName]);
end;

procedure BindSymbols;
begin
  Pointer(freerdp_connect) := MustSym(GLibRdp, 'freerdp_connect');
  Pointer(freerdp_disconnect) := MustSym(GLibRdp, 'freerdp_disconnect');
  Pointer(freerdp_abort_connect_context) :=
    MustSym(GLibRdp, 'freerdp_abort_connect_context');
  Pointer(freerdp_shall_disconnect_context) :=
    MustSym(GLibRdp, 'freerdp_shall_disconnect_context');
  Pointer(freerdp_get_event_handles) :=
    MustSym(GLibRdp, 'freerdp_get_event_handles');
  Pointer(freerdp_check_event_handles) :=
    MustSym(GLibRdp, 'freerdp_check_event_handles');
  Pointer(freerdp_get_last_error) := MustSym(GLibRdp, 'freerdp_get_last_error');
  Pointer(freerdp_get_last_error_string) :=
    MustSym(GLibRdp, 'freerdp_get_last_error_string');
  Pointer(freerdp_settings_set_string) :=
    MustSym(GLibRdp, 'freerdp_settings_set_string');
  Pointer(freerdp_settings_set_bool) :=
    MustSym(GLibRdp, 'freerdp_settings_set_bool');
  Pointer(freerdp_settings_set_uint32) :=
    MustSym(GLibRdp, 'freerdp_settings_set_uint32');
  Pointer(freerdp_settings_get_bool) :=
    MustSym(GLibRdp, 'freerdp_settings_get_bool');
  Pointer(freerdp_settings_get_uint32) :=
    MustSym(GLibRdp, 'freerdp_settings_get_uint32');
  Pointer(freerdp_detect_keyboard_layout_from_system_locale) :=
    GetProcAddress(GLibRdp, 'freerdp_detect_keyboard_layout_from_system_locale');
  Pointer(freerdp_input_send_keyboard_event) :=
    MustSym(GLibRdp, 'freerdp_input_send_keyboard_event');
  Pointer(freerdp_input_send_unicode_keyboard_event) :=
    MustSym(GLibRdp, 'freerdp_input_send_unicode_keyboard_event');
  Pointer(freerdp_input_send_mouse_event) :=
    MustSym(GLibRdp, 'freerdp_input_send_mouse_event');
  Pointer(freerdp_input_send_extended_mouse_event) :=
    MustSym(GLibRdp, 'freerdp_input_send_extended_mouse_event');
  Pointer(gdi_init) := MustSym(GLibRdp, 'gdi_init');
  Pointer(gdi_graphics_pipeline_init) :=
    MustSym(GLibRdp, 'gdi_graphics_pipeline_init');
  Pointer(gdi_resize) := MustSym(GLibRdp, 'gdi_resize');
  Pointer(gdi_free) := MustSym(GLibRdp, 'gdi_free');
  Pointer(freerdp_reconnect) := MustSym(GLibRdp, 'freerdp_reconnect');
  Pointer(freerdp_client_context_new) :=
    MustSym(GLibClient, 'freerdp_client_context_new');
  Pointer(freerdp_client_context_free) :=
    MustSym(GLibClient, 'freerdp_client_context_free');
  Pointer(freerdp_client_load_addins) :=
    MustSym(GLibClient, 'freerdp_client_load_addins');
  // winpr3.dll ne reexporte pas WaitForMultipleObjects sous Windows: kernel32
  // natif (les handles FreeRDP y sont de vrais handles Windows)
  {$IFDEF WINDOWS}
  Pointer(WaitForMultipleObjects) :=
    MustSym(GetModuleHandle('kernel32.dll'), 'WaitForMultipleObjects');
  {$ELSE}
  Pointer(WaitForMultipleObjects) :=
    MustSym(GLibWinpr, 'WaitForMultipleObjects');
  {$ENDIF}
  Pointer(PubSub_Subscribe) := MustSym(GLibWinpr, 'PubSub_Subscribe');
end;

// Temoins d'ABI au chargement: refus propre plutot que corruption en session.
// Seuls les offsets atteignables sans connexion sont couverts.
procedure CheckFreeRdpStructLayout;
var
  ep: array[0..EP_CHECK_BUF_BYTES - 1] of Byte;
  ctx, inst: Pointer;
  ctxSize: PtrUInt;
  ok: Boolean;
begin
  FillChar(ep, SizeOf(ep), 0);
  ctxSize := RdpContextSizeBytes + SizeOf(Pointer);
  if RdpShimActive then
  begin
    // le shim fait AUTORITE: son refus n'autorise pas le repli sur les offsets
    if RdpEntryPointsSize > PtrUInt(SizeOf(ep)) then
      raise EFreeRdpError.CreateFmt('Incompatible FreeRDP (%s): entry points ' +
        'are %d bytes, buffer holds %d. RDP is disabled with this library.',
        [GVersion, PtrInt(RdpEntryPointsSize), SizeOf(ep)]);
    if not RdpEpInit(@ep[0], SizeOf(ep), ctxSize) then
      raise EFreeRdpError.CreateFmt('Incompatible FreeRDP (%s): the layout ' +
        'oracle refused to initialise the entry points. RDP is disabled with ' +
        'this library.', [GVersion]);
  end
  else
  begin
    PLongWord(@ep[EP_OFF_SIZE])^ := EP_SIZE;
    PLongWord(@ep[EP_OFF_VERSION])^ := RDP_CLIENT_INTERFACE_VERSION;
    PPtrUInt(@ep[EP_OFF_CONTEXTSIZE])^ := ctxSize;
  end;
  ctx := freerdp_client_context_new(@ep[0]);
  if ctx = nil then
    raise EFreeRdpError.CreateFmt('Incompatible FreeRDP (%s): cannot create a ' +
      'client context. RDP is disabled with this library.', [GVersion]);
  try
    inst := CtxInstance(ctx);
    ok := (inst <> nil)
      and RdpInstanceLayoutValid(inst, ctx, ctxSize)
      and (CtxSettings(ctx) <> nil)
      and (freerdp_settings_get_uint32(CtxSettings(ctx), FreeRDP_ServerPort)
             = 3389);
  finally
    freerdp_client_context_free(ctx);
  end;
  if not ok then
    raise EFreeRdpError.CreateFmt('Incompatible FreeRDP (%s): the struct ' +
      'layout does not match the expected offsets. RDP is disabled with this ' +
      'library.', [GVersion]);
end;


// ---- chargement du shim ----

function ShimNames: TStringArray;
begin
  {$IFDEF DARWIN}
  Result := ['librssh_rdp_shim.dylib'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['librssh_rdp_shim.so'];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := ['rssh_rdp_shim.dll'];
  {$ENDIF}
end;

function ShimDirs: TStringArray;
var
  exeDir: string;
begin
  exeDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  // chemins ABSOLUS a cote de l'exe, jamais le PATH
  Result := [
    exeDir + 'lib' + PathDelim,
    exeDir,
    exeDir + '..' + PathDelim + 'Frameworks' + PathDelim,
    exeDir + '..' + PathDelim + '..' + PathDelim + 'lib' + PathDelim
  ];
end;

// toute anomalie desactive le shim en entier: jamais un shim a moitie lie
procedure LoadRdpShim(AMajor, AMinor: Integer);
var
  dir, path: string;
  names: TStringArray;
  ver, built: Tsh_u32;
  ctxSz, epSz: Tsh_size;
  bMaj, bMin: Integer;

  function Sym(const AName: string): Pointer;
  begin
    Result := GetProcAddress(GShim, AName);
    if Result = nil then
      GShimOk := False;
  end;

begin
  GShimOk := False;
  names := ShimNames;
  for dir in ShimDirs do
  begin
    if not AbsCandidateDir(dir) then Continue;
    path := dir + names[0];
    if not FileExists(path) then Continue;
    GShim := LoadLibrary(path);
    if GShim <> NilHandle then Break;
  end;
  if GShim = NilHandle then Exit;

  Pointer(ver) := GetProcAddress(GShim, 'rssh_abi_version');
  if not Assigned(ver) then
  begin
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;
  if ver() <> RSSH_SHIM_ABI then
  begin
    LogError(Format('rdp: shim ABI %d ignored (expected %d)',
      [ver(), RSSH_SHIM_ABI]));
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;

  Pointer(built) := GetProcAddress(GShim, 'rssh_built_version');
  if not Assigned(built) then
  begin
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;
  bMaj := Integer(built() div 10000);
  bMin := Integer((built() div 100) mod 100);
  if bMaj <> AMajor then
  begin
    LogError(Format('rdp: shim built for FreeRDP %d.%d, loaded %d.%d ' +
      '-- ignored', [bMaj, bMin, AMajor, AMinor]));
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;
  // MINEURE exigee a l'identique: des offsets bougent d'une mineure a l'autre
  // (BITMAP_OFF_HDC); rebatir via scripts/build-rdp-shim.sh pour le reactiver.
  if bMin <> AMinor then
  begin
    LogWarning(Format('rdp: shim built for FreeRDP %d.%d, loaded %d.%d ' +
      '-- ignored (rebuild it against the loaded library to re-enable it)',
      [bMaj, bMin, AMajor, AMinor]));
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;

  GShimOk := True;
  Pointer(ctxSz) := Sym('rssh_sizeof_context');
  Pointer(epSz) := Sym('rssh_sizeof_entry_points');
  Pointer(sh_ep_init) := Sym('rssh_ep_init');
  Pointer(sh_inst_ctx_size) := Sym('rssh_instance_context_size');
  Pointer(sh_ep_set_client_new) := Sym('rssh_ep_set_client_new');
  Pointer(sh_ep_set_client_free) := Sym('rssh_ep_set_client_free');
  Pointer(sh_inst_set_ctx_size) := Sym('rssh_instance_set_context_size');
  Pointer(sh_inst_set_pre_connect) := Sym('rssh_instance_set_pre_connect');
  Pointer(sh_inst_set_post_connect) := Sym('rssh_instance_set_post_connect');
  Pointer(sh_inst_set_post_disconnect) :=
    Sym('rssh_instance_set_post_disconnect');
  Pointer(sh_inst_set_verify_cert) :=
    Sym('rssh_instance_set_verify_certificate_ex');
  Pointer(sh_inst_set_verify_changed_cert) :=
    Sym('rssh_instance_set_verify_changed_certificate_ex');
  Pointer(sh_ctx_instance) := Sym('rssh_ctx_instance');
  Pointer(sh_ctx_gdi) := Sym('rssh_ctx_gdi');
  Pointer(sh_ctx_input) := Sym('rssh_ctx_input');
  Pointer(sh_ctx_settings) := Sym('rssh_ctx_settings');
  Pointer(sh_ctx_update) := Sym('rssh_ctx_update');
  Pointer(sh_ctx_channels) := Sym('rssh_ctx_channels');
  Pointer(sh_ctx_pubsub) := Sym('rssh_ctx_pubsub');
  Pointer(sh_ctx_last_error) := Sym('rssh_ctx_last_error');
  Pointer(sh_instance_context) := Sym('rssh_instance_context');
  Pointer(sh_gdi_width) := Sym('rssh_gdi_width');
  Pointer(sh_gdi_height) := Sym('rssh_gdi_height');
  Pointer(sh_gdi_stride) := Sym('rssh_gdi_stride');
  Pointer(sh_gdi_dst_format) := Sym('rssh_gdi_dst_format');
  Pointer(sh_gdi_primary_buffer) := Sym('rssh_gdi_primary_buffer');
  Pointer(sh_gdi_take_invalid) := Sym('rssh_gdi_take_invalid');
  Pointer(sh_gdi_reset_invalid) := Sym('rssh_gdi_reset_invalid');
  Pointer(sh_gdi_chain_ok) := Sym('rssh_gdi_invalid_chain_ok');
  Pointer(sh_update_context) := Sym('rssh_update_context');
  Pointer(sh_update_set_begin_paint) := Sym('rssh_update_set_begin_paint');
  Pointer(sh_update_set_end_paint) := Sym('rssh_update_set_end_paint');
  Pointer(sh_update_set_desktop_resize) := Sym('rssh_update_set_desktop_resize');
  Pointer(sh_chanevt_name) := Sym('rssh_chanevt_name');
  Pointer(sh_chanevt_interface) := Sym('rssh_chanevt_interface');
  Pointer(sh_disp_send_layout) := Sym('rssh_disp_send_layout');
  Pointer(sh_cliprdr_set_custom) := Sym('rssh_cliprdr_set_custom');
  Pointer(sh_cliprdr_custom) := Sym('rssh_cliprdr_custom');
  Pointer(sh_cliprdr_set_handler) := Sym('rssh_cliprdr_set_handler');
  Pointer(sh_cliprdr_call) := Sym('rssh_cliprdr_call');

  if GShimOk then
  begin
    GShimCtxSize := ctxSz();
    GShimEpSize := epSz();
    if (GShimCtxSize < 64) or (GShimCtxSize > 64 * 1024) or
       (GShimEpSize < 16) or (GShimEpSize > 4 * 1024) then
      GShimOk := False;
  end;

  if not GShimOk then
  begin
    LogError('rdp: shim incomplete, falling back to hardcoded offsets');
    UnloadLibrary(GShim);
    GShim := NilHandle;
    Exit;
  end;
  LogDebug(Format('rdp: shim active (sizeof rdpContext=%d, entry points=%d)',
    [GShimCtxSize, GShimEpSize]));
end;

function RdpShimActive: Boolean;
begin
  Result := GShimOk;
end;

function RdpContextSizeBytes: PtrUInt;
begin
  if GShimOk then
    Result := GShimCtxSize
  else
    Result := CTX_SIZE;
end;

function RdpEntryPointsSize: PtrUInt;
begin
  if GShimOk then
    Result := GShimEpSize
  else
    Result := EP_SIZE;
end;

function RdpEpInit(ABuf: Pointer; ALen, ACtxSize: PtrUInt): Boolean;
begin
  Result := GShimOk and Assigned(sh_ep_init) and
            (sh_ep_init(ABuf, ALen, ACtxSize) <> 0);
end;

function RdpEpSetClientNew(ABuf: Pointer; ALen: PtrUInt; ACb: Pointer): Boolean;
begin
  if GShimOk then
    Exit(sh_ep_set_client_new(ABuf, ALen, ACb) <> 0);
  if ALen < EP_SIZE then Exit(False);
  PPointer(PByte(ABuf) + EP_OFF_CLIENTNEW)^ := ACb;
  Result := True;
end;

function RdpEpSetClientFree(ABuf: Pointer; ALen: PtrUInt; ACb: Pointer): Boolean;
begin
  if GShimOk then
    Exit(sh_ep_set_client_free(ABuf, ALen, ACb) <> 0);
  if ALen < EP_SIZE then Exit(False);
  PPointer(PByte(ABuf) + EP_OFF_CLIENTFREE)^ := ACb;
  Result := True;
end;

procedure FreeRdpEnsureLoaded;
var
  dir: string;
  names: TStringArray;
  getVer: Tfreerdp_get_version;
  getVerStr: Tfreerdp_get_version_string;
  maj, min_, rev: cint;
begin
  if GReady then Exit;
  EnterCriticalSection(GInitLock);
  try
  if GReady then Exit;
  names := LibNames;
  for dir in CandidateSets do
    if AbsCandidateDir(dir) and
       FileExists(dir + names[0]) and FileExists(dir + names[1]) and
       FileExists(dir + names[2]) then
    begin
      GLibRdp := LoadLibrary(dir + names[0]);
      GLibClient := LoadLibrary(dir + names[1]);
      GLibWinpr := LoadLibrary(dir + names[2]);
      if (GLibRdp <> NilHandle) and (GLibClient <> NilHandle) and
         (GLibWinpr <> NilHandle) then
        Break;
      if GLibRdp <> NilHandle then UnloadLibrary(GLibRdp);
      if GLibClient <> NilHandle then UnloadLibrary(GLibClient);
      if GLibWinpr <> NilHandle then UnloadLibrary(GLibWinpr);
      GLibRdp := NilHandle;
      GLibClient := NilHandle;
      GLibWinpr := NilHandle;
    end;
  if (GLibRdp = NilHandle) or (GLibClient = NilHandle) or
     (GLibWinpr = NilHandle) then
    raise EFreeRdpError.Create(
      'FreeRDP not found in the expected locations');

  BindSymbols;

  // autre majeure = corruption memoire silencieuse: on refuse
  Pointer(getVer) := MustSym(GLibRdp, 'freerdp_get_version');
  Pointer(getVerStr) := MustSym(GLibRdp, 'freerdp_get_version_string');
  GVersion := string(AnsiString(getVerStr()));
  maj := 0;
  min_ := 0;
  rev := 0;
  getVer(@maj, @min_, @rev);
  if maj <> FREERDP_MIN_VERSION_MAJOR then
    raise EFreeRdpError.CreateFmt(
      'FreeRDP: incompatible major version %d (expected %d)',
      [maj, FREERDP_MIN_VERSION_MAJOR]);
  // shim charge AVANT les temoins: ils empruntent le meme chemin que la session
  LoadRdpShim(maj, min_);
  CheckFreeRdpStructLayout;
  GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function FreeRdpIsLoaded: Boolean;
begin
  Result := GReady;
end;

function FreeRdpVersionString: string;
begin
  if GReady then
    Result := GVersion
  else
    Result := '';
end;

function CtxInstance(AContext: PRdpContext): PFreeRdp;
begin
  if GShimOk then Exit(sh_ctx_instance(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_INSTANCE)^;
end;

function CtxGdi(AContext: PRdpContext): PRdpGdi;
begin
  if GShimOk then Exit(sh_ctx_gdi(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_GDI)^;
end;

function CtxInput(AContext: PRdpContext): PRdpInput;
begin
  if GShimOk then Exit(sh_ctx_input(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_INPUT)^;
end;

function CtxSettings(AContext: PRdpContext): PRdpSettings;
begin
  if GShimOk then Exit(sh_ctx_settings(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_SETTINGS)^;
end;

function CtxLastError(AContext: PRdpContext): cuint32;
begin
  if GShimOk then Exit(sh_ctx_last_error(AContext));
  Result := pcuint32(PByte(AContext) + CTX_OFF_LASTERROR)^;
end;

function CtxUpdate(AContext: PRdpContext): Pointer;
begin
  if GShimOk then Exit(sh_ctx_update(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_UPDATE)^;
end;

function RdpContextOf(AInstance: PFreeRdp): PRdpContext;
begin
  if GShimOk then Exit(sh_instance_context(AInstance));
  Result := PPointer(PByte(AInstance) + RDP_OFF_CONTEXT)^;
end;

procedure RdpSetContextSize(AInstance: PFreeRdp; ASize: PtrUInt);
begin
  if GShimOk then
  begin
    sh_inst_set_ctx_size(AInstance, ASize);
    Exit;
  end;
  PPtrUInt(PByte(AInstance) + RDP_OFF_CONTEXTSIZE)^ := ASize;
end;

procedure RdpSetPreConnect(AInstance: PFreeRdp; ACb: TpConnectCallback);
begin
  if GShimOk then
  begin
    sh_inst_set_pre_connect(AInstance, ACb);
    Exit;
  end;
  PPointer(PByte(AInstance) + RDP_OFF_PRECONNECT)^ := ACb;
end;

procedure RdpSetPostConnect(AInstance: PFreeRdp; ACb: TpConnectCallback);
begin
  if GShimOk then
  begin
    sh_inst_set_post_connect(AInstance, ACb);
    Exit;
  end;
  PPointer(PByte(AInstance) + RDP_OFF_POSTCONNECT)^ := ACb;
end;

procedure RdpSetPostDisconnect(AInstance: PFreeRdp; ACb: TpPostDisconnect);
begin
  if GShimOk then
  begin
    sh_inst_set_post_disconnect(AInstance, ACb);
    Exit;
  end;
  PPointer(PByte(AInstance) + RDP_OFF_POSTDISCONNECT)^ := ACb;
end;

procedure RdpSetVerifyCertificateEx(AInstance: PFreeRdp;
  ACb: TpVerifyCertificateEx);
begin
  if GShimOk then
  begin
    sh_inst_set_verify_cert(AInstance, ACb);
    Exit;
  end;
  PPointer(PByte(AInstance) + RDP_OFF_VERIFYCERTIFICATEEX)^ := ACb;
end;

procedure RdpSetVerifyChangedCertificateEx(AInstance: PFreeRdp;
  ACb: TpVerifyChangedCertificateEx);
begin
  if GShimOk then
  begin
    sh_inst_set_verify_changed_cert(AInstance, ACb);
    Exit;
  end;
  PPointer(PByte(AInstance) + RDP_OFF_VERIFYCHANGEDCERTIFICATEEX)^ := ACb;
end;

function GdiWidth(AGdi: PRdpGdi): cint32;
begin
  if GShimOk then Exit(sh_gdi_width(AGdi));
  Result := pcint32(PByte(AGdi) + GDI_OFF_WIDTH)^;
end;

function GdiHeight(AGdi: PRdpGdi): cint32;
begin
  if GShimOk then Exit(sh_gdi_height(AGdi));
  Result := pcint32(PByte(AGdi) + GDI_OFF_HEIGHT)^;
end;

function GdiStride(AGdi: PRdpGdi): cuint32;
begin
  if GShimOk then Exit(sh_gdi_stride(AGdi));
  Result := pcuint32(PByte(AGdi) + GDI_OFF_STRIDE)^;
end;

function GdiDstFormat(AGdi: PRdpGdi): cuint32;
begin
  if GShimOk then Exit(sh_gdi_dst_format(AGdi));
  Result := pcuint32(PByte(AGdi) + GDI_OFF_DSTFORMAT)^;
end;

function GdiPrimaryBuffer(AGdi: PRdpGdi): PByte;
begin
  if GShimOk then Exit(sh_gdi_primary_buffer(AGdi));
  Result := PPointer(PByte(AGdi) + GDI_OFF_PRIMARY_BUFFER)^;
end;

function GdiInvalidRgn(AGdi: PRdpGdi): Pointer;
var
  prim, hdc, hwnd: Pointer;
begin
  Result := nil;
  if AGdi = nil then Exit;
  prim := PPointer(PByte(AGdi) + GDI_OFF_PRIMARY)^;
  if prim = nil then Exit;
  hdc := PPointer(PByte(prim) + BITMAP_OFF_HDC)^;
  if hdc = nil then Exit;
  hwnd := PPointer(PByte(hdc) + DC_OFF_HWND)^;
  if hwnd = nil then Exit;
  Result := PPointer(PByte(hwnd) + WND_OFF_INVALID)^;
end;

procedure GdiResetInvalid(AGdi: PRdpGdi);
var
  prim, hdc, hwnd, rgn: Pointer;
begin
  if GShimOk then
  begin
    sh_gdi_reset_invalid(AGdi);
    Exit;
  end;
  rgn := GdiInvalidRgn(AGdi);
  if rgn = nil then Exit;
  // sans cette remise a zero, la region grossit: tout l'ecran a chaque frame
  pcint32(PByte(rgn) + RGN_OFF_NULL)^ := 1;
  prim := PPointer(PByte(AGdi) + GDI_OFF_PRIMARY)^;
  hdc := PPointer(PByte(prim) + BITMAP_OFF_HDC)^;
  hwnd := PPointer(PByte(hdc) + DC_OFF_HWND)^;
  pcint32(PByte(hwnd) + WND_OFF_NINVALID)^ := 0;
end;

function GdiTakeInvalid(AGdi: PRdpGdi; out AX, AY, AW, AH: Integer): Boolean;
var
  rgn: Pointer;
  x, y, w, h: cint32;
begin
  Result := False;
  AX := 0; AY := 0; AW := 0; AH := 0;
  if GShimOk then
  begin
    x := 0; y := 0; w := 0; h := 0;
    if sh_gdi_take_invalid(AGdi, @x, @y, @w, @h) = 0 then Exit;
    AX := x; AY := y; AW := w; AH := h;
    Exit(True);
  end;
  rgn := GdiInvalidRgn(AGdi);
  if rgn = nil then Exit;
  // 'null' vaut TRUE quand la region ne contient rien
  if pcint32(PByte(rgn) + RGN_OFF_NULL)^ <> 0 then Exit;
  AX := pcint32(PByte(rgn) + RGN_OFF_X)^;
  AY := pcint32(PByte(rgn) + RGN_OFF_Y)^;
  AW := pcint32(PByte(rgn) + RGN_OFF_W)^;
  AH := pcint32(PByte(rgn) + RGN_OFF_H)^;
  Result := (AW > 0) and (AH > 0);
end;

function UpdContext(AUpdate: Pointer): PRdpContext;
begin
  if GShimOk then Exit(sh_update_context(AUpdate));
  Result := PPointer(PByte(AUpdate) + UPD_OFF_CONTEXT)^;
end;

procedure UpdSetBeginPaint(AUpdate: Pointer; ACb: TpContextCallback);
begin
  if GShimOk then
  begin
    sh_update_set_begin_paint(AUpdate, ACb);
    Exit;
  end;
  PPointer(PByte(AUpdate) + UPD_OFF_BEGINPAINT)^ := ACb;
end;

function RdpInstanceLayoutValid(AInstance: PFreeRdp; AContext: PRdpContext;
  AExpectedCtxSize: PtrUInt): Boolean;
begin
  Result := False;
  if (AInstance = nil) or (AContext = nil) then Exit;
  if RdpContextOf(AInstance) <> AContext then Exit;

  if GShimOk then
  begin
    // relire aux offsets Pascal rejetterait a tort une lib saine: on confirme
    // seulement ContextSize, par le shim
    Result := sh_inst_ctx_size(AInstance) = AExpectedCtxSize;
    Exit;
  end;

  if PPtrUInt(PByte(AInstance) + RDP_OFF_CONTEXTSIZE)^ <> AExpectedCtxSize then
    Exit;
  // ContextNew/Free: fenetre aveugle reduite a une insertion entre 272 et 384;
  // les offsets d'ECRITURE, eux, se prouvent par scripts/gen-rdp-offsets.c (CI)
  if PPointer(PByte(AInstance) + RDP_OFF_CONTEXTNEW)^ = nil then Exit;
  if PPointer(PByte(AInstance) + RDP_OFF_CONTEXTFREE)^ = nil then Exit;
  Result := True;
end;

function UpdateLayoutValid(AContext: PRdpContext; AUpdate: Pointer): Boolean;
begin
  Result := (AContext <> nil) and (AUpdate <> nil) and
            (UpdContext(AUpdate) = AContext);
end;

function GdiLayoutValid(AGdi: PRdpGdi; AExpectW, AExpectH: Integer): Boolean;
begin
  Result := False;
  if (AGdi = nil) or (AExpectW <= 0) or (AExpectH <= 0) then Exit;
  if GdiWidth(AGdi) <> cint32(AExpectW) then Exit;
  if GdiHeight(AGdi) <> cint32(AExpectH) then Exit;
  // 4 octets par pixel: on demande PIXEL_FORMAT_BGRX32 a gdi_init.
  if GdiStride(AGdi) < cuint32(AExpectW) * 4 then Exit;
  if GdiPrimaryBuffer(AGdi) = nil then Exit;
  Result := True;
end;

function GdiInvalidChainValid(AGdi: PRdpGdi): Boolean;
var
  rgn: Pointer;
  x, y, w, h, nul, gw, gh: cint32;
begin
  Result := False;
  if GShimOk then
  begin
    Result := sh_gdi_chain_ok(AGdi) <> 0;
    Exit;
  end;
  rgn := GdiInvalidRgn(AGdi);
  if rgn = nil then Exit;
  // 'null' est un booleen GDI: toute autre valeur signe une lecture a cote.
  nul := pcint32(PByte(rgn) + RGN_OFF_NULL)^;
  if (nul <> 0) and (nul <> 1) then Exit;
  x := pcint32(PByte(rgn) + RGN_OFF_X)^;
  y := pcint32(PByte(rgn) + RGN_OFF_Y)^;
  w := pcint32(PByte(rgn) + RGN_OFF_W)^;
  h := pcint32(PByte(rgn) + RGN_OFF_H)^;
  if (x < 0) or (y < 0) or (w < 0) or (h < 0) then Exit;
  gw := GdiWidth(AGdi);
  gh := GdiHeight(AGdi);
  if (x > gw) or (y > gh) or (w > gw) or (h > gh) then Exit;
  Result := True;
end;

function CtxPubSub(AContext: PRdpContext): Pointer;
begin
  if GShimOk then Exit(sh_ctx_pubsub(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_PUBSUB)^;
end;

function ChanEvtName(AEvt: Pointer): PAnsiChar;
begin
  if GShimOk then Exit(PAnsiChar(sh_chanevt_name(AEvt)));
  Result := PPointer(PByte(AEvt) + CHANEVT_OFF_NAME)^;
end;

function ChanEvtInterface(AEvt: Pointer): Pointer;
begin
  if GShimOk then Exit(sh_chanevt_interface(AEvt));
  Result := PPointer(PByte(AEvt) + CHANEVT_OFF_INTERFACE)^;
end;

function DispSendLayoutFn(ADisp: Pointer): Tdisp_send_layout;
begin
  if ADisp = nil then
    Exit(nil);
  if GShimOk then
    Exit(Tdisp_send_layout(sh_disp_send_layout(ADisp)));
  Result := Tdisp_send_layout(PPointer(PByte(ADisp) + DISP_OFF_SENDLAYOUT)^);
end;

function CtxChannels(AContext: PRdpContext): Pointer;
begin
  if GShimOk then Exit(sh_ctx_channels(AContext));
  Result := PPointer(PByte(AContext) + CTX_OFF_CHANNELS)^;
end;

// decalage -> slot nomme du shim (enum rssh_cliprdr_slot); False hors table
function ClipSlotOfOffset(AOffset: Integer; out ASlot: cuint32): Boolean;
begin
  Result := True;
  case AOffset of
    CLIPRDR_OFF_SERVER_CAPABILITIES:          ASlot := 0;
    CLIPRDR_OFF_CLIENT_CAPABILITIES:          ASlot := 1;
    CLIPRDR_OFF_MONITOR_READY:                ASlot := 2;
    CLIPRDR_OFF_CLIENT_FORMAT_LIST:           ASlot := 3;
    CLIPRDR_OFF_SERVER_FORMAT_LIST:           ASlot := 4;
    CLIPRDR_OFF_CLIENT_FORMAT_LIST_RESPONSE:  ASlot := 5;
    CLIPRDR_OFF_SERVER_FORMAT_LIST_RESPONSE:  ASlot := 6;
    CLIPRDR_OFF_CLIENT_FORMAT_DATA_REQUEST:   ASlot := 7;
    CLIPRDR_OFF_SERVER_FORMAT_DATA_REQUEST:   ASlot := 8;
    CLIPRDR_OFF_CLIENT_FORMAT_DATA_RESPONSE:  ASlot := 9;
    CLIPRDR_OFF_SERVER_FORMAT_DATA_RESPONSE:  ASlot := 10;
  else
    ASlot := 0;
    Result := False;
  end;
end;

procedure CliprdrSetCustom(ACtx, AData: Pointer);
begin
  if GShimOk then
  begin
    sh_cliprdr_set_custom(ACtx, AData);
    Exit;
  end;
  PPointer(PByte(ACtx) + CLIPRDR_OFF_CUSTOM)^ := AData;
end;

function CliprdrCustom(ACtx: Pointer): Pointer;
begin
  if GShimOk then Exit(sh_cliprdr_custom(ACtx));
  Result := PPointer(PByte(ACtx) + CLIPRDR_OFF_CUSTOM)^;
end;

procedure CliprdrSetHandler(ACtx: Pointer; AOffset: Integer; ACb: Pointer);
var
  slot: cuint32;
begin
  if GShimOk then
  begin
    // slot inconnu: on n'ecrit rien plutot qu'un pointeur au hasard
    if ClipSlotOfOffset(AOffset, slot) then
      sh_cliprdr_set_handler(ACtx, slot, ACb);
    Exit;
  end;
  PPointer(PByte(ACtx) + AOffset)^ := ACb;
end;

function CliprdrCall(ACtx: Pointer; AOffset: Integer): TCliprdrFn;
var
  slot: cuint32;
begin
  if GShimOk then
  begin
    if not ClipSlotOfOffset(AOffset, slot) then
      Exit(nil);
    Exit(TCliprdrFn(sh_cliprdr_call(ACtx, slot)));
  end;
  if ACtx = nil then
    Exit(nil);
  Result := TCliprdrFn(PPointer(PByte(ACtx) + AOffset)^);
end;

procedure UpdSetEndPaint(AUpdate: Pointer; ACb: TpContextCallback);
begin
  if GShimOk then
  begin
    sh_update_set_end_paint(AUpdate, ACb);
    Exit;
  end;
  PPointer(PByte(AUpdate) + UPD_OFF_ENDPAINT)^ := ACb;
end;

procedure UpdSetDesktopResize(AUpdate: Pointer; ACb: TpContextCallback);
begin
  if GShimOk then
  begin
    sh_update_set_desktop_resize(AUpdate, ACb);
    Exit;
  end;
  PPointer(PByte(AUpdate) + UPD_OFF_DESKTOPRESIZE)^ := ACb;
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  // pas de dechargement (comme libssh2): des threads de session tournent encore
  DoneCriticalSection(GInitLock);
end.
