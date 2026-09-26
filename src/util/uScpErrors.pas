{ Erreurs de l'onglet Scp. Un « Access denied » pour un disque plein envoie
  l'admin fouiller les permissions pendant une heure: chaque cause a son code.
  sekAttrRefused n'est PAS un echec: contenu intact, date ou mode perdus.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpErrors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils{$IFNDEF WINDOWS}, BaseUnix{$ENDIF};

type
  TScpErrorKind = (
    sekNone,
    sekAccessDeniedDir,     // non lisible ou non traversable
    sekAccessDeniedRead,    // listee, mais refusee a l'ouverture
    sekAccessDeniedWrite,
    sekReadOnlyTarget,
    sekRenameRefused,       // le temporaire passe, le rename non
    sekNoSpace,             // disque plein ou quota
    sekTooManyFiles,
    sekLocked,              // verrou d'un autre processus
    sekNotFound,            // absent des le depart
    sekPathGone,            // present au listing, disparu depuis
    sekAlreadyExists,       // conflit, PAS un refus de droit
    sekNotADirectory,
    sekDirNotEmpty,
    sekInvalidName,         // sur la plateforme de destination
    sekIsSpecialFile,       // socket, tube, peripherique
    sekSymlinkSkipped,      // une decision, pas une panne
    sekOutsideRoot,         // sortirait du dossier choisi
    sekConnectionLost,
    sekTimeout,
    sekCanceled,
    sekPrematureEof,        // flux plus court que la taille annoncee
    sekUnsupported,
    sekAttrRefused,         // avertissement, JAMAIS un echec
    sekOther);

  TScpError = record
    Kind: TScpErrorKind;
    Operation: string;      // 'Uploading', 'Listing'...
    Subject: string;        // deja neutralise
    Detail: string;
  end;

function MakeScpError(AKind: TScpErrorKind;
  const AOperation, ASubject, ADetail: string): TScpError;
function NoScpError: TScpError;

function IsWarningOnly(AKind: TScpErrorKind): Boolean;
function IsFatalToSession(AKind: TScpErrorKind): Boolean;
// Decide si on PROPOSE Retry.
function IsWorthRetrying(AKind: TScpErrorKind): Boolean;

function ScpErrorKindLabel(AKind: TScpErrorKind): string;
function ScpErrorText(const AError: TScpError): string;

type
  // OS et protocole ne disent que « permission denied »; le contexte dit lequel.
  TScpAccessContext = (acRead, acWrite, acDir);

function AccessDeniedKind(AContext: TScpAccessContext): TScpErrorKind;
function WithAccessContext(const AError: TScpError;
  AContext: TScpAccessContext): TScpError;

function SftpStatusToKind(AFxCode: LongWord;
  AContext: TScpAccessContext): TScpErrorKind;
function OsErrorToKind(AOsCode: Integer): TScpErrorKind;

implementation

function MakeScpError(AKind: TScpErrorKind;
  const AOperation, ASubject, ADetail: string): TScpError;
begin
  Result.Kind := AKind;
  Result.Operation := AOperation;
  Result.Subject := ASubject;
  Result.Detail := ADetail;
end;

function NoScpError: TScpError;
begin
  Result := MakeScpError(sekNone, '', '', '');
end;

function IsWarningOnly(AKind: TScpErrorKind): Boolean;
begin
  Result := AKind in [sekNone, sekAttrRefused];
end;

function IsFatalToSession(AKind: TScpErrorKind): Boolean;
begin
  Result := AKind in [sekConnectionLost, sekTimeout];
end;

function IsWorthRetrying(AKind: TScpErrorKind): Boolean;
begin
  Result := AKind in [sekConnectionLost, sekTimeout, sekLocked,
    sekTooManyFiles, sekPrematureEof, sekOther];
end;

function ScpErrorKindLabel(AKind: TScpErrorKind): string;
begin
  case AKind of
    sekNone: Result := '';
    sekAccessDeniedDir: Result := 'Folder not readable';
    sekAccessDeniedRead: Result := 'Source not readable';
    sekAccessDeniedWrite: Result := 'Destination not writable';
    sekReadOnlyTarget: Result := 'Target is read-only';
    sekRenameRefused: Result := 'Rename refused';
    sekNoSpace: Result := 'No space left';
    sekTooManyFiles: Result := 'Too many open files';
    sekLocked: Result := 'File locked';
    sekNotFound: Result := 'Not found';
    sekPathGone: Result := 'Vanished';
    sekAlreadyExists: Result := 'Already exists';
    sekNotADirectory: Result := 'Not a directory';
    sekDirNotEmpty: Result := 'Folder not empty';
    sekInvalidName: Result := 'Invalid name here';
    sekIsSpecialFile: Result := 'Special file';
    sekSymlinkSkipped: Result := 'Symbolic link';
    sekOutsideRoot: Result := 'Outside destination';
    sekConnectionLost: Result := 'Connection lost';
    sekTimeout: Result := 'Timed out';
    sekCanceled: Result := 'Canceled';
    sekPrematureEof: Result := 'Truncated';
    sekUnsupported: Result := 'Not supported';
    sekAttrRefused: Result := 'Attributes not preserved';
  else
    Result := 'Error';
  end;
end;

// Vide plutot que generique: un conseil creux noie ceux qui comptent.
function KindAdvice(AKind: TScpErrorKind): string;
begin
  case AKind of
    sekAccessDeniedDir:
      Result := 'The account has no read or traverse permission on it.';
    sekAccessDeniedRead:
      Result := 'It appeared in the listing, but opening it was refused.';
    sekAccessDeniedWrite:
      Result := 'Creating or writing the destination was refused.';
    sekReadOnlyTarget:
      Result := 'Clear the read-only flag, or choose Keep both.';
    sekRenameRefused:
      Result := 'The temporary copy was written, but replacing the target ' +
        'was refused, so the existing file was left untouched.';
    sekNoSpace:
      Result := 'The destination is full or the quota is exhausted.';
    sekTooManyFiles:
      Result := 'Close some files or lower the number of items in the queue.';
    sekLocked:
      Result := 'Another program is holding it open.';
    sekPathGone:
      Result := 'It was there when the folder was listed and has since ' +
        'been moved or deleted.';
    sekAlreadyExists:
      Result := 'This is a name conflict, not a permission problem.';
    sekInvalidName:
      Result := 'Rename it at the source, or skip it.';
    sekIsSpecialFile:
      Result := 'Sockets, pipes and devices are not copied as files.';
    sekSymlinkSkipped:
      Result := 'Symbolic links are never followed during a recursive copy.';
    sekOutsideRoot:
      Result := 'The name would place it outside the chosen folder. ' +
        'Refused.';
    sekConnectionLost:
      Result := 'Reconnect, then resume the queue.';
    sekPrematureEof:
      Result := 'The source ended before the announced size. Nothing was ' +
        'written over the existing target.';
    sekAttrRefused:
      Result := 'The contents transferred correctly; only the timestamp or ' +
        'mode could not be set.';
  else
    Result := '';
  end;
end;

function ScpErrorText(const AError: TScpError): string;
var
  advice: string;
begin
  if AError.Kind = sekNone then Exit('');
  if AError.Subject <> '' then
    Result := Format('%s %s: %s', [AError.Operation, AError.Subject,
      ScpErrorKindLabel(AError.Kind)])
  else
    Result := Format('%s: %s', [AError.Operation,
      ScpErrorKindLabel(AError.Kind)]);
  advice := KindAdvice(AError.Kind);
  if advice <> '' then
    Result := Result + ' -- ' + advice;
  if AError.Detail <> '' then
    Result := Result + ' (' + AError.Detail + ')';
end;

const
  FX_EOF = 1;
  FX_NO_SUCH_FILE = 2;
  FX_PERMISSION_DENIED = 3;
  FX_FAILURE = 4;
  FX_BAD_MESSAGE = 5;
  FX_NO_CONNECTION = 6;
  FX_CONNECTION_LOST = 7;
  FX_OP_UNSUPPORTED = 8;
  FX_INVALID_HANDLE = 9;
  FX_NO_SUCH_PATH = 10;
  FX_FILE_ALREADY_EXISTS = 11;
  FX_WRITE_PROTECT = 12;
  FX_NO_MEDIA = 13;
  FX_NO_SPACE_ON_FILESYSTEM = 14;
  FX_QUOTA_EXCEEDED = 15;
  FX_LOCK_CONFLICT = 17;
  FX_DIR_NOT_EMPTY = 18;
  FX_NOT_A_DIRECTORY = 19;
  FX_INVALID_FILENAME = 20;
  FX_LINK_LOOP = 21;

function AccessDeniedKind(AContext: TScpAccessContext): TScpErrorKind;
begin
  case AContext of
    acRead: Result := sekAccessDeniedRead;
    acDir: Result := sekAccessDeniedDir;
  else
    Result := sekAccessDeniedWrite;
  end;
end;

function WithAccessContext(const AError: TScpError;
  AContext: TScpAccessContext): TScpError;
begin
  Result := AError;
  if Result.Kind in [sekAccessDeniedDir, sekAccessDeniedRead,
     sekAccessDeniedWrite] then
    Result.Kind := AccessDeniedKind(AContext);
end;

function SftpStatusToKind(AFxCode: LongWord;
  AContext: TScpAccessContext): TScpErrorKind;
begin
  case AFxCode of
    FX_EOF: Result := sekPrematureEof;
    FX_NO_SUCH_FILE, FX_NO_SUCH_PATH: Result := sekNotFound;
    FX_PERMISSION_DENIED: Result := AccessDeniedKind(AContext);
    FX_NO_CONNECTION, FX_CONNECTION_LOST: Result := sekConnectionLost;
    FX_OP_UNSUPPORTED: Result := sekUnsupported;
    FX_INVALID_HANDLE: Result := sekPathGone;
    FX_FILE_ALREADY_EXISTS: Result := sekAlreadyExists;
    FX_WRITE_PROTECT: Result := sekReadOnlyTarget;
    FX_NO_MEDIA: Result := sekPathGone;
    FX_NO_SPACE_ON_FILESYSTEM, FX_QUOTA_EXCEEDED: Result := sekNoSpace;
    FX_LOCK_CONFLICT: Result := sekLocked;
    FX_DIR_NOT_EMPTY: Result := sekDirNotEmpty;
    FX_NOT_A_DIRECTORY: Result := sekNotADirectory;
    FX_INVALID_FILENAME: Result := sekInvalidName;
    FX_LINK_LOOP: Result := sekSymlinkSkipped;
    // Le fourre-tout du protocole: deviner serait pire qu'avouer.
    FX_FAILURE, FX_BAD_MESSAGE: Result := sekOther;
  else
    Result := sekOther;
  end;
end;

{$IFDEF WINDOWS}
const
  ERROR_FILE_NOT_FOUND = 2;
  ERROR_PATH_NOT_FOUND = 3;
  ERROR_TOO_MANY_OPEN_FILES = 4;
  ERROR_ACCESS_DENIED = 5;
  ERROR_NOT_READY = 21;
  ERROR_WRITE_PROTECT = 19;
  ERROR_SHARING_VIOLATION = 32;
  ERROR_LOCK_VIOLATION = 33;
  ERROR_HANDLE_DISK_FULL = 39;
  ERROR_FILE_EXISTS = 80;
  ERROR_INVALID_NAME = 123;
  ERROR_DIR_NOT_EMPTY = 145;
  ERROR_ALREADY_EXISTS = 183;
  ERROR_FILENAME_EXCED_RANGE = 206;
  ERROR_DISK_FULL = 112;
  ERROR_DISK_QUOTA_EXCEEDED = 1295;
{$ENDIF}

function OsErrorToKind(AOsCode: Integer): TScpErrorKind;
begin
  {$IFDEF WINDOWS}
  case AOsCode of
    ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND: Result := sekNotFound;
    ERROR_TOO_MANY_OPEN_FILES: Result := sekTooManyFiles;
    ERROR_ACCESS_DENIED: Result := sekAccessDeniedWrite;
    ERROR_WRITE_PROTECT: Result := sekReadOnlyTarget;
    // volume retire, partage hors ligne
    ERROR_NOT_READY: Result := sekPathGone;
    ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION: Result := sekLocked;
    ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL,
      ERROR_DISK_QUOTA_EXCEEDED: Result := sekNoSpace;
    ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS: Result := sekAlreadyExists;
    ERROR_INVALID_NAME, ERROR_FILENAME_EXCED_RANGE: Result := sekInvalidName;
    ERROR_DIR_NOT_EMPTY: Result := sekDirNotEmpty;
  else
    Result := sekOther;
  end;
  {$ELSE}
  case AOsCode of
    // Constantes, pas numeros: au-dela de 35, Linux et macOS divergent.
    ESysEPERM: Result := sekAccessDeniedWrite;
    ESysENOENT: Result := sekNotFound;
    ESysEACCES: Result := sekAccessDeniedWrite;
    ESysEEXIST: Result := sekAlreadyExists;
    ESysENOTDIR: Result := sekNotADirectory;
    ESysEISDIR: Result := sekNotADirectory;
    ESysEMFILE: Result := sekTooManyFiles;
    ESysENOSPC: Result := sekNoSpace;
    ESysEROFS: Result := sekReadOnlyTarget;
    ESysENAMETOOLONG: Result := sekInvalidName;
    ESysENOTEMPTY: Result := sekDirNotEmpty;
    ESysELOOP: Result := sekSymlinkSkipped;
    ESysEDQUOT: Result := sekNoSpace;
  else
    Result := sekOther;
  end;
  {$ENDIF}
end;

end.
