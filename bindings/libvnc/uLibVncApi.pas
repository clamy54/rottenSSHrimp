unit uLibVncApi;

{$mode objfpc}{$H+}

// Binding dynamique libvncclient 0.9.x, charge par chemins absolus. Acces par
// OFFSET: la disposition de rfbClient depend des options de compilation. Pieges:
// rfbBool est un int8_t; rfbInitClient LIBERE le client quand il echoue.

interface

uses
  SysUtils, ctypes, {$IFDEF WINDOWS}Windows,{$ENDIF} dynlibs;

type
  EVncError = class(Exception);

  PVncClient = Pointer;

const
  // Offsets rfbClient (scripts/gen-vnc-offsets.c), trois jeux: SOCKET et
  // pthread_mutex_t n'ont pas la meme taille selon l'OS. Ils supposent TOUS la
  // config epinglee de build-libvnc.sh: zlib ET JPEG actifs, TLS/SASL absents.
  // Sans JPEG, clientData recule de 32 octets et sizeof de 40 -- assez pour
  // passer le controle de taille et echouer sur la disposition.
  // scripts/check-vnc-offsets.sh confronte cette table a la lib construite.
{$IFDEF WINDOWS}
  VNC_OFF_FRAMEBUFFER          = 0;
  VNC_OFF_WIDTH                = 8;
  VNC_OFF_HEIGHT               = 12;
  VNC_OFF_APPDATA              = 24;
  VNC_OFF_PROGRAMNAME          = 72;
  VNC_OFF_SERVERHOST           = 80;
  VNC_OFF_SERVERPORT           = 88;
  VNC_OFF_UPDATERECT           = 104;
  VNC_OFF_SOCK                 = 307320;
  VNC_OFF_LISTENSPECIFIED      = 92;
  VNC_OFF_CONNECTTIMEOUT       = 359792;
  VNC_OFF_READTIMEOUT          = 359796;
  VNC_OFF_DESKTOPNAME          = 307336;
  VNC_OFF_FORMAT               = 307344;
  VNC_OFF_SI                   = 307360;
  VNC_OFF_CLIENTDATA           = 359440;
  VNC_OFF_CANHANDLENEWFBSIZE   = 359464;
  VNC_OFF_HANDLETEXTCHAT       = 359472;
  VNC_OFF_HANDLEKEYBOARDLEDSTATE = 359480;
  VNC_OFF_GOTFRAMEBUFFERUPDATE = 359512;
  VNC_OFF_GETPASSWORD          = 359520;
  VNC_OFF_MALLOCFRAMEBUFFER    = 359528;
  VNC_OFF_GOTXCUTTEXT          = 359536;
  VNC_OFF_GOTXCUTTEXTUTF8      = 359864;
  VNC_OFF_BELL                 = 359544;
  VNC_OFF_GETCREDENTIAL        = 359656;
  VNC_OFF_FINISHEDFBUPDATE     = 359704;
  VNC_SIZE_RFBCLIENT           = 359880;
{$ELSE}
{$IFDEF DARWIN}
  VNC_OFF_FRAMEBUFFER          = 0;
  VNC_OFF_WIDTH                = 8;
  VNC_OFF_HEIGHT               = 12;
  VNC_OFF_APPDATA              = 24;
  VNC_OFF_PROGRAMNAME          = 72;
  VNC_OFF_SERVERHOST           = 80;
  VNC_OFF_SERVERPORT           = 88;
  VNC_OFF_UPDATERECT           = 104;
  VNC_OFF_SOCK                 = 307320;
  VNC_OFF_LISTENSPECIFIED      = 92;
  VNC_OFF_CONNECTTIMEOUT       = 359912;
  VNC_OFF_READTIMEOUT          = 359916;
  VNC_OFF_DESKTOPNAME          = 307328;
  VNC_OFF_FORMAT               = 307336;
  VNC_OFF_SI                   = 307352;
  VNC_OFF_CLIENTDATA           = 359552;
  VNC_OFF_CANHANDLENEWFBSIZE   = 359576;
  VNC_OFF_HANDLETEXTCHAT       = 359584;
  VNC_OFF_HANDLEKEYBOARDLEDSTATE = 359592;
  VNC_OFF_GOTFRAMEBUFFERUPDATE = 359624;
  VNC_OFF_GETPASSWORD          = 359632;
  VNC_OFF_MALLOCFRAMEBUFFER    = 359640;
  VNC_OFF_GOTXCUTTEXT          = 359648;
  VNC_OFF_GOTXCUTTEXTUTF8      = 360008;
  VNC_OFF_BELL                 = 359656;
  VNC_OFF_GETCREDENTIAL        = 359768;
  VNC_OFF_FINISHEDFBUPDATE     = 359816;
  VNC_SIZE_RFBCLIENT           = 360024;
{$ELSE}
  VNC_OFF_FRAMEBUFFER          = 0;
  VNC_OFF_WIDTH                = 8;
  VNC_OFF_HEIGHT               = 12;
  VNC_OFF_APPDATA              = 24;
  VNC_OFF_PROGRAMNAME          = 72;
  VNC_OFF_SERVERHOST           = 80;
  VNC_OFF_SERVERPORT           = 88;
  VNC_OFF_UPDATERECT           = 104;
  VNC_OFF_SOCK                 = 307320;
  VNC_OFF_LISTENSPECIFIED      = 92;
  VNC_OFF_CONNECTTIMEOUT       = 359912;
  VNC_OFF_READTIMEOUT          = 359916;
  VNC_OFF_DESKTOPNAME          = 307328;
  VNC_OFF_FORMAT               = 307336;
  VNC_OFF_SI                   = 307352;
  VNC_OFF_CLIENTDATA           = 359552;
  VNC_OFF_CANHANDLENEWFBSIZE   = 359576;
  VNC_OFF_HANDLETEXTCHAT       = 359584;
  VNC_OFF_HANDLEKEYBOARDLEDSTATE = 359592;
  VNC_OFF_GOTFRAMEBUFFERUPDATE = 359624;
  VNC_OFF_GETPASSWORD          = 359632;
  VNC_OFF_MALLOCFRAMEBUFFER    = 359640;
  VNC_OFF_GOTXCUTTEXT          = 359648;
  VNC_OFF_GOTXCUTTEXTUTF8      = 359984;
  VNC_OFF_BELL                 = 359656;
  VNC_OFF_GETCREDENTIAL        = 359768;
  VNC_OFF_FINISHEDFBUPDATE     = 359816;
  VNC_SIZE_RFBCLIENT           = 360000;
{$ENDIF}
{$ENDIF}

  VNC_PF_OFF_BITSPERPIXEL = 0;
  VNC_PF_OFF_DEPTH        = 1;
  VNC_PF_OFF_BIGENDIAN    = 2;
  VNC_PF_OFF_TRUECOLOUR   = 3;
  VNC_PF_OFF_REDMAX       = 4;
  VNC_PF_OFF_GREENMAX     = 6;
  VNC_PF_OFF_BLUEMAX      = 8;
  VNC_PF_OFF_REDSHIFT     = 10;
  VNC_PF_OFF_GREENSHIFT   = 11;
  VNC_PF_OFF_BLUESHIFT    = 12;
  VNC_SIZE_PIXELFORMAT    = 16;

  VNC_AD_OFF_SHAREDESKTOP    = 0;
  VNC_AD_OFF_VIEWONLY        = 1;
  VNC_AD_OFF_ENCODINGSSTRING = 8;
  VNC_AD_OFF_COMPRESSLEVEL   = 32;
  VNC_AD_OFF_QUALITYLEVEL    = 36;
  VNC_AD_OFF_USEREMOTECURSOR = 41;

  VNC_EXPECT_BITSPERPIXEL  = 32;
  VNC_EXPECT_DEPTH         = 24;
  VNC_EXPECT_TRUECOLOUR    = 1;
  VNC_EXPECT_REDMAX        = 255;
  VNC_EXPECT_COMPRESSLEVEL = 3;
  VNC_EXPECT_QUALITYLEVEL  = 5;

  VNC_BITS_PER_SAMPLE   = 8;
  VNC_SAMPLES_PER_PIXEL = 3;
  VNC_BYTES_PER_PIXEL   = 4;

  VNC_BASE_PORT    = 5900;
  VNC_DEFAULT_PORT = 5900;

  VNC_WAIT_ERROR = -1;

type
  // Rappels appeles depuis le thread de session, jamais l'UI. cdecl obligatoire.
  TVncGotFrameBufferUpdate = procedure(AClient: PVncClient;
    x, y, w, h: cint); cdecl;
  TVncFinishedFbUpdate = procedure(AClient: PVncClient); cdecl;
  TVncMallocFrameBuffer = function(AClient: PVncClient): cint8; cdecl;
  TVncGetPassword = function(AClient: PVncClient): PAnsiChar; cdecl;
  TVncGotXCutText = procedure(AClient: PVncClient; const AText: PAnsiChar;
    ALen: cint); cdecl;
  TVncGotXCutTextUTF8 = procedure(AClient: PVncClient; const AText: PAnsiChar;
    ALen: cint); cdecl;
  TVncBell = procedure(AClient: PVncClient); cdecl;

var
  rfbGetClient: function(ABitsPerSample, ASamplesPerPixel,
    ABytesPerPixel: cint): PVncClient; cdecl;
  rfbInitClient: function(AClient: PVncClient; AArgc: pcint;
    AArgv: PPAnsiChar): cint8; cdecl;
  rfbClientCleanup: procedure(AClient: PVncClient); cdecl;
  WaitForMessage: function(AClient: PVncClient; AUsecs: cuint): cint; cdecl;
  HandleRFBServerMessage: function(AClient: PVncClient): cint8; cdecl;
  SendPointerEvent: function(AClient: PVncClient;
    x, y, AButtonMask: cint): cint8; cdecl;
  SendKeyEvent: function(AClient: PVncClient; AKey: cuint32;
    ADown: cint8): cint8; cdecl;
  // LATIN-1 ici; la variante UTF8 rend 0 si l'extension n'est pas negociee.
  SendClientCutText: function(AClient: PVncClient; AStr: PAnsiChar;
    ALen: cint): cint8; cdecl;
  SendClientCutTextUTF8: function(AClient: PVncClient; AStr: PAnsiChar;
    ALen: cint): cint8; cdecl;
  SendFramebufferUpdateRequest: function(AClient: PVncClient;
    x, y, w, h: cint; AIncremental: cint8): cint8; cdecl;
  SetFormatAndEncodings: function(AClient: PVncClient): cint8; cdecl;
  // clientData n'est pas libre: rfbClientCleanup free() ce qu'on y range.
  rfbClientSetClientData: procedure(AClient: PVncClient;
    ATag, AData: Pointer); cdecl;
  rfbClientGetClientData: function(AClient: PVncClient;
    ATag: Pointer): Pointer; cdecl;

procedure VncEnsureLoaded;
function VncIsLoaded: Boolean;
function VncLibraryPath: string;

// En cas d'echec le client est DEJA libere: le parametre repart a nil.
function VncInitClient(var AClient: PVncClient): Boolean;

function VncGetFrameBuffer(AClient: PVncClient): PByte;
procedure VncSetFrameBuffer(AClient: PVncClient; AValue: PByte);
function VncGetWidth(AClient: PVncClient): Integer;
function VncGetHeight(AClient: PVncClient): Integer;
function VncGetSock(AClient: PVncClient): Integer;
// rfbClientCleanup fermera ce descripteur: ne lui passer qu'un dup().
procedure VncSetSock(AClient: PVncClient; AFd: Integer);
procedure VncSetListenSpecified(AClient: PVncClient; AValue: Boolean);
function VncGetDesktopName(AClient: PVncClient): string;
procedure VncSetServerHost(AClient: PVncClient; const AHost: string);
procedure VncSetServerPort(AClient: PVncClient; APort: Integer);
procedure VncSetProgramName(AClient: PVncClient; const AName: string);
procedure VncSetClientData(AClient: PVncClient; AValue: Pointer);
function VncGetClientData(AClient: PVncClient): Pointer;
procedure VncSetCanHandleNewFBSize(AClient: PVncClient; AValue: Boolean);

function VncGetPixelBits(AClient: PVncClient): Integer;
function VncGetPixelDepth(AClient: PVncClient): Integer;
function VncGetPixelTrueColour(AClient: PVncClient): Integer;
function VncGetPixelRedMax(AClient: PVncClient): Integer;
procedure VncSetPixelFormatBgra(AClient: PVncClient);

function VncGetCompressLevel(AClient: PVncClient): Integer;
function VncGetQualityLevel(AClient: PVncClient): Integer;
procedure VncSetCompressLevel(AClient: PVncClient; AValue: Integer);
procedure VncSetQualityLevel(AClient: PVncClient; AValue: Integer);
procedure VncSetViewOnly(AClient: PVncClient; AValue: Boolean);
procedure VncSetShared(AClient: PVncClient; AValue: Boolean);
procedure VncSetConnectTimeout(AClient: PVncClient; ASeconds: Cardinal);
procedure VncSetReadTimeout(AClient: PVncClient; ASeconds: Cardinal);

procedure VncSetGotFrameBufferUpdate(AClient: PVncClient;
  ACb: TVncGotFrameBufferUpdate);
procedure VncSetFinishedFbUpdate(AClient: PVncClient; ACb: TVncFinishedFbUpdate);
procedure VncSetMallocFrameBuffer(AClient: PVncClient; ACb: TVncMallocFrameBuffer);
procedure VncSetGetPassword(AClient: PVncClient; ACb: TVncGetPassword);
procedure VncSetGotXCutText(AClient: PVncClient; ACb: TVncGotXCutText);
procedure VncSetGotXCutTextUTF8(AClient: PVncClient; ACb: TVncGotXCutTextUTF8);
procedure VncSetBell(AClient: PVncClient; ACb: TVncBell);

// La lib libere ces pointeurs avec free(): allocateur C, jamais GetMem.
function VncStrDupC(const AValue: string): PAnsiChar;
function VncStrDupCBuf(AData: PByte; ALen: PtrUInt): PAnsiChar;

implementation

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  Classes;

type
  TStringArray = array of string;

var
  GLib: TLibHandle = NilHandle;
  GReady: Boolean = False;
  GPath: string = '';
  GInitLock: TRTLCriticalSection;

{$IFDEF WINDOWS}
// MEME CRT que la DLL: c'est son free() qui libere ce qu'on alloue ici.
function c_malloc(ASize: PtrUInt): Pointer; cdecl;
  external 'ucrtbase.dll' name 'malloc';
{$ELSE}
function c_malloc(ASize: PtrUInt): Pointer; cdecl; external 'c' name 'malloc';
{$ENDIF}
{$IFDEF DARWIN}
function malloc_size(APtr: Pointer): PtrUInt; cdecl; external 'c' name 'malloc_size';
{$ENDIF}
{$IFDEF WINDOWS}
function _msize(APtr: Pointer): PtrUInt; cdecl; external 'ucrtbase.dll' name '_msize';
{$ENDIF}
{$IFDEF LINUX}
function malloc_usable_size(APtr: Pointer): PtrUInt; cdecl;
  external 'c' name 'malloc_usable_size';
{$ENDIF}

function VncStrDupCBuf(AData: PByte; ALen: PtrUInt): PAnsiChar;
begin
  Result := c_malloc(ALen + 1);
  if Result = nil then
    raise EVncError.Create('VNC: C allocation failed');
  if (ALen > 0) and (AData <> nil) then
    Move(AData^, Result^, ALen);
  Result[ALen] := #0;
end;

function VncStrDupC(const AValue: string): PAnsiChar;
var
  s: AnsiString;
begin
  s := AnsiString(AValue);
  if s = '' then
    Result := VncStrDupCBuf(nil, 0)
  else
    Result := VncStrDupCBuf(PByte(PAnsiChar(s)), Length(s));
end;

function AbsCandidateDir(const ADir: string): Boolean;
begin
  Result := (ADir <> '') and (ADir[1] = PathDelim);
  {$IFDEF WINDOWS}
  Result := (Length(ADir) >= 3) and (ADir[2] = ':');
  {$ENDIF}
end;

function CandidateDirs: TStringArray;
var
  exeDir: string;
begin
  exeDir := IncludeTrailingPathDelimiter(
    ExtractFilePath(ExpandFileName(ParamStr(0))));
  {$IFDEF DARWIN}
  // Aucun repli systeme: les paquets 0.9.15 trainent CVE-2026-50538/44988
  // (Tight, ecriture hors tas PRE-AUTH).
  Result := [
    exeDir + '../Frameworks/',
    exeDir,
    exeDir + 'third_party/libvnc/out/lib/',
    exeDir + '../../third_party/libvnc/out/lib/'
  ];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := [
    exeDir + 'lib/',
    exeDir,
    exeDir + 'third_party/libvnc/out/lib/',
    exeDir + '../../third_party/libvnc/out/lib/'
  ];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := [exeDir];
  {$ENDIF}
end;

function LibCandidateNames: TStringArray;
begin
  {$IFDEF DARWIN}
  Result := ['libvncclient.1.dylib', 'libvncclient.dylib'];
  {$ENDIF}
  {$IFDEF LINUX}
  Result := ['libvncclient.so.1', 'libvncclient.so'];
  {$ENDIF}
  {$IFDEF WINDOWS}
  Result := ['vncclient.dll', 'libvncclient.dll'];
  {$ENDIF}
end;

function MustSym(const AName: string): Pointer;
begin
  Result := GetProcAddress(GLib, AName);
  if Result = nil then
    raise EVncError.CreateFmt('libvncclient: missing symbol: %s', [AName]);
end;

procedure BindSymbols;
begin
  Pointer(rfbGetClient) := MustSym('rfbGetClient');
  Pointer(rfbInitClient) := MustSym('rfbInitClient');
  Pointer(rfbClientCleanup) := MustSym('rfbClientCleanup');
  Pointer(WaitForMessage) := MustSym('WaitForMessage');
  Pointer(HandleRFBServerMessage) := MustSym('HandleRFBServerMessage');
  Pointer(SendPointerEvent) := MustSym('SendPointerEvent');
  Pointer(SendKeyEvent) := MustSym('SendKeyEvent');
  Pointer(SendClientCutText) := MustSym('SendClientCutText');
  Pointer(SendClientCutTextUTF8) := MustSym('SendClientCutTextUTF8');
  Pointer(SendFramebufferUpdateRequest) :=
    MustSym('SendFramebufferUpdateRequest');
  Pointer(SetFormatAndEncodings) := MustSym('SetFormatAndEncodings');
  Pointer(rfbClientSetClientData) := MustSym('rfbClientSetClientData');
  Pointer(rfbClientGetClientData) := MustSym('rfbClientGetClientData');
end;

procedure SilenceLibraryLogging;
var
  p: Pointer;
begin
  // Variable exportee, pas une fonction: sinon la lib ecrit sur stderr.
  p := GetProcAddress(GLib, 'rfbEnableClientLogging');
  if p <> nil then
    pcint8(p)^ := 0;
end;

// Temoins VNC_EXPECT_* relus aux offsets codes en dur: une lib compilee autrement
// echoue ICI, pas en pleine session. clientData compris: zlib/JPEG decalent tout.
procedure CheckStructLayout;
var
  c: PVncClient;
  ok, lateOk: Boolean;
  tag, sentinel: Integer;
begin
  c := rfbGetClient(VNC_BITS_PER_SAMPLE, VNC_SAMPLES_PER_PIXEL,
    VNC_BYTES_PER_PIXEL);
  if c = nil then
    raise EVncError.Create('libvncclient: rfbGetClient failed');
  try
    {$IFDEF DARWIN}
    if malloc_size(c) < PtrUInt(VNC_SIZE_RFBCLIENT) then
      raise EVncError.CreateFmt('Incompatible libvncclient (%s): rfbClient ' +
        'object too small (%d bytes < %d expected). Different ABI, VNC is ' +
        'disabled with this library.',
        [GPath, PtrInt(malloc_size(c)), VNC_SIZE_RFBCLIENT]);
    {$ENDIF}
    {$IFDEF WINDOWS}
    if _msize(c) < PtrUInt(VNC_SIZE_RFBCLIENT) then
      raise EVncError.CreateFmt('Incompatible libvncclient (%s): rfbClient ' +
        'object too small (%d bytes < %d expected). Different ABI, VNC is ' +
        'disabled with this library.',
        [GPath, PtrInt(_msize(c)), VNC_SIZE_RFBCLIENT]);
    {$ENDIF}
    {$IFDEF LINUX}
    if malloc_usable_size(c) < PtrUInt(VNC_SIZE_RFBCLIENT) then
      raise EVncError.CreateFmt('Incompatible libvncclient (%s): rfbClient ' +
        'object too small (%d bytes < %d expected). Different ABI, VNC is ' +
        'disabled with this library.',
        [GPath, PtrInt(malloc_usable_size(c)), VNC_SIZE_RFBCLIENT]);
    {$ENDIF}

    ok :=
      (pcuint8(PByte(c) + VNC_OFF_FORMAT + VNC_PF_OFF_BITSPERPIXEL)^ =
        VNC_EXPECT_BITSPERPIXEL) and
      (pcuint8(PByte(c) + VNC_OFF_FORMAT + VNC_PF_OFF_DEPTH)^ =
        VNC_EXPECT_DEPTH) and
      (pcuint8(PByte(c) + VNC_OFF_FORMAT + VNC_PF_OFF_TRUECOLOUR)^ =
        VNC_EXPECT_TRUECOLOUR) and
      (pcuint16(PByte(c) + VNC_OFF_FORMAT + VNC_PF_OFF_REDMAX)^ =
        VNC_EXPECT_REDMAX) and
      (pcint(PByte(c) + VNC_OFF_APPDATA + VNC_AD_OFF_COMPRESSLEVEL)^ =
        VNC_EXPECT_COMPRESSLEVEL) and
      (pcint(PByte(c) + VNC_OFF_APPDATA + VNC_AD_OFF_QUALITYLEVEL)^ =
        VNC_EXPECT_QUALITYLEVEL);

    tag := 0;
    sentinel := $5A5A5A5A;
    rfbClientSetClientData(c, @tag, @sentinel);
    lateOk :=
      (PPointer(PByte(c) + VNC_OFF_CLIENTDATA)^ <> nil) and
      (rfbClientGetClientData(c, @tag) = @sentinel);
    ok := ok and lateOk;
  finally
    rfbClientCleanup(c);
  end;
  if not ok then
    raise EVncError.CreateFmt('Incompatible libvncclient (%s): the memory ' +
      'layout does not match the expected offsets (libvncclient 0.9.15). ' +
      'VNC is disabled with this library.',
      [GPath]);
end;

procedure VncEnsureLoaded;
var
  dir, nm: string;
begin
  if GReady then Exit;
  EnterCriticalSection(GInitLock);
  try
    if GReady then Exit;
    for dir in CandidateDirs do
    begin
      if not AbsCandidateDir(dir) then
        Continue;
      for nm in LibCandidateNames do
        if FileExists(dir + nm) then
        begin
          GLib := LoadLibrary(dir + nm);
          if GLib <> NilHandle then
          begin
            GPath := dir + nm;
            Break;
          end;
        end;
      if GLib <> NilHandle then
        Break;
    end;
    if GLib = NilHandle then
      raise EVncError.Create(
        'libvncclient not found in the expected locations');
    try
      BindSymbols;
      SilenceLibraryLogging;
      CheckStructLayout;
    except
      FreeLibrary(GLib);
      GLib := NilHandle;
      GPath := '';
      raise;
    end;
    GReady := True;
  finally
    LeaveCriticalSection(GInitLock);
  end;
end;

function VncIsLoaded: Boolean;
begin
  Result := GReady;
end;

function VncLibraryPath: string;
begin
  if GReady then
    Result := GPath
  else
    Result := '';
end;

function VncInitClient(var AClient: PVncClient): Boolean;
begin
  if AClient = nil then
    Exit(False);
  Result := rfbInitClient(AClient, nil, nil) <> 0;
  if not Result then
    AClient := nil;
end;

function VncGetFrameBuffer(AClient: PVncClient): PByte;
begin
  Result := PPointer(PByte(AClient) + VNC_OFF_FRAMEBUFFER)^;
end;

procedure VncSetFrameBuffer(AClient: PVncClient; AValue: PByte);
begin
  PPointer(PByte(AClient) + VNC_OFF_FRAMEBUFFER)^ := AValue;
end;

function VncGetWidth(AClient: PVncClient): Integer;
begin
  Result := pcint(PByte(AClient) + VNC_OFF_WIDTH)^;
end;

function VncGetHeight(AClient: PVncClient): Integer;
begin
  Result := pcint(PByte(AClient) + VNC_OFF_HEIGHT)^;
end;

{$IFDEF WINDOWS}
// rfbClient.sock est un SOCKET de 8 octets initialise a ~0: n'en ecrire que 4
// laisse 0xFFFFFFFF en poids fort et le handshake meurt. Toute la largeur.
function VncGetSock(AClient: PVncClient): Integer;
begin
  Result := Integer(PPtrUInt(PByte(AClient) + VNC_OFF_SOCK)^);
end;

procedure VncSetSock(AClient: PVncClient; AFd: Integer);
begin
  PPtrUInt(PByte(AClient) + VNC_OFF_SOCK)^ := PtrUInt(Cardinal(AFd));
end;
{$ELSE}
function VncGetSock(AClient: PVncClient): Integer;
begin
  Result := pcint(PByte(AClient) + VNC_OFF_SOCK)^;
end;

procedure VncSetSock(AClient: PVncClient; AFd: Integer);
begin
  pcint(PByte(AClient) + VNC_OFF_SOCK)^ := AFd;
end;
{$ENDIF}

procedure VncSetListenSpecified(AClient: PVncClient; AValue: Boolean);
begin
  if AValue then
    pcint(PByte(AClient) + VNC_OFF_LISTENSPECIFIED)^ := 1
  else
    pcint(PByte(AClient) + VNC_OFF_LISTENSPECIFIED)^ := 0;
end;

function VncGetDesktopName(AClient: PVncClient): string;
var
  p: PAnsiChar;
begin
  p := PPointer(PByte(AClient) + VNC_OFF_DESKTOPNAME)^;
  if p = nil then
    Result := ''
  else
    Result := string(AnsiString(p));
end;

procedure VncSetServerHost(AClient: PVncClient; const AHost: string);
begin
  PPointer(PByte(AClient) + VNC_OFF_SERVERHOST)^ := VncStrDupC(AHost);
end;

procedure VncSetServerPort(AClient: PVncClient; APort: Integer);
begin
  pcint(PByte(AClient) + VNC_OFF_SERVERPORT)^ := APort;
end;

procedure VncSetProgramName(AClient: PVncClient; const AName: string);
begin
  PPointer(PByte(AClient) + VNC_OFF_PROGRAMNAME)^ := VncStrDupC(AName);
end;

var
  GClientDataTag: Byte = 0;

procedure VncSetClientData(AClient: PVncClient; AValue: Pointer);
begin
  rfbClientSetClientData(AClient, @GClientDataTag, AValue);
end;

function VncGetClientData(AClient: PVncClient): Pointer;
begin
  Result := rfbClientGetClientData(AClient, @GClientDataTag);
end;

procedure VncSetCanHandleNewFBSize(AClient: PVncClient; AValue: Boolean);
begin
  if AValue then
    pcint8(PByte(AClient) + VNC_OFF_CANHANDLENEWFBSIZE)^ := 1
  else
    pcint8(PByte(AClient) + VNC_OFF_CANHANDLENEWFBSIZE)^ := 0;
end;

function PfByte(AClient: PVncClient; AOff: Integer): pcuint8;
begin
  Result := pcuint8(PByte(AClient) + VNC_OFF_FORMAT + AOff);
end;

function PfWord(AClient: PVncClient; AOff: Integer): pcuint16;
begin
  Result := pcuint16(PByte(AClient) + VNC_OFF_FORMAT + AOff);
end;

function VncGetPixelBits(AClient: PVncClient): Integer;
begin
  Result := PfByte(AClient, VNC_PF_OFF_BITSPERPIXEL)^;
end;

function VncGetPixelDepth(AClient: PVncClient): Integer;
begin
  Result := PfByte(AClient, VNC_PF_OFF_DEPTH)^;
end;

function VncGetPixelTrueColour(AClient: PVncClient): Integer;
begin
  Result := PfByte(AClient, VNC_PF_OFF_TRUECOLOUR)^;
end;

function VncGetPixelRedMax(AClient: PVncClient): Integer;
begin
  Result := PfWord(AClient, VNC_PF_OFF_REDMAX)^;
end;

procedure VncSetPixelFormatBgra(AClient: PVncClient);
begin
  // BGRA en memoire = A<<24|R<<16|G<<8|B en petit-boutiste: d'ou les shifts.
  PfByte(AClient, VNC_PF_OFF_BITSPERPIXEL)^ := 32;
  PfByte(AClient, VNC_PF_OFF_DEPTH)^ := 24;
  PfByte(AClient, VNC_PF_OFF_BIGENDIAN)^ := 0;
  PfByte(AClient, VNC_PF_OFF_TRUECOLOUR)^ := 1;
  PfWord(AClient, VNC_PF_OFF_REDMAX)^ := 255;
  PfWord(AClient, VNC_PF_OFF_GREENMAX)^ := 255;
  PfWord(AClient, VNC_PF_OFF_BLUEMAX)^ := 255;
  PfByte(AClient, VNC_PF_OFF_REDSHIFT)^ := 16;
  PfByte(AClient, VNC_PF_OFF_GREENSHIFT)^ := 8;
  PfByte(AClient, VNC_PF_OFF_BLUESHIFT)^ := 0;
end;

function AdInt(AClient: PVncClient; AOff: Integer): pcint;
begin
  Result := pcint(PByte(AClient) + VNC_OFF_APPDATA + AOff);
end;

function VncGetCompressLevel(AClient: PVncClient): Integer;
begin
  Result := AdInt(AClient, VNC_AD_OFF_COMPRESSLEVEL)^;
end;

function VncGetQualityLevel(AClient: PVncClient): Integer;
begin
  Result := AdInt(AClient, VNC_AD_OFF_QUALITYLEVEL)^;
end;

procedure VncSetCompressLevel(AClient: PVncClient; AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 9 then AValue := 9;
  AdInt(AClient, VNC_AD_OFF_COMPRESSLEVEL)^ := AValue;
end;

procedure VncSetQualityLevel(AClient: PVncClient; AValue: Integer);
begin
  if AValue < 0 then AValue := 0;
  if AValue > 9 then AValue := 9;
  AdInt(AClient, VNC_AD_OFF_QUALITYLEVEL)^ := AValue;
end;

procedure VncSetViewOnly(AClient: PVncClient; AValue: Boolean);
begin
  if AValue then
    pcint8(PByte(AClient) + VNC_OFF_APPDATA + VNC_AD_OFF_VIEWONLY)^ := 1
  else
    pcint8(PByte(AClient) + VNC_OFF_APPDATA + VNC_AD_OFF_VIEWONLY)^ := 0;
end;

procedure VncSetShared(AClient: PVncClient; AValue: Boolean);
begin
  // False = session exclusive: le serveur deconnecte les autres clients.
  if AValue then
    pcint8(PByte(AClient) + VNC_OFF_APPDATA + VNC_AD_OFF_SHAREDESKTOP)^ := 1
  else
    pcint8(PByte(AClient) + VNC_OFF_APPDATA + VNC_AD_OFF_SHAREDESKTOP)^ := 0;
end;

procedure VncSetConnectTimeout(AClient: PVncClient; ASeconds: Cardinal);
begin
  pcuint32(PByte(AClient) + VNC_OFF_CONNECTTIMEOUT)^ := ASeconds;
end;

procedure VncSetReadTimeout(AClient: PVncClient; ASeconds: Cardinal);
begin
  pcuint32(PByte(AClient) + VNC_OFF_READTIMEOUT)^ := ASeconds;
end;

procedure SetCb(AClient: PVncClient; AOff: Integer; ACb: Pointer);
begin
  PPointer(PByte(AClient) + AOff)^ := ACb;
end;

procedure VncSetGotFrameBufferUpdate(AClient: PVncClient;
  ACb: TVncGotFrameBufferUpdate);
begin
  SetCb(AClient, VNC_OFF_GOTFRAMEBUFFERUPDATE, ACb);
end;

procedure VncSetFinishedFbUpdate(AClient: PVncClient; ACb: TVncFinishedFbUpdate);
begin
  SetCb(AClient, VNC_OFF_FINISHEDFBUPDATE, ACb);
end;

procedure VncSetMallocFrameBuffer(AClient: PVncClient;
  ACb: TVncMallocFrameBuffer);
begin
  SetCb(AClient, VNC_OFF_MALLOCFRAMEBUFFER, ACb);
end;

procedure VncSetGetPassword(AClient: PVncClient; ACb: TVncGetPassword);
begin
  SetCb(AClient, VNC_OFF_GETPASSWORD, ACb);
end;

procedure VncSetGotXCutText(AClient: PVncClient; ACb: TVncGotXCutText);
begin
  SetCb(AClient, VNC_OFF_GOTXCUTTEXT, ACb);
end;

procedure VncSetGotXCutTextUTF8(AClient: PVncClient; ACb: TVncGotXCutTextUTF8);
begin
  SetCb(AClient, VNC_OFF_GOTXCUTTEXTUTF8, ACb);
end;

procedure VncSetBell(AClient: PVncClient; ACb: TVncBell);
begin
  SetCb(AClient, VNC_OFF_BELL, ACb);
end;

initialization
  InitCriticalSection(GInitLock);

finalization
  DoneCriticalSection(GInitLock);

end.
