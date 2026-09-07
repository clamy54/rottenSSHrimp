unit uSshCopyIdConnect;

{$mode objfpc}{$H+}

// « Copy SSH ID » et rotation de cle geree, par le transport SSH standard.
// Rotation en deux passes, ordre non negociable: poser la nouvelle ligne partout
// avec l'ANCIENNE cle, stocker, SAUVEGARDER le document, puis retirer
// l'ancienne avec la NOUVELLE. Sans la sauvegarde entre les deux, un .rsh que
// l'on n'arrive plus a ecrire garderait une cle deja revoquee partout.

interface

uses
  Classes, SysUtils, uRshDocument, uRshModel;

function CanCopySshId(AModel: TRshModel; const AConnUuid: string): Boolean;

function CopySshIdToHost(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AErr: string): Boolean;

// ASave: sauvegarde du document (celle du menu, dialogues compris). Elle est
// appelee entre les deux passes; si le document reste non sauve, la seconde
// passe est SAUTEE et le resume le dit.
function RotateManagedKey(ADoc: TRshDocument; AModel: TRshModel;
  const ACredUuid: string; ASave: TNotifyEvent; out ASummary: string;
  out AErr: string): Boolean;

implementation

uses
  Forms, Controls, StdCtrls, Dialogs,
  uSecureBytes, uSshTransport, uSshTunnel, uSshTunnelConnect, uSshConnect,
  uSshKeyGen, uAuthPrompt, uFidoPrompt, uSshSkKeyGen;

const
  // Sortie distante conservee au plus: un script bavard ou un serveur hostile
  // ne doit pas pouvoir remplir la memoire, le delai ne borne que le temps.
  COPYID_OUTPUT_MAX = 256 * 1024;

type
  TCopyIdRun = class
  public
    Output: RawByteString;
    ErrMsg: string;
    ExitCode: Integer;
    Finished: Boolean;
    Failed: Boolean;
    Overflow: Boolean;
    procedure HandleData(const AData: RawByteString);
    procedure HandleError(const AMessage: string);
    procedure HandleFinished(AExitCode: Integer);
  end;

  TCopyIdWaitDialog = class
  private
    FForm: TForm;
    FDisabled: TList;
    FCancelled: Boolean;
    procedure CancelClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor Create(const ACaption: string);
    destructor Destroy; override;
    property Cancelled: Boolean read FCancelled;
  end;

procedure TCopyIdRun.HandleData(const AData: RawByteString);
begin
  if Overflow then Exit;
  if Length(Output) + Length(AData) > COPYID_OUTPUT_MAX then
  begin
    Output := Output + Copy(AData, 1, COPYID_OUTPUT_MAX - Length(Output));
    Overflow := True;
    Exit;
  end;
  Output := Output + AData;
end;

procedure TCopyIdRun.HandleError(const AMessage: string);
begin
  if ErrMsg = '' then
    ErrMsg := AMessage;
  Failed := True;
end;

procedure TCopyIdRun.HandleFinished(AExitCode: Integer);
begin
  ExitCode := AExitCode;
  Finished := True;
end;

constructor TCopyIdWaitDialog.Create(const ACaption: string);
var
  lbl: TLabel;
  btn: TButton;
begin
  inherited Create;
  FCancelled := False;
  FForm := TForm.CreateNew(nil);
  FForm.Caption := 'Copy SSH ID';
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
  lbl.Caption := ACaption;

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
  // Non modale (la boucle est a l'appelant) mais les autres fenetres doivent
  // dormir comme sous ShowModal: ProcessMessages livrait leurs clics, et une
  // seconde rotation pouvait s'imbriquer dans la premiere.
  FDisabled := Screen.DisableForms(FForm);
end;

destructor TCopyIdWaitDialog.Destroy;
begin
  Screen.EnableForms(FDisabled);
  FForm.Free;
  inherited Destroy;
end;

procedure TCopyIdWaitDialog.CancelClick(Sender: TObject);
begin
  FCancelled := True;
end;

procedure TCopyIdWaitDialog.FormCloseQuery(Sender: TObject;
  var CanClose: Boolean);
begin
  FCancelled := True;
  CanClose := False;
end;

function ResolvedCredUuid(AModel: TRshModel; ANode: TRshNode): string;
var
  srcFolder: string;
begin
  if ANode.InheritCredential then
    Result := AModel.ResolveFolderCredential(ANode.ParentUuid,
      ANode.Protocol, srcFolder)
  else
    Result := ANode.CredentialUuid;
end;

function CanCopySshId(AModel: TRshModel; const AConnUuid: string): Boolean;
var
  node: TRshNode;
  cred: TRshCredential;
  credUuid: string;
begin
  Result := False;
  if (AModel = nil) or (AConnUuid = '') then Exit;
  node := nil;
  cred := nil;
  try
    try
      node := AModel.GetNode(AConnUuid);
      if (node = nil) or (node.Protocol <> rpSsh) then Exit;
      credUuid := ResolvedCredUuid(AModel, node);
      if credUuid = '' then Exit;
      cred := AModel.GetCredential(credUuid);
      Result := IsManagedKeyType(cred.AuthType) and (cred.PublicKey <> '') and
        cred.HasPrivateKey;
    except
      on Exception do
        Result := False;
    end;
  finally
    cred.Free;
    node.Free;
  end;
end;

function ShellSingleQuote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''\''''', [rfReplaceAll]) + '''';
end;

// Idempotent: grep -qxF = litteral, ligne entiere; le touch evite un grep a vide.
function InstallCommand(const ALine: string): string;
var
  esc: string;
begin
  esc := ShellSingleQuote(ALine);
  Result :=
    'umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && ' +
    'touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && ' +
    '{ grep -qxF ' + esc + ' ~/.ssh/authorized_keys || ' +
    'printf ''%s\n'' ' + esc + ' >> ~/.ssh/authorized_keys; }';
end;

// rc <= 1 ET temporaire non vide: sinon un disque plein tronque authorized_keys.
// La branche d'abandon sort en 1: son rm -f reussissait et rendait 0, la
// rotation annoncait alors une revocation qui n'avait pas eu lieu. Et on relit
// le fichier a la fin: la ligne doit avoir DISPARU, pas seulement ete filtree.
function RevokeCommand(const AOldLine: string): string;
var
  esc: string;
begin
  esc := ShellSingleQuote(AOldLine);
  Result :=
    'umask 077; grep -vxF ' + esc +
    ' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp; rc=$?; ' +
    'if [ "$rc" -le 1 ] && [ -s ~/.ssh/authorized_keys.tmp ]; then ' +
    'mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && ' +
    'chmod 600 ~/.ssh/authorized_keys && ' +
    '! grep -qxF ' + esc + ' ~/.ssh/authorized_keys; ' +
    'else rm -f ~/.ssh/authorized_keys.tmp; exit 1; fi';
end;

// Prend possession d'APassword. True = la commande a tourne, exit code compris.
function RunSshExecOnHost(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid, ACommand, AWaitCaption: string; APassword: TSecureBytes;
  out AExitCode: Integer; out AOutput, AErr: string;
  out ACancelled: Boolean): Boolean;
var
  prompts: TFidoSessionPrompts;
  params: TSshConnectParams;
  run: TCopyIdRun;
  broker, tunBroker: TSshTunnelBroker;
  tun: TSshTunnel;
  tr: TSshTransport;
  dlg: TCopyIdWaitDialog;
  displayName, jumpUuid: string;
  localPort, waited: Integer;
begin
  Result := False;
  AExitCode := -1;
  AOutput := '';
  AErr := '';
  ACancelled := False;
  params := nil; run := nil; broker := nil; tunBroker := nil;
  tun := nil; tr := nil;
  try
    if not BuildSshConnectParams(ADoc, AModel, AConnUuid, params,
      displayName, AErr) then
    begin
      APassword.Free;
      Exit;
    end;
    if APassword <> nil then
    begin
      FreeAndNil(params.PrivateKey);
      params.AuthKind := sakPassword;
      params.Password := APassword;
      APassword := nil;
    end;
    params.ExecCommand := ACommand;
    params.RequestPty := False;

    jumpUuid := AModel.GetJumpVia(AConnUuid);
    if jumpUuid <> '' then
    begin
      if not EstablishJumpTunnel(ADoc, AModel, jumpUuid,
        params.Host, params.Port, tun, tunBroker, localPort, AErr) then
      begin
        ACancelled := AErr = '';
        Exit;
      end;
      params.ConnectHost := '127.0.0.1';
      params.ConnectPort := localPort;
    end;

    broker := TSshTunnelBroker.Create(ADoc);
    run := TCopyIdRun.Create;
    tr := TSshTransport.Create(params);
    params := nil;
    tr.OnHostKeyLookup := @broker.HostKeyLookup;
    tr.OnHostKey := @broker.HostKeyAsk;
    tr.OnHostKeySave := @broker.HostKeySave;
    tr.OnData := @run.HandleData;
    tr.OnError := @run.HandleError;
    tr.OnFinished := @run.HandleFinished;
    prompts := TFidoSessionPrompts.Create(nil);
    tr.OnSkNotice := @prompts.SkNotice;
    tr.OnSkPin := @prompts.SkPin;
    tr.Start;

    // sans pompe a messages, les dialogues de cle d'hote (Synchronize) pendent
    dlg := TCopyIdWaitDialog.Create(AWaitCaption);
    Screen.Cursor := crHourGlass;
    try
      waited := 0;
      while True do
      begin
        Application.ProcessMessages;
        if run.Finished or run.Failed then Break;
        if run.Overflow then
        begin
          tr.Shutdown;
          AErr := Format('The remote command produced more than %d KiB of ' +
            'output: aborted.', [COPYID_OUTPUT_MAX div 1024]);
          Break;
        end;
        if dlg.Cancelled or prompts.Cancelled then
        begin
          ACancelled := True;
          tr.Shutdown;
          Break;
        end;
        Sleep(15);
        Inc(waited, 15);
        if waited > 12 * 60 * 1000 then
        begin
          tr.Shutdown;
          AErr := 'Timed out.';
          Break;
        end;
      end;
      Application.ProcessMessages;
    finally
      Screen.Cursor := crDefault;
      dlg.Free;
      tr.OnSkNotice := nil;
      tr.OnSkPin := nil;
      prompts.Free;
    end;

    if ACancelled then
      Exit;
    if run.Overflow then
      Exit;
    if run.Failed then
    begin
      if AErr = '' then AErr := run.ErrMsg;
      Exit;
    end;
    if not run.Finished then
      Exit;
    AExitCode := run.ExitCode;
    AOutput := Trim(string(run.Output));
    Result := True;
  finally
    if tr <> nil then
    begin
      tr.Shutdown;
      tr.Free;
    end;
    broker.Free;
    run.Free;
    if tun <> nil then
    begin
      tun.Shutdown;
      tun.Free;
    end;
    tunBroker.Free;
    params.Free;
  end;
end;

function CopySshIdToHost(ADoc: TRshDocument; AModel: TRshModel;
  const AConnUuid: string; out AErr: string): Boolean;
var
  node: TRshNode;
  cred: TRshCredential;
  pw: TSecureBytes;
  credUuid, user, dom, displayName, output: string;
  exitCode: Integer;
  cancelled: Boolean;
begin
  Result := False;
  AErr := '';
  node := nil; cred := nil; pw := nil;
  try
    try
      node := AModel.GetNode(AConnUuid);
      credUuid := ResolvedCredUuid(AModel, node);
      if credUuid = '' then
      begin
        AErr := 'This host has no credential to copy a key from.';
        Exit;
      end;
      cred := AModel.GetCredential(credUuid);
    except
      on E: Exception do
      begin
        AErr := E.Message;
        Exit;
      end;
    end;
    if (not IsManagedKeyType(cred.AuthType)) or (cred.PublicKey = '') then
    begin
      AErr := 'This host does not use a managed SSH key credential ' +
        '(or no key pair has been generated yet).';
      Exit;
    end;

    // mot de passe du compte: la cle geree n'est justement pas encore la-bas
    user := cred.Username;
    dom := '';
    displayName := node.DisplayName;
    if not AskLogin('Copy SSH ID',
      Format('Install the public key for %s@%s.' + LineEnding +
        'Enter the account password:', [cred.Username, node.Hostname]),
      False, user, dom, pw, False, 'Install Key') then
    begin
      AErr := '';
      Exit;
    end;

    if not RunSshExecOnHost(ADoc, AModel, AConnUuid,
      InstallCommand(cred.PublicKey),
      Format('Installing the SSH key on %s…', [displayName]),
      pw, exitCode, output, AErr, cancelled) then
    begin
      pw := nil;
      Exit;
    end;
    pw := nil;
    if exitCode <> 0 then
    begin
      AErr := Format('The install command failed on the host (exit %d).',
        [exitCode]);
      if output <> '' then
        AErr := AErr + LineEnding + output;
      Exit;
    end;
    Result := True;
  finally
    pw.Free;
    cred.Free;
    node.Free;
  end;
end;

function RotateManagedKey(ADoc: TRshDocument; AModel: TRshModel;
  const ACredUuid: string; ASave: TNotifyEvent; out ASummary: string;
  out AErr: string): Boolean;
var
  cred: TRshCredential;
  hosts: TStringArray;
  names: array of string;
  node: TRshNode;
  newPem: TSecureBytes;
  oldLine, newLine, output, hostErr, algName, enrollErr: string;
  oldPem: TSecureBytes;
  skFlags: Byte;
  wantUv: Boolean;
  i, exitCode: Integer;
  cancelled: Boolean;
  warnings: string;
begin
  Result := False;
  ASummary := '';
  AErr := '';
  cred := nil;
  newPem := nil;
  try
    try
      cred := AModel.GetCredential(ACredUuid);
    except
      on E: Exception do
      begin
        AErr := E.Message;
        Exit;
      end;
    end;
    if (not IsManagedKeyType(cred.AuthType)) or (cred.PublicKey = '') or
       (not cred.HasPrivateKey) then
    begin
      AErr := 'This credential has no generated key pair to rotate.';
      Exit;
    end;
    oldLine := cred.PublicKey;

    hosts := AModel.CredentialSshHosts(ACredUuid);
    SetLength(names, Length(hosts));
    for i := 0 to High(hosts) do
    begin
      node := AModel.GetNode(hosts[i]);
      try
        names[i] := node.DisplayName;
      finally
        node.Free;
      end;
    end;

    // Une cle de securite ne se « regenere » pas: on en enrole une autre sur le
    // meme token. L'utilisateur doit y poser le doigt avant que la premiere
    // passe ne commence.
    if cred.AuthType = atFidoKey then
    begin
      // La nouvelle cle reprend l'exigence de PIN de l'ancienne: le drapeau
      // vit dans le key handle, on le relit plutot que de le deviner -- une
      // rotation qui retirait le PIN en silence affaiblissait ce que
      // l'utilisateur avait choisi.
      // Et si on ne peut pas la relire, on s'arrete: deviner « sans PIN »
      // serait choisir le reglage le plus faible a la place de l'utilisateur.
      if not AModel.GetSecret(ACredUuid, FIELD_CRED_PRIVATE_KEY, oldPem) then
      begin
        AErr := 'Rotation aborted: the current security-key credential ' +
          'cannot be read, so its PIN requirement cannot be carried over.' +
          LineEnding + 'The current key is unchanged.';
        Exit;
      end;
      try
        if not DecodeSkPrivateFlags(oldPem.Data, oldPem.Len, skFlags) then
        begin
          AErr := 'Rotation aborted: the stored key is not a readable FIDO2 ' +
            'key, so its PIN requirement cannot be carried over.' +
            LineEnding + 'The current key is unchanged.';
          Exit;
        end;
      finally
        oldPem.Free;
      end;
      wantUv := (skFlags and SSH_SK_USER_VERIFICATION_REQD) <> 0;
      if not EnrollFidoKeyWithDialog(nil, cred.Username, wantUv,
        newPem, newLine, algName, enrollErr) then
      begin
        if enrollErr = '' then
          AErr := 'Rotation cancelled — the current key is unchanged.'
        else
          AErr := 'Rotation aborted: ' + enrollErr + LineEnding +
            'The current key is unchanged and still works on every host.';
        Exit;
      end;
    end
    else
      GenerateEd25519KeyPair(cred.Username + '@rottensshrimp', newPem, newLine);

    // ---- Passe 1: nouvelle ligne partout, sous l'ANCIENNE cle ----
    for i := 0 to High(hosts) do
    begin
      if not RunSshExecOnHost(ADoc, AModel, hosts[i],
        InstallCommand(newLine),
        Format('Rotating: installing the new key on %s (%d/%d)…',
          [names[i], i + 1, Length(hosts)]),
        nil, exitCode, output, hostErr, cancelled) then
      begin
        if cancelled then
          AErr := 'Rotation cancelled — the current key pair is unchanged.'
        else
          AErr := Format('Rotation aborted at %s: %s' + LineEnding +
            'The current key pair is unchanged and still works on every host.',
            [names[i], hostErr]);
        Exit;
      end;
      if exitCode <> 0 then
      begin
        AErr := Format('Rotation aborted: the install command failed on %s' +
          ' (exit %d).', [names[i], exitCode]);
        if output <> '' then
          AErr := AErr + LineEnding + output;
        AErr := AErr + LineEnding +
          'The current key pair is unchanged and still works on every host.';
        Exit;
      end;
    end;

    // ---- Bascule: stockage rate = passe 2 sautee, ancienne paire active ----
    try
      AModel.SetManagedKeyPair(ACredUuid, newPem, newLine);
    except
      on E: Exception do
      begin
        AErr := 'The new key was installed on every host but could not be ' +
          'stored: ' + E.Message + LineEnding +
          'The current key pair is unchanged and still works everywhere.';
        Exit;
      end;
    end;

    // ---- Sauvegarde du .rsh AVANT de revoquer quoi que ce soit ----
    // La nouvelle paire ne vit que dans la copie de travail. Revoquer d'abord
    // et echouer a sauver ensuite laissait le fichier principal avec une cle
    // morte partout: on s'arrete ici, les deux cles restent valables.
    if Length(hosts) > 0 then
    begin
      if Assigned(ASave) then
        ASave(nil);
      if ADoc.Dirty or (ADoc.SourcePath = '') then
      begin
        ASummary := Format('The new key pair was installed on %d host(s) ' +
          'and stored in the working copy, but the document has NOT been ' +
          'saved.', [Length(hosts)]) + LineEnding + LineEnding +
          'The old key was deliberately left in place on every host: both ' +
          'keys work until the document is saved. Save it, then remove the ' +
          'old key lines by hand or rotate again.';
        Result := True;
        Exit;
      end;
    end;

    // ---- Passe 2: retirer l'ancienne ligne, sous la NOUVELLE ----
    warnings := '';
    for i := 0 to High(hosts) do
    begin
      if not RunSshExecOnHost(ADoc, AModel, hosts[i],
        RevokeCommand(oldLine),
        Format('Rotating: removing the old key on %s (%d/%d)…',
          [names[i], i + 1, Length(hosts)]),
        nil, exitCode, output, hostErr, cancelled) then
      begin
        if cancelled then
        begin
          warnings := warnings + Format(
            '- %s: old key line left in place (cancelled).', [names[i]]) +
            LineEnding;
          Break;
        end;
        warnings := warnings + Format('- %s: old key line left in place (%s).',
          [names[i], hostErr]) + LineEnding;
        Continue;
      end;
      if exitCode <> 0 then
        warnings := warnings + Format(
          '- %s: old key line left in place (exit %d).',
          [names[i], exitCode]) + LineEnding;
    end;

    if Length(hosts) = 0 then
      ASummary := 'A new key pair was generated. No SSH host references ' +
        'this credential, so nothing was pushed.'
    else
      ASummary := Format('The key pair was rotated and installed on %d ' +
        'host(s). Old key removed everywhere it could be.', [Length(hosts)]);
    if warnings <> '' then
      ASummary := ASummary + LineEnding + LineEnding +
        'Warnings:' + LineEnding + TrimRight(warnings) + LineEnding +
        'This document no longer holds the old private key, but any earlier ' +
        'backup or copy of it still does: remove those stale lines by hand.';
    Result := True;
  finally
    newPem.Free;
    cred.Free;
  end;
end;

end.
