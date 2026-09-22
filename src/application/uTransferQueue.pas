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
  SysUtils, Classes, uScpErrors;

type
  // tdDuplicate: la source et la destination sont le MEME systeme de
  // fichiers, le meme dossier meme. Ce n'est ni un envoi ni une reception, et
  // l'annoncer comme tel dans la file serait mentir sur ce qui circule.
  TTransferDirection = (tdUpload, tdDownload, tdDuplicate);

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
  public
    constructor Create(AId: Integer; ADirection: TTransferDirection;
      AKind: TTransferItemKind; const ASourcePath, ATargetPath,
      ADisplayName: string);
    function IsTerminal: Boolean;
    function IsRunnable: Boolean;
    function PercentDone: Integer;

    property Id: Integer read FId;
    property Direction: TTransferDirection read FDirection;
    property Kind: TTransferItemKind read FKind;
    property SourcePath: string read FSourcePath;
    property TargetPath: string read FTargetPath write FTargetPath;
    property DisplayName: string read FDisplayName;
    property TotalBytes: Int64 read FTotalBytes write FTotalBytes;
    property DoneBytes: Int64 read FDoneBytes write FDoneBytes;
    property State: TTransferState read FState;
    property Error: TScpError read FError write FError;
    property Warning: string read FWarning write FWarning;
    property SourceTimeUtc: Int64 read FSourceTimeUtc write FSourceTimeUtc;
    property SourceMode: LongWord read FSourceMode write FSourceMode;
    property Attempts: Integer read FAttempts write FAttempts;
    property Depth: Integer read FDepth write FDepth;
    property TargetRoot: string read FTargetRoot write FTargetRoot;
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
    FConflictPolicy: TConflictAction;   // cnAsk = pas de decision globale
    FSkipAllKinds: set of TScpErrorKind;
    function GetItem(AIndex: Integer): TTransferItem;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(ADirection: TTransferDirection; AKind: TTransferItemKind;
      const ASourcePath, ATargetPath, ADisplayName: string): TTransferItem;
    procedure Clear;
    // Retire les elements finis SANS toucher au reste: le curseur de parcours
    // est recalcule, sinon un « Clear completed » en pleine file ferait sauter
    // un element.
    procedure ClearFinished;
    function FindById(AId: Integer): TTransferItem;

    // Seul point de mutation. False = transition refusee: un callback en retard
    // ne ressuscite pas un element fini.
    function SetState(AItem: TTransferItem; ANext: TTransferState): Boolean;
    class function IsLegalTransition(AFrom, ATo: TTransferState): Boolean;

    // Prochain element a traiter, nil s'il n'y a rien a faire maintenant
    // (file en pause, ou plus rien d'executable).
    function NextRunnable: TTransferItem;
    procedure RewindCursor;

    procedure PauseQueue;
    procedure ResumeQueue;
    function IsPaused: Boolean;

    // Annule tout ce qui n'est pas deja fini. Idempotent: rappeler la methode
    // sur une file deja annulee ne change rien et ne leve rien.
    procedure CancelAll;
    procedure CancelItem(AItem: TTransferItem);
    function RetryItem(AItem: TTransferItem): Boolean;
    function RetryAllFailed: Integer;

    procedure SetConflictPolicy(AAction: TConflictAction);
    function ConflictPolicy: TConflictAction;
    procedure ClearConflictPolicy;
    // « Skip all similar errors »: la CLASSE d'erreur est ignoree ensuite.
    procedure SkipAllOfKind(AKind: TScpErrorKind);
    function IsSkippedKind(AKind: TScpErrorKind): Boolean;
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
  FNextId := 1;
  FNextIndex := 0;
  FConflictPolicy := cnAsk;
  FSkipAllKinds := [];
end;

destructor TTransferQueue.Destroy;
begin
  Clear;
  FItems.Free;
  inherited Destroy;
end;

function TTransferQueue.GetItem(AIndex: Integer): TTransferItem;
begin
  Result := TTransferItem(FItems[AIndex]);
end;

function TTransferQueue.GetCount: Integer;
begin
  Result := FItems.Count;
end;

function TTransferQueue.Add(ADirection: TTransferDirection;
  AKind: TTransferItemKind;
  const ASourcePath, ATargetPath, ADisplayName: string): TTransferItem;
begin
  Result := TTransferItem.Create(FNextId, ADirection, AKind,
    ASourcePath, ATargetPath, ADisplayName);
  Inc(FNextId);
  FItems.Add(Result);
end;

procedure TTransferQueue.Clear;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    TTransferItem(FItems[i]).Free;
  FItems.Clear;
  FNextIndex := 0;
end;

procedure TTransferQueue.ClearFinished;
var
  i: Integer;
  it: TTransferItem;
begin
  for i := FItems.Count - 1 downto 0 do
  begin
    it := TTransferItem(FItems[i]);
    if it.IsTerminal or (it.State = tsFailed) then
    begin
      it.Free;
      FItems.Delete(i);
    end;
  end;
  // Le curseur designait une position dans l'ancienne liste: le garder ferait
  // sauter des elements encore a traiter.
  RewindCursor;
end;

function TTransferQueue.FindById(AId: Integer): TTransferItem;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    if TTransferItem(FItems[i]).Id = AId then
      Exit(TTransferItem(FItems[i]));
  Result := nil;
end;

class function TTransferQueue.IsLegalTransition(AFrom,
  ATo: TTransferState): Boolean;
begin
  if AFrom = ATo then Exit(True);          // idempotence: pas une erreur
  if AFrom in TERMINAL_STATES then Exit(False);
  case AFrom of
    tsPending:
      Result := ATo in [tsEnumerating, tsTransferring, tsPaused, tsSkipped,
        tsFailed, tsCanceled];
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
        tsCanceled];
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
  if not IsLegalTransition(AItem.FState, ANext) then Exit;
  AItem.FState := ANext;
  Result := True;
end;

function TTransferQueue.NextRunnable: TTransferItem;
var
  it: TTransferItem;
begin
  Result := nil;
  if FPaused then Exit;
  while FNextIndex < FItems.Count do
  begin
    it := TTransferItem(FItems[FNextIndex]);
    if it.IsRunnable then
      Exit(it);
    Inc(FNextIndex);
  end;
end;

procedure TTransferQueue.RewindCursor;
begin
  FNextIndex := 0;
end;

procedure TTransferQueue.PauseQueue;
begin
  FPaused := True;
end;

procedure TTransferQueue.ResumeQueue;
begin
  FPaused := False;
  RewindCursor;
end;

function TTransferQueue.IsPaused: Boolean;
begin
  Result := FPaused;
end;

procedure TTransferQueue.CancelAll;
var
  i: Integer;
  it: TTransferItem;
begin
  for i := 0 to FItems.Count - 1 do
  begin
    it := TTransferItem(FItems[i]);
    if not it.IsTerminal then
      SetState(it, tsCanceled);
  end;
end;

procedure TTransferQueue.CancelItem(AItem: TTransferItem);
begin
  if AItem = nil then Exit;
  if AItem.IsTerminal then Exit;     // idempotent, silencieux
  SetState(AItem, tsCanceled);
end;

function TTransferQueue.RetryItem(AItem: TTransferItem): Boolean;
begin
  Result := False;
  if AItem = nil then Exit;
  if not (AItem.State in [tsFailed, tsInterrupted]) then Exit;
  if not SetState(AItem, tsRetrying) then Exit;
  AItem.Attempts := AItem.Attempts + 1;
  AItem.Error := NoScpError;
  RewindCursor;
  Result := True;
end;

function TTransferQueue.RetryAllFailed: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to FItems.Count - 1 do
    if RetryItem(TTransferItem(FItems[i])) then
      Inc(Result);
end;

procedure TTransferQueue.SetConflictPolicy(AAction: TConflictAction);
begin
  FConflictPolicy := AAction;
end;

function TTransferQueue.ConflictPolicy: TConflictAction;
begin
  Result := FConflictPolicy;
end;

procedure TTransferQueue.ClearConflictPolicy;
begin
  FConflictPolicy := cnAsk;
end;

procedure TTransferQueue.SkipAllOfKind(AKind: TScpErrorKind);
begin
  if AKind = sekNone then Exit;
  Include(FSkipAllKinds, AKind);
end;

function TTransferQueue.IsSkippedKind(AKind: TScpErrorKind): Boolean;
begin
  Result := (AKind <> sekNone) and (AKind in FSkipAllKinds);
end;

procedure TTransferQueue.ClearSkipKinds;
begin
  FSkipAllKinds := [];
end;

function TTransferQueue.Summary: TQueueSummary;
var
  i: Integer;
  it: TTransferItem;
begin
  Result := Default(TQueueSummary);
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
end;

function TTransferQueue.AllSucceeded: Boolean;
var
  i: Integer;
  st: TTransferState;
begin
  Result := True;
  for i := 0 to FItems.Count - 1 do
  begin
    st := TTransferItem(FItems[i]).State;
    if st <> tsCompleted then
      Exit(False);
  end;
end;

function TTransferQueue.IsFinished: Boolean;
var
  i: Integer;
begin
  for i := 0 to FItems.Count - 1 do
    if not (TTransferItem(FItems[i]).State in
       [tsCompleted, tsSkipped, tsCanceled, tsFailed]) then
      Exit(False);
  Result := True;
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
