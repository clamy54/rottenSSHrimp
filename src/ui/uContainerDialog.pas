unit uContainerDialog;

{$mode objfpc}{$H+}

// Proprietes d'un hote conteneur, a l'ecart du dialogue multi-protocole: un
// conteneur n'a ni hote, ni port, ni identifiants -- juste un parent SSH, un
// moteur, un nom, un mode.

interface

uses
  uRshModel;

// AParentGroupUuid '' = racine; rend l'uuid cree, '' si annule
function ShowNewContainerDialog(AModel: TRshModel;
  const AParentGroupUuid: string): string;

function ShowContainerProperties(AModel: TRshModel;
  const AUuid: string): Boolean;

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
  TContainerForm = class(TForm)
  public
    NameEdit: TEdit;
    ParentCombo: TComboBox;
    ParentUuids: TStringList;
    EngineCombo: TComboBox;
    CNameEdit: TEdit;
    ShellCombo: TComboBox;
    Y: Integer;
    constructor CreateShell(const ATitle: string);
    destructor Destroy; override;
    function AddRow(const ACaption: string): TControl;
    procedure FillParents(AModel: TRshModel; const ASelfUuid, ACurrent: string);
  end;

constructor TContainerForm.CreateShell(const ATitle: string);
begin
  inherited CreateNew(nil, 0);
  Caption := ATitle;
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  Width := DLG_W;
  Y := MARGIN;
  ParentUuids := TStringList.Create;
end;

destructor TContainerForm.Destroy;
begin
  ParentUuids.Free;
  inherited Destroy;
end;

function TContainerForm.AddRow(const ACaption: string): TControl;
var
  lbl: TLabel;
begin
  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.Left := MARGIN;
  lbl.Top := Y + 4;
  lbl.Width := LBL_W;
  lbl.Caption := ACaption;
  Result := lbl;
end;

procedure TContainerForm.FillParents(AModel: TRshModel;
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
  // visible meme non marque: le perdre en silence a l'edition serait pire.
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
  const AName: string; const ACfg: TContainerConfig): TContainerForm;
var
  f: TContainerForm;

  function MakeEdit: TEdit;
  begin
    Result := TEdit.Create(f);
    Result.Parent := f;
    Result.Left := EDIT_X;
    Result.Top := f.Y;
    Result.Width := EDIT_W;
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
  f := TContainerForm.CreateShell(ATitle);

  f.AddRow('Name');
  f.NameEdit := MakeEdit;
  f.NameEdit.Text := AName;
  Inc(f.Y, ROW_H);

  f.AddRow('Connect via');
  f.ParentCombo := MakeCombo;
  Inc(f.Y, ROW_H);

  f.AddRow('Engine');
  f.EngineCombo := MakeCombo;
  f.EngineCombo.Items.Add('Docker');
  f.EngineCombo.Items.Add('Podman');
  f.EngineCombo.ItemIndex := Ord(ACfg.Engine);
  Inc(f.Y, ROW_H);

  f.AddRow('Container name');
  f.CNameEdit := MakeEdit;
  f.CNameEdit.Text := ACfg.ContainerName;
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

// False = invalide, le message a deja ete affiche a l'utilisateur
function ReadForm(f: TContainerForm; out AName: string;
  out ACfg: TContainerConfig): Boolean;
var
  err: string;
begin
  Result := False;
  AName := f.NameEdit.Text;
  if not ValidateName(AName, err) then
  begin
    MessageDlg('Container', err, mtError, [mbOK], 0);
    Exit;
  end;
  if f.ParentCombo.ItemIndex < 0 then
  begin
    MessageDlg('Container', 'Choose an SSH host to connect via.',
      mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.ParentUuid := f.ParentUuids[f.ParentCombo.ItemIndex];
  ACfg.Engine := TContainerEngine(f.EngineCombo.ItemIndex);
  ACfg.ContainerName := f.CNameEdit.Text;
  if not ValidateContainerName(ACfg.ContainerName, err) then
  begin
    MessageDlg('Container', err, mtError, [mbOK], 0);
    Exit;
  end;
  ACfg.Shell := TContainerShell(f.ShellCombo.ItemIndex);
  Result := True;
end;

function ShowNewContainerDialog(AModel: TRshModel;
  const AParentGroupUuid: string): string;
var
  f: TContainerForm;
  name: string;
  cfg: TContainerConfig;
begin
  Result := '';
  cfg := Default(TContainerConfig);
  cfg.Engine := ceDocker;
  cfg.Shell := csSh;   // /bin/sh: present dans plus d'images que bash
  f := BuildForm(AModel, 'New Container', '', 'container', cfg);
  try
    repeat
      if f.ShowModal <> mrOk then Exit;
    until ReadForm(f, name, cfg);
    Result := AModel.CreateContainerConnection(AParentGroupUuid, name,
      cfg.ParentUuid, cfg.Engine, cfg.ContainerName, cfg.Shell);
  finally
    f.Free;
  end;
end;

function ShowContainerProperties(AModel: TRshModel;
  const AUuid: string): Boolean;
var
  f: TContainerForm;
  node: TRshNode;
  name: string;
  cfg: TContainerConfig;
begin
  Result := False;
  if not AModel.GetContainerConfig(AUuid, cfg) then
  begin
    MessageDlg('Container',
      'This container cannot be edited (older document format).',
      mtError, [mbOK], 0);
    Exit;
  end;
  node := AModel.GetNode(AUuid);
  try
    name := node.DisplayName;
  finally
    node.Free;
  end;
  f := BuildForm(AModel, 'Container Properties', AUuid, name, cfg);
  try
    repeat
      if f.ShowModal <> mrOk then Exit;
    until ReadForm(f, name, cfg);
    AModel.RenameNode(AUuid, name);
    AModel.SetContainerConfig(AUuid, cfg);
    Result := True;
  finally
    f.Free;
  end;
end;

end.
