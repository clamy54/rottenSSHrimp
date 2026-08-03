unit uPodDialog;

{$mode objfpc}{$H+}

// Proprietes d'un pod Kubernetes, jumeau de uContainerDialog: ni hote, ni
// port, ni identifiants -- un parent SSH ou kubectl vit, un namespace, un pod,
// un container, un mode.

interface

uses
  uRshModel;

// AParentGroupUuid '' = racine; rend l'uuid cree, '' si annule
function ShowNewPodDialog(AModel: TRshModel;
  const AParentGroupUuid: string): string;

function ShowPodProperties(AModel: TRshModel; const AUuid: string): Boolean;

implementation

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, uTheme, uRshValidation;

const
  DLG_W = 460;
  MARGIN = 16;
  LBL_W = 130;
  EDIT_X = MARGIN + LBL_W + 8;
  EDIT_W = DLG_W - EDIT_X - MARGIN;
  ROW_H = 30;

type
  TPodForm = class(TForm)
  public
    NameEdit: TEdit;
    ParentCombo: TComboBox;
    ParentUuids: TStringList;
    NsEdit: TEdit;
    PodEdit: TEdit;
    ContEdit: TEdit;
    ShellCombo: TComboBox;
    Y: Integer;
    constructor CreateShell(const ATitle: string);
    destructor Destroy; override;
    procedure AddRow(const ACaption: string);
    procedure FillParents(AModel: TRshModel; const ASelfUuid, ACurrent: string);
  end;

constructor TPodForm.CreateShell(const ATitle: string);
begin
  inherited CreateNew(nil, 0);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Width := DLG_W;
  Y := MARGIN;
  ParentUuids := TStringList.Create;
end;

destructor TPodForm.Destroy;
begin
  ParentUuids.Free;
  inherited Destroy;
end;

procedure TPodForm.AddRow(const ACaption: string);
var
  lbl: TLabel;
begin
  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.Left := MARGIN;
  lbl.Top := Y + 4;
  lbl.Width := LBL_W;
  lbl.Caption := ACaption;
end;

procedure TPodForm.FillParents(AModel: TRshModel;
  const ASelfUuid, ACurrent: string);
var
  nodes: TRshNodeList;
  offers: TStringList;
  filtering: Boolean;
  i, sel: Integer;
begin
  ParentCombo.Style := csDropDownList;
  ParentCombo.Items.Clear;
  ParentUuids.Clear;
  sel := -1;
  // Filtre sur les hotes marques « Offer this host ». Table absente (document
  // ancien) => pas de filtre, sinon liste vide. Le parent DEJA choisi reste
  // visible meme non marque.
  offers := TStringList.Create;
  try
    offers.Sorted := True;
    AModel.LoadJumpHostOffers(offers);
    filtering := AModel.JumpHostOffersAvailable;
    nodes := AModel.LoadNodes;
    try
      for i := 0 to nodes.Count - 1 do
        if (nodes[i].Kind = nkConnection) and (nodes[i].Protocol = rpSsh)
           and (nodes[i].Uuid <> ASelfUuid)
           and ((not filtering) or (nodes[i].Uuid = ACurrent)
                or (offers.IndexOf(nodes[i].Uuid) >= 0)) then
        begin
          ParentCombo.Items.Add(Format('%s (%s)',
            [nodes[i].DisplayName, nodes[i].Hostname]));
          ParentUuids.Add(nodes[i].Uuid);
          if nodes[i].Uuid = ACurrent then
            sel := ParentUuids.Count - 1;
        end;
    finally
      nodes.Free;
    end;
  finally
    offers.Free;
  end;
  ParentCombo.ItemIndex := sel;
end;

function BuildForm(AModel: TRshModel; const ATitle, ASelfUuid: string;
  const AName: string; const ACfg: TPodConfig): TPodForm;
var
  f: TPodForm;

  function MakeEdit(const AHint: string): TEdit;
  begin
    Result := TEdit.Create(f);
    Result.Parent := f;
    Result.Left := EDIT_X;
    Result.Top := f.Y;
    Result.Width := EDIT_W;
    Result.TextHint := AHint;
  end;

  function MakeCombo: TComboBox;
  begin
    Result := TComboBox.Create(f);
    Result.Parent := f;
    Result.Left := EDIT_X;
    Result.Top := f.Y;
    Result.Style := csDropDownList;
    // sous LCL Cocoa un csDropDownList s'ajuste a son contenu et ignore Width:
    // seules les contraintes figent la largeur
    Result.AutoSize := False;
    Result.Width := EDIT_W;
    Result.Constraints.MinWidth := EDIT_W;
    Result.Constraints.MaxWidth := EDIT_W;
  end;

var
  ok, cancel: TButton;
begin
  f := TPodForm.CreateShell(ATitle);

  f.AddRow('Name');
  f.NameEdit := MakeEdit('');
  f.NameEdit.Text := AName;
  Inc(f.Y, ROW_H);

  f.AddRow('Connect via');
  f.ParentCombo := MakeCombo;
  Inc(f.Y, ROW_H);

  f.AddRow('Namespace');
  f.NsEdit := MakeEdit('optional (default)');
  f.NsEdit.Text := ACfg.Namespace;
  Inc(f.Y, ROW_H);

  f.AddRow('Pod name');
  f.PodEdit := MakeEdit('required');
  f.PodEdit.Text := ACfg.PodName;
  Inc(f.Y, ROW_H);

  f.AddRow('Container');
  f.ContEdit := MakeEdit('optional (default)');
  f.ContEdit.Text := ACfg.ContainerName;
  Inc(f.Y, ROW_H);

  f.AddRow('Shell / mode');
  f.ShellCombo := MakeCombo;
  f.ShellCombo.Items.Add('/bin/sh');
  f.ShellCombo.Items.Add('/bin/bash');
  f.ShellCombo.Items.Add('Log (read-only, follow)');
  f.ShellCombo.ItemIndex := Ord(ACfg.Shell);
  Inc(f.Y, ROW_H);

  f.FillParents(AModel, ASelfUuid, ACfg.ParentUuid);

  Inc(f.Y, 8);
  ok := TButton.Create(f);
  ok.Parent := f;
  ok.Caption := 'OK';
  ok.ModalResult := mrOk;
  ok.Default := True;
  ok.Width := 90;
  ok.Top := f.Y;
  ok.Left := DLG_W - MARGIN - 2 * 90 - 8;

  cancel := TButton.Create(f);
  cancel.Parent := f;
  cancel.Caption := 'Cancel';
  cancel.ModalResult := mrCancel;
  cancel.Cancel := True;
  cancel.Width := 90;
  cancel.Top := f.Y;
  cancel.Left := DLG_W - MARGIN - 90;

  f.ClientHeight := f.Y + 40;
  ApplyUiFont(f);
  Result := f;
end;

// False = invalide, le message a deja ete affiche. Seul le pod est obligatoire.
function ReadForm(f: TPodForm; out AName: string;
  out ACfg: TPodConfig): Boolean;
var
  err, s: string;
begin
  Result := False;
  AName := f.NameEdit.Text;
  if not ValidateName(AName, err) then
  begin
    MessageDlg('Pod', err, mtError, [mbOK], 0);
    Exit;
  end;
  if f.ParentCombo.ItemIndex < 0 then
  begin
    MessageDlg('Pod', 'Choose an SSH host to connect via.',
      mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.ParentUuid := f.ParentUuids[f.ParentCombo.ItemIndex];
  s := f.PodEdit.Text;
  if not ValidateK8sName(s, err) then
  begin
    MessageDlg('Pod', err, mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.PodName := s;
  s := Trim(f.NsEdit.Text);
  if (s <> '') and not ValidateK8sLabel(s, err) then
  begin
    MessageDlg('Pod', 'Namespace: ' + err, mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.Namespace := s;
  s := Trim(f.ContEdit.Text);
  if (s <> '') and not ValidateK8sLabel(s, err) then
  begin
    MessageDlg('Pod', 'Container: ' + err, mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.ContainerName := s;
  ACfg.Shell := TContainerShell(f.ShellCombo.ItemIndex);
  Result := True;
end;

function ShowNewPodDialog(AModel: TRshModel;
  const AParentGroupUuid: string): string;
var
  f: TPodForm;
  name: string;
  cfg: TPodConfig;
begin
  Result := '';
  cfg := Default(TPodConfig);
  cfg.Shell := csSh;   // /bin/sh: present dans plus d'images que bash
  f := BuildForm(AModel, 'New Kubernetes Pod', '', 'pod', cfg);
  try
    repeat
      if f.ShowModal <> mrOk then Exit;
    until ReadForm(f, name, cfg);
    Result := AModel.CreatePodConnection(AParentGroupUuid, name,
      cfg.ParentUuid, cfg.Namespace, cfg.PodName, cfg.ContainerName, cfg.Shell);
  finally
    f.Free;
  end;
end;

function ShowPodProperties(AModel: TRshModel; const AUuid: string): Boolean;
var
  f: TPodForm;
  node: TRshNode;
  name: string;
  cfg: TPodConfig;
begin
  Result := False;
  if not AModel.GetPodConfig(AUuid, cfg) then
  begin
    MessageDlg('Pod',
      'This pod cannot be edited (older document format).',
      mtError, [mbOK], 0);
    Exit;
  end;
  node := AModel.GetNode(AUuid);
  try
    name := node.DisplayName;
  finally
    node.Free;
  end;
  f := BuildForm(AModel, 'Pod Properties', AUuid, name, cfg);
  try
    repeat
      if f.ShowModal <> mrOk then Exit;
    until ReadForm(f, name, cfg);
    AModel.RenameNode(AUuid, name);
    AModel.SetPodConfig(AUuid, cfg);
    Result := True;
  finally
    f.Free;
  end;
end;

end.
