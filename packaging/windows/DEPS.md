# Dépendances natives Windows

Les chargeurs (`bindings/*`) attendent chaque DLL **à côté de l'exécutable**
(chemin absolu construit sur `ParamStr(0)`, jamais de recherche
`PATH`/répertoire courant). Pour le développement : à la racine du dépôt, à
côté de `rottensshrimp.exe`. Les DLL **sont versionnées** (éviter de les
reprovisionner/recompiler à chaque clone) ; ce fichier consigne provenance et
empreintes.

## Contrôle d'intégrité

`scripts/check-win-deps.sh` confronte chaque empreinte consignée ici aux DLL
effectivement versionnées. Toute DLL suivie doit avoir son empreinte ici et
toute empreinte doit correspondre au fichier suivi. Un document de provenance
aux empreintes fausses ne prouve plus rien : il continue simplement à
*ressembler* à une preuve, ce qui est strictement pire que son absence.
Constat de revue du 2026-07-30 : 9 empreintes sur 11 étaient périmées après un
re-provisioning que personne n'avait répercuté ici. À lancer en CI et à chaque
re-provisioning, parce que la mémoire humaine a déjà été essayée.

## Provisionnées (2026-07-21 ; FreeRDP re-provisionné 2026-07-30)

### sqlite3.dll : SQLite 3.53.3 (x64)

- Source : https://www.sqlite.org/2026/sqlite-dll-win-x64-3530300.zip
- SHA3-256 de l'archive (publiée sur sqlite.org, vérifiée) :
  `3a494861ce24d1f330efbc6c3fb58ce4972f2cf8df4e43122246ed987109dc8a`
- SHA-256 de l'archive : `ad713e1865bdc1e3f7647618697fad71ecf8967edabb9dcc903c1b48c6a7cce2`
- SHA-256 de `sqlite3.dll` : `79fd9ec89dba3f8bd64529a2ca8e9dde6ae6edc486c55a1d3f1ce77975a8375c`

### libsodium.dll : libsodium 1.0.22 stable (x64, MSVC v143, dynamic Release)

- Source : https://download.libsodium.org/libsodium/releases/libsodium-1.0.22-stable-msvc.zip
  (DLL extraite de `libsodium/x64/Release/v143/dynamic/`)
- SHA-256 de l'archive : `d0a945a6ac8f6b60e47e1d9778b99b0beb6e0817602ef53543defbd39c108e7f`
- SHA-256 de `libsodium.dll` : `c636ec98e72d67466ef314cf4d09b720b33769e3d52ab036e102fa25a6a13142`
- Le `.minisig` officiel accompagne l'archive ; vérification minisign à
  intégrer quand l'outil sera disponible sur la machine de build (clé
  publique libsodium : `RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3`).

### libssh2.dll (+ libcrypto-3-x64.dll + z.dll) : libssh2 1.11.1, backend OpenSSL

Trois DLL à poser ensemble à côté de l'exe : `libssh2.dll`, sa dépendance
crypto `libcrypto-3-x64.dll` (OpenSSL 3.6.3) et `z.dll` (zlib).

- Construites via **vcpkg** (2026-07-22) : `libssh2[core,openssl,zlib]:x64-windows`,
  baseline vcpkg `82b6bc886d7b0f8342e34babc2e0b8943f79b0e1`, OpenSSL 3.6.3.
- **Backend OpenSSL, PAS WinCNG.** Un premier build WinCNG (sans dépendance
  externe) échouait la négociation de kex avec des serveurs OpenSSH durcis :
  WinCNG n'offre pas les échanges Diffie-Hellman `group14/16/18-sha2` ni
  `group-exchange-sha256` que ces serveurs exigent (« no matching key exchange
  method found » côté serveur). OpenSSL couvre tout l'éventail, c'est le
  backend qu'utilisait déjà la version macOS. Ne pas revenir à WinCNG.
- SHA-256 des DLL versionnées (builds vcpkg non reproductibles au bit près :
  l'empreinte fait foi pour le FICHIER SUIVI, contrôlée par
  `scripts/check-win-deps.sh`). `libcrypto-3-x64.dll` et `z.dll` proviennent
  depuis 2026-07-30 du build FreeRDP (baseline
  `c1d80d9cb071c3f4a98c67c1196b137cc5b72918`) : mêmes versions (OpenSSL
  3.6.3, zlib 1.3.2), un seul jeu cohérent pour toutes les DLL ; libssh2,
  lié à ces noms de DLL et à l'ABI stable d'OpenSSL 3, n'a pas besoin d'être
  reconstruit :
  - `libssh2.dll` : `43682e313244ec65f735de223d698cfc8cfc4b4112e3502cce04a9b351caf3e0`
  - `libcrypto-3-x64.dll` : `acca52ccd0c3641281c1fc696d0a57a968786db9348be83e0b0f6451928edde0`
  - `z.dll` : `eb73c521d1d74a43fc2aaa4107ef080ec76edbc42971a6138e9c5579d1fa8fbf`
- Dépend aussi de `VCRUNTIME140.dll` / UCRT (VC++ redist, présent avec Visual
  Studio ; à inclure dans le paquet final).
- À terme : `bindings/libssh2` documente déjà `<exeDir>\libssh2.dll` ; les deux
  autres DLL se chargent par dépendance depuis le même dossier. Script de
  provisioning vcpkg versionné à ajouter.

### FreeRDP 3 : freerdp3.dll + freerdp-client3.dll + winpr3.dll (+ deps)

Le binding charge `freerdp3.dll`, `freerdp-client3.dll`, `winpr3.dll` depuis
exeDir (major 3). DLL à poser ensemble :

- `freerdp3.dll`, `freerdp-client3.dll`, `winpr3.dll` (FreeRDP **3.30.0**,
  re-provisioning sécurité 2026-07-30 : la 3.26.0 livrée jusque-là était
  vulnérable à deux débordements de tas dans le client TS Gateway,
  GHSA-9gxm-3mf5-f5cx et GHSA-7rp4-66mc-j9vx, corrigés en 3.27.0, alors que
  le chemin passerelle est branché)
- `cjson.dll` (dépendance de winpr3, 1.7.19)
- `libssl-3-x64.dll` + `libcrypto-3-x64.dll` (OpenSSL 3.6.3, **le même
  libcrypto que libssh2**, un seul OpenSSL cohérent)
- `legacy.dll`, **provider OpenSSL « legacy »**, INDISPENSABLE à NLA :
  l'authentification RDP passe par NTLM, qui exige MD4 + RC4, algorithmes
  hérités qu'OpenSSL 3.x ne fournit QUE via ce module séparé. Le fichier dont
  le nom annonce que plus personne ne devrait s'en servir est donc requis pour
  ouvrir une session Windows en 2026 ; le supprimer par souci de propreté est
  une erreur que l'on ne commet qu'une fois. Sans lui :
  « OpenSSL LEGACY provider failed to load » → NTLM indisponible →
  `ERRCONNECT_LOGON_FAILURE` → écran noir + déconnexion. Le code pose
  `OPENSSL_MODULES` sur le dossier de l'exe (`uRdpTransport`) pour qu'OpenSSL
  l'y trouve après relocalisation des DLL.
- `z.dll` (zlib 1.3.2, déjà livré pour libssh2)
- `rssh_rdp_shim.dll`, **l'oracle de disposition mémoire**
  (`bindings/freerdp/shim/rssh_rdp_shim.c`, ABI 3), compilé MSVC contre les
  en-têtes du build vcpkg 3.30.0. Ne lie PAS FreeRDP (importe uniquement
  kernel32) ; le binding le charge depuis exeDir et l'écarte de lui-même si
  sa version bâtie (3.30) ne correspond pas à la DLL chargée. À
  **reconstruire à chaque re-provisioning FreeRDP** (voir ci-dessous),
  sinon il se désactive et l'application retombe sur les offsets en dur.

- Construits via **vcpkg** (2026-07-30) : `freerdp[client]:x64-windows@3.30.0`,
  baseline `c1d80d9cb071c3f4a98c67c1196b137cc5b72918`, outil vcpkg
  `2026-07-27`. **Piège découvert à ce re-provisioning** : le port `freerdp`
  du registre vcpkg est resté à **3.26.0**, même à la baseline la plus
  récente, c'est-à-dire que « prendre la dernière version de vcpkg » livrait
  encore, ce jour-là, une bibliothèque vulnérable à deux débordements de tas
  corrigés depuis la 3.27.0. La 3.30.0 a donc été construite via un
  **overlay port** local : copie de `ports/freerdp`, version passée à
  3.30.0, SHA512 du tarball GitHub recalculé localement
  (`5559616755c3050077589c1000ea451b195cfb450c74d2278c6a09e0c2bfff718293dbc0041428c0a8e8ca321131daa14c92483f70bb5bed4482bb7962f1ef92`),
  feature `client` demandée explicitement (le port n'a pas de features par
  défaut), les 4 patches du port 3.26 s'appliquent tels quels. Le vcpkg
  embarqué avec Visual Studio est inutilisable pour cela (base de versions
  figée, outil trop vieux pour le registre récent) : cloner
  `microsoft/vcpkg` et `bootstrap-vcpkg.bat`.
- Offsets de la branche non-Darwin **revérifiés contre les en-têtes 3.30.0**
  (sonde `scripts/gen-rdp-offsets.c` compilée MSVC) : les 62 offsets, dont
  `BITMAP_OFF_HDC` = 296, sont identiques à la table de `uFreeRdpApi.pas` :
  aucun changement entre 3.26.0 et 3.30.0 sur x64 Windows.
- SHA-256 des DLL versionnées (même régime que libssh2 ci-dessus) :
  - `freerdp3.dll` : `349ccc2371bbe5a3275b2dd26adb7b2d96634c42c5cc0d2e70443557f0694c0d`
  - `freerdp-client3.dll` : `cc1137a1cfb6c39f6376f37944ebc79b44ea69406f141ccc943e1f43a8575a8e`
  - `winpr3.dll` : `d410946ed0633b4d1f2e3eb93cf9d9c4092554b86ec110ae4959f1bdec9d6487`
  - `cjson.dll` : `f0935a9585349819ea2b866bb7aa06d7ddee983df9b42c84098e0729d662d8ea`
  - `libssl-3-x64.dll` : `cf8ac5afe70e86caf12bbcebf53c33b433425df66aa4a9199ed770ededcc9380`
  - `legacy.dll` : `c1cc942460ff0e73fa40689b58d959e48bf8d81fbb119dce8ecf137cf213e66e`
  - `rssh_rdp_shim.dll` : `4838b43a340c09d7d8123693bde4283e7ebd79e1340cb1ef3be75ae83d7f6520`
- Note portage : `WaitForMultipleObjects` est résolu depuis `kernel32.dll` sous
  Windows (API native), pas depuis winpr3 qui, contrairement à l'émulation
  WinPR d'Unix, ne la réexporte pas.

### VNC : vncclient.dll (+ jpeg62.dll + z.dll)

libvncclient 0.9.15 **vendorisée + patchée** (comme sous Unix : 3 patchs CVE
Tight/UltraZip, config figée zlib+JPEG, tout le reste OFF). Le binding charge
`vncclient.dll` depuis exeDir.

- Source épinglée : `third_party/libvnc/SHA256SUMS`
  (`62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7`), patchs
  dans `third_party/libvnc/patches/`.
- Build MSVC/CMake/Ninja (2026-07-22), `CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON`
  (MSVC n'exporte rien sans `__declspec`, la source LibVNC n'annote pas) ;
  zlib + libjpeg-turbo fournis via vcpkg. Lie l'UCRT (cohérent avec le
  `c_malloc`/`_msize` du binding liés à `ucrtbase.dll`).
- Dépendances à livrer avec : `z.dll` (déjà présent), `jpeg62.dll` (libjpeg
  3.2.0, vcpkg).
- SHA-256 des DLL versionnées (même régime que libssh2 ci-dessus) :
  - `vncclient.dll` : `0e2b44102ebb4fb94a410ac3c2651d2c3a33c4e75eff58bd440d749c9e93bed0`
  - `jpeg62.dll` : `4a0b915d9d29be3b6c9f812f3b0c47e7347007292bf6f3b292841af2b9805e29`
- **Offsets `rfbClient` régénérés pour Windows** (LLP64 : `SOCKET sock` = 8 o
  vs int=4, padding différent) → bloc conditionnel `{$IFDEF WINDOWS}` dans
  `uLibVncApi`, regénéré via `scripts/gen-vnc-offsets.c` compilé contre les
  en-têtes du build (définir `WIN32`, inclure zlib/jpeg). Validés au chargement
  (`CheckStructLayout` + `_msize`) et par `TVncApiTests`.

## Provisioning reproductible

Les trois protocoles s'appuient sur des builds vcpkg : baseline
`82b6bc886d7b0f8342e34babc2e0b8943f79b0e1` (libssh2, libjpeg),
`c1d80d9cb071c3f4a98c67c1196b137cc5b72918` (FreeRDP 3.30.0 + OpenSSL/zlib/
cjson, via overlay port : voir la section FreeRDP), ou, pour libvnc, sur la
source épinglée + patchs. Scripts de provisioning Windows versionnés à
ajouter (pendants de `build-libvnc.sh`). **Piège** : builder
libvnc/vcpkg depuis un chemin court (`D:\tmp\...`) : la limite Windows de
260 caractères casse sinon la génération CMake.

Contraintes : versions épinglées + hash avant usage,
architecture x64 vérifiée, `SetDefaultDllDirectories`/chemins absolus, DLL
transitives incluses, signature Authenticode du paquet final recommandée.
