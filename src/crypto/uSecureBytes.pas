unit uSecureBytes;

{$mode objfpc}{$H+}

// Secrets en sodium_malloc + mlock. JAMAIS copier le contenu dans une string:
// elle finirait en clair dans le tas, puis dans le swap.

interface

uses
  SysUtils;

type
  TSecureBytes = class
  private
    FData: PByte;
    FLength: NativeUInt;
    FLocked: Boolean;
  public
    constructor Create(ALength: NativeUInt);
    // Copie; effacer la source reste le probleme de l'appelant.
    constructor CreateFrom(const AData; ALength: NativeUInt);
    destructor Destroy; override;
    procedure Clear;
    function Data: PByte;
    function Len: NativeUInt;
    // temps constant
    function Equals(AOther: TSecureBytes): Boolean; reintroduce;
  end;

implementation

uses
  uSodiumApi;

constructor TSecureBytes.Create(ALength: NativeUInt);
begin
  inherited Create;
  SodiumEnsureLoaded;
  FLength := ALength;
  if ALength = 0 then
    ALength := 1;
  FData := sodium_malloc(ALength);
  if FData = nil then
    raise EOutOfMemory.Create('sodium_malloc failed');
  FillChar(FData^, ALength, 0);
  FLocked := sodium_mlock(FData, ALength) = 0;
end;

constructor TSecureBytes.CreateFrom(const AData; ALength: NativeUInt);
begin
  Create(ALength);
  if ALength > 0 then
    Move(AData, FData^, ALength);
end;

destructor TSecureBytes.Destroy;
begin
  if FData <> nil then
  begin
    if FLocked then
      sodium_munlock(FData, FLength);
    sodium_free(FData);
  end;
  inherited Destroy;
end;

procedure TSecureBytes.Clear;
begin
  if (FData <> nil) and (FLength > 0) then
    sodium_memzero(FData, FLength);
end;

function TSecureBytes.Data: PByte;
begin
  Result := FData;
end;

function TSecureBytes.Len: NativeUInt;
begin
  Result := FLength;
end;

function TSecureBytes.Equals(AOther: TSecureBytes): Boolean;
var
  i: NativeUInt;
  diff: Byte;
begin
  Result := False;
  if (AOther = nil) or (FLength <> AOther.FLength) then Exit;
  diff := 0;
  if FLength > 0 then
    for i := 0 to FLength - 1 do
      diff := diff or ((FData + i)^ xor (AOther.FData + i)^);
  Result := diff = 0;
end;

end.
