{ Contrat du moteur de transfert, sans LCL ni libssh2: testable contre des
  backends factices qui produisent a volonte ce qu'un vrai serveur reserve au
  pire moment. Classe et non interface COM: le thread de transport possede,
  un comptage de references ne ferait que brouiller qui.

  Convention: False remplit AErr. Un False avec sekNone est un bogue.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpBackend;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, uScpErrors, uScpPaths;

type
  TScpEntry = record
    Name: string;          // nom simple, jamais un chemin
    IsDir: Boolean;
    IsLink: Boolean;
    IsSpecial: Boolean;    // socket, tube, peripherique: jamais lu comme fichier
    TargetIsDir: Boolean;  // lien: nature de la CIBLE, sans recursion
    BrokenLink: Boolean;
    // Faux = les deux champs ci-dessus sont du vent: SFTP ne suit plus chaque
    // lien (trois allers-retours par lien dans /usr/lib, merci). Le serveur tranche.
    TargetKnown: Boolean;
    Size: Int64;           // -1 si inconnue
    Mode: LongWord;        // 0 si le serveur ne l'a pas envoye
    ModeKnown: Boolean;    // sinon 0 = « inconnu » ET « aucun droit »
    // Tous les Is* a faux ne veut PAS dire fichier ordinaire: on refuse l'innommable.
    TypeUnknown: Boolean;
    MTimeUtc: Int64;       // secondes Unix, 0 si inconnue
    Owner: string;
    Group: string;
    LinkTarget: string;
    Hidden: Boolean;
    ReadOnly: Boolean;
    AttrsUnknown: Boolean;
  end;

  TScpEntryArray = array of TScpEntry;

  // Propriete du backend: le moteur ne fait que la passer.
  TScpFileHandle = class
  end;

  TScpOpenMode = (somRead, somWriteNew);

  TScpFileSystem = class
  public
    function IsRemote: Boolean; virtual; abstract;
    function DisplayName: string; virtual; abstract;

    function Canceled: Boolean; virtual; abstract;

    function HomeDir(out APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Echec non fatal: on garde la forme lexicale.
    function RealPath(const APath: string; out AResolved: string;
      out AErr: TScpError): Boolean; virtual; abstract;
    // JAMAIS '.' ni '..': elles deviendraient transferables, voire supprimables.
    function List(const APath: string; out AEntries: TScpEntryArray;
      out AErr: TScpError): Boolean; virtual; abstract;
    // AFollowLink=False = lstat.
    function Stat(const APath: string; AFollowLink: Boolean;
      out AEntry: TScpEntry; out AErr: TScpError): Boolean; virtual; abstract;
    // AErr seulement si la question n'a pas pu etre posee.
    function Exists(const APath: string; out AFound: Boolean;
      out AErr: TScpError): Boolean; virtual; abstract;

    // AMode pose A LA CREATION: prive des la naissance, pas apres un chmod.
    function MakeDir(const APath: string; AMode: LongWord;
      out AErr: TScpError): Boolean; virtual; abstract;
    // N'ecrase JAMAIS. Entorse a la convention: True + AErr = publie sous ATo,
    // AFrom reste a nettoyer.
    function Rename(const AFrom, ATo: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    // sekUnsupported/sekRenameRefused: l'appelant DEMANDE avant tout repli,
    // il ne supprime jamais la cible de lui-meme.
    function ReplaceAtomic(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; virtual; abstract;
    function DeleteFile(const APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Passe outre la lecture seule que CopyAttributesFrom a pu poser.
    function DeleteTemp(const APath: string; out AErr: TScpError): Boolean;
      virtual;
    function DeleteDir(const APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;

    function OpenRead(const APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Nom imprevisible, creation EXCLUSIVE: un lien deja pose fait echouer, pas
    // suivre. L'umask peut encore restreindre AMode.
    function CreateTemp(const ADir: string; AMode: LongWord;
      out APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Poignee en LECTURE aussi: le prefixe verifie doit l'etre par la MEME. Un
    // lien doit echouer a l'ouverture, ou juste apres en SFTP v3 qui ne sait pas.
    function OpenAppend(const APath: string; AOffset: Int64;
      out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;
    // AGot < ACount n'est NI une erreur NI la fin: seul AGot = 0 est la fin.
    function Read(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out AGot: Integer; out AErr: TScpError): Boolean; virtual; abstract;
    // APut < ACount est normal: l'appelant boucle.
    function Write(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out APut: Integer; out AErr: TScpError): Boolean; virtual; abstract;
    function Seek(AHandle: TScpFileHandle; AOffset: Int64;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Un echec ici est un echec du TRANSFERT.
    function Flush(AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Libere meme en cas d'echec.
    function Close(AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;

    // Par la POIGNEE: ferme, le nom du temporaire peut deja designer le fichier
    // d'un tiers. Echec = sekAttrRefused, un avertissement.
    function SetMTime(AHandle: TScpFileHandle; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; virtual; abstract;
    function SetMode(AHandle: TScpFileHandle; AMode: LongWord;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Par CHEMIN (fenetre de proprietes). SETSTAT suit les liens: l'appelant
    // les ecarte par lstat avant.
    function SetModeAt(const APath: string; AMode: LongWord;
      out AErr: TScpError): Boolean; virtual;
    // Copie sur place: ACL Windows posee avant le premier octet.
    function CopyProtectionFrom(const ASourcePath, ATargetPath: string;
      out AErr: TScpError): Boolean; virtual;
    // Le dossier NAIT protege: pas de poignee exclusive pour couvrir l'apres-coup.
    function MakeDirFromSource(const ASourcePath, APath: string;
      AMode: LongWord; out AErr: TScpError): Boolean; virtual;
    // Lecture seule, cache, systeme, hors index. En dernier, avant fermeture.
    function CopyAttributesFrom(ASource, ATarget: TScpFileHandle;
      out AErr: TScpError): Boolean; virtual;

    // Chaque cote a ses regles: jamais de concatenation nue.
    function Join(const ABase, AName: string): string; virtual; abstract;
    function Parent(const APath: string): string; virtual; abstract;
    function BaseName(const APath: string): string; virtual; abstract;
    function Normalize(const APath: string): string; virtual; abstract;
    function IsUnder(const ARoot, APath: string): Boolean; virtual; abstract;
    function CheckName(const AName: string): TNameVerdict; virtual; abstract;
    // Deux noms, un seul fichier (casse, points).
    function CollisionKey(const AName: string): string; virtual; abstract;
  end;

// Source muette (disque Windows). Jamais de setuid/setgid/sticky reportes sur
// un contenu nouveau.
const
  SCP_DEFAULT_FILE_MODE = &0644;
  SCP_DEFAULT_DIR_MODE = &0755;

implementation

function TScpFileSystem.SetModeAt(const APath: string; AMode: LongWord;
  out AErr: TScpError): Boolean;
begin
  AErr := MakeScpError(sekUnsupported, 'Setting the permissions of',
    DisplaySafeName(APath), '');
  Result := False;
end;

function TScpFileSystem.CopyProtectionFrom(const ASourcePath,
  ATargetPath: string; out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  Result := True;
end;

function TScpFileSystem.MakeDirFromSource(const ASourcePath, APath: string;
  AMode: LongWord; out AErr: TScpError): Boolean;
begin
  Result := MakeDir(APath, AMode, AErr);
end;

function TScpFileSystem.CopyAttributesFrom(ASource, ATarget: TScpFileHandle;
  out AErr: TScpError): Boolean;
begin
  AErr := NoScpError;
  Result := True;
end;

function TScpFileSystem.DeleteTemp(const APath: string;
  out AErr: TScpError): Boolean;
begin
  Result := DeleteFile(APath, AErr);
end;

end.
