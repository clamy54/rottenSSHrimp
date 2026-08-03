unit uRemoteSurface;

{$mode objfpc}{$H+}

// Surface de session graphique, BGRA 32 bits de stride impose:
// rendez-vous entre le thread de session qui blitte et le thread UI qui dessine.
// Partagee RDP/VNC: rien ici ne connait de protocole ni la LCL.

interface

uses
  SysUtils, SyncObjs;

const
  // 40 Mpx (~160 Mio en BGRA) passent tout ecran existant, 8K
  // portrait compris, la ou 8192 x 8192 en offriraient 256 a un serveur hostile.
  REMOTE_MIN_WIDTH = 200;
  REMOTE_MIN_HEIGHT = 200;
  REMOTE_MAX_WIDTH = 8192;
  REMOTE_MAX_HEIGHT = 8192;
  REMOTE_MAX_PIXELS = 40000000;
  REMOTE_BYTES_PER_PIXEL = 4;

type
  ERemoteSurfaceError = class(Exception);

  TRemoteRect = record
    Left, Top, Right, Bottom: Integer;
  end;

  TRemoteSurface = class
  private
    FLock: TCriticalSection;
    FData: PByte;
    FWidth, FHeight: Integer;
    FDirty: TRemoteRect;
    FHasDirty: Boolean;
    FGeneration: Int64;
    function GetWidth: Integer;
    function GetHeight: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Resize(AWidth, AHeight: Integer);

    // rectangles hors surface rognes, pas rejetes
    procedure BlitFrom(ASrc: PByte; ASrcStride: Integer;
      ALeft, ATop, AWidth, AHeight: Integer);

    function TakeDirty(out ARect: TRemoteRect): Boolean;
    procedure InvalidateAll;

    procedure Lock;
    procedure Unlock;
    // Data et ScanLine ne valent qu'entre Lock et Unlock.
    function ScanLine(AY: Integer): PByte;
    property Data: PByte read FData;

    property Width: Integer read GetWidth;
    property Height: Integer read GetHeight;
    // incrementee a chaque Resize: l'UI sait que sa mise en cache est perimee
    property Generation: Int64 read FGeneration;
  end;

function RemoteRect(ALeft, ATop, ARight, ABottom: Integer): TRemoteRect;
function RemoteRectIsEmpty(const AR: TRemoteRect): Boolean;
function RemoteRectUnion(const A, B: TRemoteRect): TRemoteRect;

// SEPARE de Resize: la GDI FreeRDP alloue w*h*4 des l'annonce du serveur, bien
// avant Resize -- ne verifier que la offrait 256 Mio a un serveur hostile.
function RemoteSizeAcceptable(AWidth, AHeight: Integer): Boolean;

implementation

function RemoteSizeAcceptable(AWidth, AHeight: Integer): Boolean;
begin
  Result := (AWidth >= REMOTE_MIN_WIDTH) and (AWidth <= REMOTE_MAX_WIDTH)
    and (AHeight >= REMOTE_MIN_HEIGHT) and (AHeight <= REMOTE_MAX_HEIGHT)
    and (Int64(AWidth) * Int64(AHeight) <= REMOTE_MAX_PIXELS);
end;

function RemoteRect(ALeft, ATop, ARight, ABottom: Integer): TRemoteRect;
begin
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Right := ARight;
  Result.Bottom := ABottom;
end;

function RemoteRectIsEmpty(const AR: TRemoteRect): Boolean;
begin
  Result := (AR.Right <= AR.Left) or (AR.Bottom <= AR.Top);
end;

function RemoteRectUnion(const A, B: TRemoteRect): TRemoteRect;
begin
  if RemoteRectIsEmpty(A) then
    Exit(B);
  if RemoteRectIsEmpty(B) then
    Exit(A);
  Result.Left := A.Left;
  if B.Left < Result.Left then Result.Left := B.Left;
  Result.Top := A.Top;
  if B.Top < Result.Top then Result.Top := B.Top;
  Result.Right := A.Right;
  if B.Right > Result.Right then Result.Right := B.Right;
  Result.Bottom := A.Bottom;
  if B.Bottom > Result.Bottom then Result.Bottom := B.Bottom;
end;

{ TRemoteSurface }

constructor TRemoteSurface.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDirty := RemoteRect(0, 0, 0, 0);
end;

destructor TRemoteSurface.Destroy;
begin
  if FData <> nil then
    FreeMem(FData);
  FLock.Free;
  inherited Destroy;
end;

procedure TRemoteSurface.Resize(AWidth, AHeight: Integer);
var
  sz: PtrUInt;
begin
  if not RemoteSizeAcceptable(AWidth, AHeight) then
    raise ERemoteSurfaceError.CreateFmt('Surface size refused: %dx%d',
      [AWidth, AHeight]);
  FLock.Acquire;
  try
    if (AWidth = FWidth) and (AHeight = FHeight) and (FData <> nil) then
      Exit;
    if FData <> nil then
    begin
      FreeMem(FData);
      FData := nil;
    end;
    sz := PtrUInt(AWidth) * PtrUInt(AHeight) * REMOTE_BYTES_PER_PIXEL;
    FData := GetMem(sz);
    FillChar(FData^, sz, 0);
    FWidth := AWidth;
    FHeight := AHeight;
    FDirty := RemoteRect(0, 0, AWidth, AHeight);
    FHasDirty := True;
    Inc(FGeneration);
  finally
    FLock.Release;
  end;
end;

procedure TRemoteSurface.BlitFrom(ASrc: PByte; ASrcStride: Integer;
  ALeft, ATop, AWidth, AHeight: Integer);
var
  y, copyBytes: Integer;
  dst, src: PByte;
  r: TRemoteRect;
  l64, t64, w64, h64: Int64;
begin
  if (ASrc = nil) or (AWidth <= 0) or (AHeight <= 0) then
    Exit;
  // un stride negatif ferait pointer la source n'importe ou
  if ASrcStride <= 0 then
    Exit;
  FLock.Acquire;
  try
    if FData = nil then
      Exit;
    // Rognage en Int64: sur des coordonnees extremes, ces sommes DEBORDENT en
    // Integer et laissent passer un Move hors de FData. Le controle doit etre
    // plus large que le type qu'il controle.
    l64 := ALeft;
    t64 := ATop;
    w64 := AWidth;
    h64 := AHeight;
    if l64 < 0 then
    begin
      w64 := w64 + l64;   // et non Dec(AWidth, -ALeft): -ALeft deborde en -MaxInt
      l64 := 0;
    end;
    if t64 < 0 then
    begin
      h64 := h64 + t64;
      t64 := 0;
    end;
    if l64 >= FWidth then Exit;
    if t64 >= FHeight then Exit;
    if l64 + w64 > FWidth then
      w64 := Int64(FWidth) - l64;
    if t64 + h64 > FHeight then
      h64 := Int64(FHeight) - t64;
    if (w64 <= 0) or (h64 <= 0) then
      Exit;
    ALeft := Integer(l64);
    ATop := Integer(t64);
    AWidth := Integer(w64);
    AHeight := Integer(h64);

    copyBytes := AWidth * REMOTE_BYTES_PER_PIXEL;
    for y := 0 to AHeight - 1 do
    begin
      dst := FData + PtrUInt((ATop + y) * FWidth + ALeft) * REMOTE_BYTES_PER_PIXEL;
      src := ASrc + PtrUInt((ATop + y) * ASrcStride) +
             PtrUInt(ALeft * REMOTE_BYTES_PER_PIXEL);
      Move(src^, dst^, copyBytes);
    end;

    r := RemoteRect(ALeft, ATop, ALeft + AWidth, ATop + AHeight);
    if FHasDirty then
      FDirty := RemoteRectUnion(FDirty, r)
    else
    begin
      FDirty := r;
      FHasDirty := True;
    end;
  finally
    FLock.Release;
  end;
end;

function TRemoteSurface.TakeDirty(out ARect: TRemoteRect): Boolean;
begin
  FLock.Acquire;
  try
    Result := FHasDirty and (not RemoteRectIsEmpty(FDirty));
    ARect := FDirty;
    FHasDirty := False;
    FDirty := RemoteRect(0, 0, 0, 0);
  finally
    FLock.Release;
  end;
end;

procedure TRemoteSurface.InvalidateAll;
begin
  FLock.Acquire;
  try
    if FData = nil then
      Exit;
    FDirty := RemoteRect(0, 0, FWidth, FHeight);
    FHasDirty := True;
  finally
    FLock.Release;
  end;
end;

procedure TRemoteSurface.Lock;
begin
  FLock.Acquire;
end;

procedure TRemoteSurface.Unlock;
begin
  FLock.Release;
end;

function TRemoteSurface.ScanLine(AY: Integer): PByte;
begin
  if (FData = nil) or (AY < 0) or (AY >= FHeight) then
    Exit(nil);
  Result := FData + PtrUInt(AY) * PtrUInt(FWidth) * REMOTE_BYTES_PER_PIXEL;
end;

function TRemoteSurface.GetWidth: Integer;
begin
  FLock.Acquire;
  try
    Result := FWidth;
  finally
    FLock.Release;
  end;
end;

function TRemoteSurface.GetHeight: Integer;
begin
  FLock.Acquire;
  try
    Result := FHeight;
  finally
    FLock.Release;
  end;
end;

end.
