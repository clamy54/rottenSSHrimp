unit uLog;

{$mode objfpc}{$H+}

// Journalisation locale: desactivee par defaut, aucune telemetrie, rotation
// bornee, 0600/0700. Ne journalise JAMAIS de secret -- discipline d'appelant,
// le module ne fournit que la redaction et le masquage. Les sessions ecrivent
// depuis leur thread reseau: tout passe par une section critique.

interface

uses
  SysUtils;

type
  TLogLevel = (llError, llWarning, llInfo, llDebug);

procedure LogConfigure(AEnabled: Boolean; AMinLevel: TLogLevel;
  AConfidential: Boolean);
procedure LogSetDir(const ADir: string);
procedure LogSetRotation(AMaxBytes: Int64; AMaxFiles: Integer);
function LogIsEnabled: Boolean;
function LogIsConfidential: Boolean;
function LogDir: string;
function LogFilePath: string;

procedure LogError(const AMsg: string);
procedure LogWarning(const AMsg: string);
procedure LogInfo(const AMsg: string);
procedure LogDebug(const AMsg: string);
procedure LogMsg(ALevel: TLogLevel; const AMsg: string);

function RedactHome(const APath: string): string;
function MaskHint(const AValue: string): string;

// A appeler DANS le bloc except: ailleurs, plus de backtrace a capturer.
function WriteCrashReport(E: Exception; const AContext: string): string;

procedure LogShutdown;

implementation

uses
  Classes, uAppPaths, uSafeSave;

const
  DEFAULT_MAX_BYTES = 1024 * 1024;
  DEFAULT_MAX_FILES = 5;
  MAX_MSG_CHARS = 8192;

var
  GLock: TRTLCriticalSection;
  GLockInit: Boolean = False;
  GEnabled: Boolean = False;
  GMinLevel: TLogLevel = llInfo;
  GConfidential: Boolean = False;
  GDir: string = '';
  GMaxBytes: Int64 = DEFAULT_MAX_BYTES;
  GMaxFiles: Integer = DEFAULT_MAX_FILES;

procedure EnsureLock;
begin
  if not GLockInit then
  begin
    InitCriticalSection(GLock);
    GLockInit := True;
  end;
end;

procedure LogConfigure(AEnabled: Boolean; AMinLevel: TLogLevel;
  AConfidential: Boolean);
begin
  EnsureLock;
  EnterCriticalSection(GLock);
  try
    GEnabled := AEnabled;
    GMinLevel := AMinLevel;
    GConfidential := AConfidential;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LogSetDir(const ADir: string);
begin
  EnsureLock;
  EnterCriticalSection(GLock);
  try
    GDir := ADir;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LogSetRotation(AMaxBytes: Int64; AMaxFiles: Integer);
begin
  EnsureLock;
  EnterCriticalSection(GLock);
  try
    if AMaxBytes > 0 then GMaxBytes := AMaxBytes;
    if AMaxFiles > 0 then GMaxFiles := AMaxFiles;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function LogIsEnabled: Boolean;
begin
  Result := GEnabled;
end;

function LogIsConfidential: Boolean;
begin
  Result := GConfidential;
end;

function LogDir: string;
begin
  if GDir <> '' then
    Result := GDir
  else
    Result := AppDataDir + PathDelim + 'logs';
end;

function LogFilePath: string;
begin
  Result := LogDir + PathDelim + 'rottensshrimp.log';
end;

function LevelTag(ALevel: TLogLevel): string;
begin
  case ALevel of
    llError:   Result := 'ERROR';
    llWarning: Result := 'WARN ';
    llInfo:    Result := 'INFO ';
    llDebug:   Result := 'DEBUG';
  else
    Result := '?????';
  end;
end;

// Une ligne = une entree: un retour a la ligne forgerait de fausses entrees.
function SanitizeLine(const AMsg: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := AMsg;
  if Length(Result) > MAX_MSG_CHARS then
    Result := Copy(Result, 1, MAX_MSG_CHARS) + ' [truncated]';
  for i := 1 to Length(Result) do
  begin
    c := Result[i];
    if (c < #32) or (c = #127) then
      Result[i] := ' ';
  end;
end;

function HomeDir: string;
begin
  {$IFDEF WINDOWS}
  Result := GetEnvironmentVariable('USERPROFILE');
  {$ELSE}
  Result := GetEnvironmentVariable('HOME');
  {$ENDIF}
end;

function RedactHome(const APath: string): string;
var
  home: string;
begin
  Result := APath;
  home := HomeDir;
  if home = '' then Exit;
  {$IFDEF WINDOWS}
  if (Length(APath) >= Length(home)) and
     (LowerCase(Copy(APath, 1, Length(home))) = LowerCase(home)) then
    Result := '~' + Copy(APath, Length(home) + 1, MaxInt);
  {$ELSE}
  if (Length(APath) >= Length(home)) and
     (Copy(APath, 1, Length(home)) = home) then
    Result := '~' + Copy(APath, Length(home) + 1, MaxInt);
  {$ENDIF}
end;

function MaskHint(const AValue: string): string;
begin
  if (AValue = '') or (not GConfidential) then
    Exit(AValue);
  Result := Copy(AValue, 1, 1) + Format('***(%d)', [Length(AValue)]);
end;

procedure RotateFiles;
var
  base, older, newer: string;
  i: Integer;
begin
  base := LogFilePath;
  older := base + '.' + IntToStr(GMaxFiles - 1);
  if FileExists(older) then
    DeleteFile(older);
  for i := GMaxFiles - 2 downto 1 do
  begin
    newer := base + '.' + IntToStr(i);
    older := base + '.' + IntToStr(i + 1);
    if FileExists(newer) then
      RenameFile(newer, older);
  end;
  if FileExists(base) then
    RenameFile(base, base + '.1');
end;

procedure EnsureLogDir;
var
  d: string;
begin
  d := LogDir;
  if not DirectoryExists(d) then
    if not ForceDirectories(d) then
      Exit;
  MakePrivateDir(d);
end;

function FileSizeOf(const APath: string): Int64;
var
  h: THandle;
begin
  Result := 0;
  h := FileOpen(APath, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit;
  try
    Result := FileSeek(h, Int64(0), fsFromEnd);
  finally
    FileClose(h);
  end;
end;

procedure AppendRaw(const APath, ALine: string);
var
  fs: TFileStream;
  existed: Boolean;
  bytes: TBytes;
begin
  existed := FileExists(APath);
  if existed then
    fs := TFileStream.Create(APath, fmOpenWrite or fmShareDenyWrite)
  else
    fs := TFileStream.Create(APath, fmCreate);
  try
    fs.Seek(0, soEnd);
    bytes := TEncoding.UTF8.GetBytes(ALine + LineEnding);
    if Length(bytes) > 0 then
      fs.WriteBuffer(bytes[0], Length(bytes));
  finally
    fs.Free;
  end;
  if not existed then
    MakePrivateFile(APath);
end;

procedure LogMsg(ALevel: TLogLevel; const AMsg: string);
var
  path, line: string;
  sz: Int64;
begin
  EnsureLock;
  EnterCriticalSection(GLock);
  try
    if not GEnabled then Exit;
    if Ord(ALevel) > Ord(GMinLevel) then Exit;
    EnsureLogDir;
    path := LogFilePath;
    if FileExists(path) then
    begin
      sz := FileSizeOf(path);
      if sz >= GMaxBytes then
        RotateFiles;
    end;
    line := Format('%s %s %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), LevelTag(ALevel),
       SanitizeLine(AMsg)]);
    try
      AppendRaw(path, line);
    except
      // un journal muet vaut mieux qu'une application morte
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LogError(const AMsg: string);
begin
  LogMsg(llError, AMsg);
end;

procedure LogWarning(const AMsg: string);
begin
  LogMsg(llWarning, AMsg);
end;

procedure LogInfo(const AMsg: string);
begin
  LogMsg(llInfo, AMsg);
end;

procedure LogDebug(const AMsg: string);
begin
  LogMsg(llDebug, AMsg);
end;

function DumpBacktrace: string;
var
  i: Integer;
  frames: PPointer;
begin
  Result := BackTraceStrFunc(ExceptAddr);
  frames := ExceptFrames;
  for i := 0 to ExceptFrameCount - 1 do
    Result := Result + LineEnding + BackTraceStrFunc(frames[i]);
end;

function CrashDir: string;
begin
  Result := AppDataDir + PathDelim + 'crash';
end;

function WriteCrashReport(E: Exception; const AContext: string): string;
var
  d, path, body: string;
  sl: TStringList;
begin
  Result := '';
  EnsureLock;
  EnterCriticalSection(GLock);
  try
    d := CrashDir;
    if not DirectoryExists(d) then
      if not ForceDirectories(d) then Exit;
    MakePrivateDir(d);
    path := d + PathDelim +
      'crash-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.txt';
    sl := TStringList.Create;
    try
      sl.Add('RottenSSHrimp crash report');
      sl.Add('time: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
      sl.Add('os: ' + {$I %FPCTARGETOS%} + '/' + {$I %FPCTARGETCPU%});
      if AContext <> '' then
        sl.Add('context: ' + AContext);
      if E <> nil then
      begin
        sl.Add('exception: ' + E.ClassName);
        sl.Add('message: ' + RedactHome(E.Message));
      end;
      sl.Add('');
      sl.Add('backtrace:');
      // le backtrace charrie des chemins de compilation
      body := RedactHome(DumpBacktrace);
      sl.Add(body);
      try
        sl.SaveToFile(path);
        MakePrivateFile(path);
        Result := path;
      except
        Result := '';
      end;
    finally
      sl.Free;
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure LogShutdown;
begin
  if GLockInit then
  begin
    DoneCriticalSection(GLock);
    GLockInit := False;
  end;
end;

end.
