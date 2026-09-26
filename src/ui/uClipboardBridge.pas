{ Presse-papiers RDP/VNC. Thread UI seulement, aucun verrou.
  Invariants: rien ne part avant une reference saine; copie sous garde = adoptee
  sans envoi; seul l'onglet au PREMIER PLAN envoie; ce qui vient d'UN serveur ne
  part vers AUCUN autre (copier dans A pour coller dans B: a la main). }

{ Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipboardBridge;

{$mode objfpc}{$H+}

interface

type
  { False = presse-papiers verrouille, rien ne part. Vide = reference valide. }
  TClipReadFunc = function(out AText: string): Boolean of object;

  TClipSendProc = procedure(const AText: string) of object;

  TClipForegroundFunc = function: Boolean of object;

  { False: l'ancien contenu y est toujours. }
  TClipWriteFunc = function(const AText: string): Boolean of object;

  TClipboardBridge = class
  private
    FSig: string;
    FPrimed: Boolean;
    FGuardSeen: Boolean;
    FGuardGen: LongInt;
    FSigBound: Integer;
    FRead: TClipReadFunc;
    FSend: TClipSendProc;
    FForeground: TClipForegroundFunc;
    function Signature(const S: string): string;
  public
    constructor Create(ARead: TClipReadFunc; ASend: TClipSendProc;
      ASigBound: Integer; AForeground: TClipForegroundFunc = nil);

    procedure PrimeBaseline;

    procedure Poll;

    { Provenance posee AVANT l'ecriture (sinon echo) et RETIREE si elle echoue,
      sinon le texte de A, etiquete B, part chez B. }
    function NoteRemote(const AText: string; AWrite: TClipWriteFunc): Boolean;
  end;

// FNV-1a borne, longueur totale comprise: un ajout en fin de texte reste vu.
function ClipSignature(const S: string; ABound: Integer): string;

implementation

uses
  SysUtils, uSecretClipGuard;

var
  // dernier texte recu, tous serveurs confondus; non bornee
  GRemoteSig: string = '';

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
  ASigBound: Integer; AForeground: TClipForegroundFunc);
begin
  inherited Create;
  FRead := ARead;
  FSend := ASend;
  FForeground := AForeground;
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
  // gen: une garde ouverte ET refermee entre deux ticks compte aussi
  gen := ClipGuardGeneration;
  guarded := SecretRevealActive or ClipboardSharingSuspended;
  if guarded or FGuardSeen or (gen <> FGuardGen) then
  begin
    FSig := Signature(cur);
    FGuardSeen := guarded;
    FGuardGen := gen;
    Exit;
  end;
  // Arriere-plan: ni envoi ni adoption. Garde AVANT: un secret vu cache
  // reste adopte, jamais envoye.
  if Assigned(FForeground) and (not FForeground()) then
    Exit;
  if cur = '' then
    Exit;
  sig := Signature(cur);
  if sig = FSig then
    Exit;
  FSig := sig;
  // recu d'un serveur: adopte, jamais retransmis
  if (GRemoteSig <> '') and (ClipSignature(cur, 0) = GRemoteSig) then
    Exit;
  FSend(cur);
end;

function TClipboardBridge.NoteRemote(const AText: string;
  AWrite: TClipWriteFunc): Boolean;
var
  prevSig, prevRemote: string;
  prevPrimed: Boolean;
begin
  prevSig := FSig;
  prevPrimed := FPrimed;
  prevRemote := GRemoteSig;
  FSig := Signature(AText);
  FPrimed := True;
  GRemoteSig := ClipSignature(AText, 0);
  Result := False;
  try
    Result := AWrite(AText);
  except
    Result := False;
  end;
  if not Result then
  begin
    FSig := prevSig;
    FPrimed := prevPrimed;
    GRemoteSig := prevRemote;
  end;
end;

end.
