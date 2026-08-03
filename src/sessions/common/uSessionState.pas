unit uSessionState;

{$mode objfpc}{$H+}

// Machine a etats de session distante, partagee SSH/RDP: transitions
// invalides interdites. Ecrite par le thread de session, lue par l'UI, d'ou le
// verrou.

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
    // leve ESessionStateError si la transition est refusee
    procedure TransitionTo(ANext: TRemoteSessionState);
    // pour les chemins d'arret, ou deux demandes de fermeture se courent apres
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
  // Tout ce qui n'est pas ici est refuse: pas de retour arriere, pas de
  // resurrection d'un terminal -- une reconnexion cree une session.
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

{ TSessionStateMachine }

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
