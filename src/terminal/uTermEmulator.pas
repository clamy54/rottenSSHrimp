unit uTermEmulator;

{$mode objfpc}{$H+}

// Emulateur de terminal: interprete les actions du parseur sur l'ecran. Cible
// xterm-256color, sous-ensemble VT100/VT220. Sequences dangereuses neutralisees:
// OSC 52 ignore, titre borne, ni acces fichier ni execution.

interface

uses
  SysUtils, uTermTypes, uTermScreen, uTermParser;

type
  TTermResponseEvent = procedure(const AData: RawByteString) of object;
  TTermTitleEvent = procedure(const ATitle: string) of object;
  TTermNotifyEvent = procedure of object;

  TMouseTrackMode = (mtNone, mtX10, mtNormal, mtButton, mtAny);
  TCursorStyle = (csBlockBlink, csBlock, csUnderBlink, csUnder, csBarBlink, csBar);

  TSavedCursor = record
    X, Y: Integer;
    Attrs: TTermAttrs;
    Fg, Bg: TTermColor;
    Origin: Boolean;
    Charset0, Charset1: Char;
    GlIsG1: Boolean;
    Valid: Boolean;
  end;

  TTermEmulator = class(TTermHandler)
  private
    FScreen: TTermScreen;
    FParser: TTermParser;
    FX, FY: Integer;
    FWrapPending: Boolean;
    FAttrs: TTermAttrs;
    FFg, FBg: TTermColor;
    FScrollTop, FScrollBottom: Integer;
    FTabs: array of Boolean;
    FLastPrinted: UCS4Char;
    // modes
    FOrigin: Boolean;
    FAutoWrap: Boolean;
    FInsertMode: Boolean;
    FLnm: Boolean;
    FAppCursorKeys: Boolean;
    FAppKeypad: Boolean;
    FCursorVisible: Boolean;
    FReverseVideo: Boolean;
    FBracketedPaste: Boolean;
    FFocusEvents: Boolean;
    FMouseMode: TMouseTrackMode;
    FMouseSgr: Boolean;
    FCursorStyle: TCursorStyle;
    // charsets
    FCharset0, FCharset1: Char; // 'B' ascii, '0' DEC graphics
    FGlIsG1: Boolean;
    FSavedMain, FSavedAlt: TSavedCursor;
    FSaved1049: TSavedCursor;
    FTitle: string;
    FDamaged: Boolean;
    FOnResponse: TTermResponseEvent;
    FOnTitle: TTermTitleEvent;
    FOnBell: TTermNotifyEvent;
    // couleurs par defaut annoncees aux requetes OSC 10/11
    FDefaultFgRgb: Cardinal;
    FDefaultBgRgb: Cardinal;
    procedure Damage;
    function BlankPen: TTermCell;
    procedure ResetTabs;
    procedure CarriageReturn;
    procedure LineFeed;
    procedure ReverseIndex;
    procedure NextTab;
    procedure PrevTab;
    procedure MoveTo(AX, AY: Integer);
    procedure MoveRel(ADx, ADy: Integer);
    procedure ScrollRegionUp(N: Integer);
    procedure ScrollRegionDown(N: Integer);
    procedure DoSgr(const P: array of Integer; Count: Integer);
    procedure DoDecMode(AMode: Integer; ASet: Boolean);
    procedure DoAnsiMode(AMode: Integer; ASet: Boolean);
    procedure SaveCursorState(var S: TSavedCursor);
    procedure RestoreCursorState(const S: TSavedCursor);
    procedure EnterAlt(ASaveCursor, AClear: Boolean);
    procedure LeaveAlt(ARestoreCursor: Boolean);
    procedure Respond(const S: RawByteString);
    function TranslateGlyph(C: UCS4Char): UCS4Char;
    procedure FullReset;
  public
    constructor Create(ACols, ARows, AScrollbackMax: Integer);
    destructor Destroy; override;

    procedure Feed(const AData: PByte; ALen: SizeInt);
    procedure FeedStr(const AData: RawByteString);
    procedure Resize(ACols, ARows: Integer);
    procedure Reset;

    // TTermHandler
    procedure Print(C: UCS4Char); override;
    procedure Execute(B: Byte); override;
    procedure EscDispatch(const AInters: string; AFinal: Char); override;
    procedure CsiDispatch(const AParams: array of Integer; AParamCount: Integer;
      APrivate: Char; const AInters: string; AFinal: Char); override;
    procedure OscDispatch(const APayload: RawByteString); override;

    function ConsumeDamage: Boolean;

    property Screen: TTermScreen read FScreen;
    property CursorX: Integer read FX;
    property CursorY: Integer read FY;
    property CursorVisible: Boolean read FCursorVisible;
    property CursorStyle: TCursorStyle read FCursorStyle;
    property ReverseVideo: Boolean read FReverseVideo;
    property BracketedPaste: Boolean read FBracketedPaste;
    property AppCursorKeys: Boolean read FAppCursorKeys;
    property AppKeypad: Boolean read FAppKeypad;
    property FocusEvents: Boolean read FFocusEvents;
    property MouseMode: TMouseTrackMode read FMouseMode;
    property MouseSgr: Boolean read FMouseSgr;
    property Title: string read FTitle;
    property OnResponse: TTermResponseEvent read FOnResponse write FOnResponse;
    property OnTitle: TTermTitleEvent read FOnTitle write FOnTitle;
    property OnBell: TTermNotifyEvent read FOnBell write FOnBell;
    property DefaultFgRgb: Cardinal read FDefaultFgRgb write FDefaultFgRgb;
    property DefaultBgRgb: Cardinal read FDefaultBgRgb write FDefaultBgRgb;
  end;

implementation

// table DEC Special Graphics (ESC ( 0), plage 0x60..0x7E
const
  DecGraphics: array[$60..$7E] of UCS4Char = (
    $25C6, $2592, $2409, $240C, $240D, $240A, $00B0, $00B1, // ` a b c d e f g
    $2424, $240B, $2518, $2510, $250C, $2514, $253C, $23BA, // h i j k l m n o
    $23BB, $2500, $23BC, $23BD, $251C, $2524, $2534, $252C, // p q r s t u v w
    $2502, $2264, $2265, $03C0, $2260, $00A3, $00B7);       // x y z { | } ~

constructor TTermEmulator.Create(ACols, ARows, AScrollbackMax: Integer);
begin
  inherited Create;
  FScreen := TTermScreen.Create(ACols, ARows, AScrollbackMax);
  FParser := TTermParser.Create(Self);
  FDefaultFgRgb := $D0D0D0;
  FDefaultBgRgb := $101010;
  FullReset;
end;

destructor TTermEmulator.Destroy;
begin
  FParser.Free;
  FScreen.Free;
  inherited Destroy;
end;

procedure TTermEmulator.FullReset;
begin
  FX := 0;
  FY := 0;
  FWrapPending := False;
  FAttrs := [];
  FFg := DefaultColor;
  FBg := DefaultColor;
  FScrollTop := 0;
  FScrollBottom := FScreen.Rows - 1;
  FOrigin := False;
  FAutoWrap := True;
  FInsertMode := False;
  FLnm := False;
  FAppCursorKeys := False;
  FAppKeypad := False;
  FCursorVisible := True;
  FReverseVideo := False;
  FBracketedPaste := False;
  FFocusEvents := False;
  FMouseMode := mtNone;
  FMouseSgr := False;
  FCursorStyle := csBlockBlink;
  FCharset0 := 'B';
  FCharset1 := 'B';
  FGlIsG1 := False;
  FSavedMain.Valid := False;
  FSavedAlt.Valid := False;
  FSaved1049.Valid := False;
  FLastPrinted := 0;
  if FScreen.OnAlt then
    FScreen.UseAlt(False, BlankPen);
  FScreen.FillScreen(BlankCell(DefaultColor, DefaultColor));
  ResetTabs;
  Damage;
end;

procedure TTermEmulator.Reset;
begin
  FParser.Reset;
  FullReset;
end;

procedure TTermEmulator.Damage;
begin
  FDamaged := True;
end;

function TTermEmulator.ConsumeDamage: Boolean;
begin
  Result := FDamaged;
  FDamaged := False;
end;

function TTermEmulator.BlankPen: TTermCell;
begin
  // BCE: on efface avec la couleur de fond courante, sans attributs
  Result := BlankCell(DefaultColor, FBg);
end;

procedure TTermEmulator.ResetTabs;
var
  i: Integer;
begin
  SetLength(FTabs, FScreen.Cols);
  for i := 0 to High(FTabs) do
    FTabs[i] := (i mod 8) = 0;
end;

procedure TTermEmulator.Respond(const S: RawByteString);
begin
  if Assigned(FOnResponse) then
    FOnResponse(S);
end;

procedure TTermEmulator.Feed(const AData: PByte; ALen: SizeInt);
begin
  FParser.Feed(AData, ALen);
end;

procedure TTermEmulator.FeedStr(const AData: RawByteString);
begin
  FParser.FeedStr(AData);
end;

procedure TTermEmulator.Resize(ACols, ARows: Integer);
var
  cy: Integer;
begin
  cy := FY;
  FScreen.Resize(ACols, ARows, cy);
  FY := cy;
  if FX >= FScreen.Cols then
    FX := FScreen.Cols - 1;
  FScrollTop := 0;
  FScrollBottom := FScreen.Rows - 1;
  FWrapPending := False;
  ResetTabs;
  Damage;
end;

function TTermEmulator.TranslateGlyph(C: UCS4Char): UCS4Char;
var
  cs: Char;
begin
  Result := C;
  if FGlIsG1 then
    cs := FCharset1
  else
    cs := FCharset0;
  if (cs = '0') and (C >= $60) and (C <= $7E) then
    Result := DecGraphics[C];
end;

procedure TTermEmulator.Print(C: UCS4Char);
var
  w: Integer;
  cell: TTermCell;
begin
  C := TranslateGlyph(C);
  w := CodepointWidth(C);
  if w = 0 then
    Exit; // combinants ignores dans le MVP (grille stable garantie)

  if FWrapPending and FAutoWrap then
  begin
    FWrapPending := False;
    CarriageReturn;
    LineFeed;
  end
  else
    FWrapPending := False;

  // caractere large en fin de ligne: force le wrap avant
  if (w = 2) and (FX >= FScreen.Cols - 1) then
  begin
    if FAutoWrap then
    begin
      CarriageReturn;
      LineFeed;
    end
    else
      FX := FScreen.Cols - 2;
    if FX < 0 then
      FX := 0;
  end;

  if FInsertMode then
    FScreen.InsertChars(FX, FY, w, BlankPen);

  cell.Code := C;
  cell.Attrs := FAttrs;
  cell.Fg := FFg;
  cell.Bg := FBg;
  FScreen.SetCell(FX, FY, cell);
  if w = 2 then
  begin
    cell.Code := TERM_WIDE_CONT;
    FScreen.SetCell(FX + 1, FY, cell);
  end;
  FLastPrinted := C;

  if FX + w >= FScreen.Cols then
  begin
    FX := FScreen.Cols - 1;
    FWrapPending := True;
  end
  else
    Inc(FX, w);
  Damage;
end;

procedure TTermEmulator.CarriageReturn;
begin
  FX := 0;
  FWrapPending := False;
end;

procedure TTermEmulator.LineFeed;
begin
  if FY = FScrollBottom then
    ScrollRegionUp(1)
  else if FY < FScreen.Rows - 1 then
    Inc(FY);
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.ReverseIndex;
begin
  if FY = FScrollTop then
    ScrollRegionDown(1)
  else if FY > 0 then
    Dec(FY);
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.NextTab;
var
  x: Integer;
begin
  x := FX + 1;
  while (x < FScreen.Cols - 1) and ((x >= Length(FTabs)) or not FTabs[x]) do
    Inc(x);
  if x > FScreen.Cols - 1 then
    x := FScreen.Cols - 1;
  FX := x;
  FWrapPending := False;
end;

procedure TTermEmulator.PrevTab;
var
  x: Integer;
begin
  x := FX - 1;
  while (x > 0) and ((x >= Length(FTabs)) or not FTabs[x]) do
    Dec(x);
  if x < 0 then
    x := 0;
  FX := x;
  FWrapPending := False;
end;

procedure TTermEmulator.MoveTo(AX, AY: Integer);
var
  top, bottom: Integer;
begin
  if FOrigin then
  begin
    top := FScrollTop;
    bottom := FScrollBottom;
  end
  else
  begin
    top := 0;
    bottom := FScreen.Rows - 1;
  end;
  FY := top + AY;
  if FY < top then FY := top;
  if FY > bottom then FY := bottom;
  FX := AX;
  if FX < 0 then FX := 0;
  if FX >= FScreen.Cols then FX := FScreen.Cols - 1;
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.MoveRel(ADx, ADy: Integer);
var
  ny, top, bottom: Integer;
begin
  // les mouvements relatifs s'arretent aux marges de la region si le
  // curseur y est, sinon aux bords de l'ecran (VT100)
  if (FY >= FScrollTop) and (FY <= FScrollBottom) then
  begin
    top := FScrollTop;
    bottom := FScrollBottom;
  end
  else
  begin
    top := 0;
    bottom := FScreen.Rows - 1;
  end;
  ny := FY + ADy;
  if ny < top then ny := top;
  if ny > bottom then ny := bottom;
  FY := ny;
  FX := FX + ADx;
  if FX < 0 then FX := 0;
  if FX >= FScreen.Cols then FX := FScreen.Cols - 1;
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.ScrollRegionUp(N: Integer);
begin
  FScreen.ScrollUp(FScrollTop, FScrollBottom, N, BlankPen);
  Damage;
end;

procedure TTermEmulator.ScrollRegionDown(N: Integer);
begin
  FScreen.ScrollDown(FScrollTop, FScrollBottom, N, BlankPen);
  Damage;
end;

procedure TTermEmulator.Execute(B: Byte);
begin
  case B of
    $05: Respond(''); // ENQ: pas de chaine de reponse (rien a divulguer)
    $07: if Assigned(FOnBell) then FOnBell;
    $08: begin if FX > 0 then Dec(FX); FWrapPending := False; Damage; end;
    $09: begin NextTab; Damage; end;
    $0A, $0B, $0C:
      begin
        LineFeed;
        if FLnm then
          CarriageReturn;
      end;
    $0D: begin CarriageReturn; Damage; end;
    $0E: FGlIsG1 := True;  // SO
    $0F: FGlIsG1 := False; // SI
  end;
end;

procedure TTermEmulator.EscDispatch(const AInters: string; AFinal: Char);
var
  cellE: TTermCell;
begin
  if AInters = '' then
    case AFinal of
      '7': SaveCursorState(FSavedMain); // DECSC (partage main/alt: suffisant)
      '8': RestoreCursorState(FSavedMain);
      'D': LineFeed;          // IND
      'E': begin LineFeed; CarriageReturn; end; // NEL
      'H': if (FX >= 0) and (FX < Length(FTabs)) then FTabs[FX] := True; // HTS
      'M': ReverseIndex;      // RI
      'Z': Respond(#27'[?62;22c'); // DECID
      'c': FullReset;         // RIS
      '=': FAppKeypad := True;
      '>': FAppKeypad := False;
    end
  else if (AInters = '(') then
  begin
    if (AFinal = '0') or (AFinal = 'B') then FCharset0 := AFinal
    else FCharset0 := 'B';
  end
  else if (AInters = ')') then
  begin
    if (AFinal = '0') or (AFinal = 'B') then FCharset1 := AFinal
    else FCharset1 := 'B';
  end
  else if (AInters = '#') and (AFinal = '8') then
  begin
    // DECALN: remplit l'ecran de E, reset region et curseur
    FScrollTop := 0;
    FScrollBottom := FScreen.Rows - 1;
    cellE := BlankCell(DefaultColor, DefaultColor);
    cellE.Code := UCS4Char(Ord('E'));
    FScreen.FillScreen(cellE);
    FX := 0;
    FY := 0;
    Damage;
  end;
end;

procedure TTermEmulator.CsiDispatch(const AParams: array of Integer;
  AParamCount: Integer; APrivate: Char; const AInters: string; AFinal: Char);
var
  p: array of Integer;
  i, n, m: Integer;

  function P1(Idx: Integer): Integer; // param avec defaut 1
  begin
    if (Idx < AParamCount) and (AParams[Idx] > 0) then
      Result := AParams[Idx]
    else
      Result := 1;
  end;

  function P0(Idx: Integer): Integer; // param avec defaut 0
  begin
    if Idx < AParamCount then
      Result := AParams[Idx]
    else
      Result := 0;
  end;

begin
  p := nil;
  SetLength(p, AParamCount);
  for i := 0 to AParamCount - 1 do
    p[i] := AParams[i];

  if APrivate = '?' then
  begin
    case AFinal of
      'h': for i := 0 to AParamCount - 1 do DoDecMode(p[i], True);
      'l': for i := 0 to AParamCount - 1 do DoDecMode(p[i], False);
    end;
    Exit;
  end;
  if APrivate = '>' then
  begin
    if AFinal = 'c' then
      Respond(#27'[>1;10;0c'); // DA2: VT220-like
    Exit;
  end;
  if APrivate <> #0 then
    Exit; // '<' ou '=' non supporte: ignore

  if AInters = ' ' then
  begin
    if AFinal = 'q' then // DECSCUSR
    begin
      n := P0(0);
      case n of
        0, 1: FCursorStyle := csBlockBlink;
        2: FCursorStyle := csBlock;
        3: FCursorStyle := csUnderBlink;
        4: FCursorStyle := csUnder;
        5: FCursorStyle := csBarBlink;
        6: FCursorStyle := csBar;
      end;
      Damage;
    end;
    Exit;
  end;
  if AInters <> '' then
    Exit; // intermediaires non geres: ignore sans erreur

  case AFinal of
    'A': MoveRel(0, -P1(0));
    'B': MoveRel(0, P1(0));
    'C': MoveRel(P1(0), 0);
    'D': MoveRel(-P1(0), 0);
    'E': begin MoveRel(0, P1(0)); FX := 0; end;
    'F': begin MoveRel(0, -P1(0)); FX := 0; end;
    'G', '`': begin
        FX := P1(0) - 1;
        if FX < 0 then FX := 0;
        if FX >= FScreen.Cols then FX := FScreen.Cols - 1;
        FWrapPending := False;
        Damage;
      end;
    'H', 'f': MoveTo(P1(1) - 1, P1(0) - 1);
    'I': for i := 1 to P1(0) do NextTab;
    'J': begin
        n := P0(0);
        case n of
          0: begin
              FScreen.EraseChars(FX, FY, FScreen.Cols - FX, BlankPen);
              if FY < FScreen.Rows - 1 then
                FScreen.ClearRegion(0, FY + 1, FScreen.Cols - 1,
                  FScreen.Rows - 1, BlankPen);
            end;
          1: begin
              if FY > 0 then
                FScreen.ClearRegion(0, 0, FScreen.Cols - 1, FY - 1, BlankPen);
              FScreen.EraseChars(0, FY, FX + 1, BlankPen);
            end;
          2: FScreen.ClearRegion(0, 0, FScreen.Cols - 1, FScreen.Rows - 1,
               BlankPen);
          3: begin
              FScreen.ClearRegion(0, 0, FScreen.Cols - 1, FScreen.Rows - 1,
                BlankPen);
              FScreen.ClearScrollback;
            end;
        end;
        Damage;
      end;
    'K': begin
        case P0(0) of
          0: FScreen.EraseChars(FX, FY, FScreen.Cols - FX, BlankPen);
          1: FScreen.EraseChars(0, FY, FX + 1, BlankPen);
          2: FScreen.EraseChars(0, FY, FScreen.Cols, BlankPen);
        end;
        Damage;
      end;
    'L': if (FY >= FScrollTop) and (FY <= FScrollBottom) then
      begin
        FScreen.ScrollDown(FY, FScrollBottom, P1(0), BlankPen);
        Damage;
      end;
    'M': if (FY >= FScrollTop) and (FY <= FScrollBottom) then
      begin
        FScreen.ScrollUp(FY, FScrollBottom, P1(0), BlankPen);
        Damage;
      end;
    '@': begin FScreen.InsertChars(FX, FY, P1(0), BlankPen); Damage; end;
    'P': begin FScreen.DeleteChars(FX, FY, P1(0), BlankPen); Damage; end;
    'S': ScrollRegionUp(P1(0));
    'T': ScrollRegionDown(P1(0));
    'X': begin FScreen.EraseChars(FX, FY, P1(0), BlankPen); Damage; end;
    'Z': for i := 1 to P1(0) do PrevTab;
    'b': begin // REP: repete le dernier caractere imprime
        n := P1(0);
        if n > FScreen.Cols * FScreen.Rows then
          n := FScreen.Cols * FScreen.Rows; // borne: pas d'allocation distante
        if FLastPrinted >= $20 then
          for i := 1 to n do
            Print(FLastPrinted);
      end;
    'c': Respond(#27'[?62;22c'); // DA1: VT220 avec couleurs
    'd': MoveTo(FX, P1(0) - 1);
    'g': begin
        case P0(0) of
          0: if (FX >= 0) and (FX < Length(FTabs)) then FTabs[FX] := False;
          3: for i := 0 to High(FTabs) do FTabs[i] := False;
        end;
      end;
    'h': for i := 0 to AParamCount - 1 do DoAnsiMode(p[i], True);
    'l': for i := 0 to AParamCount - 1 do DoAnsiMode(p[i], False);
    'm': DoSgr(p, AParamCount);
    'n': begin
        case P0(0) of
          5: Respond(#27'[0n');
          6: begin
              if FOrigin then
                m := FY - FScrollTop + 1
              else
                m := FY + 1;
              Respond(#27'[' + IntToStr(m) + ';' + IntToStr(FX + 1) + 'R');
            end;
        end;
      end;
    'r': begin // DECSTBM
        n := P1(0) - 1;
        if AParamCount >= 2 then
          m := P1(1) - 1
        else
          m := FScreen.Rows - 1;
        if m >= FScreen.Rows then
          m := FScreen.Rows - 1;
        if (n >= 0) and (n < m) then
        begin
          FScrollTop := n;
          FScrollBottom := m;
          MoveTo(0, 0);
        end;
      end;
    's': SaveCursorState(FSavedMain);
    'u': RestoreCursorState(FSavedMain);
    't': ; // window ops: ignore, un serveur ne bouge pas nos fenetres
  end;
end;

procedure TTermEmulator.DoSgr(const P: array of Integer; Count: Integer);
var
  i, v: Integer;

  function TakeExtColor(var Idx: Integer; out Col: TTermColor): Boolean;
  begin
    Result := False;
    Col := DefaultColor;
    if Idx + 1 >= Count then
      Exit;
    case P[Idx + 1] of
      5: begin
          if Idx + 2 < Count then
          begin
            Col := IndexedColor(P[Idx + 2] and $FF);
            Inc(Idx, 2);
            Result := True;
          end
          else
            Inc(Idx, 1);
        end;
      2: begin
          if Idx + 4 < Count then
          begin
            Col := RgbColor(P[Idx + 2] and $FF, P[Idx + 3] and $FF,
              P[Idx + 4] and $FF);
            Inc(Idx, 4);
            Result := True;
          end
          else
            Idx := Count;
        end;
    else
      Inc(Idx, 1);
    end;
  end;

var
  col: TTermColor;
begin
  if Count = 0 then
  begin
    FAttrs := [];
    FFg := DefaultColor;
    FBg := DefaultColor;
    Exit;
  end;
  i := 0;
  while i < Count do
  begin
    v := P[i];
    case v of
      0: begin FAttrs := []; FFg := DefaultColor; FBg := DefaultColor; end;
      1: Include(FAttrs, taBold);
      2: Include(FAttrs, taFaint);
      3: Include(FAttrs, taItalic);
      4: Include(FAttrs, taUnderline);
      5, 6: Include(FAttrs, taBlink);
      7: Include(FAttrs, taInverse);
      8: Include(FAttrs, taInvisible);
      9: Include(FAttrs, taStrike);
      21, 22: FAttrs := FAttrs - [taBold, taFaint];
      23: Exclude(FAttrs, taItalic);
      24: Exclude(FAttrs, taUnderline);
      25: Exclude(FAttrs, taBlink);
      27: Exclude(FAttrs, taInverse);
      28: Exclude(FAttrs, taInvisible);
      29: Exclude(FAttrs, taStrike);
      30..37: FFg := IndexedColor(v - 30);
      38: if TakeExtColor(i, col) then FFg := col;
      39: FFg := DefaultColor;
      40..47: FBg := IndexedColor(v - 40);
      48: if TakeExtColor(i, col) then FBg := col;
      49: FBg := DefaultColor;
      90..97: FFg := IndexedColor(v - 90 + 8);
      100..107: FBg := IndexedColor(v - 100 + 8);
    end;
    Inc(i);
  end;
end;

procedure TTermEmulator.DoDecMode(AMode: Integer; ASet: Boolean);
begin
  case AMode of
    1: FAppCursorKeys := ASet;   // DECCKM
    3: begin // DECCOLM: pas de redimensionnement physique, juste clear+home
        FScreen.ClearRegion(0, 0, FScreen.Cols - 1, FScreen.Rows - 1, BlankPen);
        FScrollTop := 0;
        FScrollBottom := FScreen.Rows - 1;
        MoveTo(0, 0);
      end;
    5: begin FReverseVideo := ASet; Damage; end; // DECSCNM
    6: begin FOrigin := ASet; MoveTo(0, 0); end; // DECOM
    7: FAutoWrap := ASet;        // DECAWM
    9: if ASet then FMouseMode := mtX10 else FMouseMode := mtNone;
    12: ; // clignotement curseur: gere par DECSCUSR
    25: begin FCursorVisible := ASet; Damage; end; // DECTCEM
    47: if ASet then EnterAlt(False, False) else LeaveAlt(False);
    1000: if ASet then FMouseMode := mtNormal else FMouseMode := mtNone;
    1002: if ASet then FMouseMode := mtButton else FMouseMode := mtNone;
    1003: if ASet then FMouseMode := mtAny else FMouseMode := mtNone;
    1004: FFocusEvents := ASet;
    1005: ; // encodage UTF-8 souris: non supporte, SGR le remplace
    1006: FMouseSgr := ASet;
    1047: if ASet then EnterAlt(False, True) else LeaveAlt(False);
    1048: if ASet then SaveCursorState(FSaved1049)
          else RestoreCursorState(FSaved1049);
    1049: if ASet then EnterAlt(True, True) else LeaveAlt(True);
    2004: FBracketedPaste := ASet;
  end;
end;

procedure TTermEmulator.DoAnsiMode(AMode: Integer; ASet: Boolean);
begin
  case AMode of
    4: FInsertMode := ASet;  // IRM
    20: FLnm := ASet;        // LNM
  end;
end;

procedure TTermEmulator.SaveCursorState(var S: TSavedCursor);
begin
  S.X := FX;
  S.Y := FY;
  S.Attrs := FAttrs;
  S.Fg := FFg;
  S.Bg := FBg;
  S.Origin := FOrigin;
  S.Charset0 := FCharset0;
  S.Charset1 := FCharset1;
  S.GlIsG1 := FGlIsG1;
  S.Valid := True;
end;

procedure TTermEmulator.RestoreCursorState(const S: TSavedCursor);
begin
  if not S.Valid then
  begin
    FX := 0;
    FY := 0;
    FAttrs := [];
    FFg := DefaultColor;
    FBg := DefaultColor;
    Exit;
  end;
  FX := S.X;
  FY := S.Y;
  if FX >= FScreen.Cols then FX := FScreen.Cols - 1;
  if FY >= FScreen.Rows then FY := FScreen.Rows - 1;
  FAttrs := S.Attrs;
  FFg := S.Fg;
  FBg := S.Bg;
  FOrigin := S.Origin;
  FCharset0 := S.Charset0;
  FCharset1 := S.Charset1;
  FGlIsG1 := S.GlIsG1;
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.EnterAlt(ASaveCursor, AClear: Boolean);
begin
  if FScreen.OnAlt then
    Exit;
  if ASaveCursor then
    SaveCursorState(FSaved1049);
  FScreen.UseAlt(True, BlankPen);
  if AClear then
  begin
    FX := 0;
    FY := 0;
  end;
  FScrollTop := 0;
  FScrollBottom := FScreen.Rows - 1;
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.LeaveAlt(ARestoreCursor: Boolean);
begin
  if not FScreen.OnAlt then
    Exit;
  FScreen.UseAlt(False, BlankPen);
  FScrollTop := 0;
  FScrollBottom := FScreen.Rows - 1;
  if ARestoreCursor then
    RestoreCursorState(FSaved1049);
  FWrapPending := False;
  Damage;
end;

procedure TTermEmulator.OscDispatch(const APayload: RawByteString);
var
  sep, code: Integer;
  cmd, arg: RawByteString;
  cleanTitle: string;
  u: UnicodeString;
  i: Integer;
  hex: string;
begin
  sep := Pos(';', APayload);
  if sep = 0 then
  begin
    cmd := APayload;
    arg := '';
  end
  else
  begin
    cmd := Copy(APayload, 1, sep - 1);
    arg := Copy(APayload, sep + 1, MaxInt);
  end;
  code := StrToIntDef(string(cmd), -1);
  case code of
    0, 2: begin
        // titre d'onglet: borne, controles retires
        u := UTF8Decode(string(arg));
        if Length(u) > TERM_MAX_TITLE_LEN then
          SetLength(u, TERM_MAX_TITLE_LEN);
        cleanTitle := '';
        for i := 1 to Length(u) do
          if u[i] >= #32 then
            cleanTitle := cleanTitle + UTF8Encode(UnicodeString(u[i]));
        FTitle := cleanTitle;
        if Assigned(FOnTitle) then
          FOnTitle(FTitle);
      end;
    10, 11: if arg = '?' then
      begin
        // reponses limitees aux requetes de couleur
        if code = 10 then
          hex := Format('rgb:%2.2x/%2.2x/%2.2x',
            [(FDefaultFgRgb shr 16) and $FF, (FDefaultFgRgb shr 8) and $FF,
             FDefaultFgRgb and $FF])
        else
          hex := Format('rgb:%2.2x/%2.2x/%2.2x',
            [(FDefaultBgRgb shr 16) and $FF, (FDefaultBgRgb shr 8) and $FF,
             FDefaultBgRgb and $FF]);
        Respond(#27']' + string(cmd) + ';' + RawByteString(hex) + #7);
      end;
    52: ; // ecriture/lecture presse-papiers distante: refusee
    8: ;  // hyperlinks: le texte s'affiche, aucune ouverture automatique
  else
    ; // OSC inconnu: ignore
  end;
end;

end.
