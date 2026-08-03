unit uCrashRecoveryDialog;

{$mode objfpc}{$H+}

// Recuperation apres crash: les copies de travail orphelines, une action par
// element. Rien n'ecrase l'original -- TRshDocument.RecoverDocument rend un
// document sans chemin source, il n'a nulle part ou retomber.

interface

uses
  uCrashRecovery;

type
  TRecoveryChoice = (rcIgnore, rcRecover, rcSaveCopy, rcDelete);

function ShowCrashRecovery(const AItems: TRecoveryItems;
  out AIndex: Integer; out AChoice: TRecoveryChoice): Boolean;

implementation

uses
  SysUtils, Classes, Forms, Controls, StdCtrls, Buttons, Dialogs, uTheme,
  uVersion;

type
  TRecoveryForm = class(TForm)
  private
    FList: TListBox;
    FChoice: TRecoveryChoice;
    procedure RecoverClick(Sender: TObject);
    procedure SaveCopyClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure IgnoreClick(Sender: TObject);
  public
    constructor CreateWith(const AItems: TRecoveryItems);
    property Choice: TRecoveryChoice read FChoice;
    function SelectedIndex: Integer;
  end;

function HumanSize(ABytes: Int64): string;
begin
  if ABytes >= 1024 * 1024 then
    Result := Format('%.1f MiB', [ABytes / (1024 * 1024)])
  else if ABytes >= 1024 then
    Result := Format('%.0f KiB', [ABytes / 1024])
  else
    Result := Format('%d B', [ABytes]);
end;

constructor TRecoveryForm.CreateWith(const AItems: TRecoveryItems);
var
  info: TLabel;
  btnRec, btnSave, btnDel, btnIgn: TBitBtn;
  i: Integer;
  line: string;
begin
  inherited CreateNew(nil, 0);
  Caption := RSSH_APP_NAME + ' — Recovery';
  Position := poScreenCenter;
  BorderStyle := bsDialog;
  Width := 560;
  Height := 340;

  info := TLabel.Create(Self);
  info.Parent := Self;
  info.SetBounds(16, 12, Width - 32, 60);
  info.AutoSize := False;
  info.WordWrap := True;
  info.Caption := 'A previous session did not close normally. The following ' +
    'documents can be recovered. Recovery never overwrites the original — ' +
    'it opens as an untitled document you can save under a new name.';

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.SetBounds(16, 78, Width - 32, 162);
  for i := 0 to High(AItems) do
  begin
    line := RecoveryDisplayName(AItems[i]) + '   —   ' +
      FormatDateTime('yyyy-mm-dd hh:nn', AItems[i].Modified) + ', ' +
      HumanSize(AItems[i].SizeBytes);
    FList.Items.Add(line);
  end;
  if FList.Items.Count > 0 then
    FList.ItemIndex := 0;

  btnRec := TBitBtn.Create(Self);
  btnRec.Parent := Self;
  btnRec.SetBounds(16, Height - 48, 110, 30);
  btnRec.Caption := 'Recover';
  btnRec.Default := True;
  btnRec.OnClick := @RecoverClick;

  btnSave := TBitBtn.Create(Self);
  btnSave.Parent := Self;
  btnSave.SetBounds(134, Height - 48, 130, 30);
  btnSave.Caption := 'Save a Copy…';
  btnSave.OnClick := @SaveCopyClick;

  btnDel := TBitBtn.Create(Self);
  btnDel.Parent := Self;
  btnDel.SetBounds(272, Height - 48, 90, 30);
  btnDel.Caption := 'Delete';
  btnDel.OnClick := @DeleteClick;

  btnIgn := TBitBtn.Create(Self);
  btnIgn.Parent := Self;
  btnIgn.SetBounds(Width - 116, Height - 48, 100, 30);
  btnIgn.Caption := 'Ignore';
  btnIgn.Cancel := True;
  btnIgn.OnClick := @IgnoreClick;

  FChoice := rcIgnore;
end;

function TRecoveryForm.SelectedIndex: Integer;
begin
  Result := FList.ItemIndex;
end;

procedure TRecoveryForm.RecoverClick(Sender: TObject);
begin
  if FList.ItemIndex < 0 then Exit;
  FChoice := rcRecover;
  ModalResult := mrOk;
end;

procedure TRecoveryForm.SaveCopyClick(Sender: TObject);
begin
  if FList.ItemIndex < 0 then Exit;
  FChoice := rcSaveCopy;
  ModalResult := mrOk;
end;

procedure TRecoveryForm.DeleteClick(Sender: TObject);
begin
  if FList.ItemIndex < 0 then Exit;
  if MessageDlg(RSSH_APP_NAME, 'Delete this recovery permanently?',
    mtConfirmation, [mbYes, mbCancel], 0) <> mrYes then Exit;
  FChoice := rcDelete;
  ModalResult := mrOk;
end;

procedure TRecoveryForm.IgnoreClick(Sender: TObject);
begin
  FChoice := rcIgnore;
  ModalResult := mrCancel;
end;

function ShowCrashRecovery(const AItems: TRecoveryItems;
  out AIndex: Integer; out AChoice: TRecoveryChoice): Boolean;
var
  f: TRecoveryForm;
begin
  Result := False;
  AIndex := -1;
  AChoice := rcIgnore;
  if Length(AItems) = 0 then Exit;
  f := TRecoveryForm.CreateWith(AItems);
  try
    ApplyUiFont(f);
    if f.ShowModal = mrOk then
    begin
      AIndex := f.SelectedIndex;
      AChoice := f.Choice;
      Result := (AIndex >= 0) and (AChoice <> rcIgnore);
    end;
  finally
    f.Free;
  end;
end;

end.
