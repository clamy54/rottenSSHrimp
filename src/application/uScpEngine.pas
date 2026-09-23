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
  SysUtils, Classes, SyncObjs, sha1, uScpBackend, uScpErrors, uScpPaths,
  uTransferQueue;

const
  // Tampon FIXE, jamais dimensionne d'apres le reseau.
  SCP_COPY_BUFFER = 64 * 1024;
  // Au-dela de l'annonce du serveur on continue, mais pas indefiniment.
  SCP_GROWTH_SLACK = Int64(4) * 1024 * 1024 * 1024;
  SCP_PROGRESS_MS = 100;
  // Periode de vidage du tampon, qui confirme l'offset de reprise. Trop petit:
  // le debit s'effondre; trop grand, une coupure fait resservir l'intervalle.
  SCP_CONFIRM_EVERY = Int64(4) * 1024 * 1024;

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
    // refuse. SHA-1 suffit, il faudrait une seconde preimage et pas une collision.
    Digest: TSHA1Digest;
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
      const ADigest: TSHA1Digest);
    procedure Forget(const ATempPath: string);
    function Lookup(const ATempPath: string; out APartial: TScpPartial): Boolean;
    // Cherche un partiel reutilisable pour cette source exacte, sur cette
    // destination. Refuse des que le moindre element ne concorde pas.
    function FindResumable(const ATargetPath, ASourceIdentity, ADestIdentity,
      ASourcePath: string; ASourceSize, ASourceTimeUtc: Int64;
      out APartial: TScpPartial): Boolean;
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
    FLastProgressTick: QWord;
    FConfirmEvery: Int64;

    procedure Note(const AText: string);
    // Pose l'etat qui correspond a l'erreur: annule, interrompu si la session est
    // perdue, echoue sinon. Une coupure rangee en « echec » interdirait la reprise.
    procedure FailItem(AItem: TTransferItem; const AErr: TScpError);
    procedure ReportProgress(AItem: TTransferItem; AForce: Boolean);
    // Copie proprement dite, source et cible deja ouvertes. AHash court sur les
    // octets ECRITS: fraiche pour un fichier neuf, nourrie du prefixe a la reprise.
    function CopyStream(ASrcFs: TScpFileSystem; ASrcH: TScpFileHandle;
      ADstFs: TScpFileSystem; ADstH: TScpFileHandle;
      AItem: TTransferItem; AExpected: Int64; AStartOffset: Int64;
      const ATempPath: string; var AHash: TSHA1Context;
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
    // Le partiel enregistre est-il encore ce qu'on croit? Fichier ordinaire,
    // pas un lien, au moins aussi long que l'offset confirme.
    function PartialUsable(ADstFs: TScpFileSystem; const ATempPath: string;
      AConfirmed: Int64; out AWhy: string): Boolean;
    // Relit le prefixe confirme A TRAVERS la poignee rouverte et compare son
    // empreinte au registre; laisse AHash nourrie et la poignee a l'offset. False
    // avec AErr vide = partiel inutilisable, avec AErr = la relecture a echoue.
    function VerifyPartialPrefix(ADstFs: TScpFileSystem;
      ADstH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; var AHash: TSHA1Context;
      out AWhy: string; out AErr: TScpError): Boolean;
    // Meme question pour la SOURCE. Seulement quand elle sait relire sans reseau:
    // relire une source distante couterait ce que la reprise economise.
    function VerifySourcePrefix(ASrcFs: TScpFileSystem;
      ASrcH: TScpFileHandle; AItem: TTransferItem;
      const APartial: TScpPartial; out AWhy: string;
      out AErr: TScpError): Boolean;
  public
    constructor Create(AQueue: TTransferQueue);
    destructor Destroy; override;

    // Parcourt ASourcePath et remplit la file, dossiers AVANT leur contenu. False
    // seulement si le parcours a echoue; un enfant refuse donne un element ignore.
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

    property Partials: TScpPartialRegistry read FPartials;
    property ConfirmEvery: Int64 read FConfirmEvery write FConfirmEvery;
    property OnConflict: TScpConflictEvent read FOnConflict write FOnConflict;
    property OnNonAtomic: TScpNonAtomicEvent
      read FOnNonAtomic write FOnNonAtomic;
    property OnProgress: TScpProgressEvent read FOnProgress write FOnProgress;
    property OnNote: TScpNoteEvent read FOnNote write FOnNote;
  end;

implementation

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
  AOffset: Int64; const ADigest: TSHA1Digest);
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
         (FItems[i].Confirmed < ASourceSize) then
      begin
        APartial := FItems[i];
        Exit(True);
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

// Droits d'un fichier NEUF d'apres ceux de sa source. Jamais d'ecriture
// pour tous, jamais de setuid/setgid/sticky, quel que soit ce que la source
// annonce; et un mode inconnu (source Windows) donne le mode par defaut.
function ModeForNewFile(ASourceMode: LongWord): LongWord;
begin
  Result := ASourceMode and LongWord(&0777);
  if Result = 0 then Result := SCP_DEFAULT_FILE_MODE;
  Result := Result and LongWord(&0775);
end;

{ TScpTransferEngine }

constructor TScpTransferEngine.Create(AQueue: TTransferQueue);
begin
  inherited Create;
  FQueue := AQueue;
  FPartials := TScpPartialRegistry.Create;
  FConfirmEvery := SCP_CONFIRM_EVERY;
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
  AMaxDepth: Integer; out AErr: TScpError;
  const ATargetName: string): Boolean;
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

  // AOwner: l'element tikMakeDir du dossier. Un dossier inenumerable ne
  // disparait pas du bilan, il passe a « ignore » avec sa raison.
  function Walk(const ASrcDir, ADstDir: string; ADepth: Integer;
    AOwner: TTransferItem): Boolean;
  var
    entries: TScpEntryArray;
    i: Integer;
    e: TScpEntry;
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
        DisplaySafeName(AName));
      sk.Depth := ADepth;
      sk.TargetRoot := ATargetRoot;
      sk.Error := AChildErr;
      FQueue.SetState(sk, tsSkipped);
    end;

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
      // Un dossier illisible ne condamne pas le lot: il est note et saute,
      // et son element dit pourquoi -- « termine » sans lui serait un
      // mensonge.
      Note(ScpErrorText(err));
      if AOwner <> nil then
      begin
        AOwner.Error := err;
        FQueue.SetState(AOwner, tsSkipped);
      end;
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
          if not Walk(childSrc, childDst, ADepth + 1, item) then Exit;
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
  targetPath, targetName, why: string;
  v: TNameVerdict;
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
  targetName := srcName;
  if ATargetName <> '' then
  begin
    // Le nom impose passe par les regles de la DESTINATION comme un autre: il
    // vient d'un calcul, pas d'une garantie.
    v := ADstFs.CheckName(ATargetName);
    if v <> nvOk then
    begin
      AErr := MakeScpError(sekInvalidName, 'Copying',
        DisplaySafeName(ATargetName),
        NameVerdictText(v, DisplaySafeName(ATargetName)));
      Exit;
    end;
    targetName := ATargetName;
  end;
  targetPath := ADstFs.Join(ATargetParent, targetName);
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
      DisplaySafeName(targetName));
    rootItem.TargetRoot := ATargetRoot;
    rootItem.SourceMode := srcEntry.Mode;
    Exit(Walk(ASourcePath, targetPath, 1, rootItem));
  end;
  rootItem := FQueue.Add(ADirection, tikFile, ASourcePath, targetPath,
    DisplaySafeName(targetName));
  rootItem.TargetRoot := ATargetRoot;
  rootItem.TotalBytes := srcEntry.Size;
  rootItem.SourceTimeUtc := srcEntry.MTimeUtc;
  rootItem.SourceMode := srcEntry.Mode;
  Result := True;
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
  if ADstFs.Stat(ATargetPath, False, dstEntry, statErr) then
  begin
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
  const ATempPath: string; var AHash: TSHA1Context;
  out AErr: TScpError): Boolean;
var
  got, put, offset: Integer;
  total, cap, sinceConfirm: Int64;
  snap: TSHA1Context;
  digest: TSHA1Digest;
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
      SHA1Update(AHash, FBuffer[offset], put);
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
      snap := AHash;
      SHA1Final(snap, digest);
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
  const ATempPath: string; AConfirmed: Int64; out AWhy: string): Boolean;
var
  e: TScpEntry;
  err: TScpError;
begin
  Result := False;
  AWhy := '';
  // lstat: c'est le chemin qu'on juge. Un lien pose a la place du partiel ferait
  // ecrire la suite ailleurs.
  if not ADstFs.Stat(ATempPath, False, e, err) then
  begin
    AWhy := 'it is no longer there';
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
  Result := True;
end;

function TScpTransferEngine.VerifyPartialPrefix(ADstFs: TScpFileSystem;
  ADstH: TScpFileHandle; AItem: TTransferItem; const APartial: TScpPartial;
  var AHash: TSHA1Context; out AWhy: string; out AErr: TScpError): Boolean;
var
  left: Int64;
  want, got: Integer;
  snap: TSHA1Context;
  digest: TSHA1Digest;
begin
  Result := False;
  AWhy := '';
  AErr := NoScpError;
  SHA1Init(AHash);
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
    SHA1Update(AHash, FBuffer[0], got);
    Dec(left, got);
  end;
  snap := AHash;
  SHA1Final(snap, digest);
  if not SHA1Match(digest, APartial.Digest) then
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
  ctx: TSHA1Context;
  digest: TSHA1Digest;
begin
  Result := False;
  AWhy := '';
  AErr := NoScpError;
  SHA1Init(ctx);
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
    SHA1Update(ctx, FBuffer[0], got);
    Dec(left, got);
  end;
  SHA1Final(ctx, digest);
  if not SHA1Match(digest, APartial.Digest) then
  begin
    // Meme taille, meme date, autre contenu: poursuivre collerait un ancien debut
    // a une nouvelle fin.
    AWhy := 'the source has changed since the transfer was interrupted';
    Exit;
  end;
  Result := True;
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
  if Result then FPartials.Forget(ATempPath);
end;

procedure TScpTransferEngine.FailItem(AItem: TTransferItem;
  const AErr: TScpError);
begin
  AItem.Error := AErr;
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
begin
  FQueue.Lock;
  try
    for i := 0 to FQueue.Count - 1 do
    begin
      it := FQueue.Items[i];
      if it = AItem then Continue;
      if not it.IsRunnable then Continue;
      if it.Direction <> AItem.Direction then Continue;
      if not ADstFs.IsUnder(AItem.TargetPath, it.TargetPath) then Continue;
      it.Error := MakeScpError(AItem.Error.Kind, 'Copying', it.DisplayName,
        Format('its folder "%s" could not be created', [AItem.DisplayName]));
      FQueue.SetState(it, tsFailed);
    end;
  finally
    FQueue.Unlock;
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
  hash, snap: TSHA1Context;
  digest: TSHA1Digest;
  partial: TScpPartial;
  outcome: TScpConflictOutcome;
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
      FQueue.SetState(AItem, tsCompleted);
      Exit(True);
    end;
    if not ADstFs.MakeDir(targetPath, err) then
    begin
      FailItem(AItem, err);
      FailSubtree(ADstFs, AItem);
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
  newMode := ModeForNewFile(srcEntry.Mode);
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
      if not PartialUsable(ADstFs, tempPath, resumeFrom, why) then
      begin
        FPartials.Forget(tempPath);
        Note(Format('The partial file for %s cannot be resumed (%s); ' +
          'starting over.', [AItem.DisplayName, why]));
        // Le nom est le notre et ce qu'il contient ne sert plus. Un lien se retire
        // lui-meme, jamais ce qu'il designe.
        ADstFs.DeleteFile(tempPath, closeErr);
        tempPath := '';
        resumeFrom := 0;
      end
      else if not ADstFs.OpenAppend(tempPath, resumeFrom, dstH, err) then
      begin
        FPartials.Forget(tempPath);
        Note(Format('The partial file for %s could not be reopened; ' +
          'starting over.', [AItem.DisplayName]));
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
           not VerifyPartialPrefix(ADstFs, dstH, AItem, partial, hash, why,
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
          FPartials.Forget(tempPath);
          Note(Format('The partial file for %s cannot be resumed (%s); ' +
            'starting over.', [AItem.DisplayName, why]));
          ADstFs.DeleteFile(tempPath, closeErr);
          tempPath := '';
          resumeFrom := 0;
        end
        else
        begin
          // Reste la SOURCE: meme chemin, meme taille, meme date a la seconde ne disent
          // pas « meme contenu ». Son prefixe est relu quand c'est local; sur une source
          // distante cela couterait ce que la reprise economise, et taille et date
          // repondent seules.
          why := '';
          if ASrcFs.CheapReRead and (not VerifySourcePrefix(ASrcFs, srcH,
             AItem, partial, why, err)) then
          begin
            ADstFs.Close(dstH, closeErr);
            dstH := nil;
            if err.Kind <> sekNone then
            begin
              FailItem(AItem, err);
              Exit;
            end;
            FPartials.Forget(tempPath);
            Note(Format('The partial file for %s cannot be resumed (%s); ' +
              'starting over.', [AItem.DisplayName, why]));
            ADstFs.DeleteFile(tempPath, closeErr);
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
      SHA1Init(hash);
    end;

    okCopy := CopyStream(ASrcFs, srcH, ADstFs, dstH, AItem, srcEntry.Size,
      resumeFrom, tempPath, hash, err);

    // Vider AVANT de conclure: un disque plein ne se revele souvent qu'ici, et
    // conclure avant remplacerait une cible valide par un fichier tronque.
    if okCopy then
      okCopy := ADstFs.Flush(dstH, err);
    if okCopy then
    begin
      snap := hash;
      SHA1Final(snap, digest);
      FPartials.Confirm(tempPath, AItem.DoneBytes, digest);
    end;

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
      // Perte de connexion: interrompu, pas echoue, et le partiel reste enregistre.
      FailItem(AItem, err);
      Exit;
    end;

    // Un fichier REMPLACE garde ses droits: un 0600 devenu 0644 est une fuite.
    // Ils sont reposes sur le temporaire AVANT publication, et s'ils ne peuvent
    // pas l'etre la cible n'est pas remplacee.
    if targetExisted and outcome.PrevModeKnown then
      if not ADstFs.SetMode(tempPath, prevMode, attrErr) then
      begin
        attrErr := MakeScpError(attrErr.Kind, 'Setting the mode of',
          AItem.DisplayName, 'the permissions of the existing file could ' +
          'not be applied to the new content; the existing file was left ' +
          'untouched');
        if ADstFs.DeleteFile(tempPath, closeErr) then
        begin
          FPartials.Forget(tempPath);
          tempPath := '';
        end;
        FailItem(AItem, attrErr);
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

    if not CommitTemp(ADstFs, AItem, tempPath, targetPath, targetExisted,
       err) then
    begin
      FailItem(AItem, err);
      Exit;
    end;
    tempPath := '';

    // A partir d'ici le contenu EST arrive: la suite n'est qu'un avertissement.
    if srcEntry.MTimeUtc > 0 then
      if not ADstFs.SetMTime(targetPath, srcEntry.MTimeUtc, attrErr) then
        AItem.Warning := ScpErrorText(MakeScpError(sekAttrRefused,
          'Setting the timestamp of', AItem.DisplayName, attrErr.Detail));
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
