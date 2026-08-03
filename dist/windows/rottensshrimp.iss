; Installeur Windows pour RottenSSHrimp (Inno Setup 6).
; Prerequis : avoir compile l'executable avec scripts\build.ps1 -Release
; (l'exe attendu est rottensshrimp.exe a la racine du depot).
; Compilation de l'installeur : ISCC.exe rottensshrimp.iss (ou via l'IDE Inno).
;
; AppVersion est extrait de RSSH_VERSION (src\util\uVersion.pas) a la
; compilation : make-version.ps1 genere version.iss. Introuvable = erreur de
; compilation, jamais de version par defaut.

#define AppName "RottenSSHrimp"
#define AppPublisher "Cyril Lamy"
#define AppExe "rottensshrimp.exe"

#define VerRC Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + SourcePath + "\make-version.ps1""", SourcePath, 1, 0)
#if VerRC != 0
  #error make-version.ps1 a echoue: version non extraite de src\util\uVersion.pas
#endif
#include "version.iss"

; third-party.txt = LICENSES\THIRD-PARTY-NOTICES.md rendu lisible (Inno
; afficherait le markdown tel quel). Regenere ICI, a chaque compilation, pour
; qu'il ne puisse pas deriver de sa source.
#define NoticesRC Exec("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File """ + SourcePath + "\make-notices.ps1""", SourcePath, 1, 0)
#if NoticesRC != 0
  #error make-notices.ps1 a echoue: page des licences tierces non regeneree
#endif

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL=https://github.com/clamy54/RottenSSHrimp
DefaultDirName={autopf}\RottenSSHrimp
DefaultGroupName=RottenSSHrimp
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog commandline
UninstallDisplayIcon={app}\{#AppExe}
; page d'acceptation = la GPL-3, la licence de RottenSSHrimp lui-meme
LicenseFile=..\..\LICENSE
; page d'info juste apres: l'inventaire des oeuvres tierces livrees. L'afficher
; n'est pas une obligation -- les licences doivent ACCOMPAGNER la distribution,
; ce que fait [Files] -- mais autant que l'utilisateur voie ce qu'il installe.
InfoBeforeFile=third-party.txt
OutputDir=output
OutputBaseFilename=RottenSSHrimp-Setup-{#AppVersion}
SetupIconFile=..\..\app\rottensshrimp.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; x64 uniquement: toutes les DLL natives livrees le sont
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
Name: "assocrsh"; Description: "Associate .rsh documents with RottenSSHrimp"; GroupDescription: "Shell integration:"

[Files]
Source: "..\..\rottensshrimp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\app\rottensshrimp.ico"; DestDir: "{app}"

; Bibliotheques natives. Les chargeurs (bindings\*) les cherchent A COTE de
; l'executable, par chemin absolu construit sur ParamStr(0) -- jamais via le
; PATH ni le repertoire courant. Elles doivent donc atterrir dans {app}, pas
; dans un sous-dossier.
Source: "..\..\sqlite3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\libsodium.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\libssh2.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\freerdp3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\freerdp-client3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\winpr3.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\cjson.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\libssl-3-x64.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\libcrypto-3-x64.dll"; DestDir: "{app}"; Flags: ignoreversion
; legacy.dll = provider OpenSSL "legacy", INDISPENSABLE a NLA: l'auth RDP passe
; par NTLM, qui exige MD4 + RC4, qu'OpenSSL 3.x ne fournit que par ce module.
; Sans lui: ERRCONNECT_LOGON_FAILURE, ecran noir, deconnexion.
Source: "..\..\legacy.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\z.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\jpeg62.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\vncclient.dll"; DestDir: "{app}"; Flags: ignoreversion
; l'oracle de disposition memoire FreeRDP: absent, RDP retombe sur les offsets
; ecrits en dur (mode degrade mais fonctionnel)
Source: "..\..\rssh_rdp_shim.dll"; DestDir: "{app}"; Flags: ignoreversion

; Licences: on distribue des binaires tiers, leurs textes voyagent avec.
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"
Source: "..\..\LICENSES\*"; DestDir: "{app}\LICENSES"

; Source correspondante GPL de vncclient.dll (libvncclient est GPL-2.0-or-later,
; et nous la modifions: trois patchs de securite). La GPL exige que la source
; correspondante accompagne le binaire -- le tarball epingle lui-meme, pas une
; simple empreinte, qui ne reconstruit rien si l'amont disparait.
; Excludes: les artefacts de build locaux (non versionnes) n'ont rien a faire
; dans l'installeur -- sans quoi une machine de dev y embarquerait son cache.
Source: "..\..\third_party\libvnc\*"; DestDir: "{app}\source\libvnc"; Flags: recursesubdirs createallsubdirs; Excludes: "cache\*,work\*,out\*"
Source: "..\..\scripts\build-libvnc.sh"; DestDir: "{app}\source\libvnc"
Source: "..\..\scripts\gen-vnc-offsets.c"; DestDir: "{app}\source\libvnc"

[Icons]
Name: "{group}\RottenSSHrimp"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\rottensshrimp.ico"
Name: "{group}\{cm:UninstallProgram,RottenSSHrimp}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\RottenSSHrimp"; Filename: "{app}\{#AppExe}"; IconFilename: "{app}\rottensshrimp.ico"; Tasks: desktopicon

[Registry]
; Association des documents .rsh. HKA = HKLM en install machine, HKCU en
; install utilisateur. ProgID a nous, jamais de squat de l'extension d'autrui.
Root: HKA; Subkey: "Software\Classes\.rsh"; ValueType: string; ValueName: ""; ValueData: "RottenSSHrimp.Document"; Flags: uninsdeletevalue; Tasks: assocrsh
Root: HKA; Subkey: "Software\Classes\RottenSSHrimp.Document"; ValueType: string; ValueName: ""; ValueData: "RottenSSHrimp Document"; Flags: uninsdeletekey; Tasks: assocrsh
Root: HKA; Subkey: "Software\Classes\RottenSSHrimp.Document\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\rottensshrimp.ico,0"; Tasks: assocrsh
Root: HKA; Subkey: "Software\Classes\RottenSSHrimp.Document\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: assocrsh

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,RottenSSHrimp}"; Flags: nowait postinstall skipifsilent
