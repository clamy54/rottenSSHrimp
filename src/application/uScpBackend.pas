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
    // Mode reellement connu? Sans ce drapeau, 0 voudrait dire « inconnu » ET
    // « aucun droit », et un fichier en 0000 serait publie autrement.
    ModeKnown: Boolean;
    // Le serveur n'a pas dit ce qu'est cette entree, ni au listing ni au lstat.
    // IsDir, IsLink et IsSpecial sont alors tous faux, ce qui ne veut PAS dire
    // « fichier ordinaire »: le moteur refuse ce qu'il ne sait pas nommer.
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
    // Ne remplace JAMAIS une cible existante. Seule entorse a la convention:
    // True AVEC AErr rempli veut dire « publie sous ATo, mais AFrom n'a pas pu
    // etre retire »; l'appelant garde alors AFrom dans ses partiels a nettoyer.
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
    // Cree un fichier NEUF dans ADir sous un nom imprevisible et en EXCLUSIF: un
    // lien deja pose doit faire echouer la creation, pas etre suivi. AMode est
    // DEMANDE a la creation, donc encore restreignable par l'umask.
    function CreateTemp(const ADir: string; AMode: LongWord;
      out APath: string; out AHandle: TScpFileHandle;
      out AErr: TScpError): Boolean; virtual; abstract;
    // Rouvre un partiel a AOffset. La poignee doit aussi LIRE: le moteur relit le
    // prefixe par elle avant d'ecrire, et c'est cette relecture par la MEME
    // poignee qui garantit qu'on prolonge le fichier verifie. Un lien a ce chemin
    // doit faire echouer l'ouverture -- ou, la ou le protocole ne sait pas le
    // refuser a l'ouverture (SFTP v3), etre detecte juste apres.
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
    // Par la POIGNEE, jamais par le chemin: une fois le temporaire ferme, son nom
    // peut designer autre chose, pose par un tiers qui ecrit dans le dossier. Un
    // echec remonte sekAttrRefused: AVERTISSEMENT, pas perte de contenu.
    function SetMTime(AHandle: TScpFileHandle; AMTimeUtc: Int64;
      out AErr: TScpError): Boolean; virtual; abstract;
    function SetMode(AHandle: TScpFileHandle; AMode: LongWord;
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

// Mode d'un fichier NEUF dont la source n'annonce rien (un disque Windows):
// lisible par tous, inscriptible par son seul proprietaire, jamais executable.
// Une source qui en annonce un le voit repris sans ecriture pour tous, sans
// setuid et sans bit d'execution. L'umask peut encore restreindre, jamais
// elargir. Un fichier REMPLACE garde ses droits de lecture, d'ecriture et
// d'execution, les memes des deux cotes; setuid, setgid et sticky ne sont
// jamais reportes sur un contenu nouveau.
const
  SCP_DEFAULT_FILE_MODE = &0644;
  SCP_DEFAULT_DIR_MODE = &0755;

implementation

end.
