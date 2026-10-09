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

const
  // au-dela, le chemin perd son milieu: le nom du fichier est a la fin
  PATH_MAX_LINES = 3;

function Utf8Step(const S: string; AIndex: Integer): Integer;
var
  b: Byte;
begin
  b := Byte(S[AIndex]);
  if b < $80 then Result := 1
  else if b < $E0 then Result := 2
  else if b < $F0 then Result := 3
  else Result := 4;
  if AIndex + Result - 1 > Length(S) then
    Result := Length(S) - AIndex + 1;
end;

// Un chemin n'a pas d'espace: sans coupure forcee le libelle le rogne.
// Coupe a l'espace, sinon apres un separateur, sinon ou ca casse.
function WrapToWidth(const S: string; AWidth: Integer;
  out ALines: Integer): string;
var
  cur: string;
  i, n, cut, k: Integer;
begin
  Result := '';
  ALines := 1;
  cur := '';
  i := 1;
  while i <= Length(S) do
  begin
    n := Utf8Step(S, i);
    if (cur <> '') and (UiTextWidth(cur + Copy(S, i, n)) > AWidth) then
    begin
      cut := 0;
      for k := Length(cur) downto 2 do
        if cur[k] = ' ' then
        begin
          cut := k;
          Break;
        end;
      if cut = 0 then
        for k := Length(cur) downto 2 do
          if cur[k] in ['/', '\'] then
          begin
            cut := k;
            Break;
          end;
      if cut = 0 then
        cut := Length(cur);
      Result := Result + TrimRight(Copy(cur, 1, cut)) + LineEnding;
      cur := Copy(cur, cut + 1, MaxInt);
      Inc(ALines);
    end;
    cur := cur + Copy(S, i, n);
    Inc(i, n);
  end;
  Result := Result + cur;
end;

function WrapPath(const APath: string; AWidth: Integer;
  out ALines: Integer): string;
var
  starts: array of Integer;
  i, cnt, keep: Integer;
begin
  Result := WrapToWidth(APath, AWidth, ALines);
  if ALines <= PATH_MAX_LINES then
    Exit;
  starts := nil;
  cnt := 0;
  i := 1;
  while i <= Length(APath) do
  begin
    if cnt = Length(starts) then
      SetLength(starts, 64 + cnt * 2);
    starts[cnt] := i;
    Inc(cnt);
    Inc(i, Utf8Step(APath, i));
  end;
  keep := cnt div 2;
  if keep > 200 then
    keep := 200;
  repeat
    keep := keep * 9 div 10;
    if keep < 4 then
      Break;
    Result := WrapToWidth(Copy(APath, 1, starts[keep] - 1) + '...' +
      Copy(APath, starts[cnt - keep], MaxInt), AWidth, ALines);
  until ALines <= PATH_MAX_LINES;
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
const
  MARGIN = 16;
var
  y, lineH, indent, avail: Integer;
  resumeBtn: TThemedButton;

  // Tout est MESURE: une hauteur fixe coupe la deuxieme ligne en deux.
  function AddLabel(const AText: string; ABold: Boolean; AColor: TColor;
    AIndent: Integer = 0; APath: Boolean = False): TLabel;
  var
    lines: Integer;
    shown: string;
  begin
    if APath then
      shown := WrapPath(AText, avail - AIndent, lines)
    else
      shown := WrapToWidth(AText, avail - AIndent, lines);
    Result := TLabel.Create(FForm);
    Result.Parent := FForm;
    Result.AutoSize := False;
    Result.WordWrap := False;
    Result.ShowAccelChar := False;
    Result.SetBounds(MARGIN + AIndent, y, avail - AIndent, lines * lineH + 2);
    Result.Caption := shown;
    Result.Font.Color := AColor;
    if ABold then Result.Font.Style := [fsBold];
    Inc(y, lines * lineH + 4);
  end;

  function AddBtn(const ACaption: string; ATag: Integer;
    ALeft, AWidth: Integer): TThemedButton;
  begin
    Result := TThemedButton.Create(FForm);
    Result.Parent := FForm;
    Result.Caption := ACaption;
    Result.Tag := ATag;
    Result.SetBounds(ALeft, y, AWidth, 28);
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
  FForm.ClientWidth := 620;
  FForm.Color := clAppBg;
  FForm.Font.Color := clAppFg;
  FForm.OnClose := @FormClose;

  avail := FForm.ClientWidth - 2 * MARGIN;
  lineH := UiTextHeight('Ag');
  indent := UiTextWidth('    ');

  y := 14;
  AddLabel('The destination already has a file with this name.', True,
    clAppFg);
  Inc(y, 8);
  AddLabel('Source:', False, clAppFg);
  AddLabel(DisplaySafeName(AInfo.SourcePath), False, clAppFg, indent, True);
  AddLabel('size ' + SizeText(AInfo.SourceSize) + ',  modified ' +
    StampText(AInfo.SourceTimeUtc), False, clTextSecondary, indent);
  Inc(y, 6);
  AddLabel('Target:', False, clAppFg);
  AddLabel(DisplaySafeName(AInfo.TargetPath), False, clAppFg, indent, True);
  AddLabel('size ' + SizeText(AInfo.TargetSize) + ',  modified ' +
    StampText(AInfo.TargetTimeUtc), False, clTextSecondary, indent);
  Inc(y, 10);
  if AInfo.ResumeAllowed then
    AddLabel(Format('A partial file from this session matches this source: ' +
      'resuming would continue at %s.', [FormatBytes(AInfo.ResumeOffset)]),
      False, clScpOk)
  else
    AddLabel('Resume is not available: ' + AInfo.ResumeRefusedWhy, False,
      clTextSecondary);

  Inc(y, 10);
  FApplyAll := TThemedCheck.Create(FForm);
  FApplyAll.Parent := FForm;
  FApplyAll.Left := MARGIN;
  FApplyAll.Top := y;
  FApplyAll.Width := avail;
  FApplyAll.Caption := 'Apply to all conflicts of this queue';
  FApplyAll.Font.Color := clAppFg;
  Inc(y, FApplyAll.Height + 18);

  AddBtn('Overwrite', Ord(cnOverwrite), 16, 100);
  AddBtn('Skip', Ord(cnSkip), 122, 80);
  AddBtn('Keep both', Ord(cnKeepBoth), 208, 100);
  resumeBtn := AddBtn('Resume', Ord(cnResume), 314, 90);
  // Desactive plutot qu'absent: la ligne au-dessus dit pourquoi.
  resumeBtn.Enabled := AInfo.ResumeAllowed;
  AddBtn('Cancel queue', Ord(cnCancelQueue), 410, 120);

  // ClientHeight EN DERNIER: peu fiable a la creation sous Cocoa
  FForm.ClientHeight := y + 28 + 14;

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
