{ Onglet « Ping »: un TPinger sur l'hote d'une connexion, et ce qu'un admin
  regarde pendant un reboot ou une liaison douteuse: etat courant et depuis
  quand, compteurs, RTT min/moy/max/dernier/mdev, pertes consecutives et
  courbe des dernieres sondes. Pas de journal: la courbe suffit, et la page
  doit rester lisible d'un coup d'oeil.

  Tableau et courbe sont dessines a la main: les listes natives restaient
  blanches en plein theme sombre, avec la police systeme. Ici les couleurs
  viennent du theme et la police est celle embarquee, identique sur les
  trois OS.

  Ce n'est PAS une session: TabConnUuid reste vide, l'hote n'apparait pas
  « actif » dans l'arbre et une suppression n'est pas retenue par cet onglet.
  PingConnUuid sert seulement a ne pas ouvrir deux onglets pour le meme hote.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uPingTab;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Controls, ComCtrls, Forms, StdCtrls, ExtCtrls,
  Graphics, uIcmpPing, uSessionState, uSessionTabBase;

const
  // Un thread et un echo toutes les deux secondes chacun: au-dela on ne
  // surveille plus, on charge la machine.
  PING_MAX_TABS = 10;
  PING_INTERVAL_MS = 2000;
  PING_TIMEOUT_MS = 2000;

type
  TPingTab = class(TSessionTabBase)
  private
    FConnUuid: string;
    FDisplayName: string;
    FHost: string;
    FAddr: string;
    FFallback: Boolean;
    FResolveErr: string;
    FPinger: TPinger;
    FClosing: Boolean;
    // compteurs
    FSent, FRecv: Integer;
    FMin, FMax, FSum, FSumSq, FLast: Double;
    FStreakLoss, FWorstStreak: Integer;
    FHasSample, FReplying: Boolean;
    FStateSince: TDateTime;
    FStartedAt: TDateTime;
    // courbe: derniers echantillons, -1 = perte
    FGraph: array of Double;
    FGraphCount: Integer;
    // UI
    FRoot: TPanel;
    FTitle: TLabel;
    FStateLbl: TLabel;
    FSinceLbl: TLabel;
    FBtnPause, FBtnReset, FBtnCopy: TButton;
    FStatsBox: TPaintBox;
    FGraphBox: TPaintBox;
    FTick: TTimer;
    procedure PingerSample(const ASample: TPingSample);
    procedure PingerResolved(const AAddr, AErr: string; AFallback: Boolean);
    procedure PauseClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure CopyClick(Sender: TObject);
    procedure StatsPaint(Sender: TObject);
    procedure GraphPaint(Sender: TObject);
    procedure TickTimer(Sender: TObject);
    procedure ResetCounters;
    procedure UpdateState;
    procedure UpdateCaption;
    function StatsText: string;
  public
    constructor CreateTab(APages: TPageControl; const AConnUuid, ADisplayName,
      AHost: string);
    destructor Destroy; override;
    procedure Start;
    function TabState: TRemoteSessionState; override;
    function TabIsDeadLog: Boolean; override;
    function TabBarCaption: string; override;
    function ConfirmClose: Boolean; override;
    procedure BeginShutdown; override;
    procedure FocusContent; override;
    property PingConnUuid: string read FConnUuid;
  end;

implementation

uses
  Math, Clipbrd, uTheme;

const
  GRAPH_POINTS = 180;
  PAD = 12;

function FmtMs(AValue: Double): string;
begin
  if AValue < 10 then
    Result := FormatFloat('0.00', AValue) + ' ms'
  else if AValue < 100 then
    Result := FormatFloat('0.0', AValue) + ' ms'
  else
    Result := FormatFloat('0', AValue) + ' ms';
end;

function FmtElapsed(ASince: TDateTime): string;
var
  secs: Int64;
begin
  secs := Round((Now - ASince) * 86400);
  if secs < 0 then secs := 0;
  if secs < 60 then
    Result := Format('%d s', [secs])
  else if secs < 3600 then
    Result := Format('%d min %d s', [secs div 60, secs mod 60])
  else
    Result := Format('%d h %d min', [secs div 3600, (secs mod 3600) div 60]);
end;

{ ============================== TPingTab ============================== }

constructor TPingTab.CreateTab(APages: TPageControl; const AConnUuid,
  ADisplayName, AHost: string);
var
  row: TPanel;

  function AddBtn(AParent: TWinControl; const ACaption: string;
    AHandler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := AParent;
    Result.Caption := ACaption;
    Result.AutoSize := True;
    Result.OnClick := AHandler;
    Result.Align := alLeft;
    Result.BorderSpacing.Right := 8;
  end;

  function AddPanel(AParent: TWinControl; AAlign: TAlign; AHeight: Integer): TPanel;
  begin
    Result := TPanel.Create(Self);
    Result.Parent := AParent;
    Result.Align := AAlign;
    Result.Height := AHeight;
    Result.BevelOuter := bvNone;
    Result.ParentBackground := False;
    Result.ParentColor := False;
    Result.Color := clAppBg;
  end;

begin
  inherited Create(APages);
  PageControl := APages;
  FConnUuid := AConnUuid;
  FDisplayName := ADisplayName;
  FHost := AHost;
  FStartedAt := Now;
  SetLength(FGraph, GRAPH_POINTS);
  ResetCounters;

  // fond uniforme du theme: la page elle-meme reste au widgetset
  FRoot := AddPanel(Self, alClient, 0);

  // De haut en bas: titre, etat, depuis quand, boutons, tableau, courbe.
  FTitle := TLabel.Create(Self);
  FTitle.Parent := FRoot;
  FTitle.Align := alTop;
  FTitle.BorderSpacing.Left := PAD;
  FTitle.BorderSpacing.Top := 10;
  FTitle.Font.Style := [fsBold];
  FTitle.Font.Color := clAppFg;
  FTitle.Caption := FDisplayName + '  —  ' + FHost;

  FStateLbl := TLabel.Create(Self);
  FStateLbl.Parent := FRoot;
  FStateLbl.Align := alTop;
  FStateLbl.BorderSpacing.Left := PAD;
  FStateLbl.BorderSpacing.Top := 6;
  FStateLbl.Font.Size := 13;
  FStateLbl.Font.Style := [fsBold];
  FStateLbl.Caption := 'Resolving…';

  FSinceLbl := TLabel.Create(Self);
  FSinceLbl.Parent := FRoot;
  FSinceLbl.Align := alTop;
  FSinceLbl.BorderSpacing.Left := PAD;
  FSinceLbl.BorderSpacing.Top := 2;
  FSinceLbl.Font.Color := clStatusText;
  FSinceLbl.Caption := ' ';

  row := AddPanel(FRoot, alTop, 34);
  row.BorderSpacing.Left := PAD;
  row.BorderSpacing.Top := 8;
  FBtnPause := AddBtn(row, 'Pause', @PauseClick);
  FBtnReset := AddBtn(row, 'Reset', @ResetClick);
  FBtnCopy := AddBtn(row, 'Copy Stats', @CopyClick);

  FStatsBox := TPaintBox.Create(Self);
  FStatsBox.Parent := FRoot;
  FStatsBox.Align := alTop;
  FStatsBox.Height := 56;
  FStatsBox.BorderSpacing.Top := 8;
  FStatsBox.OnPaint := @StatsPaint;

  FGraphBox := TPaintBox.Create(Self);
  FGraphBox.Parent := FRoot;
  FGraphBox.Align := alTop;
  FGraphBox.Height := 120;
  FGraphBox.BorderSpacing.Left := PAD;
  FGraphBox.BorderSpacing.Right := PAD;
  FGraphBox.BorderSpacing.Top := 4;
  FGraphBox.OnPaint := @GraphPaint;

  // ordre d'empilement des alTop: le dernier cree serait en haut
  FTitle.Top := 0;
  FStateLbl.Top := 1;
  FSinceLbl.Top := 2;
  row.Top := 3;
  FStatsBox.Top := 4;
  FGraphBox.Top := 5;

  FTick := TTimer.Create(Self);
  FTick.Interval := 1000;
  FTick.OnTimer := @TickTimer;
  FTick.Enabled := True;

  // police embarquee partout, puis les styles qu'ApplyUiFont a ecrases
  ApplyUiFont(Self);
  FStateLbl.Font.Size := 13;
  FStateLbl.Font.Style := [fsBold];
  FTitle.Font.Style := [fsBold];
  UpdateState;
  UpdateCaption;
end;

destructor TPingTab.Destroy;
var
  cb: TNotifyEvent;
begin
  FClosing := True;
  if FTick <> nil then FTick.Enabled := False;
  FreeAndNil(FPinger);   // Stop: join du thread + purge de sa file Queue
  cb := FOnDestroyed;
  inherited Destroy;
  if Assigned(cb) then
    cb(nil);
end;

procedure TPingTab.Start;
begin
  if FPinger <> nil then Exit;
  FPinger := TPinger.Create(FHost, PING_INTERVAL_MS, PING_TIMEOUT_MS);
  FPinger.OnSample := @PingerSample;
  FPinger.OnResolved := @PingerResolved;
  FPinger.Start;
end;

procedure TPingTab.ResetCounters;
begin
  FSent := 0; FRecv := 0;
  FMin := 0; FMax := 0; FSum := 0; FSumSq := 0; FLast := 0;
  FStreakLoss := 0; FWorstStreak := 0;
  FGraphCount := 0;
  FStartedAt := Now;
end;

procedure TPingTab.PingerResolved(const AAddr, AErr: string; AFallback: Boolean);
begin
  if FClosing then Exit;
  FAddr := AAddr;
  FResolveErr := AErr;
  FFallback := AFallback;
  if AAddr <> '' then
  begin
    if SameText(AAddr, FHost) then
      FTitle.Caption := FDisplayName + '  —  ' + FHost
    else
      FTitle.Caption := FDisplayName + '  —  ' + FHost + '  (' + AAddr + ')';
    if AFallback then
      FTitle.Caption := FTitle.Caption + '   [system ping]';
  end;
  UpdateState;
  UpdateCaption;
end;

procedure TPingTab.PingerSample(const ASample: TPingSample);
var
  wasReplying, first: Boolean;
begin
  if FClosing then Exit;
  first := not FHasSample;
  wasReplying := FReplying;
  FHasSample := True;
  Inc(FSent);
  if ASample.Kind = prkReply then
  begin
    Inc(FRecv);
    FLast := ASample.RttMs;
    if (FRecv = 1) or (ASample.RttMs < FMin) then FMin := ASample.RttMs;
    if (FRecv = 1) or (ASample.RttMs > FMax) then FMax := ASample.RttMs;
    FSum := FSum + ASample.RttMs;
    FSumSq := FSumSq + ASample.RttMs * ASample.RttMs;
    FStreakLoss := 0;
    FReplying := True;
  end
  else
  begin
    Inc(FStreakLoss);
    if FStreakLoss > FWorstStreak then FWorstStreak := FStreakLoss;
    FReplying := False;
  end;
  if first or (wasReplying <> FReplying) then
    FStateSince := ASample.When;

  // courbe
  if FGraphCount < GRAPH_POINTS then
    Inc(FGraphCount)
  else
    Move(FGraph[1], FGraph[0], (GRAPH_POINTS - 1) * SizeOf(Double));
  if ASample.Kind = prkReply then
    FGraph[FGraphCount - 1] := ASample.RttMs
  else
    FGraph[FGraphCount - 1] := -1;

  FStatsBox.Invalidate;
  FGraphBox.Invalidate;
  UpdateState;
  if first or (wasReplying <> FReplying) then
    UpdateCaption;
end;

// Deux lignes: intitules en gris, valeurs en clair. Colonnes a la largeur du
// plus large des deux, la police est a chasse fixe.
procedure TPingTab.StatsPaint(Sender: TObject);
const
  N = 12;
  HEAD: array[0..N - 1] of string = ('Sent', 'Received', 'Lost', 'Loss',
    'Min', 'Avg', 'Max', 'Last', 'Mdev', 'Lost in a row', 'Worst streak',
    'Running for');
var
  cv: TCanvas;
  vals: array[0..N - 1] of string;
  lost, i, x, cw, y1, y2: Integer;
  avg, mdev: Double;
begin
  cv := FStatsBox.Canvas;
  cv.Font := FStatsBox.Font;
  cv.Brush.Style := bsSolid;
  cv.Brush.Color := clAppBg;
  cv.FillRect(0, 0, FStatsBox.Width, FStatsBox.Height);
  lost := FSent - FRecv;
  vals[0] := IntToStr(FSent);
  vals[1] := IntToStr(FRecv);
  vals[2] := IntToStr(lost);
  if FSent > 0 then
    vals[3] := FormatFloat('0.#', lost * 100 / FSent) + ' %'
  else
    vals[3] := '–';
  if FRecv > 0 then
  begin
    avg := FSum / FRecv;
    mdev := Sqrt(Max(0, FSumSq / FRecv - avg * avg));
    vals[4] := FmtMs(FMin);
    vals[5] := FmtMs(avg);
    vals[6] := FmtMs(FMax);
    vals[7] := FmtMs(FLast);
    vals[8] := FmtMs(mdev);
  end
  else
    for i := 4 to 8 do vals[i] := '–';
  vals[9] := IntToStr(FStreakLoss);
  vals[10] := IntToStr(FWorstStreak);
  vals[11] := FmtElapsed(FStartedAt);

  cv.Brush.Style := bsClear;
  y1 := 6;
  y2 := y1 + cv.TextHeight('Ag') + 6;
  x := PAD;
  for i := 0 to N - 1 do
  begin
    cw := Max(cv.TextWidth(HEAD[i]), cv.TextWidth(vals[i])) + 22;
    cv.Font.Color := clStatusText;
    cv.TextOut(x, y1, HEAD[i]);
    if (i = 2) and (lost > 0) then
      cv.Font.Color := clTabDead
    else if (i = 9) and (FStreakLoss > 0) then
      cv.Font.Color := clTabDead
    else
      cv.Font.Color := clAppFg;
    cv.TextOut(x, y2, vals[i]);
    Inc(x, cw);
  end;
  cv.Pen.Color := clBorder;
  cv.Line(PAD, FStatsBox.Height - 1, FStatsBox.Width - PAD, FStatsBox.Height - 1);
end;

procedure TPingTab.UpdateState;
begin
  if FResolveErr <> '' then
  begin
    FStateLbl.Font.Color := clTabDead;
    FStateLbl.Caption := 'Cannot resolve: ' + FResolveErr;
    FSinceLbl.Caption := ' ';
    Exit;
  end;
  if not FHasSample then
  begin
    FStateLbl.Font.Color := clStatusText;
    if FAddr = '' then
      FStateLbl.Caption := 'Resolving…'
    else
      FStateLbl.Caption := 'Waiting for the first reply…';
    FSinceLbl.Caption := ' ';
    Exit;
  end;
  if (FPinger <> nil) and FPinger.Paused then
  begin
    FStateLbl.Font.Color := clStatusText;
    FStateLbl.Caption := 'Paused';
    FSinceLbl.Caption := ' ';
    Exit;
  end;
  if FReplying then
  begin
    FStateLbl.Font.Color := clSideActive;
    FStateLbl.Caption := 'Replying  ·  ' + FmtMs(FLast);
    FSinceLbl.Caption := 'replying since ' +
      FormatDateTime('hh:nn:ss', FStateSince) + '  (' +
      FmtElapsed(FStateSince) + ')';
  end
  else
  begin
    FStateLbl.Font.Color := clTabDead;
    FStateLbl.Caption := Format('No reply  ·  %d lost in a row', [FStreakLoss]);
    // pas « down »: beaucoup de serveurs filtrent l'ICMP
    FSinceLbl.Caption := 'no reply since ' +
      FormatDateTime('hh:nn:ss', FStateSince) + '  (' +
      FmtElapsed(FStateSince) + ')';
  end;
end;

procedure TPingTab.UpdateCaption;
begin
  if FHasSample and (not FReplying) then
    Caption := '✕ ' + FDisplayName + ' — Ping'
  else
    Caption := '● ' + FDisplayName + ' — Ping';
  if Assigned(FOnStatusChanged) then
    FOnStatusChanged(Self);
end;

procedure TPingTab.TickTimer(Sender: TObject);
begin
  if FClosing then Exit;
  // les « depuis » et « running for » vieillissent meme sans nouveau paquet
  UpdateState;
  FStatsBox.Invalidate;
end;

procedure TPingTab.GraphPaint(Sender: TObject);
var
  cv: TCanvas;
  w, h, i, x, bw, n, bh, barTop: Integer;
  maxv, v: Double;
  r: TRect;
begin
  cv := FGraphBox.Canvas;
  cv.Font := FGraphBox.Font;
  w := FGraphBox.Width;
  h := FGraphBox.Height;
  cv.Brush.Color := clTermBg;
  cv.Brush.Style := bsSolid;
  cv.FillRect(0, 0, w, h);
  n := FGraphCount;
  cv.Brush.Style := bsClear;
  cv.Font.Color := clStatusText;
  if n = 0 then
  begin
    cv.TextOut(8, 8, 'RTT of the last ' + IntToStr(GRAPH_POINTS) +
      ' probes, red bars are losses');
    Exit;
  end;
  maxv := 1;
  for i := 0 to n - 1 do
    if FGraph[i] > maxv then maxv := FGraph[i];
  // la legende occupe une bande en haut; les barres commencent dessous
  barTop := cv.TextHeight('Ag') + 10;
  bw := Max(2, w div GRAPH_POINTS);
  cv.Brush.Style := bsSolid;
  for i := 0 to n - 1 do
  begin
    x := w - (n - i) * bw;
    if x < 0 then Continue;
    v := FGraph[i];
    r.Left := x;
    r.Right := x + bw - 1;
    r.Bottom := h - 2;
    if v < 0 then
    begin
      cv.Brush.Color := clTabDead;
      r.Top := barTop;
    end
    else
    begin
      cv.Brush.Color := clSideActive;
      bh := Round((h - 2 - barTop) * v / maxv);
      if bh < 1 then bh := 1;
      r.Top := r.Bottom - bh;
    end;
    cv.FillRect(r);
  end;
  cv.Brush.Style := bsClear;
  cv.Font.Color := clStatusText;
  cv.TextOut(6, 4, 'max ' + FmtMs(maxv) + '   ·   last ' +
    IntToStr(GRAPH_POINTS) + ' probes');
end;

procedure TPingTab.PauseClick(Sender: TObject);
begin
  if FPinger = nil then Exit;
  FPinger.Paused := not FPinger.Paused;
  if FPinger.Paused then
    FBtnPause.Caption := 'Resume'
  else
    FBtnPause.Caption := 'Pause';
  UpdateState;
end;

procedure TPingTab.ResetClick(Sender: TObject);
begin
  ResetCounters;
  FStatsBox.Invalidate;
  FGraphBox.Invalidate;
  UpdateState;
end;

function TPingTab.StatsText: string;
var
  avg, mdev: Double;
begin
  Result := Format('--- %s (%s) ping statistics ---', [FHost, FAddr]) +
    LineEnding;
  if FSent > 0 then
    Result := Result + Format('%d packets transmitted, %d received, ' +
      '%.1f%% packet loss, %d lost in a row (worst %d)',
      [FSent, FRecv, (FSent - FRecv) * 100 / FSent, FStreakLoss, FWorstStreak]) +
      LineEnding
  else
    Result := Result + 'no packet sent yet' + LineEnding;
  if FRecv > 0 then
  begin
    avg := FSum / FRecv;
    mdev := Sqrt(Max(0, FSumSq / FRecv - avg * avg));
    Result := Result + Format('rtt min/avg/max/mdev = %.3f/%.3f/%.3f/%.3f ms',
      [FMin, avg, FMax, mdev]) + LineEnding;
  end;
  if FHasSample then
  begin
    if FReplying then
      Result := Result + 'replying since '
    else
      Result := Result + 'no reply since ';
    Result := Result + FormatDateTime('yyyy-mm-dd hh:nn:ss', FStateSince) +
      LineEnding;
  end;
end;

procedure TPingTab.CopyClick(Sender: TObject);
begin
  try
    Clipboard.AsText := StatsText;
  except
  end;
end;

function TPingTab.TabState: TRemoteSessionState;
begin
  if FResolveErr <> '' then
    Result := rssFailed
  else if not FHasSample then
    Result := rssConnecting
  else if FReplying then
    Result := rssConnected
  else
    Result := rssFailed;
end;

// pastille rouge tant que l'hote ne repond pas
function TPingTab.TabIsDeadLog: Boolean;
begin
  Result := (FResolveErr <> '') or (FHasSample and (not FReplying));
end;

function TPingTab.TabBarCaption: string;
begin
  Result := FDisplayName + ' — Ping';
end;

function TPingTab.ConfirmClose: Boolean;
begin
  Result := True;
end;

procedure TPingTab.BeginShutdown;
begin
  if FPinger <> nil then
    FPinger.Terminate;
end;

procedure TPingTab.FocusContent;
begin
  if (FBtnPause <> nil) and FBtnPause.CanFocus then
    FBtnPause.SetFocus;
end;

end.
