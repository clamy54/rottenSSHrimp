# Arch Linux

`PKGBUILD` pour construire RottenSSHrimp avec `makepkg`. Il produit le même
agencement que le `.deb` : tout dans `/usr/lib/rottensshrimp/`, un wrapper dans
`/usr/bin/`, et l'association `.rsh`.

```sh
cd dist/linux/archlinux
makepkg -si
```

`pkgver` doit suivre `RSSH_VERSION` de `src/util/uVersion.pas`, comme le font
les trois autres empaquetages.

## GTK2, à lire avant de construire

**`gtk2` n'est plus dans les dépôts officiels d'Arch.** Il vit désormais dans
AUR, et `makepkg` seul ne le résoudra pas : il faut un assistant AUR (`paru`,
`yay`) ou l'installer à la main au préalable.

Ce n'est pas un choix d'empaquetage. Le widgetset LCL de l'application est
GTK2, et le code en dépend explicitement : `src/ui/uSearchBox.pas` importe
`gtk2, gdk2, glib2` et manipule directement un `GtkStyle` pour contourner les
thèmes à moteur, et `src/ui/uRdpControl.pas` lit les keycodes natifs sous
`{$IFDEF LCLGtk2}`.

Recompiler avec Qt5 (`lazarus-qt5` et `qt5pas` sont, eux, dans `extra`) est
donc plus qu'un changement de drapeau : ces branches disparaîtraient à la
compilation, sans erreur, et emporteraient avec elles le clavier RDP. C'est un
portage à mener et à tester, pas une variante à déclarer ici.

Arch fournit aussi `gtk2-compat` dans `extra`, qui « simule la présence de
GTK+2 mais tente d'utiliser GTK+3 ». Il entre en conflit avec `gtk2` et ne le
*fournit* pas au sens de pacman, donc il ne satisfait pas la dépendance
déclarée ici. Il n'a pas été essayé avec cette application.

## Dépendances

Vérifiées dans les dépôts officiels au moment d'écrire ces lignes :

| Paquet | Dépôt | Rôle |
|---|---|---|
| `gtk2` | **AUR** | widgetset LCL, voir ci-dessus |
| `libx11` | extra | lié au binaire |
| `freerdp` | extra (3.30.0) | RDP, ouvert par `dlopen` |
| `libssh2` | core | SSH, `dlopen` |
| `sqlite` | core | stockage, `dlopen` |
| `libsodium` | extra | chiffrement, `dlopen` |
| `zlib`, `libjpeg-turbo` | core / extra | libvncclient vendorisée |
| `lazarus` | extra (4.8) | compilation, tire `fpc` et `fpc-src` |
| `cmake`, `pkgconf`, `imagemagick` | extra / core | libvncclient, shim RDP, icônes |

Les quatre dépendances ouvertes par `dlopen` sont invisibles pour l'éditeur de
liens comme pour `namcap` : elles ne figurent dans aucune table de symboles.
Les retirer parce qu'un outil ne les voit pas donne un paquet qui s'installe,
se lance, et n'ouvre aucune session.

Sur Arch, les trois bibliothèques FreeRDP (`libfreerdp3`, `libfreerdp-client3`,
`libwinpr3`) sont dans le même paquet, alors que Debian les sépare et impose
d'en déclarer trois.

## Différences avec le `.deb`

**Aucun script post-installation.** Le `.deb` doit régénérer lui-même les
caches MIME, desktop et icônes ; pacman le fait par ses propres hooks dès qu'un
paquet dépose des fichiers à ces emplacements.

**`sha256sums=('SKIP')`.** Ce `PKGBUILD` est lui-même dans l'archive dont il
devrait donner l'empreinte : y inscrire une somme la changerait, indéfiniment.
Pour une publication sur AUR, où le `PKGBUILD` vit dans un dépôt séparé, le
cycle disparaît — lancer alors `updpkgsums` et remplacer `SKIP`.

## Ce qui n'a pas été vérifié

Le `PKGBUILD` a été relu et sa syntaxe validée, les noms de paquets ont été
confrontés un à un aux dépôts officiels, et le nom du répertoire extrait a été
vérifié sur l'archive publiée. **Il n'a pas été construit** : aucune machine
Arch n'était disponible. Le premier `makepkg` reste à faire.
