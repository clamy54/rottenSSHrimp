#!/usr/bin/env bash
# Build Linux / macOS. Usage: scripts/build.sh [--release]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lpi="$root/app/rottensshrimp.lpi"

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

# HOME neuf (empaquetage) = config lazbuild vide et « directory lcl not found ».
# --lazarusdir seulement si on trouve mieux; LAZARUS_DIR tranche.
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
    # lcl/interfaces: un « lcl » vide ne prouve rien
    if [ -d "$c/lcl/interfaces" ]; then lazdir="$c"; break; fi
  done
fi
lazdirarg=""
[ -n "$lazdir" ] && lazdirarg="--lazarusdir=$lazdir"

# exe en cours = lien impossible
pkill -f '[Rr]ottensshrimp$' 2>/dev/null || true

buildarg=""
[ "${1:-}" = "--release" ] && buildarg="--build-mode=Release"

# Xcode >= 15 rejette l'ObjC de FPC ("malformed method list atom"); ld-classic non.
optarg=""
if [ "$(uname -s)" = "Darwin" ]; then
  optarg="--opt=-k-ld_classic"
fi

# Linux: GTK3, celui de Lazarus trunk (>= 5). RSSH_WS=gtk2 pour l'ancien.
wsarg=""
if [ "$(uname -s)" = "Linux" ]; then
  ws="${RSSH_WS:-gtk3}"
  lazver="$("$lazbuild" --version 2>/dev/null | head -1)"
  if [ "$ws" = "gtk3" ] && [ "${lazver%%.*}" -lt 5 ] 2>/dev/null; then
    echo "Lazarus $lazver: GTK3 demande Lazarus trunk (>= 5). RSSH_WS=gtk2 sinon." >&2
    exit 1
  fi
  wsarg="--ws=$ws"
fi

# shim facultatif ici: sans en-tetes, l'app retombe sur ses offsets
"$root/scripts/build-rdp-shim.sh" || true

echo "lazbuild: $lazbuild"
[ -n "$lazdir" ] && echo "lazarusdir: $lazdir"
# lazbuild resout les RCDATA depuis le cwd, PAS depuis le .lpi
cd "$root/app"
"$lazbuild" $buildarg $wsarg ${lazdirarg:+"$lazdirarg"} \
  ${LAZBUILD_PCP:+"--pcp=$LAZBUILD_PCP"} ${optarg:+"$optarg"} ${LAZBUILD_OPTS:-} "$lpi"
echo "OK -> $root/rottensshrimp"
