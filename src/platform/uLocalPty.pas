unit uLocalPty;

{$mode objfpc}{$H+}

// Pseudo-terminal local. Darwin/Linux: fork/exec du shell sur un pty maitre.
// Windows: PowerShell sur une pseudo-console ConPTY (10 1809+), memes sequences
// VT. Le lecteur pousse par TThread.Queue; aucun appel LCL ici.

interface

uses
  // Windows AVANT SysUtils: sinon son GetEnvironmentVariable masque l'autre.
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  Classes, SysUtils{$IFDEF UNIX}, BaseUnix, Unix{$ENDIF};

type
  TPtyDataEvent = procedure(const AData: RawByteString) of object;
  TPtyExitEvent = procedure(AExitCode: Integer) of object;

  TLocalPty = class;

  TPtyReaderThread = class(TThread)
  private
    FOwner: TLocalPty;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TLocalPty);
  end;

  TLocalPty = class
  private
    FRunning: Boolean;
    FStopping: Boolean;
    FExitCode: Integer;
    FOnData: TPtyDataEvent;
    FOnExit: TPtyExitEvent;
    FReader: TPtyReaderThread;
    FLock: TRTLCriticalSection;
    FPending: RawByteString;
    FExited: Boolean;
    {$IFDEF UNIX}
    FMasterFd: Integer;
    FChildPid: Integer;
    {$ENDIF}
    {$IFDEF WINDOWS}
    FPty: Pointer;
    FInWrite: THandle;
    FOutRead: THandle;
    FProcess: THandle;
    {$ENDIF}
    procedure DrainData;
    procedure NotifyExit;
  public
    constructor Create;
    destructor Destroy; override;
    function Start(ACols, ARows: Integer; out AError: string): Boolean;
    procedure WriteData(const AData: RawByteString);
    procedure Resize(ACols, ARows: Integer);
    procedure Stop;
    property Running: Boolean read FRunning;
    property OnData: TPtyDataEvent read FOnData write FOnData;
    property OnExit: TPtyExitEvent read FOnExit write FOnExit;
  end;

implementation

constructor TPtyReaderThread.Create(AOwner: TLocalPty);
begin
  inherited Create(False);
  FOwner := AOwner;
  FreeOnTerminate := False;
end;

{$IFDEF UNIX}

type
  TWinSize = record
    ws_row: Word;
    ws_col: Word;
    ws_xpixel: Word;
    ws_ypixel: Word;
  end;

const
  {$IFDEF DARWIN}
  TIOCSWINSZ = $80087467;
  TIOCSCTTY  = $20007461;
  {$ELSE}
  TIOCSWINSZ = $5414;
  TIOCSCTTY  = $540E;
  {$ENDIF}

function posix_openpt(oflag: cint): cint; cdecl; external 'c';
function grantpt(fd: cint): cint; cdecl; external 'c';
function unlockpt(fd: cint): cint; cdecl; external 'c';
function ptsname(fd: cint): PAnsiChar; cdecl; external 'c';
function execve(path: PAnsiChar; argv, envp: PPAnsiChar): cint; cdecl;
  external 'c';

procedure TPtyReaderThread.Execute;
var
  buf: array[0..16383] of Byte;
  n: SizeInt;
  status: cint;
  i, mfd, sel: cint;
  fds: TFDSet;
  tv: TTimeVal;
begin
  // select, pas FpRead: sous macOS fermer le maitre ne reveille pas un read.
  n := 0;
  while not Terminated do
  begin
    mfd := FOwner.FMasterFd;
    if mfd < 0 then Break;
    fpFD_ZERO(fds);
    fpFD_SET(mfd, fds);
    tv.tv_sec := 0;
    tv.tv_usec := 200 * 1000;
    sel := fpSelect(mfd + 1, @fds, nil, nil, @tv);
    if Terminated then Break;
    if sel < 0 then
    begin
      if fpGetErrno = ESysEINTR then Continue;
      Break;
    end;
    if sel = 0 then Continue;
    n := FpRead(mfd, buf, SizeOf(buf));
    if n <= 0 then Break;
    EnterCriticalSection(FOwner.FLock);
    try
      SetLength(FOwner.FPending, Length(FOwner.FPending) + n);
      Move(buf, FOwner.FPending[Length(FOwner.FPending) - n + 1], n);
    finally
      LeaveCriticalSection(FOwner.FLock);
    end;
    Queue(@FOwner.DrainData);
  end;
  // Attente bornee puis SIGKILL: un waitpid bloquant pendrait sur un teigneux.
  status := 0;
  if FOwner.FChildPid > 0 then
  begin
    if FOwner.FStopping then
    begin
      i := 0;
      while FpWaitPid(FOwner.FChildPid, @status, WNOHANG) = 0 do
      begin
        if i = 30 then
          FpKill(FOwner.FChildPid, SIGKILL);
        if i > 80 then Break;
        Sleep(10);
        Inc(i);
      end;
    end
    else
      FpWaitPid(FOwner.FChildPid, @status, 0);
  end;
  FOwner.FExitCode := WEXITSTATUS(status);
  FOwner.FExited := True;
  if not FOwner.FStopping then
    Queue(@FOwner.NotifyExit);
end;

{$ENDIF}

{$IFDEF WINDOWS}

// ConPTY resolu DYNAMIQUEMENT: avant 1809, Start rend un message clair.

type
  TCreatePseudoConsole = function(ASize: TCoord; hInput, hOutput: THandle;
    AFlags: DWORD; out APty: Pointer): HRESULT; stdcall;
  TResizePseudoConsole = function(APty: Pointer; ASize: TCoord): HRESULT; stdcall;
  TClosePseudoConsole = procedure(APty: Pointer); stdcall;

  TStartupInfoExW = record
    StartupInfo: TStartupInfoW;
    lpAttributeList: Pointer;
  end;

const
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = PtrUInt($00020016);
  EXTENDED_STARTUPINFO_PRESENT_ = DWORD($00080000);

function InitializeProcThreadAttributeList(AList: Pointer;
  ACount, AFlags: DWORD; var ASize: PtrUInt): WINBOOL; stdcall;
  external 'kernel32.dll';
function UpdateProcThreadAttribute(AList: Pointer; AFlags: DWORD;
  AAttribute: PtrUInt; AValue: Pointer; ASize: PtrUInt;
  APrevious, AReturnSize: Pointer): WINBOOL; stdcall;
  external 'kernel32.dll';
procedure DeleteProcThreadAttributeList(AList: Pointer); stdcall;
  external 'kernel32.dll';

var
  GCreatePseudoConsole: TCreatePseudoConsole = nil;
  GResizePseudoConsole: TResizePseudoConsole = nil;
  GClosePseudoConsole: TClosePseudoConsole = nil;

function ConPtyAvailable: Boolean;
var
  k32: HMODULE;
begin
  if not Assigned(GCreatePseudoConsole) then
  begin
    k32 := GetModuleHandle('kernel32.dll');
    Pointer(GCreatePseudoConsole) := GetProcAddress(k32, 'CreatePseudoConsole');
    Pointer(GResizePseudoConsole) := GetProcAddress(k32, 'ResizePseudoConsole');
    Pointer(GClosePseudoConsole) := GetProcAddress(k32, 'ClosePseudoConsole');
  end;
  Result := Assigned(GCreatePseudoConsole) and Assigned(GResizePseudoConsole)
    and Assigned(GClosePseudoConsole);
end;

procedure TPtyReaderThread.Execute;
var
  buf: array[0..16383] of Byte;
  avail, got, code: DWORD;
  dead: Integer;
begin
  // ConPTY ne ferme pas le tube a la mort du shell: la fin se lit sur le HANDLE.
  dead := 0;
  while not Terminated do
  begin
    avail := 0;
    if not PeekNamedPipe(FOwner.FOutRead, nil, 0, nil, @avail, nil) then
      Break;
    if avail = 0 then
    begin
      if WaitForSingleObject(FOwner.FProcess, 0) = WAIT_OBJECT_0 then
      begin
        Inc(dead);
        if dead > 5 then Break;
      end;
      Sleep(10);
      Continue;
    end;
    dead := 0;
    if avail > SizeOf(buf) then
      avail := SizeOf(buf);
    got := 0;
    if (not ReadFile(FOwner.FOutRead, buf, avail, got, nil)) or (got = 0) then
      Break;
    EnterCriticalSection(FOwner.FLock);
    try
      SetLength(FOwner.FPending, Length(FOwner.FPending) + got);
      Move(buf, FOwner.FPending[Length(FOwner.FPending) - got + 1], got);
    finally
      LeaveCriticalSection(FOwner.FLock);
    end;
    Queue(@FOwner.DrainData);
  end;
  code := 127;
  if not FOwner.FStopping then
  begin
    WaitForSingleObject(FOwner.FProcess, 3000);
    GetExitCodeProcess(FOwner.FProcess, @code);
  end;
  FOwner.FExitCode := Integer(code);
  FOwner.FExited := True;
  if not FOwner.FStopping then
    Queue(@FOwner.NotifyExit);
end;

{$ENDIF}

{$IF NOT DEFINED(UNIX) AND NOT DEFINED(WINDOWS)}
procedure TPtyReaderThread.Execute;
begin
end;
{$ENDIF}

constructor TLocalPty.Create;
begin
  inherited Create;
  {$IFDEF UNIX}
  FMasterFd := -1;
  FChildPid := -1;
  {$ENDIF}
  {$IFDEF WINDOWS}
  FPty := nil;
  FInWrite := 0;
  FOutRead := 0;
  FProcess := 0;
  {$ENDIF}
  InitCriticalSection(FLock);
end;

destructor TLocalPty.Destroy;
begin
  Stop;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TLocalPty.DrainData;
var
  chunk: RawByteString;
begin
  EnterCriticalSection(FLock);
  try
    chunk := FPending;
    FPending := '';
  finally
    LeaveCriticalSection(FLock);
  end;
  if (chunk <> '') and (not FStopping) and Assigned(FOnData) then
    FOnData(chunk);
end;

procedure TLocalPty.NotifyExit;
begin
  FRunning := False;
  if Assigned(FOnExit) then
    FOnExit(FExitCode);
end;

{$IFDEF UNIX}

function TLocalPty.Start(ACols, ARows: Integer; out AError: string): Boolean;
var
  masterFd, slaveFd: cint;
  slaveName: RawByteString;
  pid: TPid;
  ws: TWinSize;
  shellPath: string;
  argv: array[0..1] of PAnsiChar;
  arg0, homeDir, envItem: RawByteString;
  envStr: array of RawByteString;
  envp: array of PAnsiChar;
  envCount, i, n: Integer;
  fd, maxfd: cint;
  rl: TRLimit;
begin
  Result := False;
  AError := '';
  if FRunning then
  begin
    AError := 'pty already started';
    Exit;
  end;

  masterFd := posix_openpt(O_RDWR or O_NOCTTY);
  if masterFd < 0 then
  begin
    AError := 'posix_openpt: ' + SysErrorMessage(fpgeterrno);
    Exit;
  end;
  if (grantpt(masterFd) <> 0) or (unlockpt(masterFd) <> 0) then
  begin
    AError := 'grantpt/unlockpt: ' + SysErrorMessage(fpgeterrno);
    FpClose(masterFd);
    Exit;
  end;
  slaveName := ptsname(masterFd);
  if slaveName = '' then
  begin
    AError := 'ptsname failed';
    FpClose(masterFd);
    Exit;
  end;

  ws.ws_row := Word(ARows);
  ws.ws_col := Word(ACols);
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
  // Taille posee sur l'ESCLAVE dans l'enfant: pre-fork, macOS l'ignore.

  shellPath := GetEnvironmentVariable('SHELL');
  if (shellPath = '') or (not FileExists(shellPath)) then
  begin
    {$IFDEF DARWIN}
    shellPath := '/bin/zsh';
    {$ELSE}
    shellPath := '/bin/bash';
    {$ENDIF}
    if not FileExists(shellPath) then
      shellPath := '/bin/sh';
  end;

  // Tout ce qui ALLOUE passe AVANT le fork: l'enfant herite du verrou du tas.
  homeDir := GetEnvironmentVariable('HOME');
  arg0 := '-' + ExtractFileName(shellPath);
  argv[0] := PAnsiChar(arg0);
  argv[1] := nil;

  // Prefabrique pour execve (setenv allouerait). TERM ecrase: une GUI n'en a pas.
  envCount := GetEnvironmentVariableCount;
  SetLength(envStr, envCount + 2);
  n := 0;
  for i := 1 to envCount do
  begin
    envItem := RawByteString(GetEnvironmentString(i));
    if (Copy(envItem, 1, 5) = 'TERM=') or
       (Copy(envItem, 1, 10) = 'COLORTERM=') then
      Continue;
    envStr[n] := envItem;
    Inc(n);
  end;
  envStr[n] := 'TERM=xterm-256color';
  Inc(n);
  envStr[n] := 'COLORTERM=truecolor';
  Inc(n);
  SetLength(envStr, n);
  SetLength(envp, n + 1);
  for i := 0 to n - 1 do
    envp[i] := PAnsiChar(envStr[i]);
  envp[n] := nil;

  pid := FpFork;
  if pid < 0 then
  begin
    AError := 'fork: ' + SysErrorMessage(fpgeterrno);
    FpClose(masterFd);
    Exit;
  end;

  if pid = 0 then
  begin
    FpClose(masterFd);
    FpSetsid;
    slaveFd := FpOpen(PAnsiChar(slaveName), O_RDWR);
    if slaveFd < 0 then
      FpExit(127);
    FpIOCtl(slaveFd, TIOCSCTTY, nil);
    FpIOCtl(slaveFd, TIOCSWINSZ, @ws);
    FpDup2(slaveFd, 0);
    FpDup2(slaveFd, 1);
    FpDup2(slaveFd, 2);
    if slaveFd > 2 then
      FpClose(slaveFd);
    // Fermer TOUS les fd herites: le shell y lirait tunnels et secrets.
    if FpGetRLimit(RLIMIT_NOFILE, @rl) = 0 then
      maxfd := cint(rl.rlim_cur)
    else
      maxfd := 1024;
    if (maxfd <= 0) or (maxfd > 65536) then
      maxfd := 65536;
    for fd := 3 to maxfd - 1 do
      FpClose(fd);
    // SIGPIPE rendu au DEFAUT: ignore pour nos sockets, un pipeline en meurt.
    FpSignal(SigPipe, SignalHandler(SIG_DFL));
    if homeDir <> '' then
      FpChdir(PAnsiChar(homeDir));
    execve(PAnsiChar(shellPath), @argv[0], @envp[0]);
    FpExit(127);
  end;

  FMasterFd := masterFd;
  FChildPid := pid;
  FRunning := True;
  FStopping := False;
  FExited := False;
  FPending := '';
  FReader := TPtyReaderThread.Create(Self);
  Result := True;
end;

procedure TLocalPty.WriteData(const AData: RawByteString);
var
  off: SizeInt;
  n: SizeInt;
begin
  if (not FRunning) or (FMasterFd < 0) or (AData = '') then
    Exit;
  off := 1;
  while off <= Length(AData) do
  begin
    n := FpWrite(FMasterFd, AData[off], Length(AData) - off + 1);
    if n <= 0 then
      Break;
    Inc(off, n);
  end;
end;

procedure TLocalPty.Resize(ACols, ARows: Integer);
var
  ws: TWinSize;
begin
  if (not FRunning) or (FMasterFd < 0) then
    Exit;
  ws.ws_row := Word(ARows);
  ws.ws_col := Word(ACols);
  ws.ws_xpixel := 0;
  ws.ws_ypixel := 0;
  FpIOCtl(FMasterFd, TIOCSWINSZ, @ws);
  if FChildPid > 0 then
    FpKill(FChildPid, SIGWINCH);
end;

procedure TLocalPty.Stop;
begin
  if FMasterFd < 0 then
    Exit;
  FStopping := True;
  FRunning := False;
  if (FChildPid > 0) and (not FExited) then
    FpKill(FChildPid, SIGHUP);
  // Joindre le lecteur AVANT de fermer le maitre: son select a besoin du fd.
  if Assigned(FReader) then
  begin
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  FpClose(FMasterFd);
  FMasterFd := -1;
  FChildPid := -1;
end;

{$ELSE}
{$IFDEF WINDOWS}

function TLocalPty.Start(ACols, ARows: Integer; out AError: string): Boolean;
var
  inRead, outWrite: THandle;
  sz: TCoord;
  hr: HRESULT;
  need: PtrUInt;
  attrs: Pointer;
  siex: TStartupInfoExW;
  pi: TProcessInformation;
  cmd, cwd: UnicodeString;
  pcwd: PWideChar;
  shellPath, home: string;

  procedure CloseIf(var h: THandle);
  begin
    if h <> 0 then
    begin
      CloseHandle(h);
      h := 0;
    end;
  end;

begin
  Result := False;
  AError := '';
  if FRunning then
  begin
    AError := 'pty already started';
    Exit;
  end;
  if not ConPtyAvailable then
  begin
    AError := 'ConPTY unavailable (Windows 10 1809 or later is required)';
    Exit;
  end;

  shellPath := GetEnvironmentVariable('SystemRoot') +
    '\System32\WindowsPowerShell\v1.0\powershell.exe';
  if not FileExists(shellPath) then
  begin
    AError := 'powershell.exe not found: ' + shellPath;
    Exit;
  end;

  inRead := 0;
  outWrite := 0;
  if (not CreatePipe(@inRead, @FInWrite, nil, 0)) or
     (not CreatePipe(@FOutRead, @outWrite, nil, 0)) then
  begin
    AError := 'CreatePipe: ' + SysErrorMessage(GetLastError);
    CloseIf(inRead);
    CloseIf(FInWrite);
    CloseIf(FOutRead);
    CloseIf(outWrite);
    Exit;
  end;

  sz.X := SmallInt(ACols);
  sz.Y := SmallInt(ARows);
  FPty := nil;
  attrs := nil;
  begin
    hr := GCreatePseudoConsole(sz, inRead, outWrite, 0, FPty);
    if hr <> S_OK then
    begin
      AError := Format('CreatePseudoConsole failed (HRESULT 0x%.8x)',
        [LongWord(hr)]);
      FPty := nil;
      CloseIf(inRead);
      CloseIf(outWrite);
      CloseIf(FInWrite);
      CloseIf(FOutRead);
      Exit;
    end;

    need := 0;
    InitializeProcThreadAttributeList(nil, 1, 0, need);
    attrs := AllocMem(need);
    if (not InitializeProcThreadAttributeList(attrs, 1, 0, need)) or
       (not UpdateProcThreadAttribute(attrs, 0,
          PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, FPty, SizeOf(Pointer), nil, nil))
    then
    begin
      AError := 'ProcThreadAttributeList: ' + SysErrorMessage(GetLastError);
      FreeMem(attrs);
      GClosePseudoConsole(FPty);
      FPty := nil;
      CloseIf(inRead);
      CloseIf(outWrite);
      CloseIf(FInWrite);
      CloseIf(FOutRead);
      Exit;
    end;

    FillChar(siex, SizeOf(siex), 0);
    siex.StartupInfo.cb := SizeOf(siex);
    siex.lpAttributeList := attrs;
    // STARTF_USESTDHANDLES avec des hStd* NULS, NON DOCUMENTE: sinon CreateProcess
    // duplique les handles du parent et le shell ecrit a cote de la console.
    siex.StartupInfo.dwFlags := STARTF_USESTDHANDLES;

    cmd := UTF8Decode('"' + shellPath + '" -NoLogo');
    UniqueString(cmd);
    home := GetEnvironmentVariable('USERPROFILE');
    pcwd := nil;
    if home <> '' then
    begin
      cwd := UTF8Decode(home);
      pcwd := PWideChar(cwd);
    end;

    FillChar(pi, SizeOf(pi), 0);
    if not CreateProcessW(nil, PWideChar(cmd), nil, nil, False,
         EXTENDED_STARTUPINFO_PRESENT_, nil, pcwd, siex.StartupInfo, pi) then
    begin
      AError := 'CreateProcessW(powershell): ' + SysErrorMessage(GetLastError);
      DeleteProcThreadAttributeList(attrs);
      FreeMem(attrs);
      GClosePseudoConsole(FPty);
      FPty := nil;
      CloseIf(inRead);
      CloseIf(outWrite);
      CloseIf(FInWrite);
      CloseIf(FOutRead);
      Exit;
    end;
  end;
  CloseHandle(pi.hThread);
  FProcess := pi.hProcess;
  DeleteProcThreadAttributeList(attrs);
  FreeMem(attrs);
  CloseIf(inRead);
  CloseIf(outWrite);

  FRunning := True;
  FStopping := False;
  FExited := False;
  FPending := '';
  FReader := TPtyReaderThread.Create(Self);
  Result := True;
end;

procedure TLocalPty.WriteData(const AData: RawByteString);
var
  off: SizeInt;
  n: DWORD;
begin
  if (not FRunning) or (FInWrite = 0) or (AData = '') then
    Exit;
  off := 1;
  while off <= Length(AData) do
  begin
    n := 0;
    if not WriteFile(FInWrite, AData[off], DWORD(Length(AData) - off + 1),
         n, nil) then
      Break;
    if n = 0 then
      Break;
    Inc(off, n);
  end;
end;

procedure TLocalPty.Resize(ACols, ARows: Integer);
var
  sz: TCoord;
begin
  if (not FRunning) or (FPty = nil) then
    Exit;
  sz.X := SmallInt(ACols);
  sz.Y := SmallInt(ARows);
  GResizePseudoConsole(FPty, sz);
end;

procedure TLocalPty.Stop;
begin
  if FPty = nil then
    Exit;
  FStopping := True;
  FRunning := False;
  if Assigned(FReader) then
  begin
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  // Avant ClosePseudoConsole: elle bloque sur un tube que plus personne ne vide.
  if FOutRead <> 0 then
  begin
    CloseHandle(FOutRead);
    FOutRead := 0;
  end;
  if FInWrite <> 0 then
  begin
    CloseHandle(FInWrite);
    FInWrite := 0;
  end;
  // L'equivalent du SIGHUP: la console du shell disparait.
  GClosePseudoConsole(FPty);
  FPty := nil;
  if FProcess <> 0 then
  begin
    if WaitForSingleObject(FProcess, 300) <> WAIT_OBJECT_0 then
      TerminateProcess(FProcess, 1);
    CloseHandle(FProcess);
    FProcess := 0;
  end;
end;

{$ELSE}

function TLocalPty.Start(ACols, ARows: Integer; out AError: string): Boolean;
begin
  AError := 'local pty not available on this platform';
  Result := False;
end;

procedure TLocalPty.WriteData(const AData: RawByteString);
begin
end;

procedure TLocalPty.Resize(ACols, ARows: Integer);
begin
end;

procedure TLocalPty.Stop;
begin
end;

{$ENDIF}
{$ENDIF}

end.
