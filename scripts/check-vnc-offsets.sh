#!/usr/bin/env bash
#
# Confronte les offsets en dur de bindings/libvnc/uLibVncApi.pas a ceux que le
# compilateur calcule contre les en-tetes de NOTRE construction de
# libvncclient. Contrairement a FreeRDP, la bibliotheque ne vient pas de la
# distribution: c'est nous qui la batissons, donc un ecart ici n'est jamais une
# fatalite, c'est un bogue de recette -- et il coute cher. Le controle de
# CheckStructLayout se contente de refuser la bibliotheque au chargement: VNC
# disparait purement et simplement du produit, avec un message que seul un
# lancement en terminal montre. C'est arrive: la table Linux avait ete generee
# sur une machine sans en-tetes JPEG, la CI en avait une avec, et le .deb
# publie ouvrait zero session VNC.
#
# Usage: scripts/check-vnc-offsets.sh   (0 = concordance, 1 = ecarts detailles)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pas="${root}/bindings/libvnc/uLibVncApi.pas"
src="${root}/scripts/gen-vnc-offsets.c"
vdir="${root}/third_party/libvnc"

# Quelle branche de la table? Le fichier declare TROIS jeux, dans cet ordre:
# {$IFDEF WINDOWS} (1), {$IFDEF DARWIN} (2), {$ELSE} = Linux (3). La sonde est
# native: elle ne peut valider que la branche de la machine qui l'execute.
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

# En-tetes: ceux de la construction epinglee, jamais ceux du systeme. Sans eux
# la comparaison n'a aucun sens -- c'est precisement le piege qu'on ferme.
# Meme empreinte que make-app.sh / build-deb.sh: patch modifie => reconstruction.
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
# La ligne « // config: ... » n'est pas une constante mais elle vaut d'etre lue
# quand ca casse: on la garde a l'ecran.
cfg="$(sed -n 's|^ *// config: *||p' "$tmp/raw.txt")"
sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9][0-9]*\);.*/\1=\2/p' \
  "$tmp/raw.txt" | sort > "$tmp/actual.txt"

# Constantes Pascal: « NOM = VALEUR; » du bloc const, lignes commentees exclues.
# sed portable (BRE, sans \+): mawk/busybox des conteneurs ignorent le match()
# a trois arguments de GNU awk. L'ORDRE du fichier est conserve, c'est lui qui
# distingue les trois branches.
grep -v '^[[:space:]]*//' "$pas" \
  | sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*;.*/\1=\2/p' \
  > "$tmp/declared.txt"

pick_declared() {
  # $1 = nom. Trois declarations => celle de la branche verifiee; une seule
  # (rfbPixelFormat, AppData: aucune n'est conditionnelle) => elle-meme.
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
