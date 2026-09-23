{ Fenetre « Properties » de l'onglet Scp: ce que le serveur dit d'une entree
  distante, et les droits d'acces qu'on peut lui poser.

  Elle travaille sur la SELECTION, pas sur un fichier: une case dont les
  fichiers selectionnes ne sont pas d'accord reste indeterminee, sort du
  masque rendu, et chacun garde alors le bit qu'il avait. C'est la seule facon
  de corriger une permission sur un lot mal assorti sans aligner tout le reste
  au passage.

  Proprietaire et groupe sont MONTRES, pas modifiables: SFTP v3 les pose par
  numero, et les noms rendus par le serveur ne se retraduisent pas d'ici.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpPropsDialog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Forms, StdCtrls, ExtCtrls, Graphics,
  uScpBackend, uScpPaths, uTransferQueue, uTheme;

type
  TScpPropsResult = record
    Apply: Boolean;
    Bits: LongWord;       // valeur des bits decides
    Mask: LongWord;       // bits decides; hors de la, le mode ne bouge pas
    Recursive: Boolean;
    DirX: Boolean;
  end;

// ALocation: le dossier qui contient AEntries, pour l'afficher. Fermer sans
// choisir rend Apply a False: ne rien decider ne change aucun droit.
function ShowScpProperties(const ALocation: string;
  const AEntries: TScpEntryArray): TScpPropsResult;

implementation

uses
  DateUtils;

type
  // Les douze cases, dans l'ordre des bits du mode: 0..8 = rwx des trois
  // classes, du moins au plus significatif; 9 = sticky, 10 = setgid,
  // 11 = setuid.
  TPermBoxes = array[0..11] of TCheckBox;

  TPropsForm = class
  private
    FForm: TForm;
    FResult: TScpPropsResult;
    FBoxes: TPermBoxes;
    FOctal: TEdit;
    FRecursive: TCheckBox;
    FDirX: TCheckBox;
    // Les cases ecrivent l'octal et l'octal ecrit les cases: sans ce drapeau
    // chaque frappe repartirait en boucle.
    FSyncing: Boolean;
    procedure BoxChanged(Sender: TObject);
    procedure OctalChanged(Sender: TObject);
    procedure ApplyClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure RefreshOctal;
  public
    constructor Create(const ALocation: string;
      const AEntries: TScpEntryArray);
    destructor Destroy; override;
    function Run: TScpPropsResult;
  end;

function StampText(AUnixUtc: Int64): string;
begin
  if AUnixUtc <= 0 then Exit('unknown');
  Result := FormatDateTime('yyyy-mm-dd hh:nn:ss',
    UniversalTimeToLocal(UnixToDateTime(AUnixUtc)));
end;

function KindText(const AEntry: TScpEntry): string;
begin
  if AEntry.IsLink then
  begin
    Result := 'Symbolic link';
    if AEntry.LinkTarget <> '' then
      Result := Result + ' -> ' + DisplaySafeName(AEntry.LinkTarget);
    if AEntry.BrokenLink then
      Result := Result + '  (target not reachable)';
  end
  else if AEntry.IsDir then
    Result := 'Folder'
  else if AEntry.IsSpecial then
    Result := 'Special file'
  else if AEntry.TypeUnknown then
    Result := 'unknown'
  else
    Result := 'File';
end;

function BoxBit(AIndex: Integer): LongWord;
begin
  Result := LongWord(1) shl AIndex;
end;

constructor TPropsForm.Create(const ALocation: string;
  const AEntries: TScpEntryArray);
const
  CLASS_NAMES: array[0..2] of string = ('Owner', 'Group', 'Others');
  SPECIAL_NAMES: array[0..2] of string = ('Set UID', 'Set GID', 'Sticky bit');
  COL_X: array[0..2] of Integer = (132, 172, 212);
var
  y, i, c, b, setCount, known, dirs, links: Integer;
  bit: LongWord;
  head: string;
  someModeUnknown: Boolean;
  warn: TLabel;

  function AddLabel(const AText: string; ALeft, AWidth: Integer;
    ABold: Boolean; AColor: TColor): TLabel;
  begin
    Result := TLabel.Create(FForm);
    Result.Parent := FForm;
    Result.Left := ALeft;
    Result.Top := y;
    Result.Width := AWidth;
    Result.AutoSize := False;
    Result.WordWrap := True;
    Result.Height := 17;
    Result.Caption := AText;
    Result.Font.Color := AColor;
    if ABold then Result.Font.Style := [fsBold];
  end;

  procedure AddRow(const ACaption, AValue: string);
  begin
    AddLabel(ACaption, 16, 82, False, clTextSecondary);
    AddLabel(AValue, 102, FForm.ClientWidth - 118, False, clAppFg);
    Inc(y, 19);
  end;

  procedure AddRule;
  var
    p: TPanel;
  begin
    p := TPanel.Create(FForm);
    p.Parent := FForm;
    p.Left := 16;
    p.Top := y;
    p.Width := FForm.ClientWidth - 32;
    p.Height := 1;
    p.BevelOuter := bvNone;
    p.Color := clPanelGrid;
    Inc(y, 10);
  end;

  function AddBtn(const ACaption: string; ALeft, AWidth: Integer;
    AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(FForm);
    Result.Parent := FForm;
    Result.Caption := ACaption;
    Result.Left := ALeft;
    Result.Width := AWidth;
    Result.Height := 28;
    Result.Top := FForm.ClientHeight - 40;
    Result.Anchors := [akLeft, akBottom];
    Result.OnClick := AHandler;
  end;

  function AddBox(ALeft, AWidth: Integer; const ACaption: string): TCheckBox;
  begin
    Result := TCheckBox.Create(FForm);
    Result.Parent := FForm;
    Result.Left := ALeft;
    Result.Top := y - 2;
    Result.Width := AWidth;
    Result.Caption := ACaption;
    Result.Font.Color := clAppFg;
    Result.AllowGrayed := True;
  end;

begin
  inherited Create;
  FResult.Apply := False;

  FForm := TForm.CreateNew(nil);
  FForm.Caption := 'Properties';
  FForm.Position := poScreenCenter;
  FForm.BorderStyle := bsDialog;
  FForm.Width := 440;
  FForm.Height := 440;
  FForm.Color := clAppBg;
  FForm.Font.Color := clAppFg;
  FForm.OnClose := @FormClose;

  dirs := 0;
  links := 0;
  someModeUnknown := False;
  for i := 0 to High(AEntries) do
  begin
    if AEntries[i].IsDir and (not AEntries[i].IsLink) then Inc(dirs);
    if AEntries[i].IsLink then Inc(links);
    if not AEntries[i].ModeKnown then someModeUnknown := True;
  end;

  y := 14;
  if Length(AEntries) = 1 then
    head := DisplaySafeName(AEntries[0].Name)
  else
    head := Format('%d selected items', [Length(AEntries)]);
  AddLabel(head, 16, FForm.ClientWidth - 32, True, clAppFg);
  Inc(y, 23);

  AddRow('Location:', DisplaySafeName(ALocation));
  if Length(AEntries) = 1 then
  begin
    AddRow('Type:', KindText(AEntries[0]));
    // La taille d'un dossier n'est pas comptee: il faudrait le parcourir, et
    // ouvrir une fenetre ne doit pas lancer un parcours du serveur.
    if AEntries[0].IsDir or (AEntries[0].Size < 0) then
      AddRow('Size:', 'unknown')
    else
      AddRow('Size:', Format('%s (%d bytes)',
        [FormatBytes(AEntries[0].Size), AEntries[0].Size]));
    AddRow('Modified:', StampText(AEntries[0].MTimeUtc));
    AddRow('Owner:', Format('%s    Group: %s',
      [DisplaySafeName(AEntries[0].Owner),
       DisplaySafeName(AEntries[0].Group)]));
  end;
  Inc(y, 4);
  AddRule;

  AddLabel('Permissions', 16, 110, True, clAppFg);
  for c := 0 to 2 do
    AddLabel(Copy('RWX', c + 1, 1), COL_X[c], 20, False, clTextSecondary);
  AddLabel('Special', 262, 100, False, clTextSecondary);
  Inc(y, 20);

  for i := 0 to 2 do
  begin
    AddLabel(CLASS_NAMES[i], 16, 100, False, clAppFg);
    for c := 0 to 2 do
    begin
      // Le proprietaire occupe les bits hauts, « others » les bas: la grille
      // se lit donc a l'envers de l'ordre des bits.
      b := (2 - i) * 3 + (2 - c);
      FBoxes[b] := AddBox(COL_X[c], 24, '');
    end;
    FBoxes[11 - i] := AddBox(262, 150, SPECIAL_NAMES[i]);
    Inc(y, 22);
  end;

  // Etat de depart: cochee si TOUTES les entrees ont le bit, vide si aucune,
  // indeterminee sinon. Un mode que le serveur n'a pas dit ne vote pas.
  for i := 0 to 11 do
  begin
    bit := BoxBit(i);
    setCount := 0;
    known := 0;
    for c := 0 to High(AEntries) do
      if AEntries[c].ModeKnown then
      begin
        Inc(known);
        if (AEntries[c].Mode and bit) <> 0 then Inc(setCount);
      end;
    if (known = 0) or ((setCount > 0) and (setCount < known)) then
      FBoxes[i].State := cbGrayed
    else if setCount = known then
      FBoxes[i].State := cbChecked
    else
      FBoxes[i].State := cbUnchecked;
    FBoxes[i].OnChange := @BoxChanged;
  end;

  Inc(y, 4);
  AddLabel('Octal', 16, 60, False, clAppFg);
  FOctal := TEdit.Create(FForm);
  FOctal.Parent := FForm;
  FOctal.Left := 102;
  FOctal.Top := y - 3;
  FOctal.Width := 70;
  FOctal.MaxLength := 4;
  FOctal.Color := BlendColor(clPanelBg, clAppFg, 92);
  FOctal.Font.Color := clAppFg;
  RefreshOctal;
  FOctal.OnChange := @OctalChanged;
  Inc(y, 28);

  FDirX := AddBox(16, FForm.ClientWidth - 32,
    'Add x to folders wherever r is granted');
  FDirX.AllowGrayed := False;
  FDirX.Enabled := dirs > 0;
  Inc(y, 22);

  FRecursive := AddBox(16, FForm.ClientWidth - 32,
    'Apply to the contents of folders, recursively');
  FRecursive.AllowGrayed := False;
  FRecursive.Enabled := dirs > 0;
  Inc(y, 26);

  // Ce que la fenetre ne fera PAS, ecrit avant le clic plutot qu'en note
  // apres coup.
  if links > 0 then
  begin
    warn := AddLabel('Symbolic links keep their own permissions: setting ' +
      'them through a link would land on its target.', 16,
      FForm.ClientWidth - 32, False, clScpWarn);
    warn.Height := 34;
    Inc(y, 36);
  end;
  if someModeUnknown then
  begin
    warn := AddLabel('The server did not report the permissions of every ' +
      'selected item; those boxes stay undecided.', 16,
      FForm.ClientWidth - 32, False, clScpWarn);
    warn.Height := 34;
    Inc(y, 36);
  end;

  FForm.ClientHeight := y + 48;
  AddBtn('Apply', 16, 100, @ApplyClick);
  AddBtn('Cancel', 122, 100, @CancelClick);

  ApplyUiFont(FForm);
end;

destructor TPropsForm.Destroy;
begin
  FForm.Free;
  inherited Destroy;
end;

// Vide des qu'une case est indeterminee: y afficher un nombre ferait croire a
// un mode unique que personne n'a demande.
procedure TPropsForm.RefreshOctal;
var
  i: Integer;
  m: LongWord;
begin
  m := 0;
  for i := 0 to 11 do
  begin
    if FBoxes[i].State = cbGrayed then
    begin
      FOctal.Text := '';
      Exit;
    end;
    if FBoxes[i].State = cbChecked then m := m or BoxBit(i);
  end;
  FOctal.Text := ScpModeToOctal(m);
end;

procedure TPropsForm.BoxChanged(Sender: TObject);
begin
  if FSyncing then Exit;
  FSyncing := True;
  try
    RefreshOctal;
  finally
    FSyncing := False;
  end;
end;

// Une saisie valide TRANCHE: les douze cases deviennent decidees, y compris
// celles que la selection laissait indeterminees. Une saisie qui n'est pas un
// octal ne touche a rien: elle est en cours de frappe.
procedure TPropsForm.OctalChanged(Sender: TObject);
var
  m: LongWord;
  i: Integer;
begin
  if FSyncing then Exit;
  if not ScpOctalToMode(FOctal.Text, m) then Exit;
  FSyncing := True;
  try
    for i := 0 to 11 do
      if (m and BoxBit(i)) <> 0 then
        FBoxes[i].State := cbChecked
      else
        FBoxes[i].State := cbUnchecked;
  finally
    FSyncing := False;
  end;
end;

procedure TPropsForm.ApplyClick(Sender: TObject);
var
  i: Integer;
begin
  FResult.Bits := 0;
  FResult.Mask := 0;
  for i := 0 to 11 do
    if FBoxes[i].State <> cbGrayed then
    begin
      FResult.Mask := FResult.Mask or BoxBit(i);
      if FBoxes[i].State = cbChecked then
        FResult.Bits := FResult.Bits or BoxBit(i);
    end;
  FResult.Recursive := FRecursive.Checked and FRecursive.Enabled;
  FResult.DirX := FDirX.Checked and FDirX.Enabled;
  // Aucune case decidee et pas de x a ajouter: rien a demander au serveur, et
  // surtout rien a ecrire.
  FResult.Apply := (FResult.Mask <> 0) or FResult.DirX;
  FForm.ModalResult := mrOK;
end;

procedure TPropsForm.CancelClick(Sender: TObject);
begin
  FForm.ModalResult := mrCancel;
end;

procedure TPropsForm.FormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  if FForm.ModalResult <> mrOK then
    FResult.Apply := False;
  CloseAction := caHide;
end;

function TPropsForm.Run: TScpPropsResult;
begin
  FForm.ShowModal;
  Result := FResult;
end;

function ShowScpProperties(const ALocation: string;
  const AEntries: TScpEntryArray): TScpPropsResult;
var
  dlg: TPropsForm;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Length(AEntries) = 0 then Exit;
  dlg := TPropsForm.Create(ALocation, AEntries);
  try
    Result := dlg.Run;
  finally
    dlg.Free;
  end;
end;

end.
