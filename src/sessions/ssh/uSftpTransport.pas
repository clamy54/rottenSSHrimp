{ Transport SFTP de l'onglet Scp. Un thread par onglet, proprietaire exclusif
  de la socket, du LIBSSH2_SESSION, de la session SFTP et de TOUTES les
  poignees distantes. Aucun pointeur libssh2 ne sort d'ici, aucune LCL n'y
  entre, aucun secret n'apparait dans un message.

  Tout appel libssh2 est NON BLOQUANT: la boucle d'attente respecte la
  direction que libssh2 reclame, une echeance, et l'annulation. Une operation
  qu'on ne peut pas interrompre est une interface qui gele.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uSftpTransport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes,
  uLibssh2Api, uSshTransport, uSessionState, uScpBackend, uScpErrors,
  uScpPaths, uTransferQueue, uScpEngine;

type
  TSftpTransport = class;

  // Backend distant, valide QUE sur le thread de transport: ses methodes
  // touchent des pointeurs libssh2 qui n'appartiennent qu'a lui.
  TSftpFileSystem = class(TScpFileSystem)
  private
    FOwner: TSftpTransport;
    FIdentity: string;
    // Erreur exploitable du dernier echec: le code SSH_FX_* si libssh2 signale
    // une erreur de protocole SFTP, le sien sinon.
    function LastError(const AOp, ASubject: string;
      ARc: Integer; AIsDirOp: Boolean): TScpError;
    function WaitAgain(var ADeadline: QWord): Boolean;
  public
    constructor Create(AOwner: TSftpTransport; const AIdentity: string);
    function IsRemote: Boolean; override;
    function DisplayName: string; override;
    function Canceled: Boolean; override;

    function HomeDir(out APath: string; out AErr: TScpError): Boolean; override;
    function RealPath(const APath: string; out AResolved: string;
      out AErr: TScpError): Boolean; override;
    function List(const APath: string; out AEntries: TScpEntryArray;
      out AErr: TScpError): Boolean; override;
    function Stat(const APath: string; AFollowLink: Boolean;
      out AEntry: TScpEntry; out AErr: TScpError): Boolean; override;
    function Exists(const APath: string; out AFound: Boolean;
      out AErr: TScpError): Boolean; override;
    function MakeDir(const APath: string;
      out AErr: TScpError): Boolean; override;
    function Rename(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; override;
    function ReplaceAtomic(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; override;
    function DeleteFile(const APath: string;
      out AErr: TScpError): Boolean; override;
    function DeleteDir(const APath: string;
      out AErr: TScpError): Boolean; override;
    function OpenRead(const APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function CreateTemp(const ADir: string; AMode: LongWord;
      out APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function OpenAppend(const APath: string; AOffset: Int64;
      out AHandle: TScpFileHandle; out AErr: TScpError): Boolean; override;
    function Read(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out AGot: Integer; out AErr: TScpError): Boolean; override;
    function Write(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out APut: Integer; out AErr: TScpError): Boolean; override;
    function Seek(AHandle: TScpFileHandle; AOffset: Int64;
      out AErr: TScpError): Boolean; override;
    function Flush(AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function Close(AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; override;
    function SetMTime(const APath: string; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; override;
    function SetMode(const APath: string; AMode: LongWord;
      out AErr: TScpError): Boolean; override;
    function Join(const ABase, AName: string): string; override;
    function Parent(const APath: string): string; override;
    function BaseName(const APath: string): string; override;
    function Normalize(const APath: string): string; override;
    function IsUnder(const ARoot, APath: string): Boolean; override;
    function CheckName(const AName: string): TNameVerdict; override;
    function CollisionKey(const AName: string): string; override;
  end;

  TSftpCommandKind = (
    sckListRemote,
    sckRemoteHome,
    sckRemoteMkdir,
    sckRemoteRename,
    sckRemoteDelete,      // fichier ou dossier, recursif si dossier
    sckEnqueueUpload,
    sckEnqueueDownload,
    sckEnqueueDuplicate,  // copie dans le MEME dossier, sous un autre nom
    sckRunQueue,
    sckRetryFailed,
    sckCleanupPartials,
    sckFreeSpace);

  // Commande posee par l'interface. Le thread en devient proprietaire et la
  // libere; l'interface ne la relit jamais.
  TSftpCommand = class
  public
    Kind: TSftpCommandKind;
    PathA: string;
    PathB: string;
    Sources: TStringArray;
    TargetDir: string;
    TargetRoot: string;
    OnRemote: Boolean;    // duplication: de quel cote elle se fait
    Serial: Int64;   // rapproche une reponse de sa demande
  end;

  TSftpListEvent = procedure(const APath: string;
    const AEntries: TScpEntryArray; const AError: TScpError) of object;
  TSftpPathEvent = procedure(const APath: string;
    const AError: TScpError) of object;
  TSftpSimpleEvent = procedure(const AError: TScpError) of object;
  TSftpQueueEvent = procedure of object;
  TSftpFreeSpaceEvent = procedure(const APath: string;
    AFreeBytes: Int64) of object;
  TSftpNoteEvent = procedure(const AText: string) of object;
  TSftpConflictEvent = TScpConflictEvent;
  TSftpNonAtomicEvent = TScpNonAtomicEvent;

  TSftpTransport = class(TSshChannelBase)
  private
    FStates: TSessionStateMachine;
    FSftp: PLIBSSH2_SFTP;
    FRemote: TSftpFileSystem;
    FLocal: TScpFileSystem;      // possede par l'onglet, pas par nous
    FQueue: TTransferQueue;      // idem
    // Prete par l'onglet, qui survit a une reconnexion avec son registre de
    // partiels, ou cree ici si personne ne l'a fourni.
    FEngine: TScpTransferEngine;
    FOwnsEngine: Boolean;

    FCmdLock: TCriticalSection;
    FCmds: TFPList;
    FCmdEvent: TEvent;
    FSerial: Int64;

    // Resultats publies vers l'interface, dans l'ordre: un Queue(@PublishNext)
    // par resultat. Un champ partage ferait lire au premier rappel le resultat du
    // second, et au second une liste vide.
    FPubLock: TCriticalSection;
    FPub: TFPList;

    FOnListed: TSftpListEvent;
    FOnHome: TSftpPathEvent;
    FOnOpDone: TSftpSimpleEvent;
    FOnQueueChanged: TSftpQueueEvent;
    FOnFreeSpace: TSftpFreeSpaceEvent;
    FOnNote: TSftpNoteEvent;
    FOnConflict: TSftpConflictEvent;
    FOnNonAtomic: TSftpNonAtomicEvent;
    FOnConnected: TNotifyEvent;
    FOnFailed: TSftpSimpleEvent;

    FErrLock: TCriticalSection;
    FErrorMsg: string;
    FConnIdentity: string;
    FPaused: Boolean;

    // Decisions qui appartiennent a l'utilisateur: la question part sur le thread
    // UI, l'attente est bornee et reveillable. Meme motif qu'une cle d'hote.
    FConflictEvent: TEvent;
    FConflictInfo: TConflictInfo;
    FConflictDecision: TConflictDecision;
    FNonAtomicEvent: TEvent;
    FNonAtomicPath: string;
    FNonAtomicAllow: Boolean;
    procedure AskConflictOnUi;
    procedure AskNonAtomicOnUi;

    procedure PostResult(AResult: TObject);
    procedure PublishNext;
    procedure PublishQueueChanged;
    procedure PublishConnected;

    procedure PostCommand(ACmd: TSftpCommand);
    function TakeCommand: TSftpCommand;
    function HasPendingCommand: Boolean;
    procedure ClearCommands;

    function OpenSftp: Boolean;
    procedure CommandLoop;
    procedure RunCommand(ACmd: TSftpCommand);
    procedure DoRunQueue;
    function RemoveTree(const APath: string; ADepth: Integer;
      out AErr: TScpError): Boolean;
    // Octets libres sous APath, -1 si le serveur n'annonce pas
    // statvfs@openssh.com. Thread de transport uniquement.
    function RemoteFreeBytes(const APath: string): Int64;
    procedure Cleanup;
    procedure Fail(const AMessage: string);
    procedure SetState(ANext: TRemoteSessionState);

    procedure EngineConflict(const AInfo: TConflictInfo;
      var ADecision: TConflictDecision);
    procedure EngineNonAtomic(const ATargetPath: string; var AAllow: Boolean);
    procedure EngineProgress(AItem: TTransferItem);
    procedure EngineNote(const AText: string);
  protected
    procedure ReportError(const AMessage: string); override;
    function WaitIo(AMs: Integer): Boolean; override;
    function ErrHandshakeRefused: string; override;
    procedure Execute; override;
  public
    // Prend possession de AParams. ALocal, AQueue et AEngine restent a l'appelant
    // et doivent survivre a ce thread. AEngine a nil: le transport cree le sien.
    constructor Create(AParams: TSshConnectParams; ALocal: TScpFileSystem;
      AQueue: TTransferQueue; AEngine: TScpTransferEngine = nil);
    destructor Destroy; override;

    // --- appelables depuis le thread UI ---
    procedure RequestList(const APath: string);
    procedure RequestHome;
    procedure RequestMkdir(const APath: string);
    procedure RequestRename(const AFrom, ATo: string);
    procedure RequestDelete(const APath: string);
    procedure RequestUpload(const ASources: TStringArray;
      const ARemoteDir, ARemoteRoot: string);
    procedure RequestDownload(const ASources: TStringArray;
      const ALocalDir, ALocalRoot: string);
    // Duplique dans ADir. Le nom libre est cherche par le thread qui copie: le
    // calculer ici donnerait une reponse perimee avant l'ecriture.
    procedure RequestDuplicate(const ASources: TStringArray;
      const ADir: string; AOnRemote: Boolean);
    procedure RequestRunQueue;
    procedure RequestRetryFailed;
    procedure RequestCleanupPartials;
    // Espace libre distant, rendu par OnFreeSpace. -1 sans statvfs@openssh.com:
    // l'appelant s'abstient plutot que de supposer de la place.
    procedure RequestFreeSpace(const APath: string);
    procedure PauseTransfers;
    procedure ResumeTransfers;
    procedure Shutdown;

    function State: TRemoteSessionState;
    function LastErrorText: string;
    function Identity: string;
    function ActivePartialCount: Integer;

    property OnListed: TSftpListEvent read FOnListed write FOnListed;
    property OnHome: TSftpPathEvent read FOnHome write FOnHome;
    property OnOpDone: TSftpSimpleEvent read FOnOpDone write FOnOpDone;
    property OnQueueChanged: TSftpQueueEvent
      read FOnQueueChanged write FOnQueueChanged;
    property OnFreeSpace: TSftpFreeSpaceEvent
      read FOnFreeSpace write FOnFreeSpace;
    property OnNote: TSftpNoteEvent read FOnNote write FOnNote;
    property OnConflict: TSftpConflictEvent read FOnConflict write FOnConflict;
    property OnNonAtomic: TSftpNonAtomicEvent
      read FOnNonAtomic write FOnNonAtomic;
    property OnConnected: TNotifyEvent read FOnConnected write FOnConnected;
    property OnFailed: TSftpSimpleEvent read FOnFailed write FOnFailed;
    property OnHostKey: TSshHostKeyEvent read FOnHostKey write FOnHostKey;
    property OnHostKeyLookup: TSshHostKeyLookup
      read FOnHostKeyLookup write FOnHostKeyLookup;
    property OnHostKeySave: TSshHostKeySave
      read FOnHostKeySave write FOnHostKeySave;
    property OnSkNotice: TSshSkNoticeEvent read FOnSkNotice write FOnSkNotice;
    property OnSkPin: TSshSkPinEvent read FOnSkPin write FOnSkPin;
  end;

implementation

uses
  Sockets, uSockCompat, uNetResolve, uSodiumApi;

const
  // Echeance PAR OPERATION: borne un serveur muet sans empecher un gros
  // transfert d'avancer, chaque appel la reprenant a zero.
  SFTP_OP_TIMEOUT_MS = 60 * 1000;
  // Patience devant une question a l'utilisateur, la meme que pour une cle
  // d'hote. Au-dela on s'abstient.
  CONFLICT_ANSWER_TIMEOUT_MS = 5 * 60 * 1000;
  SFTP_POLL_MS = 20;
  CONNECT_POLL_MS = 200;
  SHUTDOWN_GRACE_MS = 3000;
  // Tampons de readdir, bornes FIXES: jamais une taille venue du serveur.
  SFTP_NAME_MAX = 1024;
  SFTP_LONGENTRY_MAX = 2048;
  SFTP_MAX_RM_DEPTH = 64;
  TEMP_PREFIX = '.rssh-';
  TEMP_SUFFIX = '.part';
  TEMP_RANDOM_BYTES = 12;

type
  TSftpHandle = class(TScpFileHandle)
    H: PLIBSSH2_SFTP_HANDLE;
    Path: string;
  end;

  TSftpResultKind = (srListed, srHome, srOpDone, srFreeSpace, srNote,
    srFailed);

  TSftpResult = class
    Kind: TSftpResultKind;
    Path: string;
    Entries: TScpEntryArray;
    Error: TScpError;
    FreeBytes: Int64;
    Text: string;
  end;

function RandomSuffix: string;
const
  HexD: array[0..15] of Char = '0123456789abcdef';
var
  b: array[0..TEMP_RANDOM_BYTES - 1] of Byte;
  i: Integer;
begin
  SodiumEnsureLoaded;
  randombytes_buf(@b[0], TEMP_RANDOM_BYTES);
  SetLength(Result, TEMP_RANDOM_BYTES * 2);
  for i := 0 to TEMP_RANDOM_BYTES - 1 do
  begin
    Result[i * 2 + 1] := HexD[b[i] shr 4];
    Result[i * 2 + 2] := HexD[b[i] and $0F];
  end;
end;

{ TSftpFileSystem }

constructor TSftpFileSystem.Create(AOwner: TSftpTransport;
  const AIdentity: string);
begin
  inherited Create;
  FOwner := AOwner;
  FIdentity := AIdentity;
end;

function TSftpFileSystem.IsRemote: Boolean;
begin
  Result := True;
end;

function TSftpFileSystem.DisplayName: string;
begin
  Result := FIdentity;
end;

function TSftpFileSystem.Canceled: Boolean;
begin
  Result := FOwner.Terminated;
end;

function TSftpFileSystem.WaitAgain(var ADeadline: QWord): Boolean;
begin
  if FOwner.Terminated then Exit(False);
  if GetTickCount64 >= ADeadline then Exit(False);
  // La DIRECTION vient de libssh2: attendre en lecture quand il veut ecrire,
  // c'est attendre pour rien.
  FOwner.WaitIo(SFTP_POLL_MS);
  Result := not FOwner.Terminated;
end;

function TSftpFileSystem.LastError(const AOp, ASubject: string;
  ARc: Integer; AIsDirOp: Boolean): TScpError;
var
  fx: LongWord;
  msg: PAnsiChar;
  len, rc: cint;
  detail: string;
begin
  detail := '';
  msg := nil;
  len := 0;
  rc := libssh2_session_last_error(FOwner.FSession, @msg, @len, 0);
  if (msg <> nil) and (len > 0) then
    // Chaine NON FIABLE: elle part dans l'interface, donc elle est neutralisee.
    detail := DisplaySafeName(string(AnsiString(msg)));
  if ARc = LIBSSH2_ERROR_SFTP_PROTOCOL then
  begin
    fx := 0;
    if FOwner.FSftp <> nil then
      fx := libssh2_sftp_last_error(FOwner.FSftp);
    Exit(MakeScpError(SftpStatusToKind(fx, AIsDirOp), AOp,
      DisplaySafeName(ASubject), detail));
  end;
  case ARc of
    LIBSSH2_ERROR_EAGAIN, LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_SOCKET_TIMEOUT:
      Result := MakeScpError(sekTimeout, AOp, DisplaySafeName(ASubject),
        detail);
    LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_SEND,
    LIBSSH2_ERROR_CHANNEL_CLOSED:
      Result := MakeScpError(sekConnectionLost, AOp,
        DisplaySafeName(ASubject), detail);
  else
    Result := MakeScpError(sekOther, AOp, DisplaySafeName(ASubject),
      Format('%s (libssh2 %d)', [detail, ARc]));
  end;
  if FOwner.Terminated then
    Result.Kind := sekCanceled;
  if rc = 0 then ;
end;

function TSftpFileSystem.HomeDir(out APath: string;
  out AErr: TScpError): Boolean;
begin
  Result := RealPath('.', APath, AErr);
end;

function TSftpFileSystem.RealPath(const APath: string; out AResolved: string;
  out AErr: TScpError): Boolean;
var
  buf: array[0..SFTP_NAME_MAX - 1] of AnsiChar;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AResolved := '';
  AErr := NoScpError;
  p := AnsiString(APath);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_symlink_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      @buf[0], SFTP_NAME_MAX, LIBSSH2_SFTP_REALPATH);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if rc < 0 then
  begin
    AErr := LastError('Resolving', APath, rc, True);
    Exit(False);
  end;
  if rc > SFTP_NAME_MAX then rc := SFTP_NAME_MAX;
  SetString(AResolved, PAnsiChar(@buf[0]), rc);
  AResolved := RemoteNormalize(AResolved);
  Result := True;
end;

// Attributs SFTP -> entree. Un champ n'est lu que si son bit de presence est
// pose: le lire sans, c'est inventer une taille ou une date.
procedure AttrsToEntry(const AAttrs: LIBSSH2_SFTP_ATTRIBUTES;
  var AEntry: TScpEntry);
begin
  AEntry.Size := -1;
  AEntry.Mode := 0;
  AEntry.MTimeUtc := 0;
  AEntry.AttrsUnknown := AAttrs.flags = 0;
  if (AAttrs.flags and LIBSSH2_SFTP_ATTR_SIZE) <> 0 then
    AEntry.Size := Int64(AAttrs.filesize);
  if (AAttrs.flags and LIBSSH2_SFTP_ATTR_PERMISSIONS) <> 0 then
    AEntry.Mode := LongWord(AAttrs.permissions);
  if (AAttrs.flags and LIBSSH2_SFTP_ATTR_ACMODTIME) <> 0 then
    AEntry.MTimeUtc := Int64(AAttrs.mtime);
  AEntry.IsDir := ModeIsDir(AEntry.Mode);
  AEntry.IsLink := ModeIsLink(AEntry.Mode);
  AEntry.IsSpecial := ModeIsSpecial(AEntry.Mode);
  if AEntry.IsDir then AEntry.Size := -1;
  AEntry.ReadOnly := (AEntry.Mode <> 0) and ((AEntry.Mode and &0200) = 0);
end;

// « longentry » est un `ls -l` fabrique par le SERVEUR: on n'en tire que
// proprietaire et groupe, jamais une taille ou un mode.
procedure ParseLongEntryOwner(const ALong: string;
  var AEntry: TScpEntry);
var
  i, field, start: Integer;
  parts: array[0..3] of string;
  n: Integer;
begin
  n := 0;
  i := 1;
  field := 0;
  while (i <= Length(ALong)) and (n < 4) do
  begin
    while (i <= Length(ALong)) and (ALong[i] = ' ') do Inc(i);
    start := i;
    while (i <= Length(ALong)) and (ALong[i] <> ' ') do Inc(i);
    if i > start then
    begin
      parts[n] := Copy(ALong, start, i - start);
      Inc(n);
    end;
    Inc(field);
    if field > 8 then Break;
  end;
  if n >= 3 then AEntry.Owner := DisplaySafeName(parts[2]);
  if n >= 4 then AEntry.Group := DisplaySafeName(parts[3]);
end;

function TSftpFileSystem.List(const APath: string;
  out AEntries: TScpEntryArray; out AErr: TScpError): Boolean;
var
  h: PLIBSSH2_SFTP_HANDLE;
  nameBuf: array[0..SFTP_NAME_MAX - 1] of AnsiChar;
  longBuf: array[0..SFTP_LONGENTRY_MAX - 1] of AnsiChar;
  attrs: LIBSSH2_SFTP_ATTRIBUTES;
  rc: cint;
  deadline: QWord;
  n: Integer;
  name: string;
  p: AnsiString;
  closeRc: cint;
begin
  SetLength(AEntries, 0);
  AErr := NoScpError;
  n := 0;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    h := libssh2_sftp_open_ex(FOwner.FSftp, PAnsiChar(p), Length(p), 0, 0,
      LIBSSH2_SFTP_OPENDIR);
    if h <> nil then Break;
    rc := libssh2_session_last_errno(FOwner.FSession);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if h = nil then
  begin
    AErr := LastError('Listing', APath,
      libssh2_session_last_errno(FOwner.FSession), True);
    Exit(False);
  end;
  try
    while True do
    begin
      if FOwner.Terminated then
      begin
        AErr := MakeScpError(sekCanceled, 'Listing', DisplaySafeName(APath),
          '');
        Exit(False);
      end;
      deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
      FillChar(attrs, SizeOf(attrs), 0);
      repeat
        rc := libssh2_sftp_readdir_ex(h, @nameBuf[0], SFTP_NAME_MAX,
          @longBuf[0], SFTP_LONGENTRY_MAX, @attrs);
        if rc <> LIBSSH2_ERROR_EAGAIN then Break;
      until not WaitAgain(deadline);
      if rc = 0 then Break;          // fin du repertoire
      if rc < 0 then
      begin
        AErr := LastError('Listing', APath, rc, True);
        Exit(False);
      end;
      if rc > SFTP_NAME_MAX then rc := SFTP_NAME_MAX;
      SetString(name, PAnsiChar(@nameBuf[0]), rc);
      // '.' et '..' ne doivent jamais devenir transferables ni supprimables.
      if (name = '.') or (name = '..') or (name = '') then Continue;
      if n >= SCP_MAX_DIR_ENTRIES then
      begin
        // Un serveur qui envoie sans fin: on s'arrete et on le dit.
        AErr := MakeScpError(sekOther, 'Listing', DisplaySafeName(APath),
          Format('the server returned more than %d entries',
            [SCP_MAX_DIR_ENTRIES]));
        Exit(False);
      end;
      SetLength(AEntries, n + 1);
      AEntries[n] := Default(TScpEntry);
      AEntries[n].Name := name;
      AEntries[n].Hidden := name[1] = '.';
      AttrsToEntry(attrs, AEntries[n]);
      ParseLongEntryOwner(string(AnsiString(PAnsiChar(@longBuf[0]))),
        AEntries[n]);
      if AEntries[n].IsLink then
      begin
        // La cible s'affiche, elle n'est JAMAIS suivie pendant une recursion.
        AEntries[n].LinkTarget := '';
        AEntries[n].BrokenLink := True;
        AEntries[n].TargetIsDir := False;
      end;
      Inc(n);
    end;
  finally
    deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
    repeat
      closeRc := libssh2_sftp_close_handle(h);
      if closeRc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not WaitAgain(deadline);
  end;
  Result := True;
end;

function TSftpFileSystem.Stat(const APath: string; AFollowLink: Boolean;
  out AEntry: TScpEntry; out AErr: TScpError): Boolean;
var
  attrs: LIBSSH2_SFTP_ATTRIBUTES;
  rc, statType: cint;
  deadline: QWord;
  p: AnsiString;
  target: array[0..SFTP_NAME_MAX - 1] of AnsiChar;
  linkRc: cint;
  s: string;
begin
  AEntry := Default(TScpEntry);
  AErr := NoScpError;
  AEntry.Name := RemoteBaseName(APath);
  p := AnsiString(RemoteNormalize(APath));
  if AFollowLink then
    statType := LIBSSH2_SFTP_STAT
  else
    statType := LIBSSH2_SFTP_LSTAT;
  FillChar(attrs, SizeOf(attrs), 0);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_stat_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      statType, @attrs);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if rc < 0 then
  begin
    AErr := LastError('Reading attributes of', APath, rc, False);
    Exit(False);
  end;
  AttrsToEntry(attrs, AEntry);
  if AEntry.IsLink then
  begin
    deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
    repeat
      linkRc := libssh2_sftp_symlink_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
        @target[0], SFTP_NAME_MAX, LIBSSH2_SFTP_READLINK);
      if linkRc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not WaitAgain(deadline);
    if linkRc > 0 then
    begin
      if linkRc > SFTP_NAME_MAX then linkRc := SFTP_NAME_MAX;
      SetString(s, PAnsiChar(@target[0]), linkRc);
      AEntry.LinkTarget := DisplaySafeName(s);
    end;
  end;
  Result := True;
end;

function TSftpFileSystem.Exists(const APath: string; out AFound: Boolean;
  out AErr: TScpError): Boolean;
var
  e: TScpEntry;
  err: TScpError;
begin
  AErr := NoScpError;
  AFound := False;
  if Stat(APath, False, e, err) then
  begin
    AFound := True;
    Exit(True);
  end;
  // « Absent » est une reponse, le reste est une panne: les confondre ferait
  // ecraser une cible qu'on n'a pas su lire.
  if err.Kind in [sekNotFound, sekNotADirectory] then Exit(True);
  AErr := err;
  Result := False;
end;

function TSftpFileSystem.MakeDir(const APath: string;
  out AErr: TScpError): Boolean;
var
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_mkdir_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      SCP_DEFAULT_DIR_MODE);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
    AErr := LastError('Creating folder', APath, rc, True);
end;

function TSftpFileSystem.Rename(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
var
  rc: cint;
  deadline: QWord;
  a, b: AnsiString;
begin
  AErr := NoScpError;
  a := AnsiString(RemoteNormalize(AFrom));
  b := AnsiString(RemoteNormalize(ATo));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    // Drapeaux a zero: en SFTP v3 ils ne partent pas sur le cable, et promettre
    // un ecrasement qui n'aura pas lieu serait mentir.
    rc := libssh2_sftp_rename_ex(FOwner.FSftp, PAnsiChar(a), Length(a),
      PAnsiChar(b), Length(b), 0);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
    AErr := LastError('Renaming to', ATo, rc, False);
end;

function TSftpFileSystem.ReplaceAtomic(const AFrom, ATo: string;
  out AErr: TScpError): Boolean;
var
  rc: cint;
  deadline: QWord;
  a, b: AnsiString;
begin
  AErr := NoScpError;
  // posix-rename@openssh.com est le SEUL remplacement atomique en SFTP v3.
  if not Libssh2HasPosixRename then
  begin
    AErr := MakeScpError(sekUnsupported, 'Replacing', DisplaySafeName(ATo),
      'this libssh2 build has no posix-rename support');
    Exit(False);
  end;
  a := AnsiString(RemoteNormalize(AFrom));
  b := AnsiString(RemoteNormalize(ATo));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_posix_rename_ex(FOwner.FSftp, PAnsiChar(a), Length(a),
      PAnsiChar(b), Length(b));
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if rc = 0 then Exit(True);
  AErr := LastError('Replacing', ATo, rc, False);
  // Un serveur qui n'annonce pas l'extension repond « operation non
  // supportee ». C'est le seul cas ou un repli a du sens: un refus de DROIT
  // se reproduirait a l'identique et detruirait la cible pour rien.
  if AErr.Kind in [sekUnsupported, sekOther] then
    AErr.Kind := sekUnsupported;
  Result := False;
end;

function TSftpFileSystem.DeleteFile(const APath: string;
  out AErr: TScpError): Boolean;
var
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_unlink_ex(FOwner.FSftp, PAnsiChar(p), Length(p));
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
    AErr := LastError('Deleting', APath, rc, False);
end;

function TSftpFileSystem.DeleteDir(const APath: string;
  out AErr: TScpError): Boolean;
var
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_rmdir_ex(FOwner.FSftp, PAnsiChar(p), Length(p));
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
    AErr := LastError('Deleting folder', APath, rc, True);
end;

function TSftpFileSystem.OpenRead(const APath: string;
  out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  hnd: PLIBSSH2_SFTP_HANDLE;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AHandle := nil;
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    hnd := libssh2_sftp_open_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      LIBSSH2_FXF_READ, 0, LIBSSH2_SFTP_OPENFILE);
    if hnd <> nil then Break;
    rc := libssh2_session_last_errno(FOwner.FSession);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if hnd = nil then
  begin
    AErr := LastError('Opening', APath,
      libssh2_session_last_errno(FOwner.FSession), False);
    Exit(False);
  end;
  h := TSftpHandle.Create;
  h.H := hnd;
  h.Path := RemoteNormalize(APath);
  AHandle := h;
  Result := True;
end;

function TSftpFileSystem.CreateTemp(const ADir: string; AMode: LongWord;
  out APath: string; out AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  hnd: PLIBSSH2_SFTP_HANDLE;
  rc, attempt: cint;
  deadline: QWord;
  candidate: string;
  p: AnsiString;
begin
  AHandle := nil;
  APath := '';
  AErr := NoScpError;
  for attempt := 1 to 8 do
  begin
    candidate := RemoteJoin(RemoteNormalize(ADir),
      TEMP_PREFIX + RandomSuffix + TEMP_SUFFIX);
    p := AnsiString(candidate);
    deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
    repeat
      // EXCL: la creation echoue si le nom existe, lien compris -- c'est ce qui
      // interdit d'ecrire a travers un lien pose d'avance, le nom imprevisible
      // interdisant de le poser a temps. Le mode part dans OPEN, ou le serveur
      // applique son umask; un SETSTAT apres coup ne le ferait pas.
      hnd := libssh2_sftp_open_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
        LIBSSH2_FXF_WRITE or LIBSSH2_FXF_CREAT or LIBSSH2_FXF_EXCL,
        clong(AMode and LongWord(&0777)), LIBSSH2_SFTP_OPENFILE);
      if hnd <> nil then Break;
      rc := libssh2_session_last_errno(FOwner.FSession);
      if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not WaitAgain(deadline);
    if hnd <> nil then
    begin
      h := TSftpHandle.Create;
      h.H := hnd;
      h.Path := candidate;
      APath := candidate;
      AHandle := h;
      Exit(True);
    end;
    AErr := LastError('Creating a temporary file in', ADir,
      libssh2_session_last_errno(FOwner.FSession), True);
    if AErr.Kind <> sekAlreadyExists then
    begin
      if AErr.Kind = sekAccessDeniedDir then
        AErr.Kind := sekAccessDeniedWrite;
      Exit(False);
    end;
  end;
  AErr := MakeScpError(sekOther, 'Creating a temporary file in',
    DisplaySafeName(ADir), 'eight unpredictable names all collided');
  Result := False;
end;

function TSftpFileSystem.OpenAppend(const APath: string; AOffset: Int64;
  out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  hnd: PLIBSSH2_SFTP_HANDLE;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AHandle := nil;
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    hnd := libssh2_sftp_open_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      LIBSSH2_FXF_WRITE, &0600, LIBSSH2_SFTP_OPENFILE);
    if hnd <> nil then Break;
    rc := libssh2_session_last_errno(FOwner.FSession);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if hnd = nil then
  begin
    AErr := LastError('Reopening', APath,
      libssh2_session_last_errno(FOwner.FSession), False);
    Exit(False);
  end;
  h := TSftpHandle.Create;
  h.H := hnd;
  h.Path := RemoteNormalize(APath);
  // SFTP v3 n'a pas de troncature: on se place a l'offset CONFIRME et on ecrit
  // par-dessus. Les octets au-dela seront recouverts, jamais comptes acquis.
  libssh2_sftp_seek64(hnd, libssh2_uint64_t(AOffset));
  AHandle := h;
  Result := True;
end;

function TSftpFileSystem.Read(AHandle: TScpFileHandle; ABuf: PByte;
  ACount: Integer; out AGot: Integer; out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  n: cssize_t;
  deadline: QWord;
begin
  AGot := 0;
  AErr := NoScpError;
  h := TSftpHandle(AHandle);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    n := libssh2_sftp_read(h.H, PAnsiChar(ABuf), ACount);
    if n <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if n < 0 then
  begin
    AErr := LastError('Reading', h.Path, cint(n), False);
    Exit(False);
  end;
  // n < ACount est normal en SFTP: une lecture courte, pas une fin. Seul 0 l'est.
  AGot := Integer(n);
  Result := True;
end;

function TSftpFileSystem.Write(AHandle: TScpFileHandle; ABuf: PByte;
  ACount: Integer; out APut: Integer; out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  n: cssize_t;
  deadline: QWord;
begin
  APut := 0;
  AErr := NoScpError;
  h := TSftpHandle(AHandle);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    n := libssh2_sftp_write(h.H, PAnsiChar(ABuf), ACount);
    if n <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if n < 0 then
  begin
    AErr := LastError('Writing', h.Path, cint(n), False);
    Exit(False);
  end;
  APut := Integer(n);
  Result := True;
end;

function TSftpFileSystem.Seek(AHandle: TScpFileHandle; AOffset: Int64;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  libssh2_sftp_seek64(TSftpHandle(AHandle).H, libssh2_uint64_t(AOffset));
  Result := True;
end;

function TSftpFileSystem.Flush(AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  rc: cint;
  deadline: QWord;
begin
  AErr := NoScpError;
  h := TSftpHandle(AHandle);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_fsync(h.H);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  if rc = 0 then Exit(True);
  AErr := LastError('Flushing', h.Path, rc, False);
  // fsync@openssh.com est une extension: beaucoup de serveurs ne l'ont pas.
  // Son absence n'est pas un echec du transfert -- la fermeture du fichier
  // reste le point de verite.
  if AErr.Kind = sekUnsupported then
  begin
    AErr := NoScpError;
    Exit(True);
  end;
  Result := False;
end;

function TSftpFileSystem.Close(AHandle: TScpFileHandle;
  out AErr: TScpError): Boolean;
var
  h: TSftpHandle;
  rc: cint;
  deadline: QWord;
begin
  AErr := NoScpError;
  Result := True;
  if AHandle = nil then Exit;
  h := TSftpHandle(AHandle);
  if h.H <> nil then
  begin
    deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
    repeat
      rc := libssh2_sftp_close_handle(h.H);
      if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    until not WaitAgain(deadline);
    // La fermeture est ou un serveur avoue un quota depasse: la traiter comme une
    // formalite ferait passer un fichier tronque pour un succes.
    if rc <> 0 then
    begin
      AErr := LastError('Closing', h.Path, rc, False);
      Result := False;
    end;
    h.H := nil;
  end;
  h.Free;
end;

function TSftpFileSystem.SetMTime(const APath: string; AMTimeUtc: Int64;
  out AErr: TScpError): Boolean;
var
  attrs: LIBSSH2_SFTP_ATTRIBUTES;
  cur: LIBSSH2_SFTP_ATTRIBUTES;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  // SETSTAT ecrit TOUS les champs annonces: relire d'abord, sinon la date
  // d'acces part avec une valeur inventee.
  FillChar(cur, SizeOf(cur), 0);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_stat_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      LIBSSH2_SFTP_STAT, @cur);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);

  FillChar(attrs, SizeOf(attrs), 0);
  attrs.flags := LIBSSH2_SFTP_ATTR_ACMODTIME;
  if (rc = 0) and ((cur.flags and LIBSSH2_SFTP_ATTR_ACMODTIME) <> 0) then
    attrs.atime := cur.atime
  else
    attrs.atime := culong(AMTimeUtc);
  attrs.mtime := culong(AMTimeUtc);

  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_stat_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      LIBSSH2_SFTP_SETSTAT, @attrs);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
  begin
    AErr := LastError('Setting the timestamp of', APath, rc, False);
    // Le contenu est arrive: ce refus est un avertissement, pas une perte.
    AErr.Kind := sekAttrRefused;
  end;
end;

function TSftpFileSystem.SetMode(const APath: string; AMode: LongWord;
  out AErr: TScpError): Boolean;
var
  attrs: LIBSSH2_SFTP_ATTRIBUTES;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  AErr := NoScpError;
  p := AnsiString(RemoteNormalize(APath));
  FillChar(attrs, SizeOf(attrs), 0);
  attrs.flags := LIBSSH2_SFTP_ATTR_PERMISSIONS;
  // Jamais de droit monde en ecriture, quel que soit le mode demande.
  attrs.permissions := culong(AMode and LongWord(&0775));
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_stat_ex(FOwner.FSftp, PAnsiChar(p), Length(p),
      LIBSSH2_SFTP_SETSTAT, @attrs);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
  until not WaitAgain(deadline);
  Result := rc = 0;
  if not Result then
  begin
    AErr := LastError('Setting the mode of', APath, rc, False);
    AErr.Kind := sekAttrRefused;
  end;
end;

function TSftpFileSystem.Join(const ABase, AName: string): string;
begin
  Result := RemoteJoin(ABase, AName);
end;

function TSftpFileSystem.Parent(const APath: string): string;
begin
  Result := RemoteParent(APath);
end;

function TSftpFileSystem.BaseName(const APath: string): string;
begin
  Result := RemoteBaseName(APath);
end;

function TSftpFileSystem.Normalize(const APath: string): string;
begin
  Result := RemoteNormalize(APath);
end;

function TSftpFileSystem.IsUnder(const ARoot, APath: string): Boolean;
begin
  Result := RemoteIsUnder(ARoot, APath);
end;

function TSftpFileSystem.CheckName(const AName: string): TNameVerdict;
begin
  Result := CheckRemoteChildName(AName);
end;

function TSftpFileSystem.CollisionKey(const AName: string): string;
begin
  Result := AName;
end;

{ TSftpTransport }

constructor TSftpTransport.Create(AParams: TSshConnectParams;
  ALocal: TScpFileSystem; AQueue: TTransferQueue;
  AEngine: TScpTransferEngine);
begin
  inherited Create(True);
  FParams := AParams;
  FLocal := ALocal;
  FQueue := AQueue;
  FStates := TSessionStateMachine.Create;
  FCmdLock := TCriticalSection.Create;
  FPubLock := TCriticalSection.Create;
  FErrLock := TCriticalSection.Create;
  FCmds := TFPList.Create;
  FPub := TFPList.Create;
  FCmdEvent := TEvent.Create(nil, True, False, '');
  FConflictEvent := TEvent.Create(nil, True, False, '');
  FNonAtomicEvent := TEvent.Create(nil, True, False, '');
  FConnIdentity := Format('%s@%s:%d',
    [AParams.Username, AParams.Host, AParams.Port]);
  FRemote := TSftpFileSystem.Create(Self, FConnIdentity);
  FEngine := AEngine;
  FOwnsEngine := FEngine = nil;
  if FOwnsEngine then
    FEngine := TScpTransferEngine.Create(AQueue);
  FEngine.OnConflict := @EngineConflict;
  FEngine.OnNonAtomic := @EngineNonAtomic;
  FEngine.OnProgress := @EngineProgress;
  FEngine.OnNote := @EngineNote;
end;

destructor TSftpTransport.Destroy;
var
  i: Integer;
begin
  inherited Destroy;      // TThread joint le thread AVANT qu'on libere tout
  ClearCommands;
  FCmds.Free;
  for i := 0 to FPub.Count - 1 do
    TObject(FPub[i]).Free;
  FPub.Free;
  FCmdEvent.Free;
  FConflictEvent.Free;
  FNonAtomicEvent.Free;
  if FOwnsEngine then
    FEngine.Free
  else
  begin
    FEngine.OnConflict := nil;
    FEngine.OnNonAtomic := nil;
    FEngine.OnProgress := nil;
    FEngine.OnNote := nil;
  end;
  FRemote.Free;
  FErrLock.Free;
  FPubLock.Free;
  FCmdLock.Free;
  FStates.Free;
end;

function TSftpTransport.Identity: string;
begin
  Result := FConnIdentity;
end;

function TSftpTransport.State: TRemoteSessionState;
begin
  Result := FStates.State;
end;

function TSftpTransport.LastErrorText: string;
begin
  FErrLock.Acquire;
  try
    Result := FErrorMsg;
  finally
    FErrLock.Release;
  end;
end;

function TSftpTransport.RemoteFreeBytes(const APath: string): Int64;
var
  st: TLibssh2SftpStatVfs;
  rc: cint;
  deadline: QWord;
  p: AnsiString;
begin
  Result := -1;
  if (FSftp = nil) or (not Assigned(libssh2_sftp_statvfs)) then Exit;
  p := AnsiString(RemoteNormalize(APath));
  FillChar(st, SizeOf(st), 0);
  deadline := GetTickCount64 + SFTP_OP_TIMEOUT_MS;
  repeat
    rc := libssh2_sftp_statvfs(FSftp, PAnsiChar(p), Length(p), @st);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    if Terminated or (GetTickCount64 >= deadline) then Exit;
    WaitIo(SFTP_POLL_MS);
  until Terminated;
  // Le serveur n'annonce pas l'extension: -1, et l'appelant s'abstient
  // plutot que de supposer de la place.
  if rc <> 0 then Exit;
  if st.f_frsize = 0 then Exit;
  Result := Int64(st.f_bavail) * Int64(st.f_frsize);
end;

function TSftpTransport.ActivePartialCount: Integer;
begin
  Result := FEngine.Partials.ActiveCount;
end;

procedure TSftpTransport.SetState(ANext: TRemoteSessionState);
begin
  FStates.TryTransitionTo(ANext);
end;

procedure TSftpTransport.Fail(const AMessage: string);
var
  r: TSftpResult;
begin
  FErrLock.Acquire;
  try
    FErrorMsg := AMessage;
  finally
    FErrLock.Release;
  end;
  SetState(rssFailed);
  r := TSftpResult.Create;
  r.Kind := srFailed;
  r.Error := MakeScpError(sekConnectionLost, 'Connection', '', AMessage);
  PostResult(r);
end;

procedure TSftpTransport.ReportError(const AMessage: string);
begin
  Fail(AMessage);
end;

function TSftpTransport.ErrHandshakeRefused: string;
begin
  Result := 'SFTP: SSH handshake refused';
end;

function TSftpTransport.WaitIo(AMs: Integer): Boolean;
var
  rfds, wfds: TSockSet;
  dir, rc: cint;
  fd: cint;
begin
  Result := False;
  fd := FSock;
  if fd < 0 then Exit;
  SockSetZero(rfds);
  SockSetZero(wfds);
  dir := libssh2_session_block_directions(FSession);
  if (dir = 0) or ((dir and LIBSSH2_SESSION_BLOCK_INBOUND) <> 0) then
    SockSetAdd(fd, rfds);
  if (dir and LIBSSH2_SESSION_BLOCK_OUTBOUND) <> 0 then
    SockSetAdd(fd, wfds);
  rc := SockSelect(fd + 1, @rfds, @wfds, nil, AMs);
  Result := rc > 0;
end;

// --- File de commandes ----------------------------------------------------

procedure TSftpTransport.PostCommand(ACmd: TSftpCommand);
begin
  FCmdLock.Acquire;
  try
    Inc(FSerial);
    ACmd.Serial := FSerial;
    FCmds.Add(ACmd);
  finally
    FCmdLock.Release;
  end;
  FCmdEvent.SetEvent;
end;

function TSftpTransport.TakeCommand: TSftpCommand;
begin
  Result := nil;
  FCmdLock.Acquire;
  try
    if FCmds.Count > 0 then
    begin
      Result := TSftpCommand(FCmds[0]);
      FCmds.Delete(0);
    end;
    if FCmds.Count = 0 then
      FCmdEvent.ResetEvent;
  finally
    FCmdLock.Release;
  end;
end;

function TSftpTransport.HasPendingCommand: Boolean;
begin
  FCmdLock.Acquire;
  try
    Result := FCmds.Count > 0;
  finally
    FCmdLock.Release;
  end;
end;

procedure TSftpTransport.ClearCommands;
var
  i: Integer;
begin
  FCmdLock.Acquire;
  try
    for i := 0 to FCmds.Count - 1 do
      TSftpCommand(FCmds[i]).Free;
    FCmds.Clear;
  finally
    FCmdLock.Release;
  end;
end;

// --- Publication vers l'interface -----------------------------------------

procedure TSftpTransport.PostResult(AResult: TObject);
begin
  FPubLock.Acquire;
  try
    FPub.Add(AResult);
  finally
    FPubLock.Release;
  end;
  Queue(@PublishNext);
end;

procedure TSftpTransport.PublishNext;
var
  r: TSftpResult;
begin
  r := nil;
  FPubLock.Acquire;
  try
    if FPub.Count > 0 then
    begin
      r := TSftpResult(FPub[0]);
      FPub.Delete(0);
    end;
  finally
    FPubLock.Release;
  end;
  if r = nil then Exit;
  try
    case r.Kind of
      srListed:
        if Assigned(FOnListed) then FOnListed(r.Path, r.Entries, r.Error);
      srHome:
        if Assigned(FOnHome) then FOnHome(r.Path, r.Error);
      srOpDone:
        if Assigned(FOnOpDone) then FOnOpDone(r.Error);
      srFreeSpace:
        if Assigned(FOnFreeSpace) then FOnFreeSpace(r.Path, r.FreeBytes);
      srNote:
        if Assigned(FOnNote) and (r.Text <> '') then FOnNote(r.Text);
      srFailed:
        if Assigned(FOnFailed) then FOnFailed(r.Error);
    end;
  finally
    r.Free;
  end;
end;

procedure TSftpTransport.PublishQueueChanged;
begin
  if Assigned(FOnQueueChanged) then
    FOnQueueChanged();
end;

procedure TSftpTransport.PublishConnected;
begin
  if Assigned(FOnConnected) then
    FOnConnected(Self);
end;

// --- Relais du moteur (thread de transport) -------------------------------

// Thread UI. La modale vide QueueAsyncCall et peut liberer d'AUTRES onglets,
// jamais celui-ci: le SetEvent ne frappe pas un mort.
procedure TSftpTransport.AskConflictOnUi;
begin
  try
    if Assigned(FOnConflict) then
      FOnConflict(FConflictInfo, FConflictDecision)
    else
      FConflictDecision.Action := cnAsk;
  finally
    FConflictEvent.SetEvent;
  end;
end;

procedure TSftpTransport.AskNonAtomicOnUi;
begin
  try
    FNonAtomicAllow := False;
    if Assigned(FOnNonAtomic) then
      FOnNonAtomic(FNonAtomicPath, FNonAtomicAllow);
  finally
    FNonAtomicEvent.SetEvent;
  end;
end;

procedure TSftpTransport.EngineConflict(const AInfo: TConflictInfo;
  var ADecision: TConflictDecision);
var
  waited: Integer;
begin
  // Sans interlocuteur on ne decide pas: cnAsk saute l'element, cible intacte.
  ADecision.Action := cnAsk;
  ADecision.ApplyToAll := False;
  if not Assigned(FOnConflict) then Exit;
  FConflictInfo := AInfo;
  FConflictDecision.Action := cnAsk;
  FConflictDecision.ApplyToAll := False;
  FConflictEvent.ResetEvent;
  Queue(@AskConflictOnUi);
  waited := 0;
  while (FConflictEvent.WaitFor(200) = wrTimeout) and (not Terminated) do
  begin
    Inc(waited, 200);
    if waited >= CONFLICT_ANSWER_TIMEOUT_MS then Break;
  end;
  if Terminated then
  begin
    ADecision.Action := cnCancelQueue;
    Exit;
  end;
  ADecision := FConflictDecision;
end;

procedure TSftpTransport.EngineNonAtomic(const ATargetPath: string;
  var AAllow: Boolean);
var
  waited: Integer;
begin
  AAllow := False;
  if not Assigned(FOnNonAtomic) then Exit;
  FNonAtomicPath := ATargetPath;
  FNonAtomicAllow := False;
  FNonAtomicEvent.ResetEvent;
  Queue(@AskNonAtomicOnUi);
  waited := 0;
  while (FNonAtomicEvent.WaitFor(200) = wrTimeout) and (not Terminated) do
  begin
    Inc(waited, 200);
    if waited >= CONFLICT_ANSWER_TIMEOUT_MS then Break;
  end;
  if Terminated then Exit;
  AAllow := FNonAtomicAllow;
end;

procedure TSftpTransport.EngineProgress(AItem: TTransferItem);
begin
  if Assigned(FOnQueueChanged) then
    Queue(@PublishQueueChanged);
end;

procedure TSftpTransport.EngineNote(const AText: string);
var
  r: TSftpResult;
begin
  if not Assigned(FOnNote) then Exit;
  r := TSftpResult.Create;
  r.Kind := srNote;
  r.Text := AText;
  PostResult(r);
end;

// --- Commandes ------------------------------------------------------------

procedure TSftpTransport.RequestList(const APath: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckListRemote;
  c.PathA := APath;
  PostCommand(c);
end;

procedure TSftpTransport.RequestHome;
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRemoteHome;
  PostCommand(c);
end;

procedure TSftpTransport.RequestMkdir(const APath: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRemoteMkdir;
  c.PathA := APath;
  PostCommand(c);
end;

procedure TSftpTransport.RequestRename(const AFrom, ATo: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRemoteRename;
  c.PathA := AFrom;
  c.PathB := ATo;
  PostCommand(c);
end;

procedure TSftpTransport.RequestDelete(const APath: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRemoteDelete;
  c.PathA := APath;
  PostCommand(c);
end;

procedure TSftpTransport.RequestUpload(const ASources: TStringArray;
  const ARemoteDir, ARemoteRoot: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckEnqueueUpload;
  c.Sources := Copy(ASources, 0, Length(ASources));
  c.TargetDir := ARemoteDir;
  c.TargetRoot := ARemoteRoot;
  PostCommand(c);
end;

procedure TSftpTransport.RequestDownload(const ASources: TStringArray;
  const ALocalDir, ALocalRoot: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckEnqueueDownload;
  c.Sources := Copy(ASources, 0, Length(ASources));
  c.TargetDir := ALocalDir;
  c.TargetRoot := ALocalRoot;
  PostCommand(c);
end;

procedure TSftpTransport.RequestDuplicate(const ASources: TStringArray;
  const ADir: string; AOnRemote: Boolean);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckEnqueueDuplicate;
  c.Sources := Copy(ASources, 0, Length(ASources));
  c.TargetDir := ADir;
  c.TargetRoot := ADir;
  c.OnRemote := AOnRemote;
  PostCommand(c);
end;

procedure TSftpTransport.RequestRunQueue;
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRunQueue;
  PostCommand(c);
end;

procedure TSftpTransport.RequestRetryFailed;
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckRetryFailed;
  PostCommand(c);
end;

procedure TSftpTransport.RequestCleanupPartials;
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckCleanupPartials;
  PostCommand(c);
end;

procedure TSftpTransport.RequestFreeSpace(const APath: string);
var
  c: TSftpCommand;
begin
  c := TSftpCommand.Create;
  c.Kind := sckFreeSpace;
  c.PathA := APath;
  PostCommand(c);
end;

procedure TSftpTransport.PauseTransfers;
begin
  // Lu entre deux elements: celui en cours finit ou est annule, jamais suspendu.
  FPaused := True;
  FQueue.PauseQueue;
end;

procedure TSftpTransport.ResumeTransfers;
begin
  FPaused := False;
  FQueue.ResumeQueue;
  RequestRunQueue;
end;

procedure TSftpTransport.Shutdown;
begin
  Terminate;
  FHostKeyDecision := hkdReject;
  FHostKeyEvent.SetEvent;
  SkCancel;
  // Reveiller le thread s'il attend une reponse: sans cela, fermer pendant un
  // dialogue de conflit ferait attendre le joint jusqu'au bout du delai.
  FConflictEvent.SetEvent;
  FNonAtomicEvent.SetEvent;
  FCmdEvent.SetEvent;
  ShutdownSock;
end;

// --- Execution ------------------------------------------------------------

function TSftpTransport.OpenSftp: Boolean;
var
  deadline: QWord;
  rc: cint;
begin
  Result := False;
  deadline := GetTickCount64 + QWord(FParams.ConnectTimeoutS) * 1000;
  repeat
    FSftp := libssh2_sftp_init(FSession);
    if FSftp <> nil then Break;
    rc := libssh2_session_last_errno(FSession);
    if rc <> LIBSSH2_ERROR_EAGAIN then Break;
    if Terminated or (GetTickCount64 >= deadline) then Break;
    WaitIo(CONNECT_POLL_MS);
  until Terminated;
  if FSftp = nil then
  begin
    if not Terminated then
      // Accepter SSH et refuser le sous-systeme SFTP est une cause distincte.
      Fail('The server accepted the SSH connection but refused the SFTP ' +
        'subsystem. Check that the SFTP server is enabled for this account.');
    Exit;
  end;
  Result := True;
end;

function TSftpTransport.RemoveTree(const APath: string; ADepth: Integer;
  out AErr: TScpError): Boolean;
var
  entries: TScpEntryArray;
  i: Integer;
  child: string;
  e: TScpEntry;
  statErr: TScpError;
begin
  AErr := NoScpError;
  if Terminated then
  begin
    AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath), '');
    Exit(False);
  end;
  if ADepth > SFTP_MAX_RM_DEPTH then
  begin
    AErr := MakeScpError(sekOther, 'Deleting', DisplaySafeName(APath),
      Format('maximum depth of %d reached', [SFTP_MAX_RM_DEPTH]));
    Exit(False);
  end;
  if not FRemote.Stat(APath, False, e, statErr) then
  begin
    AErr := statErr;
    Exit(False);
  end;
  // Un lien vers un dossier se supprime LUI: y descendre effacerait sa cible.
  if e.IsLink or (not e.IsDir) then
    Exit(FRemote.DeleteFile(APath, AErr));

  if not FRemote.List(APath, entries, AErr) then Exit(False);
  for i := 0 to High(entries) do
  begin
    if Terminated then
    begin
      AErr := MakeScpError(sekCanceled, 'Deleting', DisplaySafeName(APath),
        '');
      Exit(False);
    end;
    if CheckRemoteChildName(entries[i].Name) <> nvOk then
    begin
      AErr := MakeScpError(sekInvalidName, 'Deleting',
        DisplaySafeName(entries[i].Name), '');
      Exit(False);
    end;
    child := RemoteJoin(APath, entries[i].Name);
    if not RemoteIsUnder(APath, child) then
    begin
      AErr := MakeScpError(sekOutsideRoot, 'Deleting',
        DisplaySafeName(entries[i].Name), '');
      Exit(False);
    end;
    if not RemoveTree(child, ADepth + 1, AErr) then Exit(False);
  end;
  Result := FRemote.DeleteDir(APath, AErr);
end;

procedure TSftpTransport.DoRunQueue;
var
  item: TTransferItem;
  srcFs, dstFs: TScpFileSystem;
  root: string;
begin
  while not Terminated do
  begin
    if FPaused then Break;
    // TENU jusqu'a ReleaseCurrent: « Clear completed » ne peut pas le liberer
    // sous nos pieds.
    item := FQueue.NextRunnable;
    if item = nil then Break;
    // Le sens de l'element, pose a la mise en file, designe les deux systemes de
    // fichiers: les deduire du chemin laisserait un nom decider ou on ecrit.
    case item.Direction of
      tdUpload: begin srcFs := FLocal; dstFs := FRemote; end;
      tdDownload: begin srcFs := FRemote; dstFs := FLocal; end;
      tdDuplicateLocal: begin srcFs := FLocal; dstFs := FLocal; end;
    else
      begin srcFs := FRemote; dstFs := FRemote; end;
    end;
    // La racine de confinement est posee a la mise en file et ne bouge plus: la
    // rededuire ici donnerait une garantie differente selon la profondeur.
    root := item.TargetRoot;
    if root = '' then
      // Hors enumeration: le dossier de la cible est la borne la plus stricte.
      root := dstFs.Parent(item.TargetPath);
    try
      FEngine.RunItem(srcFs, dstFs, item, root);
      if item.IsRunnable then
      begin
        item.Error := MakeScpError(sekOther, 'Copying', item.DisplayName,
          'the transfer ended without a result');
        FQueue.SetState(item, tsFailed);
      end;
    finally
      FQueue.ReleaseCurrent;
    end;
    if Assigned(FOnQueueChanged) then
      Queue(@PublishQueueChanged);
    // Entre deux elements: une commande d'interface ne coupe pas un fichier, mais
    // n'attend pas la fin du lot. La boucle REVIENT ici des qu'elle est servie.
    if HasPendingCommand then Break;
  end;
  if Assigned(FOnQueueChanged) then
    Queue(@PublishQueueChanged);
end;

// Premier nom de copie libre dans ADir, '' si tous sont pris. La reponse
// vieillit aussitot: c'est la creation exclusive qui rattrape une collision.
function FreeCopyName(AFs: TScpFileSystem; const ADir, AName: string): string;
var
  i: Integer;
  candidate: string;
  found: Boolean;
  err: TScpError;
begin
  Result := '';
  for i := 1 to 99 do
  begin
    candidate := KeepBothCandidate(AName, i);
    if AFs.CheckName(candidate) <> nvOk then Continue;
    if not AFs.Exists(AFs.Join(ADir, candidate), found, err) then Exit;
    if not found then Exit(candidate);
  end;
end;

procedure TSftpTransport.RunCommand(ACmd: TSftpCommand);
var
  entries: TScpEntryArray;
  err: TScpError;
  path, copyName: string;
  i: Integer;
  srcFs, dstFs: TScpFileSystem;
  dir: TTransferDirection;
  leftover: TStringArray;
  r: TSftpResult;
begin
  err := NoScpError;
  case ACmd.Kind of
    sckListRemote:
      begin
        if not FRemote.List(ACmd.PathA, entries, err) then
          SetLength(entries, 0);
        r := TSftpResult.Create;
        r.Kind := srListed;
        r.Path := ACmd.PathA;
        r.Entries := entries;
        r.Error := err;
        PostResult(r);
      end;
    sckRemoteHome:
      begin
        if not FRemote.HomeDir(path, err) then
        begin
          // Home en echec. La racine n'est un repli que si elle est LISIBLE.
          if FRemote.List('/', entries, err) then
            path := '/'
          else
            path := '';
        end;
        r := TSftpResult.Create;
        r.Kind := srHome;
        r.Path := path;
        r.Error := err;
        PostResult(r);
      end;
    sckRemoteMkdir:
      begin
        FRemote.MakeDir(ACmd.PathA, err);
        r := TSftpResult.Create;
        r.Kind := srOpDone;
        r.Error := err;
        PostResult(r);
      end;
    sckRemoteRename:
      begin
        FRemote.Rename(ACmd.PathA, ACmd.PathB, err);
        r := TSftpResult.Create;
        r.Kind := srOpDone;
        r.Error := err;
        PostResult(r);
      end;
    sckRemoteDelete:
      begin
        RemoveTree(ACmd.PathA, 0, err);
        r := TSftpResult.Create;
        r.Kind := srOpDone;
        r.Error := err;
        PostResult(r);
      end;
    sckEnqueueUpload, sckEnqueueDownload:
      begin
        if ACmd.Kind = sckEnqueueUpload then
        begin
          srcFs := FLocal;
          dstFs := FRemote;
          dir := tdUpload;
        end
        else
        begin
          srcFs := FRemote;
          dstFs := FLocal;
          dir := tdDownload;
        end;
        for i := 0 to High(ACmd.Sources) do
        begin
          if Terminated then Break;
          if not FEngine.EnumerateInto(srcFs, dstFs, dir, ACmd.Sources[i],
             ACmd.TargetDir, ACmd.TargetRoot, SCP_MAX_DEPTH, err) then
            EngineNote(ScpErrorText(err));
        end;
        if Assigned(FOnQueueChanged) then
          Queue(@PublishQueueChanged);
        DoRunQueue;
      end;
    sckEnqueueDuplicate:
      begin
        if ACmd.OnRemote then
        begin
          srcFs := FRemote;
          dir := tdDuplicateRemote;
        end
        else
        begin
          srcFs := FLocal;
          dir := tdDuplicateLocal;
        end;
        for i := 0 to High(ACmd.Sources) do
        begin
          if Terminated then Break;
          copyName := FreeCopyName(srcFs, ACmd.TargetDir,
            srcFs.BaseName(ACmd.Sources[i]));
          if copyName = '' then
          begin
            EngineNote(Format('No free name left to duplicate %s.',
              [DisplaySafeName(srcFs.BaseName(ACmd.Sources[i]))]));
            Continue;
          end;
          // Meme systeme des deux cotes: la racine est le dossier de la source.
          if not FEngine.EnumerateInto(srcFs, srcFs, dir,
             ACmd.Sources[i], ACmd.TargetDir, ACmd.TargetRoot,
             SCP_MAX_DEPTH, err, copyName) then
            EngineNote(ScpErrorText(err));
        end;
        if Assigned(FOnQueueChanged) then
          Queue(@PublishQueueChanged);
        DoRunQueue;
      end;
    sckRunQueue:
      DoRunQueue;
    sckRetryFailed:
      begin
        FQueue.RetryAllFailed;
        if Assigned(FOnQueueChanged) then
          Queue(@PublishQueueChanged);
        DoRunQueue;
      end;
    sckFreeSpace:
      begin
        r := TSftpResult.Create;
        r.Kind := srFreeSpace;
        r.Path := ACmd.PathA;
        r.FreeBytes := RemoteFreeBytes(ACmd.PathA);
        PostResult(r);
      end;
    sckCleanupPartials:
      begin
        leftover := FEngine.CleanupPartials(FRemote);
        for i := 0 to High(leftover) do
          EngineNote(Format('A partial file could not be removed and is ' +
            'still on the server: %s', [DisplaySafeName(leftover[i])]));
        leftover := FEngine.CleanupPartials(FLocal);
        for i := 0 to High(leftover) do
          EngineNote(Format('A partial file could not be removed and is ' +
            'still on disk: %s', [DisplaySafeName(leftover[i])]));
      end;
  end;
end;

procedure TSftpTransport.CommandLoop;
var
  cmd: TSftpCommand;
begin
  while not Terminated do
  begin
    cmd := TakeCommand;
    if cmd = nil then
    begin
      // Rien a servir: si une commande a interrompu la file, c'est ici qu'elle
      // reprend. Sans ce retour, un listing pendant un lot laissait la suite a quai.
      if (not FPaused) and FQueue.HasRunnable then
      begin
        DoRunQueue;
        Continue;
      end;
      // Attente REVEILLABLE et bornee: le reveil periodique fait revoir Terminated
      // meme si l'evenement s'est perdu.
      FCmdEvent.WaitFor(200);
      Continue;
    end;
    try
      try
        RunCommand(cmd);
      except
        on E: Exception do
          EngineNote('SFTP: ' + E.Message);
      end;
    finally
      cmd.Free;
    end;
  end;
end;

procedure TSftpTransport.Cleanup;
var
  sockToClose: cint;
begin
  if FSftp <> nil then
  begin
    // Bloquant a la fermeture: mieux vaut un court delai que des poignees
    // laissees ouvertes cote serveur.
    libssh2_session_set_blocking(FSession, 1);
    libssh2_session_set_timeout(FSession, SHUTDOWN_GRACE_MS);
    libssh2_sftp_shutdown(FSftp);
    FSftp := nil;
  end;
  if FSession <> nil then
  begin
    libssh2_session_set_blocking(FSession, 1);
    libssh2_session_set_timeout(FSession, SHUTDOWN_GRACE_MS);
    libssh2_session_disconnect_ex(FSession, SSH_DISCONNECT_BY_APPLICATION,
      'bye', '');
    libssh2_session_free(FSession);
    FSession := nil;
  end;
  sockToClose := TakeSock;
  if sockToClose >= 0 then
    CloseSocket(sockToClose);
end;

procedure TSftpTransport.Execute;
var
  res, ai: Paddrinfo;
  fd, rc: cint;
  waited: Integer;
  connected: Boolean;
  portStr, hostStr, resErr: string;

  function ResolveAndConnect: Boolean;
  begin
    Result := False;
    res := nil;
    if FParams.ConnectHost <> '' then
    begin
      hostStr := FParams.ConnectHost;
      portStr := IntToStr(FParams.ConnectPort);
    end
    else
    begin
      hostStr := FParams.Host;
      portStr := IntToStr(FParams.Port);
    end;
    // getaddrinfo n'est pas interruptible et l'onglet JOINT ce thread: sans
    // resolution annulable, fermer gelerait l'interface le temps du timeout DNS.
    if not ResolveCancellable(AnsiString(hostStr), AnsiString(portStr),
         @IsAborted, res, resErr) then
    begin
      if resErr <> '' then Fail(resErr);
      Exit;
    end;
    try
      ai := res;
      while (ai <> nil) and (not Terminated) do
      begin
        fd := fpSocket(ai^.ai_family, ai^.ai_socktype, ai^.ai_protocol);
        if fd < 0 then
        begin
          ai := ai^.ai_next;
          Continue;
        end;
        SockSetNonBlocking(fd, True);
        connected := False;
        rc := fpConnect(fd, ai^.ai_addr, TSocklen(ai^.ai_addrlen));
        if rc = 0 then
          connected := True
        else if SockErrIsInProgress(SockLastError) then
        begin
          waited := 0;
          while waited < FParams.ConnectTimeoutS * 1000 do
          begin
            if Terminated then Break;
            rc := SockWaitConnect(fd, CONNECT_POLL_MS);
            if rc > 0 then
            begin
              connected := SockGetPendingError(fd) = 0;
              Break;
            end;
            if rc < 0 then
            begin
              if SockErrIsIntr(SockLastError) then Continue;
              Break;
            end;
            Inc(waited, CONNECT_POLL_MS);
          end;
        end;
        if connected then
        begin
          SockSetNonBlocking(fd, False);
          SockSetNoDelay(fd);
          PublishSock(fd);
          Exit(True);
        end;
        CloseSocket(fd);
        ai := ai^.ai_next;
      end;
    finally
      freeaddrinfo(res);
    end;
    if not Terminated then
      Fail(Format('Cannot connect to %s:%d (timeout %ds)',
        [FParams.Host, FParams.Port, FParams.ConnectTimeoutS]));
  end;

begin
  try
    try
      Libssh2EnsureLoaded;
      SetState(rssConnecting);
      if not ResolveAndConnect then Exit;
      if Terminated then Exit;
      if not Handshake then Exit;
      // La cle verifiee est celle de la CIBLE, meme derriere un bastion: c'est
      // FParams.Host qui la nomme.
      if not VerifyHostKey then Exit;

      SetState(rssAuthenticating);
      if not Authenticate then Exit;
      if Terminated then Exit;

      if not OpenSftp then Exit;
      if FParams.KeepaliveS > 0 then
        libssh2_keepalive_config(FSession, 1, FParams.KeepaliveS);

      SetState(rssConnected);
      if Assigned(FOnConnected) then
        Queue(@PublishConnected);

      CommandLoop;
      SetState(rssDisconnecting);
    except
      on E: Exception do
        Fail(E.Message);
    end;
  finally
    FParams.WipeSecrets;
    try
      Cleanup;
    except
      on E: Exception do
        ;   // deja en fermeture: rien de plus a tenter
    end;
    FStates.TryTransitionTo(rssDisconnecting);
    FStates.TryTransitionTo(rssDisconnected);
  end;
end;

end.
