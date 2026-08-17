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

# Repertoire Lazarus (celui qui contient lcl/). lazbuild le lit normalement dans
# sa configuration primaire, mais celle-ci peut etre vide ou absente: c'est le
# cas dans un environnement d'empaquetage, ou HOME est neuf. Le message est
# alors « Invalid Lazarus directory "": directory lcl not found », qui ne dit
# pas qu'il suffit de le nommer. On le cherche donc, et on ne passe l'option que
# si on a trouve un repertoire credible -- sinon on laisse lazbuild a sa
# configuration, qui reste la reference quand elle existe.
# LAZARUS_DIR dans l'environnement tranche en dernier ressort.
lazdir="${LAZARUS_DIR:-}"
if [ -z "$lazdir" ]; then
  for c in \
    "$(dirname "$lazbuild")" \
    /usr/lib/lazarus /usr/lib/lazarus/* \
    /usr/lib64/lazarus /usr/lib64/lazarus/* \
    /usr/share/lazarus /usr/share/lazarus/* \
    /Applications/Lazarus \
    "$HOME/Applications/Lazarus" \
    "$HOME/fpcupdeluxe/lazarus"; do
    # lcl/interfaces et pas seulement lcl: un dossier « lcl » vide ne suffit pas
    if [ -d "$c/lcl/interfaces" ]; then lazdir="$c"; break; fi
  done
fi
lazdirarg=""
[ -n "$lazdir" ] && lazdirarg="--lazarusdir=$lazdir"

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
[ -n "$lazdir" ] && echo "lazarusdir: $lazdir"
# lazbuild resout les chemins des ressources RCDATA relativement au CWD,
# pas au .lpi: se placer dans app/ est obligatoire
cd "$root/app"
"$lazbuild" $buildarg ${lazdirarg:+"$lazdirarg"} ${optarg:+"$optarg"} "$lpi"
echo "OK -> $root/rottensshrimp"
