unit uAuthPrompt;

{$mode objfpc}{$H+}

// Demande interactive d'identifiants, SSH et RDP: une connexion sans credential
// demande au lieu de refuser. Le mot de passe sort en TSecureBytes,
// mais l'effacement est du MEILLEUR EFFORT: la LCL garde ses propres copies.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, uSecureBytes;

// AUsername est entree ET sortie; AAskUsername a False = mot de passe seul (VNC).
function AskLogin(const ATitle, APrompt: string; AAskDomain: Boolean;
  var AUsername, ADomain: string; out APassword: TSecureBytes;
  AAskUsername: Boolean = True;
  const AOkCaption: string = 'Connect'): Boolean;

implementation

uses
  uTheme;

function AskLogin(const ATitle, APrompt: string; AAskDomain: Boolean;
  var AUsername, ADomain: string; out APassword: TSecureBytes;
  AAskUsername: Boolean; const AOkCaption: string): Boolean;
var
  f: TForm;
  lbl: TLabel;
  edUser, edDomain, edPass: TEdit;
  btnOk, btnCancel: TButton;
  raw: RawByteString;
  y: Integer;

  function AddField(const ACaption, AValue: string; AIsPassword: Boolean): TEdit;
  begin
    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.Left := 16;
    lbl.Top := y + 4;
    lbl.Width := 90;
    lbl.Caption := ACaption;
    Result := TEdit.Create(f);
    Result.Parent := f;
    Result.Left := 112;
    Result.Top := y;
    Result.Width := 292;
    Result.Text := AValue;
    if AIsPassword then
      Result.PasswordChar := '*';
    Inc(y, 32);
  end;

begin
  Result := False;
  APassword := nil;
  edDomain := nil;
  f := TForm.CreateNew(nil);
  try
    f.Caption := ATitle;
    f.BorderStyle := bsDialog;
    f.Position := poScreenCenter;
    f.ClientWidth := 420;

    y := 16;
    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.Left := 16;
    lbl.Top := y;
    // AutoSize recalcule la LARGEUR: un prompt long deborde au lieu de replier.
    lbl.AutoSize := False;
    lbl.Width := 388;
    lbl.Height := 54;
    lbl.WordWrap := True;
    lbl.Caption := APrompt;
    Inc(y, 64);

    edUser := nil;
    if AAskUsername then
      edUser := AddField('Username:', AUsername, False);
    if AAskDomain then
      edDomain := AddField('Domain:', ADomain, False);
    edPass := AddField('Password:', '', True);
    Inc(y, 8);

    btnOk := TButton.Create(f);
    btnOk.Parent := f;
    btnOk.Caption := AOkCaption;
    btnOk.ModalResult := mrOK;
    btnOk.Default := True;
    btnOk.Left := 196;
    btnOk.Top := y;
    btnOk.Width := 112;

    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Left := 316;
    btnCancel.Top := y;
    btnCancel.Width := 88;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    // Pas SetFocus: sur une forme pas encore affichee il leve 'Can not focus'.
    if (edUser <> nil) and (edUser.Text = '') then
      f.ActiveControl := edUser
    else
      f.ActiveControl := edPass;

    if f.ShowModal <> mrOK then
      Exit;

    if edUser <> nil then
      AUsername := Trim(edUser.Text);
    if edDomain <> nil then
      ADomain := Trim(edDomain.Text);

    raw := RawByteString(edPass.Text);
    try
      if raw <> '' then
        APassword := TSecureBytes.CreateFrom(raw[1], Length(raw))
      else
        APassword := TSecureBytes.Create(0);
      Result := True;
    finally
      if raw <> '' then
        FillChar(raw[1], Length(raw), 0);
      raw := '';
      edPass.Text := '';
    end;
  finally
    f.Free;
  end;
end;

end.
