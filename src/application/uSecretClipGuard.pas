{ Un mot de passe revele sous Cocoa redevient un NSTextField copiable, et les
  sondes RDP/VNC l'offriraient a tous les serveurs. Pendant la revelation, elles
  ADOPTENT sans annoncer. Copie depuis une autre application: non couverte.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uSecretClipGuard;

{$mode objfpc}{$H+}

interface

{ Comptees: relacher a la fermeture du dialogue, meme champ encore revele. }
procedure SecretRevealBegin;
procedure SecretRevealEnd;

function SecretRevealActive: Boolean;

{ Document verrouille: les sessions gardees tournent encore, leurs sondes aussi.
  Elles adoptent sans annoncer. }
procedure SetClipboardSharingSuspended(AValue: Boolean);
function ClipboardSharingSuspended: Boolean;

{ Rattrape une revelation tenue entre deux ticks de sonde. Comparer par egalite:
  le debordement est alors sans effet. }
function ClipGuardGeneration: LongInt;

implementation

var
  GRevealed: LongInt = 0;
  GClipSuspended: LongInt = 0;
  GGuardGen: LongInt = 0;

procedure SecretRevealBegin;
begin
  InterLockedIncrement(GRevealed);
  InterLockedIncrement(GGuardGen);
end;

procedure SecretRevealEnd;
begin
  // Plancher a zero, sinon un relachement en trop desarme le garde pour de bon.
  if InterLockedDecrement(GRevealed) < 0 then
    InterLockedIncrement(GRevealed);
end;

function SecretRevealActive: Boolean;
begin
  Result := InterLockedExchangeAdd(GRevealed, 0) > 0;
end;

// Drapeau, pas compteur: verrouiller deux fois puis deverrouiller rend le partage.
procedure SetClipboardSharingSuspended(AValue: Boolean);
begin
  InterLockedExchange(GClipSuspended, Ord(AValue));
  if AValue then
    InterLockedIncrement(GGuardGen);
end;

function ClipboardSharingSuspended: Boolean;
begin
  Result := InterLockedExchangeAdd(GClipSuspended, 0) <> 0;
end;

function ClipGuardGeneration: LongInt;
begin
  Result := InterLockedExchangeAdd(GGuardGen, 0);
end;

end.
