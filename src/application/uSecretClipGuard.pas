{ Garde: ne pas exfiltrer vers un serveur distant un secret revele localement.

  Reveler un mot de passe recree le champ en NSTextField ordinaire sous Cocoa
  (SetPasswordChar => RecreateWnd): AppKit y autorise le Copy que le
  NSSecureTextField interdisait. Les sondes de presse-papiers RDP/VNC (700 ms,
  400 ms) l'annoncent alors a tous les serveurs connectes, sans trace visible.

  Tant qu'un champ est revele, les sondes ADOPTENT ce qu'elles lisent au lieu de
  l'annoncer: le contenu copie pendant la revelation ne partira pas, meme apres
  remasquage. Le partage n'est pas desactive, seule la fenetre a risque l'est.
  Une copie faite depuis une autre application n'est pas couverte.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uSecretClipGuard;

{$mode objfpc}{$H+}

interface

{ Appairees et comptees: l'appelant DOIT relacher a la fermeture du dialogue,
  meme si le champ est reste revele. }
procedure SecretRevealBegin;
procedure SecretRevealEnd;

function SecretRevealActive: Boolean;

{ Suspension GLOBALE du partage, pour le verrouillage du document: les sessions
  gardees restent connectees et leurs sondes tournent -- seule la reconnexion
  etait inhibee. Comme pour la revelation, la sonde adopte sans annoncer. }
procedure SetClipboardSharingSuspended(AValue: Boolean);
function ClipboardSharingSuspended: Boolean;

{ Incrementee a chaque OUVERTURE d'une fenetre protegee: une sonde qui memorise
  la generation vue detecte une fenetre entierement comprise entre deux ticks et
  re-adopte sans annoncer. Comparaison par egalite, le debordement est sans effet. }
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
  // Plancher a zero: un relachement en trop desactiverait le garde pour de bon.
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
