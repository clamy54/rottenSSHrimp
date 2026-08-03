# Dépendances natives Linux

Contrairement à Windows, où les DLL sont versionnées dans le dépôt et
chargées **à côté de l'exécutable**, Linux prend la plupart de ses
bibliothèques dans la distribution. Deux exceptions, et elles sont
délibérées : elles voyagent avec l'application parce que le programme refuse
d'utiliser celles du système.

Les chargeurs (`bindings/*`) n'acceptent que des **chemins absolus** construits
sur `ParamStr(0)`, jamais le `PATH` ni le répertoire courant.

## Ce qui vient de la distribution

| Bibliothèque | Chargée sous le nom | Debian/Ubuntu | Fedora/RHEL | Arch | openSUSE |
|---|---|---|---|---|---|
| FreeRDP 3 | `libfreerdp3.so.3`, `libfreerdp-client3.so.3`, `libwinpr3.so.3` | `libfreerdp3-3` | `freerdp-libs` | `freerdp` | `libfreerdp3` |
| libssh2 | `libssh2.so.1` | `libssh2-1t64` | `libssh2` | `libssh2` | `libssh2-1` |
| SQLite 3 | `libsqlite3.so.0` | `libsqlite3-0` | `sqlite-libs` | `sqlite` | `libsqlite3-0` |
| libsodium | `libsodium.so.26` ou `.so.23` | `libsodium23` | `libsodium` | `libsodium` | `libsodium23` |

La **majeure** de FreeRDP est vérifiée au chargement : une autre majeure est
refusée plutôt qu'utilisée, car l'ABI et la disposition des structures y
changent.

## Ce qui est livré avec l'application (`lib/`)

### `libvncclient.so.1` : obligatoire

Le paquet des distributions est une 0.9.15 **non corrigée** de
CVE-2026-50538 et CVE-2026-44988 (décodeur Tight, écriture hors tas
**pré-authentification** : le serveur écrit hors du tas avant même que vous
ayez tapé un mot de passe), et compilée avec TLS/SASL, donc d'une disposition
de `rfbClient` différente de celle d'où viennent nos offsets. Les replis
système ont été retirés du chargeur : **sans notre copie, VNC ne fonctionne
pas du tout**. C'est délibéré. Une fonctionnalité en panne se remarque, une
bibliothèque vulnérable non.

Construction : `scripts/build-libvnc.sh` (source épinglée par SHA-256 +
patches amont + configuration figée). Prérequis : `cmake`, en-têtes `zlib` et
`libjpeg`.

> **GPL.** Embarquer cette bibliothèque, c'est la *distribuer* : la source
> correspondante (tarball épinglé, patches, script de construction) doit
> l'accompagner. `scripts/make-linux-dist.sh` la place dans `source/libvnc/`.

### `librssh_rdp_shim.so` : vivement recommandé

Résout la disposition mémoire de FreeRDP par le compilateur C plutôt que par
des offsets écrits à la main et validés par optimisme (voir l'en-tête de
`bindings/freerdp/shim/rssh_rdp_shim.c`). Absent, RDP fonctionne quand même :
il retombe sur les offsets, protégés par des témoins d'exécution et un repli
de rendu. C'est un parachute, pas un escalier : on le prévoit, on ne l'emprunte
pas tous les matins.

Construction : `scripts/build-rdp-shim.sh`, qui nécessite les **en-têtes**
FreeRDP 3 :

| Debian/Ubuntu | Fedora/RHEL | Arch | openSUSE |
|---|---|---|---|
| `freerdp3-dev` `libwinpr3-dev` | `freerdp-devel` | `freerdp` | `freerdp3-devel` |

Le shim ne décrit que la version contre laquelle il a été **compilé** ; le
binding écarte un shim d'une autre majeure. Il doit donc être construit sur la
machine cible, ou par le paquet de la distribution.

## Construire pour distribuer

```sh
scripts/make-linux-dist.sh --release
```

Produit `dist/linux/build/rottensshrimp-<version>-linux-<arch>/` et son archive : binaire,
`lib/` (les deux bibliothèques ci-dessus), `LICENSES/`, la source
correspondante GPL, un `.desktop` et un `install.sh` sans privilèges.

**Un paquet natif reste préférable à l'archive** (`.deb`, `.rpm`, PKGBUILD) :
il construit le shim contre les en-têtes de sa propre cible, donc sans le
risque d'écart de majeure, et laisse le gestionnaire de paquets gérer les
dépendances du tableau ci-dessus.

## Contrôle d'intégrité

`scripts/check-rdp-offsets.sh` confronte les offsets écrits en dur aux vrais
en-têtes installés. La CI l'exécute sur Debian, Ubuntu, Fedora, Arch et
openSUSE, puis y construit le shim en mode strict : une distribution qui
disposerait ses structures autrement se signale là, pas chez l'utilisateur.
