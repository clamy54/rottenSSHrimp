unit uPrefsDialog;

{$mode objfpc}{$H+}

// Police des sessions terminal. On ne propose que les Monaspace embarquees,
// jamais les polices systeme: meme rendu partout.

interface

// True = valide, preferences deja enregistrees ET appliquees au theme
function ShowTerminalFontDialog: Boolean;

implementation

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics, Dialogs,
  uFontEmbed, uTheme, uPreferences;

type
  TFontPrefsForm = class(TForm)
  private
    FFamily: TComboBox;
    FSize: TComboBox;
    FPreview: TLabel;
    procedure ChoiceChanged(Sender: TObject);
    procedure UpdatePreview;
  end;

procedure TFontPrefsForm.UpdatePreview;
var
  fam: string;
begin
  fam := '';
  if FFamily.ItemIndex >= 0 then
    fam := ResolveMonaspace(FFamily.Items[FFamily.ItemIndex]);
  if fam = '' then
    fam := MonaspaceDefaultFamily;
  FPreview.Font.Name := fam;
  FPreview.Font.Size := StrToIntDef(FSize.Text, PREF_TERM_FONT_SIZE_DEFAULT);
end;

procedure TFontPrefsForm.ChoiceChanged(Sender: TObject);
begin
  UpdatePreview;
end;

function ShowTerminalFontDialog: Boolean;
var
  f: TFontPrefsForm;
  lbl: TLabel;
  btnOk, btnCancel: TButton;
  i, sz: Integer;
  key, cur: string;
begin
  Result := False;
  if not MonaspaceAvailable then
  begin
    MessageDlg('Terminal Font',
      'The embedded Monaspace fonts are not available in this ' +
      'binary: the system default font is used instead.',
      mtInformation, [mbOK], 0);
    Exit;
  end;

  f := TFontPrefsForm.CreateNew(nil);
  try
    f.Caption := 'Terminal Font';
    f.BorderStyle := bsDialog;
    f.Position := poScreenCenter;
    f.ClientWidth := 440;

    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.SetBounds(16, 20, 90, 18);
    lbl.Caption := 'Family:';

    f.FFamily := TComboBox.Create(f);
    f.FFamily.Parent := f;
    f.FFamily.SetBounds(112, 16, 200, 26);
    f.FFamily.Style := csDropDownList;
    cur := PrefTerminalFontFamily;
    if cur = '' then
      cur := 'Neon';
    for i := 0 to MonaspaceFamilyCount - 1 do
    begin
      key := MonaspaceFamilyKey(i);
      // seulement les familles reellement chargees: proposer le reste ment
      if ResolveMonaspace(key) = '' then
        Continue;
      f.FFamily.Items.Add(key);
      if SameText(key, cur) then
        f.FFamily.ItemIndex := f.FFamily.Items.Count - 1;
    end;
    if f.FFamily.ItemIndex < 0 then
      f.FFamily.ItemIndex := 0;

    lbl := TLabel.Create(f);
    lbl.Parent := f;
    lbl.SetBounds(16, 58, 90, 18);
    lbl.Caption := 'Size:';

    f.FSize := TComboBox.Create(f);
    f.FSize.Parent := f;
    f.FSize.SetBounds(112, 54, 80, 26);
    f.FSize.Style := csDropDownList;
    for sz := PREF_TERM_FONT_SIZE_MIN to PREF_TERM_FONT_SIZE_MAX do
    begin
      f.FSize.Items.Add(IntToStr(sz));
      if sz = PrefTerminalFontSize then
        f.FSize.ItemIndex := f.FSize.Items.Count - 1;
    end;
    if f.FSize.ItemIndex < 0 then
      f.FSize.ItemIndex := f.FSize.Items.IndexOf(
        IntToStr(PREF_TERM_FONT_SIZE_DEFAULT));

    f.FPreview := TLabel.Create(f);
    f.FPreview.Parent := f;
    f.FPreview.AutoSize := False;
    f.FPreview.SetBounds(16, 96, 408, 62);
    f.FPreview.WordWrap := True;
    f.FPreview.Caption := 'ssh user@host  0O1lI  |{}[]()<>#$&@' + LineEnding +
      'drwxr-xr-x  1.234 KiB  2026-07-17';

    f.FFamily.OnChange := @f.ChoiceChanged;
    f.FSize.OnChange := @f.ChoiceChanged;

    btnOk := TButton.Create(f);
    btnOk.Parent := f;
    btnOk.SetBounds(244, 174, 88, 30);
    btnOk.Caption := 'OK';
    btnOk.ModalResult := mrOK;
    btnOk.Default := True;

    btnCancel := TButton.Create(f);
    btnCancel.Parent := f;
    btnCancel.SetBounds(336, 174, 88, 30);
    btnCancel.Caption := 'Cancel';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;

    f.ClientHeight := 220;
    ApplyUiFont(f);
    // ApplyUiFont vient d'ecraser la police de l'apercu: la reposer
    f.UpdatePreview;

    if f.ShowModal <> mrOK then
      Exit;

    if f.FFamily.ItemIndex >= 0 then
      PrefTerminalFontFamily := f.FFamily.Items[f.FFamily.ItemIndex];
    PrefTerminalFontSize := StrToIntDef(f.FSize.Text,
      PREF_TERM_FONT_SIZE_DEFAULT);
    ApplyPreferencesToTheme;
    SavePreferences;
    Result := True;
  finally
    f.Free;
  end;
end;

end.
