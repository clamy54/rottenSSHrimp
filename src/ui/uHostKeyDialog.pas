unit uHostKeyDialog;

{$mode objfpc}{$H+}

// Dialogues de confiance de cle d'hote. Cle modifiee = alerte MITM, Cancel par
// defaut, remplacement seulement apres confirmation renforcee.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, Dialogs, LCLType,
  uSshTransport;

function AskUnknownHostKey(const AInfo: TSshHostKeyInfo): TSshHostKeyDecision;

// Rend hkdReject sauf remplacement explicite.
function AskChangedHostKey(const AInfo: TSshHostKeyInfo): TSshHostKeyDecision;

// Un seul dialogue pour N hotes jamais vus. Appele AVANT le handshake: pas
// d'empreintes a montrer. Une cle CHANGEE n'y passe jamais.
function AskBulkUnknownHostKeys(const AHosts: array of string;
  out ADecision: TSshHostKeyDecision; out ACancelled: Boolean): Boolean;

implementation

uses
  uTheme;

function AskBulkUnknownHostKeys(const AHosts: array of string;
  out ADecision: TSshHostKeyDecision; out ACancelled: Boolean): Boolean;
var
  f: TForm;
  lblTitle, lblWarn: TLabel;
  lst: TMemo;
  btnSaveAll, btnOnceAll, btnEach, btnCancel: TButton;
  i, y: Integer;
begin
  Result := False;
  ADecision := hkdReject;
  ACancelled := False;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Unknown Host Keys';
    f.Position := poScreenCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 560;

    y := 16;
    lblTitle := TLabel.Create(f);
    lblTitle.Parent := f;
    lblTitle.Left := 16;
    lblTitle.Top := y;
    lblTitle.Width := 528;
    lblTitle.WordWrap := True;
    lblTitle.AutoSize := False;
    lblTitle.Height := 34;
    lblTitle.Caption := Format('%d hosts in this broadcast have never been ' +
      'connected to before.', [Length(AHosts)]);
    Inc(y, 40);

    lst := TMemo.Create(f);
    lst.Parent := f;
    lst.Left := 16;
    lst.Top := y;
    lst.Width := 528;
    lst.Height := 140;
    lst.ReadOnly := True;
    lst.ScrollBars := ssAutoVertical;
    for i := Low(AHosts) to High(AHosts) do
      lst.Lines.Add(AHosts[i]);
    Inc(y, 150);

    lblWarn := TLabel.Create(f);
    lblWarn.Parent := f;
    lblWarn.Left := 16;
    lblWarn.Top := y;
    lblWarn.Width := 528;
    lblWarn.WordWrap := True;
    lblWarn.AutoSize := False;
    lblWarn.Height := 48;
    lblWarn.Caption := 'Accepting as a batch trusts each key on first sight, ' +
      'without reviewing its fingerprint. A host key that CHANGED is never ' +
      'covered by this choice: it is always confirmed individually.';
    Inc(y, 56);

    // par defaut: le choix le moins engageant montre chaque empreinte
    btnEach := TButton.Create(f);
    btnEach.Parent := f;
    btnEach.Caption := 'Ask for each host';
    btnEach.ModalResult := mrNo;
    btnEach.Default := True;
    btnEach.Left := 16;
    btnEach.Top := y;
    btnEach.Width := 150;

    btnOnceAll := TButton.Create(f);
    btnOnceAll.Parent := f;
    btnOnceAll.Caption := 'Trust once, all';
    btnOnceAll.ModalResult := mrYes;
    btnOnceAll.Left := 174;
    btnOnceAll.Top := y;
    btnOnceAll.Width := 140;

    btnSaveAll := TButton.Create(f);
    btnSaveAll.Parent := f;
    btnSaveAll.Caption := 'Trust and save, all';
    btnSaveAll.ModalResult := mrAll;
    btnSaveAll.Left := 322;
    btnSaveAll.Top := y;
    btnSaveAll.Width := 160;

    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Left := 490;
    btnCancel.Top := y;
    btnCancel.Width := 54;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    case f.ShowModal of
      mrYes:
        begin
          ADecision := hkdAcceptOnce;
          Result := True;
        end;
      mrAll:
        begin
          ADecision := hkdAcceptAndSave;
          Result := True;
        end;
      mrNo: ;   // hote par hote
    else
      ACancelled := True;
    end;
  finally
    f.Free;
  end;
end;

function AskUnknownHostKey(const AInfo: TSshHostKeyInfo): TSshHostKeyDecision;
var
  f: TForm;
  lblTitle, lblType, lblFp: TLabel;
  btnOnce, btnSave, btnCancel: TButton;
  y: Integer;
begin
  Result := hkdReject;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Unknown Host Key';
    f.Position := poScreenCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 560;

    y := 16;
    lblTitle := TLabel.Create(f);
    lblTitle.Parent := f;
    lblTitle.Left := 16;
    lblTitle.Top := y;
    lblTitle.Width := 528;
    lblTitle.WordWrap := True;
    lblTitle.Caption := Format(
      'The host key for %s:%d is unknown.', [AInfo.Host, AInfo.Port]);
    Inc(y, 44);

    lblType := TLabel.Create(f);
    lblType.Parent := f;
    lblType.Left := 16;
    lblType.Top := y;
    lblType.Caption := 'Type: ' + AInfo.KeyType;
    Inc(y, 24);

    lblFp := TLabel.Create(f);
    lblFp.Parent := f;
    lblFp.Left := 16;
    lblFp.Top := y;
    lblFp.Width := 528;
    lblFp.WordWrap := True;
    lblFp.Caption := AInfo.Fingerprint;
    Inc(y, 40);

    // par defaut la moins engageante des deux acceptations
    btnOnce := TButton.Create(f);
    btnOnce.Parent := f;
    btnOnce.Caption := 'Trust once';
    btnOnce.ModalResult := mrYes;
    btnOnce.Default := True;
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

    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Left := 444;
    btnCancel.Top := y;
    btnCancel.Width := 100;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    case f.ShowModal of
      mrYes: Result := hkdAcceptOnce;
      mrAll: Result := hkdAcceptAndSave;
    else
      Result := hkdReject;
    end;
  finally
    f.Free;
  end;
end;

function ShowChangedDetails(const AInfo: TSshHostKeyInfo): TSshHostKeyDecision;
var
  f: TForm;
  lbl, lblOld, lblNew: TLabel;
  memo: TMemo;
  btnReplace, btnCancel: TButton;
  y: Integer;
  typed: string;
begin
  Result := hkdReject;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Host Key Details';
    f.Position := poScreenCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 620;

    y := 16;
    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.Left := 16;
    lbl.Top := y;
    lbl.Width := 588;
    lbl.WordWrap := True;
    lbl.Caption := Format('%s:%d — key type %s',
      [AInfo.Host, AInfo.Port, AInfo.KeyType]);
    Inc(y, 32);

    lblOld := TLabel.Create(f);
    lblOld.Parent := f;
    lblOld.Left := 16;
    lblOld.Top := y;
    lblOld.Caption := 'Previously trusted:';
    Inc(y, 20);

    memo := TMemo.Create(f);
    memo.Parent := f;
    memo.Left := 16;
    memo.Top := y;
    memo.Width := 588;
    memo.Height := 44;
    memo.ReadOnly := True;
    memo.Lines.Text := AInfo.KnownFingerprint;
    Inc(y, 56);

    lblNew := TLabel.Create(f);
    lblNew.Parent := f;
    lblNew.Left := 16;
    lblNew.Top := y;
    lblNew.Caption := 'Offered now:';
    Inc(y, 20);

    memo := TMemo.Create(f);
    memo.Parent := f;
    memo.Left := 16;
    memo.Top := y;
    memo.Width := 588;
    memo.Height := 44;
    memo.ReadOnly := True;
    memo.Lines.Text := AInfo.Fingerprint;
    Inc(y, 60);

    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.Left := 16;
    lbl.Top := y;
    lbl.Width := 588;
    lbl.WordWrap := True;
    lbl.Caption := 'Only replace the stored key if you know why it changed ' +
      '(server rebuilt, key rotated). Otherwise this is an attack.';
    Inc(y, 44);

    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Default := True;   // l'action sure reste par defaut
    btnCancel.Left := 504;
    btnCancel.Top := y;
    btnCancel.Width := 100;

    btnReplace := TButton.Create(f);
    btnReplace.Parent := f;
    btnReplace.Caption := 'Replace stored key…';
    btnReplace.ModalResult := mrYes;
    btnReplace.Left := 16;
    btnReplace.Top := y;
    btnReplace.Width := 180;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    if f.ShowModal <> mrYes then
      Exit;
  finally
    f.Free;
  end;

  // saisie explicite, jamais un simple clic
  typed := '';
  if not InputQuery('Replace Host Key',
    Format('Type REPLACE to trust the new key for %s:%d.',
      [AInfo.Host, AInfo.Port]), typed) then
    Exit;
  if UpperCase(Trim(typed)) = 'REPLACE' then
    Result := hkdAcceptAndSave;
end;

function AskChangedHostKey(const AInfo: TSshHostKeyInfo): TSshHostKeyDecision;
var
  f: TForm;
  lblWarn, lblExpl: TLabel;
  btnCancel, btnDetails: TButton;
  y: Integer;
begin
  Result := hkdReject;
  f := TForm.CreateNew(nil);
  try
    f.Caption := 'Host Key Changed';
    f.Position := poScreenCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 520;

    y := 16;
    lblWarn := TLabel.Create(f);
    lblWarn.Parent := f;
    lblWarn.Left := 16;
    lblWarn.Top := y;
    lblWarn.Width := 488;
    lblWarn.WordWrap := True;
    lblWarn.Font.Style := [fsBold];
    lblWarn.Font.Size := 13;
    lblWarn.Caption := 'WARNING: The host key has changed.';
    Inc(y, 36);

    lblExpl := TLabel.Create(f);
    lblExpl.Parent := f;
    lblExpl.Left := 16;
    lblExpl.Top := y;
    lblExpl.Width := 488;
    lblExpl.WordWrap := True;
    lblExpl.Caption := 'This may indicate a man-in-the-middle attack.'#13#10 +
      Format('Host: %s:%d', [AInfo.Host, AInfo.Port]);
    Inc(y, 52);

    // Cancel par defaut: le remplacement n'est jamais a portee d'un Entree reflexe
    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;
    btnCancel.Default := True;
    btnCancel.Left := 16;
    btnCancel.Top := y;
    btnCancel.Width := 110;

    btnDetails := TButton.Create(f);
    btnDetails.Parent := f;
    btnDetails.Caption := 'View details';
    btnDetails.ModalResult := mrYes;
    btnDetails.Left := 134;
    btnDetails.Top := y;
    btnDetails.Width := 130;

    f.ClientHeight := y + 32 + 16;
    ApplyUiFont(f);

    if f.ShowModal <> mrYes then
      Exit;
  finally
    f.Free;
  end;

  Result := ShowChangedDetails(AInfo);
end;

end.
