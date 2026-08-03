unit uTermTypes;

{$mode objfpc}{$H+}

// Types de base du terminal: cellules, couleurs, attributs et limites
// de ressources. Aucune dependance LCL ici.

interface

const
  // Limites de ressources du parseur et de l'ecran
  TERM_MAX_CSI_PARAMS    = 16;      // au-dela: parametres ignores
  TERM_MAX_CSI_PARAM_VAL = 65535;   // clamp des valeurs numeriques
  TERM_MAX_INTERMEDIATES = 2;
  TERM_MAX_OSC_LEN       = 4096;    // octets accumules; le reste est jete
  TERM_MAX_TITLE_LEN     = 256;     // points de code du titre d'onglet
  TERM_MAX_COLS          = 1000;
  TERM_MAX_ROWS          = 500;
  TERM_MIN_COLS          = 2;
  TERM_MIN_ROWS          = 2;
  TERM_SCROLLBACK_DEFAULT = 10000;  // lignes
  TERM_SCROLLBACK_HARD    = 100000; // plafond dur par session
  TERM_SCROLLBACK_BYTES   = 64 * 1024 * 1024; // budget approximatif

type
  TTermColorKind = (tckDefault, tckIndexed, tckRgb);

  TTermColor = record
    Kind: TTermColorKind;
    Value: Cardinal; // index 0..255 ou $RRGGBB
  end;

  TTermAttr = (taBold, taFaint, taItalic, taUnderline, taBlink,
    taInverse, taInvisible, taStrike);
  TTermAttrs = set of TTermAttr;

  TTermCell = record
    Code: UCS4Char;   // 0 = cellule vide, TERM_WIDE_CONT = continuation
    Attrs: TTermAttrs;
    Fg: TTermColor;
    Bg: TTermColor;
  end;
  PTermCell = ^TTermCell;

  TTermLine = array of TTermCell;

const
  TERM_WIDE_CONT: UCS4Char = 1; // seconde cellule d'un caractere large

function DefaultColor: TTermColor;
function IndexedColor(AIndex: Cardinal): TTermColor;
function RgbColor(R, G, B: Byte): TTermColor;
function SameColor(const A, B: TTermColor): Boolean;
function BlankCell(const AFg, ABg: TTermColor): TTermCell;

// Largeur d'affichage d'un point de code: 0 (combinant), 1 ou 2 (large)
function CodepointWidth(C: UCS4Char): Integer;

// Encodeur UTF-8 UNIQUE du terminal: parseur et affichage passent par ici.
function CodepointToUtf8(C: UCS4Char): string;

implementation

function DefaultColor: TTermColor;
begin
  Result.Kind := tckDefault;
  Result.Value := 0;
end;

function IndexedColor(AIndex: Cardinal): TTermColor;
begin
  Result.Kind := tckIndexed;
  Result.Value := AIndex and $FF;
end;

function RgbColor(R, G, B: Byte): TTermColor;
begin
  Result.Kind := tckRgb;
  Result.Value := (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or B;
end;

function SameColor(const A, B: TTermColor): Boolean;
begin
  Result := (A.Kind = B.Kind) and (A.Value = B.Value);
end;

function BlankCell(const AFg, ABg: TTermColor): TTermCell;
begin
  Result.Code := 0;
  Result.Attrs := [];
  Result.Fg := AFg;
  Result.Bg := ABg;
end;

type
  TCpRange = record
    Lo, Hi: UCS4Char;
  end;

const
  // Combinants et largeur zero (extrait suffisant: Mn/Me principaux + ZWJ/ZWNJ)
  ZeroRanges: array[0..27] of TCpRange = (
    (Lo: $0300; Hi: $036F), (Lo: $0483; Hi: $0489), (Lo: $0591; Hi: $05BD),
    (Lo: $05BF; Hi: $05BF), (Lo: $05C1; Hi: $05C2), (Lo: $05C4; Hi: $05C5),
    (Lo: $05C7; Hi: $05C7), (Lo: $0610; Hi: $061A), (Lo: $064B; Hi: $065F),
    (Lo: $0670; Hi: $0670), (Lo: $06D6; Hi: $06DC), (Lo: $06DF; Hi: $06E4),
    (Lo: $0711; Hi: $0711), (Lo: $0730; Hi: $074A), (Lo: $07A6; Hi: $07B0),
    (Lo: $0816; Hi: $0819), (Lo: $0900; Hi: $0902), (Lo: $093C; Hi: $093C),
    (Lo: $0941; Hi: $0948), (Lo: $094D; Hi: $094D), (Lo: $0E31; Hi: $0E31),
    (Lo: $0E34; Hi: $0E3A), (Lo: $0E47; Hi: $0E4E), (Lo: $200B; Hi: $200F),
    (Lo: $202A; Hi: $202E), (Lo: $2060; Hi: $2064), (Lo: $FE00; Hi: $FE0F),
    (Lo: $FE20; Hi: $FE2F)
  );

  // Larges: East Asian Wide/Fullwidth (plages principales)
  WideRanges: array[0..22] of TCpRange = (
    (Lo: $1100; Hi: $115F),   // Hangul Jamo
    (Lo: $2E80; Hi: $303E),   // CJK Radicals .. CJK Symbols
    (Lo: $3041; Hi: $33FF),   // Hiragana .. CJK Compatibility
    (Lo: $3400; Hi: $4DBF),   // CJK Ext A
    (Lo: $4E00; Hi: $9FFF),   // CJK Unified
    (Lo: $A000; Hi: $A4CF),   // Yi
    (Lo: $A960; Hi: $A97F),   // Hangul Jamo Ext A
    (Lo: $AC00; Hi: $D7A3),   // Hangul Syllables
    (Lo: $F900; Hi: $FAFF),   // CJK Compatibility Ideographs
    (Lo: $FE10; Hi: $FE19),   // Vertical forms
    (Lo: $FE30; Hi: $FE52),   // CJK Compatibility Forms
    (Lo: $FE54; Hi: $FE66),
    (Lo: $FE68; Hi: $FE6B),
    (Lo: $FF00; Hi: $FF60),   // Fullwidth Forms
    (Lo: $FFE0; Hi: $FFE6),
    (Lo: $1F300; Hi: $1F64F), // emoji (best effort)
    (Lo: $1F900; Hi: $1F9FF),
    (Lo: $20000; Hi: $2A6DF), // CJK Ext B
    (Lo: $2A700; Hi: $2B73F),
    (Lo: $2B740; Hi: $2B81F),
    (Lo: $2B820; Hi: $2CEAF),
    (Lo: $2F800; Hi: $2FA1F),
    (Lo: $30000; Hi: $3134F)
  );

function InRanges(C: UCS4Char; const Ranges: array of TCpRange): Boolean;
var
  lo, hi, mid: Integer;
begin
  lo := 0;
  hi := High(Ranges);
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if C < Ranges[mid].Lo then
      hi := mid - 1
    else if C > Ranges[mid].Hi then
      lo := mid + 1
    else
      Exit(True);
  end;
  Result := False;
end;

function CodepointWidth(C: UCS4Char): Integer;
begin
  if C < $20 then
    Exit(0); // controles: jamais imprimes tels quels
  if C < $0300 then
    Exit(1);
  if InRanges(C, ZeroRanges) then
    Exit(0);
  if InRanges(C, WideRanges) then
    Exit(2);
  Result := 1;
end;

function CodepointToUtf8(C: UCS4Char): string;
begin
  // L'encodeur refuse lui-meme surrogates isoles et points hors Unicode
  // (-> U+FFFD): le parseur filtre en amont, l'appelant n'a rien a garantir.
  if ((C >= $D800) and (C <= $DFFF)) or (C > $10FFFF) then
    C := $FFFD;
  if C < $80 then
    Result := Chr(C)
  else if C < $800 then
    Result := Chr($C0 or (C shr 6)) + Chr($80 or (C and $3F))
  else if C < $10000 then
    Result := Chr($E0 or (C shr 12)) + Chr($80 or ((C shr 6) and $3F)) +
      Chr($80 or (C and $3F))
  else
    Result := Chr($F0 or (C shr 18)) + Chr($80 or ((C shr 12) and $3F)) +
      Chr($80 or ((C shr 6) and $3F)) + Chr($80 or (C and $3F));
end;

end.
