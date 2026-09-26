unit uSessionState;

{$mode objfpc}{$H+}

// Etat de session SSH/RDP. Ecrit par le thread de session, lu par l'UI: verrou.

interface

uses
  SysUtils, SyncObjs;

type
  ESessionStateError = class(Exception);

  TRemoteSessionState = (
    rssCreated,
    rssConnecting,
    rssAuthenticating,
    rssConnected,
    rssDisconnecting,
    rssDisconnected,
    rssFailed
  );

  TSessionStateMachine = class
  private
    FState: TRemoteSessionState;
    FLock: TCriticalSection;
    function GetState: TRemoteSessionState;
  public
    constructor Create;
    destructor Destroy; override;

    function CanTransition(ANext: TRemoteSessionState): Boolean;
    procedure TransitionTo(ANext: TRemoteSessionState);
    // chemins d'arret: deux fermetures peuvent se courir apres
    function TryTransitionTo(ANext: TRemoteSessionState): Boolean;

    property State: TRemoteSessionState read GetState;
  end;

function IsTerminalState(AState: TRemoteSessionState): Boolean;
function IsTransitionAllowed(AFrom, ATo: TRemoteSessionState): Boolean;
function SessionStateName(AState: TRemoteSessionState): string;

implementation

const
  STATE_NAMES: array[TRemoteSessionState] of string = (
    'Created', 'Connecting', 'Authenticating', 'Connected',
    'Disconnecting', 'Disconnected', 'Failed');

function SessionStateName(AState: TRemoteSessionState): string;
begin
  Result := STATE_NAMES[AState];
end;

function IsTerminalState(AState: TRemoteSessionState): Boolean;
begin
  Result := AState in [rssDisconnected, rssFailed];
end;

function IsTransitionAllowed(AFrom, ATo: TRemoteSessionState): Boolean;
begin
  // Pas de resurrection: une reconnexion cree une nouvelle session.
  case AFrom of
    rssCreated:
      Result := ATo in [rssConnecting, rssDisconnecting, rssFailed];
    rssConnecting:
      Result := ATo in [rssAuthenticating, rssDisconnecting, rssFailed];
    rssAuthenticating:
      Result := ATo in [rssConnected, rssDisconnecting, rssFailed];
    rssConnected:
      Result := ATo in [rssDisconnecting, rssFailed];
    rssDisconnecting:
      Result := ATo in [rssDisconnected, rssFailed];
    rssDisconnected:
      Result := False;
    rssFailed:
      Result := False;
  else
    Result := False;
  end;
end;

constructor TSessionStateMachine.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FState := rssCreated;
end;

destructor TSessionStateMachine.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

function TSessionStateMachine.GetState: TRemoteSessionState;
begin
  FLock.Acquire;
  try
    Result := FState;
  finally
    FLock.Release;
  end;
end;

function TSessionStateMachine.CanTransition(ANext: TRemoteSessionState): Boolean;
begin
  FLock.Acquire;
  try
    Result := IsTransitionAllowed(FState, ANext);
  finally
    FLock.Release;
  end;
end;

procedure TSessionStateMachine.TransitionTo(ANext: TRemoteSessionState);
var
  cur: TRemoteSessionState;
begin
  FLock.Acquire;
  try
    cur := FState;
    if not IsTransitionAllowed(cur, ANext) then
      raise ESessionStateError.CreateFmt(
        'Invalid session transition: %s -> %s',
        [STATE_NAMES[cur], STATE_NAMES[ANext]]);
    FState := ANext;
  finally
    FLock.Release;
  end;
end;

function TSessionStateMachine.TryTransitionTo(ANext: TRemoteSessionState): Boolean;
begin
  FLock.Acquire;
  try
    Result := IsTransitionAllowed(FState, ANext);
    if Result then
      FState := ANext;
  finally
    FLock.Release;
  end;
end;

end.
