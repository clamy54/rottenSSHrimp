#!/usr/bin/env bash
# Construit un paquet Debian/Ubuntu (.deb) de RottenSSHrimp.
# Prerequis : scripts/build.sh --release, plus dpkg-deb et cmake (libvncclient).
# Usage : ./build-deb.sh [version]
#
# Layout : le binaire N'EST PAS dans /usr/bin. Les chargeurs cherchent lib/ A
# COTE de l'executable (ExtractFilePath(ParamStr(0)) + 'lib/'), donc un
# /usr/bin/rottensshrimp nu irait chercher /usr/bin/lib/. Tout vit dans
# /usr/lib/rottensshrimp/ et /usr/bin/rottensshrimp est un WRAPPER qui fait exec
# sur le vrai binaire -- exec remplace argv[0] par le chemin reel. Un symlink ne
# suffirait PAS : argv[0] resterait /usr/bin/rottensshrimp.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

ver="${1:-$(sed -n "s/.*RSSH_VERSION *= *'\([^']*\)'.*/\1/p" "$root/src/util/uVersion.pas" | head -1)}"
[ -n "$ver" ] || { echo "RSSH_VERSION introuvable dans src/util/uVersion.pas" >&2; exit 1; }
arch="$(dpkg --print-architecture)"
bin="$root/rottensshrimp"

[ -x "$bin" ] || {
	echo "Executable absent : compile d'abord avec scripts/build.sh --release" >&2
	exit 1
}

# libvncclient vendorisee : comparer une EMPREINTE, pas la seule presence du
# fichier, sinon on rediffuse une lib vulnerable apres correction d'un patch.
vdir="$root/third_party/libvnc"
want_stamp="$(cat "$vdir/SHA256SUMS" "$root/scripts/build-libvnc.sh" \
	"$vdir"/patches/*.patch 2>/dev/null | sha256sum | awk '{print $1}')"
have_stamp="$(cat "$vdir/out/.build-stamp" 2>/dev/null || true)"
if [ ! -f "$vdir/out/lib/libvncclient.so.1" ] || [ "$want_stamp" != "$have_stamp" ]; then
	echo "==> libvncclient vendorisee absente ou patches modifies : (re)construction"
	"$root/scripts/build-libvnc.sh"
fi

# La table d'offsets du binding doit decrire la lib qu'on vient de batir. Sans
# ce controle, le paquet s'installe, se lance, et VNC est desactive au premier
# chargement pour tout le monde -- message visible uniquement en terminal.
"$root/scripts/check-vnc-offsets.sh"

# Shim RDP : un paquet qui l'oublie livre le mode degrade a tout le monde, en
# silence. Ici il est construit contre les en-tetes de la machine de build,
# c'est-a-dire de la cible -- l'avantage du paquet natif sur l'archive.
echo "==> construction du shim RDP"
"$root/scripts/build-rdp-shim.sh" --strict
shim="$root/lib/librssh_rdp_shim.so"
[ -f "$shim" ] || { echo "ECHEC: shim introuvable apres construction." >&2; exit 1; }

pkg="$here/build/rottensshrimp_${ver}_${arch}"
rm -rf "$pkg"
mkdir -p "$pkg/DEBIAN" \
	"$pkg/usr/bin" \
	"$pkg/usr/lib/rottensshrimp/lib" \
	"$pkg/usr/share/applications" \
	"$pkg/usr/share/doc/rottensshrimp"

install -m 0755 "$bin" "$pkg/usr/lib/rottensshrimp/rottensshrimp"
install -m 0644 "$shim" "$pkg/usr/lib/rottensshrimp/lib/"
# le fichier reel ET les liens que le chargeur essaie (.so.1 puis .so)
cp -P "$vdir/out/lib/"libvncclient.so* "$pkg/usr/lib/rottensshrimp/lib/"

cat > "$pkg/usr/bin/rottensshrimp" <<'EOF'
#!/bin/sh
exec /usr/lib/rottensshrimp/rottensshrimp "$@"
EOF
chmod 0755 "$pkg/usr/bin/rottensshrimp"

install -m 0644 "$here/rottensshrimp.desktop" "$pkg/usr/share/applications/rottensshrimp.desktop"

# Licences. On distribue des binaires tiers (libvncclient en tete), leurs textes
# voyagent avec, plus la source correspondante GPL : le tarball epingle
# lui-meme, ses patches et la recette. Une empreinte seule ne reconstruit rien.
install -m 0644 "$root/LICENSE" "$pkg/usr/share/doc/rottensshrimp/copyright"
mkdir -p "$pkg/usr/share/doc/rottensshrimp/LICENSES"
cp -R "$root/LICENSES/." "$pkg/usr/share/doc/rottensshrimp/LICENSES/"

srcdir="$pkg/usr/share/doc/rottensshrimp/source/libvnc"
mkdir -p "$srcdir"
tarball_name="$(awk '{print $2}' "$vdir/SHA256SUMS" | head -1)"
tarball_want="$(awk '{print $1}' "$vdir/SHA256SUMS" | head -1)"
src_tar="$vdir/$tarball_name"
[ -f "$src_tar" ] || src_tar="$vdir/cache/$tarball_name"
[ -f "$src_tar" ] || {
	echo "ECHEC: tarball epingle ($tarball_name) introuvable. Le paquet DOIT" >&2
	echo "embarquer la source correspondante de libvncclient." >&2
	exit 1
}
tarball_got="$(sha256sum "$src_tar" | awk '{print $1}')"
[ "$tarball_got" = "$tarball_want" ] || {
	echo "ECHEC: empreinte du tarball non conforme a SHA256SUMS." >&2
	echo "  attendu: $tarball_want" >&2
	echo "  obtenu : $tarball_got" >&2
	exit 1
}
install -m 0644 "$src_tar" "$srcdir/"
install -m 0644 "$vdir/SHA256SUMS" "$srcdir/"
install -m 0644 "$vdir/README.md" "$srcdir/"
cp -R "$vdir/patches" "$srcdir/patches"
install -m 0644 "$root/scripts/build-libvnc.sh" "$srcdir/"
install -m 0644 "$root/scripts/gen-vnc-offsets.c" "$srcdir/"
find "$srcdir" -type f -exec chmod 0644 {} +

# SBOM : ce que CE paquet embarque. Les deps de la distribution n'y sont pas,
# on ne les distribue pas.
vnc_ver="$(sed -n 's/.*LibVNCServer-\([0-9.]*\)\.tar\.gz.*/\1/p' "$vdir/SHA256SUMS" | head -1)"
"$root/scripts/gen-sbom.sh" \
	"$pkg/usr/share/doc/rottensshrimp/sbom.cdx.json" \
	"RottenSSHrimp" "$ver" "linux-${arch}" \
	"rottensshrimp|$ver|GPL-3.0-or-later|$pkg/usr/lib/rottensshrimp/rottensshrimp|application" \
	"librssh_rdp_shim|$ver|GPL-3.0-or-later|$pkg/usr/lib/rottensshrimp/lib/librssh_rdp_shim.so" \
	"libvncclient (LibVNCServer)|${vnc_ver:-0.9.15}|GPL-2.0-or-later|$pkg/usr/lib/rottensshrimp/lib/libvncclient.so.1"

# Icones dans le theme hicolor. ImageMagick optionnel ; sans lui on pose la
# source telle quelle en 256.
if command -v magick >/dev/null 2>&1; then im="magick"
elif command -v convert >/dev/null 2>&1; then im="convert"
else im=""
fi
src_icon="$root/icons/icon-transparent.png"
[ -f "$src_icon" ] || src_icon="$root/icons/icon.png"
if [ -n "$im" ]; then
	for s in 16 24 32 48 64 128 256; do
		d="$pkg/usr/share/icons/hicolor/${s}x${s}/apps"
		mkdir -p "$d"
		"$im" "$src_icon" -resize "${s}x${s}" -background none -gravity center \
			-extent "${s}x${s}" "$d/rottensshrimp.png"
		chmod 0644 "$d/rottensshrimp.png"
	done
else
	echo "ImageMagick absent : icone posee telle quelle en 256x256" >&2
	d="$pkg/usr/share/icons/hicolor/256x256/apps"
	mkdir -p "$d"
	install -m 0644 "$src_icon" "$d/rottensshrimp.png"
fi

# Depends. Deux moitiers, et la seconde est le piege :
#  - ce qui est LIE au binaire (GTK, X11, libc) : calcule par dpkg-shlibdeps,
#    jamais ecrit a la main, les noms de paquets bougent (la transition time64
#    d'Ubuntu a renomme libgtk2.0-0 en libgtk2.0-0t64, et un Depends sur un
#    paquet inexistant = paquet installable nulle part).
#  - ce qui est ouvert par dlopen (FreeRDP, libssh2, SQLite, libsodium) :
#    INVISIBLE pour shlibdeps, qui ne lit que la table des symboles. Sans cette
#    liste ecrite a la main, le paquet s'installe, se lance, et n'ouvre aucune
#    session -- l'echec le plus couteux a diagnostiquer.
deps=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
	sd="$here/build/shlibdeps"
	rm -rf "$sd"; mkdir -p "$sd/debian"
	: > "$sd/debian/control"   # shlibdeps exige un debian/control, meme vide
	if (cd "$sd" && dpkg-shlibdeps -O --ignore-missing-info \
		"$pkg/usr/lib/rottensshrimp/rottensshrimp" 2>/dev/null) > "$sd/out"; then
		deps="$(sed -n 's/^shlibs:Depends=//p' "$sd/out")"
	fi
	rm -rf "$sd"
fi
[ -n "$deps" ] || {
	echo "dpkg-shlibdeps indisponible : Depends de repli (a verifier)" >&2
	deps="libc6, libgtk2.0-0t64 | libgtk2.0-0, libx11-6"
}
# FreeRDP compte pour TROIS paquets, pas un. libfreerdp3.so.3,
# libfreerdp-client3.so.3 et libwinpr3.so.3 sont empaquetes separement et
# libfreerdp3-3 ne tire QUE libwinpr3-3: sans la ligne ci-dessous, une machine
# neuve n'a pas libfreerdp-client3-3, le chargeur exige les trois fichiers et
# RDP tombe sur « FreeRDP not found in the expected locations ». Constate sur
# Linux Mint 22.3. libwinpr3-3 est declare aussi: on l'ouvre nous-memes par
# dlopen, s'en remettre au Depends d'un autre paquet est un pari, pas une regle.
dlopen_deps="libfreerdp3-3, libfreerdp-client3-3, libwinpr3-3"
dlopen_deps="${dlopen_deps}, libssh2-1t64 | libssh2-1, libsqlite3-0, libsodium23"
deps="${deps}, ${dlopen_deps}"

# Substitution bash, PAS sed : les Depends contiennent des alternatives Debian
# (« libssh2-1t64 | libssh2-1 »), et le premier | de la valeur fermait
# l'expression s|@DEPENDS@|...| -- « unknown option to `s' ». Ici le
# remplacement est litteral, aucun caractere n'a de sens special.
control="$(cat "$here/control.in")"
control="${control//@VERSION@/$ver}"
control="${control//@ARCH@/$arch}"
control="${control//@DEPENDS@/$deps}"
printf '%s\n' "$control" > "$pkg/DEBIAN/control"

dpkg-deb --build --root-owner-group "$pkg"
echo "OK -> ${pkg}.deb"
echo "Depends: $deps"
