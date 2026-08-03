#!/usr/bin/env bash
# Build portable (Linux / macOS). Localise lazbuild tout seul, chemin .lpi
# relatif, tue l'exe avant de recompiler.
# Usage: scripts/build.sh [--release]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lpi="$root/app/rottensshrimp.lpi"

# lazbuild : PATH d'abord, puis emplacements d'install classiques
lazbuild="$(command -v lazbuild || true)"
if [ -z "$lazbuild" ]; then
  for c in \
    /usr/bin/lazbuild \
    /usr/local/bin/lazbuild \
    /Applications/Lazarus/lazbuild \
    "$HOME/Applications/Lazarus/lazbuild" \
    "$HOME/fpcupdeluxe/lazarus/lazbuild" \
    "$HOME/Downloads/lazarus/lazbuild" \
    /Applications/fpcupdeluxe/lazarus/lazbuild \
    /snap/bin/lazbuild; do
    if [ -x "$c" ]; then lazbuild="$c"; break; fi
  done
fi
[ -n "$lazbuild" ] || { echo "lazbuild introuvable. Ajoute-le au PATH ou installe Lazarus." >&2; exit 1; }

# tuer l'exe s'il tourne (sinon lien impossible)
pkill -f '[Rr]ottensshrimp$' 2>/dev/null || true

buildarg=""
[ "${1:-}" = "--release" ] && buildarg="--build-mode=Release"

# macOS: le linker Xcode >= 15 rejette les metadonnees ObjC generees par FPC
# pour la LCL Cocoa ("malformed method list atom"). ld-classic les accepte.
optarg=""
if [ "$(uname -s)" = "Darwin" ]; then
  optarg="--opt=-k-ld_classic"
fi

# Shim FreeRDP: facultatif. Sans en-tetes freerdp3, il s'arrete proprement et
# l'app retombe sur ses offsets en dur -- le build n'echoue pas pour autant.
"$root/scripts/build-rdp-shim.sh" || true

echo "lazbuild: $lazbuild"
# lazbuild resout les chemins des ressources RCDATA relativement au CWD,
# pas au .lpi: se placer dans app/ est obligatoire
cd "$root/app"
"$lazbuild" $buildarg ${optarg:+"$optarg"} "$lpi"
echo "OK -> $root/rottensshrimp"
