unit uTermControl;

{$mode objfpc}{$H+}

// Rendu par cellules du TTermEmulator, thread UI, coalesce par timer. Selection
// = copie immediate; le collage est borne, denulle et desamorce.

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, LCLIntf, Forms, ExtCtrls,
  Clipbrd, Dialogs, LMessages,
  uTermTypes, uTermScreen, uTermEmulator, uFontEmbed, uTheme, uTreeScrollBar;

const
  PASTE_MAX_BYTES = 1024 * 1024;
  PASTE_CONFIRM_CHARS = 512;
  PASTE_PREVIEW_LINES = 8;

type
  TTermSendEvent = procedure(const AData: RawByteString) of object;
  TTermGridEvent = procedure(ACols, ARows: Integer) of object;
  TTermStrEvent = procedure(const AValue: string) of object;

  TCellPos = record
    Line: Integer; // index absolu: scrollback puis ecran
    Col: Integer;
  end;

  TRottenTerminalControl = class(TCustomControl, IThemedScrollTarget)
  private
    FEmu: TTermEmulator;
    FCellW, FCellH: Integer;
    FFontSize: Integer;
    FBaseFontSize: Integer;
    FViewOffset: Integer; // lignes de scrollback visibles, comptees depuis le bas
    FOnScrollViewChanged: TNotifyEvent;
    FScrollAnimTimer: TTimer;
    FScrollAnimTarget: Integer;
    FScrollAnimActive: Boolean;
    FSelActive: Boolean;
    FSelecting: Boolean;
    FSelAnchor, FSelPoint: TCellPos;
    FLastClickAt: QWord;
    FClickCount: Integer;
    FRefreshTimer: TTimer;
    FOnSendData: TTermSendEvent;
    FOnGridResize: TTermGridEvent;
    FOnTitleChanged: TTermStrEvent;
    FOnEscapeCapture: TNotifyEvent;
    FPalette: array[0..255] of TColor;
    FDefFg, FDefBg: TColor;
    procedure BuildPalette;
    procedure MeasureCell;
    procedure RecomputeGrid;
    procedure RefreshTick(Sender: TObject);
    procedure EmuResponse(const AData: RawByteString);
    procedure EmuTitle(const ATitle: string);
    procedure EmuBell;
    function ColorOf(const C: TTermColor; AIsFg: Boolean): TColor;
    function TotalLines: Integer;
    function AbsLine(AViewRow: Integer): Integer;
    function LineAt(AAbs: Integer): TTermLine;
    function CellFromPoint(AX, AY: Integer): TCellPos;
    function PosLE(const A, B: TCellPos): Boolean;
    function HasSelection: Boolean;
    function SelectionText: string;
    procedure ClearSelection;
    procedure CopySelection;
    procedure SelectWordAt(const P: TCellPos);
    procedure SelectLineAt(const P: TCellPos);
    procedure DoPasteClipboard;
    procedure SendBytes(const AData: RawByteString);
    procedure SendMouseReport(AButton: Integer; AX, AY: Integer;
      ARelease, AMotion: Boolean; AShift: TShiftState);
    procedure ScrollView(ADelta: Integer);
    procedure SetZoom(ADelta: Integer);
    // offset PIXEL depuis le haut, sans stopper l'animation: le tick passe ici
    procedure SetViewFromTop(ATopPx: Integer);
    procedure ScrollAnimStop;
    procedure ScrollAnimTick(Sender: TObject);
  protected
    procedure Paint; override;
    // lit l'emulateur, pas l'ecran: correct meme onglet cache (miniatures)
    procedure RenderTo(ACanvas: TCanvas; const AClientRect: TRect;
      AFocused: Boolean);
    procedure Resize; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure UTF8KeyPress(var UTF8Key: TUTF8Char); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure WMGetDlgCode(var Msg: TLMNoParams); message LM_GETDLGCODE;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure FeedData(const AData: RawByteString);
    procedure ResetTerminal;
    function GridCols: Integer;
    function GridRows: Integer;
    // nil si trop petit ou pas encore mesure; l'appelant possede le bitmap
    function Snapshot: TBitmap;
    procedure SetTerminalFontSize(ASize: Integer);
    procedure SetDefaultColors(AFg, ABg: TColor);
    function ScrollViewportHeight: Integer;
    function ScrollMaxTop: Integer;
    function ScrollGetTop: Integer;
    procedure ScrollSetTop(AValue: Integer);
    procedure ScrollAnimateBy(ADelta: Integer);
    procedure ScrollWheelBy(AWheelDelta: Integer);
    procedure SetOnScrollViewChanged(AHandler: TNotifyEvent);
    property Emulator: TTermEmulator read FEmu;
    property OnSendData: TTermSendEvent read FOnSendData write FOnSendData;
    property OnGridResize: TTermGridEvent read FOnGridResize write FOnGridResize;
    property OnTitleChanged: TTermStrEvent read FOnTitleChanged write FOnTitleChanged;
    property OnEscapeCapture: TNotifyEvent read FOnEscapeCapture
      write FOnEscapeCapture;
  end;

implementation

const
  // TColor est BGR: ces litteraux xterm sont deja retournes
  Ansi16: array[0..15] of TColor = (
    $000000, $0000CD, $00CD00, $00CDCD, $EE0000, $CD00CD, $CDCD00, $E5E5E5,
    $7F7F7F, $5C5CFF, $00FF00, $00FFFF, $FF5C5C, $FF00FF, $FFFF00, $FFFFFF);

function BgrOfRgb(R, G, B: Byte): TColor;
begin
  Result := TColor(R or (G shl 8) or (B shl 16));
end;

constructor TRottenTerminalControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  TabStop := True;
  DoubleBuffered := True;
  Cursor := crIBeam;
  FBaseFontSize := RSTerminalFontSize;
  if FBaseFontSize <= 0 then
    FBaseFontSize := 13;
  FFontSize := FBaseFontSize;
  if RSTerminalFontName <> '' then
    Font.Name := RSTerminalFontName
  else
    Font.Name := string(EmbeddedFontManager.TerminalFontName);
  Font.Size := FFontSize;
  Font.Quality := fqCleartype;
  FDefFg := clTermFg;
  FDefBg := clTermBg;
  Color := FDefBg;
  BuildPalette;
  FEmu := TTermEmulator.Create(80, 24, TERM_SCROLLBACK_DEFAULT);
  FEmu.OnResponse := @EmuResponse;
  FEmu.OnTitle := @EmuTitle;
  FEmu.OnBell := @EmuBell;
  FEmu.DefaultFgRgb := (Red(clTermFg) shl 16) or (Green(clTermFg) shl 8)
    or Blue(clTermFg);
  FEmu.DefaultBgRgb := (Red(clTermBg) shl 16) or (Green(clTermBg) shl 8)
    or Blue(clTermBg);
  FCellW := 8;
  FCellH := 16;
  FRefreshTimer := TTimer.Create(Self);
  FRefreshTimer.Interval := 33;
  FRefreshTimer.OnTimer := @RefreshTick;
  FRefreshTimer.Enabled := True;
end;

destructor TRottenTerminalControl.Destroy;
begin
  FEmu.Free;
  inherited Destroy;
end;

procedure TRottenTerminalControl.BuildPalette;
var
  i, r, g, b: Integer;
const
  Steps: array[0..5] of Byte = (0, 95, 135, 175, 215, 255);
begin
  for i := 0 to 15 do
    FPalette[i] := Ansi16[i];
  for i := 16 to 231 do
  begin
    r := (i - 16) div 36;
    g := ((i - 16) div 6) mod 6;
    b := (i - 16) mod 6;
    FPalette[i] := BgrOfRgb(Steps[r], Steps[g], Steps[b]);
  end;
  for i := 232 to 255 do
  begin
    r := 8 + (i - 232) * 10;
    FPalette[i] := BgrOfRgb(r, r, r);
  end;
end;

procedure TRottenTerminalControl.MeasureCell;
var
  bmp: TBitmap;
begin
  bmp := TBitmap.Create;
  try
    bmp.Canvas.Font.Assign(Font);
    FCellW := bmp.Canvas.TextWidth('M');
    FCellH := bmp.Canvas.TextHeight('Mg');
    if FCellW < 2 then FCellW := 2;
    if FCellH < 4 then FCellH := 4;
  finally
    bmp.Free;
  end;
end;

procedure TRottenTerminalControl.RecomputeGrid;
var
  c, r: Integer;
begin
  MeasureCell;
  c := ClientWidth div FCellW;
  r := ClientHeight div FCellH;
  if c < TERM_MIN_COLS then c := TERM_MIN_COLS;
  if r < TERM_MIN_ROWS then r := TERM_MIN_ROWS;
  if c > TERM_MAX_COLS then c := TERM_MAX_COLS;
  if r > TERM_MAX_ROWS then r := TERM_MAX_ROWS;
  if (c <> FEmu.Screen.Cols) or (r <> FEmu.Screen.Rows) then
  begin
    FEmu.Resize(c, r);
    ClearSelection;
    if Assigned(FOnGridResize) then
      FOnGridResize(c, r);
  end;
  Invalidate;
end;

procedure TRottenTerminalControl.Resize;
begin
  inherited Resize;
  if FEmu <> nil then
    RecomputeGrid;
end;

procedure TRottenTerminalControl.RefreshTick(Sender: TObject);
begin
  if FEmu.ConsumeDamage then
    Invalidate;
end;

procedure TRottenTerminalControl.FeedData(const AData: RawByteString);
begin
  if AData = '' then
    Exit;
  FEmu.FeedStr(AData);
  // pas de saut en bas: qui lit le scrollback y reste
end;

procedure TRottenTerminalControl.ResetTerminal;
begin
  FEmu.Reset;
  FViewOffset := 0;
  ClearSelection;
  Invalidate;
end;

function TRottenTerminalControl.GridCols: Integer;
begin
  Result := FEmu.Screen.Cols;
end;

function TRottenTerminalControl.GridRows: Integer;
begin
  Result := FEmu.Screen.Rows;
end;

procedure TRottenTerminalControl.EmuResponse(const AData: RawByteString);
begin
  SendBytes(AData);
end;

procedure TRottenTerminalControl.EmuTitle(const ATitle: string);
begin
  if Assigned(FOnTitleChanged) then
    FOnTitleChanged(ATitle);
end;

procedure TRottenTerminalControl.EmuBell;
begin
  Beep;
end;

procedure TRottenTerminalControl.SendBytes(const AData: RawByteString);
begin
  if Assigned(FOnSendData) then
    FOnSendData(AData);
end;

function TRottenTerminalControl.ColorOf(const C: TTermColor;
  AIsFg: Boolean): TColor;
begin
  case C.Kind of
    tckIndexed: Result := FPalette[C.Value and $FF];
    tckRgb: Result := BgrOfRgb((C.Value shr 16) and $FF,
      (C.Value shr 8) and $FF, C.Value and $FF);
  else
    if AIsFg then
      Result := FDefFg
    else
      Result := FDefBg;
  end;
end;

function TRottenTerminalControl.TotalLines: Integer;
begin
  Result := FEmu.Screen.ScrollbackCount + FEmu.Screen.Rows;
end;

function TRottenTerminalControl.AbsLine(AViewRow: Integer): Integer;
begin
  Result := FEmu.Screen.ScrollbackCount - FViewOffset + AViewRow;
end;

function TRottenTerminalControl.LineAt(AAbs: Integer): TTermLine;
var
  sb: Integer;
begin
  sb := FEmu.Screen.ScrollbackCount;
  if AAbs < 0 then
    Exit(nil);
  if AAbs < sb then
    Result := FEmu.Screen.ScrollbackLine(AAbs)
  else if AAbs - sb < FEmu.Screen.Rows then
    Result := FEmu.Screen.LineRef(AAbs - sb)
  else
    Result := nil;
end;

procedure TRottenTerminalControl.Paint;
begin
  RenderTo(Canvas, ClientRect, Focused);
  // la barre themee resynchronise son pouce; le rendu n'ecrit jamais FViewOffset
  if Assigned(FOnScrollViewChanged) then
    FOnScrollViewChanged(Self);
end;

function TRottenTerminalControl.Snapshot: TBitmap;
var
  w, h: Integer;
begin
  Result := nil;
  w := Width;
  h := Height;
  if (w < 16) or (h < 16) or (FCellW <= 0) or (FCellH <= 0) then
    Exit;
  Result := TBitmap.Create;
  try
    Result.SetSize(w, h);
    RenderTo(Result.Canvas, Rect(0, 0, w, h), False);
  except
    FreeAndNil(Result);
  end;
end;

procedure TRottenTerminalControl.RenderTo(ACanvas: TCanvas;
  const AClientRect: TRect; AFocused: Boolean);
var
  y, x, xPix, yPix, wcells: Integer;
  absIdx, selL1, selC1, selL2, selC2: Integer;
  line: TTermLine;
  cell: TTermCell;
  fg, bg, tmp: TColor;
  style: TFontStyles;
  glyph: string;
  drawGlyph: Boolean;
  selMin, selMax: TCellPos;
  hasSel, cellSel: Boolean;
  cursorOn: Boolean;
begin
  ACanvas.Font.Assign(Font);
  ACanvas.Brush.Color := FDefBg;
  ACanvas.FillRect(AClientRect);

  hasSel := HasSelection;
  if hasSel then
  begin
    if PosLE(FSelAnchor, FSelPoint) then
    begin
      selMin := FSelAnchor;
      selMax := FSelPoint;
    end
    else
    begin
      selMin := FSelPoint;
      selMax := FSelAnchor;
    end;
    selL1 := selMin.Line; selC1 := selMin.Col;
    selL2 := selMax.Line; selC2 := selMax.Col;
  end
  else
  begin
    selL1 := 0; selC1 := 0; selL2 := -1; selC2 := -1;
  end;

  // Chaque glyphe epingle a x*FCellW: la chasse fractionnaire derive de la grille
  for y := 0 to FEmu.Screen.Rows - 1 do
  begin
    absIdx := AbsLine(y);
    line := LineAt(absIdx);
    if line = nil then
      Continue;
    yPix := y * FCellH;
    x := 0;
    while x < Length(line) do
    begin
      cell := line[x];
      if cell.Code = TERM_WIDE_CONT then
      begin
        Inc(x);
        Continue;
      end;
      wcells := 1;
      if (x + 1 < Length(line)) and (line[x + 1].Code = TERM_WIDE_CONT) then
        wcells := 2;
      fg := ColorOf(cell.Fg, True);
      bg := ColorOf(cell.Bg, False);
      if (taInverse in cell.Attrs) xor FEmu.ReverseVideo then
      begin
        tmp := fg; fg := bg; bg := tmp;
      end;
      if taFaint in cell.Attrs then
        fg := BgrOfRgb(
          (Red(fg) + Red(bg)) div 2,
          (Green(fg) + Green(bg)) div 2,
          (Blue(fg) + Blue(bg)) div 2);
      if taInvisible in cell.Attrs then
        fg := bg;
      cellSel := hasSel and
        ((absIdx > selL1) or ((absIdx = selL1) and (x >= selC1))) and
        ((absIdx < selL2) or ((absIdx = selL2) and (x <= selC2)));
      if cellSel then
      begin
        tmp := fg; fg := bg; bg := tmp;
        if fg = bg then
        begin
          fg := FDefBg;
          bg := FDefFg;
        end;
      end;
      xPix := x * FCellW;
      ACanvas.Brush.Style := bsSolid;
      ACanvas.Brush.Color := bg;
      ACanvas.FillRect(xPix, yPix, xPix + wcells * FCellW, yPix + FCellH);
      drawGlyph := (cell.Code > 32) or
        (taUnderline in cell.Attrs) or (taStrike in cell.Attrs);
      if drawGlyph then
      begin
        if cell.Code <= 32 then
          glyph := ' '
        else
          glyph := CodepointToUtf8(cell.Code);
        style := [];
        if taBold in cell.Attrs then Include(style, fsBold);
        if taItalic in cell.Attrs then Include(style, fsItalic);
        if taUnderline in cell.Attrs then Include(style, fsUnderline);
        if taStrike in cell.Attrs then Include(style, fsStrikeOut);
        ACanvas.Font.Style := style;
        ACanvas.Font.Color := fg;
        ACanvas.Brush.Style := bsClear;
        ACanvas.TextOut(xPix, yPix, glyph);
        ACanvas.Brush.Style := bsSolid;
      end;
      Inc(x, wcells);
    end;
  end;

  cursorOn := FEmu.CursorVisible and (FViewOffset = 0);
  if cursorOn then
  begin
    x := FEmu.CursorX;
    y := FEmu.CursorY;
    ACanvas.Brush.Style := bsSolid;
    if AFocused then
    begin
      case FEmu.CursorStyle of
        csUnderBlink, csUnder:
          begin
            ACanvas.Brush.Color := FDefFg;
            ACanvas.FillRect(x * FCellW, (y + 1) * FCellH - 2,
              (x + 1) * FCellW, (y + 1) * FCellH);
          end;
        csBarBlink, csBar:
          begin
            ACanvas.Brush.Color := FDefFg;
            ACanvas.FillRect(x * FCellW, y * FCellH, x * FCellW + 2,
              (y + 1) * FCellH);
          end;
      else
        begin
          line := FEmu.Screen.LineRef(y);
          ACanvas.Brush.Color := FDefFg;
          ACanvas.FillRect(x * FCellW, y * FCellH, (x + 1) * FCellW,
            (y + 1) * FCellH);
          if (line <> nil) and (x < Length(line)) and (line[x].Code > 1) then
          begin
            ACanvas.Font.Color := FDefBg;
            ACanvas.Font.Style := [];
            ACanvas.Brush.Style := bsClear;
            ACanvas.TextOut(x * FCellW, y * FCellH, CodepointToUtf8(line[x].Code));
            ACanvas.Brush.Style := bsSolid;
          end;
        end;
      end;
    end
    else
    begin
      ACanvas.Pen.Color := FDefFg;
      ACanvas.Brush.Style := bsClear;
      ACanvas.Rectangle(x * FCellW, y * FCellH, (x + 1) * FCellW,
        (y + 1) * FCellH);
      ACanvas.Brush.Style := bsSolid;
    end;
  end;
end;

function TRottenTerminalControl.CellFromPoint(AX, AY: Integer): TCellPos;
var
  vr: Integer;
begin
  Result.Col := AX div FCellW;
  if Result.Col < 0 then Result.Col := 0;
  if Result.Col >= FEmu.Screen.Cols then Result.Col := FEmu.Screen.Cols - 1;
  vr := AY div FCellH;
  if vr < 0 then vr := 0;
  if vr >= FEmu.Screen.Rows then vr := FEmu.Screen.Rows - 1;
  Result.Line := AbsLine(vr);
  if Result.Line < 0 then Result.Line := 0;
  if Result.Line >= TotalLines then Result.Line := TotalLines - 1;
end;

function TRottenTerminalControl.PosLE(const A, B: TCellPos): Boolean;
begin
  Result := (A.Line < B.Line) or ((A.Line = B.Line) and (A.Col <= B.Col));
end;

function TRottenTerminalControl.HasSelection: Boolean;
begin
  Result := FSelActive and
    ((FSelAnchor.Line <> FSelPoint.Line) or (FSelAnchor.Col <> FSelPoint.Col));
end;

procedure TRottenTerminalControl.ClearSelection;
begin
  FSelActive := False;
  FSelecting := False;
end;

function TRottenTerminalControl.SelectionText: string;
var
  a, b: TCellPos;
  l, x1, x2, x: Integer;
  line: TTermLine;
  s: string;
begin
  Result := '';
  if not HasSelection then
    Exit;
  if PosLE(FSelAnchor, FSelPoint) then
  begin
    a := FSelAnchor;
    b := FSelPoint;
  end
  else
  begin
    a := FSelPoint;
    b := FSelAnchor;
  end;
  for l := a.Line to b.Line do
  begin
    line := LineAt(l);
    if line = nil then
      Continue;
    if l = a.Line then x1 := a.Col else x1 := 0;
    if l = b.Line then x2 := b.Col else x2 := Length(line) - 1;
    s := '';
    for x := x1 to x2 do
      if x < Length(line) then
      begin
        if line[x].Code = 0 then
          s := s + ' '
        else if line[x].Code <> TERM_WIDE_CONT then
          s := s + CodepointToUtf8(line[x].Code);
      end;
    s := TrimRight(s);
    if l = a.Line then
      Result := s
    else
      Result := Result + LineEnding + s;
  end;
end;

procedure TRottenTerminalControl.CopySelection;
var
  s: string;
begin
  s := SelectionText;
  if s <> '' then
    Clipboard.AsText := s;
end;

function IsWordChar(C: UCS4Char): Boolean;
begin
  Result := ((C >= Ord('a')) and (C <= Ord('z'))) or
    ((C >= Ord('A')) and (C <= Ord('Z'))) or
    ((C >= Ord('0')) and (C <= Ord('9'))) or
    (C = Ord('_')) or (C = Ord('-')) or (C = Ord('.')) or (C = Ord('/')) or
    (C = Ord('~')) or (C > $7F);
end;

procedure TRottenTerminalControl.SelectWordAt(const P: TCellPos);
var
  line: TTermLine;
  c1, c2: Integer;
begin
  line := LineAt(P.Line);
  if (line = nil) or (P.Col >= Length(line)) or
     (not IsWordChar(line[P.Col].Code)) then
    Exit;
  c1 := P.Col;
  c2 := P.Col;
  while (c1 > 0) and IsWordChar(line[c1 - 1].Code) do
    Dec(c1);
  while (c2 < Length(line) - 1) and IsWordChar(line[c2 + 1].Code) do
    Inc(c2);
  FSelAnchor.Line := P.Line;
  FSelAnchor.Col := c1;
  FSelPoint.Line := P.Line;
  FSelPoint.Col := c2;
  FSelActive := True;
  CopySelection;
  Invalidate;
end;

procedure TRottenTerminalControl.SelectLineAt(const P: TCellPos);
begin
  FSelAnchor.Line := P.Line;
  FSelAnchor.Col := 0;
  FSelPoint.Line := P.Line;
  FSelPoint.Col := FEmu.Screen.Cols - 1;
  FSelActive := True;
  CopySelection;
  Invalidate;
end;

procedure TRottenTerminalControl.DoPasteClipboard;
var
  txt: string;
  cleaned: RawByteString;
  i, n, lineCount: Integer;
  preview: string;
  previewLines: TStringList;
  needConfirm: Boolean;
begin
  txt := Clipboard.AsText;
  if txt = '' then
    Exit;
  // BORNER D'ABORD: nettoyer 300 Mo pour n'en coller 1 se paye sur le thread UI
  if Length(txt) > PASTE_MAX_BYTES then
    SetLength(txt, PASTE_MAX_BYTES);
  SetLength(cleaned, Length(txt));
  n := 0;
  for i := 1 to Length(txt) do
    if txt[i] <> #0 then
    begin
      Inc(n);
      cleaned[n] := txt[i];
    end;
  SetLength(cleaned, n);
  cleaned := StringReplace(cleaned, #13#10, #13, [rfReplaceAll]);
  cleaned := StringReplace(cleaned, #10, #13, [rfReplaceAll]);
  // fin de bracketed paste embarquee = injection: on la desamorce
  cleaned := StringReplace(cleaned, #27'[201~', '', [rfReplaceAll]);

  lineCount := 1;
  for i := 1 to Length(cleaned) do
    if cleaned[i] = #13 then
      Inc(lineCount);

  needConfirm := (lineCount > 1) or (Length(cleaned) > PASTE_CONFIRM_CHARS);
  if needConfirm then
  begin
    previewLines := TStringList.Create;
    try
      previewLines.Text := StringReplace(string(cleaned), #13, LineEnding,
        [rfReplaceAll]);
      preview := '';
      for i := 0 to previewLines.Count - 1 do
      begin
        if i >= PASTE_PREVIEW_LINES then
        begin
          preview := preview + LineEnding + Format('… (%d more lines)',
            [previewLines.Count - PASTE_PREVIEW_LINES]);
          Break;
        end;
        if i > 0 then
          preview := preview + LineEnding;
        preview := preview + Copy(previewLines[i], 1, 120);
      end;
    finally
      previewLines.Free;
    end;
    if QuestionDlg('Paste',
      Format('The clipboard contains %d lines.', [lineCount]) + LineEnding +
      'Pasting multiple commands can be dangerous.' + LineEnding +
      LineEnding + preview,
      mtWarning, [mrOK, 'Paste', mrCancel, 'Cancel', 'IsCancel'], 0) <> mrOK then
      Exit;
  end;

  if FEmu.BracketedPaste then
    cleaned := #27'[200~' + cleaned + #27'[201~';
  SendBytes(cleaned);
  FViewOffset := 0;
  Invalidate;
end;

procedure TRottenTerminalControl.SendMouseReport(AButton: Integer;
  AX, AY: Integer; ARelease, AMotion: Boolean; AShift: TShiftState);
var
  cb, col, row: Integer;
  s: RawByteString;
begin
  col := AX div FCellW + 1;
  row := AY div FCellH + 1;
  if col < 1 then col := 1;
  if row < 1 then row := 1;
  if col > FEmu.Screen.Cols then col := FEmu.Screen.Cols;
  if row > FEmu.Screen.Rows then row := FEmu.Screen.Rows;
  cb := AButton;
  if AMotion then
    Inc(cb, 32);
  if ssShift in AShift then Inc(cb, 4);
  if ssAlt in AShift then Inc(cb, 8);
  if ssCtrl in AShift then Inc(cb, 16);
  if FEmu.MouseSgr then
  begin
    if ARelease then
      s := #27'[<' + IntToStr(cb) + ';' + IntToStr(col) + ';' +
        IntToStr(row) + 'm'
    else
      s := #27'[<' + IntToStr(cb) + ';' + IntToStr(col) + ';' +
        IntToStr(row) + 'M';
  end
  else
  begin
    if ARelease then
      cb := 3;
    if (col > 223) or (row > 223) then
      Exit;
    s := #27'[M' + Chr(32 + cb) + Chr(32 + col) + Chr(32 + row);
  end;
  SendBytes(s);
end;

procedure TRottenTerminalControl.MouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  p: TCellPos;
  now_: QWord;
  reportToApp: Boolean;
begin
  inherited MouseDown(Button, Shift, X, Y);
  SetFocus;
  reportToApp := (FEmu.MouseMode <> mtNone) and (not (ssShift in Shift)) and
    (FViewOffset = 0);

  if Button = mbRight then
  begin
    if reportToApp then
      SendMouseReport(2, X, Y, False, False, Shift)
    else
      DoPasteClipboard;
    Exit;
  end;

  if Button = mbMiddle then
  begin
    if reportToApp then
      SendMouseReport(1, X, Y, False, False, Shift);
    Exit;
  end;

  if reportToApp and (FEmu.MouseMode <> mtNone) then
  begin
    SendMouseReport(0, X, Y, False, False, Shift);
    Exit;
  end;

  p := CellFromPoint(X, Y);
  now_ := GetTickCount64;
  if (now_ - FLastClickAt) < 400 then
    Inc(FClickCount)
  else
    FClickCount := 1;
  FLastClickAt := now_;

  case FClickCount of
    2: begin SelectWordAt(p); Exit; end;
    3: begin SelectLineAt(p); FClickCount := 0; Exit; end;
  end;

  FSelecting := True;
  FSelActive := True;
  FSelAnchor := p;
  FSelPoint := p;
  Invalidate;
end;

procedure TRottenTerminalControl.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if FSelecting then
  begin
    FSelPoint := CellFromPoint(X, Y);
    Invalidate;
  end
  else if (FEmu.MouseMode = mtAny) and (FViewOffset = 0) and
    (not (ssShift in Shift)) then
    SendMouseReport(0, X, Y, False, True, Shift);
end;

procedure TRottenTerminalControl.MouseUp(Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (FEmu.MouseMode <> mtNone) and (not (ssShift in Shift)) and
    (FViewOffset = 0) and (not FSelecting) then
  begin
    case Button of
      mbLeft: SendMouseReport(0, X, Y, True, False, Shift);
      mbMiddle: SendMouseReport(1, X, Y, True, False, Shift);
      mbRight: SendMouseReport(2, X, Y, True, False, Shift);
    end;
    Exit;
  end;
  if FSelecting then
  begin
    FSelecting := False;
    if HasSelection then
      CopySelection
    else
      FSelActive := False;
    Invalidate;
  end;
end;

function TRottenTerminalControl.DoMouseWheel(Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  steps, i: Integer;
  seq: RawByteString;
begin
  Result := True;
  steps := WheelDelta div 40;
  if steps = 0 then
  begin
    if WheelDelta > 0 then steps := 1 else steps := -1;
  end;

  if (ssMeta in Shift) or (ssCtrl in Shift) then
  begin
    SetZoom(steps);
    Exit;
  end;

  {$IFDEF DARWIN}
  // Cocoa met deja le defilement « naturel » dans le signe: sans ca, contresens
  steps := -steps;
  {$ENDIF}

  if (FEmu.MouseMode <> mtNone) and (not (ssShift in Shift)) and
    (FViewOffset = 0) then
  begin
    for i := 1 to Abs(steps) do
      if steps > 0 then
        SendMouseReport(64, MousePos.X, MousePos.Y, False, False, Shift)
      else
        SendMouseReport(65, MousePos.X, MousePos.Y, False, False, Shift);
    Exit;
  end;

  if FEmu.Screen.OnAlt then
  begin
    if FEmu.AppCursorKeys then
    begin
      if steps > 0 then seq := #27'OA' else seq := #27'OB';
    end
    else
    begin
      if steps > 0 then seq := #27'[A' else seq := #27'[B';
    end;
    for i := 1 to Abs(steps) * 3 do
      SendBytes(seq);
    Exit;
  end;

  ScrollView(steps * 3);
end;

procedure TRottenTerminalControl.ScrollView(ADelta: Integer);
var
  v: Integer;
begin
  v := FViewOffset + ADelta;
  if v < 0 then v := 0;
  if v > FEmu.Screen.ScrollbackCount then v := FEmu.Screen.ScrollbackCount;
  if v <> FViewOffset then
  begin
    FViewOffset := v;
    Invalidate;
  end;
end;

{ IThemedScrollTarget: le terminal defile en LIGNES, expose en PIXELS. FViewOffset
  compte depuis le BAS (0 = live), la barre depuis le HAUT -- conversion inversee. }

function TRottenTerminalControl.ScrollViewportHeight: Integer;
begin
  Result := FEmu.Screen.Rows * FCellH;
end;

function TRottenTerminalControl.ScrollMaxTop: Integer;
begin
  Result := FEmu.Screen.ScrollbackCount * FCellH;
end;

function TRottenTerminalControl.ScrollGetTop: Integer;
begin
  Result := (FEmu.Screen.ScrollbackCount - FViewOffset) * FCellH;
end;

procedure TRottenTerminalControl.SetViewFromTop(ATopPx: Integer);
var
  sb, linesFromTop, newOffset: Integer;
begin
  if FCellH <= 0 then Exit;
  sb := FEmu.Screen.ScrollbackCount;
  linesFromTop := Round(ATopPx / FCellH);
  newOffset := sb - linesFromTop;
  if newOffset < 0 then newOffset := 0;
  if newOffset > sb then newOffset := sb;
  if newOffset <> FViewOffset then
  begin
    FViewOffset := newOffset;
    Invalidate;
  end;
end;

procedure TRottenTerminalControl.ScrollSetTop(AValue: Integer);
begin
  ScrollAnimStop;   // le glisser du pouce prime sur l'animation en cours
  SetViewFromTop(AValue);
end;

procedure TRottenTerminalControl.ScrollAnimStop;
begin
  FScrollAnimActive := False;
  if FScrollAnimTimer <> nil then
    FScrollAnimTimer.Enabled := False;
end;

procedure TRottenTerminalControl.ScrollAnimateBy(ADelta: Integer);
var
  target, maxTop: Integer;
begin
  if ADelta = 0 then Exit;
  // chaque cran s'ajoute a la CIBLE, pas a l'offset: le rapide ne se traine pas
  if FScrollAnimActive then
    target := FScrollAnimTarget + ADelta
  else
    target := ScrollGetTop + ADelta;
  maxTop := ScrollMaxTop;
  if target < 0 then target := 0;
  if target > maxTop then target := maxTop;
  FScrollAnimTarget := target;
  if FScrollAnimTimer = nil then
  begin
    FScrollAnimTimer := TTimer.Create(Self);
    FScrollAnimTimer.Interval := 15;
    FScrollAnimTimer.OnTimer := @ScrollAnimTick;
  end;
  FScrollAnimActive := True;
  FScrollAnimTimer.Enabled := True;
end;

procedure TRottenTerminalControl.ScrollAnimTick(Sender: TObject);
var
  cur, dist, step: Integer;
begin
  cur := ScrollGetTop;
  dist := FScrollAnimTarget - cur;
  if Abs(dist) <= FCellH div 2 then
  begin
    ScrollAnimStop;
    Exit;
  end;
  step := dist div 3;
  if Abs(step) < FCellH then
    if dist > 0 then step := FCellH else step := -FCellH;
  SetViewFromTop(cur + step);
  if ScrollGetTop = cur then
    ScrollAnimStop;
end;

procedure TRottenTerminalControl.ScrollWheelBy(AWheelDelta: Integer);
var
  px: Integer;
begin
  px := -((AWheelDelta * Mouse.WheelScrollLines * FCellH) div 120);
  {$IFDEF DARWIN}
  px := -px;   // meme parite macOS que DoMouseWheel
  {$ENDIF}
  ScrollAnimateBy(px);
end;

procedure TRottenTerminalControl.SetOnScrollViewChanged(AHandler: TNotifyEvent);
begin
  FOnScrollViewChanged := AHandler;
end;

procedure TRottenTerminalControl.SetTerminalFontSize(ASize: Integer);
begin
  if ASize < 6 then ASize := 6;
  if ASize > 72 then ASize := 72;
  FBaseFontSize := ASize;
  if ASize = FFontSize then Exit;
  FFontSize := ASize;
  Font.Size := ASize;
  RecomputeGrid;
end;

procedure TRottenTerminalControl.SetDefaultColors(AFg, ABg: TColor);
begin
  FDefFg := AFg;
  FDefBg := ABg;
  FEmu.DefaultFgRgb := (Red(AFg) shl 16) or (Green(AFg) shl 8) or Blue(AFg);
  FEmu.DefaultBgRgb := (Red(ABg) shl 16) or (Green(ABg) shl 8) or Blue(ABg);
  Invalidate;
end;

procedure TRottenTerminalControl.SetZoom(ADelta: Integer);
var
  sz: Integer;
begin
  if ADelta = 0 then
    sz := FBaseFontSize
  else
    sz := FFontSize + ADelta;
  if sz < 6 then sz := 6;
  if sz > 72 then sz := 72;
  if sz = FFontSize then
    Exit;
  FFontSize := sz;
  Font.Size := sz;
  RecomputeGrid;
end;

procedure TRottenTerminalControl.WMGetDlgCode(var Msg: TLMNoParams);
begin
  // recuperer Tab et les fleches au lieu de la navigation de focus
  Msg.Result := DLGC_WANTALLKEYS or DLGC_WANTTAB or DLGC_WANTARROWS or
    DLGC_WANTCHARS;
end;

procedure TRottenTerminalControl.KeyDown(var Key: Word; Shift: TShiftState);
var
  seq: RawByteString;
  mods: Integer;

  function ModParam: string;
  begin
    mods := 1;
    if ssShift in Shift then Inc(mods, 1);
    if ssAlt in Shift then Inc(mods, 2);
    if ssCtrl in Shift then Inc(mods, 4);
    Result := IntToStr(mods);
  end;

  function CursorSeq(const AFinal: Char): RawByteString;
  begin
    if (Shift * [ssShift, ssAlt, ssCtrl]) <> [] then
      Result := #27'[1;' + ModParam + AFinal
    else if FEmu.AppCursorKeys then
      Result := #27'O' + AFinal
    else
      Result := #27'[' + AFinal;
  end;

  function TildeSeq(ACode: Integer): RawByteString;
  begin
    if (Shift * [ssShift, ssAlt, ssCtrl]) <> [] then
      Result := #27'[' + IntToStr(ACode) + ';' + ModParam + '~'
    else
      Result := #27'[' + IntToStr(ACode) + '~';
  end;

var
  isCopyCombo, isPasteCombo: Boolean;
begin
  // echappement: rend le focus a l'application, rien ne part au shell
  if (Key = VK_RETURN) and (ssCtrl in Shift) and (ssAlt in Shift) then
  begin
    Key := 0;
    if Assigned(FOnEscapeCapture) then
      FOnEscapeCapture(Self);
    Exit;
  end;

  // Ctrl+C SEUL doit rester au terminal: le copier demande Shift (ou Cmd)
  {$IFDEF DARWIN}
  isCopyCombo := (ssMeta in Shift) and (Key = VK_C);
  isPasteCombo := (ssMeta in Shift) and (Key = VK_V);
  {$ELSE}
  isCopyCombo := (ssCtrl in Shift) and (ssShift in Shift) and (Key = VK_C);
  isPasteCombo := (ssCtrl in Shift) and (ssShift in Shift) and (Key = VK_V);
  {$ENDIF}
  if isCopyCombo then
  begin
    CopySelection;
    Key := 0;
    Exit;
  end;
  if isPasteCombo then
  begin
    DoPasteClipboard;
    Key := 0;
    Exit;
  end;

  {$IFDEF DARWIN}
  if ssMeta in Shift then
  {$ELSE}
  if ssCtrl in Shift then
  {$ENDIF}
  begin
    case Key of
      VK_ADD, VK_OEM_PLUS: begin SetZoom(1); Key := 0; Exit; end;
      VK_SUBTRACT, VK_OEM_MINUS: begin SetZoom(-1); Key := 0; Exit; end;
      VK_0, VK_NUMPAD0: begin SetZoom(0); Key := 0; Exit; end;
    end;
  end;

  if (ssShift in Shift) and ((Key = VK_PRIOR) or (Key = VK_NEXT)) then
  begin
    if Key = VK_PRIOR then
      ScrollView(FEmu.Screen.Rows - 1)
    else
      ScrollView(-(FEmu.Screen.Rows - 1));
    Key := 0;
    Exit;
  end;

  seq := '';
  case Key of
    VK_RETURN: seq := #13;
    VK_BACK: seq := #127;
    VK_TAB: if ssShift in Shift then seq := #27'[Z' else seq := #9;
    VK_ESCAPE: seq := #27;
    VK_UP: seq := CursorSeq('A');
    VK_DOWN: seq := CursorSeq('B');
    VK_RIGHT: seq := CursorSeq('C');
    VK_LEFT: seq := CursorSeq('D');
    VK_HOME: seq := CursorSeq('H');
    VK_END: seq := CursorSeq('F');
    VK_PRIOR: seq := TildeSeq(5);
    VK_NEXT: seq := TildeSeq(6);
    VK_INSERT: seq := TildeSeq(2);
    VK_DELETE: seq := TildeSeq(3);
    VK_F1: seq := #27'OP';
    VK_F2: seq := #27'OQ';
    VK_F3: seq := #27'OR';
    VK_F4: seq := #27'OS';
    VK_F5: seq := TildeSeq(15);
    VK_F6: seq := TildeSeq(17);
    VK_F7: seq := TildeSeq(18);
    VK_F8: seq := TildeSeq(19);
    VK_F9: seq := TildeSeq(20);
    VK_F10: seq := TildeSeq(21);
    VK_F11: seq := TildeSeq(23);
    VK_F12: seq := TildeSeq(24);
  else
    if (ssCtrl in Shift) and (not (ssMeta in Shift)) and
       (Key >= Ord('A')) and (Key <= Ord('Z')) then
      seq := Chr(Key - Ord('A') + 1)
    else if (ssCtrl in Shift) and (Key = VK_SPACE) then
      seq := #0;
  end;

  if seq <> '' then
  begin
    SendBytes(seq);
    FViewOffset := 0;
    ClearSelection;
    Invalidate;
    Key := 0;
  end;
end;

procedure TRottenTerminalControl.UTF8KeyPress(var UTF8Key: TUTF8Char);
var
  s: RawByteString;
begin
  s := UTF8Key;
  // les controles sont geres dans KeyDown (pas de double envoi)
  if (Length(s) = 1) and (s[1] < #32) then
    Exit;
  if s = #127 then
    Exit;
  if s <> '' then
  begin
    SendBytes(s);
    FViewOffset := 0;
    ClearSelection;
    Invalidate;
    UTF8Key := '';
  end;
end;

procedure TRottenTerminalControl.DoEnter;
begin
  inherited DoEnter;
  if FEmu.FocusEvents then
    SendBytes(#27'[I');
  Invalidate;
end;

procedure TRottenTerminalControl.DoExit;
begin
  inherited DoExit;
  if FEmu.FocusEvents then
    SendBytes(#27'[O');
  Invalidate;
end;

end.
