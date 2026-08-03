unit uImportExport;

{$mode objfpc}{$H+}

// Import et export, sans dependance LCL (donc testable en console). Aucun
// secret ne sort JAMAIS: les formats sont incapables d'en transporter, les
// credentials partent par reference. L'import traite ses entrees comme hostiles.

interface

uses
  Classes, SysUtils, uRshModel;

type
  EImportExportError = class(Exception);

  TExportFormat = (efJson, efCsv);

  TImportReport = record
    GroupsCreated: Integer;
    ConnectionsCreated: Integer;
    Skipped: Integer;
    Messages: TStringList;   // possede par l'appelant
  end;

function ExportSubtree(AModel: TRshModel; const ARootUuid: string;
  AFormat: TExportFormat): string;

function ImportOpenSshConfig(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;

function ImportJson(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;

function ImportHostsCsv(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;

const
  MAX_IMPORT_FILE_BYTES = 8 * 1024 * 1024;
  MAX_IMPORT_ENTRIES = 5000;

function NewImportReport: TImportReport;

implementation

uses
  fpjson, jsonparser, uRshValidation, uCryptoPolicy;

const
  // Refusee avant le parseur: ne protege que sa pile, pas l'arbre du modele.
  MAX_JSON_DEPTH = 256;
  JSON_FORMAT_NAME = 'rottensshrimp-export';
  JSON_FORMAT_VERSION = 1;

function NewImportReport: TImportReport;
begin
  Result.GroupsCreated := 0;
  Result.ConnectionsCreated := 0;
  Result.Skipped := 0;
  Result.Messages := TStringList.Create;
end;

procedure AddFolderCredentialRefs(AModel: TRshModel; const AFolderUuid: string;
  AObj: TJSONObject);
var
  p: TRshProtocol;
  credUuid: string;
  cred: TRshCredential;
  refs, one: TJSONObject;
begin
  refs := TJSONObject.Create;
  for p := rpSsh to rpVnc do
  begin
    credUuid := AModel.GetFolderCredential(AFolderUuid, p);
    if credUuid = '' then Continue;
    try
      cred := AModel.GetCredential(credUuid);
    except
      on EModelError do Continue;
    end;
    try
      one := TJSONObject.Create;
      one.Add('credential_name', cred.DisplayName);
      if cred.Username <> '' then
        one.Add('username', cred.Username);
      one.Add('auth_type', AUTH_TYPE_NAMES[cred.AuthType]);
      refs.Add(PROTOCOL_NAMES[p], one);
    finally
      cred.Free;
    end;
  end;
  if refs.Count > 0 then
    AObj.Add('folder_credentials', refs)
  else
    refs.Free;
end;

// ADepth borne la recursion: une chaine de parents cyclique deborderait la pile.
function NodeToJson(AModel: TRshModel; ANodes: TRshNodeList;
  const AUuid: string; ADepth: Integer): TJSONObject;
var
  i: Integer;
  kids: TJSONArray;
  n, child: TRshNode;
  cred: TRshCredential;
  credUuid: string;
begin
  Result := TJSONObject.Create;
  if ADepth > MAX_TREE_DEPTH then
  begin
    Result.Add('error', 'branch too deep, truncated');
    Exit;
  end;
  n := nil;
  for i := 0 to ANodes.Count - 1 do
    if ANodes[i].Uuid = AUuid then
    begin
      n := ANodes[i];
      Break;
    end;

  if n <> nil then
  begin
    Result.Add('name', n.DisplayName);
    if n.Kind = nkGroup then
      Result.Add('type', 'group')
    else
      Result.Add('type', 'connection');
    if n.Description <> '' then
      Result.Add('description', n.Description);
    // credentials de dossier par reference: l'import les ignore
    if n.Kind = nkGroup then
      AddFolderCredentialRefs(AModel, n.Uuid, Result);
    if n.Kind = nkConnection then
    begin
      Result.Add('protocol', PROTOCOL_NAMES[n.Protocol]);
      Result.Add('hostname', n.Hostname);
      Result.Add('port', n.Port);
      if n.ConnectTimeoutS > 0 then
        Result.Add('timeout_s', n.ConnectTimeoutS);
      credUuid := n.CredentialUuid;
      if credUuid <> '' then
      try
        cred := AModel.GetCredential(credUuid);
        try
          Result.Add('credential_name', cred.DisplayName);
          if cred.Username <> '' then
            Result.Add('username', cred.Username);
          Result.Add('auth_type', AUTH_TYPE_NAMES[cred.AuthType]);
        finally
          cred.Free;
        end;
      except
        on EModelError do ;
      end;
    end;
  end;

  kids := TJSONArray.Create;
  for i := 0 to ANodes.Count - 1 do
    if ANodes[i].ParentUuid = AUuid then
    begin
      child := ANodes[i];
      kids.Add(NodeToJson(AModel, ANodes, child.Uuid, ADepth + 1));
    end;
  if kids.Count > 0 then
    Result.Add('children', kids)
  else
    kids.Free;
end;

function CsvField(const S: string): string;
var
  v: string;
begin
  v := S;
  // CSV injection: Excel execute = + - @ en tete de cellule, l'apostrophe non.
  if (v <> '') and (v[1] in ['=', '+', '-', '@', #9, #13]) then
    v := '''' + v;
  Result := '"' + StringReplace(v, '"', '""', [rfReplaceAll]) + '"';
end;

procedure AppendCsvRows(AModel: TRshModel; ANodes: TRshNodeList;
  const AUuid, APath: string; AOut: TStringList; ADepth: Integer);
var
  i: Integer;
  n: TRshNode;
  cred: TRshCredential;
  credName, user, childPath: string;
begin
  if ADepth > MAX_TREE_DEPTH then
    Exit;
  for i := 0 to ANodes.Count - 1 do
  begin
    if ANodes[i].ParentUuid <> AUuid then Continue;
    n := ANodes[i];
    if APath = '' then
      childPath := n.DisplayName
    else
      childPath := APath + '/' + n.DisplayName;

    if n.Kind = nkConnection then
    begin
      credName := '';
      user := '';
      if n.CredentialUuid <> '' then
      try
        cred := AModel.GetCredential(n.CredentialUuid);
        try
          credName := cred.DisplayName;
          user := cred.Username;
        finally
          cred.Free;
        end;
      except
        on EModelError do ;
      end;
      AOut.Add(CsvField(APath) + ',' + CsvField(n.DisplayName) + ',' +
        CsvField(PROTOCOL_NAMES[n.Protocol]) + ',' +
        CsvField(n.Hostname) + ',' + CsvField(IntToStr(n.Port)) + ',' +
        CsvField(user) + ',' + CsvField(credName));
    end
    else
      AppendCsvRows(AModel, ANodes, n.Uuid, childPath, AOut, ADepth + 1);
  end;
end;

function ExportSubtree(AModel: TRshModel; const ARootUuid: string;
  AFormat: TExportFormat): string;
var
  nodes: TRshNodeList;
  root: TJSONObject;
  doc: TJSONObject;
  lines: TStringList;
begin
  if AModel = nil then
    raise EImportExportError.Create('No document open.');
  nodes := AModel.LoadNodes;
  try
    case AFormat of
      efJson:
        begin
          doc := TJSONObject.Create;
          try
            doc.Add('format', JSON_FORMAT_NAME);
            doc.Add('version', JSON_FORMAT_VERSION);
            doc.Add('contains_secrets', False);
            root := NodeToJson(AModel, nodes, ARootUuid, 0);
            doc.Add('root', root);
            Result := doc.FormatJSON;
          finally
            doc.Free;
          end;
        end;
      efCsv:
        begin
          lines := TStringList.Create;
          try
            lines.Add('group_path,name,protocol,hostname,port,username,' +
              'credential_name');
            AppendCsvRows(AModel, nodes, ARootUuid, '', lines, 0);
            Result := lines.Text;
          finally
            lines.Free;
          end;
        end;
    end;
  finally
    nodes.Free;
  end;
end;

function TryCreateConnection(AModel: TRshModel; const AParent, AName: string;
  AProto: TRshProtocol; const AHost: string; APort: Integer;
  var AReport: TImportReport; AInheritCredential: Boolean = False): Boolean;
begin
  Result := False;
  try
    AModel.CreateConnection(AParent, AName, AProto, AHost, APort,
      AInheritCredential);
    Inc(AReport.ConnectionsCreated);
    Result := True;
  except
    on E: EModelError do
    begin
      Inc(AReport.Skipped);
      AReport.Messages.Add(Format('"%s" skipped: %s', [AName, E.Message]));
    end;
  end;
end;

function ImportOpenSshConfig(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;
var
  rep: TImportReport;
  lines: TStringList;
  i, sp, port, entries: Integer;
  ok: Boolean;
  line, key, value, curHost, curHostName: string;

  procedure FlushHost;
  var
    host: string;
  begin
    if curHost = '' then Exit;
    // Sans HostName explicite, OpenSSH utilise le nom de l'entree.
    host := curHostName;
    if host = '' then host := curHost;
    TryCreateConnection(AModel, AParentUuid, curHost, rpSsh, host, port, rep);
    curHost := '';
    curHostName := '';
    port := 22;
  end;

begin
  rep := NewImportReport;
  port := 22;
  curHost := '';
  curHostName := '';
  entries := 0;
  ok := False;

  lines := TStringList.Create;
  try
    // Le finally exterieur possede les ressources, l'interieur la transaction.
    AModel.BeginBatch;
    try
      lines.Text := AText;
      for i := 0 to lines.Count - 1 do
      begin
        line := Trim(lines[i]);
        if (line = '') or (line[1] = '#') then Continue;
        // OpenSSH accepte espace, tabulation ou « cle=valeur »: tout a l'espace.
        line := StringReplace(line, #9, ' ', [rfReplaceAll]);
        line := StringReplace(line, '=', ' ', []);
        sp := Pos(' ', line);
        if sp = 0 then Continue;
        key := LowerCase(Copy(line, 1, sp - 1));
        value := Trim(Copy(line, sp + 1, MaxInt));
        if value = '' then Continue;

        if key = 'host' then
        begin
          FlushHost;
          Inc(entries);
          if entries > MAX_IMPORT_ENTRIES then
            raise EImportExportError.CreateFmt(
              'File too large: more than %d entries.',
              [MAX_IMPORT_ENTRIES]);
          // « Host * » n'est pas un hote; reinitialiser, sinon un HostName pose
          // sous le motif deborde sur l'hote reel suivant.
          if (Pos('*', value) > 0) or (Pos('?', value) > 0) then
          begin
            rep.Messages.Add(Format('pattern "%s" ignored', [value]));
            curHost := '';
            curHostName := '';
            port := 22;
            Continue;
          end;
          sp := Pos(' ', value);
          if sp > 0 then
            value := Copy(value, 1, sp - 1);
          curHost := value;
        end
        else if (key = 'hostname') and (curHost <> '') then
          curHostName := value
        else if (key = 'port') and (curHost <> '') then
        begin
          port := StrToIntDef(value, 22);
          if (port < 1) or (port > 65535) then port := 22;
        end;
      end;
      FlushHost;
      AModel.CommitBatch;
      ok := True;
    finally
      if not ok then
        AModel.RollbackBatch;
    end;
  finally
    lines.Free;
    // rep.Messages ne passe a l'appelant que si on rend un rapport.
    if not ok then
      FreeAndNil(rep.Messages);
  end;
  Result := rep;
end;

// Strict: retyper en silence l'hote d'un fichier etranger le trahirait.
function KnownProtocol(const S: string; out AProto: TRshProtocol): Boolean;
var
  p: TRshProtocol;
begin
  Result := False;
  for p := Low(TRshProtocol) to High(TRshProtocol) do
    if PROTOCOL_NAMES[p] = S then
    begin
      AProto := p;
      Exit(True);
    end;
end;

procedure ImportJsonNode(AModel: TRshModel; const AParentUuid: string;
  ANode: TJSONObject; ADepth: Integer; var AReport: TImportReport;
  var AEntries: Integer);
var
  kind, name, host, proto: string;
  protoVal: TRshProtocol;
  port, i: Integer;
  kids: TJSONArray;
  newParent: string;
begin
  if ANode = nil then Exit;
  if ADepth > 64 then
  begin
    Inc(AReport.Skipped);
    AReport.Messages.Add('branch too deep, skipped');
    Exit;
  end;
  Inc(AEntries);
  if AEntries > MAX_IMPORT_ENTRIES then
    raise EImportExportError.CreateFmt(
      'File too large: more than %d entries.', [MAX_IMPORT_ENTRIES]);

  name := ANode.Get('name', '');
  kind := ANode.Get('type', '');

  // Racine virtuelle: traversee sans rien creer, sinon reimport a vide.
  if (name = '') and (kind = '') and (ANode.Find('children', jtArray) <> nil) then
  begin
    kids := ANode.Arrays['children'];
    for i := 0 to kids.Count - 1 do
      if kids.Items[i].JSONType = jtObject then
        ImportJsonNode(AModel, AParentUuid, TJSONObject(kids.Items[i]),
          ADepth + 1, AReport, AEntries);
    Exit;
  end;

  if name = '' then
  begin
    Inc(AReport.Skipped);
    Exit;
  end;

  if kind = 'connection' then
  begin
    // Cle absente = ssh (fichier ecrit a la main); presente mais inconnue = ecartee.
    proto := ANode.Get('protocol', 'ssh');
    if not KnownProtocol(proto, protoVal) then
    begin
      Inc(AReport.Skipped);
      AReport.Messages.Add(Format('"%s" skipped: unknown protocol "%s"',
        [name, proto]));
      Exit;
    end;
    host := ANode.Get('hostname', '');
    port := ANode.Get('port', 0);
    if port = 0 then
      case protoVal of
        rpRdp: port := 3389;
        rpVnc: port := 5900;   // et pas 22: un ecran VNC n'est pas un shell
      else
        port := 22;
      end;
    TryCreateConnection(AModel, AParentUuid, name, protoVal,
      host, port, AReport);
    Exit;
  end;

  if kind <> 'group' then
  begin
    Inc(AReport.Skipped);
    AReport.Messages.Add(Format('"%s" skipped: unknown type "%s"',
      [name, kind]));
    Exit;
  end;

  try
    newParent := AModel.CreateGroup(AParentUuid, name);
    Inc(AReport.GroupsCreated);
  except
    on E: EModelError do
    begin
      Inc(AReport.Skipped);
      AReport.Messages.Add(Format('folder "%s" skipped: %s',
        [name, E.Message]));
      Exit;
    end;
  end;

  if ANode.Find('children', jtArray) <> nil then
  begin
    kids := ANode.Arrays['children'];
    for i := 0 to kids.Count - 1 do
      if kids.Items[i].JSONType = jtObject then
        ImportJsonNode(AModel, newParent, TJSONObject(kids.Items[i]),
          ADepth + 1, AReport, AEntries);
  end;
end;

function JsonNestingTooDeep(const AText: string; AMax: Integer): Boolean; forward;

function ImportJson(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;
var
  data: TJSONData;
  doc, root: TJSONObject;
  rep: TImportReport;
  entries, ver: Integer;
begin
  rep := NewImportReport;
  data := nil;
  // GetJSON construit le DOM par recursion: dix mille '[' epuisent sa pile.
  if JsonNestingTooDeep(AText, MAX_JSON_DEPTH) then
  begin
    rep.Messages.Free;
    raise EImportExportError.CreateFmt(
      'JSON nesting is deeper than %d levels.', [MAX_JSON_DEPTH]);
  end;
  try
    try
      data := GetJSON(AText);
    except
      on E: Exception do
      begin
        rep.Messages.Free;
        raise EImportExportError.Create('Unreadable JSON file.');
      end;
    end;
    if (data = nil) or (data.JSONType <> jtObject) then
    begin
      rep.Messages.Free;
      raise EImportExportError.Create('This is not a RottenSSHrimp export.');
    end;
    doc := TJSONObject(data);
    if doc.Get('format', '') <> JSON_FORMAT_NAME then
    begin
      rep.Messages.Free;
      raise EImportExportError.Create('This is not a RottenSSHrimp export.');
    end;
    ver := doc.Get('version', 0);
    if ver < 1 then
    begin
      rep.Messages.Free;
      raise EImportExportError.Create('This is not a RottenSSHrimp export.');
    end;
    if ver > JSON_FORMAT_VERSION then
    begin
      rep.Messages.Free;
      raise EImportExportError.Create(
        'This export comes from a newer version of RottenSSHrimp.');
    end;
    root := nil;
    if doc.Find('root', jtObject) <> nil then
      root := doc.Objects['root'];
    if root <> nil then
    begin
      entries := 0;
      // Un seul batch: le content_mac n'est re-scelle qu'une fois, sinon O(n^2).
      AModel.BeginBatch;
      try
        ImportJsonNode(AModel, AParentUuid, root, 0, rep, entries);
        AModel.CommitBatch;
      except
        on E: EImportExportError do
        begin
          AModel.RollbackBatch;
          rep.Messages.Free;
          raise;
        end;
        on E: Exception do
        begin
          AModel.RollbackBatch;
          rep.Messages.Free;
          raise EImportExportError.Create('Import aborted: ' + E.Message);
        end;
      end;
    end;
    Result := rep;
  finally
    data.Free;
  end;
end;

function JsonNestingTooDeep(const AText: string; AMax: Integer): Boolean;
var
  i, depth: Integer;
  inStr, esc: Boolean;
  c: Char;
begin
  Result := False;
  depth := 0;
  inStr := False;
  esc := False;
  for i := 1 to Length(AText) do
  begin
    c := AText[i];
    if inStr then
    begin
      if esc then esc := False
      else if c = '\' then esc := True
      else if c = '"' then inStr := False;
      Continue;
    end;
    case c of
      '"': inStr := True;
      '[', '{':
        begin
          Inc(depth);
          if depth > AMax then Exit(True);
        end;
      ']', '}': if depth > 0 then Dec(depth);
    end;
  end;
end;

const
  // Au-dela on cesse d'accumuler: une quote non fermee coute quadratique.
  MAX_CSV_FIELD = 8192;

function DetectDelimiter(const S: string): Char;
var
  i, nComma, nSemi, nTab: Integer;
begin
  nComma := 0; nSemi := 0; nTab := 0;
  for i := 1 to Length(S) do
  begin
    if S[i] in [#10, #13] then Break;
    case S[i] of
      ',': Inc(nComma);
      ';': Inc(nSemi);
      #9:  Inc(nTab);
    end;
  end;
  if (nSemi >= nComma) and (nSemi >= nTab) and (nSemi > 0) then
    Result := ';'
  else if (nTab >= nComma) and (nTab > 0) then
    Result := #9
  else
    Result := ',';
end;

function ReadCsvRecord(const S: string; var APos: Integer; ADelim: Char;
  AFields: TStringList; out AOversized: Boolean;
  out AUnterminated: Boolean): Boolean;
var
  c: Char;
  field: string;
  inQuotes, atStart: Boolean;
begin
  AFields.Clear;
  AOversized := False;
  AUnterminated := False;
  if APos > Length(S) then Exit(False);
  field := '';
  inQuotes := False;
  atStart := True;
  while APos <= Length(S) do
  begin
    c := S[APos];
    if inQuotes then
    begin
      if c = '"' then
      begin
        if (APos < Length(S)) and (S[APos + 1] = '"') then
        begin
          if Length(field) < MAX_CSV_FIELD then field := field + '"'
          else AOversized := True;
          Inc(APos, 2);
        end
        else
        begin
          inQuotes := False;
          atStart := False;
          Inc(APos);
        end;
      end
      else
      begin
        if Length(field) < MAX_CSV_FIELD then field := field + c
        else AOversized := True;
        Inc(APos);
      end;
    end
    else
    begin
      if (c = '"') and atStart then
      begin
        inQuotes := True;
        atStart := False;
        Inc(APos);
      end
      else if c = ADelim then
      begin
        AFields.Add(field);
        field := '';
        atStart := True;
        Inc(APos);
      end
      else if c = #10 then
      begin
        Inc(APos);
        Break;
      end
      else if c = #13 then
      begin
        Inc(APos);
        if (APos <= Length(S)) and (S[APos] = #10) then Inc(APos);
        Break;
      end
      else
      begin
        if Length(field) < MAX_CSV_FIELD then field := field + c
        else AOversized := True;
        atStart := False;
        Inc(APos);
      end;
    end;
  end;
  AFields.Add(field);
  // Guillemet jamais referme = tout le reste du fichier avale en un champ.
  AUnterminated := inQuotes;
  Result := True;
end;

function TryParseProtocol(const S: string; out AProto: TRshProtocol): Boolean;
var
  t: string;
begin
  t := LowerCase(Trim(S));
  Result := True;
  if t = 'ssh' then AProto := rpSsh
  else if t = 'rdp' then AProto := rpRdp
  else if t = 'vnc' then AProto := rpVnc
  else Result := False;
end;

function NormHeader(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c in ['A'..'Z'] then
      Result := Result + Chr(Ord(c) + 32)
    else if c in ['a'..'z', '0'..'9'] then
      Result := Result + c;
  end;
end;

function DefaultPortFor(AProto: TRshProtocol): Integer;
begin
  case AProto of
    rpRdp: Result := 3389;
    rpVnc: Result := 5900;
  else
    Result := 22;
  end;
end;

function ImportHostsCsv(AModel: TRshModel; const AParentUuid: string;
  const AText: string): TImportReport;
var
  rep: TImportReport;
  text: string;
  delim: Char;
  cursor, lineNo, entries: Integer;
  fields, header: TStringList;
  existNames, existHosts: TStringList;
  idxName, idxIp, idxType, idxPort, i: Integer;
  oversized, blank, unterminated: Boolean;
  name, ip, typeStr, portStr, keyN, keyH: string;
  proto: TRshProtocol;
  port: Integer;
  nodes: TRshNodeList;

  function ColOf(AFields: TStringList; AIdx: Integer): string;
  begin
    if (AIdx >= 0) and (AIdx < AFields.Count) then
      Result := Trim(AFields[AIdx])
    else
      Result := '';
  end;

begin
  rep := NewImportReport;

  if Length(AText) > MAX_IMPORT_FILE_BYTES then
  begin
    FreeAndNil(rep.Messages);
    raise EImportExportError.CreateFmt(
      'File too large (max %d bytes).', [MAX_IMPORT_FILE_BYTES]);
  end;

  text := AText;
  // BOM UTF-8: Excel en pose un a chaque fois.
  if (Length(text) >= 3) and (text[1] = #$EF) and (text[2] = #$BB) and
     (text[3] = #$BF) then
    Delete(text, 1, 3);

  delim := DetectDelimiter(text);

  fields := TStringList.Create;
  header := TStringList.Create;
  existNames := TStringList.Create;
  existHosts := TStringList.Create;
  try
   try
    existNames.Sorted := True;
    existNames.CaseSensitive := False;
    existNames.Duplicates := dupIgnore;
    existHosts.Sorted := True;
    existHosts.CaseSensitive := False;
    existHosts.Duplicates := dupIgnore;

    nodes := AModel.LoadNodes;
    try
      for i := 0 to nodes.Count - 1 do
        if nodes[i].Kind = nkConnection then
        begin
          if nodes[i].DisplayName <> '' then
            existNames.Add(LowerCase(Trim(nodes[i].DisplayName)));
          if nodes[i].Hostname <> '' then
            existHosts.Add(LowerCase(Trim(nodes[i].Hostname)));
        end;
    finally
      nodes.Free;
    end;

    cursor := 1;
    if not ReadCsvRecord(text, cursor, delim, header, oversized,
      unterminated) then
    begin
      rep.Messages.Add('Empty file.');
      Result := rep;
      Exit;
    end;
    idxName := -1; idxIp := -1; idxType := -1; idxPort := -1;
    for i := 0 to header.Count - 1 do
    begin
      case NormHeader(header[i]) of
        'name', 'nom', 'node', 'nodename', 'nodedelhote', 'label', 'alias':
          if idxName < 0 then idxName := i;
        'ip', 'adresse', 'address', 'addr', 'host', 'hostname', 'ipaddress':
          if idxIp < 0 then idxIp := i;
        'type', 'protocol', 'protocole', 'proto':
          if idxType < 0 then idxType := i;
        'port':
          if idxPort < 0 then idxPort := i;
      end;
    end;
    if (idxName < 0) or (idxIp < 0) or (idxType < 0) then
    begin
      FreeAndNil(rep.Messages);
      raise EImportExportError.Create(
        'Invalid CSV header: columns for name, ip and type (ssh/rdp/vnc) ' +
        'are required. Port is optional.');
    end;

    entries := 0;
    lineNo := 1;

    // BeginBatch DANS le try: dehors, une levee sautait le RollbackBatch.
    try
      AModel.BeginBatch;
      while ReadCsvRecord(text, cursor, delim, fields, oversized,
        unterminated) do
      begin
        Inc(lineNo);
        Inc(entries);
        if entries > MAX_IMPORT_ENTRIES then
          raise EImportExportError.CreateFmt(
            'File too large: more than %d rows.', [MAX_IMPORT_ENTRIES]);

        // Tester TOUS les champs: un tableur exporte des lignes « ,,, » vides.
        blank := True;
        for i := 0 to fields.Count - 1 do
          if Trim(fields[i]) <> '' then
          begin
            blank := False;
            Break;
          end;
        if blank then
        begin
          Dec(entries);
          Continue;
        end;

        if unterminated then
        begin
          Inc(rep.Skipped);
          rep.Messages.Add(Format('row %d skipped: unterminated quoted field ' +
            '-- everything after it was read as a single value.', [lineNo]));
          Continue;
        end;
        if oversized then
        begin
          Inc(rep.Skipped);
          rep.Messages.Add(Format('row %d skipped: oversized field.', [lineNo]));
          Continue;
        end;

        name := ColOf(fields, idxName);
        ip := ColOf(fields, idxIp);
        typeStr := ColOf(fields, idxType);
        portStr := ColOf(fields, idxPort);

        if (name = '') or (ip = '') or (typeStr = '') then
        begin
          Inc(rep.Skipped);
          rep.Messages.Add(Format(
            'row %d skipped: missing name, ip or type.', [lineNo]));
          Continue;
        end;

        if not TryParseProtocol(typeStr, proto) then
        begin
          Inc(rep.Skipped);
          rep.Messages.Add(Format(
            'row %d skipped: unknown type "%s" (ssh, rdp or vnc).',
            [lineNo, typeStr]));
          Continue;
        end;

        if (idxPort < 0) or (portStr = '') then
          port := DefaultPortFor(proto)
        else
        begin
          port := StrToIntDef(portStr, -1);
          if (port < 1) or (port > 65535) then
          begin
            Inc(rep.Skipped);
            rep.Messages.Add(Format(
              'row %d skipped: invalid port "%s".', [lineNo, portStr]));
            Continue;
          end;
        end;

        keyN := LowerCase(name);
        keyH := LowerCase(ip);
        if (existNames.IndexOf(keyN) >= 0) or (existHosts.IndexOf(keyH) >= 0) then
        begin
          Inc(rep.Skipped);
          rep.Messages.Add(Format(
            'row %d skipped: "%s" (%s) already exists.', [lineNo, name, ip]));
          Continue;
        end;

        if TryCreateConnection(AModel, AParentUuid, name, proto, ip, port, rep,
          True) then
        begin
          existNames.Add(keyN);
          existHosts.Add(keyH);
        end;
      end;
      AModel.CommitBatch;
    except
      on E: EImportExportError do
      begin
        AModel.RollbackBatch;
        FreeAndNil(rep.Messages);
        raise;
      end;
      on E: Exception do
      begin
        AModel.RollbackBatch;
        FreeAndNil(rep.Messages);
        raise EImportExportError.Create('Import aborted: ' + E.Message);
      end;
    end;

    Result := rep;
   except
     if rep.Messages <> nil then
       FreeAndNil(rep.Messages);
     raise;
   end;
  finally
    fields.Free;
    header.Free;
    existNames.Free;
    existHosts.Free;
  end;
end;

end.
