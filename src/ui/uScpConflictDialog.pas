{ Thread UI, appeles par le transport qui attend la reponse.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpConflictDialog;

{$mode objfpc}{$H+}

interface

uses
  uRtMessage, Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls, Graphics, Dialogs,
  uTransferQueue, uScpPaths, uTheme;

// Fermer vaut cnSkip: ne rien decider n'ecrase jamais rien.
function AskTransferConflict(const AInfo: TConflictInfo): TConflictDecision;

// True: repli non atomique accepte en connaissance de cause. Defaut: False.
function AskNonAtomicReplace(const ATargetPath: string): Boolean;

implementation

uses
  uThemedControls, DateUtils;

function StampText(AUnixUtc: Int64): string;
begin
  if AUnixUtc <= 0 then Exit('unknown');
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    UniversalTimeToLocal(UnixToDateTime(AUnixUtc)));
end;

function SizeText(ASize: Int64): string;
begin
  if ASize < 0 then Exit('unknown');
  Result := Format('%s (%d bytes)', [FormatBytes(ASize), ASize]);
end;

type
  TConflictForm = class
  private
    FForm: TForm;
    FDecision: TConflictDecision;
    FApplyAll: TThemedCheck;
    procedure BtnClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor Create(const AInfo: TConflictInfo);
    destructor Destroy; override;
    function Run: TConflictDecision;
  end;

constructor TConflictForm.Create(const AInfo: TConflictInfo);
var
  y: Integer;
  resumeBtn: TThemedButton;

  function AddLabel(const AText: string; ABold: Boolean;
    AColor: TColor): TLabel;
  begin
    Result := TLabel.Create(FForm);
    Result.Parent := FForm;
    Result.Left := 16;
    Result.Top := y;
    Result.Width := FForm.ClientWidth - 32;
    Result.AutoSize := False;
    Result.WordWrap := True;
    Result.Height := 17;
    Result.Caption := AText;
    Result.Font.Color := AColor;
    if ABold then Result.Font.Style := [fsBold];
    Inc(y, 19);
  end;

  function AddBtn(const ACaption: string; ATag: Integer;
    ALeft, AWidth: Integer): TThemedButton;
  begin
    Result := TThemedButton.Create(FForm);
    Result.Parent := FForm;
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.Left := ALeft;
    Result.Width := AWidth;
    Result.Height := 28;
    Result.Top := FForm.ClientHeight - 40;
    Result.Anchors := [akLeft, akBottom];
    Result.OnClick := @BtnClick;
  end;

begin
  inherited Create;
  FDecision.Action := cnSkip;
  FDecision.ApplyToAll := False;

  FForm := TForm.CreateNew(nil);
  FForm.Caption := 'File already exists';
  FForm.Position := poScreenCenter;
  FForm.BorderStyle := bsDialog;
  FForm.Width := 620;
  FForm.Height := 330;
  FForm.Color := clAppBg;
  FForm.Font.Color := clAppFg;
  FForm.OnClose := @FormClose;

  y := 14;
  AddLabel('The destination already has a file with this name.', True,
    clAppFg);
  Inc(y, 6);
  AddLabel('Source: ' + DisplaySafeName(AInfo.SourcePath), False, clAppFg);
  AddLabel('    size ' + SizeText(AInfo.SourceSize) +
    ',  modified ' + StampText(AInfo.SourceTimeUtc), False, clTextSecondary);
  Inc(y, 4);
  AddLabel('Target: ' + DisplaySafeName(AInfo.TargetPath), False, clAppFg);
  AddLabel('    size ' + SizeText(AInfo.TargetSize) +
    ',  modified ' + StampText(AInfo.TargetTimeUtc), False, clTextSecondary);
  Inc(y, 8);
  if AInfo.ResumeAllowed then
    AddLabel(Format('A partial file from this session matches this source: ' +
      'resuming would continue at %s.', [FormatBytes(AInfo.ResumeOffset)]),
      False, clScpOk)
  else
    AddLabel('Resume is not available: ' + AInfo.ResumeRefusedWhy, False,
      clTextSecondary);

  Inc(y, 8);
  FApplyAll := TThemedCheck.Create(FForm);
  FApplyAll.Parent := FForm;
  FApplyAll.Left := 16;
  FApplyAll.Top := y;
  FApplyAll.Width := FForm.ClientWidth - 32;
  FApplyAll.Caption := 'Apply to all conflicts of this queue';
  FApplyAll.Font.Color := clAppFg;

  AddBtn('Overwrite', Ord(cnOverwrite), 16, 100);
  AddBtn('Skip', Ord(cnSkip), 122, 80);
  AddBtn('Keep both', Ord(cnKeepBoth), 208, 100);
  resumeBtn := AddBtn('Resume', Ord(cnResume), 314, 90);
  // Desactive plutot qu'absent: la ligne au-dessus dit pourquoi.
  resumeBtn.Enabled := AInfo.ResumeAllowed;
  AddBtn('Cancel queue', Ord(cnCancelQueue), 410, 120);

  ApplyUiFont(FForm);
  DialogKeys(FForm);
end;

destructor TConflictForm.Destroy;
begin
  FForm.Free;
  inherited Destroy;
end;

procedure TConflictForm.BtnClick(Sender: TObject);
begin
  FDecision.Action := TConflictAction(TThemedButton(Sender).Tag);
  FDecision.ApplyToAll := FApplyAll.Checked;
  FForm.ModalResult := mrOK;
end;

procedure TConflictForm.FormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  // Fermer sans choisir n'est pas un accord.
  if FForm.ModalResult <> mrOK then
  begin
    FDecision.Action := cnSkip;
    FDecision.ApplyToAll := False;
  end;
  CloseAction := caHide;
end;

function TConflictForm.Run: TConflictDecision;
begin
  FForm.ShowModal;
  Result := FDecision;
end;

function AskTransferConflict(const AInfo: TConflictInfo): TConflictDecision;
var
  dlg: TConflictForm;
begin
  dlg := TConflictForm.Create(AInfo);
  try
    Result := dlg.Run;
  finally
    dlg.Free;
  end;
end;

function AskNonAtomicReplace(const ATargetPath: string): Boolean;
begin
  Result := RtQuestionDlg('Atomic replacement not available',
    Format('%s cannot be replaced atomically here.' + LineEnding + LineEnding +
      'Continuing means deleting the existing file first and then renaming ' +
      'the new one into place. If the connection drops in between, the old ' +
      'file is gone and the new one is not there yet.' + LineEnding +
      LineEnding +
      'The transferred copy is complete and waiting in a temporary file, so ' +
      'declining leaves the existing file untouched.',
      [DisplaySafeName(ATargetPath)]),
    mtWarning,
    [mrNo, 'Keep the existing file', 'IsDefault',
     mrYes, 'Replace anyway'], 0) = mrYes;
end;

end.
