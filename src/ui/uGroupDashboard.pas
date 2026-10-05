unit uGroupDashboard;

{$mode objfpc}{$H+}

// N'emprunte que le modele, ne le POSSEDE pas: Detach AVANT de fermer le document.

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics, uRtList,
  uRshModel;

type
  // '' = aucune session ouverte
  TDashSessionState = function(const AConnUuid: string): string of object;
  TDashConnect = procedure(const AConnUuid: string) of object;

  TGroupDashboard = class(TForm)
  private
    FList: TRtListGrid;
    FSummary: TLabel;
    FModel: TRshModel;
    FUuids: TStringList;   // aligne sur l'index de ligne
    FGroupUuid: string;
    FGroupName: string;
    FOnSessionState: TDashSessionState;
    FOnConnect: TDashConnect;
    procedure ListActivate(Sender: TObject; AIndex: Integer);
    procedure RefreshClick(Sender: TObject);
    function DescribeLast(AEntry: TRshQuickEntry): string;
  public
    constructor CreateFor(AOwner: TComponent; AModel: TRshModel;
      const AGroupUuid, AGroupName: string);
    procedure Refresh;
    property OnSessionState: TDashSessionState read FOnSessionState
      write FOnSessionState;
    property OnConnect: TDashConnect read FOnConnect write FOnConnect;
    // apres ca, plus une seule touche au modele
    procedure Detach;
    destructor Destroy; override;
  end;

implementation

uses
  uThemedControls, uTheme, DateUtils, uRsUtil;

constructor TGroupDashboard.CreateFor(AOwner: TComponent; AModel: TRshModel;
  const AGroupUuid, AGroupName: string);
var
  btn: TThemedButton;
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
  // sinon sombre sur fond sombre
  FSummary.Font.Color := clAppFg;
  FSummary.ParentFont := False;

  btn := TThemedButton.Create(Self);
  btn.Parent := bar;
  btn.Align := alRight;
  btn.Width := 110;
  btn.BorderSpacing.Around := 6;
  btn.Caption := 'Refresh';
  btn.OnClick := @RefreshClick;

  FList := TRtListGrid.Create(Self);
  FList.Parent := Self;
  FList.Align := alClient;
  FList.Color := clAppBg;
  FList.OnActivateRow := @ListActivate;
  FList.AddColumn('', 26);   // favori
  FList.AddColumn('Name', 150);
  FList.AddColumn('Group', 130);
  FList.AddColumn('Proto', 55);
  FList.AddColumn('Host', 160);
  FList.AddColumn('Session', 90);
  FList.AddColumn('Last attempt', 160);
  FList.StretchLastColumn := True;
  ApplyUiFont(Self);
  FList.RefreshMetrics;

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
  FList.Clear;
  FUuids.Clear;
  FSummary.Caption := 'Document closed.';
end;

// LastConnectedMs = 0: jamais tentee, LastResult ne veut rien dire (PAS un echec)
function TGroupDashboard.DescribeLast(AEntry: TRshQuickEntry): string;
var
  whenUtc: TDateTime;
  mins: Int64;
begin
  if AEntry.LastConnectedMs <= 0 then
    Exit('never');
  whenUtc := UnixToDateTime(AEntry.LastConnectedMs div 1000);
  // UTC de bout en bout: Now decalerait du fuseau local
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
  e: TRshQuickEntry;
  state, fav: string;
begin
  FList.BeginUpdate;
  try
    FList.Clear;
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

        if e.Favorite then fav := '★' else fav := '';
        FList.AddRow([fav, e.DisplayName, e.GroupPath,
          UpperCase(PROTOCOL_NAMES[e.Protocol]), e.Hostname, state,
          DescribeLast(e)]);
        FUuids.Add(e.ConnUuid);
      end;
      FSummary.Caption := Format(
        '%d connection(s) · %d session(s) open · %d failed',
        [list.Count, open, failed]);
    finally
      list.Free;
    end;
  finally
    FList.EndUpdate;
  end;
end;

procedure TGroupDashboard.RefreshClick(Sender: TObject);
begin
  Refresh;
end;

procedure TGroupDashboard.ListActivate(Sender: TObject; AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FUuids.Count) then Exit;
  if Assigned(FOnConnect) then
    FOnConnect(FUuids[AIndex]);
end;

end.
