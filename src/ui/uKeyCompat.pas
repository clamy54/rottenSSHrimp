{ Compat clavier: distinguer l'AltGr PHYSIQUE d'un vrai Ctrl+Alt. Sous
  Windows, le pilote presente AltGr comme Ctrl gauche + Alt droite: un
  raccourci qui intercepte Ctrl mangerait le caractere compose (@ sur la
  touche 0 d'azerty, l'euro sur E). Ailleurs, AltGr n'arrive jamais en
  Ctrl+Alt: rien a distinguer.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uKeyCompat;

{$mode objfpc}{$H+}

interface

uses
  Classes, LCLType, LCLIntf;

// True: la combinaison vient d'AltGr tenu; le caractere compose arrive par
// UTF8KeyPress et aucun raccourci Ctrl ne doit consommer la touche. Un vrai
// Ctrl+Alt (les deux touches gauches) reste un raccourci: Ctrl+Alt+lettre
// doit continuer d'atteindre l'application distante.
function ShiftIsAltGr(AShift: TShiftState): Boolean;

implementation

function ShiftIsAltGr(AShift: TShiftState): Boolean;
begin
  Result := False;
  if not ((ssCtrl in AShift) and (ssAlt in AShift)) then Exit;
  {$IFDEF WINDOWS}
  // Etat au moment du message: AltGr tenu = Alt DROITE enfoncee. Qui pose
  // Ctrl gauche + Alt gauche veut le raccourci, pas le caractere.
  Result := GetKeyState(VK_RMENU) < 0;
  {$ENDIF}
end;

end.
