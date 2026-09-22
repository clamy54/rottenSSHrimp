{ Thread des operations LOCALES du panneau de gauche.

  Il existe pour une seule raison, et elle est suffisante: un partage reseau
  hors ligne, un lecteur BitLocker verrouille ou une cle USB retiree font
  bloquer un simple listing pendant le timeout du systeme -- des dizaines de
  secondes. Fait sur le thread de l'interface, c'est l'application entiere qui
  parait plantee; fait sur le thread de transport, c'est un transfert en cours
  qui s'arrete.

  Ce thread-ci ne fait donc que du disque local, et il est distinct des deux
  autres. Son annulation est cooperative: on ne peut pas interrompre un appel
  systeme deja parti, mais on cesse d'en emettre, et l'onglet ne l'attend pas
  pour se fermer.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uLocalFsWorker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uScpBackend, uScpErrors, uLocalFileSystem;

type
  TLocalOpKind = (lokList, lokMkdir, lokRename, lokDelete, lokVolumes);

  TLocalListEvent = procedure(const APath: string;
    const AEntries: TScpEntryArray; const AError: TScpError) of object;
  TLocalOpEvent = procedure(const AError: TScpError) of object;
  TLocalVolumesEvent = procedure(const AVolumes: TLocalVolumeArray) of object;

  TLocalFsWorker = class(TThread)
  private
    FFs: TLocalFileSystem;
    FLock: TCriticalSection;
    FWake: TEvent;
    FOps: TFPList;

    FPubPath: string;
    FPubEntries: TScpEntryArray;
    FPubError: TScpError;
    FPubVolumes: TLocalVolumeArray;
    FPubLock: TCriticalSection;

    FOnListed: TLocalListEvent;
    FOnOpDone: TLocalOpEvent;
    FOnVolumes: TLocalVolumesEvent;

    procedure PublishListed;
    procedure PublishOpDone;
    procedure PublishVolumes;
    procedure Post(AKind: TLocalOpKind; const AArg1: string = '';
      const AArg2: string = '');
    function RemoveTree(const APath: string; ADepth: Integer;
      out AErr: TScpError): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AFs: TLocalFileSystem);
    destructor Destroy; override;

    procedure RequestList(const APath: string);
    procedure RequestVolumes;
    procedure RequestMkdir(const APath: string);
    procedure RequestRename(const AFrom, ATo: string);
    procedure RequestDelete(const APath: string);
    procedure Shutdown;

    property OnListed: TLocalListEvent read FOnListed write FOnListed;
    property OnOpDone: TLocalOpEvent read FOnOpDone write FOnOpDone;
    property OnVolumes: TLocalVolumesEvent read FOnVolumes write FOnVolumes;
  end;

implementation

uses
  uScpPaths;

const
  LOCAL_MAX_RM_DEPTH = 64;

type
  TLocalOp = class
    Kind: TLocalOpKind;
    Arg1, Arg2: string;
  end;

constructor TLocalFsWorker.Create(AFs: TLocalFileSystem);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FFs := AFs;
  FLock := TCriticalSection.Create;
  FPubLock := TCriticalSection.Create;
  FOps := TFPList.Create;
  FWake := TEvent.Create(nil, True, False, '');
end;

destructor TLocalFsWorker.Destroy;
var
  i: Integer;
begin
  inherited Destroy;      // joint le thread avant de liberer ses vivres
  for i := 0 to FOps.Count - 1 do
    TLocalOp(FOps[i]).Free;
  FOps.Free;
  FWake.Free;
  FPubLock.Free;
  FLock.Free;
end;

procedure TLocalFsWorker.Shutdown;
begin
  Terminate;
  // L'annulation cooperative sort le listing de sa boucle: elle n'interrompt
  // pas l'appel deja parti, elle empeche le suivant.
  FFs.Cancel;
  FWake.SetEvent;
end;

procedure TLocalFsWorker.Post(AKind: TLocalOpKind;
  const AArg1, AArg2: string);
var
  op: TLocalOp;
begin
  if Terminated then Exit;
  op := TLocalOp.Create;
  op.Kind := AKind;
  op.Arg1 := AArg1;
  op.Arg2 := AArg2;
  FLock.Acquire;
  try
    FOps.Add(op);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

procedure TLocalFsWorker.RequestList(const APath: string);
begin
  Post(lokList, APath);
end;

procedure TLocalFsWorker.RequestVolumes;
begin
  Post(lokVolumes);
end;

procedure TLocalFsWorker.RequestMkdir(const APath: string);
begin
  Post(lokMkdir, APath);
end;

procedure TLocalFsWorker.RequestRename(const AFrom, ATo: string);
begin
  Post(lokRename, AFrom, ATo);
end;

procedure TLocalFsWorker.RequestDelete(const APath: string);
begin
  Post(lokDelete, APath);
end;

procedure TLocalFsWorker.PublishListed;
var
  path: string;
  entries: TScpEntryArray;
  err: TScpError;
begin
  FPubLock.Acquire;
  try
    path := FPubPath;
    entries := FPubEntries;
    err := FPubError;
    FPubEntries := nil;
  finally
    FPubLock.Release;
  end;
  if Assigned(FOnListed) then
    FOnListed(path, entries, err);
end;

procedure TLocalFsWorker.PublishOpDone;
var
  err: TScpError;
begin
  FPubLock.Acquire;
  try
    err := FPubError;
  finally
    FPubLock.Release;
  end;
  if Assigned(FOnOpDone) then
    FOnOpDone(err);
end;

procedure TLocalFsWorker.PublishVolumes;
var
  vols: TLocalVolumeArray;
begin
  FPubLock.Acquire;
  try
    vols := FPubVolumes;
    FPubVolumes := nil;
  finally
    FPubLock.Release;
  end;
  if Assigned(FOnVolumes) then
    FOnVolumes(vols);
end;

function TLocalFsWorker.RemoveTree(const APath: string; ADepth: Integer;
  out AErr: TScpError): Boolean;
var
  entries: TScpEntryArray;
  i: Integer;
  child: string;
  e: TScpEntry;
  statErr: TScpError;
begin
  AErr := NoScpError;
  if Terminated then
  begin
    AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath), '');
    Exit(False);
  end;
  if ADepth > LOCAL_MAX_RM_DEPTH then
  begin
    AErr := MakeScpError(sekOther, 'Deleting', DisplaySafeName(APath),
      Format('maximum depth of %d reached', [LOCAL_MAX_RM_DEPTH]));
    Exit(False);
  end;
  if not FFs.Stat(APath, False, e, statErr) then
  begin
    AErr := statErr;
    Exit(False);
  end;
  // Un lien vers un dossier se supprime LUI: y descendre effacerait sa cible.
  if e.IsLink or (not e.IsDir) then
    Exit(FFs.DeleteFile(APath, AErr));

  if not FFs.List(APath, entries, AErr) then Exit(False);
  for i := 0 to High(entries) do
  begin
    if Terminated then
    begin
      AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath),
        '');
      Exit(False);
    end;
    if CheckRemoteChildName(entries[i].Name) <> nvOk then
    begin
      AErr := MakeScpError(sekInvalidName, 'Deleting',
        DisplaySafeName(entries[i].Name), '');
      Exit(False);
    end;
    child := LocalJoin(APath, entries[i].Name);
    // La jointure doit rester sous le dossier a effacer: un nom fabrique ne fait
    // pas sortir une suppression recursive.
    if not LocalIsUnder(APath, child) then
    begin
      AErr := MakeScpError(sekOutsideRoot, 'Deleting',
        DisplaySafeName(entries[i].Name), '');
      Exit(False);
    end;
    if not RemoveTree(child, ADepth + 1, AErr) then Exit(False);
  end;
  Result := FFs.DeleteDir(APath, AErr);
end;

procedure TLocalFsWorker.Execute;
var
  op: TLocalOp;
  entries: TScpEntryArray;
  err: TScpError;
  vols: TLocalVolumeArray;
begin
  while not Terminated do
  begin
    op := nil;
    FLock.Acquire;
    try
      if FOps.Count > 0 then
      begin
        op := TLocalOp(FOps[0]);
        FOps.Delete(0);
      end;
      if FOps.Count = 0 then
        FWake.ResetEvent;
    finally
      FLock.Release;
    end;
    if op = nil then
    begin
      // Attente bornee: meme si l'evenement se perd, Terminated est revu.
      FWake.WaitFor(200);
      Continue;
    end;
    try
      try
        if not Terminated then
          FFs.ResetCancel;
        err := NoScpError;
        case op.Kind of
          lokList:
            begin
              if not FFs.List(op.Arg1, entries, err) then
                SetLength(entries, 0);
              FPubLock.Acquire;
              try
                FPubPath := op.Arg1;
                FPubEntries := entries;
                FPubError := err;
              finally
                FPubLock.Release;
              end;
              if Assigned(FOnListed) then Queue(@PublishListed);
            end;
          lokVolumes:
            begin
              vols := EnumerateLocalVolumes;
              FPubLock.Acquire;
              try
                FPubVolumes := vols;
              finally
                FPubLock.Release;
              end;
              if Assigned(FOnVolumes) then Queue(@PublishVolumes);
            end;
          lokMkdir:
            begin
              FFs.MakeDir(op.Arg1, err);
              FPubLock.Acquire;
              try
                FPubError := err;
              finally
                FPubLock.Release;
              end;
              if Assigned(FOnOpDone) then Queue(@PublishOpDone);
            end;
          lokRename:
            begin
              FFs.Rename(op.Arg1, op.Arg2, err);
              FPubLock.Acquire;
              try
                FPubError := err;
              finally
                FPubLock.Release;
              end;
              if Assigned(FOnOpDone) then Queue(@PublishOpDone);
            end;
          lokDelete:
            begin
              RemoveTree(op.Arg1, 0, err);
              FPubLock.Acquire;
              try
                FPubError := err;
              finally
                FPubLock.Release;
              end;
              if Assigned(FOnOpDone) then Queue(@PublishOpDone);
            end;
        end;
      except
        on E: Exception do
        begin
          FPubLock.Acquire;
          try
            FPubError := MakeScpError(sekOther, 'Local operation', '',
              E.Message);
          finally
            FPubLock.Release;
          end;
          if Assigned(FOnOpDone) then Queue(@PublishOpDone);
        end;
      end;
    finally
      op.Free;
    end;
  end;
end;

end.
