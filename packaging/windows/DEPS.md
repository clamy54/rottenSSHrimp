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

## Provisionnées (2026-07-21 ; FreeRDP re-provisionné 2026-07-30, 2026-09-09 et 2026-10-25 ; OpenSSL et SQLite 2026-10-27)

### sqlite3.dll : SQLite 3.54.1 (x64)

- Source : https://www.sqlite.org/2026/sqlite-dll-win-x64-3540100.zip
- SHA3-256 de l'archive (publiée sur sqlite.org, vérifiée) :
  `c2d09c8babb9399277055c057c97a53f1ffd7c5f11d0c1f2118ffdfa39f2daa4`
- SHA-256 de l'archive : `f436f53ad8f965af43f3817b42c99c0689e6787f6b7ace208fe38dab7ffc4971`
- La 3.54 abandonne Windows XP et ses cousins : sans effet ici, l'application
  exige déjà bien plus récent.
- SHA-256 de `sqlite3.dll` : `4b59d3cded9dc1608544160f3b4b10ac974c6ac0d6ffc23064e5f4c8dbd05aea`

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
crypto `libcrypto-3-x64.dll` (OpenSSL 3.6.5) et `z.dll` (zlib).

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
  3.6.5 depuis le 2026-10-27, zlib 1.3.2), un seul jeu cohérent pour toutes
  les DLL ; libssh2,
  lié à ces noms de DLL et à l'ABI stable d'OpenSSL 3, n'a pas besoin d'être
  reconstruit :
  - `libssh2.dll` : `43682e313244ec65f735de223d698cfc8cfc4b4112e3502cce04a9b351caf3e0`
  - `libcrypto-3-x64.dll` : `476c7457fcbd6ea3194cec7d870b29f6e7f20a96aa1dc1b3972ebb72d9d13ee6`
  - `z.dll` : `eb73c521d1d74a43fc2aaa4107ef080ec76edbc42971a6138e9c5579d1fa8fbf`
- Dépend aussi de `VCRUNTIME140.dll` : livrée ici même, voir sa section plus
  bas (l'UCRT, elle, fait partie de Windows).
- À terme : `bindings/libssh2` documente déjà `<exeDir>\libssh2.dll` ; les deux
  autres DLL se chargent par dépendance depuis le même dossier. Script de
  provisioning vcpkg versionné à ajouter.

### FreeRDP 3 : freerdp3.dll + freerdp-client3.dll + winpr3.dll (+ deps)

Le binding charge `freerdp3.dll`, `freerdp-client3.dll`, `winpr3.dll` depuis
exeDir (major 3). DLL à poser ensemble :

- `freerdp3.dll`, `freerdp-client3.dll`, `winpr3.dll` (FreeRDP **3.32.2**,
  re-provisioning sécurité 2026-10-25 : la 3.31.1 en retard de trois
  versions, environ 70 avis corrigés entre 3.32.0 et 3.32.2, dont une
  majorité contre des messages de serveur piégés, c'est-à-dire notre côté
  du câble. La 3.32.0 seule est à éviter : elle rejetait les PDU de canal
  statique fragmentés et cassait le copier-coller des gros contenus. Le
  2026-09-09, la 3.30.0 livrée jusque-là était
  exposée, côté client, à un débordement de tas sur le jeton de redirection
  d'une réponse de négociation (GHSA-r9pv-ffph-6gg6, un serveur qui redirige
  choisit la taille) et à un déréférencement nul dans `gdi_surface_bits`
  sur une commande NSCodec (GHSA-ffjr-p229-hpch), tous deux corrigés en
  3.31.0, qui ferme en tout une vingtaine d'avis. Le 2026-07-30, la 3.26.0
  était déjà partie pour deux débordements de tas dans le client TS Gateway,
  GHSA-9gxm-3mf5-f5cx et GHSA-7rp4-66mc-j9vx, corrigés en 3.27.0. La
  bibliothèque qui parle au serveur est celle qui se met à jour le plus
  souvent ; c'est attendu.)
- `cjson.dll` (dépendance de winpr3, 1.7.19)
- `libssl-3-x64.dll` + `libcrypto-3-x64.dll` (OpenSSL 3.6.5, **le même
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
  (`bindings/freerdp/shim/rssh_rdp_shim.c`, ABI 6), compilé MSVC contre les
  en-têtes du build vcpkg 3.32.2. Ne lie PAS FreeRDP (importe uniquement
  kernel32) ; le binding le charge depuis exeDir et l'écarte de lui-même si
  sa version bâtie (3.32) ne correspond pas à la DLL chargée. À
  **reconstruire à chaque re-provisioning FreeRDP** (voir ci-dessous),
  sinon il se désactive et l'application retombe sur les offsets en dur.

- Construits via **vcpkg** (2026-10-25) : `freerdp[client]:x64-windows@3.32.2`,
  baseline `c1d80d9cb071c3f4a98c67c1196b137cc5b72918`, outil vcpkg
  `2026-07-27`, la même recette que le 2026-07-30 : le port `freerdp` du
  registre vcpkg est resté à **3.26.0**, même à la baseline la plus
  récente, c'est-à-dire que « prendre la dernière version de vcpkg » livre
  encore une bibliothèque vulnérable à deux débordements de tas corrigés
  depuis la 3.27.0. Les versions suivantes se construisent donc via un
  **overlay port** local : copie de `ports/freerdp`, version passée à
  3.32.2, SHA512 du tarball GitHub recalculé localement
  (`2f036908fc96650fcec0810c05cf7fbad08f7c47a27aa7951b25e4bc1f390eb47223eaeaf622715bf2df6bd056e7f245502a3af57e606fd53d214c121a862a7e` ;
  3.31.1 : `f01cbcf5504fbc609d50205e772f95bbb915caea6e87ee8d7c1d9a18a0c0f477d5ff2cec489d6e57c841a8a32232ac51b6f5df24fc8f207654fd38e501c5996d` ;
  3.30.0 : `5559616755c3050077589c1000ea451b195cfb450c74d2278c6a09e0c2bfff718293dbc0041428c0a8e8ca321131daa14c92483f70bb5bed4482bb7962f1ef92`),
  feature `client` demandée explicitement (le port n'a pas de features par
  défaut), les 4 patches du port 3.26 s'appliquaient tels quels jusqu'à la
  3.31.1 ; en 3.32, `install-layout.patch` a dû être recalé (deux lignes
  `FREERDP_LIBEXEC_*` apparues dans le bloc qu'il modifie, effet inchangé). Le
  vcpkg embarqué avec Visual Studio est inutilisable pour cela (base de
  versions figée, outil trop vieux pour le registre récent) : cloner
  `microsoft/vcpkg` et `bootstrap-vcpkg.bat`. Seules les trois DLL FreeRDP
  et le shim changent : OpenSSL, zlib et cJSON ressortent du build bit pour
  bit identiques aux fichiers versionnés, la baseline commune fait son
  travail.
- **OpenSSL 3.6.5** (2026-10-27) : la baseline commune s'arrête à 3.6.3,
  à qui manquent deux versions de correctifs de sécurité (3.6.4 et 3.6.5,
  la plus grave classée High). Même méthode que FreeRDP : overlay port
  `overlay/openssl`, copie du port 3.6.3, version passée à 3.6.5, SHA512 du
  tarball GitHub `openssl-3.6.5` recalculé localement
  (`40f0b346a9a5cf4cb37f1ecebdc74750c39a95783710061bfac58964883b0831543ecee0aee9f747ea093781b13c58a543b0b935d222519e3cb19648d77a0276`).
  FreeRDP et libfido2 sont reconstruits contre lui dans la même passe ;
  libssh2, lié à l'ABI stable d'OpenSSL 3, ne l'est pas. Le provider
  `legacy` (MD4, RC4 pour NTLM) a été vérifié chargeable avant livraison.
- Offsets de la branche non-Darwin **revérifiés contre les en-têtes 3.32.2**
  (sonde `scripts/gen-rdp-offsets.c` compilée MSVC) : les 71 offsets, dont
  `BITMAP_OFF_HDC` = 296, sont identiques à la table de `uFreeRdpApi.pas` :
  aucun changement entre 3.26.0 et 3.32.2 sur x64 Windows.
- Taille du contexte : depuis la 3.32, le code client de FreeRDP vérifie que
  le contexte alloué contient un `rdpClientContext` (3064 octets en x64) et
  refuse sinon ses propres traitements, en le disant dans le journal à chaque
  ouverture. Le shim rend donc `sizeof(rdpClientContext)` et non plus
  `sizeof(rdpContext)` ; le pointeur de retour vers le transport est rangé
  après.
- SHA-256 des DLL versionnées (même régime que libssh2 ci-dessus) :
  - `freerdp3.dll` : `3d317725e7421c39cb6f07a2e8fc2a57342cd535776b489479fc9650aa54e232`
  - `freerdp-client3.dll` : `073f94f051cc5636ba256a15da7c07ece2827355d98fc0e6cf045401b9de5d70`
  - `winpr3.dll` : `5c1e7cbafe43ae76d8497d02a9f05f0c03dfcd56f7933b8ab1635c146b28cd68`
  - `cjson.dll` : `f0935a9585349819ea2b866bb7aa06d7ddee983df9b42c84098e0729d662d8ea`
  - `libssl-3-x64.dll` : `b1d2790b5d51dcf16a9905b3d604705ab774f662e0769abae45163a0800c0170`
  - `legacy.dll` : `40e3dbcb0d23a853fab27b2d539970b7a52f5ad894ce97f63c0c5ca47b6715da`
  - `rssh_rdp_shim.dll` : `3420fa6f145e349e34c2fb7d60646f85f1b48ee0872a016c423b8b0b6894399a`
- Note portage : `WaitForMultipleObjects` est résolu depuis `kernel32.dll` sous
  Windows (API native), pas depuis winpr3 qui, contrairement à l'émulation
  WinPR d'Unix, ne la réexporte pas.

### FIDO2 : fido2.dll (+ cbor.dll)

Cles de securite materielles (`sk-ssh-ed25519@openssh.com`,
`sk-ecdsa-sha2-nistp256@openssh.com`). Chargee **a la demande** et jamais au
demarrage : sans elle l'application fonctionne, seuls les identifiants FIDO2
sont indisponibles, avec un message qui dit quoi installer.

- Construites via **vcpkg** (2026-09-02) : `libfido2:x64-windows@1.17.0`,
  baseline `c1d80d9cb071c3f4a98c67c1196b137cc5b72918`, la MEME que FreeRDP.
- SHA-256 des DLL versionnées :
  - `fido2.dll` : `cb96b101e7376418435ee95ec7b1943ce44be37b100595e84c7ea40e9bd21822`
  - `cbor.dll` : `481c6a2c96ef21c167455d9a9e6c6ecc8bc7c74298bcf7c43deb8837452d8301`
- `cbor.dll` = libcbor 0.14.0 (MIT ; la baseline la donnait déjà, ce
  document disait 0.11 à tort), la seule dépendance qui s'ajoute : fido2.dll
  se lie pour le reste à `libcrypto-3-x64.dll` et `z.dll` **déjà livrées**, dont
  les empreintes issues de ce build sont identiques bit pour bit à celles
  consignées plus haut. C'est tout l'intérêt de la baseline commune.

**Pourquoi pas les binaires officiels de Yubico.** L'archive
`libfido2-1.17.0-win.zip` publiée par Yubico est parfaitement redistribuable
(BSD-2), mais elle apporte QUATRE DLL : elle embarque son propre OpenSSL
(`crypto-56.dll`, dont les métadonnées ne portent même pas de numéro de
version) et son propre zlib (`zlib1.dll`). On se retrouverait avec deux OpenSSL
et deux zlib dans le même processus, donc deux surfaces à suivre a chaque CVE,
dont une opaque. Le build vcpkg en demande deux, et réutilise les nôtres.

- Dépend aussi de `VCRUNTIME140.dll`, déjà livrée (voir sa section).
- Sous Windows, l'accès HID direct exige les droits administrateur depuis la
  1903 : l'application n'utilise donc que le périphérique virtuel
  `windows://hello`, servi par l'API WebAuthn du système, qui présente
  elle-même la demande de geste et de PIN.

### vcruntime140.dll : runtime C de MSVC (déploiement *app-local*)

Douze des quatorze DLL livrées (toutes sauf `sqlite3.dll` et
`rssh_rdp_shim.dll`) importent `VCRUNTIME140.dll`. Elle **ne fait pas partie de
Windows** : sans elle, l'application ne démarre pas sur une machine où Visual
Studio n'a jamais été installé. Elle est donc livrée à côté de l'exécutable,
comme les autres.

- Source : `VC\Redist\MSVC\14.50.35710\x64\Microsoft.VC145.CRT\vcruntime140.dll`
  d'une installation Visual Studio (fichier de la liste *Distributable Code*,
  déploiement app-local prévu par Microsoft).
- Version : 14.50.35719.0, 123 472 octets.
- SHA-256 de `vcruntime140.dll` : `184146852727a9db4eea06178716bec3cdbb1015c911f6b0f915b184ad7775b2`
- Version **14.50** alors que les DLL sont bâties avec le toolset v143 : c'est
  le sens de compatibilité supporté (le CRT est binairement compatible depuis
  2015, un binaire v143 tourne sur un runtime plus récent), et c'est celui qui
  porte les correctifs de sécurité.
- Ne dépend que de l'UCRT système et de `kernel32` : la chaîne s'arrête là,
  rien d'autre à livrer.

**Ce que le reste de l'UCRT ne demande PAS.** Les `api-ms-win-crt-*.dll` qui
apparaissent dans les imports sont l'UCRT, **composant de Windows depuis la
10** (dans `System32`, via apiset) : rien à redistribuer. C'est ce qui permet
à `bindings/libvnc` d'importer `ucrtbase.dll` en dur. Aucune DLL livrée ne
demande `MSVCP140.dll` ni `VCRUNTIME140_1.dll` : pas de runtime C++ dans le
lot. Vérifiable par `dumpbin /dependents` sur les DLL de la racine.

**Rançon du app-local :** cette copie n'est plus mise à jour par Windows
Update. Une faille du CRT vit dans le paquet jusqu'à la release suivante ;
à reprovisionner comme les autres DLL, pas à oublier parce qu'elle est petite.

**Ne PAS « supprimer la dépendance » en passant les builds vcpkg en CRT
statique (`/MT`).** Chaque DLL aurait son propre tas, alors que
`bindings/libvnc` appelle `c_malloc`/`_msize` sur `ucrtbase.dll` en supposant
un tas partagé : `_msize` sur un pointeur venu d'un autre tas est un
comportement indéfini, et c'est précisément le contrôle de disposition mémoire
de `vncclient` qui se casserait.

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
`c1d80d9cb071c3f4a98c67c1196b137cc5b72918` (FreeRDP 3.32.2 + OpenSSL/zlib/
cjson, via overlay port : voir la section FreeRDP), ou, pour libvnc, sur la
source épinglée + patchs. Scripts de provisioning Windows versionnés à
ajouter (pendants de `build-libvnc.sh`). **Piège** : builder
libvnc/vcpkg depuis un chemin court (`D:\tmp\...`) : la limite Windows de
260 caractères casse sinon la génération CMake.

Contraintes : versions épinglées + hash avant usage,
architecture x64 vérifiée, `SetDefaultDllDirectories`/chemins absolus, DLL
transitives incluses, signature Authenticode du paquet final recommandée.
