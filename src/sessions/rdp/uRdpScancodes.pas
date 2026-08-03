unit uRdpScancodes;

{$mode objfpc}{$H+}

// Touche virtuelle LCL -> scancode PC/XT set 1. RDP transporte des
// positions physiques, pas des caracteres: la disposition s'applique cote serveur.
// Sans uses: les VK_* sont numeriques, l'unite reste testable en console.

interface

function VkToScancode(AVk: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;

// Position PHYSIQUE (keycode X11 = evdev + 8, et evdev == set 1 jusqu'a 88):
// sans MapVirtualKeyW, la table VK QWERTY US rendait 'q' pour le A azerty.
function X11KeycodeToScancode(AKeycode: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;

// Position PHYSIQUE aussi: les kVK_* sont positionnels par construction, mais
// sans formule -- table figee. Piege ISO: certains claviers croisent $0A et $32.
function MacKeycodeToScancode(AKeycode: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;

implementation

{$IFDEF WINDOWS}
function MapVirtualKeyW(AuCode, AuMapType: LongWord): LongWord;
  stdcall; external 'user32.dll';

const
  MAPVK_VK_TO_VSC = 0;
{$ENDIF}

const
  SC_ESCAPE = $01;
  SC_BACK = $0E;
  SC_TAB = $0F;
  SC_RETURN = $1C;
  SC_LCONTROL = $1D;
  SC_LSHIFT = $2A;
  SC_RSHIFT = $36;
  SC_LMENU = $38;
  SC_SPACE = $39;
  SC_CAPITAL = $3A;

function VkToScancode(AVk: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;
{$IFDEF WINDOWS}
var
  sc: LongWord;
{$ENDIF}
begin
  AScancode := 0;
  AExtended := False;
  Result := True;
  {$IFDEF WINDOWS}
  // touches "caractere": la disposition active tranche, la table US plus bas
  case AVk of
    Ord('0')..Ord('9'), Ord('A')..Ord('Z'), 186..192, 219..223, 226:
      begin
        sc := MapVirtualKeyW(AVk, MAPVK_VK_TO_VSC);
        if (sc > 0) and (sc <= $7F) then
        begin
          AScancode := Integer(sc);
          Exit;
        end;
      end;
  end;
  {$ENDIF}
  case AVk of
    Ord('1')..Ord('9'): AScancode := $02 + (AVk - Ord('1'));
    Ord('0'): AScancode := $0B;

    Ord('Q'): AScancode := $10;
    Ord('W'): AScancode := $11;
    Ord('E'): AScancode := $12;
    Ord('R'): AScancode := $13;
    Ord('T'): AScancode := $14;
    Ord('Y'): AScancode := $15;
    Ord('U'): AScancode := $16;
    Ord('I'): AScancode := $17;
    Ord('O'): AScancode := $18;
    Ord('P'): AScancode := $19;
    Ord('A'): AScancode := $1E;
    Ord('S'): AScancode := $1F;
    Ord('D'): AScancode := $20;
    Ord('F'): AScancode := $21;
    Ord('G'): AScancode := $22;
    Ord('H'): AScancode := $23;
    Ord('J'): AScancode := $24;
    Ord('K'): AScancode := $25;
    Ord('L'): AScancode := $26;
    Ord('Z'): AScancode := $2C;
    Ord('X'): AScancode := $2D;
    Ord('C'): AScancode := $2E;
    Ord('V'): AScancode := $2F;
    Ord('B'): AScancode := $30;
    Ord('N'): AScancode := $31;
    Ord('M'): AScancode := $32;

    27: AScancode := SC_ESCAPE;        // VK_ESCAPE
    8: AScancode := SC_BACK;           // VK_BACK
    9: AScancode := SC_TAB;            // VK_TAB
    13: AScancode := SC_RETURN;        // VK_RETURN
    32: AScancode := SC_SPACE;         // VK_SPACE
    20: AScancode := SC_CAPITAL;       // VK_CAPITAL
    16: AScancode := SC_LSHIFT;        // VK_SHIFT
    17: AScancode := SC_LCONTROL;      // VK_CONTROL
    18: AScancode := SC_LMENU;         // VK_MENU (Alt)
    160: AScancode := SC_LSHIFT;       // VK_LSHIFT
    161: AScancode := SC_RSHIFT;       // VK_RSHIFT
    162: AScancode := SC_LCONTROL;     // VK_LCONTROL
    163:                               // VK_RCONTROL
      begin
        AScancode := SC_LCONTROL;
        AExtended := True;
      end;
    164: AScancode := SC_LMENU;        // VK_LMENU
    165:                               // VK_RMENU (AltGr)
      begin
        AScancode := SC_LMENU;
        AExtended := True;
      end;

    112..121: AScancode := $3B + (AVk - 112);   // F1..F10
    122: AScancode := $57;                      // F11
    123: AScancode := $58;                      // F12

    45: begin AScancode := $52; AExtended := True; end;  // VK_INSERT
    46: begin AScancode := $53; AExtended := True; end;  // VK_DELETE
    36: begin AScancode := $47; AExtended := True; end;  // VK_HOME
    35: begin AScancode := $4F; AExtended := True; end;  // VK_END
    33: begin AScancode := $49; AExtended := True; end;  // VK_PRIOR
    34: begin AScancode := $51; AExtended := True; end;  // VK_NEXT
    37: begin AScancode := $4B; AExtended := True; end;  // VK_LEFT
    38: begin AScancode := $48; AExtended := True; end;  // VK_UP
    39: begin AScancode := $4D; AExtended := True; end;  // VK_RIGHT
    40: begin AScancode := $50; AExtended := True; end;  // VK_DOWN

    91: begin AScancode := $5B; AExtended := True; end;  // VK_LWIN
    92: begin AScancode := $5C; AExtended := True; end;  // VK_RWIN
    93: begin AScancode := $5D; AExtended := True; end;  // VK_APPS

    96: AScancode := $52;    // VK_NUMPAD0
    97: AScancode := $4F;
    98: AScancode := $50;
    99: AScancode := $51;
    100: AScancode := $4B;
    101: AScancode := $4C;
    102: AScancode := $4D;
    103: AScancode := $47;
    104: AScancode := $48;
    105: AScancode := $49;   // VK_NUMPAD9
    106: AScancode := $37;   // VK_MULTIPLY
    107: AScancode := $4E;   // VK_ADD
    109: AScancode := $4A;   // VK_SUBTRACT
    110: AScancode := $53;   // VK_DECIMAL
    111: begin AScancode := $35; AExtended := True; end;  // VK_DIVIDE
    144: AScancode := $45;   // VK_NUMLOCK
    145: AScancode := $46;   // VK_SCROLL

    186: AScancode := $27;   // VK_OEM_1  ;:
    187: AScancode := $0D;   // VK_OEM_PLUS
    188: AScancode := $33;   // VK_OEM_COMMA
    189: AScancode := $0C;   // VK_OEM_MINUS
    190: AScancode := $34;   // VK_OEM_PERIOD
    191: AScancode := $35;   // VK_OEM_2  /?
    192: AScancode := $29;   // VK_OEM_3  `~
    219: AScancode := $1A;   // VK_OEM_4  [{
    220: AScancode := $2B;   // VK_OEM_5  \|
    221: AScancode := $1B;   // VK_OEM_6  ]}
    222: AScancode := $28;   // VK_OEM_7  '"
    226: AScancode := $56;   // VK_OEM_102 (touche < > des claviers ISO)
  else
    Result := False;
  end;
end;

function X11KeycodeToScancode(AKeycode: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;
var
  ev: Integer;
begin
  AScancode := 0;
  AExtended := False;
  Result := True;
  if AKeycode < 8 then Exit(False);
  ev := AKeycode - 8;                   // keycode X11 -> code evdev

  // 84 n'est pas affecte, 85 (ZENKAKUHANKAKU) n'a pas d'equivalent PC
  if (ev >= 1) and (ev <= 88) and (ev <> 84) and (ev <> 85) then
  begin
    AScancode := ev;
    Exit;
  end;

  case ev of
    96:  begin AScancode := $1C; AExtended := True; end;  // KP Enter
    97:  begin AScancode := $1D; AExtended := True; end;  // RCtrl
    98:  begin AScancode := $35; AExtended := True; end;  // KP /
    99:  begin AScancode := $37; AExtended := True; end;  // PrintScreen
    100: begin AScancode := $38; AExtended := True; end;  // RAlt (AltGr)
    102: begin AScancode := $47; AExtended := True; end;  // Home
    103: begin AScancode := $48; AExtended := True; end;  // Up
    104: begin AScancode := $49; AExtended := True; end;  // PageUp
    105: begin AScancode := $4B; AExtended := True; end;  // Left
    106: begin AScancode := $4D; AExtended := True; end;  // Right
    107: begin AScancode := $4F; AExtended := True; end;  // End
    108: begin AScancode := $50; AExtended := True; end;  // Down
    109: begin AScancode := $51; AExtended := True; end;  // PageDown
    110: begin AScancode := $52; AExtended := True; end;  // Insert
    111: begin AScancode := $53; AExtended := True; end;  // Delete
    // 119 (Pause) absent: set 1 le veut en sequence E1, et son $45 nu est NUM LOCK
    125: begin AScancode := $5B; AExtended := True; end;  // LWin
    126: begin AScancode := $5C; AExtended := True; end;  // RWin
    127: begin AScancode := $5D; AExtended := True; end;  // Menu
  else
    Result := False;
  end;
end;

function MacKeycodeToScancode(AKeycode: Word; out AScancode: Integer;
  out AExtended: Boolean): Boolean;
begin
  AScancode := 0;
  AExtended := False;
  Result := True;
  case AKeycode of
    $00: AScancode := $1E;   // A
    $01: AScancode := $1F;   // S
    $02: AScancode := $20;   // D
    $03: AScancode := $21;   // F
    $04: AScancode := $23;   // H
    $05: AScancode := $22;   // G
    $06: AScancode := $2C;   // Z
    $07: AScancode := $2D;   // X
    $08: AScancode := $2E;   // C
    $09: AScancode := $2F;   // V
    $0A: AScancode := $56;   // ISO_Section (102e touche ISO, cf. note)
    $0B: AScancode := $30;   // B
    $0C: AScancode := $10;   // Q
    $0D: AScancode := $11;   // W
    $0E: AScancode := $12;   // E
    $0F: AScancode := $13;   // R
    $10: AScancode := $15;   // Y
    $11: AScancode := $14;   // T
    $12: AScancode := $02;   // 1
    $13: AScancode := $03;   // 2
    $14: AScancode := $04;   // 3
    $15: AScancode := $05;   // 4
    $16: AScancode := $07;   // 6
    $17: AScancode := $06;   // 5
    $18: AScancode := $0D;   // = +
    $19: AScancode := $0A;   // 9
    $1A: AScancode := $08;   // 7
    $1B: AScancode := $0C;   // - _
    $1C: AScancode := $09;   // 8
    $1D: AScancode := $0B;   // 0
    $1E: AScancode := $1B;   // ] }
    $1F: AScancode := $18;   // O
    $20: AScancode := $16;   // U
    $21: AScancode := $1A;   // [ {
    $22: AScancode := $17;   // I
    $23: AScancode := $19;   // P
    $24: AScancode := $1C;   // Return
    $25: AScancode := $26;   // L
    $26: AScancode := $24;   // J
    $27: AScancode := $28;   // ' "
    $28: AScancode := $25;   // K
    $29: AScancode := $27;   // ; :
    $2A: AScancode := $2B;   // backslash
    $2B: AScancode := $33;   // , <
    $2C: AScancode := $35;   // / ?
    $2D: AScancode := $31;   // N
    $2E: AScancode := $32;   // M
    $2F: AScancode := $34;   // . >
    $30: AScancode := $0F;   // Tab
    $31: AScancode := $39;   // Space
    $32: AScancode := $29;   // ` ~ (a gauche du 1, cf. note ISO)
    $33: AScancode := $0E;   // Delete (Backspace)
    $35: AScancode := $01;   // Escape

    $36: begin AScancode := $5C; AExtended := True; end;  // RCommand -> RWin
    $37: begin AScancode := $5B; AExtended := True; end;  // Command -> LWin
    $38: AScancode := $2A;                                // LShift
    $39: AScancode := $3A;                                // CapsLock
    $3A: AScancode := $38;                                // LOption -> LAlt
    $3B: AScancode := $1D;                                // LControl
    $3C: AScancode := $36;                                // RShift
    $3D: begin AScancode := $38; AExtended := True; end;  // ROption -> AltGr
    $3E: begin AScancode := $1D; AExtended := True; end;  // RControl

    $41: AScancode := $53;                                // KP .
    $43: AScancode := $37;                                // KP *
    $45: AScancode := $4E;                                // KP +
    $47: AScancode := $45;                                // KP Clear -> NumLock
    $4B: begin AScancode := $35; AExtended := True; end;  // KP /
    $4C: begin AScancode := $1C; AExtended := True; end;  // KP Enter
    $4E: AScancode := $4A;                                // KP -
    $51: AScancode := $59;                                // KP =
    $52: AScancode := $52;                                // KP 0
    $53: AScancode := $4F;                                // KP 1
    $54: AScancode := $50;                                // KP 2
    $55: AScancode := $51;                                // KP 3
    $56: AScancode := $4B;                                // KP 4
    $57: AScancode := $4C;                                // KP 5
    $58: AScancode := $4D;                                // KP 6
    $59: AScancode := $47;                                // KP 7
    $5B: AScancode := $48;                                // KP 8
    $5C: AScancode := $49;                                // KP 9

    $5D: AScancode := $7D;   // Yen
    $5E: AScancode := $73;   // Underscore (Ro)
    $5F: AScancode := $7E;   // KP virgule (claviers bresiliens/JIS)
    $66: AScancode := $7B;   // Eisu (position Muhenkan)
    $68: AScancode := $70;   // Kana

    $60: AScancode := $3F;   // F5
    $61: AScancode := $40;   // F6
    $62: AScancode := $41;   // F7
    $63: AScancode := $3D;   // F3
    $64: AScancode := $42;   // F8
    $65: AScancode := $43;   // F9
    $67: AScancode := $57;   // F11
    $6D: AScancode := $44;   // F10
    $6F: AScancode := $58;   // F12
    $76: AScancode := $3E;   // F4
    $78: AScancode := $3C;   // F2
    $7A: AScancode := $3B;   // F1
    $40: AScancode := $64;   // F17
    $4F: AScancode := $65;   // F18
    $50: AScancode := $66;   // F19
    $5A: AScancode := $67;   // F20
    $69: begin AScancode := $37; AExtended := True; end;  // F13 -> PrintScreen
    $6B: AScancode := $46;                                // F14 -> ScrollLock
    $6E: begin AScancode := $5D; AExtended := True; end;  // Menu -> Apps

    $72: begin AScancode := $52; AExtended := True; end;  // Help -> Insert
    $73: begin AScancode := $47; AExtended := True; end;  // Home
    $74: begin AScancode := $49; AExtended := True; end;  // PageUp
    $75: begin AScancode := $53; AExtended := True; end;  // Suppr avant -> Delete
    $77: begin AScancode := $4F; AExtended := True; end;  // End
    $79: begin AScancode := $51; AExtended := True; end;  // PageDown
    $7B: begin AScancode := $4B; AExtended := True; end;  // Left
    $7C: begin AScancode := $4D; AExtended := True; end;  // Right
    $7D: begin AScancode := $50; AExtended := True; end;  // Down
    $7E: begin AScancode := $48; AExtended := True; end;  // Up
  else
    Result := False;
  end;
end;

end.
