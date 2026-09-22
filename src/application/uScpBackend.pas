{ Interface de systeme de fichiers de l'onglet Scp. Abstraite, sans LCL et sans
  libssh2: le moteur de transfert ne connait que ce contrat, ce qui permet de
  le faire tourner contre des backends factices et d'y injecter ce qu'un
  serveur reel ne produit qu'au pire moment.

  Deux implementations concretes existent: uLocalFileSystem (disque local) et
  le backend SFTP porte par uSftpTransport. Une troisieme, factice, vit dans
  les tests.

  Classe abstraite et non interface COM: ces objets appartiennent au thread de
  transport, qui les cree et les detruit; un comptage de references n'apporte
  rien ici et masquerait qui possede quoi.

  Convention uniforme: toute methode rend True en cas de succes, et remplit
  AErr en cas d'echec. Un False avec AErr.Kind a sekNone est un bogue.

  Copyright (C) 2024 - 2026 Cyril LAMY
  SPDX-License-Identifier: GPL-3.0-or-later }
unit uScpBackend;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, uScpErrors, uScpPaths;

type
  // Une entree de listing. IsSpecial couvre sockets, tubes et peripheriques:
  // ce qu'on refuse de lire comme un fichier.
  TScpEntry = record
    Name: string;          // nom simple, tel que rendu; jamais un chemin
    IsDir: Boolean;
    IsLink: Boolean;
    IsSpecial: Boolean;
    // Pour un lien: ce que designe la CIBLE, si elle a pu etre suivie. Permet
    // « lien vers un dossier » sans le suivre en recursion.
    TargetIsDir: Boolean;
    BrokenLink: Boolean;
    Size: Int64;           // -1 si inconnue
    Mode: LongWord;        // 0 si le serveur ne l'a pas envoye
    MTimeUtc: Int64;       // secondes Unix, 0 si inconnue
    Owner: string;
    Group: string;
    LinkTarget: string;
    Hidden: Boolean;
    ReadOnly: Boolean;
    AttrsUnknown: Boolean;
  end;

  TScpEntryArray = array of TScpEntry;

  // Poignee ouverte, propriete du backend: le moteur ne fait que la passer.
  TScpFileHandle = class
  end;

  TScpOpenMode = (somRead, somWriteNew);

  TScpFileSystem = class
  public
    // Distant ou local: change les regles de nommage, pas le protocole d'appel.
    function IsRemote: Boolean; virtual; abstract;
    function DisplayName: string; virtual; abstract;

    // Annulation cooperative: le moteur l'interroge a chaque tour de boucle.
    function Canceled: Boolean; virtual; abstract;

    // --- Navigation ---
    function HomeDir(out APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    // realpath du serveur ou de l'OS. Un echec n'est pas fatal: forme lexicale.
    function RealPath(const APath: string; out AResolved: string;
      out AErr: TScpError): Boolean; virtual; abstract;
    // '.' et '..' ne doivent JAMAIS figurer dans AEntries: elles deviendraient
    // transferables ou supprimables.
    function List(const APath: string; out AEntries: TScpEntryArray;
      out AErr: TScpError): Boolean; virtual; abstract;
    // AFollowLink=False = lstat: c'est le lien lui-meme qu'on decrit.
    function Stat(const APath: string; AFollowLink: Boolean;
      out AEntry: TScpEntry; out AErr: TScpError): Boolean; virtual; abstract;
    // True si le chemin existe, quel qu'il soit. AErr seulement si la question
    // n'a pas pu etre posee.
    function Exists(const APath: string; out AFound: Boolean;
      out AErr: TScpError): Boolean; virtual; abstract;

    // --- Operations ---
    function MakeDir(const APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    function Rename(const AFrom, ATo: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Remplacement ATOMIQUE d'une cible existante. False + sekUnsupported ou
    // sekRenameRefused si la plateforme ne sait pas faire: l'appelant DEMANDE
    // avant un repli, il ne supprime jamais la cible de lui-meme.
    function ReplaceAtomic(const AFrom, ATo: string;
      out AErr: TScpError): Boolean; virtual; abstract;
    function DeleteFile(const APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;
    function DeleteDir(const APath: string; out AErr: TScpError): Boolean;
      virtual; abstract;

    // --- Fichiers ---
    function OpenRead(const APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Cree un fichier NEUF dans ADir, avec un nom imprevisible, en exigeant
    // l'exclusivite: un lien deja pose a ce nom doit faire echouer la
    // creation, pas etre suivi.
    function CreateTemp(const ADir: string; out APath: string;
      out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Rouvre un partiel pour y reprendre l'ecriture a AOffset.
    function OpenAppend(const APath: string; AOffset: Int64;
      out AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;
    // AGot < ACount n'est NI une erreur NI la fin: seul AGot = 0 est la fin.
    function Read(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out AGot: Integer; out AErr: TScpError): Boolean; virtual; abstract;
    // APut < ACount est normal: l'appelant boucle sur le reste.
    function Write(AHandle: TScpFileHandle; ABuf: PByte; ACount: Integer;
      out APut: Integer; out AErr: TScpError): Boolean; virtual; abstract;
    function Seek(AHandle: TScpFileHandle; AOffset: Int64;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Vide les tampons. Un echec ici est un echec du TRANSFERT.
    function Flush(AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;
    // Libere la poignee, meme en cas d'echec. AHandle est invalide apres.
    function Close(AHandle: TScpFileHandle; out AErr: TScpError): Boolean;
      virtual; abstract;

    // --- Metadonnees ---
    // Un echec remonte sekAttrRefused: AVERTISSEMENT, pas perte de contenu.
    function SetMTime(const APath: string; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; virtual; abstract;
    function SetMode(const APath: string; AMode: LongWord;
      out AErr: TScpError): Boolean; virtual; abstract;

    // --- Chemins: chaque cote a ses regles, jamais de concatenation nue ---
    function Join(const ABase, AName: string): string; virtual; abstract;
    function Parent(const APath: string): string; virtual; abstract;
    function BaseName(const APath: string): string; virtual; abstract;
    function Normalize(const APath: string): string; virtual; abstract;
    function IsUnder(const ARoot, APath: string): Boolean; virtual; abstract;
    function CheckName(const AName: string): TNameVerdict; virtual; abstract;
    // Cle detectant deux noms qui viseraient le meme fichier (casse, points).
    function CollisionKey(const AName: string): string; virtual; abstract;
  end;

// Mode par defaut d'un fichier envoye: lisible par tous, inscriptible par son
// seul proprietaire, et jamais executable. L'umask du serveur peut encore le
// restreindre -- il ne peut pas l'elargir.
const
  SCP_DEFAULT_FILE_MODE = &0644;
  SCP_DEFAULT_DIR_MODE = &0755;

implementation

end.
