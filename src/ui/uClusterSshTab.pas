unit uClusterSshTab;

{$mode objfpc}{$H+}

// Onglet Broadcast SSH facon clusterssh: N terminaux, une barre qui diffuse en
// OCTETS. Chaque cellule est une VRAIE session, comptee au plafond global.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, Graphics, StdCtrls,
  ExtCtrls, LCLType, Clipbrd,
  uTermControl, uSshTransport, uSshKnownHosts, uSessionState,
  uSessionManager, uRshDocument, uSessionTabBase, uSshTunnel,
  uSshTunnelConnect;

const
  CLUSTER_MAX_SESSIONS = 16;

type
  TClusterSshTab = class;

  TClusterCell = class(TCustomControl)
  private
    FOwnerTab: TClusterSshTab;
    FTerm: TRottenTerminalControl;
    FTransport: TSshTransport;
    FKnownHosts: TSshKnownHosts;
    // la cellule POSSEDE son tunnel de rebond; nil = connexion directe
    FTunnel: TSshTunnel;
    FBroker: TSshTunnelBroker;
    FDisplayName: string;
    FConnUuid: string;
    FState: TRemoteSessionState;
    FErrorMsg: string;
    FLabel: TLabel;

    procedure TermSend(const AData: RawByteString);
    procedure TermGridResize(ACols, ARows: Integer);
    procedure TransportData(const AData: RawByteString);
    procedure TransportState(AState: TRemoteSessionState);
    procedure TransportError(const AMessage: string);
    procedure TransportFinished(AExitCode: Integer);
    procedure HostKeyLookup(const AHost: string; APort: Integer;
      const AKeyType, AFingerprint: string;
      out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
    procedure HostKeyAsk(const AInfo: TSshHostKeyInfo;
      var ADecision: TSshHostKeyDecision);
    procedure HostKeySave(const AInfo: TSshHostKeyInfo);
    procedure UpdateHeader;
  public
    constructor CreateCell(AOwnerTab: TClusterSshTab; ADoc: TRshDocument;
      const ADisplayName, AConnUuid: string; AParams: TSshConnectParams;
      AAccent: TColor; AFontSize: Integer);
    destructor Destroy; override;

    procedure Start;
    procedure BeginShutdown;
    procedure Broadcast(const AData: RawByteString);
    procedure AttachTunnel(ATunnel: TSshTunnel; ABroker: TSshTunnelBroker);

    property CellState: TRemoteSessionState read FState;
    property CellName: string read FDisplayName;
    property CellConnUuid: string read FConnUuid;
    property Terminal: TRottenTerminalControl read FTerm;
  end;

  // un handle par cellule: 16 sessions cluster comptent pour 16, pas pour 1
  TClusterCellHandle = class(TManagedSession)
  private
    FCell: TClusterCell;
  public
    constructor Create(ACell: TClusterCell);
    function SessionState: TRemoteSessionState; override;
    function DisplayName: string; override;
    procedure BeginShutdown; override;
  end;

  TClusterSshTab = class(TSessionTabBase)
  private
    FGridHost: TPanel;
    FBar: TEdit;
    FCells: array of TClusterCell;
    FHandles: array of TClusterCellHandle;
    FManager: TSessionManager;
    FGroupName: string;
    FClosing: Boolean;
    FBulkHostKeySet: Boolean;
    FBulkHostKeyDecision: TSshHostKeyDecision;

    procedure GridResize(Sender: TObject);
    procedure LayoutCells;
    procedure CellFinished(ACell: TClusterCell);
    procedure DeferredRemoveCell(Data: PtrInt);
    procedure BarKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure BarUtf8KeyPress(Sender: TObject; var UTF8Key: TUTF8Char);
    procedure PasteBroadcast;
    procedure CellChanged;
    procedure Broadcast(const AData: RawByteString);
  public
    constructor CreateCluster(APages: TPageControl; ADoc: TRshDocument;
      AManager: TSessionManager; const AGroupName: string;
      const ADisplays, AConnUuids: array of string;
      const AParams: array of TSshConnectParams;
      const ATunnels: array of TSshTunnel;
      const ABrokers: array of TSshTunnelBroker);
    destructor Destroy; override;

    procedure Start;
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    function ActiveCount: Integer;
    function CountSessionsIn(AUuids: TStrings): Integer; override;
    procedure ShutdownSessionsIn(AUuids: TStrings); override;
    function HasSessionFor(const AConnUuid: string): Boolean; override;
    // TOFU en gros: cles INCONNUES seulement, jamais une cle CHANGEE
    procedure SetUnknownHostKeyPolicy(ADecision: TSshHostKeyDecision);
    function UnknownHostKeyPolicy(out ADecision: TSshHostKeyDecision): Boolean;
    property Closing: Boolean read FClosing;
    function TabState: TRemoteSessionState; override;
    function TabBarCaption: string; override;

    property GroupName: string read FGroupName;
  end;

implementation

uses
  uHostKeyDialog, uTheme;

const
  CLUSTER_ACCENTS: array[0..15] of TColor = (
    $4EB88F,
    $E8A23D,
    $5B78F0,
    $3DC9E8,
    $D08FFF,
    $8FD4A0,
    $F0B25B,
    $6A5BF0,
    $3DE8C9,
    $E83D8E,
    $91E83D,
    $5BB2F0,
    $C9E83D,
    $3D5BE8,
    $A0D48F,
    $F08F5B
  );

  CELL_BORDER = 2;
  HEADER_H    = 18;
  BAR_H       = 30;

function FontSizeForCount(ACount: Integer): Integer;
begin
  if ACount <= 1 then Result := 13
  else if ACount <= 4 then Result := 11
  else if ACount <= 9 then Result := 10
  else if ACount <= 12 then Result := 9
  else Result := 8;
end;

constructor TClusterCellHandle.Create(ACell: TClusterCell);
begin
  inherited Create;
  FCell := ACell;
end;

function TClusterCellHandle.SessionState: TRemoteSessionState;
begin
  Result := FCell.FState;
end;

function TClusterCellHandle.DisplayName: string;
begin
  Result := FCell.FDisplayName + ' (broadcast)';
end;

procedure TClusterCellHandle.BeginShutdown;
begin
  FCell.BeginShutdown;
end;

constructor TClusterCell.CreateCell(AOwnerTab: TClusterSshTab;
  ADoc: TRshDocument; const ADisplayName, AConnUuid: string;
  AParams: TSshConnectParams; AAccent: TColor; AFontSize: Integer);
begin
  inherited Create(AOwnerTab);
  FOwnerTab := AOwnerTab;
  FDisplayName := ADisplayName;
  FConnUuid := AConnUuid;
  FState := rssCreated;
  Color := AAccent;

  FKnownHosts := TSshKnownHosts.Create(ADoc);

  FLabel := TLabel.Create(Self);
  FLabel.Parent := Self;
  FLabel.AutoSize := False;
  FLabel.Font.Color := clBlack;
  FLabel.Font.Size := 9;
  FLabel.Caption := ' ' + ADisplayName;

  FTerm := TRottenTerminalControl.Create(Self);
  FTerm.Parent := Self;
  FTerm.OnSendData := @TermSend;
  FTerm.OnGridResize := @TermGridResize;
  FTerm.SetTerminalFontSize(AFontSize);
  FTerm.SetDefaultColors(AAccent, clTermBg);

  AParams.Cols := FTerm.GridCols;
  AParams.Rows := FTerm.GridRows;

  FTransport := TSshTransport.Create(AParams);
  FTransport.OnData := @TransportData;
  FTransport.OnStateChanged := @TransportState;
  FTransport.OnError := @TransportError;
  FTransport.OnFinished := @TransportFinished;
  FTransport.OnHostKey := @HostKeyAsk;
  FTransport.OnHostKeyLookup := @HostKeyLookup;
  FTransport.OnHostKeySave := @HostKeySave;
end;

destructor TClusterCell.Destroy;
begin
  if FTransport <> nil then
  begin
    FTransport.Shutdown;
    FTransport.Free;
    FTransport := nil;
  end;
  // le tunnel se ferme APRES le transport, qui ne l'emprunte plus
  if FTunnel <> nil then
  begin
    FTunnel.Shutdown;
    FTunnel.Free;
    FTunnel := nil;
  end;
  FreeAndNil(FBroker);
  // piege mordu deux fois: la fin de session a pu deposer des appels differes
  Application.RemoveAsyncCalls(Self);
  FreeAndNil(FKnownHosts);
  inherited Destroy;
end;

procedure TClusterCell.AttachTunnel(ATunnel: TSshTunnel;
  ABroker: TSshTunnelBroker);
begin
  FTunnel := ATunnel;
  FBroker := ABroker;
end;

procedure TClusterCell.Start;
begin
  FTransport.Start;
end;

procedure TClusterCell.BeginShutdown;
begin
  if FTransport <> nil then
    FTransport.Shutdown;
end;

procedure TClusterCell.Broadcast(const AData: RawByteString);
begin
  if (FTransport <> nil) and (FState = rssConnected) then
    FTransport.SendData(AData);
end;

procedure TClusterCell.TermSend(const AData: RawByteString);
begin
  if (FTransport <> nil) and (FState = rssConnected) then
    FTransport.SendData(AData);
end;

procedure TClusterCell.TermGridResize(ACols, ARows: Integer);
begin
  if FTransport <> nil then
    FTransport.RequestResize(ACols, ARows);
end;

procedure TClusterCell.TransportData(const AData: RawByteString);
begin
  FTerm.FeedData(AData);
end;

procedure TClusterCell.TransportState(AState: TRemoteSessionState);
begin
  FState := AState;
  UpdateHeader;
  if FOwnerTab <> nil then
    FOwnerTab.CellChanged;
end;

procedure TClusterCell.TransportError(const AMessage: string);
begin
  FErrorMsg := AMessage;
  if (FTunnel <> nil) and (FTunnel.LastError <> '') then
    FErrorMsg := FTunnel.LastError;
end;

procedure TClusterCell.TransportFinished(AExitCode: Integer);
begin
  FState := FTransport.State;
  UpdateHeader;
  if (FErrorMsg <> '') and (FOwnerTab <> nil) then
    FOwnerTab.EmitNotice(Format('%s: %s', [FDisplayName, FErrorMsg]));
  if FOwnerTab <> nil then
    FOwnerTab.CellFinished(Self);
end;

procedure TClusterCell.HostKeyLookup(const AHost: string; APort: Integer;
  const AKeyType, AFingerprint: string;
  out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
var
  entry: TKnownHostEntry;
  v: TKnownHostVerdict;
begin
  AVerdict := hkUnknown;
  AKnownFingerprint := '';
  v := FKnownHosts.Verify(AHost, APort, AKeyType, AFingerprint, entry);
  case v of
    khvMatch:
      begin
        AVerdict := hkMatch;
        FKnownHosts.TouchSeen(entry.Uuid);
      end;
    khvChanged:
      begin
        AVerdict := hkChanged;
        AKnownFingerprint := entry.Fingerprint;
      end;
  end;
end;

procedure TClusterCell.HostKeyAsk(const AInfo: TSshHostKeyInfo;
  var ADecision: TSshHostKeyDecision);
var
  bulk: TSshHostKeyDecision;
begin
  // USE-AFTER-FREE: RemoveAsyncCalls ne purge PAS les TThread.Queue.
  if (FOwnerTab = nil) or FOwnerTab.Closing then
  begin
    ADecision := hkdReject;
    Exit;
  end;
  // alerte MITM: toujours individuelle, jamais couverte par la decision groupee
  if AInfo.Verdict = hkChanged then
  begin
    ADecision := AskChangedHostKey(AInfo);
    Exit;
  end;
  if (FOwnerTab <> nil) and FOwnerTab.UnknownHostKeyPolicy(bulk) then
  begin
    ADecision := bulk;
    Exit;
  end;
  ADecision := AskUnknownHostKey(AInfo);
end;

procedure TClusterCell.HostKeySave(const AInfo: TSshHostKeyInfo);
begin
  FKnownHosts.Remember(AInfo.Host, AInfo.Port, AInfo.KeyType,
    AInfo.Fingerprint, AInfo.Blob);
end;

procedure TClusterCell.UpdateHeader;
begin
  FLabel.Caption := Format(' %s — %s',
    [FDisplayName, SessionStateName(FState)]);
end;

constructor TClusterSshTab.CreateCluster(APages: TPageControl;
  ADoc: TRshDocument; AManager: TSessionManager; const AGroupName: string;
  const ADisplays, AConnUuids: array of string;
  const AParams: array of TSshConnectParams;
  const ATunnels: array of TSshTunnel;
  const ABrokers: array of TSshTunnelBroker);
var
  i, fsz, consumed: Integer;
begin
  inherited Create(APages);
  PageControl := APages;
  FManager := AManager;
  FGroupName := AGroupName;
  Caption := AGroupName + ' — Broadcast';

  FBar := TEdit.Create(Self);
  FBar.Parent := Self;
  FBar.Align := alBottom;
  FBar.Height := BAR_H;
  FBar.TextHint := 'Broadcast to all sessions…';
  FBar.OnKeyDown := @BarKeyDown;
  FBar.OnUTF8KeyPress := @BarUtf8KeyPress;

  FGridHost := TPanel.Create(Self);
  FGridHost.Parent := Self;
  FGridHost.Align := alClient;
  FGridHost.BevelOuter := bvNone;
  FGridHost.Color := clSideBg;
  FGridHost.OnResize := @GridResize;

  fsz := FontSizeForCount(Length(AParams));
  SetLength(FCells, Length(AParams));
  SetLength(FHandles, Length(AParams));
  consumed := 0;
  try
    for i := 0 to High(AParams) do
    begin
      FCells[i] := TClusterCell.CreateCell(Self, ADoc, ADisplays[i],
        AConnUuids[i], AParams[i],
        CLUSTER_ACCENTS[i mod Length(CLUSTER_ACCENTS)], fsz);
      consumed := i + 1;
      // AVANT RegisterSession: une levee la-bas laisse le tunnel a la cellule
      FCells[i].AttachTunnel(ATunnels[i], ABrokers[i]);
      FCells[i].Parent := FGridHost;
      FHandles[i] := TClusterCellHandle.Create(FCells[i]);
      FManager.RegisterSession(FHandles[i]);
    end;
  except
    for i := consumed to High(AParams) do
    begin
      AParams[i].Free;
      if ATunnels[i] <> nil then
      begin
        ATunnels[i].Shutdown;
        ATunnels[i].Free;
      end;
      ABrokers[i].Free;
    end;
    raise;
  end;
  LayoutCells;
end;

destructor TClusterSshTab.Destroy;
var
  i: Integer;
  cb: TNotifyEvent;
begin
  FClosing := True;
  for i := 0 to High(FCells) do
    if FCells[i] <> nil then
      FCells[i].BeginShutdown;
  for i := 0 to High(FHandles) do
    if FHandles[i] <> nil then
    begin
      FManager.UnregisterSession(FHandles[i]);
      FreeAndNil(FHandles[i]);
    end;
  Application.RemoveAsyncCalls(Self);
  cb := FOnDestroyed;
  FOnDestroyed := nil;
  // USE-AFTER-FREE: liberer un transport fait WaitFor, qui POMPE les Queue.
  FOnStatusChanged := nil;
  FOnNotice := nil;
  SetLength(FCells, 0);
  SetLength(FHandles, 0);
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TClusterSshTab.Start;
var
  i: Integer;
begin
  for i := 0 to High(FCells) do
    FCells[i].Start;
end;

function TClusterSshTab.ActiveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FCells) do
    if (FCells[i] <> nil) and (not IsTerminalState(FCells[i].CellState)) then
      Inc(Result);
end;

function TClusterSshTab.TabState: TRemoteSessionState;
var
  i: Integer;
begin
  Result := rssDisconnected;
  for i := 0 to High(FCells) do
    if FCells[i] <> nil then
      case FCells[i].CellState of
        rssConnected: Exit(rssConnected);
        rssConnecting, rssAuthenticating: Result := rssConnecting;
      else
        ;
      end;
end;

function TClusterSshTab.TabBarCaption: string;
begin
  Result := Format('%s — Broadcast (%d)', [FGroupName, ActiveCount]);
end;

function TClusterSshTab.ConfirmClose: Boolean;
begin
  if ActiveCount = 0 then
    Exit(True);
  Result := QuestionDlg('Disconnect',
    Format('Disconnect %d broadcast session(s)?', [ActiveCount]),
    mtConfirmation,
    [mrOK, 'Disconnect', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

procedure TClusterSshTab.BeginShutdown;
var
  i: Integer;
begin
  FClosing := True;
  for i := 0 to High(FCells) do
    if FCells[i] <> nil then
      FCells[i].BeginShutdown;
end;

function TClusterSshTab.CountSessionsIn(AUuids: TStrings): Integer;
var
  i: Integer;
begin
  Result := 0;
  if AUuids = nil then Exit;
  for i := 0 to High(FCells) do
    if (FCells[i] <> nil) and (not IsTerminalState(FCells[i].CellState)) and
       (AUuids.IndexOf(FCells[i].CellConnUuid) >= 0) then
      Inc(Result);
end;

procedure TClusterSshTab.ShutdownSessionsIn(AUuids: TStrings);
var
  i: Integer;
begin
  if AUuids = nil then Exit;
  for i := 0 to High(FCells) do
    if (FCells[i] <> nil) and (AUuids.IndexOf(FCells[i].CellConnUuid) >= 0) then
      FCells[i].BeginShutdown;
end;

function TClusterSshTab.HasSessionFor(const AConnUuid: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if AConnUuid = '' then Exit;
  for i := 0 to High(FCells) do
    if (FCells[i] <> nil) and (FCells[i].CellConnUuid = AConnUuid) and
       (not IsTerminalState(FCells[i].CellState)) then
      Exit(True);
end;

procedure TClusterSshTab.SetUnknownHostKeyPolicy(ADecision: TSshHostKeyDecision);
begin
  FBulkHostKeyDecision := ADecision;
  FBulkHostKeySet := True;
end;

function TClusterSshTab.UnknownHostKeyPolicy(
  out ADecision: TSshHostKeyDecision): Boolean;
begin
  Result := FBulkHostKeySet;
  ADecision := FBulkHostKeyDecision;
end;

procedure TClusterSshTab.FocusContent;
begin
  if FBar.CanFocus then
    FBar.SetFocus;
end;

procedure TClusterSshTab.CellChanged;
begin
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

procedure TClusterSshTab.CellFinished(ACell: TClusterCell);
begin
  CellChanged;
  // differe: on vient d'un evenement de la cellule, la liberer ici la tue
  if not FClosing then
    Application.QueueAsyncCall(@DeferredRemoveCell, PtrInt(ACell));
end;

procedure TClusterSshTab.DeferredRemoveCell(Data: PtrInt);
var
  i, idx, fsz: Integer;
begin
  if FClosing then Exit;
  idx := -1;
  for i := 0 to High(FCells) do
    if FCells[i] = TClusterCell(Data) then
    begin
      idx := i;
      Break;
    end;
  if idx < 0 then Exit;

  if FHandles[idx] <> nil then
  begin
    FManager.UnregisterSession(FHandles[idx]);
    FreeAndNil(FHandles[idx]);
  end;
  if FCells[idx].FTerm.Focused and FBar.CanFocus then
    FBar.SetFocus;
  FCells[idx].Free;
  Delete(FCells, idx, 1);
  Delete(FHandles, idx, 1);

  if Length(FCells) = 0 then
  begin
    Free;
    Exit;
  end;
  fsz := FontSizeForCount(Length(FCells));
  for i := 0 to High(FCells) do
    FCells[i].FTerm.SetTerminalFontSize(fsz);
  LayoutCells;
  CellChanged;
end;

procedure TClusterSshTab.GridResize(Sender: TObject);
begin
  LayoutCells;
end;

procedure TClusterSshTab.LayoutCells;
var
  n, cols, rows, i, cw, ch, x, y: Integer;
begin
  n := Length(FCells);
  if (n = 0) or (FGridHost.ClientWidth <= 0) then Exit;
  cols := 1;
  while cols * cols < n do
    Inc(cols);
  rows := (n + cols - 1) div cols;
  cw := FGridHost.ClientWidth div cols;
  ch := FGridHost.ClientHeight div rows;
  if (cw < 40) or (ch < 40) then Exit;
  for i := 0 to n - 1 do
  begin
    if FCells[i] = nil then Continue;
    x := (i mod cols) * cw;
    y := (i div cols) * ch;
    FCells[i].SetBounds(x, y, cw, ch);
    FCells[i].FLabel.SetBounds(CELL_BORDER, CELL_BORDER,
      cw - 2 * CELL_BORDER, HEADER_H);
    FCells[i].FTerm.SetBounds(CELL_BORDER, CELL_BORDER + HEADER_H,
      cw - 2 * CELL_BORDER, ch - 2 * CELL_BORDER - HEADER_H);
  end;
end;

procedure TClusterSshTab.Broadcast(const AData: RawByteString);
var
  i: Integer;
begin
  for i := 0 to High(FCells) do
    if FCells[i] <> nil then
      FCells[i].Broadcast(AData);
end;

procedure TClusterSshTab.BarKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
var
  c: Byte;
begin
  // un collage n'emet aucun evenement clavier: sans interception il reste dans
  // la barre. Ctrl+V ne diffuse donc PAS #22 ici.
  {$IFDEF DARWIN}
  if (ssMeta in Shift) and (Key = VK_V) then
  {$ELSE}
  if (ssCtrl in Shift) and (Key = VK_V) then
  {$ENDIF}
  begin
    PasteBroadcast;
    Key := 0;
    Exit;
  end;
  case Key of
    VK_RETURN:
      begin
        Broadcast(#13);
        FBar.Text := '';
        Key := 0;
      end;
    VK_BACK:
      begin
        Broadcast(#127);
      end;
    VK_TAB:
      begin
        Broadcast(#9);
        Key := 0;
      end;
    VK_ESCAPE:
      begin
        Broadcast(#27);
        Key := 0;
      end;
    VK_UP:    begin Broadcast(#27'[A'); Key := 0; end;
    VK_DOWN:  begin Broadcast(#27'[B'); Key := 0; end;
    VK_RIGHT: begin Broadcast(#27'[C'); Key := 0; end;
    VK_LEFT:  begin Broadcast(#27'[D'); Key := 0; end;
  else
    if (ssCtrl in Shift) and (Key >= Ord('A')) and (Key <= Ord('Z')) then
    begin
      c := Byte(Key) - Ord('A') + 1;
      Broadcast(AnsiChar(c));
      Key := 0;
    end;
  end;
end;

procedure TClusterSshTab.BarUtf8KeyPress(Sender: TObject;
  var UTF8Key: TUTF8Char);
begin
  if UTF8Key = '' then Exit;
  if (Length(UTF8Key) = 1) and (Ord(UTF8Key[1]) < 32) then Exit;
  Broadcast(RawByteString(UTF8Key));
end;

// Comme uTermControl.DoPasteClipboard, sans bracketed paste: octets bruts.
procedure TClusterSshTab.PasteBroadcast;
const
  PASTE_MAX = 1024 * 1024;
var
  txt: string;
  cleaned: RawByteString;
  i, n, lineCount: Integer;
begin
  txt := Clipboard.AsText;
  if txt = '' then Exit;
  if Length(txt) > PASTE_MAX then
    SetLength(txt, PASTE_MAX);
  SetLength(cleaned, Length(txt));
  n := 0;
  for i := 1 to Length(txt) do
    if txt[i] <> #0 then
    begin
      Inc(n);
      cleaned[n] := txt[i];
    end;
  SetLength(cleaned, n);
  cleaned := StringReplace(cleaned, #13#10, #13, [rfReplaceAll]);
  cleaned := StringReplace(cleaned, #10, #13, [rfReplaceAll]);
  cleaned := StringReplace(cleaned, #27'[201~', '', [rfReplaceAll]);
  if cleaned = '' then Exit;

  lineCount := 1;
  for i := 1 to Length(cleaned) do
    if cleaned[i] = #13 then
      Inc(lineCount);
  if (lineCount > 1) and
     (QuestionDlg('Paste',
       Format('Broadcast %d lines to all sessions?', [lineCount]) + LineEnding +
       'Pasting multiple commands can be dangerous.',
       mtWarning, [mrOK, 'Paste', mrCancel, 'Cancel', 'IsCancel'], 0) <> mrOK) then
    Exit;

  Broadcast(cleaned);
  FBar.SelText := StringReplace(string(cleaned), #13, ' ', [rfReplaceAll]);
end;

end.
