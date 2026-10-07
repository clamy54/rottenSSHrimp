unit uAuthPrompt;

{$mode objfpc}{$H+}

// Effacement du mot de passe au MEILLEUR EFFORT: la LCL garde ses copies.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, uSecureBytes;

// AUsername est entree ET sortie; AAskUsername a False = mot de passe seul (VNC).
function AskLogin(const ATitle, APrompt: string; AAskDomain: Boolean;
  var AUsername, ADomain: string; out APassword: TSecureBytes;
  AAskUsername: Boolean = True;
  const AOkCaption: string = 'Connect'): Boolean;

function AskSecret(const APrompt: string; out ASecret: TSecureBytes): Boolean;

implementation

uses
  uTheme, uThemedControls, uRtSecretEdit;

function AskSecret(const APrompt: string; out ASecret: TSecureBytes): Boolean;
var
  f: TForm;
  lbl: TLabel;
  ed: TRtSecretEdit;
  btnOk, btnCancel: TThemedButton;
  raw: RawByteString;
begin
  Result := False;
  ASecret := nil;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Authentication';
    f.BorderStyle := bsDialog;
    f.Position := poScreenCenter;
    f.ClientWidth := 420;

    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.Left := 16;
    lbl.Top := 16;
    lbl.Width := 388;
    lbl.WordWrap := True;
    lbl.Caption := APrompt;

    ed := TRtSecretEdit.Create(f);
    ed.Parent := f;
    ed.Left := 16;
    ed.Top := 52;
    ed.Width := 388;
    ed.Height := 26;

    btnOk := TThemedButton.Create(f);
    btnOk.Parent := f;
    btnOk.Caption := 'OK';
    btnOk.ModalResult := mrOK;
    btnOk.Default := True;
    btnOk.Left := 224;
    btnOk.Top := 92;
    btnOk.Width := 88;

    btnCancel := TThemedButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Left := 316;
    btnCancel.Top := 92;
    btnCancel.Width := 88;

    f.ClientHeight := 140;
    ThemeDialog(f);

    if f.ShowModal <> mrOK then
      Exit;
    ed.GetSecret(raw);
    try
      if raw = '' then
        Exit;
      ASecret := TSecureBytes.CreateFrom(raw[1], Length(raw));
      Result := True;
    finally
      RtWipeSecret(raw);
      ed.Wipe;
    end;
  finally
    f.Free;
  end;
end;


function AskLogin(const ATitle, APrompt: string; AAskDomain: Boolean;
  var AUsername, ADomain: string; out APassword: TSecureBytes;
  AAskUsername: Boolean; const AOkCaption: string): Boolean;
var
  f: TForm;
  lbl: TLabel;
  edUser, edDomain: TEdit;
  edPass: TRtSecretEdit;
  btnOk, btnCancel: TThemedButton;
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
    if AIsPassword then
      Result := TRtSecretEdit.Create(f)
    else
      Result := TEdit.Create(f);
    Result.Parent := f;
    Result.Left := 112;
    Result.Top := y;
    Result.Width := 292;
    Result.Height := 26;
    Result.Text := AValue;
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
    // AutoSize recalcule la LARGEUR: un prompt long deborde au lieu de replier
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
    edPass := TRtSecretEdit(AddField('Password:', '', True));
    Inc(y, 8);

    btnOk := TThemedButton.Create(f);
    btnOk.Parent := f;
    btnOk.Caption := AOkCaption;
    btnOk.ModalResult := mrOK;
    btnOk.Default := True;
    btnOk.Left := 196;
    btnOk.Top := y;
    btnOk.Width := 112;

    btnCancel := TThemedButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Left := 316;
    btnCancel.Top := y;
    btnCancel.Width := 88;

    f.ClientHeight := y + 32 + 16;
    ThemeDialog(f);

    // Pas SetFocus: forme pas encore affichee = 'Can not focus'
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

    edPass.GetSecret(raw);
    try
      if raw <> '' then
        APassword := TSecureBytes.CreateFrom(raw[1], Length(raw))
      else
        APassword := TSecureBytes.Create(0);
      Result := True;
    finally
      RtWipeSecret(raw);
      edPass.Wipe;
    end;
  finally
    f.Free;
  end;
end;

end.
