unit uVncKeysyms;

{$mode objfpc}{$H+}

// Correspondance clavier LCL -> keysym X11 (message RFB KeyEvent). VNC
// transporte des keysyms, pas des scancodes: c'est le CLIENT qui decide du
// caractere. Hors ASCII, keysym = point de code + $01000000 (convention RFB).

interface

uses
  SysUtils, Classes;

const
  XK_BackSpace = $FF08;
  XK_Tab = $FF09;
  XK_Linefeed = $FF0A;
  XK_Clear = $FF0B;
  XK_Return = $FF0D;
  XK_Pause = $FF13;
  XK_Scroll_Lock = $FF14;
  XK_Sys_Req = $FF15;
  XK_Escape = $FF1B;
  XK_Delete = $FFFF;

  XK_Home = $FF50;
  XK_Left = $FF51;
  XK_Up = $FF52;
  XK_Right = $FF53;
  XK_Down = $FF54;
  XK_Page_Up = $FF55;
  XK_Page_Down = $FF56;
  XK_End = $FF57;
  XK_Select = $FF60;
  XK_Print = $FF61;
  XK_Execute = $FF62;
  XK_Insert = $FF63;
  XK_Menu = $FF67;
  XK_Cancel = $FF69;
  XK_Help = $FF6A;
  XK_Break = $FF6B;
  XK_Num_Lock = $FF7F;

  XK_KP_Enter = $FF8D;
  XK_KP_Multiply = $FFAA;
  XK_KP_Add = $FFAB;
  XK_KP_Separator = $FFAC;
  XK_KP_Subtract = $FFAD;
  XK_KP_Decimal = $FFAE;
  XK_KP_Divide = $FFAF;
  XK_KP_0 = $FFB0;
  XK_KP_9 = $FFB9;

  XK_F1 = $FFBE;
  XK_F12 = $FFC9;

  XK_Shift_L = $FFE1;
  XK_Shift_R = $FFE2;
  XK_Control_L = $FFE3;
  XK_Control_R = $FFE4;
  XK_Caps_Lock = $FFE5;
  XK_Meta_L = $FFE7;
  XK_Alt_L = $FFE9;
  XK_Alt_R = $FFEA;
  XK_Super_L = $FFEB;
  XK_Super_R = $FFEC;
  XK_ISO_Level3_Shift = $FE03;

  KEYSYM_UNICODE_BASE = $01000000;

// False = le caractere depend de la disposition: passer par Utf8ToKeysym.
function VkToKeysym(AVk: Word; out AKeysym: Cardinal): Boolean;

function VkToKeysymDef(AVk: Word): Cardinal;

function UnicodeToKeysym(ACodepoint: Cardinal): Cardinal;

function Utf8ToKeysym(const AUtf8: string; out AKeysym: Cardinal): Boolean;

function Utf8FirstCodepoint(const AUtf8: string; out ACodepoint: Cardinal;
  out ABytes: Integer): Boolean;

implementation

function VkToKeysym(AVk: Word; out AKeysym: Cardinal): Boolean;
begin
  AKeysym := 0;
  Result := True;
  case AVk of
    8: AKeysym := XK_BackSpace;
    9: AKeysym := XK_Tab;
    12: AKeysym := XK_Clear;
    13: AKeysym := XK_Return;
    19: AKeysym := XK_Pause;
    20: AKeysym := XK_Caps_Lock;
    27: AKeysym := XK_Escape;
    32: AKeysym := Ord(' ');

    16: AKeysym := XK_Shift_L;
    17: AKeysym := XK_Control_L;
    18: AKeysym := XK_Alt_L;
    160: AKeysym := XK_Shift_L;
    161: AKeysym := XK_Shift_R;
    162: AKeysym := XK_Control_L;
    163: AKeysym := XK_Control_R;
    164: AKeysym := XK_Alt_L;
    165: AKeysym := XK_ISO_Level3_Shift; // VK_RMENU, c'est AltGr
    91: AKeysym := XK_Super_L;
    92: AKeysym := XK_Super_R;
    93: AKeysym := XK_Menu;

    33: AKeysym := XK_Page_Up;
    34: AKeysym := XK_Page_Down;
    35: AKeysym := XK_End;
    36: AKeysym := XK_Home;
    37: AKeysym := XK_Left;
    38: AKeysym := XK_Up;
    39: AKeysym := XK_Right;
    40: AKeysym := XK_Down;
    41: AKeysym := XK_Select;
    43: AKeysym := XK_Execute;
    44: AKeysym := XK_Print;
    45: AKeysym := XK_Insert;
    46: AKeysym := XK_Delete;
    47: AKeysym := XK_Help;
    3: AKeysym := XK_Cancel;

    112..123: AKeysym := XK_F1 + (AVk - 112);

    96..105: AKeysym := XK_KP_0 + (AVk - 96);
    106: AKeysym := XK_KP_Multiply;
    107: AKeysym := XK_KP_Add;
    108: AKeysym := XK_KP_Separator;
    109: AKeysym := XK_KP_Subtract;
    110: AKeysym := XK_KP_Decimal;
    111: AKeysym := XK_KP_Divide;
    144: AKeysym := XK_Num_Lock;
    145: AKeysym := XK_Scroll_Lock;
  else
    Result := False;
  end;
end;

function VkToKeysymDef(AVk: Word): Cardinal;
begin
  if not VkToKeysym(AVk, Result) then
    Result := 0;
end;

function UnicodeToKeysym(ACodepoint: Cardinal): Cardinal;
begin
  if (ACodepoint >= $20) and (ACodepoint <= $7E) then
    Result := ACodepoint
  else
    Result := ACodepoint or KEYSYM_UNICODE_BASE;
end;

function Utf8FirstCodepoint(const AUtf8: string; out ACodepoint: Cardinal;
  out ABytes: Integer): Boolean;
var
  b0, b: Byte;
  need, i: Integer;
  cp: Cardinal;
begin
  ACodepoint := 0;
  ABytes := 0;
  Result := False;
  if AUtf8 = '' then
    Exit;

  b0 := Byte(AUtf8[1]);
  if b0 < $80 then
  begin
    cp := b0;
    need := 0;
  end
  else if (b0 and $E0) = $C0 then
  begin
    cp := b0 and $1F;
    need := 1;
  end
  else if (b0 and $F0) = $E0 then
  begin
    cp := b0 and $0F;
    need := 2;
  end
  else if (b0 and $F8) = $F0 then
  begin
    cp := b0 and $07;
    need := 3;
  end
  else
    Exit;

  if Length(AUtf8) < need + 1 then
    Exit;

  for i := 1 to need do
  begin
    b := Byte(AUtf8[1 + i]);
    if (b and $C0) <> $80 then
      Exit;
    cp := (cp shl 6) or (b and $3F);
  end;

  // surrogates et hors plage: refuses
  if (cp > $10FFFF) or ((cp >= $D800) and (cp <= $DFFF)) then
    Exit;

  ACodepoint := cp;
  ABytes := need + 1;
  Result := True;
end;

function Utf8ToKeysym(const AUtf8: string; out AKeysym: Cardinal): Boolean;
var
  cp: Cardinal;
  n: Integer;
begin
  AKeysym := 0;
  Result := Utf8FirstCodepoint(AUtf8, cp, n);
  if Result then
    AKeysym := UnicodeToKeysym(cp);
end;

end.
