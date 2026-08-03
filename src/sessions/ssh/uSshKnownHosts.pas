unit uSshKnownHosts;

{$mode objfpc}{$H+}

// Magasin TOFU des cles d'hote, table ssh_known_hosts. Il constate,
// il ne decide pas: accepter appartient a l'UI. Les empreintes y vivent en clair,
// couvertes par le content_mac et non par un AEAD par champ.

interface

uses
  SysUtils, uRshDocument;

type
  TKnownHostVerdict = (
    khvUnknown,
    khvMatch,
    khvChanged    // meme type, empreinte differente: alerte MITM
  );

  TKnownHostEntry = record
    Uuid: string;
    Hostname: string;
    Port: Integer;
    KeyType: string;
    Fingerprint: string;
    FirstSeenMs: Int64;
    LastSeenMs: Int64;
  end;

  TSshKnownHosts = class
  private
    FDoc: TRshDocument;
  public
    constructor Create(ADoc: TRshDocument);

    function Verify(const AHostname: string; APort: Integer;
      const AKeyType, AFingerprint: string;
      out AExisting: TKnownHostEntry): TKnownHostVerdict;

    // marque le document dirty: l'empreinte n'est durable qu'apres un Save
    procedure Remember(const AHostname: string; APort: Integer;
      const AKeyType, AFingerprint: string; const ABlob: TBytes);

    procedure TouchSeen(const AUuid: string);

    procedure Forget(const AHostname: string; APort: Integer;
      const AKeyType: string);

    // contraint la negociation: sinon un type non enregistre degrade
    // une cle modifiee en hote inconnu
    function KnownKeyTypes(const AHostname: string;
      APort: Integer): TStringArray;

    function Count: Integer;
  end;

// trim, minuscules, crochets IPv6 retires; ne resout rien
function CanonicalHost(const AHostname: string): string;

function FormatFingerprintSha256(const AHash: TBytes): string;

implementation

uses
  base64, uSqliteDb, uRsUtil;

function CanonicalHost(const AHostname: string): string;
begin
  Result := LowerCase(Trim(AHostname));
  if (Length(Result) >= 2) and (Result[1] = '[') and
     (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

function FormatFingerprintSha256(const AHash: TBytes): string;
var
  raw: AnsiString;
  i: Integer;
begin
  SetLength(raw, Length(AHash));
  for i := 0 to High(AHash) do
    raw[i + 1] := AnsiChar(AHash[i]);
  Result := EncodeStringBase64(raw);
  while (Result <> '') and (Result[Length(Result)] = '=') do   // sans padding
    SetLength(Result, Length(Result) - 1);
  Result := 'SHA256:' + Result;
end;

{ TSshKnownHosts }

constructor TSshKnownHosts.Create(ADoc: TRshDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

function TSshKnownHosts.Verify(const AHostname: string; APort: Integer;
  const AKeyType, AFingerprint: string;
  out AExisting: TKnownHostEntry): TKnownHostVerdict;
var
  st: TSqliteStmt;
begin
  Result := khvUnknown;
  AExisting := Default(TKnownHostEntry);
  st := FDoc.Db.Prepare('SELECT uuid, hostname, port, key_type, ' +
    'fingerprint_sha256, first_seen_ms, last_seen_ms FROM ssh_known_hosts ' +
    'WHERE hostname = ? AND port = ? AND key_type = ?;');
  try
    st.BindText(1, CanonicalHost(AHostname));
    st.BindInt64(2, APort);
    st.BindText(3, AKeyType);
    if not st.Step then
      Exit;
    AExisting.Uuid := st.ColText(0);
    AExisting.Hostname := st.ColText(1);
    AExisting.Port := st.ColInt64(2);
    AExisting.KeyType := st.ColText(3);
    AExisting.Fingerprint := st.ColText(4);
    AExisting.FirstSeenMs := st.ColInt64(5);
    AExisting.LastSeenMs := st.ColInt64(6);
    if AExisting.Fingerprint = AFingerprint then
      Result := khvMatch
    else
      Result := khvChanged;
  finally
    st.Free;
  end;
end;

procedure TSshKnownHosts.Remember(const AHostname: string; APort: Integer;
  const AKeyType, AFingerprint: string; const ABlob: TBytes);
var
  st: TSqliteStmt;
  existing: TKnownHostEntry;
  verdict: TKnownHostVerdict;
  now_: Int64;
begin
  now_ := NowUtcMs;
  verdict := Verify(AHostname, APort, AKeyType, AFingerprint, existing);
  if verdict = khvMatch then
  begin
    TouchSeen(existing.Uuid);
    Exit;
  end;

  FDoc.Db.BeginImmediate;
  try
    if verdict = khvChanged then
    begin
      st := FDoc.Db.Prepare('UPDATE ssh_known_hosts SET ' +
        'fingerprint_sha256 = ?, public_key_blob = ?, last_seen_ms = ? ' +
        'WHERE uuid = ?;');
      try
        st.BindText(1, AFingerprint);
        if Length(ABlob) > 0 then
          st.BindBlob(2, ABlob)
        else
          st.BindNull(2);
        st.BindInt64(3, now_);
        st.BindText(4, existing.Uuid);
        st.Step;
      finally
        st.Free;
      end;
    end
    else
    begin
      st := FDoc.Db.Prepare('INSERT INTO ssh_known_hosts (uuid, hostname, ' +
        'port, key_type, fingerprint_sha256, public_key_blob, ' +
        'first_seen_ms, last_seen_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?);');
      try
        st.BindText(1, NewUuid);
        st.BindText(2, CanonicalHost(AHostname));
        st.BindInt64(3, APort);
        st.BindText(4, AKeyType);
        st.BindText(5, AFingerprint);
        if Length(ABlob) > 0 then
          st.BindBlob(6, ABlob)
        else
          st.BindNull(6);
        st.BindInt64(7, now_);
        st.BindInt64(8, now_);
        st.Step;
      finally
        st.Free;
      end;
    end;
    FDoc.Db.Commit;
  except
    FDoc.Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TSshKnownHosts.TouchSeen(const AUuid: string);
var
  st: TSqliteStmt;
begin
  // Toute ecriture ici DOIT etre transactionnelle: le content_mac n'est
  // re-scelle qu'au Commit, et un MAC perime = document declare altere.
  FDoc.Db.BeginImmediate;
  try
    st := FDoc.Db.Prepare(
      'UPDATE ssh_known_hosts SET last_seen_ms = ? WHERE uuid = ?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    FDoc.Db.Commit;
  except
    FDoc.Db.Rollback;
    raise;
  end;
  // PAS de MarkDirty: last_seen n'est pas une modification de l'utilisateur, et
  // salir le document lui reclamerait un enregistrement apres chaque session.
end;

procedure TSshKnownHosts.Forget(const AHostname: string; APort: Integer;
  const AKeyType: string);
var
  st: TSqliteStmt;
begin
  FDoc.Db.BeginImmediate;
  try
    st := FDoc.Db.Prepare('DELETE FROM ssh_known_hosts WHERE hostname = ? ' +
      'AND port = ? AND key_type = ?;');
    try
      st.BindText(1, CanonicalHost(AHostname));
      st.BindInt64(2, APort);
      st.BindText(3, AKeyType);
      st.Step;
    finally
      st.Free;
    end;
    FDoc.Db.Commit;
  except
    FDoc.Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TSshKnownHosts.KnownKeyTypes(const AHostname: string;
  APort: Integer): TStringArray;
var
  st: TSqliteStmt;
  n: Integer;
begin
  Result := nil;
  n := 0;
  st := FDoc.Db.Prepare('SELECT key_type FROM ssh_known_hosts ' +
    'WHERE hostname = ? AND port = ? ORDER BY key_type;');
  try
    st.BindText(1, CanonicalHost(AHostname));
    st.BindInt64(2, APort);
    while st.Step do
    begin
      SetLength(Result, n + 1);
      Result[n] := st.ColText(0);
      Inc(n);
    end;
  finally
    st.Free;
  end;
end;

function TSshKnownHosts.Count: Integer;
begin
  Result := FDoc.Db.ExecScalarInt('SELECT COUNT(*) FROM ssh_known_hosts;');
end;

end.
