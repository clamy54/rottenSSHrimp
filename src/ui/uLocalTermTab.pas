unit uLocalTermTab;

{$mode objfpc}{$H+}

// Onglet de terminal local: un TSessionTabBase ordinaire dont les octets
// viennent d'un TLocalPty au lieu d'un transport reseau. Ce n'est PAS une
// session distante -- pas d'enregistrement aupres du TSessionManager, donc
// hors plafond et hors « deconnecter tout le dossier ».

interface

uses
  Classes, SysUtils, Controls, ComCtrls, Forms, Dialogs, Graphics,
  uTermControl, uLocalPty, uSessionState, uSessionTabBase;

type
  TLocalTermTab = class(TSessionTabBase)
  private
    FTerm: TRottenTerminalControl;
    FPty: TLocalPty;
    FTitle: string;      // titre pose par le shell (OSC), sinon vide
    FExited: Boolean;
    FClosing: Boolean;
    procedure TermSend(const AData: RawByteString);
    procedure TermGridResize(ACols, ARows: Integer);
    procedure TermTitle(const ATitle: string);
    procedure PtyData(const AData: RawByteString);
    procedure PtyExit(ACode: Integer);
    procedure UpdateCaption;
  public
    constructor CreateTab(APages: TPageControl);
    destructor Destroy; override;
    // a appeler APRES ActivePage := tab: la grille reelle doit etre connue.
    // False = l'appelant libere l'onglet.
    function Start(out AErr: string): Boolean;
    function TabState: TRemoteSessionState; override;
    function TabBarCaption: string; override;
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    function GrabThumbnail: TBitmap; override;
    property Terminal: TRottenTerminalControl read FTerm;
  end;

implementation

constructor TLocalTermTab.CreateTab(APages: TPageControl);
begin
  inherited Create(APages);
  PageControl := APages;
  FTerm := TRottenTerminalControl.Create(Self);
  FTerm.Parent := Self;
  FTerm.Align := alClient;
  FTerm.OnSendData := @TermSend;
  FTerm.OnGridResize := @TermGridResize;
  FTerm.OnTitleChanged := @TermTitle;
  FPty := TLocalPty.Create;
  FPty.OnData := @PtyData;
  FPty.OnExit := @PtyExit;
  UpdateCaption;
end;

destructor TLocalTermTab.Destroy;
var
  cb: TNotifyEvent;
begin
  FClosing := True;
  // le join du thread lecteur pompe la file: un PtyExit en attente rappellerait
  // un onglet deja mort, FClosing le neutralise
  FreeAndNil(FPty);
  Application.RemoveAsyncCalls(Self);
  cb := FOnDestroyed;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

function TLocalTermTab.Start(out AErr: string): Boolean;
begin
  AErr := '';
  Result := FPty.Start(FTerm.GridCols, FTerm.GridRows, AErr);
  if Result then
    FocusContent;
end;

procedure TLocalTermTab.TermSend(const AData: RawByteString);
begin
  FPty.WriteData(AData);
end;

procedure TLocalTermTab.TermGridResize(ACols, ARows: Integer);
begin
  FPty.Resize(ACols, ARows);
end;

procedure TLocalTermTab.TermTitle(const ATitle: string);
begin
  FTitle := ATitle;
  UpdateCaption;
end;

procedure TLocalTermTab.PtyData(const AData: RawByteString);
begin
  if not FClosing then
    FTerm.FeedData(AData);
end;

procedure TLocalTermTab.PtyExit(ACode: Integer);
begin
  if FClosing then Exit;
  // on ne referme PAS l'onglet: la sortie finale reste lisible jusqu'a ce que
  // l'utilisateur ferme lui-meme
  FExited := True;
  FTerm.FeedData(#13#10'[process exited with code ' + IntToStr(ACode) +
    ']'#13#10);
  UpdateCaption;
end;

procedure TLocalTermTab.UpdateCaption;
var
  base: string;
begin
  if FTitle <> '' then
    base := FTitle
  else
    base := 'Local Terminal';
  if FExited then
    Caption := '✕ ' + base
  else
    Caption := '● ' + base;
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

function TLocalTermTab.TabState: TRemoteSessionState;
begin
  if FExited then
    Result := rssDisconnected
  else
    Result := rssConnected;
end;

function TLocalTermTab.TabBarCaption: string;
begin
  if FTitle <> '' then
    Result := FTitle + ' — Local'
  else
    Result := 'Local Terminal';
end;

function TLocalTermTab.ConfirmClose: Boolean;
begin
  if FExited or (FPty = nil) or (not FPty.Running) then
    Exit(True);
  Result := QuestionDlg('Local Terminal',
    'A shell is still running. Close the terminal?', mtConfirmation,
    [mrOK, 'Close', mrCancel, 'Cancel', 'IsCancel'], 0) = mrOK;
end;

procedure TLocalTermTab.BeginShutdown;
begin
  if FPty <> nil then
    FPty.Stop;
end;

procedure TLocalTermTab.FocusContent;
begin
  if (FTerm <> nil) and FTerm.CanFocus then
    FTerm.SetFocus;
end;

function TLocalTermTab.GrabThumbnail: TBitmap;
begin
  Result := nil;
  if FTerm <> nil then
    Result := FTerm.Snapshot;
end;

end.
