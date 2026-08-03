unit uRdpKnownCerts;

{$mode objfpc}{$H+}

// Magasin TOFU des certificats RDP dans le document (.rsh) et pas dans
// ~/.config/freerdp: la confiance voyage avec le fichier (par analogie).
// Cle document_settings 'rdp_cert:<host>:<port>' -> JSON. Empreintes en clair,
// couvertes par content_mac et pas par un AEAD par champ (comme SSH).

interface

uses
  SysUtils, uRshDocument;

type
  TRdpCertVerdict = (rcvUnknown, rcvMatch, rcvChanged);

  TRdpCertEntry = record
    Fingerprint: string;
    CommonName: string;
    FirstSeenMs: Int64;
    LastSeenMs: Int64;
  end;

  TRdpKnownCerts = class
  private
    FDoc: TRshDocument;
    function KeyOf(const AHost: string; APort: Integer): string;
    function ReadEntry(const AKey: string; out AEntry: TRdpCertEntry): Boolean;
    // ADirty=False pour un refresh de last_seen: se connecter n'est pas modifier
    procedure WriteEntry(const AKey: string; const AEntry: TRdpCertEntry;
      ADirty: Boolean = True);
  public
    constructor Create(ADoc: TRshDocument);

    function Verify(const AHost: string; APort: Integer;
      const AFingerprint: string; out AExisting: TRdpCertEntry): TRdpCertVerdict;
    procedure Remember(const AHost: string; APort: Integer;
      const AFingerprint, ACommonName: string);
    procedure TouchSeen(const AHost: string; APort: Integer);
    procedure Forget(const AHost: string; APort: Integer);
    function Count: Integer;
  end;

function CanonicalRdpHost(const AHostname: string): string;

implementation

uses
  fpjson, jsonparser, uSqliteDb, uRsUtil;

function CanonicalRdpHost(const AHostname: string): string;
begin
  Result := LowerCase(Trim(AHostname));
  if (Length(Result) >= 2) and (Result[1] = '[') and
     (Result[Length(Result)] = ']') then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

{ TRdpKnownCerts }

constructor TRdpKnownCerts.Create(ADoc: TRshDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

function TRdpKnownCerts.KeyOf(const AHost: string; APort: Integer): string;
begin
  Result := Format('rdp_cert:%s:%d', [CanonicalRdpHost(AHost), APort]);
end;

function TRdpKnownCerts.ReadEntry(const AKey: string;
  out AEntry: TRdpCertEntry): Boolean;
var
  st: TSqliteStmt;
  raw: string;
  data: TJSONData;
  obj: TJSONObject;
begin
  Result := False;
  AEntry := Default(TRdpCertEntry);
  st := FDoc.Db.Prepare(
    'SELECT value_json FROM document_settings WHERE key = ?;');
  try
    st.BindText(1, AKey);
    if not st.Step then
      Exit;
    raw := st.ColText(0);
  finally
    st.Free;
  end;
  if raw = '' then
    Exit;
  try
    data := GetJSON(raw);
    try
      if not (data is TJSONObject) then
        Exit;
      obj := TJSONObject(data);
      AEntry.Fingerprint := obj.Get('fp', '');
      AEntry.CommonName := obj.Get('cn', '');
      AEntry.FirstSeenMs := obj.Get('first', Int64(0));
      AEntry.LastSeenMs := obj.Get('last', Int64(0));
      Result := AEntry.Fingerprint <> '';
    finally
      data.Free;
    end;
  except
    // JSON corrompu (document trafique) = absent: l'UI redemandera la confiance
    Result := False;
  end;
end;

procedure TRdpKnownCerts.WriteEntry(const AKey: string;
  const AEntry: TRdpCertEntry; ADirty: Boolean);
var
  st: TSqliteStmt;
  obj: TJSONObject;
  raw: string;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('fp', AEntry.Fingerprint);
    obj.Add('cn', AEntry.CommonName);
    obj.Add('first', AEntry.FirstSeenMs);
    obj.Add('last', AEntry.LastSeenMs);
    raw := obj.AsJSON;
  finally
    obj.Free;
  end;
  FDoc.Db.BeginImmediate;
  try
    st := FDoc.Db.Prepare('INSERT INTO document_settings(key, value_json) ' +
      'VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value_json = ?;');
    try
      st.BindText(1, AKey);
      st.BindText(2, raw);
      st.BindText(3, raw);
      st.Step;
    finally
      st.Free;
    end;
    FDoc.Db.Commit;
  except
    FDoc.Db.Rollback;
    raise;
  end;
  if ADirty then
    FDoc.MarkDirty;
end;

function TRdpKnownCerts.Verify(const AHost: string; APort: Integer;
  const AFingerprint: string; out AExisting: TRdpCertEntry): TRdpCertVerdict;
begin
  if not ReadEntry(KeyOf(AHost, APort), AExisting) then
    Exit(rcvUnknown);
  if AExisting.Fingerprint = AFingerprint then
    Result := rcvMatch
  else
    Result := rcvChanged;
end;

procedure TRdpKnownCerts.Remember(const AHost: string; APort: Integer;
  const AFingerprint, ACommonName: string);
var
  key: string;
  e: TRdpCertEntry;
  now_: Int64;
begin
  now_ := NowUtcMs;
  key := KeyOf(AHost, APort);
  if ReadEntry(key, e) and (e.Fingerprint = AFingerprint) then
  begin
    e.LastSeenMs := now_;
    WriteEntry(key, e, False);
    Exit;
  end;
  if e.FirstSeenMs = 0 then
    e.FirstSeenMs := now_;
  e.Fingerprint := AFingerprint;
  e.CommonName := ACommonName;
  e.LastSeenMs := now_;
  WriteEntry(key, e, True);
end;

procedure TRdpKnownCerts.TouchSeen(const AHost: string; APort: Integer);
var
  key: string;
  e: TRdpCertEntry;
begin
  key := KeyOf(AHost, APort);
  if not ReadEntry(key, e) then
    Exit;
  e.LastSeenMs := NowUtcMs;
  WriteEntry(key, e, False);
end;

procedure TRdpKnownCerts.Forget(const AHost: string; APort: Integer);
var
  st: TSqliteStmt;
begin
  // transaction explicite: le content_mac n'est re-scelle qu'au Commit, sinon
  // Forget puis Save rend un fichier declare altere a la reouverture
  FDoc.Db.BeginImmediate;
  try
    st := FDoc.Db.Prepare('DELETE FROM document_settings WHERE key = ?;');
    try
      st.BindText(1, KeyOf(AHost, APort));
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

function TRdpKnownCerts.Count: Integer;
begin
  Result := FDoc.Db.ExecScalarInt(
    'SELECT COUNT(*) FROM document_settings WHERE key LIKE ''rdp_cert:%'';');
end;

end.
