unit uRsUtil;

{$mode objfpc}{$H+}

// Petits utilitaires sans dependance: temps UTC ms, UUID canonique, hex.

interface

uses
  SysUtils;

// millisecondes UTC depuis l'epoque Unix
function NowUtcMs: Int64;

// UUID v4 aleatoire, forme canonique minuscule sans accolades
function NewUuid: string;
function IsCanonicalUuid(const S: string): Boolean;

function BytesToHex(const B: TBytes): string;
function HexToBytes(const S: string; out B: TBytes): Boolean;

implementation

uses
  DateUtils, uSodiumApi;

function NowUtcMs: Int64;
begin
  Result := MilliSecondsBetween(LocalTimeToUniversal(Now), UnixEpoch);
end;

function NewUuid: string;
var
  b: array[0..15] of Byte;
  i, k: Integer;
const
  HexD: array[0..15] of Char = '0123456789abcdef';
begin
  SodiumEnsureLoaded;
  randombytes_buf(@b[0], 16);
  b[6] := (b[6] and $0F) or $40;  // version 4
  b[8] := (b[8] and $3F) or $80;  // variante RFC 4122
  SetLength(Result, 36);
  i := 1;
  for k := 0 to 15 do
  begin
    if (k = 4) or (k = 6) or (k = 8) or (k = 10) then
    begin
      Result[i] := '-';
      Inc(i);
    end;
    Result[i] := HexD[b[k] shr 4];
    Result[i + 1] := HexD[b[k] and $0F];
    Inc(i, 2);
  end;
end;

function IsCanonicalUuid(const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Length(S) <> 36 then Exit;
  for i := 1 to 36 do
    if (i = 9) or (i = 14) or (i = 19) or (i = 24) then
    begin
      if S[i] <> '-' then Exit;
    end
    else if not (S[i] in ['0'..'9', 'a'..'f']) then
      Exit;
  Result := True;
end;

function BytesToHex(const B: TBytes): string;
const
  HexD: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, Length(B) * 2);
  for i := 0 to High(B) do
  begin
    Result[i * 2 + 1] := HexD[B[i] shr 4];
    Result[i * 2 + 2] := HexD[B[i] and $0F];
  end;
end;

function HexToBytes(const S: string; out B: TBytes): Boolean;

  function Nib(C: Char; out V: Byte): Boolean;
  begin
    Result := True;
    case C of
      '0'..'9': V := Ord(C) - Ord('0');
      'a'..'f': V := Ord(C) - Ord('a') + 10;
      'A'..'F': V := Ord(C) - Ord('A') + 10;
    else
      begin
        V := 0;
        Result := False;
      end;
    end;
  end;

var
  i: Integer;
  hi, lo: Byte;
begin
  B := nil;
  Result := False;
  if Odd(Length(S)) then Exit;
  SetLength(B, Length(S) div 2);
  for i := 0 to High(B) do
  begin
    if not Nib(S[i * 2 + 1], hi) then Exit;
    if not Nib(S[i * 2 + 2], lo) then Exit;
    B[i] := (hi shl 4) or lo;
  end;
  Result := True;
end;

end.
