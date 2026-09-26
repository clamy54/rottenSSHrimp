{ Disque LOCAL du panneau de gauche, sur son propre thread: un partage hors
  ligne ou une cle arrachee gele un listing des dizaines de secondes, et ni
  l'interface ni un transfert n'ont a payer. Un appel systeme parti ne
  s'annule pas; on cesse juste d'en emettre.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uLocalFsWorker;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uScpBackend, uScpErrors, uLocalFileSystem;

type
  TLocalOpKind = (lokList, lokMkdir, lokRename, lokDelete, lokVolumes);

  TLocalListEvent = procedure(const APath: string; ASerial: Int64;
    const AEntries: TScpEntryArray; const AError: TScpError) of object;
  TLocalOpEvent = procedure(const AError: TScpError) of object;
  TLocalVolumesEvent = procedure(const AVolumes: TLocalVolumeArray) of object;

  TLocalFsWorker = class(TThread)
  private
    FFs: TLocalFileSystem;
    FLock: TCriticalSection;
    FWake: TEvent;
    FOps: TFPList;

    FPub: TFPList;               // un objet par resultat: rien ne s'ecrase
    FPubLock: TCriticalSection;

    FOnListed: TLocalListEvent;
    FSerial: Int64;
    FOnOpDone: TLocalOpEvent;
    FOnVolumes: TLocalVolumesEvent;

    procedure PostResult(AResult: TObject);
    procedure PublishNext;
    function Post(AKind: TLocalOpKind; const AArg1: string = '';
      const AArg2: string = ''): Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(AFs: TLocalFileSystem);
    destructor Destroy; override;

    // L'appelant ignore toute reponse qui ne porte pas ce numero.
    function RequestList(const APath: string): Int64;
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

type
  TLocalOp = class
    Kind: TLocalOpKind;
    Arg1, Arg2: string;
    // Pas le chemin: A, B, puis A confondrait les deux reponses de A.
    Serial: Int64;
  end;

  TLocalResultKind = (lrListed, lrOpDone, lrVolumes);

  TLocalResult = class
    Kind: TLocalResultKind;
    Path: string;
    Entries: TScpEntryArray;
    Error: TScpError;
    Volumes: TLocalVolumeArray;
    Serial: Int64;
  end;

constructor TLocalFsWorker.Create(AFs: TLocalFileSystem);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FFs := AFs;
  FLock := TCriticalSection.Create;
  FPubLock := TCriticalSection.Create;
  FOps := TFPList.Create;
  FPub := TFPList.Create;
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
  for i := 0 to FPub.Count - 1 do
    TObject(FPub[i]).Free;
  FPub.Free;
  FWake.Free;
  FPubLock.Free;
  FLock.Free;
end;

procedure TLocalFsWorker.Shutdown;
begin
  Terminate;
  FFs.Cancel;
  FWake.SetEvent;
end;

function TLocalFsWorker.Post(AKind: TLocalOpKind;
  const AArg1, AArg2: string): Int64;
var
  op: TLocalOp;
begin
  Result := 0;
  if Terminated then Exit;
  op := TLocalOp.Create;
  op.Kind := AKind;
  op.Arg1 := AArg1;
  op.Arg2 := AArg2;
  FLock.Acquire;
  try
    Inc(FSerial);
    op.Serial := FSerial;
    Result := FSerial;
    FOps.Add(op);
  finally
    FLock.Release;
  end;
  FWake.SetEvent;
end;

function TLocalFsWorker.RequestList(const APath: string): Int64;
begin
  Result := Post(lokList, APath);
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

// Thread de travail: le resultat appartient a la file des cet appel.
procedure TLocalFsWorker.PostResult(AResult: TObject);
begin
  FPubLock.Acquire;
  try
    FPub.Add(AResult);
  finally
    FPubLock.Release;
  end;
  Queue(@PublishNext);
end;

// Thread UI: un appel poste par resultat, dans l'ordre.
procedure TLocalFsWorker.PublishNext;
var
  r: TLocalResult;
begin
  r := nil;
  FPubLock.Acquire;
  try
    if FPub.Count > 0 then
    begin
      r := TLocalResult(FPub[0]);
      FPub.Delete(0);
    end;
  finally
    FPubLock.Release;
  end;
  if r = nil then Exit;
  try
    case r.Kind of
      lrListed:
        if Assigned(FOnListed) then
          FOnListed(r.Path, r.Serial, r.Entries, r.Error);
      lrOpDone:
        if Assigned(FOnOpDone) then FOnOpDone(r.Error);
      lrVolumes:
        if Assigned(FOnVolumes) then FOnVolumes(r.Volumes);
    end;
  finally
    r.Free;
  end;
end;

procedure TLocalFsWorker.Execute;
var
  op: TLocalOp;
  entries: TScpEntryArray;
  err: TScpError;
  r: TLocalResult;
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
      // bornee: un evenement perdu ne cache pas Terminated
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
              r := TLocalResult.Create;
              r.Kind := lrListed;
              r.Path := op.Arg1;
              r.Entries := entries;
              r.Error := err;
              r.Serial := op.Serial;
              PostResult(r);
            end;
          lokVolumes:
            begin
              r := TLocalResult.Create;
              r.Kind := lrVolumes;
              r.Volumes := EnumerateLocalVolumes;
              PostResult(r);
            end;
          lokMkdir:
            begin
              FFs.MakeDir(op.Arg1, SCP_DEFAULT_DIR_MODE, err);
              r := TLocalResult.Create;
              r.Kind := lrOpDone;
              r.Error := err;
              PostResult(r);
            end;
          lokRename:
            begin
              FFs.Rename(op.Arg1, op.Arg2, err);
              r := TLocalResult.Create;
              r.Kind := lrOpDone;
              r.Error := err;
              PostResult(r);
            end;
          lokDelete:
            begin
              FFs.RemoveTree(op.Arg1, err);
              r := TLocalResult.Create;
              r.Kind := lrOpDone;
              r.Error := err;
              PostResult(r);
            end;
        end;
      except
        on E: Exception do
        begin
          // Du type ATTENDU, sinon le panneau reste sur « Reading... » a vie.
          r := TLocalResult.Create;
          if op.Kind = lokList then
          begin
            r.Kind := lrListed;
            r.Path := op.Arg1;
            r.Serial := op.Serial;
          end
          else
            r.Kind := lrOpDone;
          r.Error := MakeScpError(sekOther, 'Local operation', '',
            E.Message);
          PostResult(r);
        end;
      end;
    finally
      op.Free;
    end;
  end;
end;

end.
