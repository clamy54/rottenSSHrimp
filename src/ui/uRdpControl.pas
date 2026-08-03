unit uRdpControl;

{$mode objfpc}{$H+}

// Affichage RDP: surface peinte sur le thread UI, entrees publiees en
// evenements. Rien de FreeRDP ici -- la session pourra demenager en worker.

interface

uses
  Classes, SysUtils, Controls, Graphics, GraphType, LCLType, LCLIntf,
  LMessages, ExtCtrls, uRemoteSurface;

type
  TRdpMouseEvent = procedure(AFlags: Integer; AX, AY: Integer) of object;
  TRdpKeyEvent = procedure(AFlags: Integer; ACode: Integer) of object;
  TRdpSizeEvent = procedure(AWidth, AHeight: Integer) of object;

  TRottenRdpControl = class(TCustomControl)
  private
    FSurface: TRemoteSurface;
    FBitmap: TBitmap;
    FBitmapGen: Int64;
    FTimer: TTimer;
    FDirtyPending: Boolean;

    FOnMouse: TRdpMouseEvent;
    FOnExtMouse: TRdpMouseEvent;
    FOnKey: TRdpKeyEvent;
    FOnEscapeCapture: TNotifyEvent;
    {$IF defined(LCLGtk2) or defined(LCLCocoa)}
    FHwKeycode: Integer;   // vide = -1, PAS 0: 0 est un keycode Cocoa reel
    {$ENDIF}
    {$IFDEF LCLCocoa}
    // Cote retenu a l'ENFONCEMENT: au relachement le bit est deja retombe.
    FModRight: array[0..4] of Boolean;
    {$ENDIF}

    procedure RefreshTick(Sender: TObject);
    procedure SyncBitmap;
    procedure RecomputeLayout;
    function ToRemote(AX, AY: Integer; out ARX, ARY: Integer): Boolean;
    procedure SendButton(AButton: TMouseButton; ADown: Boolean;
      AX, AY: Integer);
    function ResolveScancode(AKey: Word; out ASc: Integer;
      out AExt: Boolean): Boolean;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyUp(var Key: Word; Shift: TShiftState); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure WMGetDlgCode(var Message: TLMNoParams); message LM_GETDLGCODE;
    {$IF defined(LCLGtk2) or defined(LCLCocoa)}
    // KeyDown ne voit que la virtuelle; ceux-ci arrivent avant, avec la position.
    procedure CaptureKeycode(AVk: Word; AKeyData: PtrInt; ADown: Boolean);
    procedure CNKeyDown(var Message: TLMKeyDown); message CN_KEYDOWN;
    procedure CNSysKeyDown(var Message: TLMKeyDown); message CN_SYSKEYDOWN;
    procedure CNKeyUp(var Message: TLMKeyUp); message CN_KEYUP;
    procedure CNSysKeyUp(var Message: TLMKeyUp); message CN_SYSKEYUP;
    {$ENDIF}
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AttachSurface(ASurface: TRemoteSurface);
    procedure NotifyPainted;
    function Snapshot: TBitmap;

    property OnMouseEvent: TRdpMouseEvent read FOnMouse write FOnMouse;
    property OnExtMouseEvent: TRdpMouseEvent read FOnExtMouse write FOnExtMouse;
    property OnKeyEvent: TRdpKeyEvent read FOnKey write FOnKey;
    property OnEscapeCapture: TNotifyEvent read FOnEscapeCapture
      write FOnEscapeCapture;
  end;

implementation

uses
  uFreeRdpApi, uRdpScancodes, uTheme
  {$IFDEF LCLCocoa}, uMacKbdLayout{$ENDIF};

const
  REFRESH_MS = 33;

constructor TRottenRdpControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  Color := clBlack;
  {$IF defined(LCLGtk2) or defined(LCLCocoa)}
  FHwKeycode := -1;
  {$ENDIF}
  FBitmap := TBitmap.Create;
  FBitmap.PixelFormat := pf32bit;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := REFRESH_MS;
  FTimer.OnTimer := @RefreshTick;
  FTimer.Enabled := True;
end;

destructor TRottenRdpControl.Destroy;
begin
  FTimer.Enabled := False;
  FBitmap.Free;
  inherited Destroy;
end;

procedure TRottenRdpControl.AttachSurface(ASurface: TRemoteSurface);
begin
  FSurface := ASurface;
  FBitmapGen := -1;
  RecomputeLayout;
  Invalidate;
end;

procedure TRottenRdpControl.NotifyPainted;
begin
  FDirtyPending := True;   // le timer peint: un flux rapide noierait l'UI
end;

function TRottenRdpControl.Snapshot: TBitmap;
begin
  Result := nil;
  if FSurface = nil then
    Exit;
  SyncBitmap;
  if (FBitmap.Width <= 0) or (FBitmap.Height <= 0) then
    Exit;
  Result := TBitmap.Create;
  Result.Assign(FBitmap);
end;

procedure TRottenRdpControl.RefreshTick(Sender: TObject);
begin
  if not FDirtyPending then
    Exit;
  FDirtyPending := False;
  SyncBitmap;
  Invalidate;
end;

procedure TRottenRdpControl.SyncBitmap;
var
  w, h: Integer;
  raw: TRawImage;
  r: TRemoteRect;
begin
  if FSurface = nil then
    Exit;
  FSurface.Lock;
  try
    w := FSurface.Width;
    h := FSurface.Height;
    if (w <= 0) or (h <= 0) or (FSurface.Data = nil) then
      Exit;
    FSurface.TakeDirty(r);

    // Pas GetLineStart (= ecran noir), et sans alpha: le 4e octet ment.
    raw.Init;
    raw.Description.Init_BPP32_B8G8R8_BIO_TTB(w, h);
    raw.DataSize := PtrUInt(w) * PtrUInt(h) * REMOTE_BYTES_PER_PIXEL;
    raw.Data := FSurface.Data;
    FBitmap.LoadFromRawImage(raw, False);
    FBitmapGen := FSurface.Generation;
  finally
    FSurface.Unlock;
  end;
  RecomputeLayout;
end;

procedure TRottenRdpControl.RecomputeLayout;
begin
  if (FBitmap.Width > 0) and (FBitmap.Height > 0) then
    if (Width <> FBitmap.Width) or (Height <> FBitmap.Height) then
      SetBounds(Left, Top, FBitmap.Width, FBitmap.Height);
end;

procedure TRottenRdpControl.Paint;
begin
  if (FSurface = nil) or (FBitmap.Width <= 0) or (FBitmap.Height <= 0) then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Exit;
  end;
  Canvas.Draw(0, 0, FBitmap);
  if Focused then
  begin
    Canvas.Brush.Style := bsClear;
    Canvas.Pen.Color := clBlack;
    Canvas.Pen.Width := 2;
    Canvas.Rectangle(1, 1, Width - 1, Height - 1);
    Canvas.Pen.Width := 1;
    Canvas.Brush.Style := bsSolid;
  end;
end;

procedure TRottenRdpControl.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRottenRdpControl.DoExit;
begin
  inherited DoExit;
  Invalidate;
end;

procedure TRottenRdpControl.Resize;
begin
  inherited Resize;
  Invalidate;
end;

function TRottenRdpControl.ToRemote(AX, AY: Integer;
  out ARX, ARY: Integer): Boolean;
begin
  ARX := AX;
  ARY := AY;
  Result := (FBitmap.Width > 0) and (AX >= 0) and (AY >= 0) and
    (AX < FBitmap.Width) and (AY < FBitmap.Height);
end;

procedure TRottenRdpControl.SendButton(AButton: TMouseButton; ADown: Boolean;
  AX, AY: Integer);
var
  rx, ry, flags: Integer;
  ext: Boolean;
begin
  if not ToRemote(AX, AY, rx, ry) then
    Exit;
  flags := 0;
  ext := False;
  case AButton of
    mbLeft: flags := PTR_FLAGS_BUTTON1;
    mbRight: flags := PTR_FLAGS_BUTTON2;
    mbMiddle: flags := PTR_FLAGS_BUTTON3;
    mbExtra1:
      begin
        flags := PTR_XFLAGS_BUTTON1;
        ext := True;
      end;
    mbExtra2:
      begin
        flags := PTR_XFLAGS_BUTTON2;
        ext := True;
      end;
  else
    Exit;
  end;
  if ext then
  begin
    if ADown then
      flags := flags or PTR_XFLAGS_DOWN;
    if Assigned(FOnExtMouse) then
      FOnExtMouse(flags, rx, ry);
  end
  else
  begin
    if ADown then
      flags := flags or PTR_FLAGS_DOWN;
    if Assigned(FOnMouse) then
      FOnMouse(flags, rx, ry);
  end;
end;

procedure TRottenRdpControl.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus and (not Focused) then
    SetFocus;
  SendButton(Button, True, X, Y);
end;

procedure TRottenRdpControl.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  SendButton(Button, False, X, Y);
end;

procedure TRottenRdpControl.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  rx, ry: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not ToRemote(X, Y, rx, ry) then
    Exit;
  if Assigned(FOnMouse) then
    FOnMouse(PTR_FLAGS_MOVE, rx, ry);
end;

function TRottenRdpControl.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  rx, ry, flags, steps: Integer;
  p: TPoint;
begin
  Result := True;
  p := ScreenToClient(MousePos);
  if not ToRemote(p.X, p.Y, rx, ry) then
    Exit;
  // RDP loge la rotation sur 8 bits dans les bits bas du flag
  steps := Abs(WheelDelta);
  if steps > 255 then
    steps := 255;
  flags := PTR_FLAGS_WHEEL or steps;
  if WheelDelta < 0 then
    flags := PTR_FLAGS_WHEEL or PTR_FLAGS_WHEEL_NEGATIVE or
             ((-WheelDelta) and $FF);
  if Assigned(FOnMouse) then
    FOnMouse(flags, rx, ry);
end;

{$IF defined(LCLGtk2) or defined(LCLCocoa)}
// Bits 16..23 de KeyData = keycode natif, GTK2 comme Cocoa; les KF_* sont plus haut.
function HwKeycodeOf(AKeyData: PtrInt): Integer; inline;
begin
  Result := (AKeyData shr 16) and $FF;
end;

{$IFDEF LCLCocoa}
// Un modificateur Cocoa passe par flagsChanged, sans keycode: on reconstruit.
const
  MOD_SHIFT = 0; MOD_CTRL = 1; MOD_ALT = 2; MOD_CMD = 3; MOD_CAPS = 4;
  KVK_LSHIFT = $38; KVK_RSHIFT = $3C;
  KVK_LCTRL  = $3B; KVK_RCTRL  = $3E;
  KVK_LALT   = $3A; KVK_RALT   = $3D;
  KVK_LCMD   = $37; KVK_RCMD   = $36;
  KVK_CAPS   = $39;

function ModIndexOf(AVk: Word): Integer; inline;
begin
  case AVk of
    VK_SHIFT:         Result := MOD_SHIFT;
    VK_CONTROL:       Result := MOD_CTRL;
    VK_MENU:          Result := MOD_ALT;
    VK_LWIN, VK_RWIN: Result := MOD_CMD;
    VK_CAPITAL:       Result := MOD_CAPS;
  else
    Result := -1;
  end;
end;

function RightSideDown(AVk: Word): Boolean;
var
  m: LongWord;
begin
  m := MacCurrentKeyModifiers;
  case AVk of
    VK_SHIFT:   Result := (m and MAC_MOD_RSHIFT) <> 0;
    VK_CONTROL: Result := (m and MAC_MOD_RCONTROL) <> 0;
    VK_MENU:    Result := (m and MAC_MOD_ROPTION) <> 0;
  else
    Result := False;
  end;
end;

function ModifierKeycode(AVk: Word; ARight: Boolean): Integer;
begin
  case AVk of
    VK_SHIFT:
      if ARight then Result := KVK_RSHIFT else Result := KVK_LSHIFT;
    VK_CONTROL:
      if ARight then Result := KVK_RCTRL else Result := KVK_LCTRL;
    VK_MENU:
      if ARight then Result := KVK_RALT else Result := KVK_LALT;
    VK_LWIN, VK_RWIN:
      if ARight then Result := KVK_RCMD else Result := KVK_LCMD;
    VK_CAPITAL:
      Result := KVK_CAPS;
  else
    Result := -1;
  end;
end;
{$ENDIF}

procedure TRottenRdpControl.CaptureKeycode(AVk: Word; AKeyData: PtrInt;
  ADown: Boolean);
{$IFDEF LCLCocoa}
var
  idx: Integer;
  right: Boolean;
{$ENDIF}
begin
  {$IFDEF LCLCocoa}
  idx := ModIndexOf(AVk);
  if idx >= 0 then
  begin
    if ADown then
    begin
      right := RightSideDown(AVk);
      FModRight[idx] := right;
    end
    else
      right := FModRight[idx];
    FHwKeycode := ModifierKeycode(AVk, right);
    Exit;
  end;
  {$ENDIF}
  FHwKeycode := HwKeycodeOf(AKeyData);
end;

procedure TRottenRdpControl.CNKeyDown(var Message: TLMKeyDown);
begin
  CaptureKeycode(Message.CharCode, Message.KeyData, True);
  inherited;
end;

procedure TRottenRdpControl.CNSysKeyDown(var Message: TLMKeyDown);
begin
  CaptureKeycode(Message.CharCode, Message.KeyData, True);
  inherited;
end;

procedure TRottenRdpControl.CNKeyUp(var Message: TLMKeyUp);
begin
  CaptureKeycode(Message.CharCode, Message.KeyData, False);
  inherited;
end;

procedure TRottenRdpControl.CNSysKeyUp(var Message: TLMKeyUp);
begin
  CaptureKeycode(Message.CharCode, Message.KeyData, False);
  inherited;
end;
{$ENDIF}

function TRottenRdpControl.ResolveScancode(AKey: Word; out ASc: Integer;
  out AExt: Boolean): Boolean;
begin
  {$IF defined(LCLGtk2) or defined(LCLCocoa)}
  // usage unique: un keycode perime enverrait la touche du coup d'avant
  if FHwKeycode >= 0 then
  begin
    {$IFDEF LCLGtk2}
    Result := X11KeycodeToScancode(Word(FHwKeycode), ASc, AExt);
    {$ELSE}
    Result := MacKeycodeToScancode(Word(FHwKeycode), ASc, AExt);
    {$ENDIF}
    FHwKeycode := -1;
    if Result then Exit;
  end;
  {$ENDIF}
  Result := VkToScancode(AKey, ASc, AExt);
end;

procedure TRottenRdpControl.KeyDown(var Key: Word; Shift: TShiftState);
var
  sc: Integer;
  ext: Boolean;
begin
  inherited KeyDown(Key, Shift);

  // Ctrl+Alt+Enter ne part pas, les appuis si: relacher ou le distant reste coince.
  if (Key = VK_RETURN) and (ssCtrl in Shift) and (ssAlt in Shift) then
  begin
    if Assigned(FOnKey) then
    begin
      FOnKey(KBD_FLAGS_RELEASE, $1D);
      FOnKey(KBD_FLAGS_RELEASE or KBD_FLAGS_EXTENDED, $1D);
      FOnKey(KBD_FLAGS_RELEASE, $38);
      FOnKey(KBD_FLAGS_RELEASE or KBD_FLAGS_EXTENDED, $38);
    end;
    Key := 0;
    if Assigned(FOnEscapeCapture) then
      FOnEscapeCapture(Self);
    Exit;
  end;

  if ResolveScancode(Key, sc, ext) then
  begin
    if Assigned(FOnKey) then
      FOnKey(KBD_FLAGS_DOWN or (Ord(ext) * KBD_FLAGS_EXTENDED), sc);
    Key := 0;
  end;
end;

procedure TRottenRdpControl.KeyUp(var Key: Word; Shift: TShiftState);
var
  sc: Integer;
  ext: Boolean;
begin
  inherited KeyUp(Key, Shift);
  if ResolveScancode(Key, sc, ext) then
  begin
    if Assigned(FOnKey) then
      FOnKey(KBD_FLAGS_RELEASE or (Ord(ext) * KBD_FLAGS_EXTENDED), sc);
    Key := 0;
  end;
end;

procedure TRottenRdpControl.WMGetDlgCode(var Message: TLMNoParams);
begin
  Message.Result := DLGC_WANTALLKEYS or DLGC_WANTTAB or DLGC_WANTARROWS or
    DLGC_WANTCHARS;
end;

end.
