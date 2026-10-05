unit uPasswordDialog;

{$mode objfpc}{$H+}

// Le mot de passe sort en RawByteString UTF-8 que l'appelant DOIT effacer.

interface

function AskNewDocumentPassword(out APassword: RawByteString;
  const ATitle: string = 'New Document';
  const AOkCaption: string = 'Create'): Boolean;
function AskOpenPassword(const AFileName: string;
  out APassword: RawByteString): Boolean;
function AskCurrentPassword(out APassword: RawByteString): Boolean;
function AskUnlockPassword(out APassword: RawByteString): Boolean;

implementation

uses
  Classes, SysUtils, Math, Forms, Controls, StdCtrls, Graphics,
  uTheme, uThemedControls;

type
  TPasswordDialog = class(TForm)
  private
    FEdit: TEdit;
    FConfirm: TEdit;          // nil en mode saisie simple
    FGauge: TThemedGauge;
    FGaugeLabel: TLabel;
    FOkButton: TThemedButton;
    procedure EditsChanged(Sender: TObject);
    procedure UpdateState;
  public
    constructor CreateNewDoc(AOwner: TComponent;
      const ATitle, AOkCaption: string);
    constructor CreateSingle(AOwner: TComponent;
      const ATitle, APrompt, AOkCaption: string);
    procedure WipeFields;
  end;

// longueur x log2(classes presentes): grossier, et sans consequence
function EstimateBits(const S: string): Double;
var
  lower, upper, digit, other: Boolean;
  i: Integer;
  space: Double;
begin
  Result := 0;
  if S = '' then Exit;
  lower := False;
  upper := False;
  digit := False;
  other := False;
  for i := 1 to Length(S) do
    case S[i] of
      'a'..'z': lower := True;
      'A'..'Z': upper := True;
      '0'..'9': digit := True;
    else
      other := True;
    end;
  space := 0;
  if lower then space := space + 26;
  if upper then space := space + 26;
  if digit then space := space + 10;
  if other then space := space + 33;
  Result := Length(S) * Log2(space);
end;

procedure DescribeStrength(ABits: Double; out ALabel: string;
  out APercent: Integer);
begin
  APercent := Min(100, Round(ABits));
  if ABits < 40 then
    ALabel := 'Weak'
  else if ABits < 60 then
    ALabel := 'Fair'
  else if ABits < 80 then
    ALabel := 'Good'
  else
    ALabel := 'Excellent';
  ALabel := Format('%s (~%d bits)', [ALabel, Round(ABits)]);
end;

const
  DLG_W = 460;
  MARGIN = 16;

constructor TPasswordDialog.CreateNewDoc(AOwner: TComponent;
  const ATitle, AOkCaption: string);
var
  y: Integer;
  lbl, warn: TLabel;
  cancelBtn: TThemedButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Width := DLG_W;
  y := MARGIN;

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 18);
  lbl.Caption := 'Master password:';
  Inc(y, 22);

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 26);
  FEdit.EchoMode := emPassword;
  FEdit.OnChange := @EditsChanged;
  Inc(y, 34);

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 18);
  lbl.Caption := 'Confirm password:';
  Inc(y, 22);

  FConfirm := TEdit.Create(Self);
  FConfirm.Parent := Self;
  FConfirm.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 26);
  FConfirm.EchoMode := emPassword;
  FConfirm.OnChange := @EditsChanged;
  Inc(y, 34);

  FGauge := TThemedGauge.Create(Self);
  FGauge.Parent := Self;
  FGauge.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 12);
  FGauge.Max := 100;
  Inc(y, 16);

  FGaugeLabel := TLabel.Create(Self);
  FGaugeLabel.Parent := Self;
  FGaugeLabel.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 18);
  FGaugeLabel.Caption := 'Long passphrases are encouraged.';
  Inc(y, 26);

  warn := TLabel.Create(Self);
  warn.Parent := Self;
  // AutoSize AVANT WordWrap, sinon le texte est tronque au lieu de revenir a la ligne
  warn.AutoSize := False;
  warn.WordWrap := True;
  warn.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 66);
  warn.Caption := 'If you lose this password, the document is permanently' +
    ' unrecoverable. There is no recovery procedure.';
  Inc(y, 74);

  FOkButton := TThemedButton.Create(Self);
  FOkButton.Parent := Self;
  FOkButton.SetBounds(DLG_W - MARGIN - 110, y, 110, 30);
  FOkButton.Caption := AOkCaption;
  FOkButton.ModalResult := mrOk;
  FOkButton.Default := True;
  FOkButton.Enabled := False;

  cancelBtn := TThemedButton.Create(Self);
  cancelBtn.Parent := Self;
  cancelBtn.SetBounds(DLG_W - MARGIN - 230, y, 110, 30);
  cancelBtn.Caption := 'Cancel';
  cancelBtn.ModalResult := mrCancel;
  cancelBtn.Cancel := True;
  Inc(y, 30 + MARGIN);

  ClientHeight := y;
  ThemeDialog(Self);
  warn.Font.Color := clAccent;
end;

constructor TPasswordDialog.CreateSingle(AOwner: TComponent;
  const ATitle, APrompt, AOkCaption: string);
var
  y: Integer;
  lbl: TLabel;
  cancelBtn: TThemedButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Width := DLG_W;
  y := MARGIN;

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 18);
  lbl.Caption := APrompt;
  Inc(y, 22);

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.SetBounds(MARGIN, y, DLG_W - 2 * MARGIN, 26);
  FEdit.EchoMode := emPassword;
  FEdit.OnChange := @EditsChanged;
  Inc(y, 38);

  FOkButton := TThemedButton.Create(Self);
  FOkButton.Parent := Self;
  FOkButton.SetBounds(DLG_W - MARGIN - 110, y, 110, 30);
  FOkButton.Caption := AOkCaption;
  FOkButton.ModalResult := mrOk;
  FOkButton.Default := True;
  FOkButton.Enabled := False;

  cancelBtn := TThemedButton.Create(Self);
  cancelBtn.Parent := Self;
  cancelBtn.SetBounds(DLG_W - MARGIN - 230, y, 110, 30);
  cancelBtn.Caption := 'Cancel';
  cancelBtn.ModalResult := mrCancel;
  cancelBtn.Cancel := True;
  Inc(y, 30 + MARGIN);

  ClientHeight := y;
  ThemeDialog(Self);
end;

procedure TPasswordDialog.EditsChanged(Sender: TObject);
begin
  UpdateState;
end;

procedure TPasswordDialog.UpdateState;
var
  bits: Double;
  txt: string;
  pct: Integer;
begin
  if FConfirm = nil then
  begin
    FOkButton.Enabled := FEdit.Text <> '';
    Exit;
  end;
  bits := EstimateBits(FEdit.Text);
  DescribeStrength(bits, txt, pct);
  FGauge.Position := pct;
  if FEdit.Text = '' then
    FGaugeLabel.Caption := 'Long passphrases are encouraged.'
  else
    FGaugeLabel.Caption := txt;
  FOkButton.Enabled := (FEdit.Text <> '') and (FEdit.Text = FConfirm.Text);
end;

procedure TPasswordDialog.WipeFields;
begin
  // Meilleur effort: Text realloue et abandonne l'ancienne string sans la zeroer.
  FEdit.Text := StringOfChar('*', Length(FEdit.Text));
  FEdit.Text := '';
  if FConfirm <> nil then
  begin
    FConfirm.Text := StringOfChar('*', Length(FConfirm.Text));
    FConfirm.Text := '';
  end;
end;

function AskNewDocumentPassword(out APassword: RawByteString;
  const ATitle: string; const AOkCaption: string): Boolean;
var
  dlg: TPasswordDialog;
begin
  APassword := '';
  dlg := TPasswordDialog.CreateNewDoc(nil, ATitle, AOkCaption);
  try
    ApplyUiFont(dlg);
    Result := dlg.ShowModal = mrOk;
    if Result then
      APassword := RawByteString(UTF8Encode(dlg.FEdit.Text));
    dlg.WipeFields;
  finally
    dlg.Free;
  end;
end;

function AskSingle(const ATitle, APrompt, AOkCaption: string;
  out APassword: RawByteString): Boolean;
var
  dlg: TPasswordDialog;
begin
  APassword := '';
  dlg := TPasswordDialog.CreateSingle(nil, ATitle, APrompt, AOkCaption);
  try
    ApplyUiFont(dlg);
    Result := dlg.ShowModal = mrOk;
    if Result then
      APassword := RawByteString(UTF8Encode(dlg.FEdit.Text));
    dlg.WipeFields;
  finally
    dlg.Free;
  end;
end;

function AskOpenPassword(const AFileName: string;
  out APassword: RawByteString): Boolean;
begin
  Result := AskSingle('Open Document',
    'Master password for ' + ExtractFileName(AFileName) + ':', 'Open',
    APassword);
end;

function AskCurrentPassword(out APassword: RawByteString): Boolean;
begin
  Result := AskSingle('Change Master Password',
    'Current master password:', 'Continue', APassword);
end;

function AskUnlockPassword(out APassword: RawByteString): Boolean;
begin
  Result := AskSingle('Unlock Document',
    'Master password:', 'Unlock', APassword);
end;

end.
