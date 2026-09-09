{ Pont presse-papiers local <-> serveur, commun aux onglets RDP et VNC. Rien ne
  part tant qu'une lecture saine n'a pas fixe la reference; ce qui est copie sous
  garde est adopte sans envoi; ce qui vient du serveur ne lui revient jamais.
  Thread UI seulement, aucun verrou.

  Seul l'onglet au PREMIER PLAN envoie. Chaque onglet surveille le meme
  presse-papiers global: sans cette regle, un texte recu du serveur A etait pris
  pour une copie locale par l'onglet B et lui partait en arriere-plan -- fuite
  entre deux environnements que rien ne relie. Un onglet en arriere-plan ne
  touche pas a sa reference: ce qui a ete copie pendant qu'il etait cache part
  quand l'utilisateur le remet devant, comme le ferait un client RDP classique.

  Et ce qui vient d'UN serveur ne part vers AUCUN autre: la signature du dernier
  texte recu est memorisee au niveau de l'unite, tous ponts confondus. Un onglet
  qui la retrouve dans le presse-papiers l'adopte sans envoyer, meme au premier
  plan. Prix assume: copier dans la session A puis coller dans la session B ne
  passe plus par le partage automatique. }

{ Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uClipboardBridge;

{$mode objfpc}{$H+}

interface

type
  { False = echec FRANC (presse-papiers verrouille): le pont reste non amorce
    et rien ne part. Un presse-papiers vide, lui, est une reference valide. }
  TClipReadFunc = function(out AText: string): Boolean of object;

  TClipSendProc = procedure(const AText: string) of object;

  { True = cet onglet est celui que l'utilisateur regarde: le seul a envoyer. }
  TClipForegroundFunc = function: Boolean of object;

  { Pose AText dans le presse-papiers systeme. False = l'ecriture a echoue
    (presse-papiers verrouille par un autre programme): l'ancien contenu y est
    toujours. }
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

    { Texte recu du serveur: memorise sa provenance PUIS l'ecrit via AWrite. La
      provenance est posee avant l'ecriture (sinon un sondage glisse entre les
      deux et le renvoie: boucle d'echo) et RETIREE si l'ecriture echoue. Sans
      ce retour en arriere, le presse-papiers garde le texte du serveur A, la
      signature globale annonce B, et le prochain sondage de l'onglet B prend
      le texte de A pour une copie locale et le lui envoie. }
    function NoteRemote(const AText: string; AWrite: TClipWriteFunc): Boolean;
  end;

// FNV-1a borne, longueur totale comprise: un ajout en fin de texte reste vu.
function ClipSignature(const S: string; ABound: Integer): string;

implementation

uses
  SysUtils, uSecretClipGuard;

var
  // Signature (non bornee) du dernier texte recu d'un serveur, quel qu'il
  // soit. Thread UI seulement, comme les ponts.
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
  // Arriere-plan: ni envoi ni adoption. La garde ci-dessus passe AVANT, un
  // secret revele pendant que l'onglet etait cache reste adopte, jamais envoye.
  if Assigned(FForeground) and (not FForeground()) then
    Exit;
  if cur = '' then
    Exit;
  sig := Signature(cur);
  if sig = FSig then
    Exit;
  FSig := sig;
  // Recu d'un autre serveur: adopte, jamais retransmis.
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
