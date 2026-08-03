unit uTermScreen;

{$mode objfpc}{$H+}

// Stockage de l'ecran terminal: grille active (principale ou alternate),
// scrollback en anneau borne en lignes ET en octets.
// Purement mecanique: le decodage et les modes vivent dans uTermEmulator.

interface

uses
  SysUtils, uTermTypes;

type
  TTermScreen = class
  private
    FCols, FRows: Integer;
    FMain: array of TTermLine;
    FAlt: array of TTermLine;
    FOnAlt: Boolean;
    FScrollback: array of TTermLine; // anneau
    FSbHead: Integer;                // index du plus ancien
    FSbCount: Integer;
    FSbMax: Integer;
    FSbBytes: Int64;
    function ActiveLines: Integer;
    function GetLine(Y: Integer): TTermLine;
    procedure PushScrollback(const ALine: TTermLine);
    function NewBlankLine(const ABlank: TTermCell): TTermLine;
    function LineBytes(const ALine: TTermLine): Int64;
  public
    constructor Create(ACols, ARows, AScrollbackMax: Integer);
    property Cols: Integer read FCols;
    property Rows: Integer read FRows;
    property OnAlt: Boolean read FOnAlt;
    // borne en octets de l'anneau, exposee pour le fuzzing
    property ScrollbackBytes: Int64 read FSbBytes;

    function GetCell(X, Y: Integer): TTermCell;
    procedure SetCell(X, Y: Integer; const ACell: TTermCell);
    // acces direct pour le rendu (ne pas conserver la reference)
    function LineRef(Y: Integer): TTermLine;

    procedure UseAlt(AOn: Boolean; const ABlank: TTermCell);
    procedure ScrollUp(ATop, ABottom, N: Integer; const ABlank: TTermCell);
    procedure ScrollDown(ATop, ABottom, N: Integer; const ABlank: TTermCell);
    procedure InsertChars(X, Y, N: Integer; const ABlank: TTermCell);
    procedure DeleteChars(X, Y, N: Integer; const ABlank: TTermCell);
    procedure EraseChars(X, Y, N: Integer; const ABlank: TTermCell);
    procedure ClearRegion(X1, Y1, X2, Y2: Integer; const ABlank: TTermCell);
    procedure FillScreen(const ACell: TTermCell);
    procedure Resize(ANewCols, ANewRows: Integer; var ACursorY: Integer);

    // Scrollback (ecran principal seulement)
    function ScrollbackCount: Integer;
    function ScrollbackLine(I: Integer): TTermLine; // 0 = plus ancien
    procedure ClearScrollback;
  end;

implementation

constructor TTermScreen.Create(ACols, ARows, AScrollbackMax: Integer);
var
  y: Integer;
  blank: TTermCell;
begin
  inherited Create;
  if ACols < TERM_MIN_COLS then ACols := TERM_MIN_COLS;
  if ACols > TERM_MAX_COLS then ACols := TERM_MAX_COLS;
  if ARows < TERM_MIN_ROWS then ARows := TERM_MIN_ROWS;
  if ARows > TERM_MAX_ROWS then ARows := TERM_MAX_ROWS;
  FCols := ACols;
  FRows := ARows;
  if AScrollbackMax < 0 then AScrollbackMax := 0;
  if AScrollbackMax > TERM_SCROLLBACK_HARD then
    AScrollbackMax := TERM_SCROLLBACK_HARD;
  FSbMax := AScrollbackMax;
  SetLength(FScrollback, FSbMax);
  blank := BlankCell(DefaultColor, DefaultColor);
  SetLength(FMain, FRows);
  SetLength(FAlt, FRows);
  for y := 0 to FRows - 1 do
  begin
    FMain[y] := NewBlankLine(blank);
    FAlt[y] := NewBlankLine(blank);
  end;
end;

function TTermScreen.ActiveLines: Integer;
begin
  Result := FRows;
end;

function TTermScreen.NewBlankLine(const ABlank: TTermCell): TTermLine;
var
  x: Integer;
begin
  Result := nil;
  SetLength(Result, FCols);
  for x := 0 to FCols - 1 do
    Result[x] := ABlank;
end;

function TTermScreen.LineBytes(const ALine: TTermLine): Int64;
begin
  Result := Int64(Length(ALine)) * SizeOf(TTermCell);
end;

function TTermScreen.GetLine(Y: Integer): TTermLine;
begin
  if FOnAlt then
    Result := FAlt[Y]
  else
    Result := FMain[Y];
end;

function TTermScreen.LineRef(Y: Integer): TTermLine;
begin
  if (Y < 0) or (Y >= FRows) then
    Exit(nil);
  Result := GetLine(Y);
end;

function TTermScreen.GetCell(X, Y: Integer): TTermCell;
begin
  if (X < 0) or (X >= FCols) or (Y < 0) or (Y >= FRows) then
    Exit(BlankCell(DefaultColor, DefaultColor));
  Result := GetLine(Y)[X];
end;

procedure TTermScreen.SetCell(X, Y: Integer; const ACell: TTermCell);
begin
  if (X < 0) or (X >= FCols) or (Y < 0) or (Y >= FRows) then
    Exit;
  GetLine(Y)[X] := ACell;
end;

procedure TTermScreen.UseAlt(AOn: Boolean; const ABlank: TTermCell);
var
  y: Integer;
begin
  if AOn = FOnAlt then
    Exit;
  FOnAlt := AOn;
  if AOn then
    for y := 0 to FRows - 1 do
      FAlt[y] := NewBlankLine(ABlank)
  else
    // Rendre l'ecran alterne en QUITTANT: son contenu ne resservira pas, et le
    // garder retenait Cols x Rows cellules par session ayant lance un vim.
    for y := 0 to FRows - 1 do
      FAlt[y] := nil;
end;

procedure TTermScreen.PushScrollback(const ALine: TTermLine);
var
  idx: Integer;
begin
  if FSbMax = 0 then
    Exit;
  // budget octets: evince les plus anciens
  FSbBytes := FSbBytes + LineBytes(ALine);
  while (FSbCount > 0) and (FSbBytes > TERM_SCROLLBACK_BYTES) do
  begin
    FSbBytes := FSbBytes - LineBytes(FScrollback[FSbHead]);
    FScrollback[FSbHead] := nil;
    FSbHead := (FSbHead + 1) mod FSbMax;
    Dec(FSbCount);
  end;
  if FSbCount = FSbMax then
  begin
    FSbBytes := FSbBytes - LineBytes(FScrollback[FSbHead]);
    FScrollback[FSbHead] := nil;
    FSbHead := (FSbHead + 1) mod FSbMax;
    Dec(FSbCount);
  end;
  idx := (FSbHead + FSbCount) mod FSbMax;
  FScrollback[idx] := ALine;
  Inc(FSbCount);
end;

procedure TTermScreen.ScrollUp(ATop, ABottom, N: Integer; const ABlank: TTermCell);
var
  y, i: Integer;
begin
  if (ATop < 0) or (ABottom >= FRows) or (ATop > ABottom) or (N <= 0) then
    Exit;
  if N > ABottom - ATop + 1 then
    N := ABottom - ATop + 1;
  for i := 0 to N - 1 do
    if (not FOnAlt) and (ATop = 0) then
      PushScrollback(FMain[ATop + i]);
  if FOnAlt then
  begin
    for y := ATop to ABottom - N do
      FAlt[y] := FAlt[y + N];
    for y := ABottom - N + 1 to ABottom do
      FAlt[y] := NewBlankLine(ABlank);
  end
  else
  begin
    for y := ATop to ABottom - N do
      FMain[y] := FMain[y + N];
    for y := ABottom - N + 1 to ABottom do
      FMain[y] := NewBlankLine(ABlank);
  end;
end;

procedure TTermScreen.ScrollDown(ATop, ABottom, N: Integer; const ABlank: TTermCell);
var
  y: Integer;
begin
  if (ATop < 0) or (ABottom >= FRows) or (ATop > ABottom) or (N <= 0) then
    Exit;
  if N > ABottom - ATop + 1 then
    N := ABottom - ATop + 1;
  if FOnAlt then
  begin
    for y := ABottom downto ATop + N do
      FAlt[y] := FAlt[y - N];
    for y := ATop to ATop + N - 1 do
      FAlt[y] := NewBlankLine(ABlank);
  end
  else
  begin
    for y := ABottom downto ATop + N do
      FMain[y] := FMain[y - N];
    for y := ATop to ATop + N - 1 do
      FMain[y] := NewBlankLine(ABlank);
  end;
end;

procedure TTermScreen.InsertChars(X, Y, N: Integer; const ABlank: TTermCell);
var
  line: TTermLine;
  i: Integer;
begin
  if (Y < 0) or (Y >= FRows) or (X < 0) or (X >= FCols) or (N <= 0) then
    Exit;
  if N > FCols - X then
    N := FCols - X;
  line := GetLine(Y);
  for i := FCols - 1 downto X + N do
    line[i] := line[i - N];
  for i := X to X + N - 1 do
    line[i] := ABlank;
end;

procedure TTermScreen.DeleteChars(X, Y, N: Integer; const ABlank: TTermCell);
var
  line: TTermLine;
  i: Integer;
begin
  if (Y < 0) or (Y >= FRows) or (X < 0) or (X >= FCols) or (N <= 0) then
    Exit;
  if N > FCols - X then
    N := FCols - X;
  line := GetLine(Y);
  for i := X to FCols - 1 - N do
    line[i] := line[i + N];
  for i := FCols - N to FCols - 1 do
    line[i] := ABlank;
end;

procedure TTermScreen.EraseChars(X, Y, N: Integer; const ABlank: TTermCell);
var
  line: TTermLine;
  i: Integer;
begin
  if (Y < 0) or (Y >= FRows) or (X < 0) or (X >= FCols) or (N <= 0) then
    Exit;
  if N > FCols - X then
    N := FCols - X;
  line := GetLine(Y);
  for i := X to X + N - 1 do
    line[i] := ABlank;
end;

procedure TTermScreen.ClearRegion(X1, Y1, X2, Y2: Integer; const ABlank: TTermCell);
var
  x, y, sx, ex: Integer;
  line: TTermLine;
begin
  if Y1 < 0 then Y1 := 0;
  if Y2 >= FRows then Y2 := FRows - 1;
  for y := Y1 to Y2 do
  begin
    line := GetLine(y);
    if y = Y1 then sx := X1 else sx := 0;
    if y = Y2 then ex := X2 else ex := FCols - 1;
    if sx < 0 then sx := 0;
    if ex >= FCols then ex := FCols - 1;
    for x := sx to ex do
      line[x] := ABlank;
  end;
end;

procedure TTermScreen.FillScreen(const ACell: TTermCell);
var
  x, y: Integer;
  line: TTermLine;
begin
  for y := 0 to FRows - 1 do
  begin
    line := GetLine(y);
    for x := 0 to FCols - 1 do
      line[x] := ACell;
  end;
end;

procedure TTermScreen.Resize(ANewCols, ANewRows: Integer; var ACursorY: Integer);
var
  y, x, keep, excess: Integer;
  blank: TTermCell;

  procedure ResizeLines(var Lines: array of TTermLine; NewCols: Integer);
  var
    i, oldLen, j: Integer;
  begin
    for i := 0 to High(Lines) do
    begin
      oldLen := Length(Lines[i]);
      SetLength(Lines[i], NewCols);
      for j := oldLen to NewCols - 1 do
        Lines[i][j] := blank;
    end;
  end;

begin
  if ANewCols < TERM_MIN_COLS then ANewCols := TERM_MIN_COLS;
  if ANewCols > TERM_MAX_COLS then ANewCols := TERM_MAX_COLS;
  if ANewRows < TERM_MIN_ROWS then ANewRows := TERM_MIN_ROWS;
  if ANewRows > TERM_MAX_ROWS then ANewRows := TERM_MAX_ROWS;
  if (ANewCols = FCols) and (ANewRows = FRows) then
    Exit;
  blank := BlankCell(DefaultColor, DefaultColor);

  // reduction en lignes: pousse le haut de l'ecran principal dans le
  // scrollback pour garder la ligne du curseur visible
  if ANewRows < FRows then
  begin
    excess := FRows - ANewRows;
    if ACursorY < ANewRows then
      keep := 0 // le curseur reste visible sans decaler
    else
      keep := ACursorY - ANewRows + 1;
    if keep > excess then
      keep := excess;
    if (keep > 0) and (not FOnAlt) then
      for y := 0 to keep - 1 do
        PushScrollback(FMain[y]);
    if keep > 0 then
    begin
      for y := 0 to FRows - 1 - keep do
      begin
        FMain[y] := FMain[y + keep];
        FAlt[y] := FAlt[y + keep];
      end;
      Dec(ACursorY, keep);
    end;
    SetLength(FMain, ANewRows);
    SetLength(FAlt, ANewRows);
  end
  else if ANewRows > FRows then
  begin
    SetLength(FMain, ANewRows);
    SetLength(FAlt, ANewRows);
    for y := FRows to ANewRows - 1 do
    begin
      FMain[y] := nil;
      FAlt[y] := nil;
      SetLength(FMain[y], ANewCols);
      SetLength(FAlt[y], ANewCols);
      for x := 0 to ANewCols - 1 do
      begin
        FMain[y][x] := blank;
        FAlt[y][x] := blank;
      end;
    end;
  end;
  FRows := ANewRows;

  ResizeLines(FMain, ANewCols);
  ResizeLines(FAlt, ANewCols);
  FCols := ANewCols;

  if ACursorY < 0 then ACursorY := 0;
  if ACursorY >= FRows then ACursorY := FRows - 1;
end;

function TTermScreen.ScrollbackCount: Integer;
begin
  Result := FSbCount;
end;

function TTermScreen.ScrollbackLine(I: Integer): TTermLine;
begin
  if (I < 0) or (I >= FSbCount) then
    Exit(nil);
  Result := FScrollback[(FSbHead + I) mod FSbMax];
end;

procedure TTermScreen.ClearScrollback;
var
  i: Integer;
begin
  for i := 0 to FSbMax - 1 do
    FScrollback[i] := nil;
  FSbHead := 0;
  FSbCount := 0;
  FSbBytes := 0;
end;

end.
