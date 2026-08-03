#!/usr/bin/env bash
# Installe Lazarus 4.8 aarch64 sur un runner macOS. Partage par ci.yml et
# release.yml.
#
# Pas setup-lazarus: sur macOS il ne pose que la variante x86_64 (l'app
# sortirait en Intel/Rosetta) et s'arrete a 4.4. On installe la distribution
# aarch64 officielle 4.8, celle qui sert en local.
set -euo pipefail

base="https://sourceforge.net/projects/lazarus/files/Lazarus%20macOS%20aarch64/Lazarus%204.8"

curl -fsSL -o /tmp/fpc.dmg "$base/fpc-3.2.4rc1a.intelarm64-macosx.dmg/download"
sudo hdiutil attach -noautoopen /tmp/fpc.dmg
# le dmg 3.2.4rc1a monte en fpc-3.2.4rc1...-flat: glob sur fpc-*
pkg="$(find /Volumes/fpc-* -maxdepth 1 \( -name '*.mpkg' -o -name '*.pkg' \) | head -1)"
[ -n "$pkg" ] || { echo "paquet FPC introuvable dans le dmg" >&2; ls /Volumes >&2; exit 1; }
sudo installer -package "$pkg" -target /
sudo hdiutil detach /Volumes/fpc-*

curl -fsSL -o /tmp/lazarus.zip "$base/lazarus-darwin-aarch64-4.8.zip/download"
unzip -q /tmp/lazarus.zip -d "$HOME/laz"

# la config portable du zip pointe /Developer/lazarus, inaccessible (racine
# scellee SSV): on la fait pointer sur l'emplacement reel
cfg="$HOME/laz/lazarus/config/environmentoptions.xml"
[ -f "$cfg" ] || { echo "config du zip introuvable" >&2; ls "$HOME/laz" "$HOME/laz/lazarus" >&2; exit 1; }
sed -i '' "s|/Developer/lazarus|$HOME/laz/lazarus|g" "$cfg"

lb="$HOME/laz/lazarus/lazbuild"
[ -x "$lb" ] || { echo "lazbuild introuvable dans le zip" >&2; exit 1; }
sudo ln -sf "$lb" /usr/local/bin/lazbuild
lazbuild --version
