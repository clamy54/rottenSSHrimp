unit uRecent;

{$mode objfpc}{$H+}

// MRU des documents .rsh (File > Open Recent). recent.json dans AppDataDir, en
// ecriture atomique ET privee: la liste des documents de connexions d'un
// administrateur dessine son infrastructure, elle n'a pas a etre lisible par
// les autres comptes de la machine.
//
// Plusieurs instances peuvent tourner en meme temps (un document = un verrou):
// le fichier est relu avant chaque ajout et a chaque ouverture du menu, dernier
// ecrivain gagne. Best effort de bout en bout: une MRU illisible ne doit jamais
// empecher d'ouvrir un document.

interface

const
  MAX_RECENT = 15;

// restaurer une session ne doit pas reordonner la MRU
var
  RecentSuspended: Boolean = False;

procedure RecentReload;
procedure RecentAdd(const APath: string);
procedure RecentRemove(const APath: string);
procedure RecentClear;
function RecentCount: Integer;
function RecentPath(AIndex: Integer): string;    // chemin BRUT (pour ouvrir)
function RecentDisplay(AIndex: Integer): string; // assaini (libelle de menu)

implementation

uses
  Classes, SysUtils, fpjson, jsonparser, uAppPaths, uSafeSave;

const
  MAX_FILE_BYTES = 64 * 1024;
  MAX_ENTRY_LEN  = 4096; // chemin plus long = entree ignoree
  MAX_DISPLAY    = 200;

var
  FList: TStringList;

// un chemin peut contenir des controles: pas de caption multi-lignes
function SanitizeEntry(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    if S[i] >= ' ' then
      Result := Result + S[i]
    else
      Result := Result + ' ';
    if Length(Result) >= MAX_DISPLAY then Break;
  end;
  Result := Trim(Result);
end;

function RecentFilePath: string;
begin
  Result := IncludeTrailingPathDelimiter(AppDataDir) + 'recent.json';
end;

function ReadWhole(const AFile: string; out AData: string): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  AData := '';
  fs := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    if (fs.Size <= 0) or (fs.Size > MAX_FILE_BYTES) then Exit;
    SetLength(AData, fs.Size);
    fs.ReadBuffer(AData[1], fs.Size);
    Result := True;
  finally
    fs.Free;
  end;
end;

function EntryOK(const S: string): Boolean;
begin
  Result := (S <> '') and (Length(S) <= MAX_ENTRY_LEN) and
    (SanitizeEntry(S) <> ''); // que des controles/espaces = dechet
end;

procedure RecentReload;
var
  data, entry: string;
  root: TJSONData;
  arr: TJSONArray;
  i: Integer;
begin
  FList.Clear;
  root := nil;
  try
    try
      if not FileExists(RecentFilePath) then Exit;
      if not ReadWhole(RecentFilePath, data) then Exit;
      // GetJSON refuse un BOM UTF-8
      if (Length(data) >= 3) and (data[1] = #$EF) and (data[2] = #$BB) and
         (data[3] = #$BF) then
        Delete(data, 1, 3);
      root := GetJSON(data);
      if (root = nil) or (root.JSONType <> jtArray) then Exit;
      arr := TJSONArray(root);
      for i := 0 to arr.Count - 1 do
      begin
        if arr[i].JSONType <> jtString then Continue;
        entry := arr[i].AsString;
        if not EntryOK(entry) then Continue;
        FList.Add(entry);
        if FList.Count >= MAX_RECENT then Break;
      end;
    except
      FList.Clear; // fichier corrompu/verrouille: liste vide, pas d'erreur
    end;
  finally
    // sans le finally, un Exit (JSON non-tableau) fuit l'arbre a chaque popup
    root.Free;
  end;
end;

procedure SaveList;
var
  data: string;
  arr: TJSONArray;
  i: Integer;
begin
  try
    ForceDirectories(AppDataDir);
    arr := TJSONArray.Create;
    try
      for i := 0 to FList.Count - 1 do
        arr.Add(FList[i]);
      data := arr.FormatJSON;
    finally
      arr.Free;
    end;
    // privee, pas seulement atomique: voir l'en-tete de l'unite
    SavePrivateFile(RecentFilePath, data);
  except
    on E: Exception do
      ;   // best effort: la MRU ne casse jamais l'operation en cours
  end;
end;

// Chemin canonique, pour ne pas lister deux fois le meme document atteint par
// deux ecritures differentes (symlink, casse, chemin relatif).
function Canonical(const APath: string): string;
begin
  try
    Result := ExpandFileName(ResolveLink(ExpandFileName(APath)));
  except
    on E: Exception do
      Result := ExpandFileName(APath);
  end;
end;

procedure DropSame(const AFull: string);
var
  i: Integer;
  canon: string;
begin
  canon := Canonical(AFull);
  for i := FList.Count - 1 downto 0 do
    if SameFileName(FList[i], AFull) or SameFileName(Canonical(FList[i]), canon) then
      FList.Delete(i);
end;

procedure RecentAdd(const APath: string);
var
  full: string;
begin
  if RecentSuspended then Exit;
  if APath = '' then Exit;
  full := ExpandFileName(APath);
  if not EntryOK(full) then Exit;
  RecentReload; // fusion avec ce que les autres instances ont ecrit
  DropSame(full);
  FList.Insert(0, full);
  while FList.Count > MAX_RECENT do
    FList.Delete(FList.Count - 1);
  SaveList;
end;

procedure RecentRemove(const APath: string);
var
  before: Integer;
begin
  if APath = '' then Exit;
  RecentReload;
  before := FList.Count;
  DropSame(ExpandFileName(APath));
  if FList.Count <> before then
    SaveList;
end;

procedure RecentClear;
begin
  FList.Clear;
  SaveList;
end;

function RecentCount: Integer;
begin
  Result := FList.Count;
end;

function RecentPath(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex < FList.Count) then
    Result := FList[AIndex]
  else
    Result := '';
end;

function RecentDisplay(AIndex: Integer): string;
begin
  Result := SanitizeEntry(RecentPath(AIndex));
end;

initialization
  FList := TStringList.Create;

finalization
  FList.Free;

end.
