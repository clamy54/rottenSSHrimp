unit uNodeDialogs;

{$mode objfpc}{$H+}

// Dialogues de proprietes des noeuds, construits par code. En « Inherit from
// parent folder », le dialogue AFFICHE ce que l'heritage resoudrait.

interface

uses
  Graphics, uRshModel;

procedure MakeEyeGlyph(ABmp: TBitmap; ACrossed: Boolean);

function ShowNewConnectionDialog(AModel: TRshModel;
  const AParentUuid: string; AProtocol: TRshProtocol): string;

function ShowConnectionProperties(AModel: TRshModel;
  const AUuid: string): Boolean;

function ShowGroupProperties(AModel: TRshModel; const AUuid: string): Boolean;

implementation

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Buttons, Dialogs,
  IntfGraphics, fpImage, uRshValidation, uTheme, uVersion, uSecureBytes,
  uSecretClipGuard;

const
  DLG_W = 520;
  MARGIN = 16;
  LBL_W = 130;
  EDIT_X = MARGIN + LBL_W + 8;
  EDIT_W = DLG_W - EDIT_X - MARGIN;

  TAG_ASK = '#ask';
  TAG_PASSWORD = '#password';
  TAG_KEY = '#key';
  TAG_INHERIT = '#inherit';
  TAG_MANAGED = '#managed';
  TAG_NONE = '#none';

  MAX_KEY_BYTES = 64 * 1024; // au-dela, ce n'est pas une cle privee

type
  TFolderCredSection = record
    Proto: TRshProtocol;
    Combo: TComboBox;
    Tags: array of string;
    UserLbl, DomainLbl, PassLbl, KeyLbl, PhraseLbl: TLabel;
    UserEdit, DomainEdit, PassEdit, KeyEdit, PhraseEdit: TEdit;
    KeyBrowse: TButton;
    CurCred: string;
    HasStoredPassword: Boolean;
    HasStoredKey: Boolean;
  end;

  TNodeDialog = class(TForm)
  private
    FNameEdit: TEdit;
    FHostEdit: TEdit;
    FPortEdit: TEdit;
    FTimeoutEdit: TEdit;
    FDescEdit: TMemo;
    FCredCombo: TComboBox;
    FCredUuids: TStringList;
    FManagedCombo: TComboBox;
    FManagedUuids: TStringList;
    FJumpCombo: TComboBox;
    FJumpUuids: TStringList;
    FUserLbl, FDomainLbl, FPassLbl, FKeyLbl, FPhraseLbl: TLabel;
    FUserEdit, FDomainEdit, FPassEdit, FKeyEdit, FPhraseEdit: TEdit;
    FInheritHint: string;
    FInheritAvailable: Boolean;
    FSections: array of TFolderCredSection;
    FGwHostLbl, FGwPortLbl: TLabel;
    FGwHostEdit, FGwPortEdit: TEdit;
    FVncActualSizeChk: TCheckBox;
    FJumpOfferChk: TCheckBox;
    FKeyBrowse: TButton;
    FPassEye: TSpeedButton;
    FPassRevealed: Boolean;
    FHintLbl: TLabel;
    FProto: TRshProtocol;
    FHasStoredPassword: Boolean;
    FHasStoredKey: Boolean;
    FY: Integer;
    function AddRow(const ACaption: string): TLabel;
    function AddEdit(const ACaption, AValue: string): TEdit;
    procedure AddButtons(const AOkCaption: string);
    procedure CredComboChanged(Sender: TObject);
    procedure BrowseKeyClick(Sender: TObject);
    procedure PassEyeClick(Sender: TObject);
    function SelectedTag: string;
    function SelectedManagedUuid: string;
    procedure UpdateAuthRows;
    procedure AddFolderSection(AProto: TRshProtocol);
    procedure FolderComboChanged(Sender: TObject);
    procedure FolderBrowseClick(Sender: TObject);
    procedure UpdateFolderSections;
    function SectionTag(const ASec: TFolderCredSection): string;
  public
    constructor CreateShell(AOwner: TComponent; const ATitle: string);
    destructor Destroy; override;
  end;

// TransparentColor est ignore sur un glyph Cocoa: on peint sur un fond masque,
// converti ensuite en alpha=0.
procedure MakeEyeGlyph(ABmp: TBitmap; ACrossed: Boolean);
const
  MASK = clFuchsia;
var
  cy, x, yy: Integer;
  img: TLazIntfImage;
  mc, c: TFPColor;
begin
  ABmp.PixelFormat := pf32bit;
  ABmp.SetSize(16, 16);
  ABmp.Canvas.AntialiasingMode := amOff;
  ABmp.Canvas.Brush.Color := MASK;
  ABmp.Canvas.FillRect(0, 0, 16, 16);
  cy := 8;
  ABmp.Canvas.Pen.Color := clBlack;
  ABmp.Canvas.Pen.Width := 1;
  ABmp.Canvas.Brush.Style := bsClear;
  ABmp.Canvas.Ellipse(1, cy - 4, 15, cy + 4);
  ABmp.Canvas.Brush.Style := bsSolid;
  ABmp.Canvas.Brush.Color := clBlack;
  ABmp.Canvas.Ellipse(6, cy - 2, 10, cy + 2);
  if ACrossed then
  begin
    ABmp.Canvas.Pen.Color := clBlack;
    ABmp.Canvas.Line(2, 14, 14, 2);
  end;
  ABmp.Canvas.Brush.Style := bsSolid;

  mc := TColorToFPColor(MASK);
  img := ABmp.CreateIntfImage;
  try
    for yy := 0 to img.Height - 1 do
      for x := 0 to img.Width - 1 do
      begin
        c := img.Colors[x, yy];
        if (c.Red = mc.Red) and (c.Green = mc.Green) and (c.Blue = mc.Blue) then
          c.Alpha := 0
        else
          c.Alpha := alphaOpaque;
        img.Colors[x, yy] := c;
      end;
    ABmp.LoadFromIntfImage(img);
  finally
    img.Free;
  end;
end;

constructor TNodeDialog.CreateShell(AOwner: TComponent; const ATitle: string);
begin
  inherited CreateNew(AOwner, 0);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Width := DLG_W;
  FY := MARGIN;
  FCredUuids := TStringList.Create;
  FManagedUuids := TStringList.Create;
  FJumpUuids := TStringList.Create;
end;

destructor TNodeDialog.Destroy;

  procedure Wipe(AEdit: TEdit);
  begin
    if AEdit = nil then Exit;
    AEdit.Text := StringOfChar('*', Length(AEdit.Text));
    AEdit.Text := '';
  end;

var
  i: Integer;
begin
  // sans ce relachement, le presse-papiers reste gele jusqu'a la fin du process
  if FPassRevealed then
  begin
    FPassRevealed := False;
    SecretRevealEnd;
  end;
  Wipe(FPassEdit);
  Wipe(FPhraseEdit);
  for i := 0 to High(FSections) do
  begin
    Wipe(FSections[i].PassEdit);
    Wipe(FSections[i].PhraseEdit);
  end;
  FCredUuids.Free;
  FManagedUuids.Free;
  FJumpUuids.Free;
  inherited Destroy;
end;

function TNodeDialog.AddRow(const ACaption: string): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(MARGIN, FY + 4, LBL_W, 18);
  Result.Caption := ACaption;
end;

function TNodeDialog.AddEdit(const ACaption, AValue: string): TEdit;
begin
  AddRow(ACaption);
  Result := TEdit.Create(Self);
  Result.Parent := Self;
  Result.SetBounds(EDIT_X, FY, EDIT_W, 26);
  Result.Text := AValue;
  Inc(FY, 34);
end;

procedure TNodeDialog.AddButtons(const AOkCaption: string);
var
  ok, cancel: TButton;
begin
  Inc(FY, 6);
  ok := TButton.Create(Self);
  ok.Parent := Self;
  ok.SetBounds(DLG_W - MARGIN - 110, FY, 110, 30);
  ok.Caption := AOkCaption;
  ok.ModalResult := mrOk;
  ok.Default := True;
  cancel := TButton.Create(Self);
  cancel.Parent := Self;
  cancel.SetBounds(DLG_W - MARGIN - 230, FY, 110, 30);
  cancel.Caption := 'Cancel';
  cancel.ModalResult := mrCancel;
  cancel.Cancel := True;
  Inc(FY, 30 + MARGIN);
  ClientHeight := FY;
end;

function TNodeDialog.SelectedTag: string;
begin
  if (FCredCombo.ItemIndex >= 0) and
     (FCredCombo.ItemIndex < FCredUuids.Count) then
    Result := FCredUuids[FCredCombo.ItemIndex]
  else
    Result := TAG_ASK;
end;

function TNodeDialog.SelectedManagedUuid: string;
begin
  Result := '';
  if (FManagedCombo <> nil) and (FManagedCombo.ItemIndex >= 0) and
     (FManagedCombo.ItemIndex < FManagedUuids.Count) then
    Result := FManagedUuids[FManagedCombo.ItemIndex];
end;

procedure TNodeDialog.UpdateAuthRows;
var
  mode: string;
  wantUser, wantPass, wantKey, wantManaged: Boolean;
begin
  mode := SelectedTag;
  wantPass := mode = TAG_PASSWORD;
  wantKey := mode = TAG_KEY;
  wantManaged := mode = TAG_MANAGED;
  if FManagedCombo <> nil then
    FManagedCombo.Visible := wantManaged;
  wantUser := (wantPass or wantKey) and (FProto <> rpVnc);

  FUserLbl.Visible := wantUser;
  FUserEdit.Visible := wantUser;
  FDomainLbl.Visible := wantPass and (FProto = rpRdp);
  FDomainEdit.Visible := wantPass and (FProto = rpRdp);
  FPassLbl.Visible := wantPass;
  FPassEdit.Visible := wantPass;
  FPassEye.Visible := wantPass;
  FKeyLbl.Visible := wantKey;
  FKeyEdit.Visible := wantKey;
  FKeyBrowse.Visible := wantKey;
  FPhraseLbl.Visible := wantKey;
  FPhraseEdit.Visible := wantKey;

  if mode = TAG_INHERIT then
    FHintLbl.Caption := FInheritHint
  else if mode = TAG_ASK then
    FHintLbl.Caption :=
      'Username and password will be asked when the session opens.'
  else if wantPass and FHasStoredPassword then
    FHintLbl.Caption := 'The stored password is shown. Use the eye to reveal it.'
  else if wantKey and FHasStoredKey then
    FHintLbl.Caption := 'A private key is stored. Leave blank to keep it.'
  else if wantPass then
    FHintLbl.Caption := 'Leave the password blank to be asked at connect.'
  else if wantKey then
    FHintLbl.Caption :=
      'The key is read now and stored encrypted in the document.'
  else
    FHintLbl.Caption := 'Shared credential from the Credential Manager.';
end;

procedure TNodeDialog.CredComboChanged(Sender: TObject);
begin
  UpdateAuthRows;
end;

function TNodeDialog.SectionTag(const ASec: TFolderCredSection): string;
begin
  if (ASec.Combo.ItemIndex >= 0) and
     (ASec.Combo.ItemIndex <= High(ASec.Tags)) then
    Result := ASec.Tags[ASec.Combo.ItemIndex]
  else
    Result := TAG_NONE;
end;

procedure TNodeDialog.UpdateFolderSections;
var
  i: Integer;
  mode: string;
  wantUser, wantPass, wantKey: Boolean;
begin
  for i := 0 to High(FSections) do
  begin
    mode := SectionTag(FSections[i]);
    wantPass := mode = TAG_PASSWORD;
    wantKey := mode = TAG_KEY;
    wantUser := (wantPass or wantKey) and (FSections[i].Proto <> rpVnc);
    if FSections[i].UserLbl <> nil then
    begin
      FSections[i].UserLbl.Visible := wantUser;
      FSections[i].UserEdit.Visible := wantUser;
    end;
    if FSections[i].DomainLbl <> nil then
    begin
      FSections[i].DomainLbl.Visible := wantPass;
      FSections[i].DomainEdit.Visible := wantPass;
    end;
    FSections[i].PassLbl.Visible := wantPass;
    FSections[i].PassEdit.Visible := wantPass;
    if FSections[i].KeyLbl <> nil then
    begin
      FSections[i].KeyLbl.Visible := wantKey;
      FSections[i].KeyEdit.Visible := wantKey;
      FSections[i].KeyBrowse.Visible := wantKey;
      FSections[i].PhraseLbl.Visible := wantKey;
      FSections[i].PhraseEdit.Visible := wantKey;
    end;
  end;
end;

procedure TNodeDialog.FolderComboChanged(Sender: TObject);
begin
  UpdateFolderSections;
end;

procedure TNodeDialog.FolderBrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
  i: Integer;
begin
  for i := 0 to High(FSections) do
    if FSections[i].KeyBrowse = Sender then
    begin
      dlg := TOpenDialog.Create(Self);
      try
        dlg.Title := 'Select private key';
        dlg.Options := dlg.Options + [ofFileMustExist];
        if dlg.Execute then
          FSections[i].KeyEdit.Text := dlg.FileName;
      finally
        dlg.Free;
      end;
      Exit;
    end;
end;

procedure TNodeDialog.AddFolderSection(AProto: TRshProtocol);
var
  sec: TFolderCredSection;
  n: Integer;
begin
  sec := Default(TFolderCredSection);
  sec.Proto := AProto;

  AddRow(UpperCase(PROTOCOL_NAMES[AProto]) + ' credentials:');
  sec.Combo := TComboBox.Create(Self);
  sec.Combo.Parent := Self;
  sec.Combo.Style := csDropDownList;
  sec.Combo.SetBounds(EDIT_X, FY, EDIT_W, 26);
  sec.Combo.OnChange := @FolderComboChanged;
  sec.Combo.Items.Add('(none)');
  SetLength(sec.Tags, 2);
  sec.Tags[0] := TAG_NONE;
  sec.Tags[1] := TAG_PASSWORD;
  if AProto = rpVnc then
    sec.Combo.Items.Add('Password')
  else
    sec.Combo.Items.Add('Username and password');
  if AProto = rpSsh then
  begin
    sec.Combo.Items.Add('SSH private key');
    SetLength(sec.Tags, 3);
    sec.Tags[2] := TAG_KEY;
  end;
  sec.Combo.ItemIndex := 0;
  Inc(FY, 34);

  if AProto <> rpVnc then
  begin
    sec.UserLbl := AddRow('Username:');
    sec.UserEdit := TEdit.Create(Self);
    sec.UserEdit.Parent := Self;
    sec.UserEdit.SetBounds(EDIT_X, FY, EDIT_W, 26);
    Inc(FY, 34);
  end;
  if AProto = rpRdp then
  begin
    sec.DomainLbl := AddRow('Domain:');
    sec.DomainEdit := TEdit.Create(Self);
    sec.DomainEdit.Parent := Self;
    sec.DomainEdit.SetBounds(EDIT_X, FY, EDIT_W, 26);
    Inc(FY, 34);
  end;
  sec.PassLbl := AddRow('Password:');
  sec.PassEdit := TEdit.Create(Self);
  sec.PassEdit.Parent := Self;
  sec.PassEdit.SetBounds(EDIT_X, FY, EDIT_W, 26);
  sec.PassEdit.PasswordChar := '*';
  if AProto = rpSsh then
  begin
    sec.KeyLbl := AddRow('Private key:');
    sec.KeyEdit := TEdit.Create(Self);
    sec.KeyEdit.Parent := Self;
    sec.KeyEdit.SetBounds(EDIT_X, FY, EDIT_W - 92, 26);
    sec.KeyBrowse := TButton.Create(Self);
    sec.KeyBrowse.Parent := Self;
    sec.KeyBrowse.SetBounds(EDIT_X + EDIT_W - 86, FY, 86, 26);
    sec.KeyBrowse.Caption := 'Browse…';
    sec.KeyBrowse.OnClick := @FolderBrowseClick;
    Inc(FY, 34);
    sec.PhraseLbl := AddRow('Passphrase:');
    sec.PhraseEdit := TEdit.Create(Self);
    sec.PhraseEdit.Parent := Self;
    sec.PhraseEdit.SetBounds(EDIT_X, FY, EDIT_W, 26);
    sec.PhraseEdit.PasswordChar := '*';
    Inc(FY, 34);
  end
  else
    Inc(FY, 34);

  n := Length(FSections);
  SetLength(FSections, n + 1);
  FSections[n] := sec;
end;

procedure TNodeDialog.PassEyeClick(Sender: TObject);
begin
  if FPassEdit.PasswordChar = #0 then
  begin
    FPassEdit.PasswordChar := '*';
    MakeEyeGlyph(FPassEye.Glyph, False);
    if FPassRevealed then
    begin
      FPassRevealed := False;
      SecretRevealEnd;
    end;
  end
  else
  begin
    FPassEdit.PasswordChar := #0;
    MakeEyeGlyph(FPassEye.Glyph, True);
    // en clair, Cocoa redonne un champ copiable: on gele l'annonce presse-papiers
    if not FPassRevealed then
    begin
      FPassRevealed := True;
      SecretRevealBegin;
    end;
  end;
end;

procedure TNodeDialog.BrowseKeyClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(Self);
  try
    dlg.Title := 'Select private key';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if dlg.Execute then
      FKeyEdit.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

function ShowError(const AMsg: string): Boolean;
begin
  MessageDlg(RSSH_APP_NAME, AMsg, mtError, [mbOK], 0);
  Result := False;
end;

function ReadInt(const S: string; out V: Integer): Boolean;
begin
  Result := TryStrToInt(Trim(S), V);
end;

function GwPortOf(ADlg: TNodeDialog): Integer;
begin
  if (ADlg.FGwPortEdit = nil) or
     (not TryStrToInt(Trim(ADlg.FGwPortEdit.Text), Result)) then
    Result := RDP_GATEWAY_DEFAULT_PORT;
end;

// Possede = un seul usage, modifiable en place; un credential gere, jamais.
function IsOwnedCredential(AModel: TRshModel;
  const ACredUuid: string): Boolean;
begin
  Result := (ACredUuid <> '') and (not AModel.IsManagedCredential(ACredUuid))
    and (Length(AModel.CredentialUsage(ACredUuid)) <= 1);
end;

function TakeSecret(AEdit: TEdit): TSecureBytes;
var
  raw: RawByteString;
begin
  Result := nil;
  raw := RawByteString(AEdit.Text);
  if raw = '' then
    Exit;
  try
    Result := TSecureBytes.CreateFrom(raw[1], Length(raw));
  finally
    FillChar(raw[1], Length(raw), 0);
    raw := '';
  end;
end;

function LoadKeyFile(const APath: string; out AKey: TSecureBytes;
  out AErr: string): Boolean;
var
  fs: TFileStream;
  tmp: TBytes;
  n: Int64;
begin
  Result := False;
  AKey := nil;
  AErr := '';
  if not FileExists(APath) then
  begin
    AErr := Format('Key file not found: %s', [APath]);
    Exit;
  end;
  try
    fs := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
    try
      // taille lue UNE FOIS: en fmShareDenyNone, la relire faisait deborder tmp
      n := fs.Size;
      if n = 0 then
      begin
        AErr := 'The key file is empty.';
        Exit;
      end;
      if n > MAX_KEY_BYTES then
      begin
        AErr := 'This file is too large for a private key.';
        Exit;
      end;
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
  except
    on E: Exception do
      AErr := 'Cannot read the key: ' + E.Message;
  end;
end;

procedure PreloadSecret(AModel: TRshModel; const ACredUuid, AField: string;
  AEdit: TEdit);
var
  secret: TSecureBytes;
  raw: RawByteString;
begin
  secret := nil;
  try
    if not AModel.GetSecret(ACredUuid, AField, secret) then Exit;
    if (secret = nil) or (secret.Len = 0) then Exit;
    SetLength(raw, secret.Len);
    Move(secret.Data^, raw[1], secret.Len);
    try
      AEdit.Text := raw;
    finally
      FillChar(raw[1], Length(raw), 0);
      raw := '';
    end;
  except
  end;
  secret.Free;
end;

function FillManagedCombo(ADlg: TNodeDialog; AModel: TRshModel;
  AProto: TRshProtocol): Boolean;
var
  list: TRshCredentialList;
  i: Integer;
begin
  ADlg.FManagedCombo.Items.Clear;
  ADlg.FManagedUuids.Clear;
  list := AModel.ListManagedCredentials;
  try
    for i := 0 to list.Count - 1 do
    begin
      // une cle SSH est refusee au connect par RDP/VNC: ne pas la proposer
      if (AProto <> rpSsh) and
         (list[i].AuthType in [atManagedKey, atSshKey]) then
        Continue;
      ADlg.FManagedCombo.Items.Add(list[i].DisplayName);
      ADlg.FManagedUuids.Add(list[i].Uuid);
    end;
  finally
    list.Free;
  end;
  Result := ADlg.FManagedUuids.Count > 0;
  if Result then
  begin
    ADlg.FCredCombo.Items.Add('Credential Manager');
    ADlg.FCredUuids.Add(TAG_MANAGED);
    ADlg.FManagedCombo.ItemIndex := 0;
  end;
end;

procedure FillCredCombo(ADlg: TNodeDialog; AModel: TRshModel;
  const ASelectedUuid: string; AProto: TRshProtocol; AInherit: Boolean);
var
  cur: TRshCredential;
begin
  ADlg.FCredCombo.Style := csDropDownList;
  ADlg.FCredCombo.Items.Add('Inherit from parent folder');
  ADlg.FCredUuids.Add(TAG_INHERIT);
  ADlg.FCredCombo.Items.Add('Ask at connect');
  ADlg.FCredUuids.Add(TAG_ASK);
  if AProto = rpVnc then
    ADlg.FCredCombo.Items.Add('Password')
  else
    ADlg.FCredCombo.Items.Add('Username and password');
  ADlg.FCredUuids.Add(TAG_PASSWORD);
  if AProto = rpSsh then
  begin
    ADlg.FCredCombo.Items.Add('SSH private key');
    ADlg.FCredUuids.Add(TAG_KEY);
  end;

  FillManagedCombo(ADlg, AModel, AProto);

  ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_ASK);
  if ASelectedUuid = '' then
  begin
    if AInherit then
      ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_INHERIT);
    Exit;
  end;
  if AModel.IsManagedCredential(ASelectedUuid) then
  begin
    if ADlg.FManagedUuids.IndexOf(ASelectedUuid) >= 0 then
    begin
      ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_MANAGED);
      ADlg.FManagedCombo.ItemIndex := ADlg.FManagedUuids.IndexOf(ASelectedUuid);
    end
    else
      ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_ASK);
    if ADlg.FCredCombo.ItemIndex < 0 then
      ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_ASK);
    Exit;
  end;
  cur := AModel.GetCredential(ASelectedUuid);
  try
    ADlg.FUserEdit.Text := cur.Username;
    ADlg.FDomainEdit.Text := cur.DomainName;
    ADlg.FHasStoredPassword := cur.HasPassword;
    ADlg.FHasStoredKey := cur.HasPrivateKey;
    if cur.HasPassword then
      PreloadSecret(AModel, ASelectedUuid, FIELD_CRED_PASSWORD, ADlg.FPassEdit);
    case cur.AuthType of
      atSshKey:
        ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_KEY);
      atPassword:
        ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_PASSWORD);
    else
      ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_ASK);
    end;
  finally
    cur.Free;
  end;
  if ADlg.FCredCombo.ItemIndex < 0 then
    ADlg.FCredCombo.ItemIndex := ADlg.FCredUuids.IndexOf(TAG_ASK);
end;

// Filtre les hotes qui rebondissent deja: un seul saut est supporte.
procedure FillJumpCombo(ADlg: TNodeDialog; AModel: TRshModel;
  const ASelfUuid, ACurrentJump: string);
var
  nodes: TRshNodeList;
  offers: TStringList;
  filtering: Boolean;
  i, sel: Integer;
begin
  ADlg.FJumpCombo.Style := csDropDownList;
  ADlg.FJumpCombo.Items.Clear;
  ADlg.FJumpUuids.Clear;
  ADlg.FJumpCombo.Items.Add('(direct — no jump host)');
  ADlg.FJumpUuids.Add('');
  sel := 0;
  offers := TStringList.Create;
  try
    offers.Sorted := True;
    AModel.LoadJumpHostOffers(offers);
    filtering := AModel.JumpHostOffersAvailable;
    // LoadNodes DANS le try: cree avant, offers fuit s'il leve
    nodes := AModel.LoadNodes;
    try
    for i := 0 to nodes.Count - 1 do
      if (nodes[i].Kind = nkConnection) and (nodes[i].Protocol = rpSsh)
         and (nodes[i].Uuid <> ASelfUuid)
         and (AModel.GetJumpVia(nodes[i].Uuid) = '')
         // le rebond configure reste visible: sinon un aller-retour le supprime
         and ((not filtering) or (nodes[i].Uuid = ACurrentJump)
              or (offers.IndexOf(nodes[i].Uuid) >= 0)) then
      begin
        ADlg.FJumpCombo.Items.Add(Format('%s (%s)',
          [nodes[i].DisplayName, nodes[i].Hostname]));
        ADlg.FJumpUuids.Add(nodes[i].Uuid);
        if nodes[i].Uuid = ACurrentJump then
          sel := ADlg.FJumpUuids.Count - 1;
      end;
    finally
      nodes.Free;
    end;
  finally
    offers.Free;
  end;
  ADlg.FJumpCombo.ItemIndex := sel;
end;

function SelectedJump(ADlg: TNodeDialog): string;
begin
  Result := '';
  if (ADlg.FJumpCombo <> nil) and (ADlg.FJumpCombo.ItemIndex >= 0)
     and (ADlg.FJumpCombo.ItemIndex < ADlg.FJumpUuids.Count) then
    Result := ADlg.FJumpUuids[ADlg.FJumpCombo.ItemIndex];
end;

function BuildConnectionDialog(AModel: TRshModel; const ATitle: string;
  const AName, AHost: string; APort, ATimeout: Integer;
  const ACredUuid, ADesc: string; AProto: TRshProtocol;
  const AParentUuid: string; AInherit: Boolean;
  const AGwHost: string = ''; AGwPort: Integer = 0;
  const AConnUuid: string = ''; const AJumpUuid: string = ''): TNodeDialog;
var
  resolvedCred, srcFolder: string;
  cred: TRshCredential;
begin
  Result := TNodeDialog.CreateShell(nil, ATitle);
  Result.FProto := AProto;

  resolvedCred := AModel.ResolveFolderCredential(AParentUuid, AProto,
    srcFolder);
  Result.FInheritAvailable := resolvedCred <> '';
  if Result.FInheritAvailable then
  begin
    try
      cred := AModel.GetCredential(resolvedCred);
      try
        Result.FInheritHint := Format('Inherited: %s (from folder "%s").',
          [cred.DisplayName, srcFolder]);
      finally
        cred.Free;
      end;
    except
      on EModelError do
        Result.FInheritHint := Format('Inherited from folder "%s".',
          [srcFolder]);
    end;
  end
  else
    Result.FInheritHint := Format('No parent folder provides %s' +
      ' credentials: you will be asked at connect.',
      [UpperCase(PROTOCOL_NAMES[AProto])]);
  Result.FNameEdit := Result.AddEdit('Name:', AName);
  Result.FHostEdit := Result.AddEdit('Hostname:', AHost);
  Result.FPortEdit := Result.AddEdit('Port:', IntToStr(APort));
  Result.FTimeoutEdit := Result.AddEdit('Timeout (s):', IntToStr(ATimeout));

  Result.AddRow('Connect via:');
  Result.FJumpCombo := TComboBox.Create(Result);
  Result.FJumpCombo.Parent := Result;
  Result.FJumpCombo.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Inc(Result.FY, 34);
  FillJumpCombo(Result, AModel, AConnUuid, AJumpUuid);

  if AProto = rpSsh then
  begin
    Result.FJumpOfferChk := TCheckBox.Create(Result);
    Result.FJumpOfferChk.Parent := Result;
    Result.FJumpOfferChk.Caption := 'Offer this host as a jump host';
    Result.FJumpOfferChk.SetBounds(EDIT_X, Result.FY, EDIT_W, 22);
    Result.FJumpOfferChk.Checked := (AConnUuid <> '')
      and AModel.IsJumpHostOffered(AConnUuid);
    if not AModel.JumpHostOffersAvailable then
    begin
      Result.FJumpOfferChk.Enabled := False;
      Result.FJumpOfferChk.Caption := Result.FJumpOfferChk.Caption +
        '  (unavailable: older document format)';
    end;
    Inc(Result.FY, 30);
  end;

  Result.AddRow('Authentication:');
  Result.FCredCombo := TComboBox.Create(Result);
  Result.FCredCombo.Parent := Result;
  Result.FCredCombo.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Result.FCredCombo.OnChange := @Result.CredComboChanged;
  Inc(Result.FY, 34);

  Result.FManagedCombo := TComboBox.Create(Result);
  Result.FManagedCombo.Parent := Result;
  Result.FManagedCombo.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Result.FManagedCombo.Style := csDropDownList;
  Result.FManagedCombo.Visible := False;

  Result.FUserLbl := Result.AddRow('Username:');
  Result.FUserEdit := TEdit.Create(Result);
  Result.FUserEdit.Parent := Result;
  Result.FUserEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Inc(Result.FY, 34);

  Result.FDomainLbl := Result.AddRow('Domain:');
  Result.FDomainEdit := TEdit.Create(Result);
  Result.FDomainEdit.Parent := Result;
  Result.FDomainEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Inc(Result.FY, 34);

  Result.FPassLbl := Result.AddRow('Password:');
  Result.FPassEdit := TEdit.Create(Result);
  Result.FPassEdit.Parent := Result;
  Result.FPassEdit.SetBounds(EDIT_X, Result.FY, EDIT_W - 32, 26);
  Result.FPassEdit.PasswordChar := '*';
  Result.FPassEye := TSpeedButton.Create(Result);
  Result.FPassEye.Parent := Result;
  Result.FPassEye.SetBounds(EDIT_X + EDIT_W - 26, Result.FY, 26, 26);
  Result.FPassEye.Flat := True;
  Result.FPassEye.OnClick := @Result.PassEyeClick;
  MakeEyeGlyph(Result.FPassEye.Glyph, False);

  Result.FKeyLbl := Result.AddRow('Private key:');
  Result.FKeyEdit := TEdit.Create(Result);
  Result.FKeyEdit.Parent := Result;
  Result.FKeyEdit.SetBounds(EDIT_X, Result.FY, EDIT_W - 92, 26);
  Result.FKeyBrowse := TButton.Create(Result);
  Result.FKeyBrowse.Parent := Result;
  Result.FKeyBrowse.SetBounds(EDIT_X + EDIT_W - 86, Result.FY, 86, 26);
  Result.FKeyBrowse.Caption := 'Browse…';
  Result.FKeyBrowse.OnClick := @Result.BrowseKeyClick;
  Inc(Result.FY, 34);

  Result.FPhraseLbl := Result.AddRow('Passphrase:');
  Result.FPhraseEdit := TEdit.Create(Result);
  Result.FPhraseEdit.Parent := Result;
  Result.FPhraseEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
  Result.FPhraseEdit.PasswordChar := '*';
  Inc(Result.FY, 32);

  Result.FHintLbl := TLabel.Create(Result);
  Result.FHintLbl.Parent := Result;
  // AutoSize avant WordWrap: sinon le TLabel s'etire et sort du dialogue
  Result.FHintLbl.AutoSize := False;
  Result.FHintLbl.WordWrap := True;
  Result.FHintLbl.SetBounds(EDIT_X, Result.FY, EDIT_W, 32);
  Result.FHintLbl.Font.Color := clGrayText;
  Inc(Result.FY, 38);

  FillCredCombo(Result, AModel, ACredUuid, AProto, AInherit);
  Result.UpdateAuthRows;

  if AProto = rpRdp then
  begin
    Result.FGwHostLbl := Result.AddRow('RD Gateway:');
    Result.FGwHostEdit := TEdit.Create(Result);
    Result.FGwHostEdit.Parent := Result;
    Result.FGwHostEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
    Result.FGwHostEdit.Text := AGwHost;
    Result.FGwHostEdit.TextHint := 'gateway.example.com (empty = none)';
    Inc(Result.FY, 34);

    Result.FGwPortLbl := Result.AddRow('Gateway port:');
    Result.FGwPortEdit := TEdit.Create(Result);
    Result.FGwPortEdit.Parent := Result;
    Result.FGwPortEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 26);
    if AGwPort > 0 then
      Result.FGwPortEdit.Text := IntToStr(AGwPort)
    else
      Result.FGwPortEdit.Text := IntToStr(RDP_GATEWAY_DEFAULT_PORT);
    Inc(Result.FY, 34);
  end;

  if AProto = rpVnc then
  begin
    with TLabel.Create(Result) do
    begin
      Parent := Result;
      AutoSize := False;
      WordWrap := True;
      SetBounds(EDIT_X, Result.FY, EDIT_W, 44);
      Font.Style := [fsBold];
      Caption := 'Warning: VNC is not encrypted. Keystrokes, screen and ' +
        'clipboard travel in cleartext; RFB truncates the password to ' +
        '8 characters.';
    end;
    Inc(Result.FY, 50);

    Result.FVncActualSizeChk := TCheckBox.Create(Result);
    Result.FVncActualSizeChk.Parent := Result;
    Result.FVncActualSizeChk.Caption :=
      'Show at actual size (1:1, with scrollbars)';
    Result.FVncActualSizeChk.SetBounds(EDIT_X, Result.FY, EDIT_W, 22);
    Result.FVncActualSizeChk.Checked := False;
    Inc(Result.FY, 30);
  end;

  Result.AddRow('Description:');
  Result.FDescEdit := TMemo.Create(Result);
  Result.FDescEdit.Parent := Result;
  Result.FDescEdit.SetBounds(EDIT_X, Result.FY, EDIT_W, 60);
  Result.FDescEdit.Text := ADesc;
  Inc(Result.FY, 68);
end;

function ApplyCredential(AModel: TRshModel; ADlg: TNodeDialog;
  const AConnName, ACurrentCredUuid: string;
  out ACredUuid: string; out AInherit: Boolean; out AErr: string): Boolean;
var
  mode, user, domain, keyPath: string;
  owned: Boolean;
  pw, key, phrase: TSecureBytes;
  authType: TAuthType;
begin
  Result := False;
  ACredUuid := '';
  AErr := '';
  mode := ADlg.SelectedTag;
  AInherit := mode = TAG_INHERIT;

  if AInherit or (mode = TAG_ASK) then
  begin
    ACredUuid := '';
    Exit(True);
  end;
  if mode = TAG_MANAGED then
  begin
    ACredUuid := ADlg.SelectedManagedUuid;
    if ACredUuid = '' then
    begin
      AErr := 'Pick a credential from the Credential Manager.';
      Exit;
    end;
    Exit(True);
  end;

  user := Trim(ADlg.FUserEdit.Text);
  // force a vide en VNC: le champ est masque, l'exiger bloquerait tout
  if ADlg.FProto = rpVnc then
    user := ''
  else if user = '' then
  begin
    AErr := 'A username is required for this mode.';
    Exit;
  end;
  domain := '';
  if ADlg.FDomainEdit.Visible then
    domain := Trim(ADlg.FDomainEdit.Text);

  pw := nil;
  key := nil;
  phrase := nil;
  try
    if mode = TAG_PASSWORD then
    begin
      authType := atPassword;
      pw := TakeSecret(ADlg.FPassEdit);
    end
    else
    begin
      authType := atSshKey;
      keyPath := Trim(ADlg.FKeyEdit.Text);
      if keyPath <> '' then
      begin
        if not LoadKeyFile(keyPath, key, AErr) then
          Exit;
      end
      else if not ADlg.FHasStoredKey then
      begin
        AErr := 'Pick a private key file.';
        Exit;
      end;
      phrase := TakeSecret(ADlg.FPhraseEdit);
    end;

    owned := IsOwnedCredential(AModel, ACurrentCredUuid);
    if owned then
    begin
      // secrets nil = inchanges: un champ laisse vide garde sa valeur
      AModel.UpdateCredential(ACurrentCredUuid, AConnName, authType,
        user, domain, '', pw, key, phrase);
      ACredUuid := ACurrentCredUuid;
    end
    else
      ACredUuid := AModel.CreateCredential(AConnName, authType,
        user, domain, '', pw, key, phrase);
    Result := True;
  finally
    pw.Free;
    key.Free;
    phrase.Free;
  end;
end;

function ShowNewConnectionDialog(AModel: TRshModel;
  const AParentUuid: string; AProtocol: TRshProtocol): string;
var
  dlg: TNodeDialog;
  port, tmo: Integer;
  credUuid, err: string;
  inheritCred: Boolean;
begin
  Result := '';
  case AProtocol of
    rpRdp: port := RDP_DEFAULT_PORT;
    rpVnc: port := VNC_DEFAULT_PORT;
  else
    port := SSH_DEFAULT_PORT;
  end;
  dlg := BuildConnectionDialog(AModel,
    'New ' + UpperCase(PROTOCOL_NAMES[AProtocol]) + ' Connection',
    '', '', port, 15, '', '', AProtocol, AParentUuid, True);
  try
    if not dlg.FInheritAvailable then
    begin
      dlg.FCredCombo.ItemIndex := dlg.FCredUuids.IndexOf(TAG_ASK);
      dlg.UpdateAuthRows;
    end;
    dlg.AddButtons('Create');
    ApplyUiFont(dlg);
    while dlg.ShowModal = mrOk do
    begin
      if not ReadInt(dlg.FPortEdit.Text, port) then
      begin
        ShowError('The port must be an integer.');
        Continue;
      end;
      if not ReadInt(dlg.FTimeoutEdit.Text, tmo) then
      begin
        ShowError('The timeout must be an integer.');
        Continue;
      end;
      AModel.BeginBatch;   // une seule transaction: le rollback purge le credential
      try
        if not ApplyCredential(AModel, dlg, Trim(dlg.FNameEdit.Text), '',
          credUuid, inheritCred, err) then
        begin
          AModel.RollbackBatch;
          ShowError(err);
          Continue;
        end;
        Result := AModel.CreateConnection(AParentUuid, dlg.FNameEdit.Text,
          AProtocol, dlg.FHostEdit.Text, port);
        AModel.UpdateConnection(Result, dlg.FHostEdit.Text, port,
          credUuid, tmo, inheritCred);
        if dlg.FDescEdit.Text <> '' then
          AModel.UpdateNodeDescription(Result, dlg.FDescEdit.Text);
        if SelectedJump(dlg) <> '' then
          AModel.SetJumpVia(Result, SelectedJump(dlg));
        if (dlg.FJumpOfferChk <> nil) and dlg.FJumpOfferChk.Checked
           and AModel.JumpHostOffersAvailable then
          AModel.SetJumpHostOffered(Result, True);
        if AProtocol = rpRdp then
          AModel.SetRdpGateway(Result, Trim(dlg.FGwHostEdit.Text),
            GwPortOf(dlg));
        if (AProtocol = rpVnc) and (dlg.FVncActualSizeChk <> nil) and
           dlg.FVncActualSizeChk.Checked then
          AModel.SetVncActualSize(Result, True);
        AModel.CommitBatch;
        Exit;
      except
        on E: Exception do
        begin
          AModel.RollbackBatch;
          Result := '';
          ShowError(E.Message);
        end;
      end;
    end;
  finally
    dlg.Free;
  end;
end;

function ShowConnectionProperties(AModel: TRshModel;
  const AUuid: string): Boolean;
var
  dlg: TNodeDialog;
  n: TRshNode;
  port, tmo: Integer;
  oldCred, credUuid, err: string;
  isRdp, inheritCred: Boolean;
  deps: Integer;
  gw: TRshRdpGateway;
begin
  Result := False;
  n := AModel.GetNode(AUuid);
  isRdp := n.Protocol = rpRdp;
  gw.Hostname := '';
  gw.Port := 0;
  if isRdp then
    gw := AModel.GetRdpGateway(AUuid);
  try
    oldCred := n.CredentialUuid;
    dlg := BuildConnectionDialog(AModel,
      'Properties — ' + n.DisplayName, n.DisplayName, n.Hostname,
      n.Port, n.ConnectTimeoutS, oldCred, n.Description, n.Protocol,
      n.ParentUuid, n.InheritCredential,
      gw.Hostname, gw.Port, AUuid, AModel.GetJumpVia(AUuid));
  finally
    n.Free;
  end;
  if dlg.FVncActualSizeChk <> nil then
    dlg.FVncActualSizeChk.Checked := AModel.GetVncActualSize(AUuid);
  try
    dlg.AddButtons('Save');
    ApplyUiFont(dlg);
    while dlg.ShowModal = mrOk do
    begin
      if not ReadInt(dlg.FPortEdit.Text, port) then
      begin
        ShowError('The port must be an integer.');
        Continue;
      end;
      if not ReadInt(dlg.FTimeoutEdit.Text, tmo) then
      begin
        ShowError('The timeout must be an integer.');
        Continue;
      end;
      // AVANT le batch: un modal tiendrait le verrou d'ecriture SQLite
      if (dlg.FJumpOfferChk <> nil) and (not dlg.FJumpOfferChk.Checked)
         and AModel.IsJumpHostOffered(AUuid) then
      begin
        deps := AModel.CountJumpDependents(AUuid);
        if (deps > 0) and (MessageDlg('Jump host', Format(
          '%d connection(s) still use this host as their jump host.' +
          LineEnding + 'They keep working; it just stops being offered when ' +
          'configuring other connections.' + LineEnding + LineEnding +
          'Stop offering it?', [deps]),
          mtConfirmation, [mbYes, mbCancel], 0) <> mrYes) then
          dlg.FJumpOfferChk.Checked := True;
      end;

      AModel.BeginBatch;
      try
        if not ApplyCredential(AModel, dlg, Trim(dlg.FNameEdit.Text), oldCred,
          credUuid, inheritCred, err) then
        begin
          AModel.RollbackBatch;
          ShowError(err);
          Continue;
        end;
        AModel.RenameNode(AUuid, dlg.FNameEdit.Text);
        AModel.UpdateConnection(AUuid, dlg.FHostEdit.Text, port,
          credUuid, tmo, inheritCred);
        AModel.UpdateNodeDescription(AUuid, dlg.FDescEdit.Text);
        AModel.SetJumpVia(AUuid, SelectedJump(dlg));
        if (dlg.FJumpOfferChk <> nil) and AModel.JumpHostOffersAvailable then
          AModel.SetJumpHostOffered(AUuid, dlg.FJumpOfferChk.Checked);
        if isRdp then
          AModel.SetRdpGateway(AUuid, Trim(dlg.FGwHostEdit.Text),
            GwPortOf(dlg));
        if dlg.FVncActualSizeChk <> nil then
          AModel.SetVncActualSize(AUuid, dlg.FVncActualSizeChk.Checked);
        if (oldCred <> '') and (oldCred <> credUuid) then
          AModel.PurgeOrphanCredentials;
        AModel.CommitBatch;
        Exit(True);
      except
        on E: Exception do
        begin
          AModel.RollbackBatch;
          ShowError(E.Message);
        end;
      end;
    end;
  finally
    dlg.Free;
  end;
end;

function ApplyFolderSection(AModel: TRshModel; ADlg: TNodeDialog;
  const AFolderUuid, AFolderName: string; ASecIdx: Integer;
  out AChanged: Boolean; out AErr: string): Boolean;
var
  sec: ^TFolderCredSection;
  mode, user, domain, keyPath, credName, newCred: string;
  pw, key, phrase: TSecureBytes;
  authType: TAuthType;
begin
  Result := False;
  AChanged := False;
  AErr := '';
  sec := @ADlg.FSections[ASecIdx];
  mode := ADlg.SectionTag(sec^);

  if mode = TAG_NONE then
  begin
    if sec^.CurCred <> '' then
    begin
      AModel.SetFolderCredential(AFolderUuid, sec^.Proto, '');
      AChanged := True;
    end;
    Exit(True);
  end;

  user := '';
  if sec^.UserEdit <> nil then
    user := Trim(sec^.UserEdit.Text);
  if (sec^.Proto <> rpVnc) and (user = '') then
  begin
    AErr := Format('%s: a username is required.',
      [UpperCase(PROTOCOL_NAMES[sec^.Proto])]);
    Exit;
  end;
  domain := '';
  if sec^.DomainEdit <> nil then
    domain := Trim(sec^.DomainEdit.Text);

  pw := nil;
  key := nil;
  phrase := nil;
  try
    if mode = TAG_PASSWORD then
    begin
      authType := atPassword;
      pw := TakeSecret(sec^.PassEdit);
      if (sec^.Proto = rpVnc) and (pw = nil) and
         not sec^.HasStoredPassword then
      begin
        AErr := 'VNC: enter the password.';
        Exit;
      end;
    end
    else
    begin
      authType := atSshKey;
      keyPath := Trim(sec^.KeyEdit.Text);
      if keyPath <> '' then
      begin
        if not LoadKeyFile(keyPath, key, AErr) then
          Exit;
      end
      else if not sec^.HasStoredKey then
      begin
        AErr := 'SSH: pick a private key file.';
        Exit;
      end;
      phrase := TakeSecret(sec^.PhraseEdit);
    end;

    credName := AFolderName + ' (' +
      UpperCase(PROTOCOL_NAMES[sec^.Proto]) + ')';
    if (sec^.CurCred <> '') and IsOwnedCredential(AModel, sec^.CurCred) then
    begin
      AModel.UpdateCredential(sec^.CurCred, credName, authType, user, domain,
        '', pw, key, phrase);
      newCred := sec^.CurCred;
    end
    else
      newCred := AModel.CreateCredential(credName, authType, user, domain,
        '', pw, key, phrase);
    if newCred <> sec^.CurCred then
    begin
      AModel.SetFolderCredential(AFolderUuid, sec^.Proto, newCred);
      AChanged := True;
    end;
    Result := True;
  finally
    pw.Free;
    key.Free;
    phrase.Free;
  end;
end;

function ShowGroupProperties(AModel: TRshModel; const AUuid: string): Boolean;
var
  dlg: TNodeDialog;
  n: TRshNode;
  p: TRshProtocol;
  i: Integer;
  cur, err: string;
  cred: TRshCredential;
  changed, anyChanged, ok: Boolean;
begin
  Result := False;
  n := AModel.GetNode(AUuid);
  try
    dlg := TNodeDialog.CreateShell(nil, 'Properties — ' + n.DisplayName);
    dlg.FNameEdit := dlg.AddEdit('Name:', n.DisplayName);
    dlg.AddRow('Description:');
    dlg.FDescEdit := TMemo.Create(dlg);
    dlg.FDescEdit.Parent := dlg;
    dlg.FDescEdit.SetBounds(EDIT_X, dlg.FY, EDIT_W, 72);
    dlg.FDescEdit.Text := n.Description;
    Inc(dlg.FY, 80);
  finally
    n.Free;
  end;
  try
    for p := rpSsh to rpVnc do   // folder_credentials n'accepte pas rpContainer
      dlg.AddFolderSection(p);
    for i := 0 to High(dlg.FSections) do
    begin
      cur := AModel.GetFolderCredential(AUuid, dlg.FSections[i].Proto);
      if cur = '' then Continue;
      dlg.FSections[i].CurCred := cur;
      try
        cred := AModel.GetCredential(cur);
      except
        on EModelError do Continue;
      end;
      try
        if dlg.FSections[i].UserEdit <> nil then
          dlg.FSections[i].UserEdit.Text := cred.Username;
        if dlg.FSections[i].DomainEdit <> nil then
          dlg.FSections[i].DomainEdit.Text := cred.DomainName;
        dlg.FSections[i].HasStoredPassword := cred.HasPassword;
        dlg.FSections[i].HasStoredKey := cred.HasPrivateKey;
        if (cred.AuthType = atSshKey) and
           (Length(dlg.FSections[i].Tags) > 2) then
          dlg.FSections[i].Combo.ItemIndex := 2
        else
          dlg.FSections[i].Combo.ItemIndex := 1;
      finally
        cred.Free;
      end;
    end;
    dlg.UpdateFolderSections;

    dlg.AddButtons('Save');
    ApplyUiFont(dlg);
    while dlg.ShowModal = mrOk do
    begin
      AModel.BeginBatch;
      try
        AModel.RenameNode(AUuid, dlg.FNameEdit.Text);
        AModel.UpdateNodeDescription(AUuid, dlg.FDescEdit.Text);
        anyChanged := False;
        ok := True;
        for i := 0 to High(dlg.FSections) do
        begin
          if not ApplyFolderSection(AModel, dlg, AUuid,
            Trim(dlg.FNameEdit.Text), i, changed, err) then
          begin
            ok := False;
            Break;
          end;
          anyChanged := anyChanged or changed;
        end;
        if not ok then
        begin
          AModel.RollbackBatch;
          ShowError(err);
          Continue;
        end;
        if anyChanged then
          AModel.PurgeOrphanCredentials;
        AModel.CommitBatch;
        Exit(True);
      except
        on E: Exception do
        begin
          AModel.RollbackBatch;
          ShowError(E.Message);
        end;
      end;
    end;
  finally
    dlg.Free;
  end;
end;

end.
