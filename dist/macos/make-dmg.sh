#!/usr/bin/env bash
# Cree un .dmg de RottenSSHrimp : une fenetre contenant RottenSSHrimp.app et un
# raccourci vers /Applications, cote a cote (glisser-deposer pour installer).
#
# Prerequis : avoir construit le bundle avec scripts/make-app.sh --release.
# C'est LUI le pipeline macOS (build + bundle + dylibs rapatriees + shim + .icns
# + Info.plist + SBOM + signature ad-hoc) ; on ne le duplique pas ici, on
# empaquette son resultat.
#
# Usage : ./make-dmg.sh [version]
#   RSSH_SIGN_IDENTITY="Developer ID Application: Nom (TEAMID)" pour signer.
#
# Notarisation (optionnelle, pour une vraie distribution) : il faut d'abord une
# signature Developer ID -- l'ad-hoc de make-app.sh ne suffit pas -- puis :
#   xcrun notarytool submit RottenSSHrimp-<ver>.dmg --keychain-profile <profil> --wait
#   xcrun stapler staple RottenSSHrimp-<ver>.dmg
# Profil cree par notarytool store-credentials, jamais ces secrets en clair.
# Sans ca, Gatekeeper bloque le premier lancement : ouvrir l'app une fois puis
# l'autoriser dans Reglages Systeme > Confidentialite et securite. C'est normal
# sur de l'ad-hoc.
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

# Les licences voyagent avec le .dmg : le bundle embarque des bibliotheques
# tierces, donc il les DISTRIBUE. Regroupees dans un dossier pour ne pas
# encombrer la fenetre d'installation.
mkdir -p "$stage/Licenses"
cp "$root/LICENSE" "$stage/Licenses/LICENSE.txt"
cp -R "$root/LICENSES/." "$stage/Licenses/"

# Source correspondante GPL de la libvncclient embarquee (GPL-2.0-or-later, et
# nous la modifions : trois patchs de securite). Le tarball epingle LUI-MEME,
# verifie avant embarquement : expedier un tarball corrompu serait pire que de
# l'omettre.
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

# Image lecture/ecriture d'abord : la mise en page (positions des icones, taille
# de la fenetre) vit dans le .DS_Store du volume, donc il faut pouvoir ECRIRE
# dedans. La compression vient apres.
rw="$here/build/rw.dmg"
rm -f "$rw"
mb=$(( $(du -sm "$stage" | cut -f1) + 60 ))
hdiutil create -volname "$vol" -srcfolder "$stage" -ov -format UDRW \
	-size "${mb}m" "$rw" >/dev/null

att="$(hdiutil attach -readwrite -noverify -noautoopen "$rw")"
dev="$(printf '%s\n' "$att" | grep '^/dev/' | head -1 | awk '{print $1}')"
mnt="$(printf '%s\n' "$att" | grep -o '/Volumes/.*$' | head -1)"
[ -n "$dev" ] && [ -d "$mnt" ] || { echo "montage du dmg rate" >&2; exit 1; }
trap 'hdiutil detach "$dev" -force >/dev/null 2>&1 || true' EXIT

# Mise en page via le Finder. BEST EFFORT : le piloter demande une autorisation
# d'automatisation (TCC) qui peut manquer (CI, machine verrouillee) -> on borne
# l'attente et on livre sans layout plutot que de bloquer le build. Le dmg reste
# parfaitement fonctionnel, les icones sont juste mal placees.
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
hdiutil convert "$rw" -format UDZO -imagekey zlib-level=9 -ov -o "$dmg" >/dev/null
rm -f "$rw"
rm -rf "$stage"

# Le DMG lui-meme se signe : Gatekeeper verifie le conteneur avant l'app.
identity="${RSSH_SIGN_IDENTITY:-}"
if [ -n "$identity" ]; then
	codesign --force --timestamp --sign "$identity" "$dmg"
	echo "DMG signe ($identity) -- reste a notariser, voir l'en-tete de ce script"
else
	echo "DMG NON signe (pas de RSSH_SIGN_IDENTITY)"
fi

echo "OK -> $dmg  ($(du -h "$dmg" | cut -f1))"
