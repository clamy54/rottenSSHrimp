{ Compat sockets multiplateforme: ce que l'unite Sockets de FPC laisse a la
  plateforme. Piege: l'echec d'un connect non bloquant se lit en writefds +
  SO_ERROR sous Unix, en EXCEPTFDS sous Windows.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uSockCompat;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, ctypes, Sockets
  {$IFDEF WINDOWS}, WinSock2{$ELSE}, BaseUnix{$ENDIF};

type
  TSockSet = {$IFDEF WINDOWS}WinSock2.TFDSet{$ELSE}BaseUnix.TFDSet{$ENDIF};
  PSockSet = ^TSockSet;

procedure SockSetZero(var ASet: TSockSet);
procedure SockSetAdd(AFd: cint; var ASet: TSockSet);
function SockSetHas(AFd: cint; var ASet: TSockSet): Boolean;

function SockSelect(AMaxFdPlus1: cint; ARead, AWrite, AExcept: PSockSet;
  AMs: Integer): cint;

function SockWaitConnect(AFd: cint; AMs: Integer): cint;

function SockSetNonBlocking(AFd: cint; AEnable: Boolean): Boolean;

function SockLastError: cint;
function SockErrIsInProgress(ACode: cint): Boolean;
function SockErrIsWouldBlock(ACode: cint): Boolean;
function SockErrIsIntr(ACode: cint): Boolean;

function SockGetPendingError(AFd: cint): cint;

// Debloque un thread coince en lecture. Ne FERME pas le descripteur.
procedure SockShutdownBoth(AFd: cint);

// Descripteur INDEPENDANT: la bibliotheque ferme le sien sans fermer le notre.
function SockDup(AFd: cint): cint;

procedure SockClose(AFd: cint);

// Detecte le pair MORT SANS FIN/RST: sinon select() attend un zombie sans fin.
procedure SockEnableKeepalive(AFd: cint; AIdleS, AIntervalS: Integer);

implementation

const
  SOCK_SHUT_RDWR = 2;

{$IFDEF WINDOWS}

procedure SockSetZero(var ASet: TSockSet);
begin
  WinSock2.FD_ZERO(ASet);
end;

procedure SockSetAdd(AFd: cint; var ASet: TSockSet);
begin
  WinSock2.FD_SET(TSocket(AFd), ASet);
end;

function SockSetHas(AFd: cint; var ASet: TSockSet): Boolean;
begin
  Result := WinSock2.FD_ISSET(TSocket(AFd), ASet);
end;

function SockSelect(AMaxFdPlus1: cint; ARead, AWrite, AExcept: PSockSet;
  AMs: Integer): cint;
var
  tv: WinSock2.TTimeVal;
  ptv: WinSock2.PTimeVal;
begin
  if AMs < 0 then
    ptv := nil
  else
  begin
    tv.tv_sec := AMs div 1000;
    tv.tv_usec := (AMs mod 1000) * 1000;
    ptv := @tv;
  end;
  Result := WinSock2.select(AMaxFdPlus1, WinSock2.PFDSet(ARead),
    WinSock2.PFDSet(AWrite), WinSock2.PFDSet(AExcept), ptv);
end;

function SockSetNonBlocking(AFd: cint; AEnable: Boolean): Boolean;
var
  v: u_long;
begin
  v := Ord(AEnable);
  Result := ioctlsocket(TSocket(AFd), Longint(FIONBIO), @v) = 0;
end;

function SockLastError: cint;
begin
  Result := WSAGetLastError;
end;

function SockErrIsInProgress(ACode: cint): Boolean;
begin
  // WSAEINPROGRESS = « appel bloquant en cours »; le connect repond WOULDBLOCK.
  Result := (ACode = WSAEWOULDBLOCK) or (ACode = WSAEINPROGRESS);
end;

function SockErrIsWouldBlock(ACode: cint): Boolean;
begin
  Result := ACode = WSAEWOULDBLOCK;
end;

function SockErrIsIntr(ACode: cint): Boolean;
begin
  Result := ACode = WSAEINTR;
end;

procedure SockShutdownBoth(AFd: cint);
begin
  WinSock2.shutdown(TSocket(AFd), SOCK_SHUT_RDWR);
end;

function GetCurrentProcessId: DWORD; stdcall; external 'kernel32.dll';

function SockDup(AFd: cint): cint;
const
  FROM_PROTOCOL_INFO = -1;
var
  info: TWSAProtocol_InfoW;
  ns: TSocket;
begin
  Result := -1;
  FillChar(info, SizeOf(info), 0);
  if WSADuplicateSocketW(TSocket(AFd), GetCurrentProcessId, @info) <> 0 then
    Exit;
  ns := WSASocketW(FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO, FROM_PROTOCOL_INFO,
    @info, 0, WSA_FLAG_OVERLAPPED);
  if ns = INVALID_SOCKET then
    Exit;
  Result := cint(ns);
end;

procedure SockClose(AFd: cint);
begin
  closesocket(TSocket(AFd));
end;

procedure SockEnableKeepalive(AFd: cint; AIdleS, AIntervalS: Integer);
const
  SIO_KEEPALIVE_VALS = DWORD($98000004);
type
  // mstcpip.h: durees en MILLISECONDES
  TTcpKeepalive = record
    OnOff, KeepAliveTime, KeepAliveInterval: u_long;
  end;
var
  ka: TTcpKeepalive;
  got: DWORD;
begin
  ka.OnOff := 1;
  ka.KeepAliveTime := DWORD(AIdleS) * 1000;
  ka.KeepAliveInterval := DWORD(AIntervalS) * 1000;
  got := 0;
  WSAIoctl(TSocket(AFd), SIO_KEEPALIVE_VALS, @ka, SizeOf(ka), nil, 0,
    @got, nil, nil);
end;

{$ELSE}

procedure SockSetZero(var ASet: TSockSet);
begin
  fpFD_ZERO(ASet);
end;

procedure SockSetAdd(AFd: cint; var ASet: TSockSet);
begin
  fpFD_SET(AFd, ASet);
end;

function SockSetHas(AFd: cint; var ASet: TSockSet): Boolean;
begin
  Result := fpFD_ISSET(AFd, ASet) = 1;
end;

function SockSelect(AMaxFdPlus1: cint; ARead, AWrite, AExcept: PSockSet;
  AMs: Integer): cint;
var
  tv: BaseUnix.TTimeVal;
  ptv: BaseUnix.PTimeVal;
begin
  if AMs < 0 then
    ptv := nil
  else
  begin
    tv.tv_sec := AMs div 1000;
    tv.tv_usec := (AMs mod 1000) * 1000;
    ptv := @tv;
  end;
  Result := fpSelect(AMaxFdPlus1, ARead, AWrite, AExcept, ptv);
end;

function SockSetNonBlocking(AFd: cint; AEnable: Boolean): Boolean;
var
  flags: cint;
begin
  flags := FpFcntl(AFd, F_GetFl, 0);
  if flags < 0 then
    Exit(False);
  if AEnable then
    flags := flags or O_NONBLOCK
  else
    flags := flags and (not O_NONBLOCK);
  Result := FpFcntl(AFd, F_SetFl, flags) = 0;
end;

function SockLastError: cint;
begin
  Result := fpGetErrno;
end;

function SockErrIsInProgress(ACode: cint): Boolean;
begin
  Result := ACode = ESysEINPROGRESS;
end;

function SockErrIsWouldBlock(ACode: cint): Boolean;
begin
  Result := (ACode = ESysEAGAIN) or (ACode = ESysEWOULDBLOCK);
end;

function SockErrIsIntr(ACode: cint): Boolean;
begin
  Result := ACode = ESysEINTR;
end;

procedure SockShutdownBoth(AFd: cint);
begin
  fpshutdown(AFd, SOCK_SHUT_RDWR);
end;

function SockDup(AFd: cint): cint;
begin
  Result := FpDup(AFd);
end;

procedure SockClose(AFd: cint);
begin
  FpClose(AFd);
end;

procedure SockEnableKeepalive(AFd: cint; AIdleS, AIntervalS: Integer);
const
  // netinet/tcp.h: memes noms, valeurs differentes selon l'OS
  {$IFDEF DARWIN}
  TCP_KEEPIDLE_OPT  = $10;
  TCP_KEEPINTVL_OPT = $101;
  TCP_KEEPCNT_OPT   = $102;
  {$ELSE}
  TCP_KEEPIDLE_OPT  = 4;
  TCP_KEEPINTVL_OPT = 5;
  TCP_KEEPCNT_OPT   = 6;
  {$ENDIF}
  KEEP_PROBES = 4;
var
  v: cint;
begin
  v := 1;
  fpSetSockOpt(AFd, SOL_SOCKET, SO_KEEPALIVE, @v, SizeOf(v));
  v := AIdleS;
  fpSetSockOpt(AFd, IPPROTO_TCP, TCP_KEEPIDLE_OPT, @v, SizeOf(v));
  v := AIntervalS;
  fpSetSockOpt(AFd, IPPROTO_TCP, TCP_KEEPINTVL_OPT, @v, SizeOf(v));
  v := KEEP_PROBES;
  fpSetSockOpt(AFd, IPPROTO_TCP, TCP_KEEPCNT_OPT, @v, SizeOf(v));
end;

{$ENDIF}

function SockWaitConnect(AFd: cint; AMs: Integer): cint;
var
  wfds: TSockSet;
  {$IFDEF WINDOWS}
  efds: TSockSet;
  {$ENDIF}
begin
  SockSetZero(wfds);
  SockSetAdd(AFd, wfds);
  {$IFDEF WINDOWS}
  SockSetZero(efds);
  SockSetAdd(AFd, efds);
  Result := SockSelect(AFd + 1, nil, @wfds, @efds, AMs);
  {$ELSE}
  Result := SockSelect(AFd + 1, nil, @wfds, nil, AMs);
  {$ENDIF}
end;

function SockGetPendingError(AFd: cint): cint;
var
  err: cint;
  errLen: TSocklen;
begin
  err := 0;
  errLen := SizeOf(err);
  if fpGetSockOpt(AFd, SOL_SOCKET, SO_ERROR, @err, @errLen) <> 0 then
    Exit(-1);
  Result := err;
end;

end.
