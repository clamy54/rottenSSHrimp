program gentreeicons;

{$mode objfpc}{$H+}

// Genere le catalogue d'icones d'arborescence. Trois GROUPES (dossiers, hotes,
// etendu), et pour chacun deux sortes de sources:
//
//   1) monochrome    icons/folders/       icons/hosts/
//      Trace sombre sur fond transparent. On en derive les deux variantes en
//      reposant l'alpha sur une couleur pleine (noir ou blanc).
//
//   2) paires deja faites  icons/folders-dark/ + icons/folders-light/
//                          icons/hosts-dark/   + icons/hosts-light/
//      Icones couleur fournies en deux versions. Utilisees telles quelles.
//      Le suffixe du repertoire designe le THEME vise ("-dark" = pour theme
//      sombre), et non la couleur du trace.
//
//
// Outil de build uniquement. Ne depend que de la FCL:
//   fpc -O2 scripts/gen-tree-icons.lpr && scripts/gen-tree-icons

uses
  SysUtils, Classes, Math,
  FPImage, FPReadPNG, FPWritePNG;

type
  TDoubleArray = array of Double;
  TDoubleMatrix = array of TDoubleArray;
  TIntArray = array of Integer;

const
  SIZES: array[0..3] of Integer = (16, 24, 32, 48);

  ONDARK  = 'ondark';    // affichee sur fond sombre
  ONLIGHT = 'onlight';   // affichee sur fond clair

  GROUP_COUNT = 3;
  GROUPS: array[0..GROUP_COUNT - 1, 0..3] of string = (
    ('folders', 'folders', 'folders-dark', 'folders-light'),
    ('hosts', 'hosts', 'hosts-dark', 'hosts-light'),
    ('extended', 'extended-set', 'extended-dark', 'extended-light')
  );

var
  Root, IconsDir, DstDir, IncFile, LpiFile: string;
  Entries: TStringList;      // 'RESNAME'=chemin relatif au depot
  Seen: TStringList;         // id=groupe
  Skipped: TStringList;      // id=groupe proprietaire
  GroupIds: array[0..GROUP_COUNT - 1] of TStringList;

function ByteCompare(List: TStringList; Index1, Index2: Integer): Integer;
begin
  Result := CompareStr(List[Index1], List[Index2]);
end;

procedure Die(const AMsg: string);
begin
  WriteLn(StdErr, AMsg);
  Halt(1);
end;

function LoadPng(const AFile: string): TFPMemoryImage;
begin
  Result := TFPMemoryImage.Create(0, 0);
  try
    Result.LoadFromFile(AFile);
  except
    on E: Exception do
    begin
      Result.Free;
      Die(Format('lecture impossible: %s (%s)', [AFile, E.Message]));
    end;
  end;
end;

procedure SavePng(AImg: TFPCustomImage; const AFile: string);
var
  w: TFPWriterPNG;
begin
  w := TFPWriterPNG.Create;
  try
    w.Indexed := False;
    w.WordSized := False;
    w.UseAlpha := True;
    AImg.SaveToFile(AFile, w);
  finally
    w.Free;
  end;
end;

function FullyOpaque(AImg: TFPCustomImage): Boolean;
var
  x, y: Integer;
begin
  for y := 0 to AImg.Height - 1 do
    for x := 0 to AImg.Width - 1 do
      if AImg.Colors[x, y].alpha <> alphaOpaque then
        Exit(False);
  Result := True;
end;

function Recolor(ASrc: TFPCustomImage; AR, AG, AB: Word): TFPMemoryImage;
var
  x, y: Integer;
  src, dst: TFPColor;
  lum: Integer;
  deriveFromLuminance: Boolean;
begin
  deriveFromLuminance := FullyOpaque(ASrc);

  Result := TFPMemoryImage.Create(ASrc.Width, ASrc.Height);
  for y := 0 to ASrc.Height - 1 do
    for x := 0 to ASrc.Width - 1 do
    begin
      src := ASrc.Colors[x, y];
      dst.red := AR;
      dst.green := AG;
      dst.blue := AB;
      if deriveFromLuminance then
      begin
        lum := (Integer(src.red shr 8) * 19595 +
                Integer(src.green shr 8) * 38470 +
                Integer(src.blue shr 8) * 7471 + $8000) shr 16;
        lum := 255 - Min(255, Max(0, lum));
        dst.alpha := Word(lum * 257);
      end
      else
        dst.alpha := src.alpha;
      Result.Colors[x, y] := dst;
    end;
end;
function LanczosKernel(x: Double): Double;
begin
  x := Abs(x);
  if x < 1e-9 then Exit(1.0);
  if x >= 3.0 then Exit(0.0);
  x := x * Pi;
  Result := (Sin(x) / x) * (Sin(x / 3.0) / (x / 3.0));
end;

procedure BuildWeights(ASrcSize, ADstSize: Integer;
  out AStarts: TIntArray; out ACoeffs: TDoubleMatrix);
var
  scale, filterScale, support, center, w, total: Double;
  i, k, lo, hi: Integer;
begin
  scale := ASrcSize / ADstSize;
  filterScale := Max(1.0, scale);
  support := 3.0 * filterScale;
  SetLength(AStarts, ADstSize);
  SetLength(ACoeffs, ADstSize);
  for i := 0 to ADstSize - 1 do
  begin
    center := (i + 0.5) * scale;
    lo := Max(0, Floor(center - support));
    hi := Min(ASrcSize, Ceil(center + support));
    if hi <= lo then begin lo := Min(lo, ASrcSize - 1); hi := lo + 1; end;
    AStarts[i] := lo;
    SetLength(ACoeffs[i], hi - lo);
    total := 0;
    for k := lo to hi - 1 do
    begin
      w := LanczosKernel((k + 0.5 - center) / filterScale);
      ACoeffs[i][k - lo] := w;
      total := total + w;
    end;
    if total <> 0 then
      for k := 0 to High(ACoeffs[i]) do
        ACoeffs[i][k] := ACoeffs[i][k] / total;
  end;
end;

function ClampChannel(v: Double): Word;
begin
  if v <= 0 then Exit(0);
  if v >= 65535 then Exit(65535);
  Result := Word(Round(v));
end;


function Resample(ASrc: TFPCustomImage; ASize: Integer): TFPMemoryImage;
var
  xs, ys: TIntArray;
  xc, yc: TDoubleMatrix;
  tmp: array of Double;          // ASize x srcH x 4 canaux
  srcW, srcH, x, y, k, idx: Integer;
  accR, accG, accB, accA, w: Double;
  c: TFPColor;
begin
  srcW := ASrc.Width;
  srcH := ASrc.Height;
  BuildWeights(srcW, ASize, xs, xc);
  BuildWeights(srcH, ASize, ys, yc);

  SetLength(tmp, ASize * srcH * 4);
  for y := 0 to srcH - 1 do
    for x := 0 to ASize - 1 do
    begin
      accR := 0; accG := 0; accB := 0; accA := 0;
      for k := 0 to High(xc[x]) do
      begin
        w := xc[x][k];
        c := ASrc.Colors[xs[x] + k, y];
        accR := accR + c.red * w;
        accG := accG + c.green * w;
        accB := accB + c.blue * w;
        accA := accA + c.alpha * w;
      end;
      idx := (y * ASize + x) * 4;
      tmp[idx] := accR; tmp[idx + 1] := accG;
      tmp[idx + 2] := accB; tmp[idx + 3] := accA;
    end;

  Result := TFPMemoryImage.Create(ASize, ASize);
  for y := 0 to ASize - 1 do
    for x := 0 to ASize - 1 do
    begin
      accR := 0; accG := 0; accB := 0; accA := 0;
      for k := 0 to High(yc[y]) do
      begin
        w := yc[y][k];
        idx := ((ys[y] + k) * ASize + x) * 4;
        accR := accR + tmp[idx] * w;
        accG := accG + tmp[idx + 1] * w;
        accB := accB + tmp[idx + 2] * w;
        accA := accA + tmp[idx + 3] * w;
      end;
      c.red := ClampChannel(accR);
      c.green := ClampChannel(accG);
      c.blue := ClampChannel(accB);
      c.alpha := ClampChannel(accA);
      Result.Colors[x, y] := c;
    end;
end;

function Rid(const AFileName: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(AFileName), '');
end;

function ResName(const AIconId, AVariant: string; ASize: Integer): string;
begin
  Result := Format('TREE_%s_%s_%d',
    [UpperCase(StringReplace(AIconId, '-', '_', [rfReplaceAll])),
     UpperCase(AVariant), ASize]);
end;

function Listing(const ASubDir: string; ARequired: Boolean;
  out ADir: string): TStringList;
var
  rec: TSearchRec;
begin
  ADir := IncludeTrailingPathDelimiter(IconsDir + ASubDir);
  Result := TStringList.Create;
  if not DirectoryExists(ADir) then
  begin
    if ARequired then
    begin
      Result.Free;
      Die('repertoire manquant: ' + ADir);
    end;
    Exit;
  end;
  if FindFirst(ADir + '*', faAnyFile, rec) = 0 then
  begin
    repeat
      if (rec.Attr and faDirectory) = 0 then
        if SameText(ExtractFileExt(rec.Name), '.png') then
          Result.Add(rec.Name);
    until FindNext(rec) <> 0;
    FindClose(rec);
  end;
  Result.CustomSort(@ByteCompare);
end;

procedure Emit(AImg: TFPCustomImage; const AIconId, AVariant: string);
var
  i: Integer;
  scaled: TFPMemoryImage;
  name: string;
begin
  for i := Low(SIZES) to High(SIZES) do
  begin
    scaled := Resample(AImg, SIZES[i]);
    try
      name := Format('%s_%s_%d.png', [AIconId, AVariant, SIZES[i]]);
      SavePng(scaled, DstDir + name);
      Entries.Add(ResName(AIconId, AVariant, SIZES[i]) + '=' +
        'resources/icons/tree/' + name);
    finally
      scaled.Free;
    end;
  end;
end;

function PascalArray(const AName: string; AIds: TStringList): string;
var
  i: Integer;
  body: string;
begin
  if AIds.Count = 0 then
    Exit(Format('  %s: array[0..0] of string = ('''');'#10, [AName]));
  body := '';
  for i := 0 to AIds.Count - 1 do
  begin
    if i > 0 then
      body := body + ','#10;
    body := body + '    ''' + AIds[i] + '''';
  end;
  Result := Format('  %s: array[0..%d] of string = ('#10'%s);'#10,
    [AName, AIds.Count - 1, body]);
end;

procedure WriteTextKeepingEol(const AFile, AText: string);
var
  f: TFileStream;
  existing, outText: string;
  crlf: Boolean;
begin
  crlf := False;
  if FileExists(AFile) then
  begin
    with TStringList.Create do
    try
      LoadFromFile(AFile);
      existing := Text;
    finally
      Free;
    end;
    f := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
    try
      SetLength(existing, f.Size);
      if f.Size > 0 then
        f.ReadBuffer(existing[1], f.Size);
    finally
      f.Free;
    end;
    crlf := Pos(#13#10, existing) > 0;
  end;

  outText := AText;
  if crlf then
    outText := StringReplace(outText, #10, #13#10, [rfReplaceAll]);

  f := TFileStream.Create(AFile, fmCreate);
  try
    if outText <> '' then
      f.WriteBuffer(outText[1], Length(outText));
  finally
    f.Free;
  end;
end;

procedure WriteInc;
var
  s: string;
begin
  s := '// GENERE par scripts/gen-tree-icons.lpr -- NE PAS EDITER.'#10 +
       '// Identifiants d''icones (= noms de fichiers). Stables:'#10 +
       '// stockes dans nodes.icon_id.'#10 +
       'const'#10 +
       PascalArray('TREE_FOLDER_IDS', GroupIds[0]) +
       PascalArray('TREE_HOST_IDS', GroupIds[1]) +
       PascalArray('TREE_EXTENDED_IDS', GroupIds[2]);
  WriteTextKeepingEol(IncFile, s);
end;

function ReadWholeFile(const AFile: string): string;
var
  f: TFileStream;
begin
  f := TFileStream.Create(AFile, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if f.Size > 0 then
      f.ReadBuffer(Result[1], f.Size);
  finally
    f.Free;
  end;
end;

function AttrValue(const ALine, AAttr: string): string;
var
  p, q: Integer;
begin
  Result := '';
  p := Pos(AAttr + '="', ALine);
  if p = 0 then Exit;
  Inc(p, Length(AAttr) + 2);
  q := p;
  while (q <= Length(ALine)) and (ALine[q] <> '"') do
    Inc(q);
  Result := Copy(ALine, p, q - p);
end;

procedure PatchLpi;
var
  text, block, line: string;
  lines: TStringList;
  kept: TStringList;
  i, startPos, endPos: Integer;
  fn, rn, crlfEol: string;
  total: Integer;
begin
  text := ReadWholeFile(LpiFile);

  startPos := Pos('<Resources Count="', text);
  if startPos = 0 then
    Die('bloc <Resources> introuvable dans ' + LpiFile);
  endPos := Pos('</Resources>', text);
  if (endPos = 0) or (endPos < startPos) then
    Die('bloc </Resources> introuvable dans ' + LpiFile);
  Inc(endPos, Length('</Resources>'));

  kept := TStringList.Create;
  lines := TStringList.Create;
  try
    lines.Text := Copy(text, startPos, endPos - startPos);
    for i := 0 to lines.Count - 1 do
    begin
      line := lines[i];
      if Pos('<Resource_', line) = 0 then Continue;
      if Pos('Type="RCDATA"', line) = 0 then Continue;
      fn := AttrValue(line, 'FileName');
      rn := AttrValue(line, 'ResourceName');
      if (fn = '') or (rn = '') then Continue;
      if Copy(rn, 1, 5) = 'TREE_' then Continue;
      kept.Add(fn + '=' + rn);
    end;

    if Pos(#13#10, text) > 0 then crlfEol := #13#10 else crlfEol := #10;

    total := kept.Count + Entries.Count;
    block := Format('<Resources Count="%d">', [total]);
    for i := 0 to kept.Count - 1 do
      block := block + crlfEol +
        Format('        <Resource_%d FileName="%s" Type="RCDATA" ResourceName="%s"/>',
          [i, kept.Names[i], kept.ValueFromIndex[i]]);
    for i := 0 to Entries.Count - 1 do
      block := block + crlfEol +
        Format('        <Resource_%d FileName="../%s" Type="RCDATA" ResourceName="%s"/>',
          [kept.Count + i, Entries.ValueFromIndex[i], Entries.Names[i]]);
    block := block + crlfEol + '      </Resources>';

    text := Copy(text, 1, startPos - 1) + block +
      Copy(text, endPos, Length(text) - endPos + 1);
  finally
    lines.Free;
    kept.Free;
  end;

  with TFileStream.Create(LpiFile, fmCreate) do
  try
    WriteBuffer(text[1], Length(text));
  finally
    Free;
  end;
end;

procedure ClearOldPngs;
var
  rec: TSearchRec;
begin
  ForceDirectories(DstDir);
  if FindFirst(DstDir + '*', faAnyFile, rec) = 0 then
  begin
    repeat
      if ((rec.Attr and faDirectory) = 0) and
         SameText(ExtractFileExt(rec.Name), '.png') then
        DeleteFile(DstDir + rec.Name);
    until FindNext(rec) <> 0;
    FindClose(rec);
  end;
end;

procedure ProcessGroups;
var
  g, i: Integer;
  group, monoDir, darkDir, lightDir: string;
  monoPath, darkPath, lightPath, iconId, lightFile: string;
  monoFiles, darkFiles, dummy: TStringList;
  catchall: Boolean;
  src, tinted: TFPMemoryImage;
begin
  for g := 0 to GROUP_COUNT - 1 do
  begin
    group := GROUPS[g, 0];
    monoDir := GROUPS[g, 1];
    darkDir := GROUPS[g, 2];
    lightDir := GROUPS[g, 3];
    catchall := group = 'extended';
    GroupIds[g] := TStringList.Create;

    monoFiles := Listing(monoDir, True, monoPath);
    try
      for i := 0 to monoFiles.Count - 1 do
      begin
        iconId := Rid(monoFiles[i]);
        if catchall and (Seen.IndexOfName(iconId) >= 0) then
        begin
          Skipped.Add(iconId + '=' + Seen.Values[iconId]);
          Continue;
        end;
        src := LoadPng(monoPath + monoFiles[i]);
        try
          tinted := Recolor(src, $FFFF, $FFFF, $FFFF);
          try
            Emit(tinted, iconId, ONDARK);
          finally
            tinted.Free;
          end;
          tinted := Recolor(src, 0, 0, 0);
          try
            Emit(tinted, iconId, ONLIGHT);
          finally
            tinted.Free;
          end;
        finally
          src.Free;
        end;
        GroupIds[g].Add(iconId);
      end;
    finally
      monoFiles.Free;
    end;
    darkFiles := Listing(darkDir, False, darkPath);
    dummy := Listing(lightDir, False, lightPath);
    try
      for i := 0 to darkFiles.Count - 1 do
      begin
        iconId := Rid(darkFiles[i]);
        if catchall and (Seen.IndexOfName(iconId) >= 0) then
        begin
          Skipped.Add(iconId + '=' + Seen.Values[iconId]);
          Continue;
        end;
        lightFile := lightPath + darkFiles[i];
        if not FileExists(lightFile) then
          Die(Format('paire incomplete: %s existe dans %s mais pas dans %s',
            [darkFiles[i], darkDir, lightDir]));
        src := LoadPng(darkPath + darkFiles[i]);
        try
          Emit(src, iconId, ONDARK);
        finally
          src.Free;
        end;
        src := LoadPng(lightFile);
        try
          Emit(src, iconId, ONLIGHT);
        finally
          src.Free;
        end;
        GroupIds[g].Add(iconId);
      end;
    finally
      darkFiles.Free;
      dummy.Free;
    end;

    for i := 0 to GroupIds[g].Count - 1 do
    begin
      iconId := GroupIds[g][i];
      if Seen.IndexOfName(iconId) >= 0 then
        Die(Format('identifiant en collision: %s (%s et %s)',
          [iconId, Seen.Values[iconId], group]));
      Seen.Add(iconId + '=' + group);
    end;
  end;
end;

var
  i: Integer;
begin
  Root := IncludeTrailingPathDelimiter(
    ExpandFileName(ExtractFilePath(ParamStr(0)) + '..'));
  if not DirectoryExists(Root + 'icons') then
    Root := IncludeTrailingPathDelimiter(GetCurrentDir);
  if not DirectoryExists(Root + 'icons') then
    Die('racine du depot introuvable (icons/ absent). Lancer depuis le depot.');

  IconsDir := Root + 'icons' + PathDelim;
  DstDir := Root + 'resources' + PathDelim + 'icons' + PathDelim + 'tree' +
    PathDelim;
  IncFile := Root + 'src' + PathDelim + 'ui' + PathDelim + 'uTreeIconCatalog.inc';
  LpiFile := Root + 'app' + PathDelim + 'rottensshrimp.lpi';

  Entries := TStringList.Create;
  Seen := TStringList.Create;
  Skipped := TStringList.Create;
  try
    ClearOldPngs;
    ProcessGroups;
    WriteInc;
    PatchLpi;

    for i := 0 to Skipped.Count - 1 do
      WriteLn(Format('collision ignoree: %s deja fourni par le groupe %s',
        [Skipped.Names[i], Skipped.ValueFromIndex[i]]));
    WriteLn(Format('%d icones (%d folders + %d hosts + %d extended) x 2 ' +
      'variantes x %d tailles -> %d PNG',
      [Seen.Count, GroupIds[0].Count, GroupIds[1].Count, GroupIds[2].Count,
       Length(SIZES), Entries.Count]));
  finally
    for i := 0 to GROUP_COUNT - 1 do
      GroupIds[i].Free;
    Skipped.Free;
    Seen.Free;
    Entries.Free;
  end;
end.
