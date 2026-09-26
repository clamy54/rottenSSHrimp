{ Unite PURE (ni LCL, ni reseau, ni disque): la securite du Scp se joue ici.
  Un nom venu du SERVEUR est hostile: jamais concatene, decode ni « repare ».
  CheckRemoteChildName: ce qu'on MANIPULE la-bas (« a\b » y est legal).
  CheckLocalName: ce qu'on CREE ici (« a\b » y fait deux dossiers). Ne pas fusionner.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpPaths;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

const
  // Bornes contre un serveur hostile: des REFUS, pas des troncatures.
  SCP_MAX_NAME_BYTES = 255;
  SCP_MAX_PATH_BYTES = 4096;
  SCP_MAX_DEPTH = 64;
  SCP_MAX_DIR_ENTRIES = 200000;
  SCP_LIST_FIRST_CAPACITY = 256;

type
  TNameVerdict = (
    nvOk,
    nvEmpty,
    nvDot,
    nvDotDot,          // vecteur de remontee
    nvSeparator,
    nvNul,             // tronque tout chemin passe a une API C
    nvControl,         // < 0x20 ou 0x7F: de quoi piloter le terminal
    nvTooLong,
    nvReservedWin,     // CON, NUL, COM1...
    nvTrailingWin,     // point ou espace final: Windows les mange en silence
    nvInvalidCharWin); // < > : " | ? *

function NameVerdictText(AVerdict: TNameVerdict;
  const ADisplayName: string): string;

// Distant: POSIX, '/', casse significative.

function RemoteIsAbsolute(const APath: string): Boolean;
// LEXICALE: aucun lien suivi, '..' ne remonte pas au-dessus de la racine.
function RemoteNormalize(const APath: string): string;
// AName DOIT avoir passe CheckRemoteChildName. Jamais de concatenation nue.
function RemoteJoin(const ABase, AName: string): string;
function RemoteParent(const APath: string): string;
function RemoteBaseName(const APath: string): string;
function RemoteIsUnder(const ARoot, APath: string): Boolean;
function RemoteDepth(const APath: string): Integer;

function CheckRemoteChildName(const AName: string): TNameVerdict;

function LocalIsAbsolute(const APath: string): Boolean;
function LocalNormalize(const APath: string): string;
function LocalJoin(const ABase, AName: string): string;
function LocalParent(const APath: string): string;
function LocalBaseName(const APath: string): string;
function LocalIsUnder(const ARoot, APath: string): Boolean;

// Refus dit a l'utilisateur; on ne renomme jamais d'office.
function CheckLocalName(const AName: string): TNameVerdict;

function LocalCollisionKey(const AName: string): string;

// Windows: \\?\ au-dela de MAX_PATH.
function LocalNativePath(const APath: string): string;

// Controles, ESC, et le bidi qui deguise « gpj.exe » en « exe.jpg ».
function DisplaySafeName(const S: string): string;

// AIndex >= 1
function KeepBothCandidate(const AName: string; AIndex: Integer): string;

function FormatUnixMode(AMode: LongWord): string;
function ModeIsDir(AMode: LongWord): Boolean;
function ModeIsLink(AMode: LongWord): Boolean;
function ModeIsRegular(AMode: LongWord): Boolean;
function ModeIsSpecial(AMode: LongWord): Boolean;

const
  SCP_MODE_BITS = LongWord(&07777);   // ce que chmod pose, sans le type

// Hors de AMask, rien ne bouge: une case cochee sur une selection heterogene.
// ADirX: x la ou r, sur les DOSSIERS seulement (sur un fichier: executable).
function ScpApplyMode(AOld, ABits, AMask: LongWord;
  AIsDir, ADirX: Boolean): LongWord;
// Toujours quatre chiffres.
function ScpModeToOctal(AMode: LongWord): string;
// DOUBLE, borne par SCP_MAX_DIR_ENTRIES: +1 a chaque fois = quadratique.
function ScpListCapacity(ACount: Integer): Integer;
// False plutot qu'un mode arbitraire pour une saisie ratee.
function ScpOctalToMode(const AText: string; out AMode: LongWord): Boolean;

implementation

uses
  LazUTF8;

const
  S_IFMT  = &0170000;
  S_IFDIR = &0040000;
  S_IFREG = &0100000;
  S_IFLNK = &0120000;

  WIN_RESERVED: array[0..21] of string = (
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9');

function NameVerdictText(AVerdict: TNameVerdict;
  const ADisplayName: string): string;
begin
  case AVerdict of
    nvOk: Result := '';
    nvEmpty: Result := 'The server returned an entry with an empty name.';
    nvDot, nvDotDot:
      Result := Format('"%s" is a directory entry, not a file that can be ' +
        'transferred or deleted.', [ADisplayName]);
    nvSeparator:
      Result := Format('"%s" contains a path separator, so it is not a ' +
        'simple file name. Refused rather than split into directories.',
        [ADisplayName]);
    nvNul:
      Result := 'The name contains a NUL byte, which would truncate the path.';
    nvControl:
      Result := Format('"%s" contains control characters. Refused: such ' +
        'names can drive the terminal instead of naming a file.',
        [ADisplayName]);
    nvTooLong:
      Result := Format('The name is longer than %d bytes.',
        [SCP_MAX_NAME_BYTES]);
    nvReservedWin:
      Result := Format('"%s" is a reserved device name on Windows and cannot ' +
        'be a file. Rename it on the server, or skip it.', [ADisplayName]);
    nvTrailingWin:
      Result := Format('"%s" ends with a dot or a space. Windows would drop ' +
        'it silently and write to a different file, so it is refused.',
        [ADisplayName]);
    nvInvalidCharWin:
      Result := Format('"%s" contains a character Windows cannot store in a ' +
        'file name (one of < > : " | ? *).', [ADisplayName]);
  else
    Result := 'Invalid name.';
  end;
end;

// Ni %2F ni desechappement: un nom est une suite d'octets, pas une invitation.
function BasicNameVerdict(const AName: string): TNameVerdict;
var
  i: Integer;
  c: Char;
begin
  if AName = '' then Exit(nvEmpty);
  if Length(AName) > SCP_MAX_NAME_BYTES then Exit(nvTooLong);
  if AName = '.' then Exit(nvDot);
  if AName = '..' then Exit(nvDotDot);
  for i := 1 to Length(AName) do
  begin
    c := AName[i];
    if c = #0 then Exit(nvNul);
    if (c < #32) or (c = #127) then Exit(nvControl);
    if c = '/' then Exit(nvSeparator);
  end;
  Result := nvOk;
end;

function CheckRemoteChildName(const AName: string): TNameVerdict;
begin
  Result := BasicNameVerdict(AName);
end;

function CheckLocalName(const AName: string): TNameVerdict;
var
  i: Integer;
  {$IFDEF WINDOWS}
  c: Char;
  stem: string;
  p: Integer;
  {$ENDIF}
begin
  Result := BasicNameVerdict(AName);
  if Result <> nvOk then Exit;
  {$IFDEF WINDOWS}
  // Windows seulement: sous POSIX « a\b » est un nom legitime.
  for i := 1 to Length(AName) do
    if AName[i] = '\' then Exit(nvSeparator);
  for i := 1 to Length(AName) do
  begin
    c := AName[i];
    if (c = '<') or (c = '>') or (c = ':') or (c = '"') or
       (c = '|') or (c = '?') or (c = '*') then
      Exit(nvInvalidCharWin);
  end;
  c := AName[Length(AName)];
  if (c = '.') or (c = ' ') then Exit(nvTrailingWin);
  // « nul.txt » est AUSSI un peripherique.
  p := Pos('.', AName);
  if p > 0 then stem := Copy(AName, 1, p - 1) else stem := AName;
  for i := 0 to High(WIN_RESERVED) do
    if SameText(stem, WIN_RESERVED[i]) then Exit(nvReservedWin);
  {$ENDIF}
  Result := nvOk;
end;

function LocalCollisionKey(const AName: string): string;
begin
  Result := AName;
  {$IFDEF WINDOWS}
  // Casse ignoree, points et espaces finaux amputes: deux noms, un fichier.
  while (Result <> '') and
        ((Result[Length(Result)] = '.') or (Result[Length(Result)] = ' ')) do
    SetLength(Result, Length(Result) - 1);
  Result := UTF8LowerCase(Result);
  {$ENDIF}
  {$IFDEF DARWIN}
  Result := UTF8LowerCase(Result);
  {$ENDIF}
end;

function RemoteIsAbsolute(const APath: string): Boolean;
begin
  Result := (APath <> '') and (APath[1] = '/');
end;

procedure SplitPosix(const APath: string; out AParts: TStringArray);
var
  i, start, n: Integer;
begin
  SetLength(AParts, 0);
  n := 0;
  start := 1;
  for i := 1 to Length(APath) + 1 do
    if (i > Length(APath)) or (APath[i] = '/') then
    begin
      if i > start then
      begin
        if n >= Length(AParts) then
          SetLength(AParts, n + 16);
        AParts[n] := Copy(APath, start, i - start);
        Inc(n);
      end;
      start := i + 1;
    end;
  SetLength(AParts, n);
end;

function RemoteNormalize(const APath: string): string;
var
  parts, stack: TStringArray;
  i, top: Integer;
  isAbs: Boolean;
begin
  isAbs := RemoteIsAbsolute(APath);
  SplitPosix(APath, parts);
  SetLength(stack, Length(parts));
  top := 0;
  for i := 0 to High(parts) do
  begin
    if parts[i] = '.' then
      Continue;
    if parts[i] = '..' then
    begin
      // Absolu: '..' meurt a la racine. Relatif: il reste.
      if (top > 0) and (stack[top - 1] <> '..') then
        Dec(top)
      else if not isAbs then
      begin
        stack[top] := '..';
        Inc(top);
      end;
      Continue;
    end;
    stack[top] := parts[i];
    Inc(top);
  end;
  Result := '';
  for i := 0 to top - 1 do
  begin
    if Result <> '' then Result := Result + '/';
    Result := Result + stack[i];
  end;
  if isAbs then
    Result := '/' + Result
  else if Result = '' then
    Result := '.';
end;

function RemoteJoin(const ABase, AName: string): string;
begin
  if AName = '' then
    Exit(RemoteNormalize(ABase));
  if RemoteIsAbsolute(AName) then
    // Absolu: il remplace la base. Deja refuse par CheckRemoteChildName.
    Exit(RemoteNormalize(AName));
  if ABase = '' then
    Exit(RemoteNormalize(AName));
  if ABase[Length(ABase)] = '/' then
    Result := RemoteNormalize(ABase + AName)
  else
    Result := RemoteNormalize(ABase + '/' + AName);
end;

function RemoteParent(const APath: string): string;
var
  norm: string;
  i: Integer;
begin
  norm := RemoteNormalize(APath);
  if norm = '/' then Exit('/');
  i := Length(norm);
  while (i > 0) and (norm[i] <> '/') do Dec(i);
  if i <= 0 then Exit('.');
  if i = 1 then Exit('/');
  Result := Copy(norm, 1, i - 1);
end;

function RemoteBaseName(const APath: string): string;
var
  norm: string;
  i: Integer;
begin
  norm := RemoteNormalize(APath);
  if norm = '/' then Exit('/');
  i := Length(norm);
  while (i > 0) and (norm[i] <> '/') do Dec(i);
  Result := Copy(norm, i + 1, Length(norm) - i);
end;

function RemoteIsUnder(const ARoot, APath: string): Boolean;
var
  r, p: string;
begin
  r := RemoteNormalize(ARoot);
  p := RemoteNormalize(APath);
  if r = p then Exit(True);
  if r = '/' then
    Exit((Length(p) > 1) and (p[1] = '/'));
  // Sans le separateur, /home/bob contiendrait /home/bobby.
  Result := (Length(p) > Length(r)) and
    (Copy(p, 1, Length(r)) = r) and (p[Length(r) + 1] = '/');
end;

function RemoteDepth(const APath: string): Integer;
var
  parts: TStringArray;
begin
  SplitPosix(RemoteNormalize(APath), parts);
  Result := Length(parts);
end;

function IsSep(C: Char): Boolean; inline;
begin
  {$IFDEF WINDOWS}
  Result := (C = '\') or (C = '/');
  {$ELSE}
  Result := C = '/';
  {$ENDIF}
end;

// Longueur de la racine, 0 si relatif: 'C:\', '\\srv\part\', '\\?\C:\', '/'.
function LocalRootLen(const APath: string): Integer;
{$IFDEF WINDOWS}
var
  i, seps: Integer;
begin
  Result := 0;
  if Length(APath) >= 4 then
    if (APath[1] = '\') and (APath[2] = '\') and (APath[3] = '?') and
       (APath[4] = '\') then
    begin
      if (Length(APath) >= 9) and SameText(Copy(APath, 5, 4), 'UNC\') then
      begin
        i := 9;
        seps := 0;
        while (i <= Length(APath)) and (seps < 2) do
        begin
          if APath[i] = '\' then Inc(seps);
          if seps < 2 then Inc(i);
        end;
        Exit(i);
      end;
      if (Length(APath) >= 7) and (APath[6] = ':') and (APath[7] = '\') then
        Exit(7);
      Exit(4);
    end;
  if (Length(APath) >= 2) and IsSep(APath[1]) and IsSep(APath[2]) then
  begin
    i := 3;
    seps := 0;
    while (i <= Length(APath)) and (seps < 2) do
    begin
      if IsSep(APath[i]) then Inc(seps);
      if seps < 2 then Inc(i);
    end;
    Exit(i);
  end;
  // Pas 'C:xyz': relatif au cwd DU LECTEUR, un etat global.
  if (Length(APath) >= 3) and (APath[2] = ':') and IsSep(APath[3]) then
    Exit(3);
end;
{$ELSE}
begin
  if (APath <> '') and (APath[1] = '/') then Result := 1 else Result := 0;
end;
{$ENDIF}

function LocalIsAbsolute(const APath: string): Boolean;
begin
  Result := LocalRootLen(APath) > 0;
end;

function LocalNormalize(const APath: string): string;
var
  rootLen, i, start, top: Integer;
  root, rest, part: string;
  stack: TStringArray;
begin
  if APath = '' then Exit('');
  rootLen := LocalRootLen(APath);
  root := Copy(APath, 1, rootLen);
  rest := Copy(APath, rootLen + 1, Length(APath) - rootLen);
  {$IFDEF WINDOWS}
  root := StringReplace(root, '/', '\', [rfReplaceAll]);
  {$ENDIF}
  SetLength(stack, (Length(rest) div 2) + 8);
  top := 0;
  start := 1;
  for i := 1 to Length(rest) + 1 do
    if (i > Length(rest)) or IsSep(rest[i]) then
    begin
      if i > start then
      begin
        part := Copy(rest, start, i - start);
        if part = '.' then
        else if part = '..' then
        begin
          if (top > 0) and (stack[top - 1] <> '..') then
            Dec(top)
          else if rootLen = 0 then
          begin
            if top >= Length(stack) then SetLength(stack, top + 8);
            stack[top] := '..';
            Inc(top);
          end;
        end
        else
        begin
          if top >= Length(stack) then SetLength(stack, top + 8);
          stack[top] := part;
          Inc(top);
        end;
      end;
      start := i + 1;
    end;
  Result := '';
  for i := 0 to top - 1 do
  begin
    if Result <> '' then Result := Result + PathDelim;
    Result := Result + stack[i];
  end;
  if rootLen > 0 then
    Result := root + Result
  else if Result = '' then
    Result := '.';
end;

function LocalJoin(const ABase, AName: string): string;
begin
  if AName = '' then Exit(LocalNormalize(ABase));
  if LocalIsAbsolute(AName) then Exit(LocalNormalize(AName));
  if ABase = '' then Exit(LocalNormalize(AName));
  if IsSep(ABase[Length(ABase)]) then
    Result := LocalNormalize(ABase + AName)
  else
    Result := LocalNormalize(ABase + PathDelim + AName);
end;

function LocalParent(const APath: string): string;
var
  norm: string;
  rootLen, i: Integer;
begin
  norm := LocalNormalize(APath);
  rootLen := LocalRootLen(norm);
  if Length(norm) <= rootLen then Exit(norm);   // deja la racine
  i := Length(norm);
  while (i > rootLen) and (not IsSep(norm[i])) do Dec(i);
  if i <= rootLen then
  begin
    if rootLen > 0 then Exit(Copy(norm, 1, rootLen));
    Exit('.');
  end;
  Result := Copy(norm, 1, i - 1);
end;

function LocalBaseName(const APath: string): string;
var
  norm: string;
  rootLen, i: Integer;
begin
  norm := LocalNormalize(APath);
  rootLen := LocalRootLen(norm);
  if Length(norm) <= rootLen then Exit(norm);
  i := Length(norm);
  while (i > rootLen) and (not IsSep(norm[i])) do Dec(i);
  if (i > rootLen) and IsSep(norm[i]) then
    Result := Copy(norm, i + 1, Length(norm) - i)
  else
    Result := Copy(norm, rootLen + 1, Length(norm) - rootLen);
end;

function LocalIsUnder(const ARoot, APath: string): Boolean;
var
  r, p: string;
begin
  r := LocalNormalize(ARoot);
  p := LocalNormalize(APath);
  {$IFDEF WINDOWS}
  r := UTF8LowerCase(r);
  p := UTF8LowerCase(p);
  {$ENDIF}
  // 'C:\' porte deja son separateur.
  if (Length(r) > 1) and IsSep(r[Length(r)]) then
    SetLength(r, Length(r) - 1);
  if r = p then Exit(True);
  if r = '' then Exit(False);
  // '/' est deja un separateur: en exiger un de PLUS sortirait /tmp/x de /.
  if (Length(r) = 1) and IsSep(r[1]) then
    Exit((Length(p) > 1) and IsSep(p[1]));
  Result := (Length(p) > Length(r)) and
    (Copy(p, 1, Length(r)) = r) and IsSep(p[Length(r) + 1]);
end;

function LocalNativePath(const APath: string): string;
{$IFDEF WINDOWS}
const
  LONG_PATH_THRESHOLD = 240;
var
  norm: string;
begin
  norm := LocalNormalize(APath);
  Result := norm;
  if Length(norm) < LONG_PATH_THRESHOLD then Exit;
  if Copy(norm, 1, 4) = '\\?\' then Exit;
  // \\?\ coupe la normalisation systeme: LocalNormalize l'a deja faite.
  if (Length(norm) >= 2) and (norm[1] = '\') and (norm[2] = '\') then
    Result := '\\?\UNC\' + Copy(norm, 3, Length(norm) - 2)
  else if (Length(norm) >= 3) and (norm[2] = ':') and (norm[3] = '\') then
    Result := '\\?\' + norm;
end;
{$ELSE}
begin
  Result := LocalNormalize(APath);
end;
{$ENDIF}

function DisplaySafeName(const S: string): string;
var
  i, n, chLen: Integer;
  cp: LongWord;
  danger: Boolean;
begin
  Result := '';
  i := 1;
  n := Length(S);
  while i <= n do
  begin
    if (S[i] < #32) or (S[i] = #127) then
    begin
      Result := Result + '?';
      Inc(i);
      Continue;
    end;
    chLen := UTF8CodepointSize(@S[i]);
    if chLen <= 0 then chLen := 1;
    if chLen = 1 then
    begin
      Result := Result + S[i];
      Inc(i);
      Continue;
    end;
    if i + chLen - 1 > n then
    begin
      Result := Result + '?';
      Break;
    end;
    cp := UTF8CodepointToUnicode(@S[i], chLen);
    danger :=
      // marques et surcharges directionnelles
      (cp = $200E) or (cp = $200F) or
      ((cp >= $202A) and (cp <= $202E)) or
      ((cp >= $2066) and (cp <= $2069)) or
      // separateurs de ligne et de paragraphe
      (cp = $2028) or (cp = $2029) or
      // fonctions de commande C1
      ((cp >= $0080) and (cp <= $009F));
    if danger then
      Result := Result + '?'
    else
      Result := Result + Copy(S, i, chLen);
    Inc(i, chLen);
  end;
end;

function KeepBothCandidate(const AName: string; AIndex: Integer): string;
var
  dot: Integer;
  suffix: string;
begin
  if AIndex < 1 then AIndex := 1;
  suffix := Format(' (%d)', [AIndex]);
  // Dernier point, sauf celui qui ouvre un « .bashrc ».
  dot := Length(AName);
  while (dot > 1) and (AName[dot] <> '.') do Dec(dot);
  if (dot > 1) and (AName[dot] = '.') then
    Result := Copy(AName, 1, dot - 1) + suffix +
      Copy(AName, dot, Length(AName) - dot + 1)
  else
    Result := AName + suffix;
end;

function ModeIsDir(AMode: LongWord): Boolean;
begin
  Result := (AMode and S_IFMT) = S_IFDIR;
end;

function ModeIsLink(AMode: LongWord): Boolean;
begin
  Result := (AMode and S_IFMT) = S_IFLNK;
end;

function ModeIsRegular(AMode: LongWord): Boolean;
begin
  Result := (AMode and S_IFMT) = S_IFREG;
end;

function ModeIsSpecial(AMode: LongWord): Boolean;
begin
  // 0 = « non envoye », sinon tout le listing passe pour des peripheriques.
  if (AMode and S_IFMT) = 0 then Exit(False);
  Result := not (ModeIsDir(AMode) or ModeIsLink(AMode) or ModeIsRegular(AMode));
end;

function ScpApplyMode(AOld, ABits, AMask: LongWord;
  AIsDir, ADirX: Boolean): LongWord;
var
  i: Integer;
begin
  AMask := AMask and SCP_MODE_BITS;
  Result := (AOld and SCP_MODE_BITS and (not AMask)) or (ABits and AMask);
  if AIsDir and ADirX then
    for i := 0 to 2 do
      if (Result and (LongWord(4) shl (i * 3))) <> 0 then
        Result := Result or (LongWord(1) shl (i * 3));
end;

function ScpListCapacity(ACount: Integer): Integer;
begin
  if ACount < SCP_LIST_FIRST_CAPACITY then
    Result := SCP_LIST_FIRST_CAPACITY
  else if ACount >= SCP_MAX_DIR_ENTRIES div 2 then
    Result := SCP_MAX_DIR_ENTRIES
  else
    Result := ACount * 2;
end;

function ScpModeToOctal(AMode: LongWord): string;
var
  i: Integer;
begin
  AMode := AMode and SCP_MODE_BITS;
  SetLength(Result, 4);
  for i := 4 downto 1 do
  begin
    Result[i] := Char(Ord('0') + (AMode and 7));
    AMode := AMode shr 3;
  end;
end;

function ScpOctalToMode(const AText: string; out AMode: LongWord): Boolean;
var
  s: string;
  i: Integer;
begin
  AMode := 0;
  s := Trim(AText);
  if (s = '') or (Length(s) > 4) then Exit(False);
  for i := 1 to Length(s) do
  begin
    if (s[i] < '0') or (s[i] > '7') then Exit(False);
    AMode := (AMode shl 3) or LongWord(Ord(s[i]) - Ord('0'));
  end;
  Result := True;
end;

function FormatUnixMode(AMode: LongWord): string;

  function Rwx(ABits: LongWord; ASpecial: Boolean; ASpecialCh: Char): string;
  begin
    Result := '---';
    if (ABits and 4) <> 0 then Result[1] := 'r';
    if (ABits and 2) <> 0 then Result[2] := 'w';
    if (ABits and 1) <> 0 then Result[3] := 'x';
    if ASpecial then
    begin
      if (ABits and 1) <> 0 then
        Result[3] := ASpecialCh
      else
        Result[3] := UpCase(ASpecialCh);
    end;
  end;

begin
  if AMode = 0 then Exit('');
  case AMode and S_IFMT of
    S_IFDIR: Result := 'd';
    S_IFLNK: Result := 'l';
    S_IFREG: Result := '-';
    &0010000: Result := 'p';
    &0020000: Result := 'c';
    &0060000: Result := 'b';
    &0140000: Result := 's';
  else
    Result := '?';
  end;
  Result := Result
    + Rwx((AMode shr 6) and 7, (AMode and &04000) <> 0, 's')
    + Rwx((AMode shr 3) and 7, (AMode and &02000) <> 0, 's')
    + Rwx(AMode and 7, (AMode and &01000) <> 0, 't');
end;

end.
