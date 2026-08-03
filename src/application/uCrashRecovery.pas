unit uCrashRecovery;

{$mode objfpc}{$H+}

// Copies de travail orphelines laissees par un processus mort (dossier d'instance
// « mort » = verrou libre, uAppPaths). La reprise n'ecrase jamais l'original.

interface

uses
  SysUtils;

type
  TRecoveryItem = record
    WorkingPath: string;
    OriginPath: string;    // '' si inconnu
    Modified: TDateTime;
    SizeBytes: Int64;
  end;
  TRecoveryItems = array of TRecoveryItem;

// Recense les orphelines des instances mortes; fait aussi le menage au passage.
function ScanOrphanRecoveries: TRecoveryItems;

procedure DiscardRecovery(const AItem: TRecoveryItem);

function RecoveryDisplayName(const AItem: TRecoveryItem): string;

implementation

uses
  Classes, uAppPaths;

function OriginSidecar(const AWorkingPath: string): string;
begin
  Result := AWorkingPath + '.origin';
end;

function ReadOrigin(const AWorkingPath: string): string;
var
  sl: TStringList;
begin
  Result := '';
  if not FileExists(OriginSidecar(AWorkingPath)) then Exit;
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(OriginSidecar(AWorkingPath));
      if sl.Count > 0 then
        Result := Trim(sl[0]);
    except
      Result := '';
    end;
  finally
    sl.Free;
  end;
end;

procedure CollectFromDir(const ADir: string; var AItems: TRecoveryItems);
var
  sr: TSearchRec;
  full: string;
  it: TRecoveryItem;
begin
  if FindFirst(ADir + PathDelim + '*.working.rsh', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      full := ADir + PathDelim + sr.Name;
      it.WorkingPath := full;
      it.OriginPath := ReadOrigin(full);
      it.Modified := sr.TimeStamp;
      it.SizeBytes := sr.Size;
      SetLength(AItems, Length(AItems) + 1);
      AItems[High(AItems)] := it;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

procedure RemoveEmptyDeadDir(const ADir: string);
var
  sr: TSearchRec;
  onlyLock: Boolean;
begin
  onlyLock := True;
  if FindFirst(ADir + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = '.lock') then
        Continue;
      onlyLock := False;
      Break;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if onlyLock then
  begin
    if FileExists(ADir + PathDelim + '.lock') then
      DeleteFile(ADir + PathDelim + '.lock');
    RemoveDir(ADir);
  end;
end;

// SaveTo serialise la base EN CLAIR dans <uuid>.seal.tmp avant de la chiffrer:
// un crash laisse ce SQLite nu, sans enveloppe donc irrecuperable. On le
// supprime, on ne le propose pas. Instances MORTES uniquement.
procedure SweepCleartextTemps(const ADir: string);
var
  sr: TSearchRec;
begin
  if FindFirst(ADir + PathDelim + '*.seal.tmp*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Attr and faDirectory) <> 0 then Continue;
      DeleteFile(ADir + PathDelim + sr.Name);
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

function ScanOrphanRecoveries: TRecoveryItems;
var
  root, self_, sub: string;
  sr: TSearchRec;
begin
  Result := nil;
  root := RecoveryRootDir;
  self_ := InstanceDirName;
  if FindFirst(root + PathDelim + '*', faDirectory, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') then Continue;
      if (sr.Attr and faDirectory) = 0 then Continue;
      if sr.Name = self_ then Continue;           // notre propre instance
      sub := root + PathDelim + sr.Name;
      if not InstanceDirIsDead(sub) then Continue; // instance encore vivante
      CollectFromDir(sub, Result);
      SweepCleartextTemps(sub);  // efface les residus en clair d'un crash
      RemoveEmptyDeadDir(sub);   // menage: dossier mort sans copie de travail
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
end;

procedure DiscardRecovery(const AItem: TRecoveryItem);
var
  dir: string;
  sr: TSearchRec;
  onlyLock: Boolean;
begin
  if FileExists(AItem.WorkingPath) then DeleteFile(AItem.WorkingPath);
  if FileExists(AItem.WorkingPath + '-wal') then
    DeleteFile(AItem.WorkingPath + '-wal');
  if FileExists(AItem.WorkingPath + '-shm') then
    DeleteFile(AItem.WorkingPath + '-shm');
  if FileExists(OriginSidecar(AItem.WorkingPath)) then
    DeleteFile(OriginSidecar(AItem.WorkingPath));

  dir := ExtractFileDir(AItem.WorkingPath);
  onlyLock := True;
  if FindFirst(dir + PathDelim + '*', faAnyFile, sr) = 0 then
  begin
    repeat
      if (sr.Name = '.') or (sr.Name = '..') or (sr.Name = '.lock') then
        Continue;
      onlyLock := False;
      Break;
    until FindNext(sr) <> 0;
    FindClose(sr);
  end;
  if onlyLock then
  begin
    if FileExists(dir + PathDelim + '.lock') then
      DeleteFile(dir + PathDelim + '.lock');
    RemoveDir(dir);
  end;
end;

function RecoveryDisplayName(const AItem: TRecoveryItem): string;
begin
  if AItem.OriginPath <> '' then
    Result := ExtractFileName(AItem.OriginPath)
  else
    Result := 'Recovered document';
end;

end.
