unit uVncControl;

{$mode objfpc}{$H+}

// Affichage VNC, meme discipline que le controle RDP: rien de libvncclient ici.
// RFB impose deux ecarts -- souris en MASQUE des boutons tenus (un bouton
// oublie reste enfonce la-bas), texte par UTF8KeyPress et non par les VK.

interface

uses
  Classes, SysUtils, Controls, Graphics, GraphType, LCLType, LCLIntf,
  LMessages, ExtCtrls, uRemoteSurface;

type
  TVncPointerEvent = procedure(AX, AY, AButtonMask: Integer) of object;
  TVncKeyEvent = procedure(AKeysym: Cardinal; ADown: Boolean) of object;

  TRottenVncControl = class(TCustomControl)
  private
    FSurface: TRemoteSurface;
    FBitmap: TBitmap;
    FTimer: TTimer;
    FDirtyPending: Boolean;
    FButtons: Integer;
    FLastX, FLastY: Integer;
    FViewOnly: Boolean;
    // Echelle <= 1: SendExtDesktopSize existe, les serveurs l'ignorent.
    FScale: Double;
    FFitToWindow: Boolean;

    FOnPointer: TVncPointerEvent;
    FOnKey: TVncKeyEvent;
    FOnEscapeCapture: TNotifyEvent;

    procedure SetFitToWindow(AValue: Boolean);
    procedure RefreshTick(Sender: TObject);
    procedure SyncBitmap;
    procedure RecomputeLayout;
    function ToRemote(AX, AY: Integer; out ARX, ARY: Integer): Boolean;
    procedure SendPointer(AX, AY: Integer);
    procedure SendKey(AKeysym: Cardinal; ADown: Boolean);
    procedure ReleaseAll;
    function ModifierComboKeysym(AKey: Word; AShift: TShiftState): Cardinal;
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
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure WMGetDlgCode(var Message: TLMNoParams); message LM_GETDLGCODE;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure AttachSurface(ASurface: TRemoteSurface);
    procedure NotifyPainted;
    procedure UpdateLayout;
    function Snapshot: TBitmap;

    property ViewOnly: Boolean read FViewOnly write FViewOnly;
    property FitToWindow: Boolean read FFitToWindow write SetFitToWindow;

    property OnPointerEvent: TVncPointerEvent read FOnPointer write FOnPointer;
    property OnKeyEvent: TVncKeyEvent read FOnKey write FOnKey;
    property OnEscapeCapture: TNotifyEvent read FOnEscapeCapture
      write FOnEscapeCapture;
  end;

implementation

uses
  uVncKeysyms;

const
  REFRESH_MS = 33;

  RFB_BUTTON_LEFT   = 1;
  RFB_BUTTON_MIDDLE = 2;
  RFB_BUTTON_RIGHT  = 4;
  RFB_BUTTON_WHEEL_UP   = 8;
  RFB_BUTTON_WHEEL_DOWN = 16;

constructor TRottenVncControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  Color := clBlack;
  FScale := 1.0;
  FFitToWindow := True;
  FBitmap := TBitmap.Create;
  FBitmap.PixelFormat := pf32bit;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := REFRESH_MS;
  FTimer.OnTimer := @RefreshTick;
  FTimer.Enabled := True;
end;

destructor TRottenVncControl.Destroy;
begin
  FTimer.Enabled := False;
  FBitmap.Free;
  inherited Destroy;
end;

procedure TRottenVncControl.AttachSurface(ASurface: TRemoteSurface);
begin
  FSurface := ASurface;
  RecomputeLayout;
  Invalidate;
end;

procedure TRottenVncControl.NotifyPainted;
begin
  FDirtyPending := True;
end;

function TRottenVncControl.Snapshot: TBitmap;
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

procedure TRottenVncControl.RefreshTick(Sender: TObject);
begin
  if not FDirtyPending then
    Exit;
  FDirtyPending := False;
  SyncBitmap;
  Invalidate;
end;

procedure TRottenVncControl.SyncBitmap;
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
    // Sans alpha: le 4e octet du serveur n'est pas une opacite.
    raw.Init;
    raw.Description.Init_BPP32_B8G8R8_BIO_TTB(w, h);
    raw.DataSize := PtrUInt(w) * PtrUInt(h) * REMOTE_BYTES_PER_PIXEL;
    raw.Data := FSurface.Data;
    FBitmap.LoadFromRawImage(raw, False);
  finally
    FSurface.Unlock;
  end;
  RecomputeLayout;
end;

procedure TRottenVncControl.SetFitToWindow(AValue: Boolean);
begin
  if FFitToWindow = AValue then Exit;
  FFitToWindow := AValue;
  UpdateLayout;
end;

procedure TRottenVncControl.UpdateLayout;
begin
  RecomputeLayout;
  Invalidate;
end;

procedure TRottenVncControl.RecomputeLayout;
var
  vw, vh, nw, nh, nl, nt: Integer;
  scw, sch, sc: Double;
begin
  if (FBitmap.Width <= 0) or (FBitmap.Height <= 0) then
    Exit;
  if Parent = nil then
    Exit;
  vw := Parent.ClientWidth;
  vh := Parent.ClientHeight;
  if (vw <= 0) or (vh <= 0) then
    Exit;
  if not FFitToWindow then
  begin
    FScale := 1.0;
    if (Left <> 0) or (Top <> 0) or (Width <> FBitmap.Width) or
       (Height <> FBitmap.Height) then
      SetBounds(0, 0, FBitmap.Width, FBitmap.Height);
    Exit;
  end;
  scw := vw / FBitmap.Width;
  sch := vh / FBitmap.Height;
  if scw < sch then sc := scw else sc := sch;
  if sc > 1.0 then sc := 1.0;
  nw := Round(FBitmap.Width * sc);
  nh := Round(FBitmap.Height * sc);
  if nw < 1 then nw := 1;
  if nh < 1 then nh := 1;
  // echelle EFFECTIVE, apres arrondi: sinon le pointeur derive en bord d'ecran
  FScale := nw / FBitmap.Width;
  nl := (vw - nw) div 2;
  nt := (vh - nh) div 2;
  if nl < 0 then nl := 0;
  if nt < 0 then nt := 0;
  if (Left <> nl) or (Top <> nt) or (Width <> nw) or (Height <> nh) then
    SetBounds(nl, nt, nw, nh);
end;

procedure TRottenVncControl.Paint;
begin
  if (FSurface = nil) or (FBitmap.Width <= 0) or (FBitmap.Height <= 0) then
  begin
    Canvas.Brush.Color := clBlack;
    Canvas.FillRect(ClientRect);
    Exit;
  end;
  if FScale >= 1.0 then
    Canvas.Draw(0, 0, FBitmap)
  else
  begin
    Canvas.AntialiasingMode := amOn;
    Canvas.StretchDraw(Rect(0, 0, Width, Height), FBitmap);
  end;
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

procedure TRottenVncControl.DoEnter;
begin
  inherited DoEnter;
  Invalidate;
end;

procedure TRottenVncControl.DoExit;
begin
  inherited DoExit;
  ReleaseAll;   // sinon boutons et modificateurs restent enfonces la-bas
  Invalidate;
end;

procedure TRottenVncControl.Resize;
begin
  inherited Resize;
  Invalidate;
end;

function TRottenVncControl.ToRemote(AX, AY: Integer;
  out ARX, ARY: Integer): Boolean;
begin
  Result := (FBitmap.Width > 0) and (AX >= 0) and (AY >= 0) and
    (AX < Width) and (AY < Height);
  if FScale > 0 then
  begin
    ARX := Trunc(AX / FScale);
    ARY := Trunc(AY / FScale);
  end
  else
  begin
    ARX := AX;
    ARY := AY;
  end;
  if ARX >= FBitmap.Width then ARX := FBitmap.Width - 1;
  if ARY >= FBitmap.Height then ARY := FBitmap.Height - 1;
end;

procedure TRottenVncControl.SendPointer(AX, AY: Integer);
begin
  if FViewOnly then Exit;
  FLastX := AX;
  FLastY := AY;
  if Assigned(FOnPointer) then
    FOnPointer(AX, AY, FButtons);
end;

procedure TRottenVncControl.SendKey(AKeysym: Cardinal; ADown: Boolean);
begin
  if FViewOnly then Exit;
  if AKeysym = 0 then Exit;
  if Assigned(FOnKey) then
    FOnKey(AKeysym, ADown);
end;

procedure TRottenVncControl.ReleaseAll;
begin
  if FButtons <> 0 then
  begin
    FButtons := 0;
    SendPointer(FLastX, FLastY);
  end;
  SendKey(XK_Shift_L, False);
  SendKey(XK_Shift_R, False);
  SendKey(XK_Control_L, False);
  SendKey(XK_Control_R, False);
  SendKey(XK_Alt_L, False);
  SendKey(XK_Alt_R, False);
  SendKey(XK_Super_L, False);
  SendKey(XK_ISO_Level3_Shift, False);
end;

procedure TRottenVncControl.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  rx, ry: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus and (not Focused) then
    SetFocus;
  if not ToRemote(X, Y, rx, ry) then Exit;
  case Button of
    mbLeft:   FButtons := FButtons or RFB_BUTTON_LEFT;
    mbMiddle: FButtons := FButtons or RFB_BUTTON_MIDDLE;
    mbRight:  FButtons := FButtons or RFB_BUTTON_RIGHT;
  else
    Exit;
  end;
  SendPointer(rx, ry);
end;

procedure TRottenVncControl.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  rx, ry: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if not ToRemote(X, Y, rx, ry) then
  begin
    rx := FLastX;
    ry := FLastY;
  end;
  case Button of
    mbLeft:   FButtons := FButtons and (not RFB_BUTTON_LEFT);
    mbMiddle: FButtons := FButtons and (not RFB_BUTTON_MIDDLE);
    mbRight:  FButtons := FButtons and (not RFB_BUTTON_RIGHT);
  else
    Exit;
  end;
  SendPointer(rx, ry);
end;

procedure TRottenVncControl.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  rx, ry: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not ToRemote(X, Y, rx, ry) then
    Exit;
  SendPointer(rx, ry);
end;

function TRottenVncControl.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  rx, ry, bit: Integer;
  p: TPoint;
begin
  Result := True;
  if FViewOnly then Exit;
  p := ScreenToClient(MousePos);
  if not ToRemote(p.X, p.Y, rx, ry) then
    Exit;
  // en RFB la molette est un bouton sans amplitude: un cran = un aller-retour
  if WheelDelta > 0 then
    bit := RFB_BUTTON_WHEEL_UP
  else
    bit := RFB_BUTTON_WHEEL_DOWN;
  FButtons := FButtons or bit;
  SendPointer(rx, ry);
  FButtons := FButtons and (not bit);
  SendPointer(rx, ry);
end;

function TRottenVncControl.ModifierComboKeysym(AKey: Word;
  AShift: TShiftState): Cardinal;
begin
  // UTF8KeyPress ne tire pas sous Ctrl/Alt: sans ce mappage, pas de Ctrl+C.
  Result := 0;
  if not ((ssCtrl in AShift) or (ssAlt in AShift) or (ssMeta in AShift)) then
    Exit;
  case AKey of
    VK_A..VK_Z: Result := Cardinal(Ord('a') + (AKey - VK_A));
    VK_0..VK_9: Result := Cardinal(Ord('0') + (AKey - VK_0));
  end;
end;

procedure TRottenVncControl.KeyDown(var Key: Word; Shift: TShiftState);
var
  ks: Cardinal;
begin
  inherited KeyDown(Key, Shift);

  if (Key = VK_RETURN) and (ssCtrl in Shift) and (ssAlt in Shift) then
  begin
    ReleaseAll;
    Key := 0;
    if Assigned(FOnEscapeCapture) then
      FOnEscapeCapture(Self);
    Exit;
  end;

  if VkToKeysym(Key, ks) then
  begin
    SendKey(ks, True);
    Key := 0;
    Exit;
  end;
  ks := ModifierComboKeysym(Key, Shift);
  if ks <> 0 then
  begin
    SendKey(ks, True);
    Key := 0;
  end;
end;

procedure TRottenVncControl.KeyUp(var Key: Word; Shift: TShiftState);
var
  ks: Cardinal;
begin
  inherited KeyUp(Key, Shift);
  if VkToKeysym(Key, ks) then
  begin
    SendKey(ks, False);
    Key := 0;
    Exit;
  end;
  ks := ModifierComboKeysym(Key, Shift);
  if ks <> 0 then
  begin
    SendKey(ks, False);
    Key := 0;
  end;
end;

procedure TRottenVncControl.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  ks: Cardinal;
begin
  inherited UTF8KeyPress(UTF8Key);
  if UTF8Key = '' then Exit;
  if not Utf8ToKeysym(string(UTF8Key), ks) then Exit;
  // appui + relachement d'un coup: le vrai relachement arrive en VK, illisible.
  SendKey(ks, True);
  SendKey(ks, False);
  UTF8Key := '';
end;

procedure TRottenVncControl.WMGetDlgCode(var Message: TLMNoParams);
begin
  Message.Result := DLGC_WANTALLKEYS or DLGC_WANTTAB or DLGC_WANTARROWS or
    DLGC_WANTCHARS;
end;

end.
