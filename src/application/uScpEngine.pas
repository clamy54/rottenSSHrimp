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
  SysUtils, Classes, uScpBackend, uScpErrors, uScpPaths, uTransferQueue;

const
  // Tampon FIXE, jamais dimensionne d'apres le reseau.
  SCP_COPY_BUFFER = 64 * 1024;
  // Au-dela de l'annonce du serveur on continue, mais pas indefiniment.
  SCP_GROWTH_SLACK = Int64(4) * 1024 * 1024 * 1024;
  SCP_PROGRESS_MS = 100;

type
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

  // Un partiel ecrit par CETTE session. Hors de cette liste aucune reprise n'est
  // proposee: un partiel d'origine inconnue produirait un fichier mixte.
  TScpPartial = record
    TempPath: string;
    TargetPath: string;
    // Identite du systeme de fichiers SOURCE: reprendre un partiel de srv-a avec
    // les octets de srv-b donnerait un fichier valide en apparence, faux dedans.
    SourceIdentity: string;
    SourcePath: string;
    SourceSize: Int64;
    SourceTimeUtc: Int64;
    // Dernier offset CONFIRME: ecrit ET vide sur le support.
    Confirmed: Int64;
    Active: Boolean;
  end;

  TScpPartialRegistry = class
  private
    FItems: array of TScpPartial;
    function IndexOfTemp(const ATempPath: string): Integer;
  public
    procedure Note(const ATempPath, ATargetPath, ASourceIdentity,
      ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64);
    procedure Confirm(const ATempPath: string; AOffset: Int64);
    procedure Forget(const ATempPath: string);
    // Cherche un partiel reutilisable pour cette source exacte. Refuse des que
    // le moindre element ne concorde pas.
    function FindResumable(const ATargetPath, ASourceIdentity,
      ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64;
      out APartial: TScpPartial): Boolean;
    function ActiveCount: Integer;
    function ActiveAt(AIndex: Integer): TScpPartial;
    procedure Clear;
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
    FLastProgressTick: QWord;
    FNonAtomicAllowedForAll: Boolean;
    FNonAtomicRefusedForAll: Boolean;

    procedure Note(const AText: string);
    procedure ReportProgress(AItem: TTransferItem; AForce: Boolean);
    // Copie proprement dite, source deja ouverte et cible deja ouverte.
    function CopyStream(ASrcFs: TScpFileSystem; ASrcH: TScpFileHandle;
      ADstFs: TScpFileSystem; ADstH: TScpFileHandle;
      AItem: TTransferItem; AExpected: Int64; AStartOffset: Int64;
      const ATempPath: string; out AErr: TScpError): Boolean;
    function ResolveConflict(ASrcFs, ADstFs: TScpFileSystem;
      AItem: TTransferItem; const ASrcEntry: TScpEntry;
      var ATargetPath: string; out AResumeFrom: Int64;
      out AResumeTemp: string; out AErr: TScpError): Boolean;
    // Remplace la cible par le temporaire. Gere l'absence de remplacement
    // atomique en DEMANDANT, jamais en supprimant d'office.
    function CommitTemp(ADstFs: TScpFileSystem;
      const ATempPath, ATargetPath: string; ATargetExisted: Boolean;
      out AErr: TScpError): Boolean;
  public
    constructor Create(AQueue: TTransferQueue);
    destructor Destroy; override;

    // Parcourt ASourcePath et remplit la file. Les dossiers sont ajoutes AVANT
    // leur contenu. Rend False seulement si le parcours lui-meme a echoue; un
    // enfant refuse produit une note et un element ignore.
    function EnumerateInto(ASrcFs, ADstFs: TScpFileSystem;
      ADirection: TTransferDirection;
      const ASourcePath, ATargetParent, ATargetRoot: string;
      AMaxDepth: Integer; out AErr: TScpError): Boolean;

    // Traite UN element. True s'il s'est termine normalement (Completed ou
    // Skipped); False s'il a echoue ou ete interrompu, son etat dit lequel.
    function RunItem(ASrcFs, ADstFs: TScpFileSystem; AItem: TTransferItem;
      const ATargetRoot: string): Boolean;

    // Supprime les temporaires encore ouverts quand c'est sans risque, et
    // rend la liste de ceux qu'il a fallu laisser en place.
    function CleanupPartials(ADstFs: TScpFileSystem): TStringArray;

    property Partials: TScpPartialRegistry read FPartials;
    property OnConflict: TScpConflictEvent read FOnConflict write FOnConflict;
    property OnNonAtomic: TScpNonAtomicEvent
      read FOnNonAtomic write FOnNonAtomic;
    property OnProgress: TScpProgressEvent read FOnProgress write FOnProgress;
    property OnNote: TScpNoteEvent read FOnNote write FOnNote;
  end;

implementation

{ TScpPartialRegistry }

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
  ASourceIdentity, ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64);
var
  i: Integer;
begin
  i := IndexOfTemp(ATempPath);
  if i < 0 then
  begin
    SetLength(FItems, Length(FItems) + 1);
    i := High(FItems);
  end;
  FItems[i].TempPath := ATempPath;
  FItems[i].TargetPath := ATargetPath;
  FItems[i].SourceIdentity := ASourceIdentity;
  FItems[i].SourcePath := ASourcePath;
  FItems[i].SourceSize := ASourceSize;
  FItems[i].SourceTimeUtc := ASourceTimeUtc;
  FItems[i].Confirmed := 0;
  FItems[i].Active := True;
end;

procedure TScpPartialRegistry.Confirm(const ATempPath: string;
  AOffset: Int64);
var
  i: Integer;
begin
  i := IndexOfTemp(ATempPath);
  // Un offset qui recule n'a pas de sens: seul le plus grand confirme compte.
  if (i >= 0) and (AOffset > FItems[i].Confirmed) then
    FItems[i].Confirmed := AOffset;
end;

procedure TScpPartialRegistry.Forget(const ATempPath: string);
var
  i: Integer;
begin
  i := IndexOfTemp(ATempPath);
  if i >= 0 then
    FItems[i].Active := False;
end;

function TScpPartialRegistry.FindResumable(const ATargetPath,
  ASourceIdentity, ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64;
  out APartial: TScpPartial): Boolean;
var
  i: Integer;
begin
  Result := False;
  APartial := Default(TScpPartial);
  // Taille ou date inconnue: la concordance est indemontrable, donc refusee.
  if (ASourceSize < 0) or (ASourceTimeUtc = 0) then Exit;
  for i := 0 to High(FItems) do
    if FItems[i].Active and
       (FItems[i].TargetPath = ATargetPath) and
       (FItems[i].SourceIdentity = ASourceIdentity) and
       (FItems[i].SourcePath = ASourcePath) and
       (FItems[i].SourceSize = ASourceSize) and
       (FItems[i].SourceTimeUtc = ASourceTimeUtc) and
       (FItems[i].Confirmed > 0) and
       (FItems[i].Confirmed < ASourceSize) then
    begin
      APartial := FItems[i];
      Exit(True);
    end;
end;

function TScpPartialRegistry.ActiveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Active then Inc(Result);
end;

function TScpPartialRegistry.ActiveAt(AIndex: Integer): TScpPartial;
var
  i, n: Integer;
begin
  Result := Default(TScpPartial);
  n := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Active then
    begin
      if n = AIndex then Exit(FItems[i]);
      Inc(n);
    end;
end;

procedure TScpPartialRegistry.Clear;
begin
  FItems := nil;
end;

{ TScpTransferEngine }

constructor TScpTransferEngine.Create(AQueue: TTransferQueue);
begin
  inherited Create;
  FQueue := AQueue;
  FPartials := TScpPartialRegistry.Create;
  SetLength(FBuffer, SCP_COPY_BUFFER);
end;

destructor TScpTransferEngine.Destroy;
begin
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

function TScpTransferEngine.EnumerateInto(ASrcFs, ADstFs: TScpFileSystem;
  ADirection: TTransferDirection;
  const ASourcePath, ATargetParent, ATargetRoot: string;
  AMaxDepth: Integer; out AErr: TScpError): Boolean;
var
  srcEntry: TScpEntry;
  srcName: string;

  // Nom acceptable des DEUX cotes: les deux controles different.
  function NameUsable(const AName: string; out AWhy: string): Boolean;
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

  function Walk(const ASrcDir, ADstDir: string; ADepth: Integer): Boolean;
  var
    entries: TScpEntryArray;
    i: Integer;
    e: TScpEntry;
    childSrc, childDst, why: string;
    err: TScpError;
    item: TTransferItem;
    seen: TStringList;
    key: string;
  begin
    Result := False;
    if ASrcFs.Canceled or ADstFs.Canceled then
    begin
      AErr := MakeScpError(sekCanceled, 'Scanning', ASrcDir, '');
      Exit;
    end;
    if ADepth > AMaxDepth then
    begin
      // Profondeur bornee: sans elle une arborescence fabriquee epuise la pile.
      Note(Format('Skipped below %s: maximum depth of %d reached.',
        [DisplaySafeName(ASrcDir), AMaxDepth]));
      Exit(True);
    end;
    if not ASrcFs.List(ASrcDir, entries, err) then
    begin
      // Un dossier illisible ne condamne pas le lot: il est note et saute.
      Note(ScpErrorText(err));
      Exit(True);
    end;
    if Length(entries) > SCP_MAX_DIR_ENTRIES then
    begin
      AErr := MakeScpError(sekOther, 'Scanning', DisplaySafeName(ASrcDir),
        Format('the folder reports more than %d entries',
          [SCP_MAX_DIR_ENTRIES]));
      Exit;
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
        if ASrcFs.Canceled or ADstFs.Canceled then
        begin
          AErr := MakeScpError(sekCanceled, 'Scanning', ASrcDir, '');
          Exit;
        end;
        e := entries[i];
        if not NameUsable(e.Name, why) then
        begin
          Note(why);
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
          Continue;
        end;
        seen.Add(key);

        childSrc := ASrcFs.Join(ASrcDir, e.Name);
        childDst := ADstFs.Join(ADstDir, e.Name);
        // Apres jointure ET normalisation: un controle sur le nom seul se contourne.
        if not ADstFs.IsUnder(ATargetRoot, childDst) then
        begin
          Note(ScpErrorText(MakeScpError(sekOutsideRoot, 'Copying',
            DisplaySafeName(e.Name), '')));
          Continue;
        end;
        // Un nom court et une jointure repetee font quand meme un chemin trop long:
        // on s'arrete ici, avec la raison, plutot qu'au moment d'ecrire.
        if (Length(childDst) > SCP_MAX_PATH_BYTES) or
           (Length(childSrc) > SCP_MAX_PATH_BYTES) then
        begin
          Note(Format('Skipped "%s": the resulting path would exceed %d ' +
            'bytes.', [DisplaySafeName(e.Name), SCP_MAX_PATH_BYTES]));
          Continue;
        end;

        if e.IsLink then
        begin
          // Jamais suivi: un cycle devient impossible plutot que detectable.
          item := FQueue.Add(ADirection, tikFile, childSrc, childDst,
            DisplaySafeName(e.Name));
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
            DisplaySafeName(e.Name));
          item.Depth := ADepth;
          item.TargetRoot := ATargetRoot;
          item.Error := MakeScpError(sekIsSpecialFile, 'Copying',
            DisplaySafeName(e.Name), '');
          FQueue.SetState(item, tsSkipped);
          Continue;
        end;
        if e.IsDir then
        begin
          // L'ordre d'insertion EST la garantie que les parents precedent les enfants.
          item := FQueue.Add(ADirection, tikMakeDir, childSrc, childDst,
            DisplaySafeName(e.Name));
          item.Depth := ADepth;
          item.TargetRoot := ATargetRoot;
          item.SourceMode := e.Mode;
          if not Walk(childSrc, childDst, ADepth + 1) then Exit;
          Continue;
        end;
        item := FQueue.Add(ADirection, tikFile, childSrc, childDst,
          DisplaySafeName(e.Name));
        item.Depth := ADepth;
        item.TargetRoot := ATargetRoot;
        item.TotalBytes := e.Size;
        item.SourceTimeUtc := e.MTimeUtc;
        item.SourceMode := e.Mode;
      end;
    finally
      seen.Free;
    end;
    Result := True;
  end;

var
  rootItem: TTransferItem;
  targetPath, why: string;
begin
  Result := False;
  AErr := NoScpError;
  if AMaxDepth <= 0 then AMaxDepth := SCP_MAX_DEPTH;

  // lstat: c'est le lien lui-meme qu'on veut voir, pas ce qu'il designe.
  if not ASrcFs.Stat(ASourcePath, False, srcEntry, AErr) then Exit;
  srcName := ASrcFs.BaseName(ASourcePath);
  if not NameUsable(srcName, why) then
  begin
    AErr := MakeScpError(sekInvalidName, 'Copying',
      DisplaySafeName(srcName), why);
    Exit;
  end;
  targetPath := ADstFs.Join(ATargetParent, srcName);
  if not ADstFs.IsUnder(ATargetRoot, targetPath) then
  begin
    AErr := MakeScpError(sekOutsideRoot, 'Copying',
      DisplaySafeName(srcName), '');
    Exit;
  end;

  if srcEntry.IsLink then
  begin
    rootItem := FQueue.Add(ADirection, tikFile, ASourcePath, targetPath,
      DisplaySafeName(srcName));
    rootItem.TargetRoot := ATargetRoot;
    rootItem.Error := MakeScpError(sekSymlinkSkipped, 'Copying',
      DisplaySafeName(srcName), srcEntry.LinkTarget);
    FQueue.SetState(rootItem, tsSkipped);
    Exit(True);
  end;
  if srcEntry.IsSpecial then
  begin
    rootItem := FQueue.Add(ADirection, tikFile, ASourcePath, targetPath,
      DisplaySafeName(srcName));
    rootItem.TargetRoot := ATargetRoot;
    rootItem.Error := MakeScpError(sekIsSpecialFile, 'Copying',
      DisplaySafeName(srcName), '');
    FQueue.SetState(rootItem, tsSkipped);
    Exit(True);
  end;
  if srcEntry.IsDir then
  begin
    rootItem := FQueue.Add(ADirection, tikMakeDir, ASourcePath, targetPath,
      DisplaySafeName(srcName));
    rootItem.TargetRoot := ATargetRoot;
    rootItem.SourceMode := srcEntry.Mode;
    Exit(Walk(ASourcePath, targetPath, 1));
  end;
  rootItem := FQueue.Add(ADirection, tikFile, ASourcePath, targetPath,
    DisplaySafeName(srcName));
  rootItem.TargetRoot := ATargetRoot;
  rootItem.TotalBytes := srcEntry.Size;
  rootItem.SourceTimeUtc := srcEntry.MTimeUtc;
  rootItem.SourceMode := srcEntry.Mode;
  Result := True;
end;

// --- Conflits -------------------------------------------------------------

function TScpTransferEngine.ResolveConflict(ASrcFs, ADstFs: TScpFileSystem;
  AItem: TTransferItem; const ASrcEntry: TScpEntry;
  var ATargetPath: string; out AResumeFrom: Int64;
  out AResumeTemp: string; out AErr: TScpError): Boolean;
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
  AResumeFrom := 0;
  AResumeTemp := '';
  AErr := NoScpError;

  if not ADstFs.Exists(ATargetPath, found, AErr) then Exit;
  if not found then Exit(True);      // pas de conflit

  // La cible existe: decrire les DEUX cotes, sinon l'utilisateur choisit a
  // l'aveugle.
  info := Default(TConflictInfo);
  info.SourcePath := AItem.SourcePath;
  info.TargetPath := ATargetPath;
  info.SourceSize := ASrcEntry.Size;
  info.SourceTimeUtc := ASrcEntry.MTimeUtc;
  info.TargetSize := -1;
  if ADstFs.Stat(ATargetPath, True, dstEntry, statErr) then
  begin
    info.TargetSize := dstEntry.Size;
    info.TargetTimeUtc := dstEntry.MTimeUtc;
    if dstEntry.IsDir then
    begin
      // Ecraser un dossier par un fichier n'est pas un conflit ordinaire.
      AErr := MakeScpError(sekAlreadyExists, 'Copying',
        DisplaySafeName(ATargetPath),
        'the destination is a folder, not a file');
      Exit;
    end;
  end;

  info.ResumeAllowed := FPartials.FindResumable(ATargetPath,
    ASrcFs.DisplayName, AItem.SourcePath, ASrcEntry.Size,
    ASrcEntry.MTimeUtc, partial);
  if info.ResumeAllowed then
  begin
    info.ResumeOffset := partial.Confirmed;
    AResumeTemp := partial.TempPath;
  end
  else
    info.ResumeRefusedWhy := 'No partial file from this session matches this ' +
      'source (server, path, size and timestamp must all agree).';

  decision.Action := FQueue.ConflictPolicy;
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
      FQueue.SetConflictPolicy(decision.Action);
  end;

  // Une reprise impossible ne devient pas un ecrasement: on redemande.
  if (decision.Action = cnResume) and (not info.ResumeAllowed) then
    decision.Action := cnSkip;

  case decision.Action of
    cnOverwrite:
      begin
        AResumeTemp := '';
        Result := True;
      end;
    cnResume:
      begin
        AResumeFrom := info.ResumeOffset;
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
            AResumeTemp := '';
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
  const ATempPath: string; out AErr: TScpError): Boolean;
var
  got, put, offset: Integer;
  total, cap: Int64;
begin
  Result := False;
  AErr := NoScpError;
  total := AStartOffset;
  AItem.DoneBytes := total;
  cap := -1;
  if AExpected >= 0 then cap := AExpected + SCP_GROWTH_SLACK;

  while True do
  begin
    if ASrcFs.Canceled or ADstFs.Canceled then
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
      if ASrcFs.Canceled or ADstFs.Canceled then
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
      Inc(offset, put);
      Inc(total, put);
    end;

    AItem.DoneBytes := total;
    if ATempPath <> '' then
      FPartials.Confirm(ATempPath, total);
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

function TScpTransferEngine.CommitTemp(ADstFs: TScpFileSystem;
  const ATempPath, ATargetPath: string; ATargetExisted: Boolean;
  out AErr: TScpError): Boolean;
var
  allow: Boolean;
begin
  AErr := NoScpError;
  if not ATargetExisted then
  begin
    Result := ADstFs.Rename(ATempPath, ATargetPath, AErr);
    if Result then FPartials.Forget(ATempPath);
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

  if FNonAtomicRefusedForAll then Exit;
  allow := FNonAtomicAllowedForAll;
  if (not allow) and Assigned(FOnNonAtomic) then
  begin
    allow := False;
    FOnNonAtomic(ATargetPath, allow);
    if allow then
      FNonAtomicAllowedForAll := True
    else
      FNonAtomicRefusedForAll := True;
  end;
  if not allow then
  begin
    AErr := MakeScpError(sekRenameRefused, 'Replacing',
      DisplaySafeName(ATargetPath),
      'atomic replacement is not available here and the non-atomic fallback ' +
      'was declined; the existing file was left untouched');
    Exit(False);
  end;

  // Repli assume: supprimer puis renommer. Seule fenetre ou la cible n'existe
  // plus, et elle n'est ouverte qu'apres un accord explicite.
  Note(Format('Replaced %s without an atomic rename, as confirmed.',
    [DisplaySafeName(ATargetPath)]));
  if not ADstFs.DeleteFile(ATargetPath, AErr) then Exit(False);
  Result := ADstFs.Rename(ATempPath, ATargetPath, AErr);
  if Result then FPartials.Forget(ATempPath);
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
begin
  Result := False;
  srcH := nil;
  dstH := nil;
  tempPath := '';

  if AItem.IsTerminal then Exit(True);
  if ASrcFs.Canceled or ADstFs.Canceled then
  begin
    AItem.Error := MakeScpError(sekCanceled, 'Copying', AItem.DisplayName, '');
    FQueue.SetState(AItem, tsCanceled);
    Exit;
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
    FQueue.SetState(AItem, tsTransferring);
    if not ADstFs.Exists(targetPath, found, err) then
    begin
      AItem.Error := err;
      FQueue.SetState(AItem, tsFailed);
      Exit;
    end;
    if found then
    begin
      // Un dossier deja present n'est pas un conflit: on y depose la suite.
      if ADstFs.Stat(targetPath, True, dstEntry, err) and
         (not dstEntry.IsDir) then
      begin
        AItem.Error := MakeScpError(sekAlreadyExists, 'Creating folder',
          AItem.DisplayName, 'a file of that name already exists');
        FQueue.SetState(AItem, tsFailed);
        Exit;
      end;
      FQueue.SetState(AItem, tsCompleted);
      Exit(True);
    end;
    if not ADstFs.MakeDir(targetPath, err) then
    begin
      AItem.Error := err;
      FQueue.SetState(AItem, tsFailed);
      Exit;
    end;
    FQueue.SetState(AItem, tsCompleted);
    Exit(True);
  end;

  // lstat encore: la source a pu devenir un lien depuis l'enumeration.
  if not ASrcFs.Stat(AItem.SourcePath, False, srcEntry, err) then
  begin
    if err.Kind = sekNotFound then
      err.Kind := sekPathGone;
    AItem.Error := err;
    FQueue.SetState(AItem, tsFailed);
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

  if not ResolveConflict(ASrcFs, ADstFs, AItem, srcEntry, targetPath,
     resumeFrom, resumeTemp, err) then
  begin
    if AItem.State = tsSkipped then Exit(True);
    if err.Kind <> sekNone then
    begin
      AItem.Error := err;
      if err.Kind = sekCanceled then
        FQueue.SetState(AItem, tsCanceled)
      else
        FQueue.SetState(AItem, tsFailed);
    end;
    Exit;
  end;
  if AItem.State = tsSkipped then Exit(True);
  AItem.TargetPath := targetPath;

  if not ADstFs.Exists(targetPath, targetExisted, err) then
  begin
    AItem.Error := err;
    FQueue.SetState(AItem, tsFailed);
    Exit;
  end;

  FQueue.SetState(AItem, tsTransferring);
  parentDir := ADstFs.Parent(targetPath);
  try
    if not ASrcFs.OpenRead(AItem.SourcePath, srcH, err) then
    begin
      // Listee mais refusee a l'ouverture: une cause a part, que « dossier
      // illisible » ferait chercher au mauvais endroit.
      if err.Kind = sekAccessDeniedDir then
        err.Kind := sekAccessDeniedRead;
      AItem.Error := err;
      FQueue.SetState(AItem, tsFailed);
      Exit;
    end;

    if (resumeFrom > 0) and (resumeTemp <> '') then
    begin
      tempPath := resumeTemp;
      if not ADstFs.OpenAppend(tempPath, resumeFrom, dstH, err) then
      begin
        AItem.Error := err;
        FQueue.SetState(AItem, tsFailed);
        Exit;
      end;
      if not ASrcFs.Seek(srcH, resumeFrom, err) then
      begin
        AItem.Error := err;
        FQueue.SetState(AItem, tsFailed);
        Exit;
      end;
    end
    else
    begin
      // Temporaire DANS le dossier de destination: ailleurs le rename traverserait
      // un systeme de fichiers et cesserait d'etre atomique.
      if not ADstFs.CreateTemp(parentDir, tempPath, dstH, err) then
      begin
        if err.Kind = sekAccessDeniedRead then
          err.Kind := sekAccessDeniedWrite;
        AItem.Error := err;
        FQueue.SetState(AItem, tsFailed);
        Exit;
      end;
      FPartials.Note(tempPath, targetPath, ASrcFs.DisplayName,
        AItem.SourcePath, srcEntry.Size, srcEntry.MTimeUtc);
      resumeFrom := 0;
    end;

    okCopy := CopyStream(ASrcFs, srcH, ADstFs, dstH, AItem, srcEntry.Size,
      resumeFrom, tempPath, err);

    // Vider AVANT de conclure: un disque plein ne se revele souvent qu'ici, et
    // conclure avant remplacerait une cible valide par un fichier tronque.
    if okCopy then
      okCopy := ADstFs.Flush(dstH, err);

    ADstFs.Close(dstH, closeErr);
    dstH := nil;
    if okCopy and (closeErr.Kind <> sekNone) then
    begin
      okCopy := False;
      err := closeErr;
    end;
    ASrcFs.Close(srcH, closeErr);
    srcH := nil;

    if not okCopy then
    begin
      AItem.Error := err;
      if err.Kind = sekCanceled then
        FQueue.SetState(AItem, tsCanceled)
      else if IsFatalToSession(err.Kind) then
        // Perte de connexion: l'element n'a pas echoue definitivement, il est
        // interrompu. Le partiel reste enregistre pour une reprise sure.
        FQueue.SetState(AItem, tsInterrupted)
      else
        FQueue.SetState(AItem, tsFailed);
      Exit;
    end;

    if not CommitTemp(ADstFs, tempPath, targetPath, targetExisted, err) then
    begin
      AItem.Error := err;
      FQueue.SetState(AItem, tsFailed);
      Exit;
    end;
    tempPath := '';

    // A partir d'ici le contenu EST arrive: la suite n'est qu'un avertissement.
    if srcEntry.MTimeUtc > 0 then
      if not ADstFs.SetMTime(targetPath, srcEntry.MTimeUtc, attrErr) then
        AItem.Warning := ScpErrorText(MakeScpError(sekAttrRefused,
          'Setting the timestamp of', AItem.DisplayName, attrErr.Detail));
    // Le mode de la source n'est jamais recopie tel quel: un fichier distant
    // en 0777 ne doit pas arriver inscriptible par tout le monde.
    if ADstFs.IsRemote then
      if not ADstFs.SetMode(targetPath, SCP_DEFAULT_FILE_MODE, attrErr) then
        if AItem.Warning = '' then
          AItem.Warning := ScpErrorText(MakeScpError(sekAttrRefused,
            'Setting the mode of', AItem.DisplayName, attrErr.Detail));
    if AItem.Warning <> '' then
      Note(AItem.Warning);

    FQueue.SetState(AItem, tsCompleted);
    ReportProgress(AItem, True);
    Result := True;
  finally
    if dstH <> nil then ADstFs.Close(dstH, closeErr);
    if srcH <> nil then ASrcFs.Close(srcH, closeErr);
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
