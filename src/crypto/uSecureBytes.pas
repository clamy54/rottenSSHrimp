unit uSecureBytes;

{$mode objfpc}{$H+}

// Tampon memoire pour secrets: alloue par sodium_malloc (pages
// gardees, effacees a la liberation), verrouille avec sodium_mlock quand
// l'OS le permet. Ne jamais copier le contenu dans une string ordinaire.

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
    // copie AData puis c'est a l'appelant d'effacer sa source
    constructor CreateFrom(const AData; ALength: NativeUInt);
    destructor Destroy; override;
    procedure Clear;
    function Data: PByte;
    function Len: NativeUInt;
    // comparaison a temps constant
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
    ALength := 1;  // sodium_malloc(0) est valide mais restons simples
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
    // sodium_free efface la region; munlock d'abord si verrouillee
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
