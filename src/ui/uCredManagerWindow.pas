unit uCredManagerWindow;

{$mode objfpc}{$H+}

// Credential Manager: les credentials PARTAGES (managed=1) et eux seuls.
// Controles NATIFS clairs: sous Cocoa, un theme sombre les rend illisibles.

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, Buttons, Graphics, Dialogs,
  LCLType, uRshDocument, uRshModel;

procedure ShowCredentialManager(AOwner: TCustomForm; ADoc: TRshDocument;
  AModel: TRshModel; ASaveProc: TNotifyEvent);

implementation

uses
  Clipbrd, uSecureBytes, uCryptoPolicy, uSshKeyGen, uSshCopyIdConnect,
  uNodeDialogs;

const
  MAX_KEY_BYTES = 512 * 1024;
  ROW_H = 46;

type
  TCredManagerForm = class(TForm)
  private
    FDoc: TRshDocument;
    FModel: TRshModel;
    FSaveProc: TNotifyEvent;
    FList: TListBox;
    FCreds: TRshCredentialList;
    FBtnNew, FBtnEdit, FBtnDup, FBtnRotate, FBtnDelete: TButton;
    FBusy: Boolean;
    procedure PersistAndReload(const APreferUuid: string = '');
    procedure Reload(const APreferUuid: string = '');
    procedure ListDrawItem(Control: TWinControl; Index: Integer;
      ARect: TRect; State: TOwnerDrawState);
    procedure ListDblClick(Sender: TObject);
    procedure ListSelect(Sender: TObject; User: Boolean);
    function SelectedUuid: string;
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure DupClick(Sender: TObject);
    procedure RotateClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure SyncButtons;
  public
    constructor CreateFor(AOwner: TComponent; ADoc: TRshDocument;
      AModel: TRshModel; ASaveProc: TNotifyEvent);
    destructor Destroy; override;
  end;

  TCredEditForm = class(TForm)
  private
    FModel: TRshModel;
    FUuid: string;          // '' = creation
    FNameEdit, FUserEdit, FDomainEdit, FPassEdit, FKeyEdit, FPhraseEdit: TEdit;
    FPubEdit: TEdit;
    FAuthCombo: TComboBox;
    FPassEye, FKeyBrowse, FPubCopy: TSpeedButton;
    FLblUser, FLblDomain, FLblPass, FLblKey, FLblPhrase,
      FLblPub, FLblPubHint: TLabel;
    FHasStoredKey: Boolean;
    FPublicKey: string;
    procedure AuthChanged(Sender: TObject);
    procedure EyeClick(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure CopyPubClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure UpdateRows;
  public
    constructor CreateFor(AOwner: TComponent; AModel: TRshModel;
      const AUuid: string);
    destructor Destroy; override;
  end;

{ helpers de secret (dupliques de uNodeDialogs, prives la-bas) }

function TakeSecret(AEdit: TEdit): TSecureBytes;
var
  raw: RawByteString;
begin
  Result := nil;
  raw := RawByteString(AEdit.Text);
  if raw = '' then Exit;
  try
    Result := TSecureBytes.CreateFrom(raw[1], Length(raw));
  finally
    FillChar(raw[1], Length(raw), 0);
    raw := '';
  end;
end;

// ecrase le tampon avant de vider: le champ a porte du clair
procedure WipeEdit(AEdit: TEdit);
begin
  if AEdit = nil then Exit;
  AEdit.Text := StringOfChar('*', Length(AEdit.Text));
  AEdit.Text := '';
end;

function LoadKeyFile(const APath: string; out AKey: TSecureBytes;
  out AErr: string): Boolean;
var
  fs: TFileStream;
  tmp: TBytes;
  n: Int64;
begin
  Result := False; AKey := nil; AErr := '';
  if not FileExists(APath) then
  begin AErr := 'Key file not found.'; Exit; end;
  fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  try
    // taille lue UNE FOIS: en fmShareDenyNone, la relire faisait deborder tmp
    n := fs.Size;
    if (n = 0) or (n > MAX_KEY_BYTES) then
    begin AErr := 'Invalid private key file (empty or too large).'; Exit; end;
    SetLength(tmp, n);
    fs.ReadBuffer(tmp[0], n);
    try
      AKey := TSecureBytes.CreateFrom(tmp[0], Length(tmp));
      Result := True;
    finally
      FillChar(tmp[0], Length(tmp), 0);
    end;
  finally
    fs.Free;
  end;
end;

function MakeLabel(AParent: TWinControl; const ACaption: string;
  ALeft, ATop: Integer): TLabel;
begin
  Result := TLabel.Create(AParent);
  Result.Parent := AParent;
  Result.Left := ALeft;
  Result.Top := ATop;
  Result.Caption := ACaption;
end;

function MakeEdit(AParent: TWinControl; ATop, AWidth: Integer;
  APassword: Boolean): TEdit;
begin
  Result := TEdit.Create(AParent);
  Result.Parent := AParent;
  Result.Left := 20;
  Result.Top := ATop;
  Result.Width := AWidth;
  Result.Anchors := [akLeft, akTop, akRight];
  if APassword then Result.PasswordChar := '*';
end;

{ TCredEditForm }

constructor TCredEditForm.CreateFor(AOwner: TComponent; AModel: TRshModel;
  const AUuid: string);
var
  cur: TRshCredential;
  back: TSecureBytes;
  s: string;
  fullW, authY, btnY: Integer;
begin
  inherited CreateNew(AOwner);
  FModel := AModel;
  FUuid := AUuid;
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  // Cocoa: ClientWidth est fiable des la creation, ClientHeight non
  ClientWidth := 440;
  if AUuid = '' then Caption := 'New Managed Credential'
  else Caption := 'Edit Managed Credential';
  fullW := ClientWidth - 40;

  MakeLabel(Self, 'Name', 20, 12);
  FNameEdit := MakeEdit(Self, 30, fullW, False);

  MakeLabel(Self, 'Authentication', 20, 62);
  FAuthCombo := TComboBox.Create(Self);
  FAuthCombo.Parent := Self;
  FAuthCombo.Left := 20;
  FAuthCombo.Top := 80;
  FAuthCombo.Width := fullW;
  FAuthCombo.Anchors := [akLeft, akTop, akRight];
  FAuthCombo.Style := csDropDownList;
  FAuthCombo.Items.Add('Password');
  FAuthCombo.Items.Add('Existing private key');
  FAuthCombo.Items.Add('Managed SSH key (Ed25519)');
  FAuthCombo.OnChange := @AuthChanged;

  FLblUser := MakeLabel(Self, 'Username (optional)', 20, 116);
  FUserEdit := MakeEdit(Self, 134, fullW, False);

  FLblDomain := MakeLabel(Self, 'Domain (optional, RDP)', 20, 170);
  FDomainEdit := MakeEdit(Self, 188, fullW, False);

  authY := 224;
  FLblPass := MakeLabel(Self, 'Password', 20, authY);
  FPassEdit := MakeEdit(Self, authY + 18, fullW - 30, True);
  FPassEye := TSpeedButton.Create(Self);
  FPassEye.Parent := Self;
  FPassEye.SetBounds(ClientWidth - 20 - 24, authY + 17, 24, 24);
  FPassEye.Anchors := [akTop, akRight];
  FPassEye.Flat := True;
  FPassEye.OnClick := @EyeClick;
  MakeEyeGlyph(FPassEye.Glyph, False);

  FLblKey := MakeLabel(Self, 'Private key file', 20, authY);
  FKeyEdit := TEdit.Create(Self);
  FKeyEdit.Parent := Self;
  FKeyEdit.Left := 20;
  FKeyEdit.Top := authY + 18;
  FKeyEdit.Width := fullW - 92;
  FKeyEdit.Anchors := [akLeft, akTop, akRight];
  FKeyBrowse := TSpeedButton.Create(Self);
  FKeyBrowse.Parent := Self;
  FKeyBrowse.Caption := 'Browse…';
  FKeyBrowse.SetBounds(ClientWidth - 20 - 84, authY + 17, 84, 26);
  FKeyBrowse.Anchors := [akTop, akRight];
  FKeyBrowse.OnClick := @BrowseClick;
  FLblPhrase := MakeLabel(Self, 'Key passphrase (optional)', 20, authY + 52);
  FPhraseEdit := MakeEdit(Self, authY + 70, fullW, True);

  // seule la PUBLIQUE s'affiche et se copie; la privee reste scellee
  FLblPub := MakeLabel(Self, 'Public key', 20, authY);
  FPubEdit := TEdit.Create(Self);
  FPubEdit.Parent := Self;
  FPubEdit.Left := 20;
  FPubEdit.Top := authY + 18;
  FPubEdit.Width := fullW - 72;
  FPubEdit.Anchors := [akLeft, akTop, akRight];
  FPubEdit.ReadOnly := True;
  FPubCopy := TSpeedButton.Create(Self);
  FPubCopy.Parent := Self;
  FPubCopy.Caption := 'Copy';
  FPubCopy.SetBounds(ClientWidth - 20 - 64, authY + 17, 64, 26);
  FPubCopy.Anchors := [akTop, akRight];
  FPubCopy.OnClick := @CopyPubClick;
  FLblPubHint := MakeLabel(Self, '', 20, authY + 52);

  btnY := authY + 70 + 26 + 16;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Cancel';
    ModalResult := mrCancel;
    Cancel := True;
    SetBounds(20 + fullW - 96 - 10 - 96, btnY, 96, 30);
  end;
  with TButton.Create(Self) do
  begin
    Parent := Self;
    Caption := 'Save';
    Default := True;
    SetBounds(20 + fullW - 96, btnY, 96, 30);
    OnClick := @OkClick;
  end;
  ClientHeight := btnY + 30 + 16;

  FAuthCombo.ItemIndex := 0;
  if AUuid <> '' then
  begin
    cur := FModel.GetCredential(AUuid);
    try
      FNameEdit.Text := cur.DisplayName;
      FUserEdit.Text := cur.Username;
      FDomainEdit.Text := cur.DomainName;
      FKeyEdit.Text := cur.KeyPathHint;
      FHasStoredKey := cur.HasPrivateKey;
      FPublicKey := cur.PublicKey;
      if cur.AuthType = atSshKey then FAuthCombo.ItemIndex := 1
      else if cur.AuthType = atManagedKey then FAuthCombo.ItemIndex := 2;
      if cur.HasPassword and
         FModel.GetSecret(AUuid, FIELD_CRED_PASSWORD, back) then
        try
          SetString(s, PAnsiChar(back.Data), back.Len);
          FPassEdit.Text := s;
        finally
          back.Free;
        end;
    finally
      cur.Free;
    end;
  end;
  UpdateRows;
end;

procedure TCredEditForm.UpdateRows;
var
  isKey, isManaged: Boolean;
begin
  isKey := FAuthCombo.ItemIndex = 1;
  isManaged := FAuthCombo.ItemIndex = 2;
  FLblPass.Visible := not (isKey or isManaged);
  FPassEdit.Visible := not (isKey or isManaged);
  FPassEye.Visible := not (isKey or isManaged);
  FLblKey.Visible := isKey;
  FKeyEdit.Visible := isKey;
  FKeyBrowse.Visible := isKey;
  FLblPhrase.Visible := isKey;
  FPhraseEdit.Visible := isKey;
  FLblPub.Visible := isManaged;
  FPubEdit.Visible := isManaged;
  FPubCopy.Visible := isManaged;
  FLblPubHint.Visible := isManaged;
  if isManaged then
  begin
    FPubEdit.Text := FPublicKey;
    FPubCopy.Enabled := FPublicKey <> '';
    if FPublicKey = '' then
      FLblPubHint.Caption := 'A new Ed25519 key pair will be generated on save.'
    else
      FLblPubHint.Caption := 'The private key stays sealed in the document.';
  end;
  if isManaged then FLblUser.Caption := 'Username'
  else FLblUser.Caption := 'Username (optional)';
  FLblDomain.Visible := not (isKey or isManaged);
  FDomainEdit.Visible := not (isKey or isManaged);
end;

procedure TCredEditForm.AuthChanged(Sender: TObject);
begin
  UpdateRows;
end;

procedure TCredEditForm.EyeClick(Sender: TObject);
begin
  if FPassEdit.PasswordChar = #0 then
  begin
    FPassEdit.PasswordChar := '*';
    MakeEyeGlyph(FPassEye.Glyph, False);
  end
  else
  begin
    FPassEdit.PasswordChar := #0;
    MakeEyeGlyph(FPassEye.Glyph, True);
  end;
end;

procedure TCredEditForm.CopyPubClick(Sender: TObject);
begin
  if FPublicKey <> '' then
    Clipboard.AsText := FPublicKey;
end;

procedure TCredEditForm.BrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Select a private key file';
    if dlg.Execute then
      FKeyEdit.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

procedure TCredEditForm.OkClick(Sender: TObject);
var
  dispName, user, domain, keyPath, err, uuid, pubLine: string;
  isKey, isManaged: Boolean;
  pw, key, phrase, pem: TSecureBytes;
  authType: TAuthType;
begin
  dispName := Trim(FNameEdit.Text);
  if dispName = '' then
  begin
    MessageDlg('Credential Manager', 'A name is required.', mtError, [mbOK], 0);
    Exit;
  end;
  user := Trim(FUserEdit.Text);
  domain := Trim(FDomainEdit.Text);
  isKey := FAuthCombo.ItemIndex = 1;
  isManaged := FAuthCombo.ItemIndex = 2;
  if isManaged and (user = '') then
  begin
    MessageDlg('Credential Manager',
      'A username is required for a managed SSH key.', mtError, [mbOK], 0);
    Exit;
  end;
  pw := nil; key := nil; phrase := nil;
  try
    keyPath := '';
    if isManaged then
      authType := atManagedKey
    else if isKey then
    begin
      authType := atSshKey;
      keyPath := Trim(FKeyEdit.Text);
      if keyPath <> '' then
      begin
        if not LoadKeyFile(keyPath, key, err) then
        begin
          MessageDlg('Credential Manager', err, mtError, [mbOK], 0);
          Exit;
        end;
      end
      else if (FUuid = '') or (not FHasStoredKey) then
      begin
        MessageDlg('Credential Manager', 'Pick a private key file.',
          mtError, [mbOK], 0);
        Exit;
      end;
      phrase := TakeSecret(FPhraseEdit);
    end
    else
    begin
      authType := atPassword;
      pw := TakeSecret(FPassEdit);
    end;
    try
      if FUuid = '' then
      begin
        uuid := FModel.CreateCredential(dispName, authType, user, domain,
          keyPath, pw, key, phrase, True);   // AManaged=True
        // uuid adopte tout de suite: sinon un Save apres echec fait un doublon
        FUuid := uuid;
      end
      else
      begin
        uuid := FUuid;
        // secrets nil = inchanges: editer le nom ne touche pas la cle privee
        FModel.UpdateCredential(FUuid, dispName, authType, user, domain,
          keyPath, pw, key, phrase);
      end;
      if isManaged and (FPublicKey = '') then
      begin
        GenerateEd25519KeyPair(user + '@rottensshrimp', pem, pubLine);
        try
          FModel.SetManagedKeyPair(uuid, pem, pubLine);
        finally
          pem.Free;
        end;
        FPublicKey := pubLine;
      end;
    except
      on E: Exception do
      begin
        MessageDlg('Credential Manager', E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    ModalResult := mrOk;
  finally
    pw.Free; key.Free; phrase.Free;
  end;
end;

destructor TCredEditForm.Destroy;
begin
  WipeEdit(FPassEdit);
  WipeEdit(FPhraseEdit);
  inherited Destroy;
end;

{ TCredManagerForm }

constructor TCredManagerForm.CreateFor(AOwner: TComponent; ADoc: TRshDocument;
  AModel: TRshModel; ASaveProc: TNotifyEvent);
const
  W = 540;
  H = 420;
  BTN_Y = H - 44;
var
  bx: Integer;

  function AddBtn(const ACap: string; AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Self;
    Result.Caption := ACap;
    Result.SetBounds(bx, BTN_Y, 96, 30);
    Result.OnClick := AHandler;
    Inc(bx, 104);
  end;

begin
  inherited CreateNew(AOwner);
  FDoc := ADoc;
  FModel := AModel;
  FSaveProc := ASaveProc;
  Caption := 'Credential Manager';
  BorderStyle := bsSingle;
  Position := poOwnerFormCenter;
  ClientWidth := W;

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.SetBounds(14, 14, W - 28, BTN_Y - 14 - 10);
  FList.Style := lbOwnerDrawFixed;
  FList.ItemHeight := ROW_H;
  FList.OnDrawItem := @ListDrawItem;
  FList.OnDblClick := @ListDblClick;
  FList.OnSelectionChange := @ListSelect;

  bx := 14;
  FBtnNew := AddBtn('New', @NewClick);
  FBtnEdit := AddBtn('Edit', @EditClick);
  FBtnDup := AddBtn('Duplicate', @DupClick);
  FBtnRotate := AddBtn('Rotate', @RotateClick);
  FBtnDelete := AddBtn('Delete', @DeleteClick);
  ClientHeight := H;

  Reload;
end;

destructor TCredManagerForm.Destroy;
begin
  FreeAndNil(FCreds);
  inherited Destroy;
end;

procedure TCredManagerForm.PersistAndReload(const APreferUuid: string);
begin
  if Assigned(FSaveProc) then FSaveProc(Self);
  Reload(APreferUuid);
end;

procedure TCredManagerForm.Reload(const APreferUuid: string);
var
  i, keep: Integer;
  wantUuid: string;
begin
  if APreferUuid <> '' then wantUuid := APreferUuid
  else wantUuid := SelectedUuid;
  FreeAndNil(FCreds);
  FCreds := FModel.ListManagedCredentials;
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i := 0 to FCreds.Count - 1 do
      FList.Items.Add(FCreds[i].Uuid);
  finally
    FList.Items.EndUpdate;
  end;
  keep := FList.Items.IndexOf(wantUuid);
  if (keep < 0) and (FList.Count > 0) then keep := 0;
  FList.ItemIndex := keep;
  SyncButtons;
end;

function TCredManagerForm.SelectedUuid: string;
begin
  Result := '';
  if (FList <> nil) and (FList.ItemIndex >= 0) and
     (FList.ItemIndex < FList.Count) then
    Result := FList.Items[FList.ItemIndex];
end;

procedure TCredManagerForm.SyncButtons;
var
  has: Boolean;
begin
  // Cocoa: OnSelectionChange manque a l'appel, d'ou l'activation sur presence.
  has := (FList <> nil) and (FList.Count > 0);
  FBtnEdit.Enabled := has;
  FBtnDup.Enabled := has;
  FBtnRotate.Enabled := has;
  FBtnDelete.Enabled := has;
end;

procedure TCredManagerForm.ListSelect(Sender: TObject; User: Boolean);
begin
  SyncButtons;
end;

procedure TCredManagerForm.ListDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
var
  c: TRshCredential;
  cv: TCanvas;
  selected: Boolean;
  authTxt, sub: string;
  users: Integer;
begin
  cv := FList.Canvas;
  cv.Brush.Style := bsSolid;
  if (odSelected in State) then cv.Brush.Color := clHighlight
  else cv.Brush.Color := clWindow;
  cv.FillRect(ARect);
  if (Index < 0) or (Index >= FCreds.Count) then Exit;
  c := FCreds[Index];
  selected := odSelected in State;

  cv.Brush.Style := bsClear;
  cv.Font := FList.Font;
  if selected then cv.Font.Color := clHighlightText else cv.Font.Color := clWindowText;
  cv.Font.Style := [fsBold];
  cv.TextOut(ARect.Left + 12, ARect.Top + 6, c.DisplayName);
  cv.Font.Style := [];
  if c.AuthType = atManagedKey then
  begin
    if c.HasPrivateKey then authTxt := 'managed SSH key'
    else authTxt := 'managed SSH key (not generated)';
  end
  else if c.AuthType = atSshKey then authTxt := 'SSH key'
  else if c.HasPassword then authTxt := 'password'
  else authTxt := 'prompt';
  users := Length(FModel.CredentialUsage(c.Uuid));
  sub := authTxt;
  if c.Username <> '' then sub := sub + '   ·   ' + c.Username;
  if users = 1 then sub := sub + '   ·   1 host'
  else sub := sub + Format('   ·   %d hosts', [users]);
  if selected then cv.Font.Color := clHighlightText
  else cv.Font.Color := clGrayText;
  cv.TextOut(ARect.Left + 12, ARect.Top + 25, sub);

  cv.Pen.Color := clSilver;
  cv.Line(ARect.Left, ARect.Bottom - 1, ARect.Right, ARect.Bottom - 1);
end;

procedure TCredManagerForm.ListDblClick(Sender: TObject);
begin
  EditClick(Sender);
end;

procedure TCredManagerForm.NewClick(Sender: TObject);
var
  dlg: TCredEditForm;
begin
  if FBusy then Exit;
  dlg := TCredEditForm.CreateFor(Self, FModel, '');
  try
    if dlg.ShowModal = mrOk then PersistAndReload;
  finally
    dlg.Free;
  end;
end;

procedure TCredManagerForm.EditClick(Sender: TObject);
var
  dlg: TCredEditForm;
  uuid: string;
begin
  if FBusy then Exit;
  uuid := SelectedUuid;
  if uuid = '' then Exit;
  dlg := TCredEditForm.CreateFor(Self, FModel, uuid);
  try
    if dlg.ShowModal = mrOk then PersistAndReload(uuid);
  finally
    dlg.Free;
  end;
end;

procedure TCredManagerForm.DupClick(Sender: TObject);
var
  uuid, newUuid: string;
begin
  if FBusy then Exit;
  uuid := SelectedUuid;
  if uuid = '' then Exit;
  newUuid := '';
  try
    newUuid := FModel.DuplicateCredential(uuid);
  except
    on E: Exception do
      MessageDlg('Credential Manager', E.Message, mtError, [mbOK], 0);
  end;
  PersistAndReload(newUuid);
end;

procedure TCredManagerForm.RotateClick(Sender: TObject);
var
  uuid, summary, err, msg: string;
  c: TRshCredential;
  hostCount: Integer;
begin
  if FBusy then Exit;
  uuid := SelectedUuid;
  if uuid = '' then Exit;
  c := FModel.GetCredential(uuid);
  try
    if (c.AuthType <> atManagedKey) or (c.PublicKey = '') or
       (not c.HasPrivateKey) then
    begin
      MessageDlg('Rotate Managed Key',
        'Only a managed SSH key with a generated pair can be rotated.',
        mtError, [mbOK], 0);
      Exit;
    end;
  finally
    c.Free;
  end;

  hostCount := Length(FModel.CredentialSshHosts(uuid));
  if hostCount = 0 then
    msg := 'Generate a new key pair for this credential?' + LineEnding +
      'No SSH host references it, so nothing will be pushed.'
  else
    msg := Format('Rotate the key pair and update %d SSH host(s)?',
      [hostCount]) + LineEnding + LineEnding +
      'The new key is installed on every host first (authenticated with ' +
      'the current key), and only then the old key is removed. If any host ' +
      'cannot be updated, nothing changes.';
  if MessageDlg('Rotate Managed Key', msg, mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then Exit;

  if RotateManagedKey(FDoc, FModel, uuid, summary, err) then
  begin
    PersistAndReload(uuid);
    MessageDlg('Rotate Managed Key', summary, mtInformation, [mbOK], 0);
  end
  else
  begin
    // meme en echec: des cles d'hote ont pu etre approuvees en route
    PersistAndReload(uuid);
    if err <> '' then
      MessageDlg('Rotate Managed Key', err, mtError, [mbOK], 0);
  end;
end;

procedure TCredManagerForm.DeleteClick(Sender: TObject);
var
  uuid: string;
  usage: TStringArray;
  hosts: string;
  i: Integer;
begin
  if FBusy then Exit;
  uuid := SelectedUuid;
  if uuid = '' then Exit;
  // encore affecte a un hote: on refuse plutot que de le casser en douce
  usage := FModel.CredentialUsage(uuid);
  if Length(usage) > 0 then
  begin
    hosts := '';
    for i := 0 to High(usage) do
    begin
      if i > 0 then hosts := hosts + ', ';
      hosts := hosts + usage[i];
      if i >= 5 then begin hosts := hosts + '…'; Break; end;
    end;
    MessageDlg('Credential Manager',
      Format('This credential is still assigned to %d host(s): %s' + LineEnding +
        LineEnding + 'Unassign it from them first, then delete it.',
        [Length(usage), hosts]), mtError, [mbOK], 0);
    Exit;
  end;
  if QuestionDlg('Credential Manager', 'Delete this managed credential?',
     mtConfirmation, [mrYes, 'Delete', mrNo, 'Cancel', 'IsCancel'], 0)
     <> mrYes then Exit;
  try
    FModel.DeleteCredential(uuid, dsFail);
  except
    on E: Exception do
      MessageDlg('Credential Manager', E.Message, mtError, [mbOK], 0);
  end;
  PersistAndReload;
end;

procedure ShowCredentialManager(AOwner: TCustomForm; ADoc: TRshDocument;
  AModel: TRshModel; ASaveProc: TNotifyEvent);
var
  f: TCredManagerForm;
begin
  f := TCredManagerForm.CreateFor(AOwner, ADoc, AModel, ASaveProc);
  try
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
