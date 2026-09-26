{ Avant GetJSON: fpjson recurse, dix mille '[' font sauter la pile et aucun
  try/except ne rattrape une violation d'acces. Un theme piege, lu au
  demarrage, et l'application ne redemarre plus jamais.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uJsonGuard;

{$mode objfpc}{$H+}

interface

const
  // loin au-dessus du legitime, loin en dessous du crash
  JSON_MAX_DEPTH_DEFAULT = 64;

// True = ne pas parser.
function JsonNestingTooDeep(const AText: string;
  AMax: Integer = JSON_MAX_DEPTH_DEFAULT): Boolean;

implementation

function JsonNestingTooDeep(const AText: string; AMax: Integer): Boolean;
var
  i, depth: Integer;
  inStr, esc: Boolean;
  c: Char;
begin
  Result := False;
  depth := 0;
  inStr := False;
  esc := False;
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if inStr then
    begin
      if esc then esc := False
      else if c = '\' then esc := True
      else if c = '"' then inStr := False;
      Continue;
    end;
    case c of
      '"': inStr := True;
      '[', '{':
        begin
          Inc(depth);
          if depth > AMax then Exit(True);
        end;
      ']', '}': if depth > 0 then Dec(depth);
    end;
  end;
end;

end.
