#!/usr/bin/env bash
# Fabrique RottenSSHrimp.app (macOS): bundle, dylibs rapatriees, signature.
# Usage: scripts/make-app.sh [--release]
# PIEGE: pas de NSPrincipalClass dans l'Info.plist -- LCL-Cocoa instancie la
# classe app depuis cette cle, et NSApplication brut = app inquittable.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# Empreinte (patches + script + tarball epingle): un simple test « absente »
# laissait rembarquer une dylib vulnerable apres correction d'un patch.
vdir="$root/third_party/libvnc"
want_stamp="$(cat "$vdir/SHA256SUMS" "$root/scripts/build-libvnc.sh" \
  "$vdir"/patches/*.patch 2>/dev/null | shasum -a 256 | awk '{print $1}')"
have_stamp="$(cat "$vdir/out/.build-stamp" 2>/dev/null || true)"
if [ ! -f "$vdir/out/lib/libvncclient.1.dylib" ] || [ "$want_stamp" != "$have_stamp" ]; then
  echo "libvncclient vendorisee absente ou patches modifies -> (re)construction..."
  "$root/scripts/build-libvnc.sh"
fi

"$root/scripts/build.sh" "$@"

app="$root/RottenSSHrimp.app"
macos="$app/Contents/MacOS"
res="$app/Contents/Resources"

rm -rf "$app"
mkdir -p "$macos" "$res"

cp "$root/rottensshrimp" "$macos/rottensshrimp"
chmod +x "$macos/rottensshrimp"

[ -d "$root/themes" ] && cp -R "$root/themes" "$macos/themes"

# Embarquer une bibliotheque, c'est la DISTRIBUER: sa licence voyage avec.
if [ -d "$root/LICENSES" ]; then
  rm -rf "$res/LICENSES"
  cp -R "$root/LICENSES" "$res/LICENSES"
  echo "  licences tierces -> Contents/Resources/LICENSES/"
fi


# Dylibs dans le bundle: fermeture transitive dans
# Contents/Frameworks/, chemins en @loader_path, jamais d'absolu.

fw="$app/Contents/Frameworks"
mkdir -p "$fw"

seeds=(
  "/opt/homebrew/opt/freerdp/lib/libfreerdp3.3.dylib"
  "/opt/homebrew/opt/freerdp/lib/libfreerdp-client3.3.dylib"
  "/opt/homebrew/opt/freerdp/lib/libwinpr3.3.dylib"
  "/opt/homebrew/opt/libssh2/lib/libssh2.1.dylib"
  "/opt/homebrew/opt/libsodium/lib/libsodium.26.dylib"
  # la notre, vendorisee et patchee -- le paquet Homebrew 0.9.15
  # traine CVE-2026-50538 et -44988 (Tight, ecriture hors tas, PRE-AUTH).
  "${root}/third_party/libvnc/out/lib/libvncclient.1.dylib"
)

# Pas de tableau associatif: le bash livre avec macOS est un 3.2.
alias_of() {
  case "$1" in
    libsodium.26.dylib) echo "libsodium.dylib" ;;
    *) echo "" ;;
  esac
}

bundled=""   # noms de base deja traites, separes par des espaces

is_external() {
  case "$1" in
    /opt/homebrew/*|/usr/local/*) return 0 ;;
    *) return 1 ;;
  esac
}

bundle_one() {
  local src="$1" base dep alias_name
  base="$(basename "$src")"
  case " $bundled " in *" $base "*) return 0 ;; esac
  bundled="$bundled $base"

  [ -f "$src" ] || { echo "  MANQUE: $src" >&2; return 1; }
  cp -L "$src" "$fw/$base"
  chmod u+w "$fw/$base"
  install_name_tool -id "@loader_path/$base" "$fw/$base" 2>/dev/null || true

  alias_name="$(alias_of "$base")"
  if [ -n "$alias_name" ]; then
    ln -sf "$base" "$fw/$alias_name"
  fi

  while read -r dep; do
    is_external "$dep" || continue
    bundle_one "$dep"
    install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" \
      "$fw/$base" 2>/dev/null || true
  done < <(otool -L "$fw/$base" | tail -n +2 | awk '{print $1}')
}

echo "embarquement des bibliotheques natives..."
for s in "${seeds[@]}"; do bundle_one "$s"; done

# Shim RDP: OBLIGATOIRE ici, et RECONSTRUIT -- un shim rassis (batti avant un
# brew upgrade) serait ecarte au chargement, retour aux offsets en dur.
echo "construction du shim RDP (obligatoire dans l'app)..."
"$root/scripts/build-rdp-shim.sh" --strict
shim="$root/lib/librssh_rdp_shim.dylib"
if [ ! -f "$shim" ]; then
  echo "ECHEC: shim RDP introuvable apres construction (${shim})." >&2
  exit 1
fi
bundle_one "$shim"

# Une reference hors bundle = une app qui marche ici et nulle part ailleurs.
# `|| true`: sous set -e, un dernier grep bredouille -- le cas nominal -- tuerait.
leaks="$(for f in "$fw"/*.dylib; do
  [ -L "$f" ] && continue
  otool -L "$f" | tail -n +2 | awk '{print $1}' |
    grep -E '^(/opt/homebrew|/usr/local)' | sed "s|^|$(basename "$f"): |"
done || true)"
if [ -n "$leaks" ]; then
  echo "ERREUR: references hors bundle restantes:" >&2
  echo "$leaks" >&2
  exit 1
fi
echo "  $(ls -1 "$fw"/*.dylib | wc -l | tr -d ' ') bibliotheques, aucune reference externe"

# Icone best effort. Artwork detoure: la tuile squircle laissait une marge qui
# rapetissait l'icone dans le Dock.
src_icon="$root/icons/icon-transparent.png"
[ -f "$src_icon" ] || src_icon="$root/icons/icon.png"
icon_ok=0
if command -v sips >/dev/null && command -v iconutil >/dev/null && [ -f "$src_icon" ]; then
  tmpset="$(mktemp -d)/RottenSSHrimp.iconset"
  mkdir -p "$tmpset"
  if for s in 16 32 128 256 512; do
       sips -z "$s" "$s" "$src_icon" --out "$tmpset/icon_${s}x${s}.png" >/dev/null 2>&1 || exit 1
       d=$((s*2))
       sips -z "$d" "$d" "$src_icon" --out "$tmpset/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || exit 1
     done; then
    if iconutil -c icns "$tmpset" -o "$res/RottenSSHrimp.icns" >/dev/null 2>&1; then
      icon_ok=1
    fi
  fi
  rm -rf "$(dirname "$tmpset")"
fi

ver="$(sed -n "s/.*RSSH_VERSION  *= *'\([^']*\)'.*/\1/p" "$root/src/util/uVersion.pas" | head -1)"
[ -n "$ver" ] || ver="0.1"
iconline=""
[ "$icon_ok" = 1 ] && iconline="	<key>CFBundleIconFile</key>
	<string>RottenSSHrimp</string>"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>RottenSSHrimp</string>
	<key>CFBundleDisplayName</key>
	<string>RottenSSHrimp</string>
	<key>CFBundleExecutable</key>
	<string>rottensshrimp</string>
	<key>CFBundleIdentifier</key>
	<string>org.clamy.rottensshrimp</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$ver</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Cyril LAMY - GPL-3.0-or-later</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>RottenSSHrimp Document</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>org.clamy.rottensshrimp.document</string>
			</array>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
		</dict>
	</array>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>org.clamy.rottensshrimp.document</string>
			<key>UTTypeDescription</key>
			<string>RottenSSHrimp Document</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>rsh</string>
				</array>
			</dict>
		</dict>
	</array>
$iconline
</dict>
</plist>
PLIST

plutil -lint "$app/Contents/Info.plist" >/dev/null

# Signature: ad-hoc = local seulement. RSSH_SIGN_IDENTITY
# ajoute hardened runtime + entitlements. Interieur vers exterieur, pas --deep.
identity="${RSSH_SIGN_IDENTITY:--}"
entitlements="$root/packaging/entitlements-macos.plist"

signflags=(--force --timestamp=none)
if [ "$identity" != "-" ]; then
  signflags=(--force --options runtime --timestamp)
  [ -f "$entitlements" ] && signflags+=(--entitlements "$entitlements")
fi

for dylib in "$fw"/*.dylib; do
  [ -L "$dylib" ] && continue           # les alias suivent leur cible
  codesign "${signflags[@]}" --sign "$identity" "$dylib"
done

# Manifeste ecrit AVANT la signature: apres, il casserait le sceau.
manifest="$app/Contents/Resources/build-manifest.txt"
{
  echo "produit: RottenSSHrimp $ver"
  echo "date: $(date -u -r "${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y-%m-%dT%H:%M:%SZ)"
  echo "hote: $(uname -srm)"
  echo "commit: $(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo inconnu)$(git -C "$root" diff --quiet 2>/dev/null || echo '+modifie')"
  echo "compilateur: fpc $(/usr/local/bin/ppca64 -iV 2>/dev/null || echo inconnu)"
  echo "signature: $([ "$identity" = "-" ] && echo "ad-hoc" || echo "$identity")"
  echo
  echo "bibliotheques natives embarquees:"
  for f in "$fw"/*.dylib; do
    [ -L "$f" ] && continue
    echo "  $(basename "$f")  sha256=$(shasum -a 256 "$f" | awk '{print $1}')"
  done
} > "$manifest"
echo "manifeste -> Contents/Resources/build-manifest.txt"

# SBOM CycloneDX: une dylib inconnue de la table reste LISTEE.
fr_ver="$(pkg-config --modversion freerdp3 2>/dev/null || true)"
vnc_ver="$(sed -n 's/.*LibVNCServer-\([0-9.]*\)\.tar\.gz.*/\1/p' \
  "$root/third_party/libvnc/SHA256SUMS" | head -1)"
sbom_desc_of() {  # <basename de dylib> -> "nom|version|licence"
  case "$1" in
    libvncclient*)      echo "libvncclient (LibVNCServer)|${vnc_ver}|GPL-2.0-or-later" ;;
    librssh_rdp_shim*)  echo "librssh_rdp_shim|${ver}|GPL-3.0-or-later" ;;
    libfreerdp-client*) echo "FreeRDP client|${fr_ver}|Apache-2.0" ;;
    libfreerdp*)        echo "FreeRDP|${fr_ver}|Apache-2.0" ;;
    libwinpr*)          echo "WinPR|${fr_ver}|Apache-2.0" ;;
    libssh2*)           echo "libssh2||BSD-3-Clause" ;;
    libsodium*)         echo "libsodium||ISC" ;;
    libcrypto*|libssl*) echo "OpenSSL||Apache-2.0" ;;
    libjpeg*|libturbojpeg*) echo "libjpeg-turbo||BSD-3-Clause AND IJG" ;;
    libz.*)             echo "zlib||Zlib" ;;
    libcjson*)          echo "cJSON||MIT" ;;
    *)                  echo "$1||" ;;
  esac
}
sbom_args=()
for f in "$fw"/*.dylib; do
  [ -L "$f" ] && continue
  sbom_args+=("$(sbom_desc_of "$(basename "$f")")|$f")
done
# ${arr[@]+...}: sous set -u, le bash 3.2 de macOS voit un tableau VIDE comme
# une variable non liee.
"$root/scripts/gen-sbom.sh" "$app/Contents/Resources/sbom.cdx.json" \
  "RottenSSHrimp" "$ver" "macos-$(uname -m)" \
  "RottenSSHrimp|$ver|GPL-3.0-or-later|$macos/rottensshrimp|application" \
  ${sbom_args[@]+"${sbom_args[@]}"}

# La signature du bundle scelle Contents/: DERNIERE modification, sans appel.
codesign "${signflags[@]}" --sign "$identity" "$app"

codesign --verify --deep --strict "$app"
if [ "$identity" = "-" ]; then
  echo "signature OK (ad-hoc: local seulement, ni distribuable ni notarisable)"
else
  echo "signature OK ($identity, hardened runtime)"
  # notarisation: compte Apple + reseau, marche a suivre dans make-dmg.sh
fi

# LaunchServices (best effort): -f = relire l'Info.plist d'un chemin deja connu
lsreg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$lsreg" ] && "$lsreg" -f "$app" 2>/dev/null || true

echo "OK -> $app"
