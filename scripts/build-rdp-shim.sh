#!/usr/bin/env bash
#
# Construit rssh_rdp_shim, l'oracle de disposition memoire de FreeRDP 3. Compile
# contre les EN-TETES de la machine: c'est tout l'interet, le compilateur resout
# chaque champ pour la bibliotheque qui sera reellement chargee. Ne LIE PAS
# FreeRDP, donc rien ne change au chargement durci du programme.
#
# FACULTATIF: sans en-tetes, on s'arrete proprement et l'application retombe sur
# ses offsets en dur (proteges par des temoins). Paquets: freerdp3-dev +
# libwinpr3-dev (Debian), freerdp-devel (Fedora), freerdp (Arch), freerdp3-devel
# (openSUSE), brew install freerdp (macOS).
#
# Usage: scripts/build-rdp-shim.sh [--strict]   (--strict: absence d'en-tetes ou
# warning du compilateur = echec, ce que la CI doit utiliser)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${root}/bindings/freerdp/shim/rssh_rdp_shim.c"
outdir="${root}/lib"

strict=0
[ "${1:-}" = "--strict" ] && strict=1

fail_or_skip() {
  if [ "$strict" -eq 1 ]; then
    echo "$1" >&2
    exit 1
  fi
  echo "$1"
  echo "==> shim non construit: l'application utilisera ses decalages en dur."
  exit 0
}

case "$(uname -s)" in
  Darwin) libname="librssh_rdp_shim.dylib" ;;
  Linux)  libname="librssh_rdp_shim.so" ;;
  *)      libname="rssh_rdp_shim.dll" ;;
esac

cc="${CC:-cc}"
command -v "$cc" >/dev/null 2>&1 || fail_or_skip "Compilateur C introuvable ($cc)."

# En-tetes: pkg-config d'abord (portable entre distributions), puis les
# emplacements usuels si le fichier .pc manque.
# RSSH_FREERDP_CFLAGS force les chemins d'en-tetes: utile aux paquets qui
# construisent hors racine, et a la CI.
cflags="${RSSH_FREERDP_CFLAGS:-}"
if [ -z "$cflags" ] && command -v pkg-config >/dev/null 2>&1; then
  cflags="$(pkg-config --cflags freerdp3 winpr3 2>/dev/null || true)"
fi
if [ -z "$cflags" ]; then
  for d in /usr/include/freerdp3 /usr/include/winpr3 \
           /usr/local/include/freerdp3 /usr/local/include/winpr3 \
           /opt/homebrew/include/freerdp3 /opt/homebrew/include/winpr3; do
    [ -d "$d" ] && cflags="$cflags -isystem $d"
  done
fi
[ -n "$cflags" ] || fail_or_skip "En-tetes FreeRDP 3 introuvables."

# -isystem plutot que -I pour les en-tetes tiers: leurs propres avertissements
# ne doivent pas noyer les notres, que l'on veut a zero.
cflags="$(printf '%s' "$cflags" | sed 's/-I/-isystem /g')"

warn="-Wall -Wextra -Wconversion -Wcast-qual -Wshadow"
hard="-O2 -fPIC -fvisibility=hidden -fstack-protector-strong -D_FORTIFY_SOURCE=2"
case "$(uname -s)" in
  Linux) hard="$hard -Wl,-z,relro,-z,now" ;;
esac

mkdir -p "$outdir"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

if ! $cc -shared -std=gnu11 $warn $hard $cflags "$src" -o "${outdir}/${libname}" \
     2>"$log"; then
  cat "$log" >&2
  fail_or_skip "Compilation du shim impossible."
fi

if [ -s "$log" ]; then
  cat "$log"
  if [ "$strict" -eq 1 ]; then
    echo "ECHEC: avertissement du compilateur en mode strict." >&2
    exit 1
  fi
fi

echo "OK -> ${outdir}/${libname}"

# Controles de surete du binaire produit: le shim ne doit RIEN allouer (donc
# rien a fuir) et ne doit dependre d'aucune bibliotheque FreeRDP.
if command -v nm >/dev/null 2>&1; then
  if nm -D --undefined-only "${outdir}/${libname}" 2>/dev/null \
       | grep -qiE ' (malloc|calloc|realloc|free|strcpy|strcat|sprintf)$'; then
    echo "ECHEC: le shim reference une fonction d'allocation ou de copie de" >&2
    echo "chaine -- il doit rester sans allocation et sans tampon." >&2
    exit 1
  fi
fi
if command -v ldd >/dev/null 2>&1; then
  if ldd "${outdir}/${libname}" 2>/dev/null | grep -qiE 'freerdp|winpr'; then
    echo "ECHEC: le shim est lie a FreeRDP; il ne doit utiliser que ses" >&2
    echo "en-tetes (sinon le chargement durci par chemin absolu est court-circuite)." >&2
    exit 1
  fi
fi
echo "    (sans allocation, sans dependance FreeRDP)"
