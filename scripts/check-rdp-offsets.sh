#!/usr/bin/env bash
#
# Confronte les offsets en dur de bindings/freerdp/uFreeRdpApi.pas a ceux que le
# compilateur calcule contre les VRAIS en-tetes de la machine. Un offset faux en
# lecture donne un ecran noir; en ecriture, il ecrase la memoire d'autrui avec un
# pointeur de fonction. La CI attrape la derive avant l'utilisateur.
#
# La table a UN offset conditionnel, BITMAP_OFF_HDC: on verifie la branche de la
# machine (Darwin/arm64 -> 288, */x86_64 -> 296). Ailleurs (arm64 Linux, x86_64
# macOS) aucune branche Pascal ne correspond: on s'abstient plutot que d'accuser
# a tort.
#
# Usage: scripts/check-rdp-offsets.sh   (0 = concordance, 1 = ecarts detailles)
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pas="${root}/bindings/freerdp/uFreeRdpApi.pas"
src="${root}/scripts/gen-rdp-offsets.c"

# Quelle branche de la table verifie-t-on, et donc quelle declaration retenir
# en cas de doublon (BITMAP_OFF_HDC)? La sonde native rend la valeur de SA
# plateforme; on la compare a la branche Pascal correspondante.
os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Darwin/arm64)
    branch="darwin"   # {$IFDEF DARWIN}: PREMIERE declaration (288)
    ;;
  */x86_64 | */amd64)
    if [ "$os" = "Darwin" ]; then
      echo "IGNORE: la branche {\$IFDEF DARWIN} est figee pour arm64 (Apple" >&2
      echo "Silicon); cette machine est x86_64 macOS, sans branche Pascal" >&2
      echo "dediee -- tout ecart serait un faux positif." >&2
      exit 0
    fi
    branch="else"     # {$ELSE}: DERNIERE declaration (296, Linux/Windows)
    ;;
  *)
    echo "IGNORE: controle prevu pour x86_64 (Linux/Windows) ou arm64 (macOS)," >&2
    echo "machine $os/$arch. La sonde rendrait des offsets sans branche Pascal" >&2
    echo "correspondante; tout ecart serait un faux positif." >&2
    exit 0
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cc="${CC:-cc}"

compile_probe() {
  # $1 = cflags (mots separes par espace). Rend 0 si la sonde compile.
  # shellcheck disable=SC2086
  $cc -w "$src" -o "$tmp/gen" $1 2>"$tmp/cc.log"
}

# En-tetes: pkg-config d'abord (portable), sinon les emplacements usuels --
# distributions Linux ET Homebrew macOS. Sur certaines installations Homebrew,
# les --cflags de pkg-config contiennent des chemins RELATIFS non resolus
# (.../lib/pkgconfig/../../include/...) qui font echouer le compilateur: d'ou
# le repli sur des repertoires en dur si le premier essai echoue.
cflags_pc=""
if command -v pkg-config >/dev/null 2>&1; then
  cflags_pc="$(pkg-config --cflags freerdp3 winpr3 2>/dev/null || true)"
fi
cflags_fb=""
for d in /usr/include/freerdp3 /usr/include/winpr3 /usr/include \
         /opt/homebrew/opt/freerdp/include/freerdp3 \
         /opt/homebrew/opt/freerdp/include/winpr3 \
         /usr/local/opt/freerdp/include/freerdp3 \
         /usr/local/opt/freerdp/include/winpr3; do
  [ -d "$d" ] && cflags_fb="$cflags_fb -I$d"
done

if [ -n "$cflags_pc" ] && compile_probe "$cflags_pc"; then
  :
elif [ -n "$cflags_fb" ] && compile_probe "$cflags_fb"; then
  :
else
  echo "ECHEC: compilation de la sonde impossible." >&2
  echo "En-tetes FreeRDP 3 introuvables ? (freerdp3-dev / freerdp-devel," >&2
  echo "ou 'brew install freerdp' sous macOS)" >&2
  sed -n '1,20p' "$tmp/cc.log" >&2
  exit 1
fi

"$tmp/gen" | sed 's/[[:space:]]//g' | sort > "$tmp/actual.txt"

# Constantes Pascal: « NOM = VALEUR; » du bloc const, lignes commentees exclues.
# sed portable (BRE, sans \+): mawk/busybox des conteneurs ignorent le match()
# a trois arguments de GNU awk. L'ORDRE du fichier est conserve: BITMAP_OFF_HDC
# y apparait deux fois, {$IFDEF DARWIN} PUIS {$ELSE}, d'ou le head/tail choisi
# selon la branche verifiee (pick_declared).
grep -v '^[[:space:]]*//' "$pas" \
  | sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*;.*/\1=\2;/p' \
  > "$tmp/declared.txt"

pick_declared() {
  # $1 = nom. Retient la declaration de la BRANCHE verifiee: la premiere sous
  # Darwin ({$IFDEF DARWIN}), la derniere sinon ({$ELSE}).
  if [ "$branch" = "darwin" ]; then
    grep "^$1=" "$tmp/declared.txt" | head -1
  else
    grep "^$1=" "$tmp/declared.txt" | tail -1
  fi
}

fail=0
while IFS= read -r line; do
  name="${line%%=*}"
  got="${line#*=}"
  want="$(pick_declared "$name" || true)"
  if [ -z "$want" ]; then
    echo "MANQUANT   ${name}: absent de uFreeRdpApi.pas (sonde: ${got%;})"
    fail=1
    continue
  fi
  want="${want#*=}"
  if [ "$got" != "$want" ]; then
    echo "DIVERGENCE ${name}: en-tetes=${got%;} vs Pascal=${want%;}"
    fail=1
  fi
done < "$tmp/actual.txt"

n=$(wc -l < "$tmp/actual.txt" | tr -d ' ')
if [ "$fail" -eq 0 ]; then
  echo "OK: les ${n} offsets FreeRDP concordent (branche ${branch}, ${os}/${arch})."
  if command -v pkg-config >/dev/null 2>&1; then
    echo "    (freerdp3 $(pkg-config --modversion freerdp3 2>/dev/null || echo 'version inconnue'))"
  fi
else
  echo
  echo "Les offsets en dur ne correspondent PAS a cette construction de FreeRDP." >&2
  echo "L'application s'en protege a l'execution (temoins de disposition, repli" >&2
  echo "sur recopie integrale) et, sous macOS, par le shim obligatoire du" >&2
  echo "bundle; mais la table doit etre corrigee." >&2
fi
exit "$fail"
