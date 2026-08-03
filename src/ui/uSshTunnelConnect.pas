unit uSshTunnelConnect;

{$mode objfpc}{$H+}

// Tunnel SSH « via » un jump host, commun aux flux SSH/VNC/RDP. La cle d'hote de
// la passerelle passe par le MEME magasin TOFU. Tunnel et courtier reviennent a
// l'appelant, qui les confie a l'onglet pour la duree de la session.

interface

uses
  Classes, SysUtils, Forms, Controls,
  uRshDocument, uRshModel, uSshKnownHosts, uSshTransport, uSshTunnel;

type
  TSshTunnelBroker = class
  private
    FKnownHosts: TSshKnownHosts;
  public
    constructor Create(ADoc: TRshDocument);
    destructor Destroy; override;
    procedure HostKeyLookup(const AHost: string; APort: Integer;
      const AKeyType, AFingerprint: string;
      out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
    procedure HostKeyAsk(const AInfo: TSshHostKeyInfo;
      var ADecision: TSshHostKeyDecision);
    procedure HostKeySave(const AInfo: TSshHostKeyInfo);
  end;

// Thread UI obligatoire: pompe les messages. AErr vide = annulation.
function EstablishJumpTunnel(ADoc: TRshDocument; AModel: TRshModel;
  const AJumpUuid, ATargetHost: string; ATargetPort: Integer;
  out ATunnel: TSshTunnel; out ABroker: TSshTunnelBroker;
  out ALocalPort: Integer; out AErr: string): Boolean;

implementation

uses
  StdCtrls, uHostKeyDialog, uSshConnect;

type
  TTunnelWaitDialog = class
  private
    FForm: TForm;
    FCancelled: Boolean;
    procedure CancelClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor Create(const AGatewayName: string);
    destructor Destroy; override;
    property Cancelled: Boolean read FCancelled;
  end;

constructor TTunnelWaitDialog.Create(const AGatewayName: string);
var
  lbl: TLabel;
  btn: TButton;
begin
  inherited Create;
  FCancelled := False;
  FForm := TForm.CreateNew(nil);
  FForm.Caption := 'Opening Tunnel';
  FForm.Position := poScreenCenter;
  FForm.BorderStyle := bsDialog;
  FForm.Width := 380;
  FForm.Height := 130;
  FForm.OnCloseQuery := @FormCloseQuery;

  lbl := TLabel.Create(FForm);
  lbl.Parent := FForm;
  lbl.Left := 16;
  lbl.Top := 18;
  lbl.Width := FForm.ClientWidth - 32;
  lbl.WordWrap := True;
  lbl.AutoSize := False;
  lbl.Height := 40;
  lbl.Caption := Format('Connecting to jump host %s…', [AGatewayName]);

  btn := TButton.Create(FForm);
  btn.Parent := FForm;
  btn.Caption := 'Cancel';
  btn.Width := 90;
  btn.Height := 28;
  btn.Left := FForm.ClientWidth - btn.Width - 16;
  btn.Top := FForm.ClientHeight - btn.Height - 14;
  btn.Anchors := [akRight, akBottom];
  btn.Cancel := True;
  btn.OnClick := @CancelClick;

  FForm.Show;
end;

destructor TTunnelWaitDialog.Destroy;
begin
  FForm.Free;
  inherited Destroy;
end;

procedure TTunnelWaitDialog.CancelClick(Sender: TObject);
begin
  FCancelled := True;
end;

procedure TTunnelWaitDialog.FormCloseQuery(Sender: TObject;
  var CanClose: Boolean);
begin
  // fermer = annuler, sans fermer: la boucle d'attente detient encore FForm
  FCancelled := True;
  CanClose := False;
end;

constructor TSshTunnelBroker.Create(ADoc: TRshDocument);
begin
  inherited Create;
  FKnownHosts := TSshKnownHosts.Create(ADoc);
end;

destructor TSshTunnelBroker.Destroy;
begin
  FKnownHosts.Free;
  inherited Destroy;
end;

procedure TSshTunnelBroker.HostKeyLookup(const AHost: string; APort: Integer;
  const AKeyType, AFingerprint: string;
  out AVerdict: TSshHostKeyVerdictKind; out AKnownFingerprint: string);
var
  entry: TKnownHostEntry;
begin
  AVerdict := hkUnknown;
  AKnownFingerprint := '';
  case FKnownHosts.Verify(AHost, APort, AKeyType, AFingerprint, entry) of
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

procedure TSshTunnelBroker.HostKeyAsk(const AInfo: TSshHostKeyInfo;
  var ADecision: TSshHostKeyDecision);
begin
  if AInfo.Verdict = hkChanged then
    ADecision := AskChangedHostKey(AInfo)
  else
    ADecision := AskUnknownHostKey(AInfo);
end;

procedure TSshTunnelBroker.HostKeySave(const AInfo: TSshHostKeyInfo);
begin
  FKnownHosts.Remember(AInfo.Host, AInfo.Port, AInfo.KeyType,
    AInfo.Fingerprint, AInfo.Blob);
end;

function EstablishJumpTunnel(ADoc: TRshDocument; AModel: TRshModel;
  const AJumpUuid, ATargetHost: string; ATargetPort: Integer;
  out ATunnel: TSshTunnel; out ABroker: TSshTunnelBroker;
  out ALocalPort: Integer; out AErr: string): Boolean;
var
  gwParams: TSshConnectParams;
  gwName: string;
  tun: TSshTunnel;
  broker: TSshTunnelBroker;
  waited: Integer;
  dlg: TTunnelWaitDialog;
  cancelled: Boolean;
begin
  Result := False;
  ATunnel := nil;
  ABroker := nil;
  ALocalPort := 0;
  AErr := '';

  // Un seul saut: une chaine A -> B -> C sauterait le premier maillon en silence.
  if AModel.GetJumpVia(AJumpUuid) <> '' then
  begin
    AErr := 'Multi-hop jump chains are not supported: the jump host has ' +
      'a jump host of its own.';
    Exit;
  end;

  if not BuildSshConnectParams(ADoc, AModel, AJumpUuid, gwParams, gwName,
    AErr) then
    Exit;

  broker := TSshTunnelBroker.Create(ADoc);
  tun := TSshTunnel.Create(gwParams, ATargetHost, ATargetPort);
  gwParams := nil;   // possede par le tunnel
  tun.OnHostKeyLookup := @broker.HostKeyLookup;
  tun.OnHostKey := @broker.HostKeyAsk;
  tun.OnHostKeySave := @broker.HostKeySave;
  tun.Start;

  // sans pompe a messages, les dialogues (Synchronize) ne s'affichent pas
  cancelled := False;
  dlg := TTunnelWaitDialog.Create(gwName);
  Screen.Cursor := crHourGlass;
  try
    waited := 0;
    while True do
    begin
      Application.ProcessMessages;
      if tun.LocalPort > 0 then Break;
      if tun.LastError <> '' then Break;
      // Shutdown interrompt DNS/TCP sans attendre le timeout de la passerelle
      if dlg.Cancelled then
      begin
        cancelled := True;
        tun.Shutdown;
        Break;
      end;
      Sleep(15);
      Inc(waited, 15);
      if waited > 12 * 60 * 1000 then
      begin
        tun.Shutdown;
        AErr := 'Tunnel: timed out opening the jump host connection.';
        Break;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
    dlg.Free;   // apres le Shutdown, jamais avant
  end;

  if tun.LocalPort > 0 then
  begin
    ATunnel := tun;
    ABroker := broker;
    ALocalPort := tun.LocalPort;
    Result := True;
  end
  else
  begin
    // sur annulation AErr reste vide: pas l'erreur du tunnel avorte
    if (not cancelled) and (AErr = '') then
      AErr := tun.LastError;
    tun.Shutdown;
    tun.Free;      // joint le thread
    broker.Free;
  end;
end;

end.
