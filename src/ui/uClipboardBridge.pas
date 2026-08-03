{ Pont presse-papiers local <-> serveur, commun aux onglets RDP et VNC. Rien ne
  part tant qu'une lecture saine n'a pas fixe la reference; ce qui est copie sous
  garde est adopte sans envoi; ce qui vient du serveur ne lui revient jamais.
  Thread UI seulement, aucun verrou.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipboardBridge;

{$mode objfpc}{$H+}

interface

type
  { False = echec FRANC (presse-papiers verrouille): le pont reste non amorce
    et rien ne part. Un presse-papiers vide, lui, est une reference valide. }
  TClipReadFunc = function(out AText: string): Boolean of object;

  TClipSendProc = procedure(const AText: string) of object;

  TClipboardBridge = class
  private
    FSig: string;
    FPrimed: Boolean;
    FGuardSeen: Boolean;
    FGuardGen: LongInt;
    FSigBound: Integer;
    FRead: TClipReadFunc;
    FSend: TClipSendProc;
    function Signature(const S: string): string;
  public
    constructor Create(ARead: TClipReadFunc; ASend: TClipSendProc;
      ASigBound: Integer);

    procedure PrimeBaseline;

    procedure Poll;

    procedure NoteRemote(const AText: string);
  end;

// FNV-1a borne, longueur totale comprise: un ajout en fin de texte reste vu.
function ClipSignature(const S: string; ABound: Integer): string;

implementation

uses
  SysUtils, uSecretClipGuard;

function ClipSignature(const S: string; ABound: Integer): string;
var
  i, n: Integer;
  h: QWord;
begin
  h := QWord($cbf29ce484222325);
  n := Length(S);
  if (ABound > 0) and (n > ABound) then
    n := ABound;
  for i := 1 to n do
    h := (h xor QWord(Byte(S[i]))) * QWord($100000001b3);
  Result := IntToHex(Int64(Length(S)), 16) + IntToHex(Int64(h), 16);
end;

constructor TClipboardBridge.Create(ARead: TClipReadFunc; ASend: TClipSendProc;
  ASigBound: Integer);
begin
  inherited Create;
  FRead := ARead;
  FSend := ASend;
  FSigBound := ASigBound;
  FPrimed := False;
  FGuardSeen := False;
  FGuardGen := ClipGuardGeneration;
end;

function TClipboardBridge.Signature(const S: string): string;
begin
  Result := ClipSignature(S, FSigBound);
end;

procedure TClipboardBridge.PrimeBaseline;
var
  cur: string;
begin
  if FRead(cur) then
  begin
    FSig := Signature(cur);
    FPrimed := True;
    FGuardSeen := False;
    FGuardGen := ClipGuardGeneration;
  end
  else
    FPrimed := False;
end;

procedure TClipboardBridge.Poll;
var
  cur, sig: string;
  gen: LongInt;
  guarded: Boolean;
begin
  if not FRead(cur) then
    Exit;
  if not FPrimed then
  begin
    FSig := Signature(cur);
    FPrimed := True;
    Exit;
  end;
  // Trois declencheurs: garde active, garde vue au dernier sondage, ou garde
  // ouverte ET refermee entre deux ticks.
  gen := ClipGuardGeneration;
  guarded := SecretRevealActive or ClipboardSharingSuspended;
  if guarded or FGuardSeen or (gen <> FGuardGen) then
  begin
    FSig := Signature(cur);
    FGuardSeen := guarded;
    FGuardGen := gen;
    Exit;
  end;
  if cur = '' then
    Exit;
  sig := Signature(cur);
  if sig = FSig then
    Exit;
  FSig := sig;
  FSend(cur);
end;

procedure TClipboardBridge.NoteRemote(const AText: string);
begin
  FSig := Signature(AText);
  FPrimed := True;
end;

end.
