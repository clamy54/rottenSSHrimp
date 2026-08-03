unit uGroupDashboard;

{$mode objfpc}{$H+}

// « Ou en sont mes machines »: une ligne par connexion du sous-arbre, avec ce
// que l'arbre ne montre pas (session ouverte, derniere tentative, verdict).
//
// Non modale, et ne POSSEDE ni le document ni le modele: elle les emprunte le
// temps d'un rafraichissement. L'appelant doit la fermer avant le document.

interface

uses
  Classes, SysUtils, Forms, Controls, ComCtrls, StdCtrls, ExtCtrls, Graphics,
  uRshModel;

type
  // '' = aucune session ouverte
  TDashSessionState = function(const AConnUuid: string): string of object;
  TDashConnect = procedure(const AConnUuid: string) of object;

  TGroupDashboard = class(TForm)
  private
    FList: TListView;
    FSummary: TLabel;
    FModel: TRshModel;
    FUuids: TStringList;   // aligne sur l'index de ligne, refait dans Refresh
    FGroupUuid: string;
    FGroupName: string;
    FOnSessionState: TDashSessionState;
    FOnConnect: TDashConnect;
    procedure ListDblClick(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    function DescribeLast(AEntry: TRshQuickEntry): string;
  public
    constructor CreateFor(AOwner: TComponent; AModel: TRshModel;
      const AGroupUuid, AGroupName: string);
    procedure Refresh;
    property OnSessionState: TDashSessionState read FOnSessionState
      write FOnSessionState;
    property OnConnect: TDashConnect read FOnConnect write FOnConnect;
    // le document se ferme: plus une seule touche au modele apres ca
    procedure Detach;
    destructor Destroy; override;
  end;

implementation

uses
  uTheme, DateUtils, uRsUtil;

constructor TGroupDashboard.CreateFor(AOwner: TComponent; AModel: TRshModel;
  const AGroupUuid, AGroupName: string);
var
  btn: TButton;
  bar: TPanel;
begin
  inherited CreateNew(AOwner);
  FModel := AModel;
  FUuids := TStringList.Create;
  FGroupUuid := AGroupUuid;
  FGroupName := AGroupName;

  Caption := 'Dashboard — ' + AGroupName;
  Width := 720;
  Height := 420;
  Position := poMainFormCenter;
  Color := clAppBg;

  bar := TPanel.Create(Self);
  bar.Parent := Self;
  bar.Align := alBottom;
  bar.Height := 40;
  bar.BevelOuter := bvNone;
  bar.Color := clAppBg;
  bar.ParentColor := False;

  FSummary := TLabel.Create(Self);
  FSummary.Parent := bar;
  FSummary.Align := alClient;
  FSummary.BorderSpacing.Around := 10;
  FSummary.Layout := tlCenter;
  // sans couleur explicite le label reste sombre sur fond sombre
  FSummary.Font.Color := clAppFg;
  FSummary.ParentFont := False;

  btn := TButton.Create(Self);
  btn.Parent := bar;
  btn.Align := alRight;
  btn.Width := 110;
  btn.BorderSpacing.Around := 6;
  btn.Caption := 'Refresh';
  btn.OnClick := @RefreshClick;

  FList := TListView.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.OnDblClick := @ListDblClick;
  with FList.Columns.Add do begin Caption := ''; Width := 26; end;   // favori
  with FList.Columns.Add do begin Caption := 'Name'; Width := 150; end;
  with FList.Columns.Add do begin Caption := 'Group'; Width := 130; end;
  with FList.Columns.Add do begin Caption := 'Proto'; Width := 55; end;
  with FList.Columns.Add do begin Caption := 'Host'; Width := 160; end;
  with FList.Columns.Add do begin Caption := 'Session'; Width := 90; end;
  with FList.Columns.Add do begin Caption := 'Last attempt'; Width := 160; end;

  Refresh;
end;

destructor TGroupDashboard.Destroy;
begin
  FUuids.Free;
  inherited Destroy;
end;

procedure TGroupDashboard.Detach;
begin
  FModel := nil;
  FList.Items.Clear;
  FUuids.Clear;
  FSummary.Caption := 'Document closed.';
end;

// LastConnectedMs = 0 veut dire « jamais tentee »: LastResult n'a alors aucun
// sens et ne doit surtout pas se lire comme un echec
function TGroupDashboard.DescribeLast(AEntry: TRshQuickEntry): string;
var
  whenUtc: TDateTime;
  mins: Int64;
begin
  if AEntry.LastConnectedMs <= 0 then
    Exit('never');
  whenUtc := UnixToDateTime(AEntry.LastConnectedMs div 1000);
  // UTC de bout en bout: comparer a Now decalerait l'ecart du fuseau local
  mins := (NowUtcMs - AEntry.LastConnectedMs) div (60 * 1000);
  if mins < 0 then mins := 0;
  if mins < 1 then
    Result := 'just now'
  else if mins < 60 then
    Result := Format('%d min ago', [mins])
  else if mins < 60 * 24 then
    Result := Format('%d h ago', [mins div 60])
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn', whenUtc);
  if AEntry.LastResult = srFailed then
    Result := Result + ' (failed)';
end;

procedure TGroupDashboard.Refresh;
var
  list: TRshQuickList;
  i, open, failed: Integer;
  it: TListItem;
  e: TRshQuickEntry;
  state: string;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    FUuids.Clear;
    if FModel = nil then Exit;
    open := 0;
    failed := 0;
    list := FModel.ListSubtreeConnections(FGroupUuid);
    try
      for i := 0 to list.Count - 1 do
      begin
        e := list[i];
        state := '';
        if Assigned(FOnSessionState) then
          state := FOnSessionState(e.ConnUuid);
        if state <> '' then Inc(open);
        if (e.LastConnectedMs > 0) and (e.LastResult = srFailed) then
          Inc(failed);

        it := FList.Items.Add;
        if e.Favorite then it.Caption := '★' else it.Caption := '';
        it.SubItems.Add(e.DisplayName);
        it.SubItems.Add(e.GroupPath);
        it.SubItems.Add(UpperCase(PROTOCOL_NAMES[e.Protocol]));
        it.SubItems.Add(e.Hostname);
        it.SubItems.Add(state);
        it.SubItems.Add(DescribeLast(e));
        FUuids.Add(e.ConnUuid);
      end;
      FSummary.Caption := Format(
        '%d connection(s) · %d session(s) open · %d failed',
        [list.Count, open, failed]);
    finally
      list.Free;
    end;
  finally
    FList.Items.EndUpdate;
  end;
end;

procedure TGroupDashboard.RefreshClick(Sender: TObject);
begin
  Refresh;
end;

procedure TGroupDashboard.ListDblClick(Sender: TObject);
var
  it: TListItem;
begin
  it := FList.Selected;
  if it = nil then Exit;
  if (it.Index < 0) or (it.Index >= FUuids.Count) then Exit;
  if Assigned(FOnConnect) then
    FOnConnect(FUuids[it.Index]);
end;

end.
