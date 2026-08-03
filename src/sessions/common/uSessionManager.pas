unit uSessionManager;

{$mode objfpc}{$H+}

// Recensement des sessions distantes: toute session vit ici, pas de
// thread detache sans proprietaire. L'onglet concret derive de TManagedSession.

interface

uses
  SysUtils, Classes, SyncObjs, uSessionState;

const
  // plafond global par defaut
  MAX_SESSIONS_DEFAULT = 32;

type
  ESessionLimitError = class(Exception);

  TManagedSession = class
  public
    function SessionState: TRemoteSessionState; virtual; abstract;
    function DisplayName: string; virtual; abstract;
    // ne doit pas bloquer
    procedure BeginShutdown; virtual; abstract;
  end;

  TSessionManager = class
  private
    FList: TFPList;
    FLock: TCriticalSection;
    FMax: Integer;
    function GetItem(AIndex: Integer): TManagedSession;
  public
    constructor Create(AMax: Integer = MAX_SESSIONS_DEFAULT);
    destructor Destroy; override;

    function CanOpen: Boolean;
    // leve ESessionLimitError si le plafond est atteint
    procedure RegisterSession(ASession: TManagedSession);
    procedure UnregisterSession(ASession: TManagedSession);

    function Count: Integer;
    function ActiveCount: Integer;
    // demande l'arret de toutes les sessions; ne libere rien
    procedure ShutdownAll;

    property Items[AIndex: Integer]: TManagedSession read GetItem; default;
    property MaxSessions: Integer read FMax;
  end;

implementation

constructor TSessionManager.Create(AMax: Integer);
begin
  inherited Create;
  FList := TFPList.Create;
  FLock := TCriticalSection.Create;
  if AMax < 1 then
    AMax := 1;
  FMax := AMax;
end;

destructor TSessionManager.Destroy;
begin
  FList.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSessionManager.GetItem(AIndex: Integer): TManagedSession;
begin
  FLock.Acquire;
  try
    Result := TManagedSession(FList[AIndex]);
  finally
    FLock.Release;
  end;
end;

function TSessionManager.CanOpen: Boolean;
begin
  FLock.Acquire;
  try
    Result := FList.Count < FMax;
  finally
    FLock.Release;
  end;
end;

procedure TSessionManager.RegisterSession(ASession: TManagedSession);
begin
  FLock.Acquire;
  try
    if FList.Count >= FMax then
      raise ESessionLimitError.CreateFmt(
        'Limite de %d sessions simultanees atteinte.', [FMax]);
    if FList.IndexOf(ASession) < 0 then
      FList.Add(ASession);
  finally
    FLock.Release;
  end;
end;

procedure TSessionManager.UnregisterSession(ASession: TManagedSession);
var
  i: Integer;
begin
  FLock.Acquire;
  try
    i := FList.IndexOf(ASession);
    if i >= 0 then
      FList.Delete(i);
  finally
    FLock.Release;
  end;
end;

function TSessionManager.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := FList.Count;
  finally
    FLock.Release;
  end;
end;

function TSessionManager.ActiveCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  FLock.Acquire;
  try
    for i := 0 to FList.Count - 1 do
      if not IsTerminalState(TManagedSession(FList[i]).SessionState) then
        Inc(Result);
  finally
    FLock.Release;
  end;
end;

procedure TSessionManager.ShutdownAll;
var
  i: Integer;
  snap: array of TManagedSession;
begin
  // snapshot sous verrou: BeginShutdown peut declencher un Unregister
  FLock.Acquire;
  try
    SetLength(snap, FList.Count);
    for i := 0 to FList.Count - 1 do
      snap[i] := TManagedSession(FList[i]);
  finally
    FLock.Release;
  end;
  for i := 0 to High(snap) do
    snap[i].BeginShutdown;
end;

end.
