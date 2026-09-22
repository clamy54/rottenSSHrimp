{ Taxonomie des erreurs de l'onglet Scp. Unite pure, partagee par le transport,
  la file et l'interface.

  Elle existe pour une raison precise: « Access denied » affiche a la place d'un
  disque plein, d'une perte reseau ou d'un conflit est le defaut le plus couteux
  de ce genre d'outil -- il envoie l'utilisateur regarder des permissions
  pendant que la vraie cause est ailleurs. Chaque cause a donc son code, et la
  conversion depuis SFTP ou depuis l'OS se fait une seule fois, ici.

  Un cas merite d'etre souligne: sekAttrRefused n'est PAS un echec. Le contenu
  est arrive intact; seule la date ou le mode n'a pas pu etre repose. Le
  transfert reste un succes assorti d'un avertissement.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpErrors;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TScpErrorKind = (
    sekNone,
    // --- droits, et QUI exactement refuse ---
    sekAccessDeniedDir,     // dossier non lisible ou non traversable
    sekAccessDeniedRead,    // source listee mais refusee a l'ouverture
    sekAccessDeniedWrite,   // creation ou ecriture refusee dans la cible
    sekReadOnlyTarget,      // cible existante en lecture seule
    sekRenameRefused,       // le dossier accepte un temporaire, pas le rename
    // --- ressources ---
    sekNoSpace,             // disque plein ou quota depasse
    sekTooManyFiles,        // handles epuises, limite de fichiers atteinte
    // --- etat du fichier ---
    sekLocked,              // verrou d'un autre processus
    sekNotFound,            // absent des le depart
    sekPathGone,            // present au listing, disparu depuis
    sekAlreadyExists,       // la cible existe (conflit, PAS un refus de droit)
    sekNotADirectory,       // un composant du chemin n'est pas un dossier
    sekDirNotEmpty,
    // --- ce qu'on refuse de traiter ---
    sekInvalidName,         // nom inacceptable sur la plateforme de destination
    sekIsSpecialFile,       // socket, tube, peripherique
    sekSymlinkSkipped,      // lien non suivi: une decision, pas une panne
    sekOutsideRoot,         // la cible sortirait du dossier choisi
    // --- transport ---
    sekConnectionLost,
    sekTimeout,
    sekCanceled,
    sekPrematureEof,        // le flux s'arrete avant la taille annoncee
    sekUnsupported,         // operation refusee par le serveur
    // --- avertissement, jamais un echec ---
    sekAttrRefused,         // date ou mode non reposes apres un transfert reussi
    sekOther);

  // Cause, operation et objet: les trois font un message qu'on puisse suivre.
  TScpError = record
    Kind: TScpErrorKind;
    // 'Uploading', 'Listing', 'Creating folder'...
    Operation: string;
    // Chemin en cause, deja neutralise.
    Subject: string;
    Detail: string;
  end;

function MakeScpError(AKind: TScpErrorKind;
  const AOperation, ASubject, ADetail: string): TScpError;
function NoScpError: TScpError;

// Un avertissement n'interrompt pas le lot et ne fait pas echouer l'element.
function IsWarningOnly(AKind: TScpErrorKind): Boolean;
function IsFatalToSession(AKind: TScpErrorKind): Boolean;
// Reessayer peut-il aboutir sans rien changer? Sert a PROPOSER Retry.
function IsWorthRetrying(AKind: TScpErrorKind): Boolean;

function ScpErrorKindLabel(AKind: TScpErrorKind): string;
function ScpErrorText(const AError: TScpError): string;

// Conversion depuis un code SSH_FX_* rendu par libssh2_sftp_last_error.
// AIsDirOp distingue « dossier illisible » de « fichier illisible », que le
// protocole confond tous deux dans SSH_FX_PERMISSION_DENIED.
function SftpStatusToKind(AFxCode: LongWord; AIsDirOp: Boolean): TScpErrorKind;
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
  // Un nom invalide ou un lien ignore ne changeront pas d'avis au second essai.
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

// Ce que l'utilisateur peut faire, vide s'il n'y a rien d'utile: un conseil
// generique dilue ceux qui comptent.
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

function SftpStatusToKind(AFxCode: LongWord; AIsDirOp: Boolean): TScpErrorKind;
begin
  case AFxCode of
    FX_EOF: Result := sekPrematureEof;
    FX_NO_SUCH_FILE, FX_NO_SUCH_PATH: Result := sekNotFound;
    FX_PERMISSION_DENIED:
      if AIsDirOp then
        Result := sekAccessDeniedDir
      else
        Result := sekAccessDeniedRead;
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
    // SSH_FX_FAILURE est le fourre-tout du protocole: disque plein ou rename
    // refuse y arrivent pareil. Le deviner serait pire que de l'admettre.
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
    // Un volume retire ou un partage hors ligne, pas un probleme de droits.
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
    1: Result := sekAccessDeniedWrite;    // EPERM
    2: Result := sekNotFound;             // ENOENT
    13: Result := sekAccessDeniedWrite;   // EACCES
    17: Result := sekAlreadyExists;       // EEXIST
    20: Result := sekNotADirectory;       // ENOTDIR
    21: Result := sekNotADirectory;       // EISDIR
    24: Result := sekTooManyFiles;        // EMFILE
    28: Result := sekNoSpace;             // ENOSPC
    30: Result := sekReadOnlyTarget;      // EROFS
    36: Result := sekInvalidName;         // ENAMETOOLONG
    39: Result := sekDirNotEmpty;         // ENOTEMPTY
    40: Result := sekSymlinkSkipped;      // ELOOP
    122: Result := sekNoSpace;            // EDQUOT
  else
    Result := sekOther;
  end;
  {$ENDIF}
end;

end.
