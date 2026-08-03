unit uSshSessionTab;

{$mode objfpc}{$H+}

// Onglet de session SSH: le terminal local, alimente par le reseau au lieu d'un
// pty. Cles d'hote lues et ecrites sur le thread UI: le modele n'est pas thread-safe.

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, Graphics,
  uTermControl, uSshTransport, uSshKnownHosts, uSessionState,
  uSessionManager, uRshDocument, uSessionTabBase, uSshTunnel, uSshTunnelConnect,
  uTreeScrollBar, uTheme;

type
  TSshSessionTab = class;

  TSshSessionHandle = class(TManagedSession)
  private
    FTab: TSshSessionTab;
  public
    constructor Create(ATab: TSshSessionTab);
    function SessionState: TRemoteSessionState; override;
    function DisplayName: string; override;
    procedure BeginShutdown; override;
  end;

  TSshSessionTab = class(TSessionTabBase)
  private
    FTerm: TRottenTerminalControl;
    FScroll: TTreeScrollBar;
    FTransport: TSshTransport;
    FKnownHosts: TSshKnownHosts;
    // Tunnel de rebond: nil si direct, libere APRES le transport.
    FTunnel: TSshTunnel;
    FTunnelBroker: TSshTunnelBroker;
    FManager: TSessionManager;
    FHandle: TSshSessionHandle;
    FDisplayName: string;
    FConnUuid: string;
    FState: TRemoteSessionState;
    FErrorMsg: string;
    FClosing: Boolean;
    // Un echec d'ETABLISSEMENT garde l'onglet ouvert avec sa raison.
    FEverConnected: Boolean;
    FUserAbort: Boolean;
    FFailedOpen: Boolean;
    // Conteneurs: aucune frappe ne part au distant.
    FReadOnly: Boolean;
    FCaptionSuffix: string;
    // Mode log: la fin du flux ne ferme pas l'onglet.
    FLogMode: Boolean;
    FDeadStream: Boolean;
    FExitCodes: array of Integer;
    FExitMsgs: array of string;

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
    procedure UpdateCaption;
    procedure DeferredClose(Data: PtrInt);
    procedure RequestClose;
    procedure ShowFailureInTerminal;
  public
    // Prend possession de AParams. ADoc sert au magasin de cles d'hote.
    constructor CreateSession(APages: TPageControl; ADoc: TRshDocument;
      AManager: TSessionManager; const ADisplayName, AConnUuid: string;
      AParams: TSshConnectParams);
    destructor Destroy; override;

    procedure Start;
    procedure SetReadOnly(AValue: Boolean);
    procedure SetLogMode(AValue: Boolean);
    procedure SetCaptionSuffix(const AValue: string);
    procedure AddExitMessage(ACode: Integer; const AMsg: string);
    procedure AttachTunnel(ATunnel: TSshTunnel; ABroker: TSshTunnelBroker);
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    function GrabThumbnail: TBitmap; override;
    function TabState: TRemoteSessionState; override;
    function TabIsDeadLog: Boolean; override;
    function TabIsFailedKept: Boolean; override;
    function TabBarCaption: string; override;
    function TabConnUuid: string; override;

    property SessionState: TRemoteSessionState read FState;
    property SessionName: string read FDisplayName;
    property ConnectionUuid: string read FConnUuid;
    property Terminal: TRottenTerminalControl read FTerm;
  end;

implementation

uses
  uHostKeyDialog;

constructor TSshSessionHandle.Create(ATab: TSshSessionTab);
begin
  inherited Create;
  FTab := ATab;
end;

function TSshSessionHandle.SessionState: TRemoteSessionState;
begin
  Result := FTab.SessionState;
end;

function TSshSessionHandle.DisplayName: string;
begin
  Result := FTab.SessionName;
end;

procedure TSshSessionHandle.BeginShutdown;
begin
  FTab.BeginShutdown;
end;

constructor TSshSessionTab.CreateSession(APages: TPageControl;
  ADoc: TRshDocument; AManager: TSessionManager;
  const ADisplayName, AConnUuid: string;
  AParams: TSshConnectParams);
begin
  inherited Create(APages);
  PageControl := APages;
  FDisplayName := ADisplayName;
  FConnUuid := AConnUuid;
  FState := rssCreated;
  FManager := AManager;
  FKnownHosts := TSshKnownHosts.Create(ADoc);

  // Barre AVANT le terminal: alRight reserve le strip, alClient prend le reste.
  FScroll := TTreeScrollBar.Create(Self);
  FScroll.Parent := Self;
  FScroll.Align := alRight;
  FScroll.Width := 12;

  FTerm := TRottenTerminalControl.Create(Self);
  FTerm.Parent := Self;
  FTerm.Align := alClient;
  FTerm.OnSendData := @TermSend;
  FTerm.OnGridResize := @TermGridResize;

  FScroll.Bind(FTerm);
  FScroll.ApplyTheme(clTermBg,
    BlendColor(clTermFg, clTermBg, 22),
    BlendColor(clTermFg, clTermBg, 42));

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

  FHandle := TSshSessionHandle.Create(Self);
  FManager.RegisterSession(FHandle);

  UpdateCaption;
end;

destructor TSshSessionTab.Destroy;
var
  cb: TNotifyEvent;
begin
  FClosing := True;
  if (FManager <> nil) and (FHandle <> nil) then
    FManager.UnregisterSession(FHandle);
  if FTransport <> nil then
  begin
    FTransport.Shutdown;
    FTransport.Free;
    FTransport := nil;
  end;
  // La fin de session a pu deposer un DeferredClose: il tirerait a vide.
  Application.RemoveAsyncCalls(Self);
  if FTunnel <> nil then
  begin
    FTunnel.Shutdown;
    FTunnel.Free;
    FTunnel := nil;
  end;
  FreeAndNil(FTunnelBroker);
  FreeAndNil(FHandle);
  FreeAndNil(FKnownHosts);
  cb := FOnDestroyed;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TSshSessionTab.Start;
begin
  FTransport.Start;
end;

procedure TSshSessionTab.AttachTunnel(ATunnel: TSshTunnel;
  ABroker: TSshTunnelBroker);
begin
  FTunnel := ATunnel;
  FTunnelBroker := ABroker;
end;

procedure TSshSessionTab.UpdateCaption;
var
  mark: string;
begin
  case FState of
    rssCreated, rssConnecting: mark := '○ ';
    rssAuthenticating: mark := '◐ ';
    rssConnected: mark := '● ';
    rssDisconnecting: mark := '◌ ';
    rssFailed: mark := '✕ ';
  else
    mark := '';
  end;
  if FCaptionSuffix = '' then
    FCaptionSuffix := 'SSH';
  Caption := mark + FDisplayName + ' — ' + FCaptionSuffix;
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

procedure TSshSessionTab.TermSend(const AData: RawByteString);
begin
  if FFailedOpen then
  begin
    RequestClose;
    Exit;
  end;
  if FReadOnly then Exit;
  if (FTransport <> nil) and (FState = rssConnected) then
    FTransport.SendData(AData);
end;

procedure TSshSessionTab.SetReadOnly(AValue: Boolean);
begin
  FReadOnly := AValue;
end;

procedure TSshSessionTab.SetLogMode(AValue: Boolean);
begin
  FLogMode := AValue;
  FReadOnly := AValue;
end;

procedure TSshSessionTab.SetCaptionSuffix(const AValue: string);
begin
  FCaptionSuffix := AValue;
  UpdateCaption;
end;

procedure TSshSessionTab.AddExitMessage(ACode: Integer; const AMsg: string);
begin
  SetLength(FExitCodes, Length(FExitCodes) + 1);
  SetLength(FExitMsgs, Length(FExitMsgs) + 1);
  FExitCodes[High(FExitCodes)] := ACode;
  FExitMsgs[High(FExitMsgs)] := AMsg;
end;

procedure TSshSessionTab.TermGridResize(ACols, ARows: Integer);
begin
  if FTransport <> nil then
    FTransport.RequestResize(ACols, ARows);
end;

procedure TSshSessionTab.TransportData(const AData: RawByteString);
var
  s: RawByteString;
begin
  // Sans PTY, `docker logs` sort des LF nus: l'emulateur descend sans revenir
  // en colonne 0, d'ou l'escalier. Passage par LF pour ne pas doubler un CR.
  if FReadOnly then
  begin
    s := StringReplace(AData, #13#10, #10, [rfReplaceAll]);
    s := StringReplace(s, #10, #13#10, [rfReplaceAll]);
    FTerm.FeedData(s);
  end
  else
    FTerm.FeedData(AData);
end;

procedure TSshSessionTab.TransportState(AState: TRemoteSessionState);
begin
  FState := AState;
  UpdateCaption;
  if AState = rssConnected then
  begin
    FEverConnected := True;
    if CanFocus then
      FTerm.SetFocus;
  end;
end;

procedure TSshSessionTab.TransportError(const AMessage: string);
begin
  FErrorMsg := AMessage;
  if (FTunnel <> nil) and (FTunnel.LastError <> '') then
    FErrorMsg := FTunnel.LastError;
end;

procedure TSshSessionTab.TransportFinished(AExitCode: Integer);
var
  i: Integer;
begin
  FState := FTransport.State;
  UpdateCaption;
  if FErrorMsg = '' then
    for i := 0 to High(FExitCodes) do
      if FExitCodes[i] = AExitCode then
      begin
        FErrorMsg := FExitMsgs[i];
        Break;
      end;
  if FErrorMsg <> '' then
  begin
    if Assigned(FOnNotice) then
      FOnNotice(Format('%s: %s', [FDisplayName, FErrorMsg]));
  end;
  if FLogMode then
  begin
    FDeadStream := True;
    UpdateCaption;
    Exit;
  end;
  if (FState = rssFailed) and (not FEverConnected) and (not FUserAbort)
     and (not FClosing) then
  begin
    FFailedOpen := True;
    ShowFailureInTerminal;
    UpdateCaption;
    Exit;
  end;
  // Differe: on est dans un evenement du transport qu'on s'apprete a liberer.
  if not FClosing then
  begin
    FClosing := True;
    Application.QueueAsyncCall(@DeferredClose, 0);
  end;
end;

procedure TSshSessionTab.DeferredClose(Data: PtrInt);
begin
  Free;
end;

procedure TSshSessionTab.BeginShutdown;
begin
  FUserAbort := True;
  if FTransport <> nil then
    FTransport.Shutdown;
end;

procedure TSshSessionTab.RequestClose;
begin
  if FClosing then Exit;
  FClosing := True;
  Application.QueueAsyncCall(@DeferredClose, 0);
end;

procedure TSshSessionTab.ShowFailureInTerminal;
var
  reason: string;
begin
  reason := FErrorMsg;
  if reason = '' then reason := 'Connection failed (no details available).';
  FTerm.FeedData(#13#10 +
    #27'[1;31m  ✕ Connection failed'#27'[0m'#13#10#13#10 +
    '  ' + reason + #13#10#13#10 +
    #27'[2m  This tab stayed open so you can read why.'#13#10 +
    '  Press any key or close the tab to dismiss.'#27'[0m'#13#10);
end;

procedure TSshSessionTab.FocusContent;
begin
  if (FTerm <> nil) and FTerm.CanFocus then
    FTerm.SetFocus;
end;

function TSshSessionTab.GrabThumbnail: TBitmap;
begin
  Result := nil;
  if FTerm <> nil then
    Result := FTerm.Snapshot;
end;

function TSshSessionTab.TabState: TRemoteSessionState;
begin
  Result := FState;
end;

function TSshSessionTab.TabIsDeadLog: Boolean;
begin
  Result := FLogMode and FDeadStream;
end;

function TSshSessionTab.TabIsFailedKept: Boolean;
begin
  Result := FFailedOpen;
end;

function TSshSessionTab.TabBarCaption: string;
begin
  Result := FDisplayName + ' — SSH';
end;

function TSshSessionTab.TabConnUuid: string;
begin
  Result := FConnUuid;
end;

function TSshSessionTab.ConfirmClose: Boolean;
begin
  if IsTerminalState(FState) then
    Exit(True);
  Result := QuestionDlg('Disconnect',
    Format('Disconnect from %s?', [FDisplayName]), mtConfirmation,
    [mrOK, 'Disconnect', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

procedure TSshSessionTab.HostKeyLookup(const AHost: string; APort: Integer;
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

procedure TSshSessionTab.HostKeyAsk(const AInfo: TSshHostKeyInfo;
  var ADecision: TSshHostKeyDecision);
begin
  if AInfo.Verdict = hkChanged then
    ADecision := AskChangedHostKey(AInfo)
  else
    ADecision := AskUnknownHostKey(AInfo);
end;

procedure TSshSessionTab.HostKeySave(const AInfo: TSshHostKeyInfo);
begin
  FKnownHosts.Remember(AInfo.Host, AInfo.Port, AInfo.KeyType,
    AInfo.Fingerprint, AInfo.Blob);
end;

end.
