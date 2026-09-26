{ File de transferts: PURE (ni LCL, ni reseau, ni disque), donc testable.
  PARTAGEE entre le fil de copie et l'affichage: tout passe par le verrou,
  chaines comprises.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uTransferQueue;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, uScpErrors;

type
  TTransferQueue = class;

  // Le sens choisit SEUL les deux systemes de fichiers: d'ou deux duplications.
  TTransferDirection = (tdUpload, tdDownload,
    tdDuplicateLocal, tdDuplicateRemote);

  // tikMakeDir precede ses enfants par l'ordre d'insertion. tikScanRoot: selection
  // pas encore examinee, une coupure la laisse telle quelle.
  TTransferItemKind = (tikFile, tikMakeDir, tikScanRoot);

  TTransferState = (
    tsPending,
    tsEnumerating,
    tsTransferring,
    tsPaused,
    tsInterrupted,   // connexion perdue: reprise possible
    tsRetrying,
    tsSkipped,
    tsFailed,
    tsCompleted,
    tsCanceled);

  TTransferStates = set of TTransferState;

  TConflictAction = (
    cnAsk,
    cnOverwrite,
    cnSkip,
    cnKeepBoth,
    cnResume,
    cnCancelQueue);

  TConflictDecision = record
    Action: TConflictAction;
    ApplyToAll: Boolean;
  end;

  TConflictInfo = record
    SourcePath: string;
    TargetPath: string;
    SourceSize: Int64;
    TargetSize: Int64;
    SourceTimeUtc: Int64;   // secondes Unix, 0 = inconnu
    TargetTimeUtc: Int64;
    // Seulement pour un partiel A NOUS, metadonnees concordantes.
    ResumeAllowed: Boolean;
    ResumeOffset: Int64;
    ResumeRefusedWhy: string;
  end;

  TTransferItem = class
  private
    FId: Int64;
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
    // Sinon un dossier 0000 passe pour inconnu, et nait grand ouvert.
    FSourceModeKnown: Boolean;
    FAttempts: Integer;
    FDepth: Integer;
    // Rien ne s'ecrit hors de lui. Fige a la mise en file, pas rededuit en route.
    FTargetRoot: string;
    FOwner: TTransferQueue;
    FCancelRequested: Boolean;
    // « Apply to all » ne vaut que pour ce lot.
    FBatch: Integer;
    // Listing coupe: la reconnexion le reprend au lieu de l'oublier.
    FScanPending: Boolean;
    // Racine d'un lot de duplication; vide = nom de la source.
    FForcedName: string;
    // 0 = selection. La filiation, pas le chemin cible: deux lots vers le meme
    // dossier, ou un nom distant contenant « \ », ne se melangent pas.
    FParentId: Int64;
    procedure SetTargetPath(const AValue: string);
    procedure SetError(const AValue: TScpError);
    procedure SetWarning(const AValue: string);
    procedure SetTotalBytes(AValue: Int64);
    procedure SetDoneBytes(AValue: Int64);
    procedure SetScanPending(AValue: Boolean);
  public
    constructor Create(AId: Int64; ADirection: TTransferDirection;
      AKind: TTransferItemKind; const ASourcePath, ATargetPath,
      ADisplayName: string);
    function IsTerminal: Boolean;
    function IsRunnable: Boolean;
    function CancelRequested: Boolean;
    function PercentDone: Integer;

    property Id: Int64 read FId;
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
    property SourceModeKnown: Boolean
      read FSourceModeKnown write FSourceModeKnown;
    property Attempts: Integer read FAttempts write FAttempts;
    property Depth: Integer read FDepth write FDepth;
    property TargetRoot: string read FTargetRoot write FTargetRoot;
    property Batch: Integer read FBatch;
    property ScanPending: Boolean read FScanPending write SetScanPending;
    property ForcedName: string read FForcedName write FForcedName;
    property ParentId: Int64 read FParentId;
  end;

  // Moyenne exponentielle: la moyenne globale ment apres une pause, l'instantane
  // saute a chaque paquet.
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
    // Int64: jamais remis a zero, jamais de tour de compteur.
    FNextId: Int64;
    FPaused: Boolean;
    FNextIndex: Integer;
    FBatch: Integer;
    FConflictPolicy: TConflictAction;   // cnAsk = pas de decision globale
    // Un lot pose pendant la question d'un autre n'herite pas de sa reponse.
    FPolicyBatch: Integer;
    FLock: TCriticalSection;
    // Tenu par le fil de copie entre NextRunnable et ReleaseCurrent: intouchable.
    FCurrent: TTransferItem;
    function GetItem(AIndex: Integer): TTransferItem;
    function GetCount: Integer;
    procedure CancelLocked(AItem: TTransferItem);
  public
    constructor Create;
    destructor Destroy; override;

    // Recursif. Count et Items ne sont coherents entre eux que sous lui.
    procedure Lock;
    procedure Unlock;

    // ABatch 0 = lot courant. AParent nil = selection.
    function Add(ADirection: TTransferDirection; AKind: TTransferItemKind;
      const ASourcePath, ATargetPath, ADisplayName: string;
      ABatch: Integer = 0; AParent: TTransferItem = nil): TTransferItem;
    procedure CollectDescendantsLocked(AItem: TTransferItem; AInto: TFPList);
    procedure Rekind(AItem: TTransferItem; AKind: TTransferItemKind;
      const ADisplayName: string);
    procedure Clear;
    // L'element TENU reste, meme fini.
    procedure ClearFinished;
    function FindById(AId: Int64): TTransferItem;

    // Seul point de mutation. False: un callback en retard ne ressuscite pas un mort.
    function SetState(AItem: TTransferItem; ANext: TTransferState): Boolean;
    class function IsLegalTransition(AFrom, ATo: TTransferState): Boolean;

    // Ce qu'il rend est TENU jusqu'a ReleaseCurrent.
    function NextRunnable: TTransferItem;
    procedure ReleaseCurrent;
    // Filet du fil sorti par exception: personne d'autre ne relacherait l'element.
    procedure FailCurrent(const AErr: TScpError);
    function HasRunnable: Boolean;
    procedure RewindCursor;

    procedure PauseQueue;
    procedure ResumeQueue;
    function IsPaused: Boolean;

    // Idempotent. Un element en cours recoit une DEMANDE: son fil conclut.
    procedure CancelAll;
    procedure CancelItem(AItem: TTransferItem);
    function RetryItem(AItem: TTransferItem): Boolean;
    function RetryAllFailed: Integer;
    // Les INTERROMPUS seuls: un echec attend un geste humain.
    function RetryInterrupted: Integer;

    // Numero RENDU et porte par la commande, pas relu plus tard par un autre fil.
    function BeginBatch: Integer;
    procedure SetConflictPolicy(ABatch: Integer; AAction: TConflictAction);
    function ConflictPolicy(ABatch: Integer): TConflictAction;
    procedure ClearConflictPolicy;

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
  // Separateur FIXE, pas celui de la locale: un rapport doit se comparer.
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

constructor TTransferItem.Create(AId: Int64; ADirection: TTransferDirection;
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

// Sous verrou, sinon rien ne dit quand le fil de copie le verra.
function TTransferItem.CancelRequested: Boolean;
begin
  if FOwner <> nil then FOwner.Lock;
  try
    Result := FCancelRequested;
  finally
    if FOwner <> nil then FOwner.Unlock;
  end;
end;

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
    // Taille inconnue: pas de pourcentage invente, pas de 99 % pendant une heure.
    if FDoneBytes > 0 then Exit(-1);
    Exit(0);
  end;
  if FDoneBytes >= FTotalBytes then Exit(100);
  if FDoneBytes <= 0 then Exit(0);
  // *100 deborde au-dela de 92 Pio: on divise alors le TOTAL par 100.
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
  // Plus haut = nerveux, plus bas = aveugle a une chute de debit.
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
  if ATickMs <= FLastTick then Exit;
  dtMs := ATickMs - FLastTick;
  if dtMs < 200 then Exit;                // en dessous, le bruit domine
  dBytes := ATotalBytes - FLastBytes;
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
  const ASourcePath, ATargetPath, ADisplayName: string;
  ABatch: Integer; AParent: TTransferItem): TTransferItem;
begin
  Lock;
  try
    Result := TTransferItem.Create(FNextId, ADirection, AKind,
      ASourcePath, ATargetPath, ADisplayName);
    Result.FOwner := Self;
    if AParent <> nil then Result.FParentId := AParent.Id;
    if ABatch > 0 then
      Result.FBatch := ABatch
    else
      Result.FBatch := FBatch;
    Inc(FNextId);
    FItems.Add(Result);
  finally
    Unlock;
  end;
end;

procedure TTransferQueue.Rekind(AItem: TTransferItem;
  AKind: TTransferItemKind; const ADisplayName: string);
begin
  Lock;
  try
    AItem.FKind := AKind;
    AItem.FDisplayName := ADisplayName;
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
      // Fini pour la file, encore lu par le fil de copie.
      if it = FCurrent then Continue;
      // Les echecs RESTENT (raison lisible, « Retry failed »). Annule, c'est fini.
      if it.IsTerminal then
      begin
        it.Free;
        FItems.Delete(i);
      end;
    end;
    // Curseur de l'ancienne liste: le garder sauterait des elements.
    RewindCursor;
  finally
    Unlock;
  end;
end;

function TTransferQueue.FindById(AId: Int64): TTransferItem;
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
  if AFrom = ATo then Exit(True);
  if AFrom in TERMINAL_STATES then Exit(False);
  case AFrom of
    tsPending:
      // Interrompu en attente: le contenu d'un dossier coupe a la creation.
      Result := ATo in [tsEnumerating, tsTransferring, tsPaused, tsSkipped,
        tsFailed, tsCanceled, tsInterrupted];
    tsEnumerating:
      // Selection examinee: copiee dans la foulee, sans repasser par l'attente.
      Result := ATo in [tsTransferring, tsCompleted, tsFailed, tsSkipped,
        tsCanceled, tsInterrupted];
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
      // Via tsRetrying, pour que l'interface voie le changement.
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

// En cours: seul le fil qui ecrit peut dire « je me suis arrete ».
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

// Parent avant enfants, ids croissants: une passe, ids tries, dichotomie. Pas de
// table indexee par id: l'ecart grandit a chaque « Clear completed ».
procedure TTransferQueue.CollectDescendantsLocked(AItem: TTransferItem;
  AInto: TFPList);
var
  i, start, n: Integer;
  it: TTransferItem;
  ids: array of Int64;

  function InTree(AId: Int64): Boolean;
  var
    lo, hi, mid: Integer;
  begin
    lo := 0;
    hi := n - 1;
    while lo <= hi do
    begin
      mid := (lo + hi) div 2;
      if ids[mid] = AId then Exit(True);
      if ids[mid] < AId then lo := mid + 1 else hi := mid - 1;
    end;
    Result := False;
  end;

begin
  start := FItems.IndexOf(AItem);
  if start < 0 then Exit;
  SetLength(ids, 16);
  ids[0] := AItem.Id;
  n := 1;
  for i := start + 1 to FItems.Count - 1 do
  begin
    it := TTransferItem(FItems[i]);
    if (it.FParentId = 0) or (not InTree(it.FParentId)) then Continue;
    if n = Length(ids) then SetLength(ids, n * 2);
    ids[n] := it.Id;
    Inc(n);
    AInto.Add(it);
  end;
end;

// Un DOSSIER annule emporte ses descendants, pas un autre lot vers le meme lieu.
procedure TTransferQueue.CancelItem(AItem: TTransferItem);
var
  i: Integer;
  subtree: TFPList;
begin
  if AItem = nil then Exit;
  Lock;
  try
    CancelLocked(AItem);
    subtree := TFPList.Create;
    try
      CollectDescendantsLocked(AItem, subtree);
      for i := 0 to subtree.Count - 1 do
        CancelLocked(TTransferItem(subtree[i]));
    finally
      subtree.Free;
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

function TTransferQueue.BeginBatch: Integer;
begin
  Lock;
  try
    Inc(FBatch);
    Result := FBatch;
  finally
    Unlock;
  end;
end;

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
          // Sinon la barre depasse 100 % quand la taille se decouvre.
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
