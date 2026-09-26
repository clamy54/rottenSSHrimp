#!/usr/bin/env bash
#
# Offsets en dur de uLibVncApi.pas contre les en-tetes de NOTRE libvncclient.
# On la batit nous-memes: un ecart est un bogue de recette, et au chargement
# VNC disparait en silence. Deja vu: un .deb publie a zero session VNC.
#
# Usage: scripts/check-vnc-offsets.sh   (0 = concordance, 1 = ecarts detailles)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pas="${root}/bindings/libvnc/uLibVncApi.pas"
src="${root}/scripts/gen-vnc-offsets.c"
vdir="${root}/third_party/libvnc"

# TROIS jeux dans l'ordre: WINDOWS (1), DARWIN (2), ELSE = Linux (3). Sonde
# native: seule la branche de la machine courante se verifie.
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux)  branch=3; label="ELSE (Linux)" ;;
  Darwin) branch=2; label="IFDEF DARWIN" ;;
  *)
    echo "IGNORE: controle prevu pour Linux et macOS, machine $os/$arch." >&2
    echo "La branche {\$IFDEF WINDOWS} se verifie depuis Windows, ou la lib" >&2
    echo "est une DLL prebatie (scripts/check-win-deps.sh en tient les" >&2
    echo "empreintes)." >&2
    exit 0
    ;;
esac

# En-tetes de la construction epinglee, JAMAIS ceux du systeme. Meme empreinte
# que make-app.sh / build-deb.sh: patch modifie => reconstruction.
want_stamp="$(cat "$vdir/SHA256SUMS" "$root/scripts/build-libvnc.sh" \
  "$vdir"/patches/*.patch 2>/dev/null | \
  { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
  | awk '{print $1}')"
have_stamp="$(cat "$vdir/out/.build-stamp" 2>/dev/null || true)"
if [ ! -f "$vdir/out/include/rfb/rfbconfig.h" ] || [ "$want_stamp" != "$have_stamp" ]; then
  echo "==> libvncclient vendorisee absente ou recette modifiee: (re)construction"
  "$root/scripts/build-libvnc.sh" || exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cc="${CC:-cc}"
if ! $cc -w "$src" -I"$vdir/out/include" -o "$tmp/gen" 2>"$tmp/cc.log"; then
  echo "ECHEC: compilation de la sonde impossible." >&2
  sed -n '1,20p' "$tmp/cc.log" >&2
  exit 1
fi

"$tmp/gen" > "$tmp/raw.txt" || exit 1
# « // config: ... » gardee pour l'affichage: c'est elle qu'on lit quand ca casse
cfg="$(sed -n 's|^ *// config: *||p' "$tmp/raw.txt")"
sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9][0-9]*\);.*/\1=\2/p' \
  "$tmp/raw.txt" | sort > "$tmp/actual.txt"

# sed BRE sans \+: mawk/busybox ignorent le match() a trois arguments de gawk.
# L'ORDRE du fichier est conserve: c'est lui qui distingue les branches.
grep -v '^[[:space:]]*//' "$pas" \
  | sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*;.*/\1=\2/p' \
  > "$tmp/declared.txt"

pick_declared() {
  # $1 = nom. Trois declarations: celle de la branche; une seule: elle-meme.
  local n
  n="$(grep -c "^$1=" "$tmp/declared.txt")"
  if [ "$n" = "1" ]; then
    grep "^$1=" "$tmp/declared.txt"
  elif [ "$n" = "3" ]; then
    grep "^$1=" "$tmp/declared.txt" | sed -n "${branch}p"
  else
    return 1
  fi
}

fail=0
while IFS= read -r line; do
  name="${line%%=*}"
  got="${line#*=}"
  want="$(pick_declared "$name")" || {
    echo "MANQUANT   ${name}: pas de declaration exploitable dans uLibVncApi.pas (sonde: ${got})"
    fail=1
    continue
  }
  want="${want#*=}"
  if [ "$got" != "$want" ]; then
    echo "DIVERGENCE ${name}: lib construite=${got} vs Pascal=${want}"
    fail=1
  fi
done < "$tmp/actual.txt"

n=$(wc -l < "$tmp/actual.txt" | tr -d ' ')
if [ "$fail" -eq 0 ]; then
  echo "OK: les ${n} offsets libvncclient concordent (branche ${label}, ${os}/${arch})."
  echo "    (${cfg})"
else
  echo
  echo "Table incorrecte pour CETTE construction (${cfg})." >&2
  echo "L'application refuserait la bibliotheque au chargement et VNC serait" >&2
  echo "desactive en silence pour tous les utilisateurs du paquet. Regenerez:" >&2
  echo "  cc -Ithird_party/libvnc/out/include scripts/gen-vnc-offsets.c -o /tmp/gen && /tmp/gen" >&2
  echo "puis collez le resultat dans la branche ${label} de uLibVncApi.pas." >&2
fi
exit "$fail"
