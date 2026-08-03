unit uRdpCertDialog;

{$mode objfpc}{$H+}

// Confiance d'un certificat RDP. Confiance ponctuelle ou pinning explicite,
// mais AUCUN « toujours ignorer toutes les erreurs »: chaque decision porte
// sur un seul hote, jamais en bloc.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, Dialogs, LCLType,
  uRdpTransport;

// rcdReject sauf action explicite de l'utilisateur
function AskRdpCertificate(const AInfo: TRdpCertInfo): TRdpCertDecision;

implementation

uses
  uTheme;

function AskRdpCertificate(const AInfo: TRdpCertInfo): TRdpCertDecision;
var
  f: TForm;
  lblTitle, lblWarn: TLabel;
  memo: TMemo;
  btnOnce, btnSave, btnCancel: TButton;
  y: Integer;
  details: TStringList;
  problems: string;
begin
  Result := rcdReject;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Verify RDP Certificate';
    f.Position := poScreenCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 620;

    y := 16;
    lblTitle := TLabel.Create(f);
    lblTitle.Parent := f;
    lblTitle.Left := 16;
    lblTitle.Top := y;
    // AutoSize:=False AVANT WordWrap: sous Win32 un label autosize s'elargit
    // pour tenir sur UNE ligne et sort de la fenetre. macOS tolerait.
    lblTitle.AutoSize := False;
    lblTitle.Width := 588;
    lblTitle.Height := 36;
    lblTitle.WordWrap := True;
    if AInfo.Gateway then
      lblTitle.Caption := Format(
        'The gateway %s:%d presented a certificate that is not trusted.',
        [AInfo.Host, AInfo.Port])
    else
      lblTitle.Caption := Format(
        'The host %s:%d presented a certificate that is not trusted.',
        [AInfo.Host, AInfo.Port]);
    Inc(y, 40);

    problems := '';
    if AInfo.Changed then
      problems := problems +
        'The certificate has CHANGED since the last connection. ' +
        'This may indicate a man-in-the-middle attack.';
    if AInfo.Mismatch then
    begin
      if problems <> '' then
        problems := problems + LineEnding;
      problems := problems +
        Format('The certificate name does not match "%s".', [AInfo.Host]);
    end;
    if problems <> '' then
    begin
      lblWarn := TLabel.Create(f);
      lblWarn.Parent := f;
      lblWarn.Left := 16;
      lblWarn.Top := y;
      lblWarn.AutoSize := False;   // idem lblTitle
      lblWarn.Width := 588;
      lblWarn.Height := 44;
      lblWarn.WordWrap := True;
      lblWarn.Font.Style := [fsBold];
      lblWarn.Caption := problems;
      Inc(y, 48);
    end;

    details := TStringList.Create;
    try
      details.Add('Subject:     ' + AInfo.Subject);
      details.Add('Issuer:      ' + AInfo.Issuer);
      details.Add('Common name: ' + AInfo.CommonName);
      details.Add('');
      details.Add('SHA-256 fingerprint:');
      details.Add(AInfo.Fingerprint);

      memo := TMemo.Create(f);
      memo.Parent := f;
      memo.Left := 16;
      memo.Top := y;
      memo.Width := 588;
      memo.Height := 130;
      memo.ReadOnly := True;
      memo.ScrollBars := ssAutoVertical;
      memo.WordWrap := False;
      memo.Lines.Assign(details);
    finally
      details.Free;
    end;
    Inc(y, 146);

    // Cancel par defaut: un Entree reflexe ne doit pas accepter le certificat
    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Default := True;
    btnCancel.Left := 504;
    btnCancel.Top := y;
    btnCancel.Width := 100;

    btnOnce := TButton.Create(f);
    btnOnce.Parent := f;
    btnOnce.Caption := 'Trust once';
    btnOnce.ModalResult := mrYes;
    btnOnce.Left := 16;
    btnOnce.Top := y;
    btnOnce.Width := 130;

    btnSave := TButton.Create(f);
    btnSave.Parent := f;
    btnSave.Caption := 'Trust and save';
    btnSave.ModalResult := mrAll;
    btnSave.Left := 154;
    btnSave.Top := y;
    btnSave.Width := 150;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    case f.ShowModal of
      mrYes: Result := rcdAcceptOnce;
      mrAll: Result := rcdAcceptAndSave;
    else
      Result := rcdReject;
    end;
  finally
    f.Free;
  end;
end;

end.
