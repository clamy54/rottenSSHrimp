{ Moteur de transfert de l'onglet Scp: enumeration recursive et copie d'un
  fichier, ecrits contre uScpBackend et donc entierement testables sans reseau.

  Une cible valide n'est JAMAIS remplacee par un transfert incomplet: on ecrit
  dans un temporaire du dossier de destination, on vide, on ferme, et alors
  seulement on remplace atomiquement. Les autres garanties -- droits conserves,
  reprise verifiee par empreinte, liens jamais suivis, confinement sous la
  racine choisie -- sont documentees la ou chacune est tenue.

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
  // Au-dela de l'annonce du serveur on continue -- un journal qui grossit --
  // mais pas indefiniment: c'est la borne contre un disque qu'on remplit.
  SCP_GROWTH_SLACK = Int64(64) * 1024 * 1024;
  SCP_PROGRESS_MS = 100;
  // Periode de vidage du tampon, qui confirme l'offset de reprise. Trop petit:
  // le debit s'effondre; trop grand, une coupure fait resservir l'intervalle.
  SCP_CONFIRM_EVERY = Int64(4) * 1024 * 1024;
  // Elements en file, tous lots confondus. Les bornes par dossier et par
  // profondeur n'arretent pas un arbre tres large; au-dela, la selection en
  // cours est ecartee entiere plutot qu'a moitie.
  SCP_MAX_QUEUE_ITEMS = 500000;

type
  // Empreinte BLAKE2b (libsodium): elle decide si deux contenus sont les memes,
  // et doit tenir face a une substitution voulue, pas seulement a un accident.
  TScpDigest = array[0..31] of Byte;

  // Empreinte en cours. L'etat de libsodium est opaque et aligne sur 64: il vit
  // dans un bloc a lui, et une lecture intermediaire travaille sur une COPIE.
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
    // Empreinte de ce qui a ete vu jusqu'ici, sans arreter le calcul.
    procedure Peek(out ADigest: TScpDigest);
  end;

  // Decision devant un conflit, sur le thread de travail. Peut bloquer le temps
  // que l'interface reponde, mais doit rendre la main sur annulation.
  TScpConflictEvent = procedure(const AInfo: TConflictInfo;
    var ADecision: TConflictDecision) of object;
  // Remplacement atomique impossible. AAllow=False par defaut: sans reponse
  // explicite, on ne degrade pas la garantie.
  TScpNonAtomicEvent = procedure(const ATargetPath: string;
    var AAllow: Boolean) of object;
  TScpProgressEvent = procedure(AItem: TTransferItem) of object;
  // Pour le resume: liens ignores, attributs non reposes, replis acceptes.
  TScpNoteEvent = procedure(const AText: string) of object;

  // Bilan d'un changement de droits, dit a la fin: sur une erreur au milieu
  // d'un dossier, ce qui a DEJA change ne doit pas passer pour intact.
  TScpChmodTally = record
    Applied: Integer;      // droits effectivement changes
    Unchanged: Integer;    // deja au mode demande: rien n'a ete envoye
    Links: Integer;        // liens laisses tels quels
  end;

  // Un partiel ecrit par CETTE session. Hors de cette liste aucune reprise n'est
  // proposee: un partiel d'origine inconnue produirait un fichier mixte.
  TScpPartial = record
    TempPath: string;
    TargetPath: string;
    // Identite du systeme de fichiers SOURCE: reprendre un partiel de srv-a avec
    // les octets de srv-b donnerait un fichier valide en apparence, faux dedans.
    SourceIdentity: string;
    // Et celle de la DESTINATION, seule a le nettoyer: un chemin POSIX local peut
    // exister a l'identique sur le serveur, ou l'homonyme serait supprime.
    DestIdentity: string;
    SourcePath: string;
    SourceSize: Int64;
    SourceTimeUtc: Int64;
    // Dernier offset CONFIRME: vide sur le support si possible, acquitte sinon.
    Confirmed: Int64;
    // Empreinte des Confirmed premiers octets ECRITS, relue et comparee a la
    // reprise: un partiel dont le contenu a change, meme a taille egale, est
    // refuse.
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
    // ADigest: empreinte des AOffset premiers octets ecrits.
    procedure Confirm(const ATempPath: string; AOffset: Int64;
      const ADigest: TScpDigest);
    procedure Forget(const ATempPath: string);
    // Publie, mais le nom temporaire n'a pas pu etre retire: il reste a nettoyer
    // et ne doit plus JAMAIS etre repris -- c'est un second nom du fichier publie.
    procedure Retire(const ATempPath: string);
    function Lookup(const ATempPath: string; out APartial: TScpPartial): Boolean;
    // Partiel reutilisable pour cette source exacte sur cette destination. Refuse
    // au moindre ecart; s'il en reste plusieurs, celui qui a confirme le plus.
    function FindResumable(const ATargetPath, ASourceIdentity, ADestIdentity,
      ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64;
      out APartial: TScpPartial): Boolean;
    // Temporaires actifs visant cette destination: ceux qu'un depart doit retirer.
    function ActiveForTarget(const ATargetPath,
      ADestIdentity: string): TStringArray;
    function ActiveCount: Integer;
    function ActiveAt(AIndex: Integer): TScpPartial;
    procedure Clear;
  end;

  // Ce qu'une resolution de conflit a DECIDE, et ce qu'elle a VU: l'etat observe
  // choisit la maniere de publier, pour ne pas remplacer un fichier apparu depuis.
  TScpConflictOutcome = record
    ResumeFrom: Int64;
    ResumeTemp: string;
    // Droits de la cible remplacee. PrevModeKnown distingue « inconnus » de
    // « reellement 0000 »: un fichier sans aucun droit doit en garder zero.
    PrevMode: LongWord;
    PrevModeKnown: Boolean;
    TargetExisted: Boolean;
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
    // Derniere erreur qui condamne la session, vue ou que ce soit.
    FFatal: TScpError;
    FHasFatal: Boolean;
    // Selection en cours d'examen. Son annulation arrete le parcours meme
    // quand aucun des deux systemes de fichiers ne la voit: une duplication
    // locale n'a que le disque, que « Cancel selected » ne touche pas.
    FWalkRoot: TTransferItem;
    FMaxQueueItems: Integer;
    FQueueFull: Boolean;

    procedure Note(const AText: string);
    procedure NoteFatal(const AErr: TScpError);
    // Un nouveau temporaire va viser cette destination: les partiels actifs qui la
    // visaient ne servent plus, et les garder multiplierait les points de reprise.
    procedure DropPartialsFor(ADstFs: TScpFileSystem;
      const ATargetPath: string);
    // Un partiel qui ne sert plus: retire du disque, et oublie SEULEMENT alors.
    procedure DiscardPartial(ADstFs: TScpFileSystem; const ATempPath: string);
    procedure PublishedTemp(AItem: TTransferItem; const ATempPath: string;
      var AErr: TScpError);
    function NameUsable(ASrcFs, ADstFs: TScpFileSystem; const AName: string;
      out AWhy: string): Boolean;
    // Un niveau du parcours. AOwner: l'element tikMakeDir du dossier. AKnown:
    // cibles deja en file, a ne pas remettre, quand on reprend un parcours coupe.
    function WalkDir(ASrcFs, ADstFs: TScpFileSystem;
      ADirection: TTransferDirection; const ASrcDir, ADstDir,
      ATargetRoot: string; ADepth, AMaxDepth: Integer; AOwner: TTransferItem;
      AKnown: TStrings; out AErr: TScpError): Boolean;
    procedure MarkScanCut(AOwner: TTransferItem; const AErr: TScpError);
    // Le parcours doit-il s'arreter AVANT d'aller plus loin? Annulation de la
    // selection ou du dossier parcouru, ou file pleine; AErr dit laquelle.
    function WalkMustStop(ASrcFs, ADstFs: TScpFileSystem;
      AOwner: TTransferItem; const ADir: string;
      out AErr: TScpError): Boolean;
    function WalkRootStopped(ASrcFs, ADstFs: TScpFileSystem): Boolean;
    // Annulation ou file pleine pendant un parcours: l'element s'arrete avec
    // tout ce qui a deja ete mis en file pour lui. True si c'est le cas.
    function StopScan(AItem: TTransferItem; const AErr: TScpError): Boolean;
    // Reprend le parcours d'un dossier dont le listing a ete coupe.
    function RescanDir(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      out AErr: TScpError): Boolean;
    // Examine une selection (tikScanRoot) et en fait ce qu'elle est.
    function ScanRoot(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      AMaxDepth: Integer; out AErr: TScpError): Boolean;
    // Pose l'etat qui correspond a l'erreur: annule, interrompu si la session est
    // perdue, echoue sinon. Une coupure rangee en « echec » interdirait la reprise.
    procedure FailItem(AItem: TTransferItem; const AErr: TScpError);
    procedure ReportProgress(AItem: TTransferItem; AForce: Boolean);
    // Copie proprement dite, source et cible deja ouvertes. AHash court sur les
    // octets ECRITS: fraiche pour un fichier neuf, nourrie du prefixe a la reprise.
    function CopyStream(ASrcFs: TScpFileSystem; ASrcH: TScpFileHandle;
      ADstFs: TScpFileSystem; ADstH: TScpFileHandle;
      AItem: TTransferItem; AExpected: Int64; AStartOffset: Int64;
      const ATempPath: string; AHash: TScpHash;
      out AErr: TScpError): Boolean;
    function ResolveConflict(ASrcFs, ADstFs: TScpFileSystem;
      AItem: TTransferItem; const ASrcEntry: TScpEntry;
      var ATargetPath: string; out AOutcome: TScpConflictOutcome;
      out AErr: TScpError): Boolean;
    // Un dossier n'a pas pu etre cree: tout ce qui devait y aller echoue avec lui,
    // tout de suite, plutot qu'un par un avec une raison qui egare.
    procedure FailSubtree(ADstFs: TScpFileSystem; AItem: TTransferItem);
    // Remplace la cible par le temporaire. L'absence de remplacement atomique se
    // DEMANDE, jamais ne se contourne, et l'annulation est relue apres l'attente.
    function CommitTemp(ADstFs: TScpFileSystem; AItem: TTransferItem;
      const ATempPath, ATargetPath: string; ATargetExisted: Boolean;
      out AErr: TScpError): Boolean;
    // Le partiel est-il encore ce qu'on croit? Fichier ordinaire, pas un lien, au
    // moins aussi long que l'offset confirme, pas plus que la source. False avec
    // AErr vide = il ne vaut plus rien (AWhy dit pourquoi); avec AErr = on n'a pas
    // pu le savoir, et il est a GARDER: une coupure n'est pas une disparition.
    function PartialUsable(ADstFs: TScpFileSystem; const ATempPath: string;
      AConfirmed, ASourceSize: Int64; out AWhy: string;
      out AErr: TScpError): Boolean;
    // Relit le prefixe confirme A TRAVERS la poignee rouverte et compare son
    // empreinte au registre; laisse AHash nourrie et la poignee a l'offset. False
    // avec AErr vide = partiel inutilisable, avec AErr = la relecture a echoue.
    function VerifyPartialPrefix(ADstFs: TScpFileSystem;
      ADstH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; AHash: TScpHash;
      out AWhy: string; out AErr: TScpError): Boolean;
    // Meme question pour la SOURCE, distante comprise.
    function VerifySourcePrefix(ASrcFs: TScpFileSystem;
      ASrcH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; out AWhy: string;
      out AErr: TScpError): Boolean;
  public
    constructor Create(AQueue: TTransferQueue);
    destructor Destroy; override;

    // Met ASourcePath en file et l'examine tout de suite: un fichier, ou un
    // dossier et son contenu, dossiers AVANT leur contenu. False seulement si
    // une coupure a interrompu le parcours; un refus donne un element ignore.
    // ATargetName renomme la RACINE du lot et elle seule, ce qui permet de
    // dupliquer sur place. Vide = le nom de la source.
    function EnumerateInto(ASrcFs, ADstFs: TScpFileSystem;
      ADirection: TTransferDirection;
      const ASourcePath, ATargetParent, ATargetRoot: string;
      AMaxDepth: Integer; out AErr: TScpError;
      const ATargetName: string = ''): Boolean;

    // Traite UN element. True s'il s'est termine normalement (Completed ou
    // Skipped); False s'il a echoue ou ete interrompu, son etat dit lequel.
    function RunItem(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      const ATargetRoot: string): Boolean;

    // Supprime les temporaires ouverts SUR CE systeme de fichiers quand c'est sans
    // risque, et rend ceux qu'il a fallu laisser. Les autres ne sont pas touches.
    function CleanupPartials(ADstFs: TScpFileSystem): TStringArray;

    // Rend, et efface, la derniere erreur qui condamne la session: un element
    // « termine » peut avoir vu la connexion tomber juste apres sa publication.
    function TakeFatal(out AErr: TScpError): Boolean;

    property Partials: TScpPartialRegistry read FPartials;
    property ConfirmEvery: Int64 read FConfirmEvery write FConfirmEvery;
    property MaxQueueItems: Integer read FMaxQueueItems write FMaxQueueItems;
    // La file peut-elle recevoir ACount selections de plus? Une commande est
    // acceptee entiere ou pas du tout. Le compte ne peut que baisser entre ce
    // test et les ajouts: seul le fil de transfert ajoute, l'interface retire.
    function CanEnqueue(ACount: Integer): Boolean;
    property OnConflict: TScpConflictEvent read FOnConflict write FOnConflict;
    property OnNonAtomic: TScpNonAtomicEvent
      read FOnNonAtomic write FOnNonAtomic;
    property OnProgress: TScpProgressEvent read FOnProgress write FOnProgress;
    property OnNote: TScpNoteEvent read FOnNote write FOnNote;
  end;

function FreeCopyName(AFs: TScpFileSystem; const ADir, AName: string;
  out AErr: TScpError): string;

// Pose des droits sur APath et, si ARecursive, sur le contenu des dossiers.
// Les liens restent tels quels: SETSTAT les traverse. Chaque dossier est relu
// apres son listing et avant ses propres droits, chaque fichier juste avant:
// cela RESSERRE la fenetre ou un nom devient lien sans la fermer, le protocole
// n'ayant ni lchmod ni poignee de dossier. Un mode deja bon n'est pas renvoye.
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
  // Taille ou date inconnue: la concordance est indemontrable, donc refusee.
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

// Droits d'un fichier NEUF d'apres sa source: lecture et ecriture seulement.
// Jamais d'ecriture pour tous, jamais de setuid/setgid/sticky, et jamais les
// bits d'EXECUTION -- un script telecharge ne devient pas executable ici sans
// qu'on l'ait demande. Un mode INCONNU (Windows, serveur muet) donne le
// defaut. Un mode connu et NUL en est un: une source sans aucun droit donne
// un fichier sans aucun droit.
function ModeForNewFile(ASourceMode: LongWord; AModeKnown: Boolean): LongWord;
begin
  if not AModeKnown then Exit(SCP_DEFAULT_FILE_MODE and LongWord(&0664));
  Result := ASourceMode and LongWord(&0664);
end;

// Droits d'un fichier REMPLACE: ceux qu'il avait, lecture, ecriture et
// execution comprises -- jusqu'a l'ecriture pour tous, qui etait son choix.
// Jamais setuid, setgid ni sticky: un contenu nouveau sous un bit eleve est un
// autre programme qui herite du privilege.
function ModeForReplacedFile(APrevMode: LongWord): LongWord;
begin
  Result := APrevMode and LongWord(&0777);
end;

// Droits d'un dossier NEUF: ceux de sa source, sans ecriture pour tous ni bits
// speciaux, et toujours rwx pour le proprietaire -- il faut pouvoir y ecrire ce
// qui suit. Poses A LA CREATION: un dossier prive l'est des qu'il existe, et
// non apres que son contenu a ete lisible par tous. Mode inconnu: le defaut.
// Mode connu et nul: 0700, jamais le defaut ouvert.
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
    // Un second temporaire pour la meme cible laisserait deux « .part », et la
    // reprise prendrait plus tard celui des deux qu'elle trouve en premier.
    // Oublie seulement ce qui est parti: un partiel qu'on n'a pas pu retirer
    // doit rester nettoyable a la fermeture.
    if ADstFs.DeleteFile(stale[i], err) or (err.Kind = sekNotFound) then
      FPartials.Forget(stale[i]);
  end;
end;

procedure TScpTransferEngine.DiscardPartial(ADstFs: TScpFileSystem;
  const ATempPath: string);
var
  err: TScpError;
begin
  if ADstFs.DeleteFile(ATempPath, err) or (err.Kind = sekNotFound) then
    FPartials.Forget(ATempPath);
end;

// Le contenu est publie. Un temporaire que le rename n'a pas su retirer reste
// enregistre pour la fermeture, sans plus jamais servir de reprise, et
// l'element le dit.
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
  // Sans ce filtre, un fichier rapide noie l'interface et ralentit a cause de
  // son propre affichage.
  if (not AForce) and (now_ - FLastProgressTick < SCP_PROGRESS_MS) then Exit;
  FLastProgressTick := now_;
  FOnProgress(AItem);
end;

// --- Enumeration ----------------------------------------------------------

// Nom acceptable des DEUX cotes: les deux controles different.
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

// AOwner: l'element tikMakeDir du dossier. Un dossier inenumerable ne
// disparait pas du bilan, il passe a « ignore » avec sa raison.
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

  // Un enfant ecarte entre dans la file a l'etat « ignore » avec sa raison: une
  // note seule laisserait le bilan annoncer un lot complet. Le chemin retenu est
  // celui du DOSSIER, fabriquer le sien a partir d'un nom refuse n'aurait pas de
  // sens.
  procedure SkipChild(const AChildSrc, AName: string;
    const AChildErr: TScpError);
  var
    sk: TTransferItem;
  begin
    sk := FQueue.Add(ADirection, tikFile, AChildSrc, ADstDir,
      DisplaySafeName(AName), AOwner.Batch, AOwner);
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
    // Profondeur bornee: sans elle une arborescence fabriquee epuise la pile.
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
    // Un dossier illisible ne condamne pas le lot: note, saute, sa raison dite.
    Note(ScpErrorText(err));
    if IsFatalToSession(err.Kind) then
    begin
      // Une COUPURE n'est pas un dossier illisible: elle REMONTE, pour que le
      // transport declare la session perdue, et le dossier reste A PARCOURIR.
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
    // Ecarte AVEC sa raison: le laisser « en attente » le creerait vide et
    // reussi.
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
    // CaseSensitive AVANT Sorted, et True: CollisionKey a deja replie les cles
    // selon la DESTINATION. Comparer sans la casse par-dessus ferait passer tout
    // serveur POSIX pour un Windows, et « README » masquerait « readme ».
    seen.CaseSensitive := True;
    seen.Sorted := True;
    seen.Duplicates := dupIgnore;
    for i := 0 to High(entries) do
    begin
      // Avant CHAQUE ajout: une annulation ne laisse entrer personne apres elle.
      if WalkMustStop(ASrcFs, ADstFs, AOwner, ASrcDir, AErr) then Exit;
      e := entries[i];
      if not NameUsable(ASrcFs, ADstFs, e.Name, why) then
      begin
        Note(why);
        SkipChild(ASrcFs.Join(ASrcDir, e.Name), e.Name,
          MakeScpError(sekInvalidName, 'Copying',
            DisplaySafeName(e.Name), why));
        Continue;
      end;
      // Deux noms distincts visant un seul fichier ici: le second ecraserait le
      // premier sans qu'on l'ait demande.
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
      // Reprise d'un parcours coupe: ce qui est deja en file n'y entre pas deux
      // fois, et un sous-dossier deja en file se reprend par lui-meme.
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
      // Un nom court et une jointure repetee font quand meme un chemin trop long:
      // on s'arrete ici, avec la raison, plutot qu'au moment d'ecrire.
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
        // Le serveur n'a pas dit: lire un dossier comme un fichier ne se rattrape pas.
        SkipChild(childSrc, e.Name,
          MakeScpError(sekOther, 'Copying', DisplaySafeName(e.Name),
            'the server did not say whether this is a file or a folder'));
        Continue;
      end;
      if e.IsLink then
      begin
        // Jamais suivi: un cycle devient impossible plutot que detectable.
        item := FQueue.Add(ADirection, tikFile, childSrc, childDst,
          DisplaySafeName(e.Name), AOwner.Batch, AOwner);
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.Error := MakeScpError(sekSymlinkSkipped, 'Copying',
          DisplaySafeName(e.Name), e.LinkTarget);
        FQueue.SetState(item, tsSkipped);
        Continue;
      end;
      if e.IsSpecial then
      begin
        item := FQueue.Add(ADirection, tikFile, childSrc, childDst,
          DisplaySafeName(e.Name), AOwner.Batch, AOwner);
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.Error := MakeScpError(sekIsSpecialFile, 'Copying',
          DisplaySafeName(e.Name), '');
        FQueue.SetState(item, tsSkipped);
        Continue;
      end;
      if e.IsDir then
      begin
        // Le listing l'a vu dossier; lstat le revoit juste avant d'y descendre. Entre
        // les deux il a pu devenir un lien, dont le contenu partirait dans le lot.
        if not ASrcFs.Stat(childSrc, False, e2, err) then
        begin
          if IsFatalToSession(err.Kind) then
          begin
            // Toute sortie sur coupure marque le dossier parcouru: sinon, deja
            // en file, il passerait pour parcouru a la reprise.
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
        // L'ordre d'insertion EST la garantie que les parents precedent les enfants.
        item := FQueue.Add(ADirection, tikMakeDir, childSrc, childDst,
          DisplaySafeName(e.Name), AOwner.Batch, AOwner);
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
            // Seul ce sous-dossier est annule: ce qui est deja en file sous lui
            // l'est avec lui, et le parcours continue a cote.
            FQueue.CancelItem(item);
            AErr := NoScpError;
            Continue;
          end;
          // Annulation ou file pleine: rien a reprendre, RunItem conclut.
          if (AErr.Kind = sekCanceled) or FQueueFull then Exit;
          // Coupe dans un sous-dossier: celui-ci non plus n'a pas ete parcouru
          // jusqu'au bout. Sa reprise sautera ce qui est deja en file.
          MarkScanCut(AOwner, AErr);
          Exit;
        end;
        Continue;
      end;
      item := FQueue.Add(ADirection, tikFile, childSrc, childDst,
        DisplaySafeName(e.Name), AOwner.Batch, AOwner);
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
  Result := True;
end;

// Un dossier dont le listing a ete coupe par la session: interrompu AVEC le
// drapeau qui fera reprendre son parcours, pas ecarte.
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
  if FQueue.Count >= FMaxQueueItems then
  begin
    FQueueFull := True;
    AErr := MakeScpError(sekOther, 'Scanning', DisplaySafeName(ADir),
      Format('the queue would hold more than %d items', [FMaxQueueItems]));
    Exit(True);
  end;
  Result := False;
end;

function TScpTransferEngine.StopScan(AItem: TTransferItem;
  const AErr: TScpError): Boolean;
begin
  Result := FQueueFull or AItem.CancelRequested or (AErr.Kind = sekCanceled);
  if not Result then Exit;
  // L'etat de l'element d'abord, puis CancelItem balaie ce qui est deja en
  // file sous lui, y compris ce qu'un ajout concurrent de la demande aurait
  // laisse passer. Dans l'autre ordre, il serait « annule » avant d'etre dit
  // ecarte.
  if FQueueFull then
  begin
    FQueueFull := False;
    // Ecarte, pas en echec: « Retry failed » ne doit pas recreer le dossier
    // vide et le dire reussi.
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
  // lstat encore: le dossier a pu devenir un lien depuis le listing coupe.
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
    // Les descendants de CE dossier: un autre lot vers le meme endroit n'est
    // pas « deja en file », il est un autre transfert.
    subtree := TFPList.Create;
    try
      FQueue.Lock;
      try
        FQueue.CollectDescendantsLocked(AItem, subtree);
        for i := 0 to subtree.Count - 1 do
        begin
          it := TTransferItem(subtree[i]);
          // Un sous-dossier encore a parcourir se reprendra par lui-meme.
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

// Premier nom de copie libre dans ADir; '' si tous sont pris, ou si la question
// n'a pas pu etre posee (AErr le dit). La reponse vieillit aussitot: c'est la
// creation exclusive qui rattrape une collision.
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
    // Devenu lien entre le lstat et le listing, le dossier aurait fait lister
    // sa cible.
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
    // Le dossier passe APRES son contenu -- se retirer r ou x d'abord fermerait
    // la porte sur ce qu'il reste a faire -- et il est relu juste avant.
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

// Une selection encore inconnue: lstat, nom, confinement, puis l'element
// DEVIENT le fichier ou le dossier qu'il designe -- ou s'ecarte avec sa
// raison, ce qui le garde au bilan. Une coupure le laisse tel quel, a
// reprendre: c'est ce qui rend une enumeration coupee reprenable. False =
// coupure, l'element est deja interrompu.
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

  // lstat: c'est le lien lui-meme qu'on veut voir, pas ce qu'il designe.
  if not ASrcFs.Stat(AItem.SourcePath, False, srcEntry, e) then
  begin
    // Illisible: l'element reste, avec sa raison. Une coupure l'interrompt, a
    // reprendre a la reconnexion; un autre refus le laisse en echec.
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
    // Le nom impose passe par les regles de la DESTINATION comme un autre: il
    // vient d'un calcul, pas d'une garantie.
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
    // Le nom libre est cherche ICI, par le fil qui copie: choisi plus tot, il
    // serait perime avant l'ecriture.
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
    // Coupe en route: le dossier est deja interrompu, a reparcourir.
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

// --- Conflits -------------------------------------------------------------

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
    // Pas de conflit, mais un fichier NEUF interrompu est le cas ordinaire d'une
    // reprise: l'ignorer ferait tout recommencer a chaque coupure.
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

  // La cible existe: decrire les DEUX cotes, sinon le choix est aveugle. lstat
  // d'abord, un lien ici sera REMPLACE par le rename et non suivi.
  AOutcome.TargetExisted := True;
  info := Default(TConflictInfo);
  info.SourcePath := AItem.SourcePath;
  info.TargetPath := ATargetPath;
  info.SourceSize := ASrcEntry.Size;
  info.SourceTimeUtc := ASrcEntry.MTimeUtc;
  info.TargetSize := -1;
  if not ADstFs.Stat(ATargetPath, False, dstEntry, statErr) then
  begin
    // Quelque chose est la sans qu'on puisse dire quoi. La remplacer sans le
    // savoir pourrait elargir un 0000, ecraser un dossier ou masquer une coupure.
    AErr := statErr;
    Exit;
  end;
  if dstEntry.IsDir then
  begin
    // Ecraser un dossier par un fichier n'est pas un conflit ordinaire.
    AErr := MakeScpError(sekAlreadyExists, 'Copying',
      DisplaySafeName(ATargetPath),
      'the destination is a folder, not a file');
    Exit;
  end;
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
    AOutcome.PrevMode := dstEntry.Mode and LongWord(&07777);
    // Mode LU: zero veut dire « aucun droit » et doit le rester.
    AOutcome.PrevModeKnown := dstEntry.ModeKnown;
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
  // « Resume » pour tout le lot ne vaut que la ou un partiel concorde: ailleurs
  // on REDEMANDE, plutot que de sauter en silence.
  if (decision.Action = cnResume) and (not info.ResumeAllowed) then
    decision.Action := cnAsk;
  decision.ApplyToAll := decision.Action <> cnAsk;
  if decision.Action = cnAsk then
  begin
    if not Assigned(FOnConflict) then
    begin
      // Sans interlocuteur, on ne devine pas: la cible reste intacte.
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
            // Le nom retenu n'existait pas: la publication doit le creer sans ecraser.
            AOutcome.TargetExisted := False;
            AOutcome.PrevMode := 0;
            AOutcome.PrevModeKnown := False;
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
    // cnAsk rendu tel quel: l'interface n'a pas tranche, on n'ecrit rien.
    AItem.Error := MakeScpError(sekAlreadyExists, 'Copying',
      DisplaySafeName(ATargetPath), 'no decision was made');
    FQueue.SetState(AItem, tsSkipped);
  end;
end;

// --- Copie ----------------------------------------------------------------

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
    // Sans ce test, « Cancel selected » ne serait qu'un changement d'etiquette et
    // la copie irait jusqu'a remplacer la cible.
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
    // Un offset n'est CONFIRME qu'une fois vide sur le support: reprendre sur des
    // octets restes en tampon, c'est reprendre apres un trou. L'empreinte est
    // prise sur une COPIE du contexte, finaliser le courant l'arreterait.
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

  // Fin de flux avant la taille annoncee: source tronquee ou remplacee depuis
  // le listing. Ne pas remplacer la cible.
  if (AExpected >= 0) and (total < AExpected) then
  begin
    AErr := MakeScpError(sekPrematureEof, 'Copying', AItem.DisplayName,
      Format('%d bytes read, %d announced', [total, AExpected]));
    Exit;
  end;

  AItem.DoneBytes := total;
  // La taille annoncee peut etre fausse: ce qui a ete ecrit compte.
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
  // lstat: c'est le chemin qu'on juge. Un lien pose a la place du partiel ferait
  // ecrire la suite ailleurs.
  if not ADstFs.Stat(ATempPath, False, e, err) then
  begin
    // « Absent » est une reponse, tout le reste est une panne: prendre une coupure
    // pour une disparition laisserait le partiel orphelin sur le disque.
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
  // Plus court que le confirme: tronque depuis. Rouvrir l'etendrait de zeros
  // jusqu'a l'offset, pour un fichier de bonne taille au contenu faux.
  if (e.Size >= 0) and (e.Size < AConfirmed) then
  begin
    AWhy := 'it is shorter than the confirmed offset';
    Exit;
  end;
  // Plus long que la SOURCE: rien ne recouvrira l'excedent, et une destination
  // qui ne sait pas tronquer (SFTP v3) publierait cette queue.
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
  // Par la poignee qui va ecrire, pas par le chemin: entre un lstat et une
  // ouverture le chemin peut changer de fichier.
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
    // Meme taille, autre contenu: un fichier de bonne longueur et faux dedans.
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
      // Meme taille, meme date, autre contenu: poursuivre collerait un ancien debut
      // a une nouvelle fin.
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
  // Un refus de DROIT n'est pas une absence de fonctionnalite: un repli ne
  // detruirait la cible que pour buter sur le meme refus.
  if AErr.Kind <> sekUnsupported then Exit;

  // Posee POUR CE FICHIER, jamais pour le lot: le repli supprime la cible avant
  // de renommer, et retenir la reponse detruirait -- ou bloquerait -- en silence.
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
  // La question a pu rester posee longtemps: une annulation arrivee entre-temps
  // compte encore, la cible n'ayant pas ete touchee.
  if AItem.CancelRequested then
  begin
    AErr := MakeScpError(sekCanceled, 'Replacing',
      DisplaySafeName(ATargetPath), '');
    Exit(False);
  end;

  // Repli assume: supprimer puis renommer. Seule fenetre ou la cible n'existe
  // plus, et elle n'est ouverte qu'apres un accord explicite.
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
    // Connexion perdue: l'element n'a pas echoue, il est INTERROMPU. Cet etat
    // laisse la reprise possible et dit au transport que la session est finie.
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
      // La cause du dossier est celle de ses enfants: en « echec », seul le dossier
      // repartirait et son contenu resterait a quai.
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
  targetExisted, found, okCopy: Boolean;
  v: TNameVerdict;
  prevMode, newMode, tempMode: LongWord;
  why: string;
  digest: TScpDigest;
  partial: TScpPartial;
  outcome: TScpConflictOutcome;
  scanned: Boolean;

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

  // Une selection pas encore examinee: elle devient ici fichier ou dossier,
  // ou s'ecarte avec sa raison. Une coupure la laisse a reprendre telle quelle.
  if AItem.Kind = tikScanRoot then
  begin
    // « Scanning »: une annulation pendant l'examen DEMANDE l'arret, et c'est
    // le parcours qui s'arrete, au lieu que la ligne passe a « annule » sous
    // un parcours qui continue d'ajouter des enfants.
    if not FQueue.SetState(AItem, tsEnumerating) then Exit;
    scanned := ScanRoot(ASrcFs, ADstFs, AItem, SCP_MAX_DEPTH, err);
    if StopScan(AItem, err) then Exit;
    if not scanned then
    begin
      // Filet: une coupure ne laisse jamais la selection en « Scanning »,
      // ni reprise ni conclue.
      if AItem.State = tsEnumerating then
        MarkScanCut(AItem, err);
      NoteFatal(err);
      Exit;
    end;
    if AItem.IsTerminal then Exit(AItem.State = tsSkipped);
    if AItem.State = tsFailed then Exit;
  end;

  targetPath := AItem.TargetPath;
  // A chaque element, pas seulement a l'enumeration: un dossier a pu devenir
  // un lien entre les deux.
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
    // Refus = l'interface l'a annule entre-temps: l'etat est deja pose.
    if not FQueue.SetState(AItem, tsTransferring) then Exit;
    if not ADstFs.Exists(targetPath, found, err) then
    begin
      FailItem(AItem, err);
      FailSubtree(ADstFs, AItem);
      Exit;
    end;
    if found then
    begin
      // Un dossier present n'est pas un conflit. lstat et pas stat: un LIEN ici
      // conduirait le contenu ailleurs, et le controle lexical ne le voit pas.
      if not ADstFs.Stat(targetPath, False, dstEntry, err) then
      begin
        // Quelque chose est la sans qu'on sache quoi: le declarer pret enverrait tout
        // son contenu vers un endroit que personne n'a verifie.
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
      // La source est relue ICI: son parcours a pu etre long. Disparue, elle
      // serait creee vide; passee en 0700, trop ouverte; devenue lien, elle
      // n'est plus ce qu'on a parcouru.
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
      if not ADstFs.MakeDir(targetPath,
         ModeForNewDir(AItem.SourceMode, AItem.SourceModeKnown), err) then
      begin
        FailItem(AItem, err);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
      if (ASrcFs = ADstFs) and
         (not ADstFs.CopyProtectionFrom(AItem.SourcePath, targetPath, err)) then
      begin
        // Vide, il n'a rien expose: il part, et son contenu n'ira nulle part.
        ADstFs.DeleteDir(targetPath, closeErr);
        FailItem(AItem, err);
        FailSubtree(ADstFs, AItem);
        Exit;
      end;
    end;
    // Listing coupe par la session: le dossier existe, son contenu reste a
    // mettre en file. Ce qui y est deja n'y entre pas deux fois.
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

  // lstat encore: la source a pu devenir un lien depuis l'enumeration.
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
  // L'etat VU pendant la decision, pas un second Exists: un fichier apparu entre
  // les deux serait remplace sans que personne l'ait vu. Une cible vue absente
  // se publie par un rename qui REFUSE d'ecraser.
  targetExisted := outcome.TargetExisted;

  // Refus = annule par l'interface pendant qu'on preparait: rien n'est ecrit.
  if not FQueue.SetState(AItem, tsTransferring) then Exit;
  parentDir := ADstFs.Parent(targetPath);
  // Le mode d'un fichier NEUF est donne A LA CREATION du temporaire, ce qui
  // laisse l'umask le restreindre; un chmod apres coup passerait outre. Si une
  // cible EXISTE, le temporaire nait en 0600 et recoit les droits de la cible
  // juste avant la publication.
  newMode := ModeForNewFile(srcEntry.Mode, srcEntry.ModeKnown);
  tempMode := newMode;
  if targetExisted then tempMode := LongWord(&0600);
  try
    if not ASrcFs.OpenRead(AItem.SourcePath, srcH, err) then
    begin
      // Listee mais refusee a l'ouverture: une cause a part, que « dossier
      // illisible » ferait chercher au mauvais endroit.
      if err.Kind = sekAccessDeniedDir then
        err.Kind := sekAccessDeniedRead;
      FailItem(AItem, err);
      Exit;
    end;

    if (resumeFrom > 0) and (resumeTemp <> '') then
    begin
      tempPath := resumeTemp;
      // Le registre dit ce que le partiel ETAIT, le disque ce qu'il est: tronque,
      // devenu lien ou autre chose, on repart de zero.
      if not PartialUsable(ADstFs, tempPath, resumeFrom, srcEntry.Size, why,
         err) then
      begin
        if err.Kind <> sekNone then
        begin
          // Partiel non jugeable: il reste enregistre et l'element s'arrete la.
          FailItem(AItem, err);
          Exit;
        end;
        Note(Format('The partial file for %s cannot be resumed (%s); ' +
          'starting over.', [AItem.DisplayName, why]));
        // Le nom est le notre et ce qu'il contient ne sert plus. Un lien se retire
        // lui-meme, jamais ce qu'il designe.
        DiscardPartial(ADstFs, tempPath);
        tempPath := '';
        resumeFrom := 0;
      end
      else if not ADstFs.OpenAppend(tempPath, resumeFrom, dstH, err) then
      begin
        if IsFatalToSession(err.Kind) then
        begin
          // Session tombee: le partiel est intact, en creer un autre n'a pas de sens.
          FailItem(AItem, err);
          Exit;
        end;
        Note(Format('The partial file for %s could not be reopened (%s); ' +
          'starting over.', [AItem.DisplayName, ScpErrorText(err)]));
        // Un « .part » qu'on ne rouvre pas ne sert plus, et se decouvre bien tard.
        DiscardPartial(ADstFs, tempPath);
        tempPath := '';
        resumeFrom := 0;
      end
      else
      begin
        // Le fichier rouvert est-il celui qu'on a ecrit? Un lstat repond sur un
        // chemin; relire le prefixe par cette poignee repond sur le FICHIER.
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
          // Reste la SOURCE: meme chemin, meme taille, meme date a la seconde ne disent
          // pas « meme contenu ». Son prefixe est relu et compare, distante comprise:
          // cela coute alors le telechargement que la reprise economisait, mais un
          // ancien debut colle a une nouvelle fin serait un fichier faux dit reussi.
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
      // Nouveau depart: les partiels qui visaient cette cible ne seront jamais
      // repris et ne doivent pas rester.
      DropPartialsFor(ADstFs, targetPath);
      // Temporaire DANS le dossier de destination: ailleurs le rename traverserait
      // un systeme de fichiers et cesserait d'etre atomique.
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
      // Copie sur place: la protection de la source, la ou les modes ne la
      // portent pas, est posee avant le premier octet.
      if (ASrcFs = ADstFs) and (not targetExisted) and
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

    // Vider AVANT de conclure: un disque plein ne se revele souvent qu'ici, et
    // conclure avant remplacerait une cible valide par un fichier tronque.
    if okCopy then
      okCopy := ADstFs.Flush(dstH, err);
    if okCopy then
    begin
      FHash.Peek(digest);
      FPartials.Confirm(tempPath, AItem.DoneBytes, digest);
    end;

    // Droits et date par la POIGNEE, avant de la fermer: ferme, le temporaire
    // n'est plus designe que par son nom, et un tiers qui ecrit dans le dossier
    // peut y glisser autre chose entre deux appels. Le rename les conserve.
    // Un fichier REMPLACE garde ses droits: un 0600 devenu 0644 est une fuite.
    // S'ils ne peuvent pas etre reposes, la cible n'est pas remplacee.
    if okCopy and targetExisted then
    begin
      if not outcome.PrevModeKnown then
        // Les droits de la cible n'ont pas pu etre lus: le temporaire garde ceux
        // d'un fichier neuf, ce qui ne divulgue rien, mais « garde ses droits »
        // n'est pas tenu et il faut le dire.
        AddWarning(ScpErrorText(MakeScpError(sekAttrRefused,
          'Setting the mode of', AItem.DisplayName,
          'the permissions of the existing file could not be read; the new ' +
          'content was published with the permissions of a new file')))
      else if not ADstFs.SetMode(dstH, ModeForReplacedFile(prevMode), attrErr)
      then
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
    // Un refus ordinaire de la date est un avertissement; une coupure
    // interrompt, le partiel etant confirme jusqu'au bout.
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

    // La fermeture est ou un serveur avoue un quota depasse, et ou une coupure
    // se revele: elle compte meme apres un echec, sinon l'element passe en
    // « echec » et l'onglet se croit connecte.
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
    // Le contenu est complet: un refus a la fermeture de la source ne change
    // rien. Une COUPURE, elle, interrompt l'element; la reprise n'aura qu'a
    // publier.
    if IsFatalToSession(closeErr.Kind) and (not IsFatalToSession(err.Kind))
    then
    begin
      okCopy := False;
      err := closeErr;
    end;

    if not okCopy then
    begin
      // Perte de connexion: interrompu, pas echoue, et le partiel reste enregistre.
      FailItem(AItem, err);
      Exit;
    end;

    // Derniere chance de s'arreter AVANT de toucher la cible; CommitTemp relit la
    // demande une fois de plus si une question a ete posee. Passe ces controles la
    // publication va au bout: un element publie est termine.
    if AItem.CancelRequested then
    begin
      AItem.Error := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName,
        '');
      FQueue.SetState(AItem, tsCanceled);
      Exit;
    end;

    // Le temporaire va etre designe par son NOM une derniere fois, pour le
    // rename: on revoit ce que ce nom designe. Un lien, un dossier ou une autre
    // taille sont refuses; un autre fichier ordinaire de meme taille passerait,
    // et c'est la limite d'un rename par chemin.
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

    // A partir d'ici le contenu EST arrive.
    if AItem.Warning <> '' then
      Note(AItem.Warning);

    FQueue.SetState(AItem, tsCompleted);
    ReportProgress(AItem, True);
    Result := True;
  finally
    // Ces fermetures suivent un echec deja pose; une coupure qu'elles revelent
    // compte quand meme, pour que le transport declare la session perdue.
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
    // Le temporaire reste ENREGISTRE: le supprimer ici interdirait la reprise.
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
    if ADstFs.DeleteFile(p.TempPath, err) then
      FPartials.Forget(p.TempPath)
    else
    begin
      // Impossible de le retirer: le dire. Un partiel taise est pire qu'un partiel
      // signale.
      SetLength(Result, n + 1);
      Result[n] := p.TempPath;
      Inc(n);
      Inc(i);
    end;
  end;
end;

end.
