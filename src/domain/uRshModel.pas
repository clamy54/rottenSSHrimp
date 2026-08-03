unit uRshModel;

{$mode objfpc}{$H+}

// Modele du document: groupes, connexions, credentials. Chaque
// mutation = une transaction + MarkDirty; les listes rendues sont a l'appelant.
// Les secrets n'existent qu'en TSecureBytes, chiffres par champ (AAD canonique).

interface

uses
  Classes, SysUtils, fgl, uRshDocument, uSqliteDb, uSecureBytes;

type
  EModelError = class(Exception);

  TNodeKind = (nkGroup, nkConnection);
  TRshProtocol = (rpSsh, rpRdp, rpVnc, rpContainer, rpPod);
  TAuthType = (atPassword, atSshKey, atSshAgent, atPrompt, atManagedKey);
  TCredDeleteStrategy = (dsFail, dsClearRefs, dsReplace);

  TContainerEngine = (ceDocker, cePodman);
  TContainerShell = (csSh, csBash, csLog);

  TContainerConfig = record
    ParentUuid: string;
    Engine: TContainerEngine;
    ContainerName: string;
    Shell: TContainerShell;
  end;

  TPodConfig = record
    ParentUuid: string;
    Namespace: string;
    PodName: string;
    ContainerName: string;
    Shell: TContainerShell;
  end;

  TRshNode = class
  public
    Uuid: string;
    ParentUuid: string;
    Kind: TNodeKind;
    DisplayName: string;
    Description: string;
    IconId: string;
    SortOrder: Integer;
    Protocol: TRshProtocol;
    Hostname: string;
    Port: Integer;
    CredentialUuid: string;
    // True: ignore CredentialUuid, resolution en remontant les dossiers (0013)
    InheritCredential: Boolean;
    ConnectTimeoutS: Integer;
  end;

  TRshNodeList = specialize TFPGObjectList<TRshNode>;

  TRshCredential = class
  public
    Uuid: string;
    DisplayName: string;
    AuthType: TAuthType;
    Username: string;
    DomainName: string;
    KeyPathHint: string;
    HasPassword: Boolean;
    HasPrivateKey: Boolean;
    HasKeyPassphrase: Boolean;
    Managed: Boolean;
    PublicKey: string;
  end;

  TRshCredentialList = specialize TFPGObjectList<TRshCredential>;

  TRshRdpGateway = record
    Hostname: string;
    Port: Integer;
  end;

  // Stocke en texte: un ajout dans l'enum ne relit pas l'existant
  TSessionResult = (srOk, srFailed, srCancelled);

  TRshQuickEntry = class
  public
    ConnUuid: string;
    DisplayName: string;
    Hostname: string;
    Protocol: TRshProtocol;
    LastConnectedMs: Int64;   // 0 = jamais tentee: LastResult n'a aucun sens
    LastResult: TSessionResult;
    Favorite: Boolean;
    GroupPath: string;
  end;

  TRshQuickList = specialize TFPGObjectList<TRshQuickEntry>;

  TRshModel = class
  private
    FDoc: TRshDocument;
    function Db: TSqliteDb;
    function NextSortOrder(const AParentUuid: string): Integer;
    function NodeDepth(const AUuid: string): Integer;
    function SubtreeHeight(const AUuid: string): Integer;
    function SubtreeHeightBounded(const AUuid: string;
      ADepth: Integer): Integer;
    procedure EnsureParentIsGroup(const AParentUuid: string);
    procedure EnsureNodeBudget(AAdding: Integer);
    procedure InsertNodeRow(ANode: TRshNode);
    function ReadNode(const AUuid: string): TRshNode;
    procedure StoreSecret(const AOwnerUuid, AFieldName: string;
      ASecret: TSecureBytes; out AValueId: string);
    procedure DeleteSecretsOf(const AOwnerUuid: string);
    procedure GcOrphanCredentials;
    function DuplicateSubtree(const ASrcUuid, ADestParent: string;
      ASortOrder: Integer; const ANameSuffix: string;
      ADepth: Integer = 0): string;
  public
    constructor Create(ADoc: TRshDocument);

    procedure BeginBatch;
    procedure CommitBatch;
    procedure RollbackBatch;

    function LoadNodes: TRshNodeList;
    function GetNode(const AUuid: string): TRshNode;
    function CountNodes: Integer;
    function CreateGroup(const AParentUuid: string; AName: string): string;
    function CreateConnection(const AParentUuid: string; AName: string;
      AProtocol: TRshProtocol; AHostname: string; APort: Integer;
      AInheritCredential: Boolean = False): string;
    procedure RenameNode(const AUuid: string; ANewName: string);
    procedure SetNodeIcon(const AUuid, AIconId: string);
    procedure UpdateNodeDescription(const AUuid: string;
      const ADescription: string);
    procedure UpdateConnection(const AUuid: string; AHostname: string;
      APort: Integer; const ACredentialUuid: string; ATimeoutS: Integer;
      AInheritCredential: Boolean = False);
    function GetVncActualSize(const AUuid: string): Boolean;
    function GetVncReconnect(const AUuid: string;
      out AAuto: Boolean; out AMaxAttempts: Integer): Boolean;
    procedure GetVncProfile(const AUuid: string;
      out AShared, AViewOnly, AClipboardText: Boolean;
      out ACompressLevel, AQualityLevel: Integer);
    procedure SetVncActualSize(const AUuid: string; AValue: Boolean);
    procedure GetSshKeepalive(const AUuid: string;
      out AIntervalS, AMaxFailures: Integer);
    function GetRdpGateway(const AUuid: string): TRshRdpGateway;
    procedure SetRdpGateway(const AUuid: string; const AHostname: string;
      APort: Integer);
    function GetJumpVia(const AUuid: string): string;
    procedure SetJumpVia(const AUuid, AJumpUuid: string);
    // False aussi quand la table manque (v5 lecture seule, non migre): dans ce
    // cas l'appelant ne filtre PAS, la liste serait vide.
    function JumpHostOffersAvailable: Boolean;
    function IsJumpHostOffered(const AConnUuid: string): Boolean;
    procedure SetJumpHostOffered(const AConnUuid: string; AOffered: Boolean);
    procedure LoadJumpHostOffers(AList: TStrings);
    function CountJumpDependents(const AConnUuid: string): Integer;
    function CreateContainerConnection(const AParentGroupUuid: string;
      AName: string; const AParentSshUuid: string; AEngine: TContainerEngine;
      const AContainerName: string; AShell: TContainerShell): string;
    function GetContainerConfig(const AUuid: string;
      out AConfig: TContainerConfig): Boolean;
    procedure SetContainerConfig(const AUuid: string;
      const AConfig: TContainerConfig);
    function CountContainerDependents(const AParentUuid: string): Integer;
    function CreatePodConnection(const AParentGroupUuid: string;
      AName: string; const AParentSshUuid: string; const ANamespace,
      APodName, AContainerName: string; AShell: TContainerShell): string;
    function GetPodConfig(const AUuid: string;
      out AConfig: TPodConfig): Boolean;
    procedure SetPodConfig(const AUuid: string; const AConfig: TPodConfig);
    function CountPodDependents(const AParentUuid: string): Integer;
    procedure DeleteNode(const AUuid: string);
    procedure MoveNode(const AUuid, ANewParentUuid: string;
      ASortOrder: Integer);
    function DuplicateNode(const AUuid: string): string;

    function GetConnectionCredential(const AConnUuid: string): string;

    // Heritage par dossier (0013): l'emplacement de SON protocole, au porteur
    // le plus proche. Nulle part ailleurs -- l'opacite avait tue 0007.
    function GetFolderCredential(const AFolderUuid: string;
      AProtocol: TRshProtocol): string;
    procedure SetFolderCredential(const AFolderUuid: string;
      AProtocol: TRshProtocol; const ACredentialUuid: string);
    function ResolveFolderCredential(const AStartFolderUuid: string;
      AProtocol: TRshProtocol; out ASourceFolderName: string): string;
    function ResolveConnectionCredential(const AConnUuid: string;
      out ASourceFolderName: string): string;
    procedure PurgeOrphanCredentials;

    function ListCredentials: TRshCredentialList;
    function ListManagedCredentials: TRshCredentialList;
    function GetCredential(const AUuid: string): TRshCredential;
    function IsManagedCredential(const AUuid: string): Boolean;
    function CreateCredential(ADisplayName: string; AAuthType: TAuthType;
      const AUsername, ADomain, AKeyPathHint: string;
      APassword, APrivateKey, AKeyPassphrase: TSecureBytes;
      AManaged: Boolean = False): string;
    // secret nil = inchange (pas efface); AClearXxx force l'effacement
    procedure UpdateCredential(const AUuid: string; ADisplayName: string;
      AAuthType: TAuthType; const AUsername, ADomain, AKeyPathHint: string;
      APassword, APrivateKey, AKeyPassphrase: TSecureBytes;
      AClearPassword: Boolean = False; AClearKey: Boolean = False;
      AClearKeyPass: Boolean = False);
    function DuplicateCredential(const AUuid: string): string;
    procedure SetManagedKeyPair(const AUuid: string;
      APrivatePem: TSecureBytes; const APublicLine: string);
    procedure DeleteCredential(const AUuid: string;
      AStrategy: TCredDeleteStrategy; const AReplacementUuid: string = '');
    function CredentialUsage(const AUuid: string): TStringArray;
    function CredentialSshHosts(const ACredUuid: string): TStringArray;
    function GetSecret(const ACredUuid, AFieldName: string;
      out ASecret: TSecureBytes): Boolean;

    // Appelee sur les echecs aussi: on cherche souvent ce qu'on vient de rater
    procedure TouchRecent(const AConnUuid: string; AResult: TSessionResult);
    function ListRecent(AMax: Integer): TRshQuickList;
    procedure ClearRecent;

    function IsFavorite(const AConnUuid: string): Boolean;
    procedure SetFavorite(const AConnUuid: string; AOn: Boolean);

    function GetRootIcon: string;
    procedure SetRootIcon(const AIconId: string);
    function ListFavorites: TRshQuickList;
    function ListSubtreeConnections(const AGroupUuid: string): TRshQuickList;
  end;

const
  FIELD_CRED_PASSWORD = 'credential.password';
  FIELD_CRED_PRIVATE_KEY = 'credential.private_key';
  FIELD_CRED_KEY_PASSPHRASE = 'credential.private_key_passphrase';

  PROTOCOL_NAMES: array[TRshProtocol] of string =
    ('ssh', 'rdp', 'vnc', 'container', 'pod');
  CONTAINER_ENGINE_NAMES: array[TContainerEngine] of string =
    ('docker', 'podman');
  CONTAINER_SHELL_NAMES: array[TContainerShell] of string =
    ('sh', 'bash', 'log');
  CONTAINER_SHELL_PATHS: array[TContainerShell] of string =
    ('/bin/sh', '/bin/bash', '');
  SESSION_RESULT_NAMES: array[TSessionResult] of string =
    ('ok', 'failed', 'cancelled');

  MAX_RECENT_ENTRIES = 20;
  AUTH_TYPE_NAMES: array[TAuthType] of string =
    ('password', 'ssh_key', 'ssh_agent', 'prompt', 'managed_key');

  DEFAULT_GROUP_ICON = 'folder';
  ICON_SSH = 'device-desktop';
  ICON_RDP = 'brand-windows';
  ICON_VNC = 'application-x-remote-connection';
  ICON_CONTAINER = 'box';
  ICON_POD = 'hexagons';

function ProtocolFromName(const S: string): TRshProtocol;
function AuthTypeFromName(const S: string): TAuthType;
function SessionResultFromName(const S: string): TSessionResult;
function ContainerEngineFromName(const S: string): TContainerEngine;
function ContainerShellFromName(const S: string): TContainerShell;

function MatchesSearch(const AFilter, AName, AHostname, AProtocol,
  ADescription, AParentName, ACredName: string): Boolean;

implementation

uses
  uCryptoPolicy, uRshValidation, uRsUtil;

function ProtocolFromName(const S: string): TRshProtocol;
begin
  if S = 'rdp' then
    Result := rpRdp
  else if S = 'vnc' then
    Result := rpVnc
  else if S = 'container' then
    Result := rpContainer
  else if S = 'pod' then
    Result := rpPod
  else
    Result := rpSsh;
end;

function ContainerEngineFromName(const S: string): TContainerEngine;
begin
  if S = 'podman' then
    Result := cePodman
  else
    Result := ceDocker;
end;

function ContainerShellFromName(const S: string): TContainerShell;
begin
  if S = 'bash' then
    Result := csBash
  else if S = 'log' then
    Result := csLog
  else
    Result := csSh;
end;

function AuthTypeFromName(const S: string): TAuthType;
var
  a: TAuthType;
begin
  for a in TAuthType do
    if AUTH_TYPE_NAMES[a] = S then
      Exit(a);
  Result := atPrompt;
end;

function MatchesSearch(const AFilter, AName, AHostname, AProtocol,
  ADescription, AParentName, ACredName: string): Boolean;
var
  f: string;

  // minuscules via UTF-16 si le widestring manager est la, repli ASCII sinon
  function Lower(const S: string): string;
  begin
    Result := UTF8Encode(LowerCase(UTF8Decode(S)));
  end;

  function Has(const S: string): Boolean;
  begin
    Result := (S <> '') and (Pos(f, Lower(S)) > 0);
  end;

begin
  f := Lower(Trim(AFilter));
  if f = '' then Exit(True);
  Result := Has(AName) or Has(AHostname) or Has(AProtocol) or
    Has(ADescription) or Has(AParentName) or Has(ACredName);
end;

{ TRshModel }

constructor TRshModel.Create(ADoc: TRshDocument);
begin
  inherited Create;
  FDoc := ADoc;
end;

function TRshModel.Db: TSqliteDb;
begin
  Result := FDoc.Db;
end;

procedure TRshModel.BeginBatch;
begin
  Db.BeginImmediate;
end;

procedure TRshModel.CommitBatch;
begin
  Db.Commit;
  FDoc.MarkDirty;
end;

procedure TRshModel.RollbackBatch;
begin
  Db.Rollback;
end;

function TRshModel.NextSortOrder(const AParentUuid: string): Integer;
var
  st: TSqliteStmt;
begin
  if AParentUuid = '' then
    st := Db.Prepare('SELECT COALESCE(MAX(sort_order),-1)+1 FROM nodes' +
      ' WHERE parent_uuid IS NULL;')
  else
  begin
    st := Db.Prepare('SELECT COALESCE(MAX(sort_order),-1)+1 FROM nodes' +
      ' WHERE parent_uuid=?;');
    st.BindText(1, AParentUuid);
  end;
  try
    st.Step;
    Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

function TRshModel.NodeDepth(const AUuid: string): Integer;
var
  st: TSqliteStmt;
  cur: string;
begin
  Result := 0;
  cur := AUuid;
  while cur <> '' do
  begin
    Inc(Result);
    if Result > MAX_TREE_DEPTH + 1 then
      raise EModelError.Create('Cycle detected in the tree.');
    st := Db.Prepare('SELECT COALESCE(parent_uuid,'''') FROM nodes' +
      ' WHERE uuid=?;');
    try
      st.BindText(1, cur);
      if not st.Step then
        Exit;
      cur := st.ColText(0);
    finally
      st.Free;
    end;
  end;
end;

function TRshModel.SubtreeHeight(const AUuid: string): Integer;
begin
  Result := SubtreeHeightBounded(AUuid, 0);
end;

function TRshModel.SubtreeHeightBounded(const AUuid: string;
  ADepth: Integer): Integer;
var
  st: TSqliteStmt;
  children: array of string;
  child: string;
  h: Integer;
  i: Integer;
begin
  // Borne AVANT de recurser: un cycle parent_uuid forge (A enfant de B, B
  // enfant de A) deborderait la pile, le test d'en bas n'agissant qu'au retour.
  if ADepth > MAX_TREE_DEPTH then
    Exit(1);
  children := nil;
  st := Db.Prepare('SELECT uuid FROM nodes WHERE parent_uuid=?;');
  try
    st.BindText(1, AUuid);
    while st.Step do
    begin
      SetLength(children, Length(children) + 1);
      children[High(children)] := st.ColText(0);
    end;
  finally
    st.Free;
  end;
  Result := 1;
  for i := 0 to High(children) do
  begin
    child := children[i];
    h := 1 + SubtreeHeightBounded(child, ADepth + 1);
    if h > Result then
      Result := h;
    if Result > MAX_TREE_DEPTH then
      Exit;
  end;
end;

procedure TRshModel.EnsureParentIsGroup(const AParentUuid: string);
var
  st: TSqliteStmt;
begin
  if AParentUuid = '' then Exit;
  st := Db.Prepare('SELECT node_type FROM nodes WHERE uuid=?;');
  try
    st.BindText(1, AParentUuid);
    if not st.Step then
      raise EModelError.Create('The parent folder does not exist.');
    if st.ColText(0) <> 'group' then
      raise EModelError.Create('The parent must be a folder.');
  finally
    st.Free;
  end;
  if NodeDepth(AParentUuid) >= MAX_TREE_DEPTH then
    raise EModelError.Create('Maximum tree depth reached.');
end;

procedure TRshModel.EnsureNodeBudget(AAdding: Integer);
begin
  if CountNodes + AAdding > MAX_NODES then
    raise EModelError.Create('Maximum number of nodes reached.');
end;

function TRshModel.CountNodes: Integer;
begin
  Result := Db.ExecScalarInt('SELECT COUNT(*) FROM nodes;');
end;

procedure TRshModel.InsertNodeRow(ANode: TRshNode);
var
  st: TSqliteStmt;
  nowMs: Int64;
begin
  nowMs := NowUtcMs;
  st := Db.Prepare('INSERT INTO nodes(uuid, parent_uuid, node_type,' +
    ' display_name, description, icon_id, sort_order, created_at_ms,' +
    ' updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?);');
  try
    st.BindText(1, ANode.Uuid);
    if ANode.ParentUuid = '' then
      st.BindNull(2)
    else
      st.BindText(2, ANode.ParentUuid);
    if ANode.Kind = nkGroup then
      st.BindText(3, 'group')
    else
      st.BindText(3, 'connection');
    st.BindText(4, ANode.DisplayName);
    st.BindText(5, ANode.Description);
    st.BindText(6, ANode.IconId);
    st.BindInt64(7, ANode.SortOrder);
    st.BindInt64(8, nowMs);
    st.BindInt64(9, nowMs);
    st.Step;
  finally
    st.Free;
  end;
  if ANode.Kind = nkConnection then
  begin
    st := Db.Prepare('INSERT INTO connections(node_uuid, protocol,' +
      ' hostname, port, credential_uuid, inherit_settings,' +
      ' connect_timeout_s, inherit_credential) VALUES(?,?,?,?,?,1,?,?);');
    try
      st.BindText(1, ANode.Uuid);
      st.BindText(2, PROTOCOL_NAMES[ANode.Protocol]);
      st.BindText(3, ANode.Hostname);
      st.BindInt64(4, ANode.Port);
      if ANode.CredentialUuid = '' then
        st.BindNull(5)
      else
        st.BindText(5, ANode.CredentialUuid);
      st.BindInt64(6, ANode.ConnectTimeoutS);
      st.BindInt64(7, Ord(ANode.InheritCredential));
      st.Step;
    finally
      st.Free;
    end;
  end;
end;

function TRshModel.ReadNode(const AUuid: string): TRshNode;
var
  st: TSqliteStmt;
begin
  Result := nil;
  st := Db.Prepare('SELECT n.uuid, COALESCE(n.parent_uuid,''''),' +
    ' n.node_type, n.display_name, n.description, n.icon_id, n.sort_order,' +
    ' COALESCE(c.protocol,''''), COALESCE(c.hostname,''''),' +
    ' COALESCE(c.port,0), COALESCE(c.credential_uuid,''''),' +
    ' COALESCE(c.connect_timeout_s,15), COALESCE(c.inherit_credential,0)' +
    ' FROM nodes n LEFT JOIN connections c ON c.node_uuid = n.uuid' +
    ' WHERE n.uuid=?;');
  try
    st.BindText(1, AUuid);
    if not st.Step then Exit;
    Result := TRshNode.Create;
    Result.Uuid := st.ColText(0);
    Result.ParentUuid := st.ColText(1);
    if st.ColText(2) = 'group' then
      Result.Kind := nkGroup
    else
      Result.Kind := nkConnection;
    Result.DisplayName := st.ColText(3);
    Result.Description := st.ColText(4);
    Result.IconId := st.ColText(5);
    Result.SortOrder := st.ColInt64(6);
    Result.Protocol := ProtocolFromName(st.ColText(7));
    Result.Hostname := st.ColText(8);
    Result.Port := st.ColInt64(9);
    Result.CredentialUuid := st.ColText(10);
    Result.ConnectTimeoutS := st.ColInt64(11);
    Result.InheritCredential := st.ColInt64(12) <> 0;
  finally
    st.Free;
  end;
end;

function TRshModel.LoadNodes: TRshNodeList;
var
  st: TSqliteStmt;
  n: TRshNode;
begin
  Result := TRshNodeList.Create(True);
  st := Db.Prepare('SELECT n.uuid, COALESCE(n.parent_uuid,''''),' +
    ' n.node_type, n.display_name, n.description, n.icon_id, n.sort_order,' +
    ' COALESCE(c.protocol,''''), COALESCE(c.hostname,''''),' +
    ' COALESCE(c.port,0), COALESCE(c.credential_uuid,''''),' +
    ' COALESCE(c.connect_timeout_s,15), COALESCE(c.inherit_credential,0)' +
    ' FROM nodes n LEFT JOIN connections c ON c.node_uuid = n.uuid' +
    ' ORDER BY COALESCE(n.parent_uuid,''''), n.sort_order, n.display_name;');
  try
    while st.Step do
    begin
      n := TRshNode.Create;
      n.Uuid := st.ColText(0);
      n.ParentUuid := st.ColText(1);
      if st.ColText(2) = 'group' then
        n.Kind := nkGroup
      else
        n.Kind := nkConnection;
      n.DisplayName := st.ColText(3);
      n.Description := st.ColText(4);
      n.IconId := st.ColText(5);
      n.SortOrder := st.ColInt64(6);
      n.Protocol := ProtocolFromName(st.ColText(7));
      n.Hostname := st.ColText(8);
      n.Port := st.ColInt64(9);
      n.CredentialUuid := st.ColText(10);
      n.ConnectTimeoutS := st.ColInt64(11);
      n.InheritCredential := st.ColInt64(12) <> 0;
      Result.Add(n);
    end;
  finally
    st.Free;
  end;
end;

function TRshModel.GetNode(const AUuid: string): TRshNode;
begin
  Result := ReadNode(AUuid);
  if Result = nil then
    raise EModelError.Create('Node not found.');
end;

function TRshModel.CreateGroup(const AParentUuid: string;
  AName: string): string;
var
  err: string;
  n: TRshNode;
begin
  if not ValidateName(AName, err) then
    raise EModelError.Create(err);
  Db.BeginImmediate;
  try
    EnsureParentIsGroup(AParentUuid);
    EnsureNodeBudget(1);
    n := TRshNode.Create;
    try
      n.Uuid := NewUuid;
      n.ParentUuid := AParentUuid;
      n.Kind := nkGroup;
      n.DisplayName := AName;
      n.IconId := DEFAULT_GROUP_ICON;
      n.SortOrder := NextSortOrder(AParentUuid);
      InsertNodeRow(n);
      Result := n.Uuid;
    finally
      n.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.CreateConnection(const AParentUuid: string; AName: string;
  AProtocol: TRshProtocol; AHostname: string; APort: Integer;
  AInheritCredential: Boolean): string;
var
  err: string;
  n: TRshNode;
begin
  if not ValidateName(AName, err) then
    raise EModelError.Create(err);
  if not ValidateHostname(AHostname, err) then
    raise EModelError.Create(err);
  if not ValidatePort(APort, err) then
    raise EModelError.Create(err);
  Db.BeginImmediate;
  try
    EnsureParentIsGroup(AParentUuid);
    EnsureNodeBudget(1);
    n := TRshNode.Create;
    try
      n.Uuid := NewUuid;
      n.ParentUuid := AParentUuid;
      n.Kind := nkConnection;
      n.DisplayName := AName;
      case AProtocol of
        rpRdp: n.IconId := ICON_RDP;
        rpVnc: n.IconId := ICON_VNC;
      else
        n.IconId := ICON_SSH;
      end;
      n.SortOrder := NextSortOrder(AParentUuid);
      n.Protocol := AProtocol;
      n.Hostname := AHostname;
      n.Port := APort;
      n.ConnectTimeoutS := 15;
      n.InheritCredential := AInheritCredential;
      InsertNodeRow(n);
      Result := n.Uuid;
    finally
      n.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.RenameNode(const AUuid: string; ANewName: string);
var
  err: string;
  st: TSqliteStmt;
begin
  if not ValidateName(ANewName, err) then
    raise EModelError.Create(err);
  // Transaction explicite meme pour une seule instruction: en autocommit le
  // pre-commit ne rescelle pas le content_mac, et le journal reste non signe.
  Db.BeginImmediate;
  try
    st := Db.Prepare('UPDATE nodes SET display_name=?, updated_at_ms=?' +
      ' WHERE uuid=?;');
    try
      st.BindText(1, ANewName);
      st.BindInt64(2, NowUtcMs);
      st.BindText(3, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.SetNodeIcon(const AUuid, AIconId: string);
var
  st: TSqliteStmt;
begin
  Db.BeginImmediate;
  try
    st := Db.Prepare('UPDATE nodes SET icon_id=?, updated_at_ms=?' +
      ' WHERE uuid=?;');
    try
      st.BindText(1, AIconId);
      st.BindInt64(2, NowUtcMs);
      st.BindText(3, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.UpdateNodeDescription(const AUuid: string;
  const ADescription: string);
var
  err: string;
  st: TSqliteStmt;
begin
  if not ValidateDescription(ADescription, err) then
    raise EModelError.Create(err);
  Db.BeginImmediate;
  try
    st := Db.Prepare('UPDATE nodes SET description=?, updated_at_ms=?' +
      ' WHERE uuid=?;');
    try
      st.BindText(1, ADescription);
      st.BindInt64(2, NowUtcMs);
      st.BindText(3, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.UpdateConnection(const AUuid: string; AHostname: string;
  APort: Integer; const ACredentialUuid: string; ATimeoutS: Integer;
  AInheritCredential: Boolean);
var
  err: string;
  st: TSqliteStmt;
begin
  if not ValidateHostname(AHostname, err) then
    raise EModelError.Create(err);
  if not ValidatePort(APort, err) then
    raise EModelError.Create(err);
  if (ATimeoutS < 1) or (ATimeoutS > 300) then
    raise EModelError.Create('The timeout must be between 1 and 300 s.');
  // Invariant: heriter ET porter un credential rendrait la resolution ambigue
  if AInheritCredential and (ACredentialUuid <> '') then
    raise EModelError.Create(
      'A connection that inherits cannot carry its own credential.');
  Db.BeginImmediate;
  try
    st := Db.Prepare('UPDATE connections SET hostname=?, port=?,' +
      ' credential_uuid=?, connect_timeout_s=?, inherit_credential=?' +
      ' WHERE node_uuid=?;');
    try
      st.BindText(1, AHostname);
      st.BindInt64(2, APort);
      if ACredentialUuid = '' then
        st.BindNull(3)
      else
        st.BindText(3, ACredentialUuid);
      st.BindInt64(4, ATimeoutS);
      st.BindInt64(5, Ord(AInheritCredential));
      st.BindText(6, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.GetSshKeepalive(const AUuid: string;
  out AIntervalS, AMaxFailures: Integer);
var
  st: TSqliteStmt;
begin
  AIntervalS := 30;
  AMaxFailures := 3;
  st := Db.Prepare(
    'SELECT p.keepalive_interval_s, p.keepalive_max_failures' +
    ' FROM ssh_connection_settings s' +
    ' JOIN ssh_profiles p ON p.uuid = s.profile_uuid' +
    ' WHERE s.connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
    begin
      AIntervalS := st.ColInt64(0);
      AMaxFailures := st.ColInt64(1);
    end;
  finally
    st.Free;
  end;
  if AIntervalS < 0 then AIntervalS := 0;
  if AMaxFailures < 0 then AMaxFailures := 0;
end;

function TRshModel.GetRdpGateway(const AUuid: string): TRshRdpGateway;
var
  st: TSqliteStmt;
begin
  Result.Hostname := '';
  Result.Port := 0;
  st := Db.Prepare('SELECT gateway_hostname, gateway_port' +
    ' FROM rdp_connection_settings WHERE connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
    begin
      Result.Hostname := st.ColText(0);
      if not st.ColIsNull(1) then
        Result.Port := st.ColInt64(1);
    end;
  finally
    st.Free;
  end;
end;

function TRshModel.GetVncActualSize(const AUuid: string): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  st := Db.Prepare('SELECT view_actual_size FROM vnc_connection_settings' +
    ' WHERE connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
      Result := st.ColInt64(0) <> 0;
  finally
    st.Free;
  end;
end;

function TRshModel.GetVncReconnect(const AUuid: string;
  out AAuto: Boolean; out AMaxAttempts: Integer): Boolean;
var
  st: TSqliteStmt;
begin
  AAuto := True;
  AMaxAttempts := 3;
  Result := False;
  st := Db.Prepare(
    'SELECT p.auto_reconnect, p.max_reconnect_attempts' +
    ' FROM vnc_connection_settings s' +
    ' JOIN vnc_profiles p ON p.uuid = s.profile_uuid' +
    ' WHERE s.connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
    begin
      AAuto := st.ColInt64(0) <> 0;
      AMaxAttempts := st.ColInt64(1);
      if AMaxAttempts < 0 then AMaxAttempts := 0;
      Result := True;
    end;
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetVncActualSize(const AUuid: string; AValue: Boolean);
var
  st: TSqliteStmt;
begin
  Db.BeginImmediate;
  try
    st := Db.Prepare('INSERT INTO vnc_connection_settings' +
      ' (connection_uuid, view_actual_size) VALUES(?,?)' +
      ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
      ' view_actual_size=excluded.view_actual_size;');
    try
      st.BindText(1, AUuid);
      st.BindInt64(2, Ord(AValue));
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.SetRdpGateway(const AUuid: string; const AHostname: string;
  APort: Integer);
var
  err, host: string;
  st: TSqliteStmt;
begin
  host := AHostname;   // ValidateHostname normalise par var, d'ou la copie
  if host <> '' then
  begin
    if not ValidateHostname(host, err) then
      raise EModelError.Create('Gateway: ' + err);
    if (APort < 1) or (APort > 65535) then
      raise EModelError.Create('Gateway: port out of range (1..65535).');
  end;
  Db.BeginImmediate;
  try
    st := Db.Prepare('INSERT INTO rdp_connection_settings' +
      ' (connection_uuid, gateway_hostname, gateway_port) VALUES(?,?,?)' +
      ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
      ' gateway_hostname=excluded.gateway_hostname,' +
      ' gateway_port=excluded.gateway_port;');
    try
      st.BindText(1, AUuid);
      st.BindText(2, host);
      if (host = '') or (APort <= 0) then
        st.BindNull(3)
      else
        st.BindInt64(3, APort);
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.GetVncProfile(const AUuid: string;
  out AShared, AViewOnly, AClipboardText: Boolean;
  out ACompressLevel, AQualityLevel: Integer);
var
  st: TSqliteStmt;
begin
  AShared := True;
  AViewOnly := False;
  AClipboardText := True;
  ACompressLevel := 3;
  AQualityLevel := 5;
  st := Db.Prepare(
    'SELECT p.shared_session, p.view_only, p.clipboard_text_enabled,' +
    ' p.compress_level, p.quality_level' +
    ' FROM vnc_connection_settings s' +
    ' JOIN vnc_profiles p ON p.uuid = s.profile_uuid' +
    ' WHERE s.connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
    begin
      AShared := st.ColInt64(0) <> 0;
      AViewOnly := st.ColInt64(1) <> 0;
      AClipboardText := st.ColInt64(2) <> 0;
      ACompressLevel := st.ColInt64(3);
      AQualityLevel := st.ColInt64(4);
    end;
  finally
    st.Free;
  end;
end;

function TRshModel.GetJumpVia(const AUuid: string): string;
var
  st: TSqliteStmt;
begin
  Result := '';
  // connection_jump date de v5; un document plus ancien ouvert en LECTURE SEULE
  // n'est pas migre et l'interroger leverait « no such table ». Absente = direct.
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_jump'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT jump_via_uuid FROM connection_jump' +
    ' WHERE connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step and (not st.ColIsNull(0)) then
      Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetJumpVia(const AUuid, AJumpUuid: string);
var
  st: TSqliteStmt;
  jn: TRshNode;
begin
  if AJumpUuid <> '' then
  begin
    if AJumpUuid = AUuid then
      raise EModelError.Create('A connection cannot use itself as a jump host.');
    // Un seul saut: refuser vaut mieux que tronquer la chaine en silence
    jn := GetNode(AJumpUuid);
    try
      if jn.Kind <> nkConnection then
        raise EModelError.Create('The jump host must be a connection, not a folder.');
      if jn.Protocol <> rpSsh then
        raise EModelError.Create('The jump host must be an SSH connection.');
    finally
      jn.Free;
    end;
    if GetJumpVia(AJumpUuid) <> '' then
      raise EModelError.Create('Chained jump hosts are not supported: the ' +
        'jump node itself has a jump host.');
    st := Db.Prepare('SELECT 1 FROM connection_jump WHERE jump_via_uuid=? LIMIT 1;');
    try
      st.BindText(1, AUuid);
      if st.Step then
        raise EModelError.Create('This node already serves as a jump host for ' +
          'another connection: giving it a jump host would create a chain ' +
          '(not supported).');
    finally
      st.Free;
    end;
  end;
  Db.BeginImmediate;
  try
    if AJumpUuid = '' then
    begin
      st := Db.Prepare('DELETE FROM connection_jump WHERE connection_uuid=?;');
      try
        st.BindText(1, AUuid);
        st.Step;
      finally
        st.Free;
      end;
    end
    else
    begin
      st := Db.Prepare('INSERT INTO connection_jump' +
        ' (connection_uuid, jump_via_uuid) VALUES(?,?)' +
        ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
        ' jump_via_uuid=excluded.jump_via_uuid;');
      try
        st.BindText(1, AUuid);
        st.BindText(2, AJumpUuid);
        st.Step;
      finally
        st.Free;
      end;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.JumpHostOffersAvailable: Boolean;
var
  st: TSqliteStmt;
begin
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''jump_host_offers'' LIMIT 1;');
  try
    Result := st.Step;
  finally
    st.Free;
  end;
end;

function TRshModel.IsJumpHostOffered(const AConnUuid: string): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  if not JumpHostOffersAvailable then Exit;
  st := Db.Prepare('SELECT 1 FROM jump_host_offers WHERE connection_uuid=?;');
  try
    st.BindText(1, AConnUuid);
    Result := st.Step;
  finally
    st.Free;
  end;
end;

procedure TRshModel.LoadJumpHostOffers(AList: TStrings);
var
  st: TSqliteStmt;
begin
  if AList = nil then Exit;
  AList.Clear;
  if not JumpHostOffersAvailable then Exit;
  st := Db.Prepare('SELECT connection_uuid FROM jump_host_offers;');
  try
    while st.Step do
      AList.Add(st.ColText(0));
  finally
    st.Free;
  end;
end;

function TRshModel.CountJumpDependents(const AConnUuid: string): Integer;
var
  st: TSqliteStmt;
begin
  Result := 0;
  if AConnUuid = '' then Exit;
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_jump'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT COUNT(*) FROM connection_jump WHERE jump_via_uuid=?;');
  try
    st.BindText(1, AConnUuid);
    if st.Step then
      Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetJumpHostOffered(const AConnUuid: string;
  AOffered: Boolean);
var
  st: TSqliteStmt;
  n: TRshNode;
begin
  if not JumpHostOffersAvailable then
    raise EModelError.Create(
      'This document uses an older schema and cannot store jump host flags.');
  n := GetNode(AConnUuid);
  try
    if n.Kind <> nkConnection then
      raise EModelError.Create('Only a connection can be a jump host.');
    if n.Protocol <> rpSsh then
      raise EModelError.Create('Only an SSH connection can be a jump host.');
  finally
    n.Free;
  end;
  Db.BeginImmediate;
  try
    if AOffered then
      st := Db.Prepare('INSERT OR IGNORE INTO jump_host_offers' +
        ' (connection_uuid) VALUES(?);')
    else
      st := Db.Prepare('DELETE FROM jump_host_offers WHERE connection_uuid=?;');
    try
      st.BindText(1, AConnUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.CreateContainerConnection(const AParentGroupUuid: string;
  AName: string; const AParentSshUuid: string; AEngine: TContainerEngine;
  const AContainerName: string; AShell: TContainerShell): string;
var
  err, cname: string;
  n: TRshNode;
  parent: TRshNode;
  st: TSqliteStmt;
begin
  if not ValidateName(AName, err) then
    raise EModelError.Create(err);
  cname := AContainerName;
  if not ValidateContainerName(cname, err) then
    raise EModelError.Create(err);
  if AParentSshUuid = '' then
    raise EModelError.Create('A container must reference a host to connect via.');
  parent := GetNode(AParentSshUuid);
  try
    if parent.Kind <> nkConnection then
      raise EModelError.Create('The container host must be a connection, not a folder.');
    if parent.Protocol <> rpSsh then
      raise EModelError.Create('The container host must be an SSH connection.');
  finally
    parent.Free;
  end;
  Db.BeginImmediate;
  try
    EnsureParentIsGroup(AParentGroupUuid);
    EnsureNodeBudget(1);
    n := TRshNode.Create;
    try
      n.Uuid := NewUuid;
      n.ParentUuid := AParentGroupUuid;
      n.Kind := nkConnection;
      n.DisplayName := AName;
      n.IconId := ICON_CONTAINER;
      n.SortOrder := NextSortOrder(AParentGroupUuid);
      n.Protocol := rpContainer;
      // Un conteneur n'a ni hote ni port propres: hostname='' passe le NOT NULL,
      // mais le CHECK impose 1..65535 au port -- d'ou ce port SSH decoratif.
      n.Hostname := '';
      n.Port := SSH_DEFAULT_PORT;
      n.ConnectTimeoutS := 15;
      n.InheritCredential := False;
      InsertNodeRow(n);
      Result := n.Uuid;
    finally
      n.Free;
    end;
    st := Db.Prepare('INSERT INTO connection_container(connection_uuid,' +
      ' parent_uuid, engine, container_name, shell_mode)' +
      ' VALUES(?,?,?,?,?);');
    try
      st.BindText(1, Result);
      st.BindText(2, AParentSshUuid);
      st.BindText(3, CONTAINER_ENGINE_NAMES[AEngine]);
      st.BindText(4, cname);
      st.BindText(5, CONTAINER_SHELL_NAMES[AShell]);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.GetContainerConfig(const AUuid: string;
  out AConfig: TContainerConfig): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  AConfig := Default(TContainerConfig);
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_container'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT parent_uuid, engine, container_name, shell_mode' +
    ' FROM connection_container WHERE connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if not st.Step then Exit;
    AConfig.ParentUuid := st.ColText(0);
    AConfig.Engine := ContainerEngineFromName(st.ColText(1));
    AConfig.ContainerName := st.ColText(2);
    AConfig.Shell := ContainerShellFromName(st.ColText(3));
    Result := True;
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetContainerConfig(const AUuid: string;
  const AConfig: TContainerConfig);
var
  err, cname: string;
  st: TSqliteStmt;
  parent: TRshNode;
begin
  cname := AConfig.ContainerName;
  if not ValidateContainerName(cname, err) then
    raise EModelError.Create(err);
  if AConfig.ParentUuid = '' then
    raise EModelError.Create('A container must reference a host to connect via.');
  parent := GetNode(AConfig.ParentUuid);
  try
    if (parent.Kind <> nkConnection) or (parent.Protocol <> rpSsh) then
      raise EModelError.Create('The container host must be an SSH connection.');
  finally
    parent.Free;
  end;
  Db.BeginImmediate;
  try
    st := Db.Prepare('INSERT INTO connection_container(connection_uuid,' +
      ' parent_uuid, engine, container_name, shell_mode) VALUES(?,?,?,?,?)' +
      ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
      ' parent_uuid=excluded.parent_uuid, engine=excluded.engine,' +
      ' container_name=excluded.container_name,' +
      ' shell_mode=excluded.shell_mode;');
    try
      st.BindText(1, AUuid);
      st.BindText(2, AConfig.ParentUuid);
      st.BindText(3, CONTAINER_ENGINE_NAMES[AConfig.Engine]);
      st.BindText(4, cname);
      st.BindText(5, CONTAINER_SHELL_NAMES[AConfig.Shell]);
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.CountContainerDependents(const AParentUuid: string): Integer;
var
  st: TSqliteStmt;
begin
  Result := 0;
  if AParentUuid = '' then Exit;
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_container'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT COUNT(*) FROM connection_container' +
    ' WHERE parent_uuid=?;');
  try
    st.BindText(1, AParentUuid);
    if st.Step then
      Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

procedure ValidatePodFields(var ANamespace, APodName, AContainerName: string);
var
  err: string;
begin
  if not ValidateK8sName(APodName, err) then
    raise EModelError.Create(err);
  ANamespace := Trim(ANamespace);
  if (ANamespace <> '') and not ValidateK8sLabel(ANamespace, err) then
    raise EModelError.Create('Namespace: ' + err);
  AContainerName := Trim(AContainerName);
  if (AContainerName <> '') and not ValidateK8sLabel(AContainerName, err) then
    raise EModelError.Create('Container: ' + err);
end;

function TRshModel.CreatePodConnection(const AParentGroupUuid: string;
  AName: string; const AParentSshUuid: string; const ANamespace,
  APodName, AContainerName: string; AShell: TContainerShell): string;
var
  err, ns, pod, cont: string;
  n: TRshNode;
  parent: TRshNode;
  st: TSqliteStmt;
begin
  if not ValidateName(AName, err) then
    raise EModelError.Create(err);
  ns := ANamespace; pod := APodName; cont := AContainerName;
  ValidatePodFields(ns, pod, cont);
  if AParentSshUuid = '' then
    raise EModelError.Create('A pod must reference a host to connect via.');
  parent := GetNode(AParentSshUuid);
  try
    if parent.Kind <> nkConnection then
      raise EModelError.Create('The pod host must be a connection, not a folder.');
    if parent.Protocol <> rpSsh then
      raise EModelError.Create('The pod host must be an SSH connection.');
  finally
    parent.Free;
  end;
  Db.BeginImmediate;
  try
    EnsureParentIsGroup(AParentGroupUuid);
    EnsureNodeBudget(1);
    n := TRshNode.Create;
    try
      n.Uuid := NewUuid;
      n.ParentUuid := AParentGroupUuid;
      n.Kind := nkConnection;
      n.DisplayName := AName;
      n.IconId := ICON_POD;
      n.SortOrder := NextSortOrder(AParentGroupUuid);
      n.Protocol := rpPod;
      n.Hostname := '';
      n.Port := SSH_DEFAULT_PORT;
      n.ConnectTimeoutS := 15;
      n.InheritCredential := False;
      InsertNodeRow(n);
      Result := n.Uuid;
    finally
      n.Free;
    end;
    st := Db.Prepare('INSERT INTO connection_pod(connection_uuid,' +
      ' parent_uuid, namespace, pod_name, container_name, shell_mode)' +
      ' VALUES(?,?,?,?,?,?);');
    try
      st.BindText(1, Result);
      st.BindText(2, AParentSshUuid);
      st.BindText(3, ns);
      st.BindText(4, pod);
      st.BindText(5, cont);
      st.BindText(6, CONTAINER_SHELL_NAMES[AShell]);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.GetPodConfig(const AUuid: string;
  out AConfig: TPodConfig): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  AConfig := Default(TPodConfig);
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_pod'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT parent_uuid, namespace, pod_name, container_name,' +
    ' shell_mode FROM connection_pod WHERE connection_uuid=?;');
  try
    st.BindText(1, AUuid);
    if not st.Step then Exit;
    AConfig.ParentUuid := st.ColText(0);
    AConfig.Namespace := st.ColText(1);
    AConfig.PodName := st.ColText(2);
    AConfig.ContainerName := st.ColText(3);
    AConfig.Shell := ContainerShellFromName(st.ColText(4));
    Result := True;
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetPodConfig(const AUuid: string; const AConfig: TPodConfig);
var
  ns, pod, cont: string;
  st: TSqliteStmt;
  parent: TRshNode;
begin
  ns := AConfig.Namespace; pod := AConfig.PodName; cont := AConfig.ContainerName;
  ValidatePodFields(ns, pod, cont);
  if AConfig.ParentUuid = '' then
    raise EModelError.Create('A pod must reference a host to connect via.');
  parent := GetNode(AConfig.ParentUuid);
  try
    if (parent.Kind <> nkConnection) or (parent.Protocol <> rpSsh) then
      raise EModelError.Create('The pod host must be an SSH connection.');
  finally
    parent.Free;
  end;
  Db.BeginImmediate;
  try
    st := Db.Prepare('INSERT INTO connection_pod(connection_uuid,' +
      ' parent_uuid, namespace, pod_name, container_name, shell_mode)' +
      ' VALUES(?,?,?,?,?,?)' +
      ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
      ' parent_uuid=excluded.parent_uuid, namespace=excluded.namespace,' +
      ' pod_name=excluded.pod_name, container_name=excluded.container_name,' +
      ' shell_mode=excluded.shell_mode;');
    try
      st.BindText(1, AUuid);
      st.BindText(2, AConfig.ParentUuid);
      st.BindText(3, ns);
      st.BindText(4, pod);
      st.BindText(5, cont);
      st.BindText(6, CONTAINER_SHELL_NAMES[AConfig.Shell]);
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('UPDATE nodes SET updated_at_ms=? WHERE uuid=?;');
    try
      st.BindInt64(1, NowUtcMs);
      st.BindText(2, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.CountPodDependents(const AParentUuid: string): Integer;
var
  st: TSqliteStmt;
begin
  Result := 0;
  if AParentUuid = '' then Exit;
  st := Db.Prepare('SELECT 1 FROM sqlite_master WHERE type=''table''' +
    ' AND name=''connection_pod'' LIMIT 1;');
  try
    if not st.Step then Exit;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT COUNT(*) FROM connection_pod WHERE parent_uuid=?;');
  try
    st.BindText(1, AParentUuid);
    if st.Step then
      Result := st.ColInt64(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.DeleteNode(const AUuid: string);
var
  st: TSqliteStmt;
begin
  Db.BeginImmediate;
  try
    st := Db.Prepare('DELETE FROM nodes WHERE uuid=?;');
    try
      st.BindText(1, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    GcOrphanCredentials;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.PurgeOrphanCredentials;
begin
  Db.BeginImmediate;
  try
    GcOrphanCredentials;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.GcOrphanCredentials;
var
  st: TSqliteStmt;
  orphans: TStringArray;
  i, k: Integer;
begin
  // Dans une transaction. folder_credentials compte comme reference (0013), et
  // les GERES sont exclus: ils doivent survivre a zero reference.
  orphans := nil;
  k := 0;
  st := Db.Prepare('SELECT uuid FROM credentials WHERE managed=0 AND uuid NOT IN ' +
    '(SELECT credential_uuid FROM connections WHERE credential_uuid IS NOT NULL)' +
    ' AND uuid NOT IN (SELECT credential_uuid FROM folder_credentials);');
  try
    while st.Step do
    begin
      SetLength(orphans, k + 1);
      orphans[k] := st.ColText(0);
      Inc(k);
    end;
  finally
    st.Free;
  end;
  for i := 0 to High(orphans) do
  begin
    DeleteSecretsOf(orphans[i]);
    st := Db.Prepare('DELETE FROM credentials WHERE uuid=?;');
    try
      st.BindText(1, orphans[i]);
      st.Step;
    finally
      st.Free;
    end;
  end;
end;

procedure TRshModel.MoveNode(const AUuid, ANewParentUuid: string;
  ASortOrder: Integer);
var
  st: TSqliteStmt;
  cur: string;
  moved: TRshNode;
  steps: Integer;
begin
  if AUuid = ANewParentUuid then
    raise EModelError.Create('A folder cannot contain itself.');
  moved := GetNode(AUuid);
  try
    Db.BeginImmediate;
    try
      EnsureParentIsGroup(ANewParentUuid);
      // Refus des cycles: la destination ne doit pas descendre de AUuid.
      // Cap d'iterations: un cycle forge sans AUuid ferait boucler la remontee.
      cur := ANewParentUuid;
      steps := 0;
      while cur <> '' do
      begin
        Inc(steps);
        if steps > MAX_TREE_DEPTH + 1 then
          raise EModelError.Create('Cycle detected in the tree.');
        if cur = AUuid then
          raise EModelError.Create(
            'Cannot move a folder into one of its own subfolders.');
        st := Db.Prepare('SELECT COALESCE(parent_uuid,'''') FROM nodes' +
          ' WHERE uuid=?;');
        try
          st.BindText(1, cur);
          if not st.Step then Break;
          cur := st.ColText(0);
        finally
          st.Free;
        end;
      end;
      if ANewParentUuid <> '' then
        if NodeDepth(ANewParentUuid) + SubtreeHeight(AUuid) > MAX_TREE_DEPTH
        then
          raise EModelError.Create(
            'Maximum tree depth reached.');

      if ASortOrder < 0 then
        ASortOrder := NextSortOrder(ANewParentUuid);
      if ANewParentUuid = '' then
        st := Db.Prepare('UPDATE nodes SET sort_order = sort_order + 1' +
          ' WHERE parent_uuid IS NULL AND sort_order >= ?;')
      else
      begin
        st := Db.Prepare('UPDATE nodes SET sort_order = sort_order + 1' +
          ' WHERE parent_uuid = ?2 AND sort_order >= ?1;');
      end;
      try
        st.BindInt64(1, ASortOrder);
        if ANewParentUuid <> '' then
          st.BindText(2, ANewParentUuid);
        st.Step;
      finally
        st.Free;
      end;
      st := Db.Prepare('UPDATE nodes SET parent_uuid=?, sort_order=?,' +
        ' updated_at_ms=? WHERE uuid=?;');
      try
        if ANewParentUuid = '' then
          st.BindNull(1)
        else
          st.BindText(1, ANewParentUuid);
        st.BindInt64(2, ASortOrder);
        st.BindInt64(3, NowUtcMs);
        st.BindText(4, AUuid);
        st.Step;
      finally
        st.Free;
      end;
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;
  finally
    moved.Free;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.DuplicateSubtree(const ASrcUuid, ADestParent: string;
  ASortOrder: Integer; const ANameSuffix: string; ADepth: Integer): string;
var
  src: TRshNode;
  st: TSqliteStmt;
  children: array of string;
  i: Integer;
begin
  if ADepth > MAX_TREE_DEPTH then
    raise EModelError.Create('Cycle or excessive depth in the tree.');
  src := GetNode(ASrcUuid);
  try
    src.Uuid := NewUuid;
    src.ParentUuid := ADestParent;
    src.DisplayName := src.DisplayName + ANameSuffix;
    src.SortOrder := ASortOrder;
    InsertNodeRow(src);
    Result := src.Uuid;
    if src.Kind = nkGroup then
    begin
      st := Db.Prepare('INSERT INTO folder_credentials' +
        ' (folder_uuid, protocol, credential_uuid)' +
        ' SELECT ?, protocol, credential_uuid FROM folder_credentials' +
        ' WHERE folder_uuid=?;');
      try
        st.BindText(1, Result);
        st.BindText(2, ASrcUuid);
        st.Step;
      finally
        st.Free;
      end;
    end;
  finally
    src.Free;
  end;
  children := nil;
  st := Db.Prepare('SELECT uuid FROM nodes WHERE parent_uuid=?' +
    ' ORDER BY sort_order, display_name;');
  try
    st.BindText(1, ASrcUuid);
    while st.Step do
    begin
      SetLength(children, Length(children) + 1);
      children[High(children)] := st.ColText(0);
    end;
  finally
    st.Free;
  end;
  for i := 0 to High(children) do
    DuplicateSubtree(children[i], Result, i, '', ADepth + 1);
end;

function TRshModel.DuplicateNode(const AUuid: string): string;
var
  src: TRshNode;
  cnt: Integer;
  st: TSqliteStmt;
begin
  src := GetNode(AUuid);
  try
    // Taille REELLE du sous-arbre, pas du document. UNION et pas UNION ALL:
    // la deduplication fait terminer la recursion sur un cycle forge.
    st := Db.Prepare('WITH RECURSIVE sub(uuid) AS (' +
      ' SELECT uuid FROM nodes WHERE uuid=?' +
      ' UNION SELECT n.uuid FROM nodes n JOIN sub s ON n.parent_uuid=s.uuid)' +
      ' SELECT COUNT(*) FROM sub;');
    try
      st.BindText(1, AUuid);
      st.Step;
      cnt := st.ColInt64(0);
    finally
      st.Free;
    end;
    Db.BeginImmediate;
    try
      EnsureNodeBudget(cnt);
      Result := DuplicateSubtree(AUuid, src.ParentUuid,
        NextSortOrder(src.ParentUuid), ' (copy)');
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;
  finally
    src.Free;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.GetConnectionCredential(const AConnUuid: string): string;
var
  n: TRshNode;
begin
  n := GetNode(AConnUuid);
  try
    Result := n.CredentialUuid;
  finally
    n.Free;
  end;
end;

{ heritage de credentials par dossier }

function TRshModel.GetFolderCredential(const AFolderUuid: string;
  AProtocol: TRshProtocol): string;
var
  st: TSqliteStmt;
begin
  Result := '';
  st := Db.Prepare('SELECT credential_uuid FROM folder_credentials' +
    ' WHERE folder_uuid=? AND protocol=?;');
  try
    st.BindText(1, AFolderUuid);
    st.BindText(2, PROTOCOL_NAMES[AProtocol]);
    if st.Step then
      Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetFolderCredential(const AFolderUuid: string;
  AProtocol: TRshProtocol; const ACredentialUuid: string);
var
  st: TSqliteStmt;
begin
  if AFolderUuid = '' then
    raise EModelError.Create(
      'The document root cannot carry credentials.');
  Db.BeginImmediate;
  try
    st := Db.Prepare('SELECT node_type FROM nodes WHERE uuid=?;');
    try
      st.BindText(1, AFolderUuid);
      if not st.Step then
        raise EModelError.Create('The folder does not exist.');
      if st.ColText(0) <> 'group' then
        raise EModelError.Create('Only a folder can carry credentials.');
    finally
      st.Free;
    end;
    if ACredentialUuid = '' then
    begin
      st := Db.Prepare('DELETE FROM folder_credentials' +
        ' WHERE folder_uuid=? AND protocol=?;');
      try
        st.BindText(1, AFolderUuid);
        st.BindText(2, PROTOCOL_NAMES[AProtocol]);
        st.Step;
      finally
        st.Free;
      end;
    end
    else
    begin
      st := Db.Prepare('INSERT INTO folder_credentials' +
        ' (folder_uuid, protocol, credential_uuid) VALUES(?,?,?)' +
        ' ON CONFLICT(folder_uuid, protocol) DO UPDATE SET' +
        ' credential_uuid=excluded.credential_uuid;');
      try
        st.BindText(1, AFolderUuid);
        st.BindText(2, PROTOCOL_NAMES[AProtocol]);
        st.BindText(3, ACredentialUuid);
        st.Step;
      finally
        st.Free;
      end;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.ResolveFolderCredential(const AStartFolderUuid: string;
  AProtocol: TRshProtocol; out ASourceFolderName: string): string;
var
  st: TSqliteStmt;
  cur: string;
  hops: Integer;
begin
  Result := '';
  ASourceFolderName := '';
  cur := AStartFolderUuid;
  hops := 0;
  while (cur <> '') and (hops <= MAX_TREE_DEPTH) do
  begin
    Inc(hops);
    st := Db.Prepare('SELECT credential_uuid FROM folder_credentials' +
      ' WHERE folder_uuid=? AND protocol=?;');
    try
      st.BindText(1, cur);
      st.BindText(2, PROTOCOL_NAMES[AProtocol]);
      if st.Step then
        Result := st.ColText(0);
    finally
      st.Free;
    end;
    st := Db.Prepare('SELECT display_name, COALESCE(parent_uuid,'''')' +
      ' FROM nodes WHERE uuid=?;');
    try
      st.BindText(1, cur);
      if not st.Step then Exit('');
      if Result <> '' then
      begin
        ASourceFolderName := st.ColText(0);
        Exit;
      end;
      cur := st.ColText(1);
    finally
      st.Free;
    end;
  end;
end;

function TRshModel.ResolveConnectionCredential(const AConnUuid: string;
  out ASourceFolderName: string): string;
var
  n: TRshNode;
begin
  ASourceFolderName := '';
  n := GetNode(AConnUuid);
  try
    if n.InheritCredential then
      Result := ResolveFolderCredential(n.ParentUuid, n.Protocol,
        ASourceFolderName)
    else
      Result := n.CredentialUuid;
  finally
    n.Free;
  end;
end;

{ credentials }

procedure TRshModel.StoreSecret(const AOwnerUuid, AFieldName: string;
  ASecret: TSecureBytes; out AValueId: string);
var
  st: TSqliteStmt;
  nonce, cipher: TBytes;
  nowMs: Int64;
begin
  FDoc.EncryptFieldValue(AOwnerUuid, AFieldName, ASecret, nonce, cipher);
  AValueId := NewUuid;
  nowMs := NowUtcMs;
  st := Db.Prepare('INSERT INTO encrypted_values(uuid, owner_uuid,' +
    ' field_name, crypto_version, nonce, ciphertext, created_at_ms,' +
    ' updated_at_ms) VALUES(?,?,?,?,?,?,?,?)' +
    ' ON CONFLICT(owner_uuid, field_name) DO UPDATE SET' +
    ' nonce=excluded.nonce, ciphertext=excluded.ciphertext,' +
    ' updated_at_ms=excluded.updated_at_ms;');
  try
    st.BindText(1, AValueId);
    st.BindText(2, AOwnerUuid);
    st.BindText(3, AFieldName);
    st.BindInt64(4, RSH_CRYPTO_VERSION);
    st.BindBlob(5, nonce);
    st.BindBlob(6, cipher);
    st.BindInt64(7, nowMs);
    st.BindInt64(8, nowMs);
    st.Step;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT uuid FROM encrypted_values WHERE owner_uuid=?' +
    ' AND field_name=?;');
  try
    st.BindText(1, AOwnerUuid);
    st.BindText(2, AFieldName);
    if st.Step then
      AValueId := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.DeleteSecretsOf(const AOwnerUuid: string);
var
  st: TSqliteStmt;
begin
  st := Db.Prepare('DELETE FROM encrypted_values WHERE owner_uuid=?;');
  try
    st.BindText(1, AOwnerUuid);
    st.Step;
  finally
    st.Free;
  end;
end;

function TRshModel.ListCredentials: TRshCredentialList;
var
  st: TSqliteStmt;
  c: TRshCredential;
begin
  Result := TRshCredentialList.Create(True);
  st := Db.Prepare('SELECT uuid, display_name, auth_type, username,' +
    ' domain_name, key_path_hint,' +
    ' encrypted_password_id IS NOT NULL,' +
    ' encrypted_key_id IS NOT NULL,' +
    ' encrypted_key_pass_id IS NOT NULL,' +
    ' managed, public_key' +
    ' FROM credentials ORDER BY display_name;');
  try
    while st.Step do
    begin
      c := TRshCredential.Create;
      c.Uuid := st.ColText(0);
      c.DisplayName := st.ColText(1);
      c.AuthType := AuthTypeFromName(st.ColText(2));
      c.Username := st.ColText(3);
      c.DomainName := st.ColText(4);
      c.KeyPathHint := st.ColText(5);
      c.HasPassword := st.ColInt64(6) <> 0;
      c.HasPrivateKey := st.ColInt64(7) <> 0;
      c.HasKeyPassphrase := st.ColInt64(8) <> 0;
      c.Managed := st.ColInt64(9) <> 0;
      c.PublicKey := st.ColText(10);
      Result.Add(c);
    end;
  finally
    st.Free;
  end;
end;

function TRshModel.GetCredential(const AUuid: string): TRshCredential;
var
  list: TRshCredentialList;
  i: Integer;
begin
  Result := nil;
  list := ListCredentials;
  try
    for i := 0 to list.Count - 1 do
      if list[i].Uuid = AUuid then
      begin
        Result := list.Extract(list[i]);
        Break;
      end;
  finally
    list.Free;
  end;
  if Result = nil then
    raise EModelError.Create('Credential not found.');
end;

function TRshModel.ListManagedCredentials: TRshCredentialList;
var
  all: TRshCredentialList;
  i: Integer;
begin
  Result := TRshCredentialList.Create(True);
  all := ListCredentials;
  try
    // Extract cede l'objet a Result et decale les suivants: n'avancer i QUE
    // quand on ne retire rien, sinon on saute un element sur deux.
    i := 0;
    while i < all.Count do
      if all[i].Managed then
        Result.Add(all.Extract(all[i]))
      else
        Inc(i);
  finally
    all.Free;
  end;
end;

function TRshModel.IsManagedCredential(const AUuid: string): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  if AUuid = '' then Exit;
  st := Db.Prepare('SELECT managed FROM credentials WHERE uuid=?;');
  try
    st.BindText(1, AUuid);
    if st.Step then
      Result := st.ColInt64(0) <> 0;
  finally
    st.Free;
  end;
end;

function TRshModel.CreateCredential(ADisplayName: string;
  AAuthType: TAuthType; const AUsername, ADomain, AKeyPathHint: string;
  APassword, APrivateKey, AKeyPassphrase: TSecureBytes;
  AManaged: Boolean): string;
var
  err, pwId, keyId, kpId: string;
  st: TSqliteStmt;
  nowMs: Int64;
begin
  if not ValidateName(ADisplayName, err) then
    raise EModelError.Create(err);
  Result := NewUuid;
  nowMs := NowUtcMs;
  Db.BeginImmediate;
  try
    pwId := '';
    keyId := '';
    kpId := '';
    if APassword <> nil then
      StoreSecret(Result, FIELD_CRED_PASSWORD, APassword, pwId);
    if APrivateKey <> nil then
      StoreSecret(Result, FIELD_CRED_PRIVATE_KEY, APrivateKey, keyId);
    if AKeyPassphrase <> nil then
      StoreSecret(Result, FIELD_CRED_KEY_PASSPHRASE, AKeyPassphrase, kpId);
    st := Db.Prepare('INSERT INTO credentials(uuid, display_name,' +
      ' auth_type, username, domain_name, encrypted_password_id,' +
      ' encrypted_key_id, encrypted_key_pass_id, key_path_hint, managed,' +
      ' created_at_ms, updated_at_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?);');
    try
      st.BindText(1, Result);
      st.BindText(2, ADisplayName);
      st.BindText(3, AUTH_TYPE_NAMES[AAuthType]);
      st.BindText(4, AUsername);
      st.BindText(5, ADomain);
      if pwId = '' then st.BindNull(6) else st.BindText(6, pwId);
      if keyId = '' then st.BindNull(7) else st.BindText(7, keyId);
      if kpId = '' then st.BindNull(8) else st.BindText(8, kpId);
      st.BindText(9, AKeyPathHint);
      st.BindInt64(10, Ord(AManaged));
      st.BindInt64(11, nowMs);
      st.BindInt64(12, nowMs);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.UpdateCredential(const AUuid: string;
  ADisplayName: string; AAuthType: TAuthType;
  const AUsername, ADomain, AKeyPathHint: string;
  APassword, APrivateKey, AKeyPassphrase: TSecureBytes;
  AClearPassword: Boolean; AClearKey: Boolean; AClearKeyPass: Boolean);
var
  err, vid: string;
  st: TSqliteStmt;

  procedure DropField(const AField, ACol: string);
  var
    s2: TSqliteStmt;
  begin
    s2 := Db.Prepare('DELETE FROM encrypted_values WHERE owner_uuid=?' +
      ' AND field_name=?;');
    try
      s2.BindText(1, AUuid);
      s2.BindText(2, AField);
      s2.Step;
    finally
      s2.Free;
    end;
    Db.ExecScript(Format('UPDATE credentials SET %s=NULL WHERE uuid=%s;',
      [ACol, QuotedStr(AUuid)]));
  end;

  procedure PutField(ASecret: TSecureBytes; const AField, ACol: string);
  var
    s2: TSqliteStmt;
  begin
    StoreSecret(AUuid, AField, ASecret, vid);
    s2 := Db.Prepare(Format('UPDATE credentials SET %s=? WHERE uuid=?;',
      [ACol]));
    try
      s2.BindText(1, vid);
      s2.BindText(2, AUuid);
      s2.Step;
    finally
      s2.Free;
    end;
  end;

begin
  if not ValidateName(ADisplayName, err) then
    raise EModelError.Create(err);
  Db.BeginImmediate;
  try
    st := Db.Prepare('UPDATE credentials SET display_name=?, auth_type=?,' +
      ' username=?, domain_name=?, key_path_hint=?, updated_at_ms=?' +
      ' WHERE uuid=?;');
    try
      st.BindText(1, ADisplayName);
      st.BindText(2, AUTH_TYPE_NAMES[AAuthType]);
      st.BindText(3, AUsername);
      st.BindText(4, ADomain);
      st.BindText(5, AKeyPathHint);
      st.BindInt64(6, NowUtcMs);
      st.BindText(7, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    // Quitter atManagedKey efface public_key: sinon Copy SSH ID proposerait
    // encore d'installer une paire fantome.
    if AAuthType <> atManagedKey then
      Db.ExecScript(Format('UPDATE credentials SET public_key=%s WHERE uuid=%s;',
        [QuotedStr(''), QuotedStr(AUuid)]));
    if AClearPassword then
      DropField(FIELD_CRED_PASSWORD, 'encrypted_password_id')
    else if APassword <> nil then
      PutField(APassword, FIELD_CRED_PASSWORD, 'encrypted_password_id');
    if AClearKey then
      DropField(FIELD_CRED_PRIVATE_KEY, 'encrypted_key_id')
    else if APrivateKey <> nil then
      PutField(APrivateKey, FIELD_CRED_PRIVATE_KEY, 'encrypted_key_id');
    if AClearKeyPass then
      DropField(FIELD_CRED_KEY_PASSPHRASE, 'encrypted_key_pass_id')
    else if AKeyPassphrase <> nil then
      PutField(AKeyPassphrase, FIELD_CRED_KEY_PASSPHRASE,
        'encrypted_key_pass_id');
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.DuplicateCredential(const AUuid: string): string;
var
  src: TRshCredential;
  fields: array[0..2] of string;
  cols: array[0..2] of string;
  i: Integer;
  secret: TSecureBytes;
  newId, vid: string;
  st: TSqliteStmt;
  nowMs: Int64;
begin
  newId := '';
  src := GetCredential(AUuid);
  try
    newId := NewUuid;
    nowMs := NowUtcMs;
    Db.BeginImmediate;
    try
      st := Db.Prepare('INSERT INTO credentials(uuid, display_name,' +
        ' auth_type, username, domain_name, key_path_hint, managed,' +
        ' public_key, created_at_ms, updated_at_ms)' +
        ' VALUES(?,?,?,?,?,?,?,?,?,?);');
      try
        st.BindText(1, newId);
        st.BindText(2, src.DisplayName + ' (copy)');
        st.BindText(3, AUTH_TYPE_NAMES[src.AuthType]);
        st.BindText(4, src.Username);
        st.BindText(5, src.DomainName);
        st.BindText(6, src.KeyPathHint);
        st.BindInt64(7, Ord(src.Managed));
        st.BindText(8, src.PublicKey);
        st.BindInt64(9, nowMs);
        st.BindInt64(10, nowMs);
        st.Step;
      finally
        st.Free;
      end;
      // rechiffre sous le nouvel owner_uuid: l'AAD change, recopier les
      // ciphertexts se ferait rejeter -- et c'est le but
      fields[0] := FIELD_CRED_PASSWORD;
      cols[0] := 'encrypted_password_id';
      fields[1] := FIELD_CRED_PRIVATE_KEY;
      cols[1] := 'encrypted_key_id';
      fields[2] := FIELD_CRED_KEY_PASSPHRASE;
      cols[2] := 'encrypted_key_pass_id';
      for i := 0 to 2 do
        if GetSecret(AUuid, fields[i], secret) then
        try
          StoreSecret(newId, fields[i], secret, vid);
          st := Db.Prepare(Format('UPDATE credentials SET %s=?' +
            ' WHERE uuid=?;', [cols[i]]));
          try
            st.BindText(1, vid);
            st.BindText(2, newId);
            st.Step;
          finally
            st.Free;
          end;
        finally
          secret.Free;
        end;
      Db.Commit;
    except
      Db.Rollback;
      raise;
    end;
  finally
    src.Free;
  end;
  Result := newId;
  FDoc.MarkDirty;
end;

function TRshModel.CredentialSshHosts(const ACredUuid: string): TStringArray;
var
  st: TSqliteStmt;
  uuids: TStringArray;
  srcFolder: string;
  i, n: Integer;
begin
  Result := nil;
  if ACredUuid = '' then Exit;
  // Credential RESOLU: un WHERE credential_uuid=? raterait les hotes en heritage
  uuids := nil;
  st := Db.Prepare('SELECT node_uuid FROM connections' +
    ' WHERE protocol=''ssh'' ORDER BY node_uuid;');
  try
    while st.Step do
    begin
      SetLength(uuids, Length(uuids) + 1);
      uuids[High(uuids)] := st.ColText(0);
    end;
  finally
    st.Free;
  end;
  n := 0;
  SetLength(Result, Length(uuids));
  for i := 0 to High(uuids) do
    if ResolveConnectionCredential(uuids[i], srcFolder) = ACredUuid then
    begin
      Result[n] := uuids[i];
      Inc(n);
    end;
  SetLength(Result, n);
end;

procedure TRshModel.SetManagedKeyPair(const AUuid: string;
  APrivatePem: TSecureBytes; const APublicLine: string);
var
  st: TSqliteStmt;
  vid: string;
begin
  if APrivatePem = nil then
    raise EModelError.Create('No private key to store.');
  Db.BeginImmediate;
  try
    // encrypted_values n'a pas de FK sur owner_uuid: sans cette garde, un uuid
    // errone insere un secret orphelin et l'UPDATE ne touche rien. En silence.
    st := Db.Prepare('SELECT auth_type FROM credentials WHERE uuid=?;');
    try
      st.BindText(1, AUuid);
      if not st.Step then
        raise EModelError.Create('Managed key target credential not found.');
      if st.ColText(0) <> AUTH_TYPE_NAMES[atManagedKey] then
        raise EModelError.Create('Target credential is not a managed key.');
    finally
      st.Free;
    end;
    StoreSecret(AUuid, FIELD_CRED_PRIVATE_KEY, APrivatePem, vid);
    st := Db.Prepare('UPDATE credentials SET encrypted_key_id=?,' +
      ' public_key=?, updated_at_ms=? WHERE uuid=?;');
    try
      st.BindText(1, vid);
      st.BindText(2, APublicLine);
      st.BindInt64(3, NowUtcMs);
      st.BindText(4, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.CredentialUsage(const AUuid: string): TStringArray;
var
  st: TSqliteStmt;
begin
  Result := nil;
  st := Db.Prepare('SELECT n.display_name FROM connections c' +
    ' JOIN nodes n ON n.uuid = c.node_uuid WHERE c.credential_uuid=?;');
  try
    st.BindText(1, AUuid);
    while st.Step do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := st.ColText(0);
    end;
  finally
    st.Free;
  end;
  st := Db.Prepare('SELECT n.display_name FROM folder_credentials f' +
    ' JOIN nodes n ON n.uuid = f.folder_uuid WHERE f.credential_uuid=?;');
  try
    st.BindText(1, AUuid);
    while st.Step do
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := st.ColText(0) + ' (folder)';
    end;
  finally
    st.Free;
  end;
end;

procedure TRshModel.DeleteCredential(const AUuid: string;
  AStrategy: TCredDeleteStrategy; const AReplacementUuid: string);
var
  usage: TStringArray;
  st: TSqliteStmt;
begin
  usage := CredentialUsage(AUuid);
  if (Length(usage) > 0) and (AStrategy = dsFail) then
    raise EModelError.CreateFmt(
      'This credential is used by %d item(s).', [Length(usage)]);
  if (AStrategy = dsReplace) then
  begin
    if (AReplacementUuid = '') or (AReplacementUuid = AUuid) then
      raise EModelError.Create('Invalid replacement credential.');
    GetCredential(AReplacementUuid).Free;
  end;
  Db.BeginImmediate;
  try
    if AStrategy = dsReplace then
    begin
      st := Db.Prepare('UPDATE connections SET credential_uuid=?' +
        ' WHERE credential_uuid=?;');
      try
        st.BindText(1, AReplacementUuid);
        st.BindText(2, AUuid);
        st.Step;
      finally
        st.Free;
      end;
      st := Db.Prepare('UPDATE folder_credentials SET credential_uuid=?' +
        ' WHERE credential_uuid=?;');
      try
        st.BindText(1, AReplacementUuid);
        st.BindText(2, AUuid);
        st.Step;
      finally
        st.Free;
      end;
    end;
    DeleteSecretsOf(AUuid);
    st := Db.Prepare('DELETE FROM credentials WHERE uuid=?;');
    try
      st.BindText(1, AUuid);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.GetSecret(const ACredUuid, AFieldName: string;
  out ASecret: TSecureBytes): Boolean;
var
  st: TSqliteStmt;
  nonce, cipher: TBytes;
begin
  Result := False;
  ASecret := nil;
  st := Db.Prepare('SELECT nonce, ciphertext FROM encrypted_values' +
    ' WHERE owner_uuid=? AND field_name=?;');
  try
    st.BindText(1, ACredUuid);
    st.BindText(2, AFieldName);
    if not st.Step then Exit;
    nonce := st.ColBlob(0);
    cipher := st.ColBlob(1);
  finally
    st.Free;
  end;
  if not FDoc.DecryptFieldValue(ACredUuid, AFieldName, nonce, cipher,
    ASecret) then
    raise EModelError.Create(
      'Unreadable secret: the value was altered or moved.');
  Result := True;
end;

{ ---- acces rapides: connexions recentes et favoris ---- }

function SessionResultFromName(const S: string): TSessionResult;
begin
  if S = 'ok' then Result := srOk
  else if S = 'cancelled' then Result := srCancelled
  else Result := srFailed;
end;

procedure TRshModel.TouchRecent(const AConnUuid: string;
  AResult: TSessionResult);
var
  st: TSqliteStmt;
begin
  if AConnUuid = '' then Exit;
  Db.BeginImmediate;
  try
    // Horodatage STRICTEMENT croissant: deux connexions dans la meme
    // milliseconde sortiraient au hasard. D'ou max(horloge, dernier + 1).
    st := Db.Prepare('INSERT INTO recent_sessions' +
      ' (connection_uuid, last_connected_ms, last_result)' +
      ' VALUES(?, MAX(?, COALESCE(' +
      '   (SELECT MAX(last_connected_ms) FROM recent_sessions), 0) + 1), ?)' +
      ' ON CONFLICT(connection_uuid) DO UPDATE SET' +
      ' last_connected_ms=excluded.last_connected_ms,' +
      ' last_result=excluded.last_result;');
    try
      st.BindText(1, AConnUuid);
      st.BindInt64(2, NowUtcMs);
      st.BindText(3, SESSION_RESULT_NAMES[AResult]);
      st.Step;
    finally
      st.Free;
    end;
    st := Db.Prepare('DELETE FROM recent_sessions WHERE connection_uuid NOT IN' +
      ' (SELECT connection_uuid FROM recent_sessions' +
      '  ORDER BY last_connected_ms DESC LIMIT ?);');
    try
      st.BindInt64(1, MAX_RECENT_ENTRIES);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  // Volontairement PAS de MarkDirty: une tentative de connexion n'est pas une
  // modification de l'utilisateur. La transaction rescelle le content_mac.
end;

function TRshModel.ListRecent(AMax: Integer): TRshQuickList;
var
  st: TSqliteStmt;
  e: TRshQuickEntry;
begin
  Result := TRshQuickList.Create(True);
  if AMax <= 0 then Exit;
  try
    st := Db.Prepare('SELECT r.connection_uuid, n.display_name, c.hostname,' +
      ' c.protocol, r.last_connected_ms, r.last_result' +
      ' FROM recent_sessions r' +
      ' JOIN nodes n ON n.uuid = r.connection_uuid' +
      ' JOIN connections c ON c.node_uuid = r.connection_uuid' +
      ' ORDER BY r.last_connected_ms DESC LIMIT ?;');
    try
      st.BindInt64(1, AMax);
      while st.Step do
      begin
        e := TRshQuickEntry.Create;
        e.ConnUuid := st.ColText(0);
        e.DisplayName := st.ColText(1);
        e.Hostname := st.ColText(2);
        e.Protocol := ProtocolFromName(st.ColText(3));
        e.LastConnectedMs := st.ColInt64(4);
        e.LastResult := SessionResultFromName(st.ColText(5));
        e.Favorite := IsFavorite(e.ConnUuid);
        Result.Add(e);
      end;
    finally
      st.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

procedure TRshModel.ClearRecent;
begin
  Db.BeginImmediate;
  try
    Db.ExecScript('DELETE FROM recent_sessions;');
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

// Les favoris vivent dans document_settings, pas dans une colonne de nodes:
// toute DDL en plus imposerait une migration versionnee. Cher, pour un drapeau.
function FavoriteKey(const AConnUuid: string): string;
begin
  Result := 'favorite:' + AConnUuid;
end;

function TRshModel.IsFavorite(const AConnUuid: string): Boolean;
var
  st: TSqliteStmt;
begin
  Result := False;
  if AConnUuid = '' then Exit;
  st := Db.Prepare('SELECT 1 FROM document_settings WHERE key = ?;');
  try
    st.BindText(1, FavoriteKey(AConnUuid));
    Result := st.Step;
  finally
    st.Free;
  end;
end;

function TRshModel.GetRootIcon: string;
var
  st: TSqliteStmt;
begin
  Result := '';
  st := Db.Prepare('SELECT value_json FROM document_settings WHERE key = ''root_icon'';');
  try
    if st.Step then
      Result := st.ColText(0);
  finally
    st.Free;
  end;
end;

procedure TRshModel.SetRootIcon(const AIconId: string);
var
  st: TSqliteStmt;
begin
  Db.BeginImmediate;
  try
    st := Db.Prepare('INSERT INTO document_settings(key, value_json)' +
      ' VALUES(''root_icon'', ?) ON CONFLICT(key) DO UPDATE' +
      ' SET value_json = excluded.value_json;');
    try
      st.BindText(1, AIconId);
      st.Step;
    finally
      st.Free;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

procedure TRshModel.SetFavorite(const AConnUuid: string; AOn: Boolean);
var
  st: TSqliteStmt;
begin
  if AConnUuid = '' then Exit;
  Db.BeginImmediate;
  try
    if AOn then
    begin
      st := Db.Prepare('INSERT INTO document_settings(key, value_json)' +
        ' VALUES(?, ''true'') ON CONFLICT(key) DO NOTHING;');
      try
        st.BindText(1, FavoriteKey(AConnUuid));
        st.Step;
      finally
        st.Free;
      end;
    end
    else
    begin
      st := Db.Prepare('DELETE FROM document_settings WHERE key = ?;');
      try
        st.BindText(1, FavoriteKey(AConnUuid));
        st.Step;
      finally
        st.Free;
      end;
    end;
    Db.Commit;
  except
    Db.Rollback;
    raise;
  end;
  FDoc.MarkDirty;
end;

function TRshModel.ListFavorites: TRshQuickList;
var
  st: TSqliteStmt;
  e: TRshQuickEntry;
begin
  Result := TRshQuickList.Create(True);
  try
    st := Db.Prepare('SELECT n.uuid, n.display_name, c.hostname, c.protocol,' +
      ' COALESCE(r.last_connected_ms, 0), COALESCE(r.last_result, ''ok'')' +
      ' FROM document_settings s' +
      ' JOIN nodes n ON s.key = ''favorite:'' || n.uuid' +
      ' JOIN connections c ON c.node_uuid = n.uuid' +
      ' LEFT JOIN recent_sessions r ON r.connection_uuid = n.uuid' +
      ' ORDER BY n.display_name COLLATE NOCASE;');
    try
      while st.Step do
      begin
        e := TRshQuickEntry.Create;
        e.ConnUuid := st.ColText(0);
        e.DisplayName := st.ColText(1);
        e.Hostname := st.ColText(2);
        e.Protocol := ProtocolFromName(st.ColText(3));
        e.LastConnectedMs := st.ColInt64(4);
        e.LastResult := SessionResultFromName(st.ColText(5));
        e.Favorite := True;
        Result.Add(e);
      end;
    finally
      st.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TRshModel.ListSubtreeConnections(
  const AGroupUuid: string): TRshQuickList;
var
  nodes: TRshNodeList;
  i: Integer;
  e: TRshQuickEntry;
  st: TSqliteStmt;

  function PathOfAndInScope(const AUuid: string; out AInScope: Boolean): string;
  var
    cur, seg: string;
    hops, k: Integer;
    found: Boolean;
  begin
    Result := '';
    AInScope := AGroupUuid = '';
    cur := '';
    for k := 0 to nodes.Count - 1 do
      if nodes[k].Uuid = AUuid then
      begin
        cur := nodes[k].ParentUuid;
        Break;
      end;
    hops := 0;
    while (cur <> '') and (hops < MAX_TREE_DEPTH + 1) do
    begin
      Inc(hops);
      if cur = AGroupUuid then
        AInScope := True;
      seg := '';
      found := False;
      for k := 0 to nodes.Count - 1 do
        if nodes[k].Uuid = cur then
        begin
          seg := nodes[k].DisplayName;
          cur := nodes[k].ParentUuid;
          found := True;
          Break;
        end;
      if not found then Break;
      if Result = '' then
        Result := seg
      else
        Result := seg + '/' + Result;
    end;
  end;

var
  inScope: Boolean;
  path: string;
begin
  Result := TRshQuickList.Create(True);
  nodes := LoadNodes;
  try
    try
      for i := 0 to nodes.Count - 1 do
      begin
        if nodes[i].Kind <> nkConnection then Continue;
        path := PathOfAndInScope(nodes[i].Uuid, inScope);
        if not inScope then Continue;

        e := TRshQuickEntry.Create;
        e.ConnUuid := nodes[i].Uuid;
        e.DisplayName := nodes[i].DisplayName;
        e.Hostname := nodes[i].Hostname;
        e.Protocol := nodes[i].Protocol;
        e.GroupPath := path;
        e.Favorite := IsFavorite(nodes[i].Uuid);
        e.LastConnectedMs := 0;
        e.LastResult := srOk;
        st := Db.Prepare('SELECT last_connected_ms, last_result' +
          ' FROM recent_sessions WHERE connection_uuid = ?;');
        try
          st.BindText(1, nodes[i].Uuid);
          if st.Step then
          begin
            e.LastConnectedMs := st.ColInt64(0);
            e.LastResult := SessionResultFromName(st.ColText(1));
          end;
        finally
          st.Free;
        end;
        Result.Add(e);
      end;
    except
      Result.Free;
      raise;
    end;
  finally
    nodes.Free;
  end;
end;

end.