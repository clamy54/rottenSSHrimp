unit uMacKbdLayout;

{$mode objfpc}{$H+}

// Disposition clavier active sous macOS -> KLID Windows, via Text Input
// Services. Pas par la locale: $LANG dit la langue, pas la geographie.

interface

// THREAD UI UNIQUEMENT: ailleurs, TISGetInputSourceProperty leve SIGTRAP.
function MacKeyboardKlid: LongWord;

const
  // Carbon: rien d'equivalent pour Command, cmdKey ne distingue pas les cotes.
  MAC_MOD_RSHIFT   = $2000;
  MAC_MOD_ROPTION  = $4000;
  MAC_MOD_RCONTROL = $8000;

// La LCL perd le cote du modificateur; RDP en a besoin: sans lui, l'Option
// droite ne part pas en AltGr et le clavier francais n'a plus de @ # | { }.
function MacCurrentKeyModifiers: LongWord;

implementation

{$IFDEF DARWIN}
// MacOSAll declare les TIS* mais ne lie pas HIToolbox: l'app est Cocoa.
{$linkframework Carbon}
uses
  SysUtils, MacOSAll;

function LayoutName: string;
var
  src: TISInputSourceRef;
  idRef: CFStringRef;
  buf: array[0..255] of AnsiChar;
  full: string;
  p: Integer;
begin
  Result := '';
  src := TISCopyCurrentKeyboardLayoutInputSource;
  if src = nil then Exit;
  try
    // Get, pas Copy: idRef appartient a la source, pas de CFRelease ici.
    idRef := CFStringRef(TISGetInputSourceProperty(src,
      kTISPropertyInputSourceID));
    if idRef = nil then Exit;
    if not CFStringGetCString(idRef, @buf[0], Length(buf),
      kCFStringEncodingUTF8) then Exit;
    full := string(PAnsiChar(@buf[0]));
  finally
    CFRelease(src);
  end;
  p := Length(full);
  while (p > 0) and (full[p] <> '.') do
    Dec(p);
  Result := Copy(full, p + 1, MaxInt);
end;

function MacKeyboardKlid: LongWord;
var
  n: string;
begin
  n := LayoutName;
  case n of
    'French', 'French-PC', 'French-numerical', 'ABC-AZERTY':
      Result := $040C;
    'Belgian':                                   Result := $080C;
    'SwissFrench':                               Result := $100C;
    'CanadianFrench-PC':                         Result := $0C0C;
    'Canadian', 'Canadian-CSA':                  Result := $1009;
    'German', 'Austrian', 'ABC-QWERTZ',
    'German-DIN-2137':                           Result := $0407;
    'SwissGerman':                               Result := $0807;
    'British', 'British-PC':                     Result := $0809;
    'US', 'ABC', 'USExtended', 'USInternational-PC':
      Result := $0409;
    'Dvorak', 'DVORAK-QWERTYCMD':                Result := $10409;
    'Spanish', 'Spanish-ISO':                    Result := $040A;
    'Italian', 'Italian-Pro':                    Result := $0410;
    'Portuguese':                                Result := $0816;
    'Brazilian', 'Brazilian-ABNT2', 'Brazilian-Pro':
      Result := $0416;
    'Dutch':                                     Result := $0413;
    'Swedish', 'Swedish-Pro':                    Result := $041D;
    'Norwegian':                                 Result := $0414;
    'Danish':                                    Result := $0406;
    'Finnish':                                   Result := $040B;
    'Polish', 'PolishPro':                       Result := $0415;
    'Czech', 'Czech-QWERTY':                     Result := $0405;
    'Slovak':                                    Result := $041B;
    'Hungarian':                                 Result := $040E;
    'Romanian', 'Romanian-Standard':             Result := $0418;
    'Croatian', 'Croatian-PC':                   Result := $041A;
    'Slovenian':                                 Result := $0424;
    'Russian', 'RussianWin', 'Russian-PC':       Result := $0419;
    'Ukrainian', 'Ukrainian-PC':                 Result := $0422;
    'Turkish', 'Turkish-QWERTY-PC',
    'Turkish-Standard':                          Result := $041F;
    'Greek':                                     Result := $0408;
    'Hebrew', 'Hebrew-PC':                       Result := $040D;
    'Arabic', 'Arabic-PC':                       Result := $0401;
    'Icelandic':                                 Result := $040F;
    'Estonian':                                  Result := $0425;
    'Latvian':                                   Result := $0426;
    'Lithuanian':                                Result := $0427;
  else
    Result := 0;
  end;
end;

function MacCurrentKeyModifiers: LongWord;
begin
  Result := LongWord(GetCurrentKeyModifiers);
end;

{$ELSE}

function MacKeyboardKlid: LongWord;
begin
  Result := 0;
end;

function MacCurrentKeyModifiers: LongWord;
begin
  Result := 0;
end;

{$ENDIF}

end.
