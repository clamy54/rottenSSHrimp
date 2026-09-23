{ File de transferts de l'onglet Scp: modele et machine a etats, PURS. Ni LCL,
  ni reseau, ni disque, ce qui permet de tester ici les cas qu'un serveur reel
  ne produit qu'au mauvais moment.

  La file est PARTAGEE entre le fil qui transfere et celui qui affiche: tout
  parcours et toute modification passent par le verrou, chaines comprises.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uTransferQueue;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, uScpErrors;

type
  TTransferQueue = class;

  // Le sens designe aussi les deux systemes de fichiers, et rien d'autre ne les
  // choisit. Une duplication a le meme des deux cotes, d'ou DEUX valeurs:
  // « ni envoi ni reception » ne dirait pas lequel.
  TTransferDirection = (tdUpload, tdDownload,
    tdDuplicateLocal, tdDuplicateRemote);

  // tikMakeDir precede ses enfants: c'est l'ordre d'insertion qui le garantit.
  TTransferItemKind = (tikFile, tikMakeDir);

  TTransferState = (
    tsPending,
    tsEnumerating,
    tsTransferring,
    tsPaused,
    tsInterrupted,   // connexion perdue en cours: reprise possible
    tsRetrying,
    tsSkipped,
    tsFailed,
    tsCompleted,
    tsCanceled);

  TTransferStates = set of TTransferState;

  TConflictAction = (
    cnAsk,          // aucune decision prise: il faut demander
    cnOverwrite,
    cnSkip,
    cnKeepBoth,
    cnResume,
    cnCancelQueue);

  TConflictDecision = record
    Action: TConflictAction;
    ApplyToAll: Boolean;
  end;

  // La cible existante au moment du conflit: sert au dialogue et a la reprise.
  TConflictInfo = record
    SourcePath: string;
    TargetPath: string;
    SourceSize: Int64;
    TargetSize: Int64;
    SourceTimeUtc: Int64;   // secondes Unix, 0 = inconnu
    TargetTimeUtc: Int64;
    // Un partiel ecrit par nous, aux metadonnees concordantes? Seul cas ou
    // Resume est offert.
    ResumeAllowed: Boolean;
    ResumeOffset: Int64;
    ResumeRefusedWhy: string;
  end;

  TTransferItem = class
  private
    FId: Integer;
    FDirection: TTransferDirection;
    FKind: TTransferItemKind;
    FSourcePath: string;
    FTargetPath: string;
    FDisplayName: string;
    FTotalBytes: Int64;
    FDoneBytes: Int64;
    FState: TTransferState;
    FError: TScpError;
    FWarning: string;
    FSourceTimeUtc: Int64;
    FSourceMode: LongWord;
    FAttempts: Integer;
    FDepth: Integer;
    // Dossier de destination CHOISI par l'utilisateur, hors duquel rien ne sera
    // ecrit. Pose une fois a la mise en file: le rededuire a l'execution donnerait
    // une garantie differente selon la profondeur.
    FTargetRoot: string;
    FOwner: TTransferQueue;
    // Annulation posee par l'interface, lue a chaque tour de la boucle de copie.
    FCancelRequested: Boolean;
    // Lot d'origine: « Apply to all » ne vaut que pour lui.
    FBatch: Integer;
    // Dossier dont le contenu reste a enumerer: le listing a ete coupe par la
    // session, et une reconnexion doit le reprendre au lieu de l'oublier.
    FScanPending: Boolean;
    procedure SetTargetPath(const AValue: string);
    procedure SetError(const AValue: TScpError);
    procedure SetWarning(const AValue: string);
    procedure SetTotalBytes(AValue: Int64);
    procedure SetDoneBytes(AValue: Int64);
    procedure SetScanPending(AValue: Boolean);
  public
    constructor Create(AId: Integer; ADirection: TTransferDirection;
      AKind: TTransferItemKind; const ASourcePath, ATargetPath,
      ADisplayName: string);
    function IsTerminal: Boolean;
    function IsRunnable: Boolean;
    function CancelRequested: Boolean;
    function PercentDone: Integer;

    property Id: Integer read FId;
    property Direction: TTransferDirection read FDirection;
    property Kind: TTransferItemKind read FKind;
    property SourcePath: string read FSourcePath;
    property TargetPath: string read FTargetPath write SetTargetPath;
    property DisplayName: string read FDisplayName;
    property TotalBytes: Int64 read FTotalBytes write SetTotalBytes;
    property DoneBytes: Int64 read FDoneBytes write SetDoneBytes;
    property State: TTransferState read FState;
    property Error: TScpError read FError write SetError;
    property Warning: string read FWarning write SetWarning;
    property SourceTimeUtc: Int64 read FSourceTimeUtc write FSourceTimeUtc;
    property SourceMode: LongWord read FSourceMode write FSourceMode;
    property Attempts: Integer read FAttempts write FAttempts;
    property Depth: Integer read FDepth write FDepth;
    property TargetRoot: string read FTargetRoot write FTargetRoot;
    property Batch: Integer read FBatch;
    property ScanPending: Boolean read FScanPending write SetScanPending;
  end;

  // Debit lisse: une moyenne sur la duree ment apres une pause, une mesure
  // instantanee saute a chaque paquet. Moyenne exponentielle, donc.
  TRateMeter = class
  private
    FRate: Double;           // octets par seconde
    FLastTick: QWord;
    FLastBytes: Int64;
    FStarted: Boolean;
  public
    constructor Create;
    procedure Reset;
    procedure Sample(ATickMs: QWord; ATotalBytes: Int64);
    function BytesPerSecond: Double;
    function EtaSeconds(ARemainingBytes: Int64): Int64;
  end;

  TQueueSummary = record
    Total: Integer;
    Completed: Integer;
    Skipped: Integer;
    Failed: Integer;
    Canceled: Integer;
    Pending: Integer;
    Running: Integer;
    Interrupted: Integer;
    BytesDone: Int64;
    BytesTotal: Int64;
    BytesTotalIsPartial: Boolean;
  end;

  TTransferQueue = class
  private
    FItems: TFPList;
    FNextId: Integer;
    FPaused: Boolean;
    FNextIndex: Integer;
    // Les decisions « pour tout le lot » portent le numero du lot qui les a
    // prises: un lot pose pendant qu'un autre pose une question n'en herite pas.
    FBatch: Integer;
    FConflictPolicy: TConflictAction;   // cnAsk = pas de decision globale
    FPolicyBatch: Integer;
    FSkipAllKinds: set of TScpErrorKind;
    FSkipBatch: Integer;
    FLock: TCriticalSection;
    // Element rendu par NextRunnable et pas encore rendu par ReleaseCurrent:
    // le fil de transfert le tient, personne ne le libere.
    FCurrent: TTransferItem;
    function GetItem(AIndex: Integer): TTransferItem;
    function GetCount: Integer;
    procedure CancelLocked(AItem: TTransferItem);
  public
    constructor Create;
    destructor Destroy; override;

    // Verrou de la file, recursif: Count et Items ne sont coherents entre eux que
    // sous lui, et l'affichage le prend le temps de son parcours.
    procedure Lock;
    procedure Unlock;

    function Add(ADirection: TTransferDirection; AKind: TTransferItemKind;
      const ASourcePath, ATargetPath, ADisplayName: string): TTransferItem;
    procedure Clear;
    // Retire les elements finis: le curseur est recalcule, sinon un « Clear
    // completed » ferait sauter un element. L'element TENU reste, meme fini.
    procedure ClearFinished;
    function FindById(AId: Integer): TTransferItem;

    // Seul point de mutation. False = transition refusee: un callback en retard
    // ne ressuscite pas un element fini.
    function SetState(AItem: TTransferItem; ANext: TTransferState): Boolean;
    class function IsLegalTransition(AFrom, ATo: TTransferState): Boolean;

    // Prochain element a traiter, nil s'il n'y a rien a faire maintenant. Ce
    // qu'il rend est TENU jusqu'a ReleaseCurrent.
    function NextRunnable: TTransferItem;
    procedure ReleaseCurrent;
    // Filet: l'element tenu est declare en echec et relache. Quand le fil sort
    // par une exception, personne d'autre ne le ferait.
    procedure FailCurrent(const AErr: TScpError);
    function HasRunnable: Boolean;
    procedure RewindCursor;

    procedure PauseQueue;
    procedure ResumeQueue;
    function IsPaused: Boolean;

    // Annule ce qui n'est pas fini. Idempotent. Un element en cours recoit une
    // DEMANDE; c'est le fil qui le traite qui conclut.
    procedure CancelAll;
    procedure CancelItem(AItem: TTransferItem);
    function RetryItem(AItem: TTransferItem): Boolean;
    function RetryAllFailed: Integer;
    // Les INTERROMPUS seuls: une reconnexion les relance, un echec attend un
    // geste.
    function RetryInterrupted: Integer;

    // Nouveau lot: ce que Add mettra en file ensuite ne prend aucune decision
    // des lots precedents, meme prise plus tard.
    procedure BeginBatch;
    procedure SetConflictPolicy(ABatch: Integer; AAction: TConflictAction);
    function ConflictPolicy(ABatch: Integer): TConflictAction;
    procedure ClearConflictPolicy;
    // « Skip all similar errors »: la CLASSE d'erreur est ignoree ensuite.
    procedure SkipAllOfKind(ABatch: Integer; AKind: TScpErrorKind);
    function IsSkippedKind(ABatch: Integer; AKind: TScpErrorKind): Boolean;
    procedure ClearSkipKinds;

    function Summary: TQueueSummary;
    function AllSucceeded: Boolean;
    function IsFinished: Boolean;
    function SummaryText: string;

    property Items[AIndex: Integer]: TTransferItem read GetItem; default;
    property Count: Integer read GetCount;
  end;

function TransferStateName(AState: TTransferState): string;
function FormatBytes(ABytes: Int64): string;
function FormatRate(ABytesPerSecond: Double): string;
function FormatEta(ASeconds: Int64): string;

implementation

const
  TERMINAL_STATES: TTransferStates = [tsSkipped, tsCompleted, tsCanceled];

var
  // Separateur FIXE, jamais celui de la locale: « 1,5 Mio » ici et « 1.5 MiB »
  // ailleurs ne serait ni comparable ni copiable dans un rapport.
  GNumFmt: TFormatSettings;

function TransferStateName(AState: TTransferState): string;
begin
  case AState of
    tsPending: Result := 'Pending';
    tsEnumerating: Result := 'Scanning';
    tsTransferring: Result := 'Transferring';
    tsPaused: Result := 'Paused';
    tsInterrupted: Result := 'Interrupted';
    tsRetrying: Result := 'Retrying';
    tsSkipped: Result := 'Skipped';
    tsFailed: Result := 'Failed';
    tsCompleted: Result := 'Done';
    tsCanceled: Result := 'Canceled';
  else
    Result := '';
  end;
end;

function FormatBytes(ABytes: Int64): string;
const
  KB = Int64(1024);
  MB = KB * 1024;
  GB = MB * 1024;
  TB = GB * 1024;
begin
  if ABytes < 0 then Exit('');
  if ABytes < KB then
    Result := Format('%d B', [ABytes], GNumFmt)
  else if ABytes < MB then
    Result := Format('%.1f KiB', [ABytes / KB], GNumFmt)
  else if ABytes < GB then
    Result := Format('%.1f MiB', [ABytes / MB], GNumFmt)
  else if ABytes < TB then
    Result := Format('%.2f GiB', [ABytes / GB], GNumFmt)
  else
    Result := Format('%.2f TiB', [ABytes / TB], GNumFmt);
end;

function FormatRate(ABytesPerSecond: Double): string;
begin
  if ABytesPerSecond <= 0 then Exit('');
  Result := FormatBytes(Round(ABytesPerSecond)) + '/s';
end;

function FormatEta(ASeconds: Int64): string;
begin
  if ASeconds < 0 then Exit('');
  if ASeconds < 60 then
    Result := Format('%ds', [ASeconds])
  else if ASeconds < 3600 then
    Result := Format('%dm %.2ds', [ASeconds div 60, ASeconds mod 60])
  else if ASeconds < 24 * 3600 then
    Result := Format('%dh %.2dm', [ASeconds div 3600,
      (ASeconds mod 3600) div 60])
  else
    Result := '> 1 day';
end;

{ TTransferItem }

constructor TTransferItem.Create(AId: Integer; ADirection: TTransferDirection;
  AKind: TTransferItemKind; const ASourcePath, ATargetPath,
  ADisplayName: string);
begin
  inherited Create;
  FId := AId;
  FDirection := ADirection;
  FKind := AKind;
  FSourcePath := ASourcePath;
  FTargetPath := ATargetPath;
  FDisplayName := ADisplayName;
  FTotalBytes := -1;
  FDoneBytes := 0;
  FState := tsPending;
  FError := NoScpError;
end;

function TTransferItem.IsTerminal: Boolean;
begin
  Result := FState in TERMINAL_STATES;
end;

function TTransferItem.IsRunnable: Boolean;
begin
  Result := FState in [tsPending, tsRetrying];
end;

// Ecrit sous le verrou de la file par l'interface, lu par le fil de copie: le
// lire sous le meme verrou, sinon rien ne dit quand il le verra.
function TTransferItem.CancelRequested: Boolean;
begin
  if FOwner <> nil then FOwner.Lock;
  try
    Result := FCancelRequested;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

// Les compteurs sont ecrits par le fil de copie et lus par l'affichage sous
// le verrou de la file: les ecrire sous lui aussi.
procedure TTransferItem.SetTotalBytes(AValue: Int64);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FTotalBytes := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

procedure TTransferItem.SetDoneBytes(AValue: Int64);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FDoneBytes := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

procedure TTransferItem.SetScanPending(AValue: Boolean);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FScanPending := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

procedure TTransferItem.SetTargetPath(const AValue: string);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FTargetPath := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

procedure TTransferItem.SetError(const AValue: TScpError);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FError := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

procedure TTransferItem.SetWarning(const AValue: string);
begin
  if FOwner <> nil then FOwner.Lock;
  try
    FWarning := AValue;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

function TTransferItem.PercentDone: Integer;
begin
  if FState in [tsCompleted] then Exit(100);
  if FTotalBytes <= 0 then
  begin
    // Taille inconnue: 0 tant que rien n'est parti. Inventer un pourcentage ici,
    // c'est afficher 99 % pendant une heure.
    if FDoneBytes > 0 then Exit(-1);
    Exit(0);
  end;
  if FDoneBytes >= FTotalBytes then Exit(100);
  if FDoneBytes <= 0 then Exit(0);
  // Multiplier d'abord deborde au-dela de 92 Pio, diviser d'abord perd toute
  // precision: diviser le TOTAL par 100 tient les deux.
  if FTotalBytes > High(Int64) div 100 then
    Result := Integer(FDoneBytes div (FTotalBytes div 100))
  else
    Result := Integer((FDoneBytes * 100) div FTotalBytes);
  if Result > 100 then Result := 100;
  if Result < 0 then Result := 0;
end;

{ TRateMeter }

constructor TRateMeter.Create;
begin
  inherited Create;
  Reset;
end;

procedure TRateMeter.Reset;
begin
  FRate := 0;
  FLastTick := 0;
  FLastBytes := 0;
  FStarted := False;
end;

procedure TRateMeter.Sample(ATickMs: QWord; ATotalBytes: Int64);
const
  // Poids de la nouvelle mesure: plus haut = nerveux, plus bas = lent a voir
  // une chute de debit.
  ALPHA = 0.25;
var
  dtMs: QWord;
  dBytes: Int64;
  inst: Double;
begin
  if not FStarted then
  begin
    FStarted := True;
    FLastTick := ATickMs;
    FLastBytes := ATotalBytes;
    Exit;
  end;
  if ATickMs <= FLastTick then Exit;      // horloge non avancee: rien a dire
  dtMs := ATickMs - FLastTick;
  if dtMs < 200 then Exit;                // trop court: le bruit domine
  dBytes := ATotalBytes - FLastBytes;
  // Un compteur qui recule repart a zero plutot que de donner un debit negatif.
  if dBytes < 0 then dBytes := 0;
  inst := (dBytes * 1000.0) / Double(dtMs);
  if FRate <= 0 then
    FRate := inst
  else
    FRate := ALPHA * inst + (1 - ALPHA) * FRate;
  FLastTick := ATickMs;
  FLastBytes := ATotalBytes;
end;

function TRateMeter.BytesPerSecond: Double;
begin
  Result := FRate;
end;

function TRateMeter.EtaSeconds(ARemainingBytes: Int64): Int64;
begin
  // Les deux facons de mentir: diviser par zero, ou dater un reste inconnu.
  if (ARemainingBytes < 0) or (FRate < 1) then Exit(-1);
  if ARemainingBytes = 0 then Exit(0);
  Result := Round(ARemainingBytes / FRate);
  if Result < 0 then Result := -1;
end;

{ TTransferQueue }

constructor TTransferQueue.Create;
begin
  inherited Create;
  FItems := TFPList.Create;
  FLock := TCriticalSection.Create;
  FNextId := 1;
  FNextIndex := 0;
  FBatch := 1;
  FConflictPolicy := cnAsk;
  FSkipAllKinds := [];
end;

destructor TTransferQueue.Destroy;
begin
  Clear;
  FItems.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TTransferQueue.Lock;
begin
  FLock.Acquire;
end;

procedure TTransferQueue.Unlock;
begin
  FLock.Release;
end;

function TTransferQueue.GetItem(AIndex: Integer): TTransferItem;
begin
  Result := TTransferItem(FItems[AIndex]);
end;

// Sous verrou: l'affichage le lit pendant que le fil de transfert ajoute.
function TTransferQueue.GetCount: Integer;
begin
  Lock;
  try
    Result := FItems.Count;
  finally
    Unlock;
  end;
end;

function TTransferQueue.Add(ADirection: TTransferDirection;
  AKind: TTransferItemKind;
  const ASourcePath, ATargetPath, ADisplayName: string): TTransferItem;
begin
  Lock;
  try
    Result := TTransferItem.Create(FNextId, ADirection, AKind,
      ASourcePath, ATargetPath, ADisplayName);
    Result.FOwner := Self;
    Result.FBatch := FBatch;
    Inc(FNextId);
    FItems.Add(Result);
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.Clear;
var
  i: Integer;
begin
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      TTransferItem(FItems[i]).Free;
    FItems.Clear;
    FNextIndex := 0;
    FCurrent := nil;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.ClearFinished;
var
  i: Integer;
  it: TTransferItem;
begin
  Lock;
  try
    for i := FItems.Count - 1 downto 0 do
    begin
      it := TTransferItem(FItems[i]);
      // L'element TENU peut etre fini de son point de vue et encore lu de l'autre:
      // il attend le prochain nettoyage.
      if it = FCurrent then Continue;
      // Les echecs RESTENT: leur raison se lit, et « Retry failed » les reprend.
      // Annuler un echec le rend terminal, donc effacable.
      if it.IsTerminal then
      begin
        it.Free;
        FItems.Delete(i);
      end;
    end;
    // Le curseur designait l'ancienne liste: le garder ferait sauter des
    // elements encore a traiter.
    RewindCursor;
  finally
    Unlock;
  end;
end;

function TTransferQueue.FindById(AId: Integer): TTransferItem;
var
  i: Integer;
begin
  Result := nil;
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      if TTransferItem(FItems[i]).Id = AId then
        Exit(TTransferItem(FItems[i]));
  finally
    Unlock;
  end;
end;

class function TTransferQueue.IsLegalTransition(AFrom,
  ATo: TTransferState): Boolean;
begin
  if AFrom = ATo then Exit(True);          // idempotence: pas une erreur
  if AFrom in TERMINAL_STATES then Exit(False);
  case AFrom of
    tsPending:
      // tsInterrupted depuis l'attente: le contenu d'un dossier coupe a la creation
      // est interrompu AVEC lui.
      Result := ATo in [tsEnumerating, tsTransferring, tsPaused, tsSkipped,
        tsFailed, tsCanceled, tsInterrupted];
    tsEnumerating:
      Result := ATo in [tsCompleted, tsFailed, tsSkipped, tsCanceled,
        tsInterrupted];
    tsTransferring:
      Result := ATo in [tsCompleted, tsFailed, tsSkipped, tsCanceled,
        tsPaused, tsInterrupted];
    tsPaused:
      Result := ATo in [tsPending, tsTransferring, tsCanceled, tsFailed];
    tsInterrupted:
      Result := ATo in [tsRetrying, tsPending, tsFailed, tsSkipped,
        tsCanceled];
    tsRetrying:
      Result := ATo in [tsTransferring, tsEnumerating, tsFailed, tsSkipped,
        tsCanceled, tsInterrupted];
    tsFailed:
      // Un echec n'est pas terminal, mais il repasse par tsRetrying avant
      // tsTransferring pour que l'interface voie le changement.
      Result := ATo in [tsRetrying, tsPending, tsSkipped, tsCanceled];
  else
    Result := False;
  end;
end;

function TTransferQueue.SetState(AItem: TTransferItem;
  ANext: TTransferState): Boolean;
begin
  Result := False;
  if AItem = nil then Exit;
  Lock;
  try
    if not IsLegalTransition(AItem.FState, ANext) then Exit;
    AItem.FState := ANext;
    Result := True;
  finally
    Unlock;
  end;
end;

function TTransferQueue.NextRunnable: TTransferItem;
var
  it: TTransferItem;
begin
  Result := nil;
  Lock;
  try
    FCurrent := nil;
    if FPaused then Exit;
    while FNextIndex < FItems.Count do
    begin
      it := TTransferItem(FItems[FNextIndex]);
      if it.IsRunnable then
      begin
        FCurrent := it;
        Exit(it);
      end;
      Inc(FNextIndex);
    end;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.FailCurrent(const AErr: TScpError);
var
  it: TTransferItem;
begin
  Lock;
  try
    it := FCurrent;
    if it = nil then Exit;
    if not it.IsTerminal then
    begin
      it.FError := AErr;
      SetState(it, tsFailed);
    end;
    FCurrent := nil;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.ReleaseCurrent;
begin
  Lock;
  try
    FCurrent := nil;
  finally
    Unlock;
  end;
end;

function TTransferQueue.HasRunnable: Boolean;
var
  i: Integer;
begin
  Result := False;
  Lock;
  try
    if FPaused then Exit;
    for i := FNextIndex to FItems.Count - 1 do
      if TTransferItem(FItems[i]).IsRunnable then
        Exit(True);
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.RewindCursor;
begin
  Lock;
  try
    FNextIndex := 0;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.PauseQueue;
begin
  // Sous verrou: le fil de transfert lit ce drapeau entre deux elements
  // pendant que l'interface l'ecrit.
  Lock;
  try
    FPaused := True;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.ResumeQueue;
begin
  Lock;
  try
    FPaused := False;
  finally
    Unlock;
  end;
  RewindCursor;
end;

function TTransferQueue.IsPaused: Boolean;
begin
  Lock;
  try
    Result := FPaused;
  finally
    Unlock;
  end;
end;

// Sous verrou. Un element que personne ne traite passe a tsCanceled; un
// element en cours recoit la demande et garde son etat, car seul le fil qui
// ecrit peut dire « je me suis arrete ».
procedure TTransferQueue.CancelLocked(AItem: TTransferItem);
begin
  if AItem.IsTerminal then Exit;
  AItem.FCancelRequested := True;
  if AItem.FState in [tsTransferring, tsEnumerating] then Exit;
  SetState(AItem, tsCanceled);
end;

procedure TTransferQueue.CancelAll;
var
  i: Integer;
begin
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      CancelLocked(TTransferItem(FItems[i]));
  finally
    Unlock;
  end;
end;

// Confinement LEXICAL et volontairement grossier: les deux chemins viennent
// de la meme jointure. La question n'est pas la securite, c'est « cet element
// allait-il dans ce dossier ».
function PathIsUnder(const ARoot, APath: string): Boolean;
begin
  Result := (ARoot <> '') and (Length(APath) > Length(ARoot)) and
    (Copy(APath, 1, Length(ARoot)) = ARoot) and
    // Le separateur de la plateforme, plus '/' sous Windows pour les chemins
    // distants. Sous POSIX '\' est un caractere de nom: l'accepter ici ferait
    // annuler « d\x » avec le dossier « d ».
    {$IFDEF WINDOWS}
    ((APath[Length(ARoot) + 1] = '\') or (APath[Length(ARoot) + 1] = '/'));
    {$ELSE}
    (APath[Length(ARoot) + 1] = '/');
    {$ENDIF}
end;

// Annuler un DOSSIER annule ce qui devait y aller: sans cela sa ligne passe a
// « annule » et ses fichiers partent quand meme.
procedure TTransferQueue.CancelItem(AItem: TTransferItem);
var
  i: Integer;
  it: TTransferItem;
begin
  if AItem = nil then Exit;
  Lock;
  try
    CancelLocked(AItem);      // idempotent, silencieux
    if AItem.Kind <> tikMakeDir then Exit;
    for i := 0 to FItems.Count - 1 do
    begin
      it := TTransferItem(FItems[i]);
      if it = AItem then Continue;
      if it.Direction <> AItem.Direction then Continue;
      if not PathIsUnder(AItem.TargetPath, it.TargetPath) then Continue;
      CancelLocked(it);
    end;
  finally
    Unlock;
  end;
end;

function TTransferQueue.RetryItem(AItem: TTransferItem): Boolean;
begin
  Result := False;
  if AItem = nil then Exit;
  Lock;
  try
    if not (AItem.State in [tsFailed, tsInterrupted]) then Exit;
    if not SetState(AItem, tsRetrying) then Exit;
    AItem.Attempts := AItem.Attempts + 1;
    AItem.FError := NoScpError;
    AItem.FCancelRequested := False;
    RewindCursor;
    Result := True;
  finally
    Unlock;
  end;
end;

function TTransferQueue.RetryAllFailed: Integer;
var
  i: Integer;
begin
  Result := 0;
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      if RetryItem(TTransferItem(FItems[i])) then
        Inc(Result);
  finally
    Unlock;
  end;
end;

function TTransferQueue.RetryInterrupted: Integer;
var
  i: Integer;
begin
  Result := 0;
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      if (TTransferItem(FItems[i]).State = tsInterrupted) and
         RetryItem(TTransferItem(FItems[i])) then
        Inc(Result);
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.BeginBatch;
begin
  Lock;
  try
    Inc(FBatch);
  finally
    Unlock;
  end;
end;

// Sous verrou, tous: poses par le fil de transfert, effaces par l'interface.
procedure TTransferQueue.SetConflictPolicy(ABatch: Integer;
  AAction: TConflictAction);
begin
  Lock;
  try
    FConflictPolicy := AAction;
    FPolicyBatch := ABatch;
  finally
    Unlock;
  end;
end;

function TTransferQueue.ConflictPolicy(ABatch: Integer): TConflictAction;
begin
  Lock;
  try
    Result := cnAsk;
    if ABatch = FPolicyBatch then Result := FConflictPolicy;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.ClearConflictPolicy;
begin
  Lock;
  try
    FConflictPolicy := cnAsk;
    FPolicyBatch := 0;
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.SkipAllOfKind(ABatch: Integer; AKind: TScpErrorKind);
begin
  if AKind = sekNone then Exit;
  Lock;
  try
    if ABatch <> FSkipBatch then FSkipAllKinds := [];
    FSkipBatch := ABatch;
    Include(FSkipAllKinds, AKind);
  finally
    Unlock;
  end;
end;

function TTransferQueue.IsSkippedKind(ABatch: Integer;
  AKind: TScpErrorKind): Boolean;
begin
  Lock;
  try
    Result := (AKind <> sekNone) and (ABatch = FSkipBatch) and
      (AKind in FSkipAllKinds);
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.ClearSkipKinds;
begin
  Lock;
  try
    FSkipAllKinds := [];
    FSkipBatch := 0;
  finally
    Unlock;
  end;
end;

function TTransferQueue.Summary: TQueueSummary;
var
  i: Integer;
  it: TTransferItem;
begin
  Result := Default(TQueueSummary);
  Lock;
  try
    Result.Total := FItems.Count;
    for i := 0 to FItems.Count - 1 do
    begin
      it := TTransferItem(FItems[i]);
      case it.State of
        tsCompleted: Inc(Result.Completed);
        tsSkipped: Inc(Result.Skipped);
        tsFailed: Inc(Result.Failed);
        tsCanceled: Inc(Result.Canceled);
        tsInterrupted: Inc(Result.Interrupted);
        tsPending, tsPaused, tsRetrying: Inc(Result.Pending);
        tsTransferring, tsEnumerating: Inc(Result.Running);
      end;
      if it.Kind = tikFile then
      begin
        Inc(Result.BytesDone, it.DoneBytes);
        if it.TotalBytes >= 0 then
          Inc(Result.BytesTotal, it.TotalBytes)
        else if not it.IsTerminal then
          // Une taille inconnue rend le total incomplet: le dire evite une barre qui
          // depasse 100 % quand elle se decouvre.
          Result.BytesTotalIsPartial := True;
      end;
    end;
  finally
    Unlock;
  end;
end;

function TTransferQueue.AllSucceeded: Boolean;
var
  i: Integer;
begin
  Result := True;
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      if TTransferItem(FItems[i]).State <> tsCompleted then
        Exit(False);
  finally
    Unlock;
  end;
end;

function TTransferQueue.IsFinished: Boolean;
var
  i: Integer;
begin
  Result := True;
  Lock;
  try
    for i := 0 to FItems.Count - 1 do
      if not (TTransferItem(FItems[i]).State in
         [tsCompleted, tsSkipped, tsCanceled, tsFailed]) then
        Exit(False);
  finally
    Unlock;
  end;
end;

function TTransferQueue.SummaryText: string;
var
  s: TQueueSummary;
  parts: string;

  procedure AddPart(const AText: string);
  begin
    if parts <> '' then parts := parts + ', ';
    parts := parts + AText;
  end;

begin
  s := Summary;
  if s.Total = 0 then Exit('');
  parts := '';
  if s.Completed > 0 then AddPart(Format('%d done', [s.Completed]));
  if s.Skipped > 0 then AddPart(Format('%d skipped', [s.Skipped]));
  if s.Failed > 0 then AddPart(Format('%d failed', [s.Failed]));
  if s.Canceled > 0 then AddPart(Format('%d canceled', [s.Canceled]));
  if s.Interrupted > 0 then AddPart(Format('%d interrupted', [s.Interrupted]));
  if s.Pending + s.Running > 0 then
    AddPart(Format('%d left', [s.Pending + s.Running]));
  if not IsFinished then
    Exit(parts);
  // « Completed » n'est dit que si tout a reussi. Sinon on nomme ce qui manque.
  if AllSucceeded then
    Result := Format('Completed: %s', [parts])
  else
    Result := Format('Finished with problems: %s', [parts]);
end;

initialization
  GNumFmt := DefaultFormatSettings;
  GNumFmt.DecimalSeparator := '.';
  GNumFmt.ThousandSeparator := #0;

end.
