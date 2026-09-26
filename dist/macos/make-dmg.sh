#!/usr/bin/env bash
# Empaquette le bundle de scripts/make-app.sh --release (le vrai pipeline macOS).
# Usage: ./make-dmg.sh [version]
#   RSSH_SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" pour signer.
#
# Notarisation: Developer ID obligatoire (l'ad-hoc ne suffit pas), puis
#   xcrun notarytool submit RottenSSHrimp-<ver>.dmg --keychain-profile <profil> --wait
#   xcrun stapler staple RottenSSHrimp-<ver>.dmg
# Profil via notarytool store-credentials, JAMAIS de secrets en clair. Sans
# notarisation, Gatekeeper bloque le premier lancement: normal en ad-hoc.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

ver="${1:-$(sed -n "s/.*RSSH_VERSION *= *'\([^']*\)'.*/\1/p" "$root/src/util/uVersion.pas" | head -1)}"
[ -n "$ver" ] || { echo "RSSH_VERSION introuvable dans src/util/uVersion.pas" >&2; exit 1; }

app="$root/RottenSSHrimp.app"
[ -d "$app" ] || {
	echo "Bundle absent : construis d'abord avec scripts/make-app.sh --release" >&2
	exit 1
}

vol="RottenSSHrimp"
stage="$here/build/dmg"
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"

# libs tierces embarquees = DISTRIBUEES: leurs licences voyagent avec
mkdir -p "$stage/Licenses"
cp "$root/LICENSE" "$stage/Licenses/LICENSE.txt"
cp -R "$root/LICENSES/." "$stage/Licenses/"

# Source GPL de libvncclient (patchee). Tarball verifie: expedier un tarball
# corrompu serait pire que de l'omettre.
vdir="$root/third_party/libvnc"
srcdir="$stage/Licenses/source/libvnc"
mkdir -p "$srcdir"
tarball_name="$(awk '{print $2}' "$vdir/SHA256SUMS" | head -1)"
tarball_want="$(awk '{print $1}' "$vdir/SHA256SUMS" | head -1)"
src_tar="$vdir/$tarball_name"
[ -f "$src_tar" ] || src_tar="$vdir/cache/$tarball_name"
[ -f "$src_tar" ] || {
	echo "ECHEC: tarball epingle ($tarball_name) introuvable." >&2
	exit 1
}
tarball_got="$(shasum -a 256 "$src_tar" | awk '{print $1}')"
[ "$tarball_got" = "$tarball_want" ] || {
	echo "ECHEC: empreinte du tarball non conforme a SHA256SUMS." >&2
	exit 1
}
cp "$src_tar" "$vdir/SHA256SUMS" "$vdir/README.md" "$srcdir/"
cp -R "$vdir/patches" "$srcdir/patches"
cp "$root/scripts/build-libvnc.sh" "$root/scripts/gen-vnc-offsets.c" "$srcdir/"

# UDRW d'abord: la mise en page vit dans le .DS_Store, il faut y ECRIRE.
rw="$here/build/rw.dmg"
rm -f "$rw"
mb=$(( $(du -sm "$stage" | cut -f1) + 60 ))
# « Resource busy »: diskimages-helper traine sur le fichier, surtout en CI.
created=0
for attempt in 1 2 3 4 5; do
	if hdiutil create -volname "$vol" -srcfolder "$stage" -ov -format UDRW \
		-size "${mb}m" "$rw" >/dev/null; then
		created=1
		break
	fi
	echo "hdiutil create: echec (tentative $attempt/5), nouvel essai dans 5 s" >&2
	rm -f "$rw"
	sleep 5
done
[ "$created" -eq 1 ] || { echo "hdiutil create: abandon" >&2; exit 1; }

att="$(hdiutil attach -readwrite -noverify -noautoopen "$rw")"
dev="$(printf '%s\n' "$att" | grep '^/dev/' | head -1 | awk '{print $1}')"
mnt="$(printf '%s\n' "$att" | grep -o '/Volumes/.*$' | head -1)"
[ -n "$dev" ] && [ -d "$mnt" ] || { echo "montage du dmg rate" >&2; exit 1; }
trap 'hdiutil detach "$dev" -force >/dev/null 2>&1 || true' EXIT

# BEST EFFORT: piloter le Finder exige une autorisation TCC qui peut manquer.
# Attente bornee; au pire, des icones mal rangees plutot qu'un build bloque.
layout() {
	osascript <<-APPLESCRIPT
	tell application "Finder"
		tell disk "$vol"
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {200, 120, 840, 520}
			set opts to the icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 13
			set position of item "RottenSSHrimp.app" of container window to {160, 175}
			set position of item "Applications" of container window to {480, 175}
			set position of item "Licenses" of container window to {320, 320}
			update without registering applications
			close
		end tell
	end tell
	APPLESCRIPT
}
layout >/dev/null 2>&1 &
lp=$!
for _ in $(seq 1 30); do
	kill -0 "$lp" 2>/dev/null || break
	sleep 1
done
if kill -0 "$lp" 2>/dev/null; then
	kill -9 "$lp" 2>/dev/null || true
	echo "ATTENTION: mise en page Finder abandonnee (autorisation d'automatisation ?)" >&2
elif wait "$lp"; then
	echo "mise en page OK"
else
	echo "ATTENTION: mise en page Finder echouee, dmg non stylise" >&2
fi

sync
rm -rf "$mnt/.fseventsd" "$mnt/.Trashes" 2>/dev/null || true
hdiutil detach "$dev" >/dev/null
trap - EXIT

dmg="$here/build/RottenSSHrimp-${ver}.dmg"
rm -f "$dmg"
# meme humeur a la conversion, juste apres le detach
converted=0
for attempt in 1 2 3 4 5; do
	if hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov \
		-o "$dmg" >/dev/null; then
		converted=1
		break
	fi
	echo "hdiutil convert: echec (tentative $attempt/5), nouvel essai dans 5 s" >&2
	rm -f "$dmg"
	sleep 5
done
[ "$converted" -eq 1 ] || { echo "hdiutil convert: abandon" >&2; exit 1; }
rm -f "$rw"
rm -rf "$stage"

# le conteneur aussi: Gatekeeper le verifie avant l'app
identity="${RSSH_SIGN_IDENTITY:-}"
if [ -n "$identity" ]; then
	codesign --force --timestamp --sign "$identity" "$dmg"
	echo "DMG signe ($identity) -- reste a notariser, voir l'en-tete de ce script"
else
	echo "DMG NON signe (pas de RSSH_SIGN_IDENTITY)"
fi

echo "OK -> $dmg  ($(du -h "$dmg" | cut -f1))"
