{ Moteur de transfert, ecrit contre uScpBackend: testable sans reseau.
  Une cible valide n'est JAMAIS remplacee par un transfert incomplet: temporaire
  a cote, vide, ferme, puis remplacement atomique.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpEngine;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, uSodiumApi, uScpBackend, uScpErrors,
  uScpPaths, uTransferQueue;

const
  // Tampon FIXE, jamais dimensionne d'apres le reseau.
  SCP_COPY_BUFFER = 64 * 1024;
  // Marge au-dela de la taille annoncee (un journal grossit), pas un blanc-seing
  // pour remplir le disque.
  SCP_GROWTH_SLACK = Int64(64) * 1024 * 1024;
  SCP_PROGRESS_MS = 100;
  // Vidage qui confirme l'offset de reprise. Trop petit: debit a genoux. Trop
  // grand: une coupure resservira tout l'intervalle.
  SCP_CONFIRM_EVERY = Int64(4) * 1024 * 1024;
  // Tous lots confondus, contre l'arbre tres large. Au-dela, la selection saute
  // entiere, pas a moitie.
  SCP_MAX_QUEUE_ITEMS = 500000;

type
  // BLAKE2b et non un CRC: doit tenir face a une substitution VOULUE.
  TScpDigest = array[0..31] of Byte;

  // Etat libsodium opaque, aligne sur 64. Peek travaille sur une COPIE.
  TScpHash = class
  private
    FMem: Pointer;
    FState: Pointer;
    FSize: SizeUInt;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Reset;
    procedure Update(const ABuf; ALen: SizeUInt);
    procedure Peek(out ADigest: TScpDigest);
  end;

  // Sur le thread de travail. Peut bloquer, mais doit ceder a l'annulation.
  TScpConflictEvent = procedure(const AInfo: TConflictInfo;
    var ADecision: TConflictDecision) of object;
  // AAllow=False par defaut: pas de reponse, pas de garantie degradee.
  TScpNonAtomicEvent = procedure(const ATargetPath: string;
    var AAllow: Boolean) of object;
  TScpProgressEvent = procedure(AItem: TTransferItem) of object;
  TScpNoteEvent = procedure(const AText: string) of object;

  // Une erreur a mi-dossier ne doit pas faire passer le DEJA change pour intact.
  TScpChmodTally = record
    Applied: Integer;
    Unchanged: Integer;    // deja au bon mode: rien envoye
    Links: Integer;
  end;

  // CETTE session seulement: un partiel d'origine inconnue donnerait un fichier mixte.
  TScpPartial = record
    TempPath: string;
    TargetPath: string;
    // Partiel de srv-a complete par srv-b: valide en apparence, pourri dedans.
    SourceIdentity: string;
    // Seule a le nettoyer: un chemin POSIX local existe peut-etre aussi en face.
    DestIdentity: string;
    SourcePath: string;
    SourceSize: Int64;
    SourceTimeUtc: Int64;
    // Vide sur le support si possible, acquitte sinon.
    Confirmed: Int64;
    // Des Confirmed premiers octets ECRITS: meme taille, autre contenu = refuse.
    Digest: TScpDigest;
    Active: Boolean;
  end;

  // Lu par l'interface pendant que le fil de transfert ecrit: verrou partout.
  TScpPartialRegistry = class
  private
    FItems: array of TScpPartial;
    FLock: TCriticalSection;
    function IndexOfTemp(const ATempPath: string): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Note(const ATempPath, ATargetPath, ASourceIdentity,
      ADestIdentity, ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64);
    procedure Confirm(const ATempPath: string; AOffset: Int64;
      const ADigest: TScpDigest);
    procedure Forget(const ATempPath: string);
    // Publie mais temp non retire: a nettoyer, JAMAIS a reprendre (c'est un
    // second nom du fichier publie).
    procedure Retire(const ATempPath: string);
    function Lookup(const ATempPath: string; out APartial: TScpPartial): Boolean;
    // Refuse au moindre ecart; a egalite, celui qui a confirme le plus.
    function FindResumable(const ATargetPath, ASourceIdentity, ADestIdentity,
      ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64;
      out APartial: TScpPartial): Boolean;
    function ActiveForTarget(const ATargetPath,
      ADestIdentity: string): TStringArray;
    function ActiveCount: Integer;
    function ActiveAt(AIndex: Integer): TScpPartial;
    procedure Clear;
  end;

  // Ce qui a ete VU choisit la publication: on ne remplace pas un fichier apparu depuis.
  TScpConflictOutcome = record
    ResumeFrom: Int64;
    ResumeTemp: string;
    // 0 est un mode legitime. Droits illisibles: pas de remplacement.
    PrevMode: LongWord;
    TargetExisted: Boolean;
    // Le rename remplace le lien lui-meme, qui n'a aucun droit a garder.
    TargetIsLink: Boolean;
  end;

  TScpTransferEngine = class
  private
    FQueue: TTransferQueue;
    FPartials: TScpPartialRegistry;
    FOnConflict: TScpConflictEvent;
    FOnNonAtomic: TScpNonAtomicEvent;
    FOnProgress: TScpProgressEvent;
    FOnNote: TScpNoteEvent;
    FBuffer: array of Byte;
    FHash: TScpHash;
    FLastProgressTick: QWord;
    FConfirmEvery: Int64;
    FFatal: TScpError;
    FHasFatal: Boolean;
    // Une duplication locale n'a que le disque, que « Cancel selected » ne touche
    // pas: l'annulation se lit donc ici.
    FWalkRoot: TTransferItem;
    FMaxQueueItems: Integer;
    FQueueFull: Boolean;

    procedure Note(const AText: string);
    procedure NoteFatal(const AErr: TScpError);
    procedure DropPartialsFor(ADstFs: TScpFileSystem;
      const ATargetPath: string);
    // Oublie SEULEMENT une fois retire du disque.
    procedure DiscardPartial(ADstFs: TScpFileSystem; const ATempPath: string);
    procedure PublishedTemp(AItem: TTransferItem; const ATempPath: string;
      var AErr: TScpError);
    function NameUsable(ASrcFs, ADstFs: TScpFileSystem; const AName: string;
      out AWhy: string): Boolean;
    // AOwner: le tikMakeDir du dossier. AKnown: deja en file (parcours repris).
    function WalkDir(ASrcFs, ADstFs: TScpFileSystem;
      ADirection: TTransferDirection; const ASrcDir, ADstDir,
      ATargetRoot: string; ADepth, AMaxDepth: Integer; AOwner: TTransferItem;
      AKnown: TStrings; out AErr: TScpError): Boolean;
    procedure MarkScanCut(AOwner: TTransferItem; const AErr: TScpError);
    // La file pleine, elle, se juge a l'ajout.
    function WalkMustStop(ASrcFs, ADstFs: TScpFileSystem;
      AOwner: TTransferItem; const ADir: string;
      out AErr: TScpError): Boolean;
    function WalkRootStopped(ASrcFs, ADstFs: TScpFileSystem): Boolean;
    // Arrete l'element avec tout ce qu'il a deja mis en file.
    function StopScan(AItem: TTransferItem; const AErr: TScpError): Boolean;
    function RescanDir(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      out AErr: TScpError): Boolean;
    function ScanRoot(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      AMaxDepth: Integer; out AErr: TScpError): Boolean;
    // Coupure rangee en « echec » = reprise interdite. D'ou tsInterrupted.
    procedure FailItem(AItem: TTransferItem; const AErr: TScpError);
    procedure ReportProgress(AItem: TTransferItem; AForce: Boolean);
    // AHash court sur les octets ECRITS: fraiche, ou nourrie du prefixe a la reprise.
    function CopyStream(ASrcFs: TScpFileSystem; ASrcH: TScpFileHandle;
      ADstFs: TScpFileSystem; ADstH: TScpFileHandle;
      AItem: TTransferItem; AExpected: Int64; AStartOffset: Int64;
      const ATempPath: string; AHash: TScpHash;
      out AErr: TScpError): Boolean;
    function ResolveConflict(ASrcFs, ADstFs: TScpFileSystem;
      AItem: TTransferItem; const ASrcEntry: TScpEntry;
      var ATargetPath: string; out AOutcome: TScpConflictOutcome;
      out AErr: TScpError): Boolean;
    // Tout le sous-arbre echoue d'un coup, plutot qu'un par un pour de fausses raisons.
    procedure FailSubtree(ADstFs: TScpFileSystem; AItem: TTransferItem);
    // Le non-atomique se DEMANDE, jamais ne se contourne. Annulation relue apres.
    function CommitTemp(ADstFs: TScpFileSystem; AItem: TTransferItem;
      const ATempPath, ATargetPath: string; ATargetExisted: Boolean;
      out AErr: TScpError): Boolean;
    // False sans AErr: bon a jeter (AWhy). False avec AErr: on ne sait pas, on
    // GARDE; une coupure n'est pas une disparition.
    function PartialUsable(ADstFs: TScpFileSystem; const ATempPath: string;
      AConfirmed, ASourceSize: Int64; out AWhy: string;
      out AErr: TScpError): Boolean;
    // Relecture A TRAVERS la poignee rouverte. Meme semantique False/AErr.
    function VerifyPartialPrefix(ADstFs: TScpFileSystem;
      ADstH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; AHash: TScpHash;
      out AWhy: string; out AErr: TScpError): Boolean;
    function VerifySourcePrefix(ASrcFs: TScpFileSystem;
      ASrcH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; out AWhy: string;
      out AErr: TScpError): Boolean;
  public
    constructor Create(AQueue: TTransferQueue);
    destructor Destroy; override;

    // Dossiers AVANT leur contenu. False = coupure; un refus donne un element
    // ignore. ATargetName renomme la RACINE seule (duplication sur place).
    function EnumerateInto(ASrcFs, ADstFs: TScpFileSystem;
      ADirection: TTransferDirection;
      const ASourcePath, ATargetParent, ATargetRoot: string;
      AMaxDepth: Integer; out AErr: TScpError;
      const ATargetName: string = ''): Boolean;

    // False: echec ou interruption, l'etat de l'element dit lequel.
    function RunItem(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      const ATargetRoot: string): Boolean;

    // Rend les temporaires qu'il a fallu laisser.
    function CleanupPartials(ADstFs: TScpFileSystem): TStringArray;

    // Un element « termine » a pu voir la connexion tomber juste apres publication.
    function TakeFatal(out AErr: TScpError): Boolean;

    property Partials: TScpPartialRegistry read FPartials;
    property ConfirmEvery: Int64 read FConfirmEvery write FConfirmEvery;
    property MaxQueueItems: Integer read FMaxQueueItems write FMaxQueueItems;
    // Tout ou rien. Pas de TOCTOU: seul le fil de transfert ajoute, l'UI retire.
    function CanEnqueue(ACount: Integer): Boolean;
    property OnConflict: TScpConflictEvent read FOnConflict write FOnConflict;
    property OnNonAtomic: TScpNonAtomicEvent
      read FOnNonAtomic write FOnNonAtomic;
    property OnProgress: TScpProgressEvent read FOnProgress write FOnProgress;
    property OnNote: TScpNoteEvent read FOnNote write FOnNote;
  end;

function FreeCopyName(AFs: TScpFileSystem; const ADir, AName: string;
  out AErr: TScpError): string;

// Liens ignores: SETSTAT les traverse. Relecture juste avant chaque chmod: la
// fenetre ou un nom devient lien RETRECIT, sans lchmod elle ne se ferme pas.
function ScpChmodTree(AFs: TScpFileSystem; const APath: string;
  ABits, AMask: LongWord; ARecursive, ADirX: Boolean; ADepth: Integer;
  var ATally: TScpChmodTally; out AErr: TScpError): Boolean;
function ScpDigestMatch(const A, B: TScpDigest): Boolean;
function ScpDigestOfString(const S: string): TScpDigest;

implementation

{ TScpHash }

constructor TScpHash.Create;
begin
  inherited Create;
  SodiumEnsureLoaded;
  FSize := crypto_generichash_statebytes();
  GetMem(FMem, FSize + 64);
  FState := Pointer((PtrUInt(FMem) + 63) and (not PtrUInt(63)));
  Reset;
end;

destructor TScpHash.Destroy;
begin
  FreeMem(FMem);
  inherited Destroy;
end;

procedure TScpHash.Reset;
begin
  crypto_generichash_init(FState, nil, 0, SizeOf(TScpDigest));
end;

procedure TScpHash.Update(const ABuf; ALen: SizeUInt);
begin
  if ALen > 0 then
    crypto_generichash_update(FState, @ABuf, ALen);
end;

procedure TScpHash.Peek(out ADigest: TScpDigest);
var
  mem, copy: Pointer;
begin
  GetMem(mem, FSize + 64);
  try
    copy := Pointer((PtrUInt(mem) + 63) and (not PtrUInt(63)));
    Move(FState^, copy^, FSize);
    crypto_generichash_final(copy, @ADigest[0], SizeOf(ADigest));
  finally
    FreeMem(mem);
  end;
end;

function ScpDigestMatch(const A, B: TScpDigest): Boolean;
begin
  Result := CompareMem(@A[0], @B[0], SizeOf(TScpDigest));
end;

function ScpDigestOfString(const S: string): TScpDigest;
begin
  SodiumEnsureLoaded;
  FillChar(Result, SizeOf(Result), 0);
  if S = '' then
    crypto_generichash(@Result[0], SizeOf(Result), nil, 0, nil, 0)
  else
    crypto_generichash(@Result[0], SizeOf(Result), @S[1], Length(S), nil, 0);
end;

{ TScpPartialRegistry }

constructor TScpPartialRegistry.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TScpPartialRegistry.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TScpPartialRegistry.IndexOfTemp(const ATempPath: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    if FItems[i].TempPath = ATempPath then
      Exit(i);
  Result := -1;
end;

procedure TScpPartialRegistry.Note(const ATempPath, ATargetPath,
  ASourceIdentity, ADestIdentity, ASourcePath: string;
  ASourceSize, ASourceTimeUtc: Int64);
var
  i: Integer;
begin
  FLock.Acquire;
  try
    i := IndexOfTemp(ATempPath);
    if i < 0 then
    begin
      SetLength(FItems, Length(FItems) + 1);
      i := High(FItems);
    end;
    FItems[i].TempPath := ATempPath;
    FItems[i].TargetPath := ATargetPath;
    FItems[i].SourceIdentity := ASourceIdentity;
    FItems[i].DestIdentity := ADestIdentity;
    FItems[i].SourcePath := ASourcePath;
    FItems[i].SourceSize := ASourceSize;
    FItems[i].SourceTimeUtc := ASourceTimeUtc;
    FItems[i].Confirmed := 0;
    FillChar(FItems[i].Digest, SizeOf(FItems[i].Digest), 0);
    FItems[i].Active := True;
  finally
    FLock.Release;
  end;
end;

procedure TScpPartialRegistry.Confirm(const ATempPath: string;
  AOffset: Int64; const ADigest: TScpDigest);
var
  i: Integer;
begin
  FLock.Acquire;
  try
    i := IndexOfTemp(ATempPath);
    // Seul le plus grand offset confirme compte.
    if (i >= 0) and (AOffset > FItems[i].Confirmed) then
    begin
      FItems[i].Confirmed := AOffset;
      FItems[i].Digest := ADigest;
    end;
  finally
    FLock.Release;
  end;
end;

function TScpPartialRegistry.Lookup(const ATempPath: string;
  out APartial: TScpPartial): Boolean;
var
  i: Integer;
begin
  APartial := Default(TScpPartial);
  FLock.Acquire;
  try
    i := IndexOfTemp(ATempPath);
    Result := i >= 0;
    if Result then APartial := FItems[i];
  finally
    FLock.Release;
  end;
end;

procedure TScpPartialRegistry.Forget(const ATempPath: string);
var
  i: Integer;
begin
  FLock.Acquire;
  try
    i := IndexOfTemp(ATempPath);
    if i >= 0 then
      FItems[i].Active := False;
  finally
    FLock.Release;
  end;
end;

procedure TScpPartialRegistry.Retire(const ATempPath: string);
var
  i: Integer;
begin
  FLock.Acquire;
  try
    i := IndexOfTemp(ATempPath);
    if i >= 0 then
    begin
      FItems[i].Confirmed := 0;
      FillChar(FItems[i].Digest, SizeOf(FItems[i].Digest), 0);
    end;
  finally
    FLock.Release;
  end;
end;

function TScpPartialRegistry.FindResumable(const ATargetPath,
  ASourceIdentity, ADestIdentity, ASourcePath: string;
  ASourceSize, ASourceTimeUtc: Int64; out APartial: TScpPartial): Boolean;
var
  i: Integer;
begin
  Result := False;
  APartial := Default(TScpPartial);
  // Taille ou date inconnue: concordance indemontrable, refus.
  if (ASourceSize < 0) or (ASourceTimeUtc = 0) then Exit;
  FLock.Acquire;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Active and
         (FItems[i].TargetPath = ATargetPath) and
         (FItems[i].SourceIdentity = ASourceIdentity) and
         (FItems[i].DestIdentity = ADestIdentity) and
         (FItems[i].SourcePath = ASourcePath) and
         (FItems[i].SourceSize = ASourceSize) and
         (FItems[i].SourceTimeUtc = ASourceTimeUtc) and
         (FItems[i].Confirmed > 0) and
         // Confirme jusqu'au bout compris: il ne reste qu'a publier.
         (FItems[i].Confirmed <= ASourceSize) and
         ((not Result) or (FItems[i].Confirmed > APartial.Confirmed)) then
      begin
        APartial := FItems[i];
        Result := True;
      end;
  finally
    FLock.Release;
  end;
end;

function TScpPartialRegistry.ActiveForTarget(const ATargetPath,
  ADestIdentity: string): TStringArray;
var
  i, n: Integer;
begin
  Result := nil;
  n := 0;
  FLock.Acquire;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Active and (FItems[i].TargetPath = ATargetPath) and
         (FItems[i].DestIdentity = ADestIdentity) then
      begin
        SetLength(Result, n + 1);
        Result[n] := FItems[i].TempPath;
        Inc(n);
      end;
  finally
    FLock.Release;
  end;
end;

function TScpPartialRegistry.ActiveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Active then Inc(Result);
  finally
    FLock.Release;
  end;
end;

function TScpPartialRegistry.ActiveAt(AIndex: Integer): TScpPartial;
var
  i, n: Integer;
begin
  Result := Default(TScpPartial);
  n := 0;
  FLock.Acquire;
  try
    for i := 0 to High(FItems) do
      if FItems[i].Active then
      begin
        if n = AIndex then Exit(FItems[i]);
        Inc(n);
      end;
  finally
    FLock.Release;
  end;
end;

procedure TScpPartialRegistry.Clear;
begin
  FLock.Acquire;
  try
    FItems := nil;
  finally
    FLock.Release;
  end;
end;

// Ni o+w, ni bits speciaux, ni EXECUTION: un script telecharge ne devient pas
// executable en douce. Mode connu et nul: reste nul.
function ModeForNewFile(ASourceMode: LongWord; AModeKnown: Boolean): LongWord;
begin
  if not AModeKnown then Exit(SCP_DEFAULT_FILE_MODE and LongWord(&0664));
  Result := ASourceMode and LongWord(&0664);
end;

// Garde ses rwx, o+w compris (son choix). Jamais setuid/setgid/sticky: un contenu
// nouveau sous un bit eleve, c'est un autre programme qui herite du privilege.
function ModeForReplacedFile(APrevMode: LongWord): LongWord;
begin
  Result := APrevMode and LongWord(&0777);
end;

// u+rwx toujours: il faut bien y ecrire la suite. Mode connu et nul: 0700,
// jamais le defaut ouvert.
function ModeForNewDir(ASourceMode: LongWord; AModeKnown: Boolean): LongWord;
begin
  if not AModeKnown then Exit(SCP_DEFAULT_DIR_MODE);
  Result := (ASourceMode and LongWord(&0775)) or LongWord(&0700);
end;

{ TScpTransferEngine }

constructor TScpTransferEngine.Create(AQueue: TTransferQueue);
begin
  FMaxQueueItems := SCP_MAX_QUEUE_ITEMS;
  FHash := TScpHash.Create;
  inherited Create;
  FQueue := AQueue;
  FPartials := TScpPartialRegistry.Create;
  FConfirmEvery := SCP_CONFIRM_EVERY;
  SetLength(FBuffer, SCP_COPY_BUFFER);
end;

procedure TScpTransferEngine.NoteFatal(const AErr: TScpError);
begin
  if not IsFatalToSession(AErr.Kind) then Exit;
  FFatal := AErr;
  FHasFatal := True;
end;

function TScpTransferEngine.TakeFatal(out AErr: TScpError): Boolean;
begin
  Result := FHasFatal;
  if Result then
    AErr := FFatal
  else
    AErr := NoScpError;
  FHasFatal := False;
end;

procedure TScpTransferEngine.DropPartialsFor(ADstFs: TScpFileSystem;
  const ATargetPath: string);
var
  stale: TStringArray;
  i: Integer;
  err: TScpError;
begin
  stale := FPartials.ActiveForTarget(ATargetPath, ADstFs.DisplayName);
  for i := 0 to High(stale) do
  begin
    // Deux « .part » pour une cible: la reprise prendrait le premier venu.
    // Oublie seulement ce qui est parti, le reste se nettoie a la fermeture.
    if ADstFs.DeleteTemp(stale[i], err) or (err.Kind = sekNotFound) then
      FPartials.Forget(stale[i]);
  end;
end;

procedure TScpTransferEngine.DiscardPartial(ADstFs: TScpFileSystem;
  const ATempPath: string);
var
  err: TScpError;
begin
  if ADstFs.DeleteTemp(ATempPath, err) or (err.Kind = sekNotFound) then
    FPartials.Forget(ATempPath);
end;

// Temp non retire par le rename: garde pour la fermeture, plus jamais repris.
procedure TScpTransferEngine.PublishedTemp(AItem: TTransferItem;
  const ATempPath: string; var AErr: TScpError);
begin
  if AErr.Kind = sekNone then
  begin
    FPartials.Forget(ATempPath);
    Exit;
  end;
  FPartials.Retire(ATempPath);
  if AItem.Warning = '' then
    AItem.Warning := ScpErrorText(AErr)
  else
    AItem.Warning := AItem.Warning + ' ' + ScpErrorText(AErr);
  AErr := NoScpError;
end;

destructor TScpTransferEngine.Destroy;
begin
  FHash.Free;
  FPartials.Free;
  inherited Destroy;
end;

procedure TScpTransferEngine.Note(const AText: string);
begin
  if Assigned(FOnNote) then
    FOnNote(AText);
end;

procedure TScpTransferEngine.ReportProgress(AItem: TTransferItem;
  AForce: Boolean);
var
  now_: QWord;
begin
  if not Assigned(FOnProgress) then Exit;
  now_ := GetTickCount64;
  // Sinon un fichier rapide se ralentit a force de s'afficher.
  if (not AForce) and (now_ - FLastProgressTick < SCP_PROGRESS_MS) then Exit;
  FLastProgressTick := now_;
  FOnProgress(AItem);
end;

// Les DEUX cotes: leurs controles different.
function TScpTransferEngine.NameUsable(ASrcFs, ADstFs: TScpFileSystem;
  const AName: string; out AWhy: string): Boolean;
var
  v: TNameVerdict;
begin
  AWhy := '';
  v := ASrcFs.CheckName(AName);
  if v = nvOk then
    v := ADstFs.CheckName(AName);
  Result := v = nvOk;
  if not Result then
    AWhy := NameVerdictText(v, DisplaySafeName(AName));
end;

// Un dossier inenumerable ne disparait pas du bilan: « ignore », avec sa raison.
function TScpTransferEngine.WalkDir(ASrcFs, ADstFs: TScpFileSystem;
  ADirection: TTransferDirection; const ASrcDir, ADstDir, ATargetRoot: string;
  ADepth, AMaxDepth: Integer; AOwner: TTransferItem; AKnown: TStrings;
  out AErr: TScpError): Boolean;
var
  entries: TScpEntryArray;
  i: Integer;
  e, e2: TScpEntry;
  childSrc, childDst, why: string;
  err: TScpError;
  item: TTransferItem;
  seen: TStringList;
  key: string;

  // Seul point d'ajout: le plafond se juge ICI, un dossier vide tient dans une
  // file pleine. nil = pleine, FQueueFull pose.
  function AddChild(AKind: TTransferItemKind;
    const AChildSrc, AChildDst, AName: string): TTransferItem;
  begin
    Result := nil;
    if FQueue.Count >= FMaxQueueItems then
    begin
      FQueueFull := True;
      Exit;
    end;
    Result := FQueue.Add(ADirection, AKind, AChildSrc, AChildDst,
      DisplaySafeName(AName), AOwner.Batch, AOwner);
  end;

  // En file a l'etat « ignore », sinon le bilan annoncerait un lot complet.
  // Chemin du DOSSIER: rien a fabriquer a partir d'un nom refuse.
  procedure SkipChild(const AChildSrc, AName: string;
    const AChildErr: TScpError);
  var
    sk: TTransferItem;
  begin
    sk := AddChild(tikFile, AChildSrc, ADstDir, AName);
    if sk = nil then Exit;
    sk.Depth := ADepth;
    sk.TargetRoot := ATargetRoot;
    sk.Error := AChildErr;
    FQueue.SetState(sk, tsSkipped);
  end;

begin
  Result := False;
  AErr := NoScpError;
  if WalkMustStop(ASrcFs, ADstFs, AOwner, ASrcDir, AErr) then Exit;
  if ADepth > AMaxDepth then
  begin
    // Sinon une arborescence fabriquee epuise la pile.
    err := MakeScpError(sekOther, 'Scanning', DisplaySafeName(ASrcDir),
      Format('maximum depth of %d reached, contents not transferred',
        [AMaxDepth]));
    Note(ScpErrorText(err));
    if AOwner <> nil then
    begin
      AOwner.Error := err;
      FQueue.SetState(AOwner, tsSkipped);
    end;
    Exit(True);
  end;
  if not ASrcFs.List(ASrcDir, entries, err) then
  begin
    Note(ScpErrorText(err));
    if IsFatalToSession(err.Kind) then
    begin
      // Une COUPURE remonte, et le dossier reste A PARCOURIR.
      MarkScanCut(AOwner, err);
      AErr := err;
      Exit(False);
    end;
    if AOwner <> nil then
    begin
      AOwner.Error := err;
      FQueue.SetState(AOwner, tsSkipped);
    end;
    Exit(True);
  end;
  if Length(entries) > SCP_MAX_DIR_ENTRIES then
  begin
    // « En attente », il serait cree vide et declare reussi.
    err := MakeScpError(sekOther, 'Scanning', DisplaySafeName(ASrcDir),
      Format('the folder reports more than %d entries, contents not ' +
        'transferred', [SCP_MAX_DIR_ENTRIES]));
    Note(ScpErrorText(err));
    if AOwner <> nil then
    begin
      AOwner.Error := err;
      FQueue.SetState(AOwner, tsSkipped);
    end;
    Exit(True);
  end;

  seen := TStringList.Create;
  try
    // CaseSensitive AVANT Sorted, et True: CollisionKey a deja replie selon la
    // destination. Sinon « README » masque « readme » sur un POSIX.
    seen.CaseSensitive := True;
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    for i := 0 to High(entries) do
    begin
      // Avant CHAQUE ajout: personne n'entre apres une annulation.
      if WalkMustStop(ASrcFs, ADstFs, AOwner, ASrcDir, AErr) then Exit;
      if FQueueFull then Break;
      e := entries[i];
      if not NameUsable(ASrcFs, ADstFs, e.Name, why) then
      begin
        Note(why);
        SkipChild(ASrcFs.Join(ASrcDir, e.Name), e.Name,
          MakeScpError(sekInvalidName, 'Copying',
            DisplaySafeName(e.Name), why));
        Continue;
      end;
      // Deux noms, un fichier: le second ecraserait le premier.
      key := ADstFs.CollisionKey(e.Name);
      if seen.IndexOf(key) >= 0 then
      begin
        Note(Format('Skipped "%s": another entry in the same folder would ' +
          'become the same file on the destination.',
          [DisplaySafeName(e.Name)]));
        SkipChild(ASrcFs.Join(ASrcDir, e.Name), e.Name,
          MakeScpError(sekAlreadyExists, 'Copying',
            DisplaySafeName(e.Name),
            'another entry in the same folder would become the same file ' +
            'on the destination'));
        Continue;
      end;
      seen.Add(key);

      childSrc := ASrcFs.Join(ASrcDir, e.Name);
      childDst := ADstFs.Join(ADstDir, e.Name);
      // Parcours repris: un sous-dossier deja en file se reprend par lui-meme.
      if (AKnown <> nil) and (AKnown.IndexOf(childDst) >= 0) then Continue;
      // Apres jointure ET normalisation: un controle sur le nom seul se contourne.
      if not ADstFs.IsUnder(ATargetRoot, childDst) then
      begin
        Note(ScpErrorText(MakeScpError(sekOutsideRoot, 'Copying',
          DisplaySafeName(e.Name), '')));
        SkipChild(childSrc, e.Name,
          MakeScpError(sekOutsideRoot, 'Copying',
            DisplaySafeName(e.Name), ''));
        Continue;
      end;
      // Des noms courts empiles font quand meme un chemin trop long.
      if (Length(childDst) > SCP_MAX_PATH_BYTES) or
         (Length(childSrc) > SCP_MAX_PATH_BYTES) then
      begin
        Note(Format('Skipped "%s": the resulting path would exceed %d ' +
          'bytes.', [DisplaySafeName(e.Name), SCP_MAX_PATH_BYTES]));
        SkipChild(childSrc, e.Name,
          MakeScpError(sekInvalidName, 'Copying', DisplaySafeName(e.Name),
            Format('the resulting path would exceed %d bytes',
              [SCP_MAX_PATH_BYTES])));
        Continue;
      end;

      if e.TypeUnknown then
      begin
        // Lire un dossier comme un fichier ne se rattrape pas.
        SkipChild(childSrc, e.Name,
          MakeScpError(sekOther, 'Copying', DisplaySafeName(e.Name),
            'the server did not say whether this is a file or a folder'));
        Continue;
      end;
      if e.IsLink then
      begin
        // Jamais suivi: un cycle devient impossible plutot que detectable.
        item := AddChild(tikFile, childSrc, childDst, e.Name);
        if item = nil then Continue;
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.Error := MakeScpError(sekSymlinkSkipped, 'Copying',
          DisplaySafeName(e.Name), e.LinkTarget);
        FQueue.SetState(item, tsSkipped);
        Continue;
      end;
      if e.IsSpecial then
      begin
        item := AddChild(tikFile, childSrc, childDst, e.Name);
        if item = nil then Continue;
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.Error := MakeScpError(sekIsSpecialFile, 'Copying',
          DisplaySafeName(e.Name), '');
        FQueue.SetState(item, tsSkipped);
        Continue;
      end;
      if e.IsDir then
      begin
        // lstat juste avant de descendre: devenu lien, sa cible partirait dans le lot.
        if not ASrcFs.Stat(childSrc, False, e2, err) then
        begin
          if IsFatalToSession(err.Kind) then
          begin
            // Sinon, deja en file, il passerait pour parcouru a la reprise.
            MarkScanCut(AOwner, err);
            AErr := err;
            Exit;
          end;
          SkipChild(childSrc, e.Name, err);
          Continue;
        end;
        if e2.IsLink or (not e2.IsDir) then
        begin
          SkipChild(childSrc, e.Name,
            MakeScpError(sekSymlinkSkipped, 'Copying',
              DisplaySafeName(e.Name),
              'it was a folder when listed and is not one any more'));
          Continue;
        end;
        // Le lstat a pu attendre le serveur longtemps.
        if WalkMustStop(ASrcFs, ADstFs, AOwner, ASrcDir, AErr) then Exit;
        // L'ordre d'insertion EST la garantie parent avant enfants.
        item := AddChild(tikMakeDir, childSrc, childDst, e.Name);
        if item = nil then Continue;
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.SourceMode := e2.Mode;
        item.SourceModeKnown := e2.ModeKnown;
        if not WalkDir(ASrcFs, ADstFs, ADirection, childSrc, childDst,
           ATargetRoot, ADepth + 1, AMaxDepth, item, AKnown, AErr) then
        begin
          if (AErr.Kind = sekCanceled) and item.CancelRequested and
             (not WalkRootStopped(ASrcFs, ADstFs)) then
          begin
            // Seul ce sous-dossier tombe, avec sa descendance; le reste continue.
            FQueue.CancelItem(item);
            AErr := NoScpError;
            Continue;
          end;
          // Annulation ou file pleine: rien a reprendre, RunItem conclut.
          if (AErr.Kind = sekCanceled) or FQueueFull then Exit;
          // Coupe plus bas: celui-ci non plus n'est pas parcouru jusqu'au bout.
          MarkScanCut(AOwner, AErr);
          Exit;
        end;
        Continue;
      end;
      item := AddChild(tikFile, childSrc, childDst, e.Name);
      if item = nil then Continue;
      item.Depth := ADepth;
      item.TargetRoot := ATargetRoot;
      item.TotalBytes := e.Size;
      item.SourceTimeUtc := e.MTimeUtc;
      item.SourceMode := e.Mode;
      item.SourceModeKnown := e.ModeKnown;
    end;
  finally
    seen.Free;
  end;
  if FQueueFull then
  begin
    AErr := MakeScpError(sekOther, 'Scanning', DisplaySafeName(ASrcDir),
      Format('the queue would hold more than %d items', [FMaxQueueItems]));
    Exit;
  end;
  Result := True;
end;

// Interrompu, a reparcourir: pas ecarte.
procedure TScpTransferEngine.MarkScanCut(AOwner: TTransferItem;
  const AErr: TScpError);
begin
  if AOwner = nil then Exit;
  AOwner.Error := MakeScpError(AErr.Kind, 'Scanning', AOwner.DisplayName,
    'its contents could not be listed before the connection was lost; ' +
    'the folder is scanned again once reconnected');
  AOwner.ScanPending := True;
  FQueue.SetState(AOwner, tsInterrupted);
end;

function TScpTransferEngine.CanEnqueue(ACount: Integer): Boolean;
begin
  Result := FQueue.Count + ACount <= FMaxQueueItems;
end;

function TScpTransferEngine.WalkRootStopped(ASrcFs,
  ADstFs: TScpFileSystem): Boolean;
begin
  Result := ASrcFs.Canceled or ADstFs.Canceled or
    ((FWalkRoot <> nil) and FWalkRoot.CancelRequested);
end;

function TScpTransferEngine.WalkMustStop(ASrcFs, ADstFs: TScpFileSystem;
  AOwner: TTransferItem; const ADir: string; out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  if WalkRootStopped(ASrcFs, ADstFs) or
     ((AOwner <> nil) and AOwner.CancelRequested) then
  begin
    AErr := MakeScpError(sekCanceled, 'Scanning', DisplaySafeName(ADir), '');
    Exit(True);
  end;
  Result := False;
end;

function TScpTransferEngine.StopScan(AItem: TTransferItem;
  const AErr: TScpError): Boolean;
begin
  Result := FQueueFull or AItem.CancelRequested or (AErr.Kind = sekCanceled);
  if not Result then Exit;
  // L'etat d'abord, CancelItem ensuite: dans l'autre ordre il serait « annule »
  // avant d'etre dit ecarte.
  if FQueueFull then
  begin
    FQueueFull := False;
    // Ecarte, pas en echec: « Retry failed » recreerait le dossier vide, et reussi.
    AItem.Error := MakeScpError(sekOther, 'Scanning', AItem.DisplayName,
      Format('the queue would hold more than %d items; nothing of this ' +
        'selection was transferred', [FMaxQueueItems]));
    FQueue.SetState(AItem, tsSkipped);
  end
  else
  begin
    AItem.Error := MakeScpError(sekCanceled, 'Scanning', AItem.DisplayName,
      '');
    FQueue.SetState(AItem, tsCanceled);
  end;
  FQueue.CancelItem(AItem);
end;

function TScpTransferEngine.RescanDir(ASrcFs, ADstFs: TScpFileSystem;
  AItem: TTransferItem; out AErr: TScpError): Boolean;
var
  e: TScpEntry;
  known: TStringList;
  i: Integer;
  it: TTransferItem;
  subtree: TFPList;
begin
  Result := False;
  // lstat encore: devenu lien depuis la coupure?
  if not ASrcFs.Stat(AItem.SourcePath, False, e, AErr) then
  begin
    AItem.Error := AErr;
    if IsFatalToSession(AErr.Kind) then
    begin
      AItem.ScanPending := True;
      FQueue.SetState(AItem, tsInterrupted);
      Exit;
    end;
    FQueue.SetState(AItem, tsSkipped);
    Exit(True);
  end;
  if e.IsLink or (not e.IsDir) then
  begin
    AItem.Error := MakeScpError(sekSymlinkSkipped, 'Scanning',
      AItem.DisplayName, 'it was a folder when listed and is not one any more');
    FQueue.SetState(AItem, tsSkipped);
    Exit(True);
  end;
  known := TStringList.Create;
  try
    known.CaseSensitive := True;
    known.Sorted := True;
    known.Duplicates := dupIgnore;
    // Filiation, pas chemin: un autre lot vers le meme endroit reste un autre transfert.
    subtree := TFPList.Create;
    try
      FQueue.Lock;
      try
        FQueue.CollectDescendantsLocked(AItem, subtree);
        for i := 0 to subtree.Count - 1 do
        begin
          it := TTransferItem(subtree[i]);
          known.Add(it.TargetPath);
        end;
      finally
        FQueue.Unlock;
      end;
    finally
      subtree.Free;
    end;
    FWalkRoot := AItem;
    FQueueFull := False;
    try
      Result := WalkDir(ASrcFs, ADstFs, AItem.Direction, AItem.SourcePath,
        AItem.TargetPath, AItem.TargetRoot, AItem.Depth + 1, SCP_MAX_DEPTH,
        AItem, known, AErr);
    finally
      FWalkRoot := nil;
    end;
  finally
    known.Free;
  end;
end;

// '' si tout est pris ou si AErr. Reponse perimee aussitot: la creation
// exclusive rattrape la collision.
function FreeCopyName(AFs: TScpFileSystem; const ADir, AName: string;
  out AErr: TScpError): string;
var
  i: Integer;
  candidate: string;
  found: Boolean;
begin
  Result := '';
  AErr := NoScpError;
  for i := 1 to 99 do
  begin
    candidate := KeepBothCandidate(AName, i);
    if AFs.CheckName(candidate) <> nvOk then Continue;
    if not AFs.Exists(AFs.Join(ADir, candidate), found, AErr) then Exit;
    if not found then Exit(candidate);
  end;
end;

function ScpChmodTree(AFs: TScpFileSystem; const APath: string;
  ABits, AMask: LongWord; ARecursive, ADirX: Boolean; ADepth: Integer;
  var ATally: TScpChmodTally; out AErr: TScpError): Boolean;
const
  OP = 'Setting the permissions of';
var
  entries: TScpEntryArray;
  e, again: TScpEntry;
  i: Integer;
  child: string;
  newMode: LongWord;

  function Changed: Boolean;
  begin
    AErr := MakeScpError(sekOutsideRoot, OP, DisplaySafeName(APath),
      'the folder changed while its permissions were being set');
    Result := False;
  end;

begin
  Result := False;
  AErr := NoScpError;
  if AFs.Canceled then
  begin
    AErr := MakeScpError(sekCanceled, OP, DisplaySafeName(APath), '');
    Exit;
  end;
  if ADepth > SCP_MAX_DEPTH then
  begin
    AErr := MakeScpError(sekOther, OP, DisplaySafeName(APath),
      Format('maximum depth of %d reached', [SCP_MAX_DEPTH]));
    Exit;
  end;
  if not AFs.Stat(APath, False, e, AErr) then Exit;
  if e.IsLink then
  begin
    Inc(ATally.Links);
    Exit(True);
  end;
  if e.IsDir and ARecursive then
  begin
    if not AFs.List(APath, entries, AErr) then Exit;
    // Devenu lien entre lstat et listing: on aurait liste sa cible.
    if not AFs.Stat(APath, False, again, AErr) then Exit;
    if again.IsLink or (not again.IsDir) then Exit(Changed);
    for i := 0 to High(entries) do
    begin
      if AFs.CheckName(entries[i].Name) <> nvOk then
      begin
        AErr := MakeScpError(sekInvalidName, OP,
          DisplaySafeName(entries[i].Name), '');
        Exit;
      end;
      child := AFs.Join(APath, entries[i].Name);
      if not AFs.IsUnder(APath, child) then
      begin
        AErr := MakeScpError(sekOutsideRoot, OP,
          DisplaySafeName(entries[i].Name), '');
        Exit;
      end;
      if not ScpChmodTree(AFs, child, ABits, AMask, ARecursive, ADirX,
         ADepth + 1, ATally, AErr) then
        Exit;
    end;
    // Dossier APRES son contenu: se retirer r ou x d'abord, c'est s'enfermer dehors.
    if not AFs.Stat(APath, False, e, AErr) then Exit;
    if e.IsLink or (not e.IsDir) then Exit(Changed);
  end;
  if (not e.ModeKnown) and ((AMask and SCP_MODE_BITS) <> SCP_MODE_BITS) then
  begin
    // Sans les droits actuels, les bits hors du masque seraient inventes.
    AErr := MakeScpError(sekAttrRefused, OP, DisplaySafeName(APath),
      'the server did not report the current mode');
    Exit;
  end;
  newMode := ScpApplyMode(e.Mode, ABits, AMask, e.IsDir, ADirX);
  if e.ModeKnown and ((e.Mode and SCP_MODE_BITS) = newMode) then
  begin
    Inc(ATally.Unchanged);
    Exit(True);
  end;
  if not AFs.SetModeAt(APath, newMode, AErr) then Exit;
  Inc(ATally.Applied);
  Result := True;
end;

// False = coupure: l'element reste tikScanRoot, interrompu, reprenable.
function TScpTransferEngine.ScanRoot(ASrcFs, ADstFs: TScpFileSystem;
  AItem: TTransferItem; AMaxDepth: Integer; out AErr: TScpError): Boolean;
var
  srcEntry: TScpEntry;
  srcName, targetName, targetPath, parent, why: string;
  v: TNameVerdict;
  e: TScpError;

  procedure SkipWith(const AWhy: TScpError);
  begin
    AItem.Error := AWhy;
    FQueue.SetState(AItem, tsSkipped);
  end;

begin
  Result := True;
  AErr := NoScpError;
  if AMaxDepth <= 0 then AMaxDepth := SCP_MAX_DEPTH;
  srcName := ASrcFs.BaseName(AItem.SourcePath);
  // Tant que rien n'est verifie, la cible de l'element est son DOSSIER.
  parent := AItem.TargetPath;

  if not ASrcFs.Stat(AItem.SourcePath, False, srcEntry, e) then
  begin
    AItem.Error := e;
    if IsFatalToSession(e.Kind) then
    begin
      FQueue.SetState(AItem, tsInterrupted);
      AErr := e;
      Exit(False);
    end;
    FQueue.SetState(AItem, tsFailed);
    Exit;
  end;
  if srcEntry.TypeUnknown then
  begin
    SkipWith(MakeScpError(sekOther, 'Copying', DisplaySafeName(srcName),
      'the server did not say whether this is a file or a folder'));
    Exit;
  end;
  if not NameUsable(ASrcFs, ADstFs, srcName, why) then
  begin
    SkipWith(MakeScpError(sekInvalidName, 'Copying',
      DisplaySafeName(srcName), why));
    Exit;
  end;
  targetName := srcName;
  if AItem.ForcedName <> '' then
  begin
    // Nom calcule, pas garanti: controle comme un autre.
    v := ADstFs.CheckName(AItem.ForcedName);
    if v <> nvOk then
    begin
      SkipWith(MakeScpError(sekInvalidName, 'Copying',
        DisplaySafeName(AItem.ForcedName),
        NameVerdictText(v, DisplaySafeName(AItem.ForcedName))));
      Exit;
    end;
    targetName := AItem.ForcedName;
  end
  else if AItem.Direction in [tdDuplicateLocal, tdDuplicateRemote] then
  begin
    // Cherche ICI: choisi plus tot, il serait perime avant l'ecriture.
    targetName := FreeCopyName(ADstFs, parent, srcName, e);
    if targetName = '' then
    begin
      if e.Kind = sekNone then
        e := MakeScpError(sekAlreadyExists, 'Duplicating',
          DisplaySafeName(srcName), 'no free name left');
      AItem.Error := e;
      if IsFatalToSession(e.Kind) then
      begin
        FQueue.SetState(AItem, tsInterrupted);
        AErr := e;
        Exit(False);
      end;
      FQueue.SetState(AItem, tsSkipped);
      Exit;
    end;
  end;
  targetPath := ADstFs.Join(parent, targetName);
  if not ADstFs.IsUnder(AItem.TargetRoot, targetPath) then
  begin
    SkipWith(MakeScpError(sekOutsideRoot, 'Copying',
      DisplaySafeName(srcName), ''));
    Exit;
  end;
  AItem.TargetPath := targetPath;
  if srcEntry.IsLink then
  begin
    SkipWith(MakeScpError(sekSymlinkSkipped, 'Copying',
      DisplaySafeName(srcName), srcEntry.LinkTarget));
    Exit;
  end;
  if srcEntry.IsSpecial then
  begin
    SkipWith(MakeScpError(sekIsSpecialFile, 'Copying',
      DisplaySafeName(srcName), ''));
    Exit;
  end;
  if srcEntry.IsDir then
  begin
    FQueue.Rekind(AItem, tikMakeDir, DisplaySafeName(targetName));
    AItem.SourceMode := srcEntry.Mode;
    AItem.SourceModeKnown := srcEntry.ModeKnown;
    FWalkRoot := AItem;
    FQueueFull := False;
    try
      Result := WalkDir(ASrcFs, ADstFs, AItem.Direction, AItem.SourcePath,
        targetPath, AItem.TargetRoot, 1, AMaxDepth, AItem, nil, AErr);
    finally
      FWalkRoot := nil;
    end;
    Exit;
  end;
  FQueue.Rekind(AItem, tikFile, DisplaySafeName(targetName));
  AItem.TotalBytes := srcEntry.Size;
  AItem.SourceTimeUtc := srcEntry.MTimeUtc;
  AItem.SourceMode := srcEntry.Mode;
  AItem.SourceModeKnown := srcEntry.ModeKnown;
end;

function TScpTransferEngine.EnumerateInto(ASrcFs, ADstFs: TScpFileSystem;
  ADirection: TTransferDirection;
  const ASourcePath, ATargetParent, ATargetRoot: string;
  AMaxDepth: Integer; out AErr: TScpError;
  const ATargetName: string): Boolean;
var
  it: TTransferItem;
begin
  it := FQueue.Add(ADirection, tikScanRoot, ASourcePath, ATargetParent,
    DisplaySafeName(ASrcFs.BaseName(ASourcePath)));
  it.TargetRoot := ATargetRoot;
  it.ForcedName := ATargetName;
  Result := ScanRoot(ASrcFs, ADstFs, it, AMaxDepth, AErr);
  if StopScan(it, AErr) then Result := True;
end;

function TScpTransferEngine.ResolveConflict(ASrcFs, ADstFs: TScpFileSystem;
  AItem: TTransferItem; const ASrcEntry: TScpEntry;
  var ATargetPath: string; out AOutcome: TScpConflictOutcome;
  out AErr: TScpError): Boolean;
var
  found: Boolean;
  dstEntry: TScpEntry;
  info: TConflictInfo;
  decision: TConflictDecision;
  partial: TScpPartial;
  candidate, baseName, parentDir: string;
  i: Integer;
  statErr: TScpError;
begin
  Result := False;
  AOutcome := Default(TScpConflictOutcome);
  AErr := NoScpError;

  if not ADstFs.Exists(ATargetPath, found, AErr) then Exit;
  if not found then
  begin
    // Pas de conflit, mais c'est LE cas ordinaire de reprise d'un fichier neuf.
    if FPartials.FindResumable(ATargetPath, ASrcFs.DisplayName,
       ADstFs.DisplayName, AItem.SourcePath, ASrcEntry.Size,
       ASrcEntry.MTimeUtc, partial) then
    begin
      AOutcome.ResumeFrom := partial.Confirmed;
      AOutcome.ResumeTemp := partial.TempPath;
      if ASrcFs.IsRemote then
        Note(Format('Resuming %s from %s; the source is read again up to ' +
          'there to check it has not changed.',
          [AItem.DisplayName, FormatBytes(partial.Confirmed)]))
      else
        Note(Format('Resuming %s from %s.',
          [AItem.DisplayName, FormatBytes(partial.Confirmed)]));
    end;
    Exit(True);
  end;

  // lstat: un lien ici sera REMPLACE par le rename, pas suivi.
  AOutcome.TargetExisted := True;
  info := Default(TConflictInfo);
  info.SourcePath := AItem.SourcePath;
  info.TargetPath := ATargetPath;
  info.SourceSize := ASrcEntry.Size;
  info.SourceTimeUtc := ASrcEntry.MTimeUtc;
  info.TargetSize := -1;
  if not ADstFs.Stat(ATargetPath, False, dstEntry, statErr) then
  begin
    // Quelque chose d'innommable: pourrait etre un 0000, un dossier, une coupure.
    AErr := statErr;
    Exit;
  end;
  // SFTP tire le type des permissions: un serveur qui les tait cache peut-etre un dossier.
  if dstEntry.TypeUnknown then
  begin
    AErr := MakeScpError(sekOther, 'Copying', DisplaySafeName(ATargetPath),
      'the server did not say whether the destination is a file, a folder ' +
      'or a link; it was left untouched');
    Exit;
  end;
  if dstEntry.IsDir then
  begin
    AErr := MakeScpError(sekAlreadyExists, 'Copying',
      DisplaySafeName(ATargetPath),
      'the destination is a folder, not a file');
    Exit;
  end;
  if (not dstEntry.IsLink) and (not dstEntry.ModeKnown) then
  begin
    // Des droits illisibles ne se gardent pas. Refus AVANT la question.
    AErr := MakeScpError(sekAttrRefused, 'Copying',
      DisplaySafeName(ATargetPath), 'the permissions of the existing file ' +
      'could not be read, so they could not be kept; it was left untouched');
    Exit;
  end;
  AOutcome.TargetIsLink := dstEntry.IsLink;
  if dstEntry.IsLink then
  begin
    if ADstFs.Stat(ATargetPath, True, dstEntry, statErr) then
    begin
      info.TargetSize := dstEntry.Size;
      info.TargetTimeUtc := dstEntry.MTimeUtc;
    end;
  end
  else
  begin
    info.TargetSize := dstEntry.Size;
    info.TargetTimeUtc := dstEntry.MTimeUtc;
    // Zero = « aucun droit », et le reste.
    AOutcome.PrevMode := dstEntry.Mode and LongWord(&07777);
  end;

  info.ResumeAllowed := FPartials.FindResumable(ATargetPath,
    ASrcFs.DisplayName, ADstFs.DisplayName, AItem.SourcePath,
    ASrcEntry.Size, ASrcEntry.MTimeUtc, partial);
  if info.ResumeAllowed then
  begin
    info.ResumeOffset := partial.Confirmed;
    AOutcome.ResumeTemp := partial.TempPath;
  end
  else
    info.ResumeRefusedWhy := 'No partial file from this session matches this ' +
      'source (server, path, size and timestamp must all agree).';

  decision.Action := FQueue.ConflictPolicy(AItem.Batch);
  // « Resume » pour tout le lot: sans partiel concordant on REDEMANDE, on ne saute pas.
  if (decision.Action = cnResume) and (not info.ResumeAllowed) then
    decision.Action := cnAsk;
  decision.ApplyToAll := decision.Action <> cnAsk;
  if decision.Action = cnAsk then
  begin
    if not Assigned(FOnConflict) then
    begin
      // Personne a qui demander: on ne devine pas.
      AErr := MakeScpError(sekAlreadyExists, 'Copying',
        DisplaySafeName(ATargetPath), '');
      Exit;
    end;
    decision.Action := cnAsk;
    decision.ApplyToAll := False;
    FOnConflict(info, decision);
    if decision.ApplyToAll and (decision.Action <> cnAsk) then
      FQueue.SetConflictPolicy(AItem.Batch, decision.Action);
  end;

  // Une reprise impossible ne devient pas un ecrasement.
  if (decision.Action = cnResume) and (not info.ResumeAllowed) then
    decision.Action := cnSkip;

  case decision.Action of
    cnOverwrite:
      begin
        AOutcome.ResumeTemp := '';
        Result := True;
      end;
    cnResume:
      begin
        AOutcome.ResumeFrom := info.ResumeOffset;
        Result := True;
      end;
    cnKeepBoth:
      begin
        parentDir := ADstFs.Parent(ATargetPath);
        baseName := ADstFs.BaseName(ATargetPath);
        for i := 1 to 999 do
        begin
          candidate := ADstFs.Join(parentDir,
            KeepBothCandidate(baseName, i));
          if not ADstFs.Exists(candidate, found, AErr) then Exit;
          if not found then
          begin
            ATargetPath := candidate;
            AItem.TargetPath := candidate;
            AOutcome.ResumeTemp := '';
            // Nom neuf: publier en creant, jamais en ecrasant.
            AOutcome.TargetExisted := False;
            AOutcome.TargetIsLink := False;
            AOutcome.PrevMode := 0;
            Exit(True);
          end;
        end;
        AErr := MakeScpError(sekAlreadyExists, 'Copying',
          DisplaySafeName(ATargetPath),
          'no free name found after 999 attempts');
      end;
    cnSkip:
      begin
        AItem.Error := MakeScpError(sekAlreadyExists, 'Copying',
          DisplaySafeName(ATargetPath), 'skipped by choice');
        FQueue.SetState(AItem, tsSkipped);
      end;
    cnCancelQueue:
      begin
        FQueue.CancelAll;
        AErr := MakeScpError(sekCanceled, 'Copying',
          DisplaySafeName(ATargetPath), '');
      end;
  else
    // cnAsk rendu tel quel: pas de reponse, pas d'ecriture.
    AItem.Error := MakeScpError(sekAlreadyExists, 'Copying',
      DisplaySafeName(ATargetPath), 'no decision was made');
    FQueue.SetState(AItem, tsSkipped);
  end;
end;

function TScpTransferEngine.CopyStream(ASrcFs: TScpFileSystem;
  ASrcH: TScpFileHandle; ADstFs: TScpFileSystem; ADstH: TScpFileHandle;
  AItem: TTransferItem; AExpected: Int64; AStartOffset: Int64;
  const ATempPath: string; AHash: TScpHash;
  out AErr: TScpError): Boolean;
var
  got, put, offset: Integer;
  total, cap, sinceConfirm: Int64;
  digest: TScpDigest;
begin
  Result := False;
  AErr := NoScpError;
  total := AStartOffset;
  sinceConfirm := 0;
  AItem.DoneBytes := total;
  cap := -1;
  if AExpected >= 0 then cap := AExpected + SCP_GROWTH_SLACK;

  while True do
  begin
    // Sinon « Cancel selected » n'est qu'une etiquette et la copie publie quand meme.
    if ASrcFs.Canceled or ADstFs.Canceled or AItem.CancelRequested then
    begin
      AErr := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName, '');
      Exit;
    end;

    if not ASrcFs.Read(ASrcH, @FBuffer[0], SCP_COPY_BUFFER, got, AErr) then
      Exit;
    // LE piege: une lecture courte n'est pas la fin du fichier. Seul zero l'est.
    if got = 0 then Break;
    if got < 0 then
    begin
      AErr := MakeScpError(sekOther, 'Copying', AItem.DisplayName,
        'the source reported a negative read');
      Exit;
    end;

    // Ecriture courte: on boucle, sinon le fichier arrive tronque mais « reussi ».
    offset := 0;
    while offset < got do
    begin
      if ASrcFs.Canceled or ADstFs.Canceled or AItem.CancelRequested then
      begin
        AErr := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName, '');
        Exit;
      end;
      if not ADstFs.Write(ADstH, @FBuffer[offset], got - offset, put,
         AErr) then
        Exit;
      if put <= 0 then
      begin
        AErr := MakeScpError(sekOther, 'Copying', AItem.DisplayName,
          'the destination accepted no bytes');
        Exit;
      end;
      // Ce que la destination a ACCEPTE, pas ce qu'on a voulu ecrire.
      AHash.Update(FBuffer[offset], put);
      Inc(offset, put);
      Inc(total, put);
      Inc(sinceConfirm, put);
    end;

    AItem.DoneBytes := total;
    // CONFIRME = vide sur le support. Reprendre sur du tampon, c'est reprendre
    // apres un trou.
    if (ATempPath <> '') and (sinceConfirm >= FConfirmEvery) then
    begin
      if not ADstFs.Flush(ADstH, AErr) then Exit;
      AHash.Peek(digest);
      FPartials.Confirm(ATempPath, total, digest);
      sinceConfirm := 0;
    end;
    ReportProgress(AItem, False);

    if (cap > 0) and (total > cap) then
    begin
      AErr := MakeScpError(sekOther, 'Copying', AItem.DisplayName,
        Format('the source kept growing more than %s past its announced ' +
          'size', [FormatBytes(SCP_GROWTH_SLACK)]));
      Exit;
    end;
  end;

  // Source tronquee ou remplacee depuis le listing: la cible ne bouge pas.
  if (AExpected >= 0) and (total < AExpected) then
  begin
    AErr := MakeScpError(sekPrematureEof, 'Copying', AItem.DisplayName,
      Format('%d bytes read, %d announced', [total, AExpected]));
    Exit;
  end;

  AItem.DoneBytes := total;
  // La taille annoncee peut mentir; l'ecrit, non.
  if (AItem.TotalBytes < 0) or (total > AItem.TotalBytes) then
    AItem.TotalBytes := total;
  ReportProgress(AItem, True);
  Result := True;
end;

function TScpTransferEngine.PartialUsable(ADstFs: TScpFileSystem;
  const ATempPath: string; AConfirmed, ASourceSize: Int64;
  out AWhy: string; out AErr: TScpError): Boolean;
var
  e: TScpEntry;
  err: TScpError;
begin
  Result := False;
  AWhy := '';
  AErr := NoScpError;
  // lstat: un lien a la place du partiel ferait ecrire la suite ailleurs.
  if not ADstFs.Stat(ATempPath, False, e, err) then
  begin
    // « Absent » est une reponse; le reste est une panne, pas une disparition.
    if err.Kind = sekNotFound then
      AWhy := 'it is no longer there'
    else
      AErr := err;
    Exit;
  end;
  if e.IsLink then
  begin
    AWhy := 'it has been replaced by a link';
    Exit;
  end;
  if e.IsDir or e.IsSpecial then
  begin
    AWhy := 'it is no longer a regular file';
    Exit;
  end;
  // Tronque depuis: rouvrir comblerait de zeros jusqu'a l'offset.
  if (e.Size >= 0) and (e.Size < AConfirmed) then
  begin
    AWhy := 'it is shorter than the confirmed offset';
    Exit;
  end;
  // Plus long que la SOURCE: SFTP v3 ne sait pas tronquer, la queue serait publiee.
  if (e.Size >= 0) and (ASourceSize >= 0) and (e.Size > ASourceSize) then
  begin
    AWhy := 'it is longer than the source';
    Exit;
  end;
  Result := True;
end;

function TScpTransferEngine.VerifyPartialPrefix(ADstFs: TScpFileSystem;
  ADstH: TScpFileHandle; AItem: TTransferItem; const APartial: TScpPartial;
  AHash: TScpHash; out AWhy: string; out AErr: TScpError): Boolean;
var
  left: Int64;
  want, got: Integer;
  digest: TScpDigest;
begin
  Result := False;
  AWhy := '';
  AErr := NoScpError;
  AHash.Reset;
  // Par la poignee qui va ecrire: entre lstat et open, le chemin a pu changer de fichier.
  if not ADstFs.Seek(ADstH, 0, AErr) then Exit;
  left := APartial.Confirmed;
  while left > 0 do
  begin
    if ADstFs.Canceled or AItem.CancelRequested then
    begin
      AErr := MakeScpError(sekCanceled, 'Verifying', AItem.DisplayName, '');
      Exit;
    end;
    want := SCP_COPY_BUFFER;
    if left < want then want := Integer(left);
    if not ADstFs.Read(ADstH, @FBuffer[0], want, got, AErr) then Exit;
    // EOF avant l'offset confirme: lstat et la poignee peuvent differer.
    if got <= 0 then
    begin
      AWhy := 'it is shorter than the confirmed offset';
      Exit;
    end;
    AHash.Update(FBuffer[0], got);
    Dec(left, got);
  end;
  AHash.Peek(digest);
  if not ScpDigestMatch(digest, APartial.Digest) then
  begin
    AWhy := 'its content no longer matches what was written';
    Exit;
  end;
  if not ADstFs.Seek(ADstH, APartial.Confirmed, AErr) then Exit;
  Result := True;
end;

function TScpTransferEngine.VerifySourcePrefix(ASrcFs: TScpFileSystem;
  ASrcH: TScpFileHandle; AItem: TTransferItem; const APartial: TScpPartial;
  out AWhy: string; out AErr: TScpError): Boolean;
var
  left: Int64;
  want, got: Integer;
  ctx: TScpHash;
  digest: TScpDigest;
begin
  Result := False;
  AWhy := '';
  AErr := NoScpError;
  ctx := TScpHash.Create;
  try
    if not ASrcFs.Seek(ASrcH, 0, AErr) then Exit;
    left := APartial.Confirmed;
    while left > 0 do
    begin
      if ASrcFs.Canceled or AItem.CancelRequested then
      begin
        AErr := MakeScpError(sekCanceled, 'Verifying', AItem.DisplayName, '');
        Exit;
      end;
      want := SCP_COPY_BUFFER;
      if left < want then want := Integer(left);
      if not ASrcFs.Read(ASrcH, @FBuffer[0], want, got, AErr) then Exit;
      if got <= 0 then
      begin
        AWhy := 'the source is now shorter than the confirmed offset';
        Exit;
      end;
      ctx.Update(FBuffer[0], got);
      Dec(left, got);
    end;
    ctx.Peek(digest);
    if not ScpDigestMatch(digest, APartial.Digest) then
    begin
      // Meme taille, meme date, autre contenu: on collerait un vieux debut a une fin neuve.
      AWhy := 'the source has changed since the transfer was interrupted';
      Exit;
    end;
    Result := True;
  finally
    ctx.Free;
  end;
end;

function TScpTransferEngine.CommitTemp(ADstFs: TScpFileSystem;
  AItem: TTransferItem; const ATempPath, ATargetPath: string;
  ATargetExisted: Boolean; out AErr: TScpError): Boolean;
var
  allow: Boolean;
begin
  AErr := NoScpError;
  if not ATargetExisted then
  begin
    Result := ADstFs.Rename(ATempPath, ATargetPath, AErr);
    if Result then PublishedTemp(AItem, ATempPath, AErr);
    Exit;
  end;

  Result := ADstFs.ReplaceAtomic(ATempPath, ATargetPath, AErr);
  if Result then
  begin
    FPartials.Forget(ATempPath);
    Exit;
  end;
  // Refus de DROIT: le repli detruirait la cible pour buter sur le meme refus.
  if AErr.Kind <> sekUnsupported then Exit;

  // Demande POUR CE FICHIER, jamais pour le lot: le repli supprime la cible.
  allow := False;
  if Assigned(FOnNonAtomic) then
    FOnNonAtomic(ATargetPath, allow);
  if not allow then
  begin
    AErr := MakeScpError(sekRenameRefused, 'Replacing',
      DisplaySafeName(ATargetPath),
      'atomic replacement is not available here and the non-atomic fallback ' +
      'was declined; the existing file was left untouched');
    Exit(False);
  end;
  // La question a pu trainer: une annulation arrivee entre-temps compte encore.
  if AItem.CancelRequested then
  begin
    AErr := MakeScpError(sekCanceled, 'Replacing',
      DisplaySafeName(ATargetPath), '');
    Exit(False);
  end;

  // Seule fenetre sans cible, ouverte sur accord explicite.
  Note(Format('Replaced %s without an atomic rename, as confirmed.',
    [DisplaySafeName(ATargetPath)]));
  if not ADstFs.DeleteFile(ATargetPath, AErr) then Exit(False);
  Result := ADstFs.Rename(ATempPath, ATargetPath, AErr);
  if Result then PublishedTemp(AItem, ATempPath, AErr);
end;

procedure TScpTransferEngine.FailItem(AItem: TTransferItem;
  const AErr: TScpError);
begin
  AItem.Error := AErr;
  NoteFatal(AErr);
  if AErr.Kind = sekCanceled then
    FQueue.SetState(AItem, tsCanceled)
  else if IsFatalToSession(AErr.Kind) then
    // INTERROMPU, pas echoue: la reprise reste possible.
    FQueue.SetState(AItem, tsInterrupted)
  else
    FQueue.SetState(AItem, tsFailed);
end;

procedure TScpTransferEngine.FailSubtree(ADstFs: TScpFileSystem;
  AItem: TTransferItem);
var
  i: Integer;
  it: TTransferItem;
  subtree: TFPList;
begin
  subtree := TFPList.Create;
  FQueue.Lock;
  try
    FQueue.CollectDescendantsLocked(AItem, subtree);
    for i := 0 to subtree.Count - 1 do
    begin
      it := TTransferItem(subtree[i]);
      if not it.IsRunnable then Continue;
      it.Error := MakeScpError(AItem.Error.Kind, 'Copying', it.DisplayName,
        Format('its folder "%s" could not be created', [AItem.DisplayName]));
      // Meme etat que le dossier, sinon lui repart et son contenu reste a quai.
      if IsFatalToSession(AItem.Error.Kind) then
        FQueue.SetState(it, tsInterrupted)
      else
        FQueue.SetState(it, tsFailed);
    end;
  finally
    FQueue.Unlock;
    subtree.Free;
  end;
end;

function TScpTransferEngine.RunItem(ASrcFs, ADstFs: TScpFileSystem;
  AItem: TTransferItem; const ATargetRoot: string): Boolean;
var
  err, closeErr, attrErr: TScpError;
  srcEntry, dstEntry: TScpEntry;
  srcH, dstH: TScpFileHandle;
  targetPath, tempPath, parentDir: string;
  resumeFrom: Int64;
  resumeTemp: string;
  targetExisted, replacesFile, found, okCopy: Boolean;
  v: TNameVerdict;
  prevMode, newMode, tempMode: LongWord;
  why: string;
  digest: TScpDigest;
  partial: TScpPartial;
  outcome: TScpConflictOutcome;
  scanned, madeDir: Boolean;

  procedure AddWarning(const AText: string);
  begin
    if AItem.Warning = '' then
      AItem.Warning := AText
    else
      AItem.Warning := AItem.Warning + ' ' + AText;
  end;

begin
  Result := False;
  srcH := nil;
  dstH := nil;
  tempPath := '';

  if AItem.IsTerminal then Exit(True);
  if ASrcFs.Canceled or ADstFs.Canceled or AItem.CancelRequested then
  begin
    AItem.Error := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName, '');
    FQueue.SetState(AItem, tsCanceled);
    Exit;
  end;

  if AItem.Kind = tikScanRoot then
  begin
    // En « Scanning », annuler DEMANDE l'arret; sinon la ligne passe a « annule »
    // pendant que le parcours continue d'ajouter des enfants.
    if not FQueue.SetState(AItem, tsEnumerating) then Exit;
    scanned := ScanRoot(ASrcFs, ADstFs, AItem, SCP_MAX_DEPTH, err);
    if StopScan(AItem, err) then Exit;
    if not scanned then
    begin
      // Filet: jamais de selection coincee en « Scanning ».
      if AItem.State = tsEnumerating then
        MarkScanCut(AItem, err);
      NoteFatal(err);
      Exit;
    end;
    if AItem.IsTerminal then Exit(AItem.State = tsSkipped);
    if AItem.State = tsFailed then Exit;
  end;

  targetPath := AItem.TargetPath;
  // A chaque element: un dossier a pu devenir lien depuis l'enumeration.
  if not ADstFs.IsUnder(ATargetRoot, targetPath) then
  begin
    AItem.Error := MakeScpError(sekOutsideRoot, 'Copying',
      AItem.DisplayName, '');
    FQueue.SetState(AItem, tsFailed);
    Exit;
  end;
  v := ADstFs.CheckName(ADstFs.BaseName(targetPath));
  if v <> nvOk then
  begin
    AItem.Error := MakeScpError(sekInvalidName, 'Copying', AItem.DisplayName,
      NameVerdictText(v, AItem.DisplayName));
    FQueue.SetState(AItem, tsFailed);
    Exit;
  end;

  if AItem.Kind = tikMakeDir then
  begin
    // Refus = annule entre-temps, l'etat est deja pose.
    if not FQueue.SetState(AItem, tsTransferring) then Exit;
    if not ADstFs.Exists(targetPath, found, err) then
    begin
      FailItem(AItem, err);
      FailSubtree(ADstFs, AItem);
      Exit;
    end;
    if found then
    begin
      // lstat: un LIEN ici emmenerait le contenu ailleurs, invisible au controle
      // lexical.
      if not ADstFs.Stat(targetPath, False, dstEntry, err) then
      begin
        // Inconnu: pas question d'y deverser un sous-arbre.
        FailItem(AItem, err);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
      if dstEntry.IsLink then
      begin
        AItem.Error := MakeScpError(sekOutsideRoot, 'Creating folder',
          AItem.DisplayName,
          'the destination folder is a link, and nothing is written ' +
          'through links');
        FQueue.SetState(AItem, tsFailed);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
      if not dstEntry.IsDir then
      begin
        AItem.Error := MakeScpError(sekAlreadyExists, 'Creating folder',
          AItem.DisplayName, 'a file of that name already exists');
        FQueue.SetState(AItem, tsFailed);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
    end
    else
    begin
      // Relue ICI, le parcours a pu etre long: disparue, passee en 0700, devenue lien.
      if not ASrcFs.Stat(AItem.SourcePath, False, srcEntry, err) then
      begin
        if err.Kind = sekNotFound then
          err.Kind := sekPathGone;
        FailItem(AItem, err);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
      if srcEntry.IsLink or (not srcEntry.IsDir) then
      begin
        AItem.Error := MakeScpError(sekNotADirectory, 'Creating folder',
          AItem.DisplayName, 'the source is not a folder any more');
        FQueue.SetState(AItem, tsFailed);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
      AItem.SourceMode := srcEntry.Mode;
      AItem.SourceModeKnown := srcEntry.ModeKnown;
      if ASrcFs = ADstFs then
        madeDir := ADstFs.MakeDirFromSource(AItem.SourcePath, targetPath,
          ModeForNewDir(AItem.SourceMode, AItem.SourceModeKnown), err)
      else
        madeDir := ADstFs.MakeDir(targetPath,
          ModeForNewDir(AItem.SourceMode, AItem.SourceModeKnown), err);
      if not madeDir then
      begin
        FailItem(AItem, err);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
    end;
    if AItem.ScanPending then
    begin
      AItem.ScanPending := False;
      if not RescanDir(ASrcFs, ADstFs, AItem, err) then
      begin
        if StopScan(AItem, err) then Exit;
        NoteFatal(err);
        Exit;
      end;
      if StopScan(AItem, NoScpError) then Exit;
      if AItem.State = tsSkipped then Exit(True);
    end;
    FQueue.SetState(AItem, tsCompleted);
    Exit(True);
  end;

  // lstat encore: devenue lien depuis l'enumeration?
  if not ASrcFs.Stat(AItem.SourcePath, False, srcEntry, err) then
  begin
    if err.Kind = sekNotFound then
      err.Kind := sekPathGone;
    FailItem(AItem, err);
    Exit;
  end;
  if srcEntry.IsLink then
  begin
    AItem.Error := MakeScpError(sekSymlinkSkipped, 'Copying',
      AItem.DisplayName, srcEntry.LinkTarget);
    FQueue.SetState(AItem, tsSkipped);
    Exit(True);
  end;
  if srcEntry.IsSpecial then
  begin
    AItem.Error := MakeScpError(sekIsSpecialFile, 'Copying',
      AItem.DisplayName, '');
    FQueue.SetState(AItem, tsSkipped);
    Exit(True);
  end;
  if srcEntry.IsDir then
  begin
    AItem.Error := MakeScpError(sekNotADirectory, 'Copying',
      AItem.DisplayName, 'the source became a folder since it was listed');
    FQueue.SetState(AItem, tsFailed);
    Exit;
  end;
  AItem.TotalBytes := srcEntry.Size;
  AItem.SourceTimeUtc := srcEntry.MTimeUtc;
  AItem.SourceMode := srcEntry.Mode;
  AItem.SourceModeKnown := srcEntry.ModeKnown;

  if not ResolveConflict(ASrcFs, ADstFs, AItem, srcEntry, targetPath,
     outcome, err) then
  begin
    if AItem.State = tsSkipped then Exit(True);
    if err.Kind <> sekNone then FailItem(AItem, err);
    Exit;
  end;
  if AItem.State = tsSkipped then Exit(True);
  AItem.TargetPath := targetPath;
  resumeFrom := outcome.ResumeFrom;
  resumeTemp := outcome.ResumeTemp;
  prevMode := outcome.PrevMode;
  // L'etat VU, pas un second Exists: un fichier apparu entre-temps serait ecrase
  // sans temoin. Vue absente, la cible se publie par un rename qui REFUSE d'ecraser.
  targetExisted := outcome.TargetExisted;
  replacesFile := targetExisted and (not outcome.TargetIsLink);

  if not FQueue.SetState(AItem, tsTransferring) then Exit;
  parentDir := ADstFs.Parent(targetPath);
  // Mode pose A LA CREATION, sous l'umask; un chmod apres coup passerait outre.
  // Remplacement: 0600, puis les droits de la cible juste avant publication.
  newMode := ModeForNewFile(srcEntry.Mode, srcEntry.ModeKnown);
  tempMode := newMode;
  if replacesFile then tempMode := LongWord(&0600);
  try
    if not ASrcFs.OpenRead(AItem.SourcePath, srcH, err) then
    begin
      // Listee mais refusee: « dossier illisible » ferait chercher au mauvais endroit.
      if err.Kind = sekAccessDeniedDir then
        err.Kind := sekAccessDeniedRead;
      FailItem(AItem, err);
      Exit;
    end;

    if (resumeFrom > 0) and (resumeTemp <> '') then
    begin
      tempPath := resumeTemp;
      // Le registre dit ce que le partiel ETAIT, le disque ce qu'il EST.
      if not PartialUsable(ADstFs, tempPath, resumeFrom, srcEntry.Size, why,
         err) then
      begin
        if err.Kind <> sekNone then
        begin
          // Non jugeable: on le garde, l'element s'arrete la.
          FailItem(AItem, err);
          Exit;
        end;
        Note(Format('The partial file for %s cannot be resumed (%s); ' +
          'starting over.', [AItem.DisplayName, why]));
        // Un lien se retire lui-meme, jamais ce qu'il designe.
        DiscardPartial(ADstFs, tempPath);
        tempPath := '';
        resumeFrom := 0;
      end
      else if not ADstFs.OpenAppend(tempPath, resumeFrom, dstH, err) then
      begin
        if IsFatalToSession(err.Kind) then
        begin
          // Session tombee: le partiel est intact, on ne recommence pas.
          FailItem(AItem, err);
          Exit;
        end;
        Note(Format('The partial file for %s could not be reopened (%s); ' +
          'starting over.', [AItem.DisplayName, ScpErrorText(err)]));
        DiscardPartial(ADstFs, tempPath);
        tempPath := '';
        resumeFrom := 0;
      end
      else
      begin
        // lstat juge un chemin; relire par la poignee juge le FICHIER.
        if not FPartials.Lookup(tempPath, partial) then
          partial.Confirmed := -1;
        if (partial.Confirmed <> resumeFrom) or
           not VerifyPartialPrefix(ADstFs, dstH, AItem, partial, FHash, why,
             err) then
        begin
          ADstFs.Close(dstH, closeErr);
          dstH := nil;
          if err.Kind <> sekNone then
          begin
            FailItem(AItem, err);
            Exit;
          end;
          if why = '' then why := 'the registry and the offset disagree';
          Note(Format('The partial file for %s cannot be resumed (%s); ' +
            'starting over.', [AItem.DisplayName, why]));
          DiscardPartial(ADstFs, tempPath);
          tempPath := '';
          resumeFrom := 0;
        end
        else
        begin
          // Meme taille et meme date ne font pas le meme contenu. Relire la source
          // distante coute ce que la reprise economisait: tant pis, c'est le prix.
          why := '';
          if not VerifySourcePrefix(ASrcFs, srcH, AItem, partial, why, err)
          then
          begin
            ADstFs.Close(dstH, closeErr);
            dstH := nil;
            if err.Kind <> sekNone then
            begin
              FailItem(AItem, err);
              Exit;
            end;
            Note(Format('The partial file for %s cannot be resumed (%s); ' +
              'starting over.', [AItem.DisplayName, why]));
            DiscardPartial(ADstFs, tempPath);
            tempPath := '';
            resumeFrom := 0;
            if not ASrcFs.Seek(srcH, 0, err) then
            begin
              FailItem(AItem, err);
              Exit;
            end;
          end
          else if not ASrcFs.Seek(srcH, resumeFrom, err) then
          begin
            FailItem(AItem, err);
            Exit;
          end;
        end;
      end;
    end;
    if tempPath = '' then
    begin
      DropPartialsFor(ADstFs, targetPath);
      // DANS le dossier cible: ailleurs, le rename changerait de FS et d'atomicite.
      if not ADstFs.CreateTemp(parentDir, tempMode, tempPath, dstH, err) then
      begin
        if err.Kind = sekAccessDeniedRead then
          err.Kind := sekAccessDeniedWrite;
        FailItem(AItem, err);
        Exit;
      end;
      FPartials.Note(tempPath, targetPath, ASrcFs.DisplayName,
        ADstFs.DisplayName, AItem.SourcePath, srcEntry.Size,
        srcEntry.MTimeUtc);
      resumeFrom := 0;
      FHash.Reset;
      // « Pas de remplacement », pas « cible absente »: un LIEN remplace laisse un
      // fichier neuf qui, sinon, heriterait du dossier.
      if (ASrcFs = ADstFs) and (not replacesFile) and
         (not ADstFs.CopyProtectionFrom(AItem.SourcePath, tempPath, err)) then
      begin
        ADstFs.Close(dstH, closeErr);
        dstH := nil;
        DiscardPartial(ADstFs, tempPath);
        FailItem(AItem, err);
        Exit;
      end;
    end;

    okCopy := CopyStream(ASrcFs, srcH, ADstFs, dstH, AItem, srcEntry.Size,
      resumeFrom, tempPath, FHash, err);

    // Vider AVANT de conclure: un disque plein ne se revele souvent qu'ici.
    if okCopy then
      okCopy := ADstFs.Flush(dstH, err);
    if okCopy then
    begin
      FHash.Peek(digest);
      FPartials.Confirm(tempPath, AItem.DoneBytes, digest);
    end;

    // Par la POIGNEE, avant fermeture. Un 0600 devenu 0644 est une fuite: droits
    // non reposables = cible non remplacee.
    if okCopy and replacesFile then
    begin
      if not ADstFs.SetMode(dstH, ModeForReplacedFile(prevMode), attrErr) then
      begin
        ADstFs.Close(dstH, closeErr);
        dstH := nil;
        if IsFatalToSession(attrErr.Kind) then
        begin
          FailItem(AItem, attrErr);
          Exit;
        end;
        attrErr := MakeScpError(attrErr.Kind, 'Setting the mode of',
          AItem.DisplayName, 'the permissions of the existing file could ' +
          'not be applied to the new content; the existing file was left ' +
          'untouched');
        DiscardPartial(ADstFs, tempPath);
        FailItem(AItem, attrErr);
        Exit;
      end
      else if (prevMode and LongWord(&07000)) <> 0 then
        AddWarning(Format('%s: the setuid, setgid or sticky bit of the ' +
          'existing file was not carried over to the new content.',
          [AItem.DisplayName]));
    end;
    // Date refusee: avertissement. Coupure: interruption, partiel complet.
    if okCopy and (srcEntry.MTimeUtc > 0) then
      if not ADstFs.SetMTime(dstH, srcEntry.MTimeUtc, attrErr) then
      begin
        if IsFatalToSession(attrErr.Kind) then
        begin
          okCopy := False;
          err := attrErr;
        end
        else
          AddWarning(ScpErrorText(MakeScpError(sekAttrRefused,
            'Setting the timestamp of', AItem.DisplayName, attrErr.Detail)));
      end;

    // Attributs de la source en DERNIER, par la poignee. Refus = pas de publication.
    if okCopy and (ASrcFs = ADstFs) and (not replacesFile) and
       (not ADstFs.CopyAttributesFrom(srcH, dstH, attrErr)) then
    begin
      ADstFs.Close(dstH, closeErr);
      dstH := nil;
      DiscardPartial(ADstFs, tempPath);
      FailItem(AItem, attrErr);
      Exit;
    end;

    // C'est a la fermeture qu'un serveur avoue son quota ou sa coupure. Elle
    // compte meme apres un echec, sinon l'onglet se croit encore connecte.
    ADstFs.Close(dstH, closeErr);
    dstH := nil;
    if (closeErr.Kind <> sekNone) and (okCopy or
       (IsFatalToSession(closeErr.Kind) and (not IsFatalToSession(err.Kind))))
    then
    begin
      okCopy := False;
      err := closeErr;
    end;
    ASrcFs.Close(srcH, closeErr);
    srcH := nil;
    // Contenu complet: seule une COUPURE compte ici, et la reprise n'aura qu'a publier.
    if IsFatalToSession(closeErr.Kind) and (not IsFatalToSession(err.Kind))
    then
    begin
      okCopy := False;
      err := closeErr;
    end;

    if not okCopy then
    begin
      FailItem(AItem, err);
      Exit;
    end;

    // Derniere chance AVANT la cible. Passe ce point, publie = termine.
    if AItem.CancelRequested then
    begin
      AItem.Error := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName,
        '');
      FQueue.SetState(AItem, tsCanceled);
      Exit;
    end;

    // Le rename passe par le NOM. Un fichier substitue de meme taille passerait:
    // c'est la limite d'un rename par chemin.
    if not ADstFs.Stat(tempPath, False, dstEntry, err) then
    begin
      FailItem(AItem, err);
      Exit;
    end;
    if dstEntry.IsLink or dstEntry.IsDir or dstEntry.IsSpecial or
       ((dstEntry.Size >= 0) and (dstEntry.Size <> AItem.DoneBytes)) then
    begin
      FailItem(AItem, MakeScpError(sekOther, 'Publishing', AItem.DisplayName,
        'the temporary file changed before it could be published'));
      Exit;
    end;

    if not CommitTemp(ADstFs, AItem, tempPath, targetPath, targetExisted,
       err) then
    begin
      FailItem(AItem, err);
      Exit;
    end;
    tempPath := '';

    if AItem.Warning <> '' then
      Note(AItem.Warning);

    FQueue.SetState(AItem, tsCompleted);
    ReportProgress(AItem, True);
    Result := True;
  finally
    // Echec deja pose, mais une coupure revelee ici doit encore remonter.
    if dstH <> nil then
    begin
      ADstFs.Close(dstH, closeErr);
      NoteFatal(closeErr);
    end;
    if srcH <> nil then
    begin
      ASrcFs.Close(srcH, closeErr);
      NoteFatal(closeErr);
    end;
    // Le temporaire reste ENREGISTRE, sinon adieu la reprise.
  end;
end;

function TScpTransferEngine.CleanupPartials(
  ADstFs: TScpFileSystem): TStringArray;
var
  i, n: Integer;
  p: TScpPartial;
  err: TScpError;
begin
  Result := nil;
  n := 0;
  i := 0;
  while i < FPartials.ActiveCount do
  begin
    p := FPartials.ActiveAt(i);
    if p.DestIdentity <> ADstFs.DisplayName then
    begin
      Inc(i);
      Continue;
    end;
    if ADstFs.DeleteTemp(p.TempPath, err) then
      FPartials.Forget(p.TempPath)
    else
    begin
      SetLength(Result, n + 1);
      Result[n] := p.TempPath;
      Inc(n);
      Inc(i);
    end;
  end;
end;

end.
