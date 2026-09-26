{ Windows livre AltGr en Ctrl gauche + Alt droite: un raccourci Ctrl mangerait
  le @ et l'euro de l'azerty. Ailleurs, rien a distinguer.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uKeyCompat;

{$mode objfpc}{$H+}

interface

uses
  Classes, LCLType, LCLIntf;

// True: le caractere arrive par UTF8KeyPress, aucun raccourci n'y touche.
// Un vrai Ctrl+Alt reste un raccourci, l'hote distant en a besoin.
function ShiftIsAltGr(AShift: TShiftState): Boolean;

implementation

function ShiftIsAltGr(AShift: TShiftState): Boolean;
begin
  Result := False;
  if not ((ssCtrl in AShift) and (ssAlt in AShift)) then Exit;
  {$IFDEF WINDOWS}
  // etat au moment du message: AltGr = Alt DROITE
  Result := GetKeyState(VK_RMENU) < 0;
  {$ENDIF}
end;

end.
