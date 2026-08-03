#!/usr/bin/env bash
# Distribution Linux autonome et RELOGEABLE. Pendant Linux de make-app.sh.
#
# Deux bibliotheques VOYAGENT avec le binaire, le chargeur refusant celles du
# systeme: libvncclient (celle des distributions est une 0.9.15 non corrigee des
# CVE-2026-50538 et -44988, ecriture hors tas PRE-AUTH, et batie avec TLS/SASL
# donc d'une autre disposition de rfbClient) et librssh_rdp_shim. Le reste
# (FreeRDP, libssh2, SQLite, libsodium) vient de la distribution: voir
# packaging/linux/DEPS.md.
#
# Le shim ne decrit QUE la version de FreeRDP contre laquelle il fut compile:
# majeure differente, le binding l'ecarte et retombe sur les offsets. Un paquet.
# deb/.rpm/AUR, bati contre sa propre cible, n'a pas cette limite -- c'est la
# forme recommandee; cette archive vise les distributions sans paquet.
#
# Usage: scripts/make-linux-dist.sh [--release]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

[ "$(uname -s)" = "Linux" ] || { echo "Ce script cible Linux." >&2; exit 1; }

arch="$(uname -m)"
version="$(sed -n "s/.*RSSH_VERSION *= *'\([^']*\)'.*/\1/p" src/util/uVersion.pas | head -1)"
[ -n "$version" ] || version="0.0.0"
name="rottensshrimp-${version}-linux-${arch}"
out="$root/dist/linux/build/$name"

# 1) libvncclient: comparer une EMPREINTE et non la seule presence du fichier,
#    sinon on rediffuse une lib vulnerable apres correction d'un patch.
vdir="$root/third_party/libvnc"
want_stamp="$(cat "$vdir/SHA256SUMS" "$root/scripts/build-libvnc.sh" \
  "$vdir"/patches/*.patch 2>/dev/null | sha256sum | awk '{print $1}')"
have_stamp="$(cat "$vdir/out/.build-stamp" 2>/dev/null || true)"
if [ ! -f "$vdir/out/lib/libvncclient.so.1" ] || [ "$want_stamp" != "$have_stamp" ]; then
  echo "==> libvncclient vendorisee absente ou patches modifies: (re)construction"
  "$root/scripts/build-libvnc.sh"
fi

# 2) binaire
"$root/scripts/build.sh" "$@"

# 3) shim OBLIGATOIRE ici: une distribution qui l'oublie livre le mode degrade
#    a tout le monde, en silence.
echo "==> construction du shim RDP (obligatoire dans la distribution)"
"$root/scripts/build-rdp-shim.sh" --strict
shim="$root/lib/librssh_rdp_shim.so"
[ -f "$shim" ] || { echo "ECHEC: shim introuvable apres construction." >&2; exit 1; }

# 4) arborescence propre
rm -rf "$out"
mkdir -p "$out/lib" "$out/LICENSES"

cp "$root/rottensshrimp" "$out/rottensshrimp"
chmod +x "$out/rottensshrimp"
cp "$shim" "$out/lib/"

# le fichier reel ET les liens que le chargeur essaie (.so.1 puis .so)
cp -P "$vdir/out/lib/"libvncclient.so* "$out/lib/"

# 5) embarquer une bibliotheque, c'est la DISTRIBUER: sa licence la suit
[ -d "$root/LICENSES" ] && cp -R "$root/LICENSES/." "$out/LICENSES/"

# 6) Source correspondante GPL: le TARBALL lui-meme + patches + recette. Une
#    empreinte seule ne reconstruit rien si l'amont disparait. Verifiee avant
#    embarquement: expedier un tarball corrompu serait pire que l'omettre.
srcdir="$out/source/libvnc"
mkdir -p "$srcdir"
tarball_name="$(awk '{print $2}' "$vdir/SHA256SUMS" | head -1)"
tarball_want="$(awk '{print $1}' "$vdir/SHA256SUMS" | head -1)"
src_tar="$vdir/$tarball_name"
[ -f "$src_tar" ] || src_tar="$vdir/cache/$tarball_name"
if [ ! -f "$src_tar" ]; then
  echo "ECHEC: tarball epingle ($tarball_name) introuvable (ni archive dans" >&2
  echo "third_party/libvnc/, ni en cache). La distribution DOIT embarquer la" >&2
  echo "source correspondante de libvncclient." >&2
  exit 1
fi
tarball_got="$(sha256sum "$src_tar" | awk '{print $1}')"
if [ "$tarball_got" != "$tarball_want" ]; then
  echo "ECHEC: empreinte du tarball non conforme a SHA256SUMS." >&2
  echo "  attendu: $tarball_want" >&2
  echo "  obtenu : $tarball_got" >&2
  exit 1
fi
cp "$src_tar" "$srcdir/"
cp "$vdir/SHA256SUMS" "$srcdir/"
[ -f "$vdir/README.md" ] && cp "$vdir/README.md" "$srcdir/"
cp -R "$vdir/patches" "$srcdir/patches"
cp "$root/scripts/build-libvnc.sh" "$srcdir/"

# 7) Exec reste un NOM: le chemin depend d'ou l'archive atterrit, install.sh
#    le reecrit.
cp "$root/icons/icon.png" "$out/rottensshrimp.png" 2>/dev/null || true
cat > "$out/rottensshrimp.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=RottenSSHrimp
Comment=SSH, RDP and VNC connection manager
Exec=rottensshrimp
Icon=rottensshrimp
Terminal=false
Categories=Network;RemoteAccess;
DESKTOP

cat > "$out/install.sh" <<'INSTALL'
#!/usr/bin/env bash
# Installe pour l'utilisateur courant, sans droits admin. L'application reste ou
# vous avez depose cette archive: on n'y pose que des liens.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bindir="$HOME/.local/bin"
appdir="$HOME/.local/share/applications"
icondir="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$bindir" "$appdir" "$icondir"
ln -sf "$here/rottensshrimp" "$bindir/rottensshrimp"
[ -f "$here/rottensshrimp.png" ] && cp "$here/rottensshrimp.png" "$icondir/rottensshrimp.png"
sed "s|^Exec=.*|Exec=$here/rottensshrimp|" "$here/rottensshrimp.desktop" \
  > "$appdir/rottensshrimp.desktop"
echo "Installe. Si $bindir n'est pas dans votre PATH, ajoutez-le."
INSTALL
chmod +x "$out/install.sh"

cat > "$out/README.txt" <<README
RottenSSHrimp ${version} (Linux ${arch})

Lancement direct:   ./rottensshrimp
Integration bureau: ./install.sh   (utilisateur courant, sans sudo)

Ce que contient lib/
  librssh_rdp_shim.so  resout la disposition memoire de FreeRDP. Compile ici
                       contre FreeRDP $(pkg-config --modversion freerdp3 2>/dev/null || echo 'version inconnue').
                       Si votre FreeRDP est d'une autre MAJEURE, il est ecarte
                       et RDP fonctionne quand meme, par un chemin de repli.
  libvncclient.so.*    construite depuis une source epinglee et CORRIGEE de
                       CVE-2026-50538 et CVE-2026-44988, absentes du paquet des
                       distributions. VNC ne se rabat jamais sur la version
                       systeme: cette copie est indispensable.

A installer par votre distribution (voir packaging/linux/DEPS.md):
  FreeRDP 3, libssh2, SQLite 3, libsodium.

Licences: LICENSES/. La source correspondante de libvncclient (le tarball
archive, son empreinte, les patches et le script de construction) est dans
source/libvnc/, comme l'exige la GPL pour un binaire redistribue.
Inventaire des composants: sbom.cdx.json (CycloneDX).
README

# 8) SBOM: ce que CETTE archive embarque. Les deps systeme n'y sont
#    pas -- on ne les distribue pas.
vnc_ver="$(sed -n 's/.*LibVNCServer-\([0-9.]*\)\.tar\.gz.*/\1/p' "$vdir/SHA256SUMS" | head -1)"
"$root/scripts/gen-sbom.sh" "$out/sbom.cdx.json" "RottenSSHrimp" "$version" \
  "linux-${arch}" \
  "rottensshrimp|$version|GPL-3.0-or-later|$out/rottensshrimp" \
  "librssh_rdp_shim|$version|GPL-3.0-or-later|$out/lib/librssh_rdp_shim.so" \
  "libvncclient (LibVNCServer)|${vnc_ver:-0.9.15}|GPL-2.0-or-later|$out/lib/libvncclient.so.1"

# 9) archive
tar -C "$root/dist/linux/build" -czf "$root/dist/linux/build/${name}.tar.gz" "$name"

echo
echo "OK -> dist/linux/build/${name}/"
echo "OK -> dist/linux/build/${name}.tar.gz"
du -sh "$out" | awk '{print "    taille: "$1}'
