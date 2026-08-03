unit uSessionTabBase;

{$mode objfpc}{$H+}

// Classe de base des onglets de session (SSH, RDP, VNC, Broadcast SSH).
// Prefixe Tab et pas Session: les descendants exposent deja SessionState en
// PROPRIETE, qu'on ne redeclare pas en virtuelle heritee sans tout casser.

interface

uses
  Classes, ComCtrls, Graphics, uSessionState;

type
  TSessionNoticeEvent = procedure(const AMessage: string) of object;

  TSessionTabBase = class(TTabSheet)
  protected
    FOnNotice: TSessionNoticeEvent;
    FOnDestroyed: TNotifyEvent;
    FOnStatusChanged: TNotifyEvent;
  public
    function TabState: TRemoteSessionState; virtual; abstract;
    // rompu mais garde ouvert pour montrer la raison: rouge, jamais referme
    function TabIsDeadLog: Boolean; virtual;
    function TabIsFailedKept: Boolean; virtual;
    function TabBarCaption: string; virtual; abstract;
    function TabConnUuid: string; virtual;
    function CountSessionsIn(AUuids: TStrings): Integer; virtual;
    procedure ShutdownSessionsIn(AUuids: TStrings); virtual;
    function HasSessionFor(const AConnUuid: string): Boolean; virtual;
    function ConfirmClose: Boolean; virtual; abstract;
    procedure BeginShutdown; virtual; abstract;
    procedure FocusContent; virtual; abstract;
    // nil si indisponible; l'appelant possede le bitmap
    function GrabThumbnail: TBitmap; virtual;
    procedure EmitNotice(const AMessage: string);

    property OnNotice: TSessionNoticeEvent read FOnNotice write FOnNotice;
    property OnDestroyed: TNotifyEvent read FOnDestroyed write FOnDestroyed;
    property OnStatusChanged: TNotifyEvent
      read FOnStatusChanged write FOnStatusChanged;
  end;

implementation

function TSessionTabBase.TabConnUuid: string;
begin
  Result := '';
end;

function TSessionTabBase.TabIsDeadLog: Boolean;
begin
  Result := False;
end;

function TSessionTabBase.TabIsFailedKept: Boolean;
begin
  Result := False;
end;

// sessions VIVANTES seulement: un onglet mort ne retient pas une suppression
function TSessionTabBase.CountSessionsIn(AUuids: TStrings): Integer;
begin
  Result := 0;
  if AUuids = nil then Exit;
  if (TabConnUuid <> '') and (AUuids.IndexOf(TabConnUuid) >= 0) and
     (not IsTerminalState(TabState)) then
    Result := 1;
end;

procedure TSessionTabBase.ShutdownSessionsIn(AUuids: TStrings);
begin
  if AUuids = nil then Exit;
  if (TabConnUuid <> '') and (AUuids.IndexOf(TabConnUuid) >= 0) then
    BeginShutdown;
end;

function TSessionTabBase.HasSessionFor(const AConnUuid: string): Boolean;
begin
  Result := (AConnUuid <> '') and (TabConnUuid = AConnUuid) and
    (not IsTerminalState(TabState));
end;

function TSessionTabBase.GrabThumbnail: TBitmap;
begin
  Result := nil;
end;

procedure TSessionTabBase.EmitNotice(const AMessage: string);
begin
  if Assigned(FOnNotice) then
    FOnNotice(AMessage);
end;

end.
