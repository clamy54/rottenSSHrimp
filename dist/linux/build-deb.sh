#!/usr/bin/env bash
# .deb Debian/Ubuntu. Prerequis: scripts/build.sh --release, dpkg-deb, cmake.
# Usage: ./build-deb.sh [version]
#
# Les chargeurs cherchent lib/ A COTE de argv[0]: tout vit dans
# /usr/lib/rottensshrimp/, /usr/bin n'a qu'un WRAPPER exec. Un symlink
# laisserait argv[0] dans /usr/bin, et lib/ irait se chercher en /usr/bin/lib/.
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

# EMPREINTE, pas presence: sinon un patch corrige et on rediffuse l'ancienne lib.
vdir="$root/third_party/libvnc"
want_stamp="$(cat "$vdir/SHA256SUMS" "$root/scripts/build-libvnc.sh" \
	"$vdir"/patches/*.patch 2>/dev/null | sha256sum | awk '{print $1}')"
have_stamp="$(cat "$vdir/out/.build-stamp" 2>/dev/null || true)"
if [ ! -f "$vdir/out/lib/libvncclient.so.1" ] || [ "$want_stamp" != "$have_stamp" ]; then
	echo "==> libvncclient vendorisee absente ou patches modifies : (re)construction"
	"$root/scripts/build-libvnc.sh"
fi

# Offsets du binding contre la lib batie. Sans ca, VNC meurt chez tout le
# monde et ne le dit qu'au terminal.
"$root/scripts/check-vnc-offsets.sh"

# Shim RDP oublie = mode degrade pour tous, en silence. Bati contre les
# en-tetes de la cible: l'avantage du paquet natif.
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
	"$pkg/usr/share/mime/packages" \
	"$pkg/usr/share/doc/rottensshrimp"

install -m 0755 "$bin" "$pkg/usr/lib/rottensshrimp/rottensshrimp"
install -m 0644 "$shim" "$pkg/usr/lib/rottensshrimp/lib/"
# fichier reel ET liens essayes par le chargeur (.so.1 puis .so)
cp -P "$vdir/out/lib/"libvncclient.so* "$pkg/usr/lib/rottensshrimp/lib/"

cat > "$pkg/usr/bin/rottensshrimp" <<'EOF'
#!/bin/sh
exec /usr/lib/rottensshrimp/rottensshrimp "$@"
EOF
chmod 0755 "$pkg/usr/bin/rottensshrimp"

install -m 0644 "$here/rottensshrimp.desktop" "$pkg/usr/share/applications/rottensshrimp.desktop"
# sans cette definition, le MimeType du .desktop n'existe pour personne
install -m 0644 "$here/rottensshrimp-mime.xml" \
	"$pkg/usr/share/mime/packages/rottensshrimp.xml"

# MIME, desktop, icones: des CACHES a reconstruire. Outils optionnels (conteneur
# minimal), et un cache perime ne vaut pas une install ratee.
cat > "$pkg/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
	if command -v update-mime-database >/dev/null 2>&1; then
		update-mime-database /usr/share/mime >/dev/null 2>&1 || true
	fi
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		gtk-update-icon-cache -q -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
	fi
fi
exit 0
EOF
chmod 0755 "$pkg/DEBIAN/postinst"

# sinon le bureau propose encore d'ouvrir avec un binaire disparu
cat > "$pkg/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
	if command -v update-mime-database >/dev/null 2>&1; then
		update-mime-database /usr/share/mime >/dev/null 2>&1 || true
	fi
	if command -v update-desktop-database >/dev/null 2>&1; then
		update-desktop-database -q /usr/share/applications >/dev/null 2>&1 || true
	fi
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then
		gtk-update-icon-cache -q -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
	fi
fi
exit 0
EOF
chmod 0755 "$pkg/DEBIAN/postrm"

# Binaires tiers distribues: licences + source GPL correspondante (tarball,
# patches, recette). Une empreinte seule ne reconstruit rien.
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

# SBOM: ce que CE paquet embarque, pas les deps de la distribution.
vnc_ver="$(sed -n 's/.*LibVNCServer-\([0-9.]*\)\.tar\.gz.*/\1/p' "$vdir/SHA256SUMS" | head -1)"
"$root/scripts/gen-sbom.sh" \
	"$pkg/usr/share/doc/rottensshrimp/sbom.cdx.json" \
	"RottenSSHrimp" "$ver" "linux-${arch}" \
	"rottensshrimp|$ver|GPL-3.0-or-later|$pkg/usr/lib/rottensshrimp/rottensshrimp|application" \
	"librssh_rdp_shim|$ver|GPL-3.0-or-later|$pkg/usr/lib/rottensshrimp/lib/librssh_rdp_shim.so" \
	"libvncclient (LibVNCServer)|${vnc_ver:-0.9.15}|GPL-2.0-or-later|$pkg/usr/lib/rottensshrimp/lib/libvncclient.so.1"

# ImageMagick optionnel; sans lui, la source telle quelle en 256.
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

# Depends: le LIE vient de dpkg-shlibdeps (les noms bougent, cf. time64).
# Le dlopen est INVISIBLE pour lui: liste a la main, sinon le paquet
# s'installe, se lance, et n'ouvre aucune session.
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
# FreeRDP = TROIS paquets; libfreerdp3-3 ne tire pas le client. winpr declare
# aussi: on le dlopen nous-memes, compter sur un Depends tiers est un pari.
dlopen_deps="libfreerdp3-3, libfreerdp-client3-3, libwinpr3-3"
dlopen_deps="${dlopen_deps}, libssh2-1t64 | libssh2-1, libsqlite3-0, libsodium23"
deps="${deps}, ${dlopen_deps}"
# Recommends: sans libfido2, seul FIDO2 manque.
recommends="libfido2-1"

# Substitution bash, PAS sed: le | des alternatives Debian ferme s|...|...|.
control="$(cat "$here/control.in")"
control="${control//@VERSION@/$ver}"
control="${control//@ARCH@/$arch}"
control="${control//@DEPENDS@/$deps}"
control="${control//@RECOMMENDS@/$recommends}"
printf '%s\n' "$control" > "$pkg/DEBIAN/control"

dpkg-deb --build --root-owner-group "$pkg"
echo "OK -> ${pkg}.deb"
echo "Depends: $deps"
