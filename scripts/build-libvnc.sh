#!/usr/bin/env bash
# Construit une libvncclient VENDORISEE, EPINGLEE et PATCHEE:
# le paquet Homebrew 0.9.15 traine CVE-2026-50538 et -44988 (Tight, hors tas,
# PRE-AUTH) qu'aucune release amont ne corrige. La compiler nous-memes fige la
# config (zlib + JPEG ON, tout le reste OFF) et les offsets de rfbClient.
# GPL, source correspondante = ce script + les patches + le tarball ARCHIVE
# dans le depot: le hash seul ne survit pas a la disparition de l'amont.

set -euo pipefail

VER="0.9.15"
TARBALL="LibVNCServer-${VER}.tar.gz"
URL="https://github.com/LibVNC/libvncserver/archive/refs/tags/${TARBALL}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VDIR="${REPO_ROOT}/third_party/libvnc"
CACHE="${VDIR}/cache"
WORK="${VDIR}/work"
OUT="${VDIR}/out"

OS="$(uname -s)"
case "$OS" in
  Darwin|Linux) ;;
  *) echo "plateforme non supportee: $OS" >&2; exit 1 ;;
esac

CMAKE="${CMAKE:-$(command -v cmake || true)}"
if [[ ! -x "$CMAKE" ]]; then
  for c in /usr/bin/cmake /usr/local/bin/cmake /opt/homebrew/bin/cmake \
           "$HOME/cmake/bin/cmake"; do
    [[ -x "$c" ]] && { CMAKE="$c"; break; }
  done
fi
if [[ ! -x "$CMAKE" ]]; then
  echo "cmake introuvable (apt install cmake / brew install cmake), ou CMAKE=<chemin>" >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
fetch_to() {  # fetch_to <url> <dest>
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 300 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q --timeout=300 -O "$2" "$1"
  else echo "ni curl ni wget disponibles" >&2; return 1; fi
}
if command -v nproc >/dev/null 2>&1; then NCPU="$(nproc)"
else NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"; fi

mkdir -p "$CACHE"

# La copie ARCHIVEE prime sur le telechargement: c'est elle, la source GPL.
if [[ ! -f "${CACHE}/${TARBALL}" ]]; then
  if [[ -f "${VDIR}/${TARBALL}" ]]; then
    echo "==> tarball archive dans le depot"
    cp "${VDIR}/${TARBALL}" "${CACHE}/${TARBALL}"
  else
    echo "==> telechargement ${TARBALL}"
    fetch_to "$URL" "${CACHE}/${TARBALL}.part"
    mv "${CACHE}/${TARBALL}.part" "${CACHE}/${TARBALL}"
  fi
fi
echo "==> verification SHA-256 (epingle)"
EXPECTED="$(awk '{print $1}' "${VDIR}/SHA256SUMS")"
GOT="$(sha256_of "${CACHE}/${TARBALL}")"
if [[ "$GOT" != "$EXPECTED" ]]; then
  echo "SHA-256 du tarball NON conforme: build refuse." >&2
  echo "  attendu: $EXPECTED" >&2
  echo "  obtenu : $GOT" >&2
  exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK"
tar xzf "${CACHE}/${TARBALL}" -C "$WORK"
SRC="$(ls -d "${WORK}"/*/)"
echo "==> source: ${SRC}"

# Ordre lexicographique, --fuzz=0, echec dur: jamais de lib a moitie corrigee.
for p in "${VDIR}"/patches/*.patch; do
  echo "==> patch $(basename "$p")"
  ( cd "$SRC" && patch -p1 --fuzz=0 <"$p" )
done

BUILD="${WORK}/build"
"$CMAKE" -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_SHARED_LIBS=ON \
  -DLIBVNCSERVER_INSTALL=OFF \
  -DWITH_ZLIB=ON -DWITH_JPEG=ON \
  -DWITH_LZO=OFF -DWITH_PNG=OFF \
  -DWITH_GNUTLS=OFF -DWITH_OPENSSL=OFF -DWITH_GCRYPT=OFF \
  -DWITH_SASL=OFF -DWITH_WEBSOCKETS=OFF \
  -DWITH_SYSTEMD=OFF -DWITH_XCB=OFF \
  -DWITH_TIGHTVNC_FILETRANSFER=OFF \
  -DWITH_SDL=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
  -DWITH_LIBSSHTUNNEL=OFF -DWITH_FFMPEG=OFF \
  -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF \
  >/dev/null
"$CMAKE" --build "$BUILD" --target vncclient -j"$NCPU"

rm -rf "$OUT"
mkdir -p "${OUT}/lib" "${OUT}/include/rfb"
if [[ "$OS" == "Darwin" ]]; then
  LIB="$(ls "${BUILD}"/libvncclient.*.dylib | grep -E 'libvncclient\.[0-9]' | head -1)"
else
  # le vrai fichier porte la version complete; les .so/.so.1 du build sont des liens
  LIB="$(ls "${BUILD}"/libvncclient.so.* | grep -E 'libvncclient\.so\.[0-9]+\.[0-9]' | head -1)"
  [[ -n "$LIB" ]] || LIB="$(ls "${BUILD}"/libvncclient.so.* | head -1)"
fi
[[ -n "$LIB" && -f "$LIB" ]] || { echo "bibliotheque construite introuvable dans ${BUILD}" >&2; exit 1; }
cp "$LIB" "${OUT}/lib/"
BASE="$(basename "$LIB")"
( cd "${OUT}/lib"
  if [[ "$OS" == "Darwin" ]]; then
    ln -sf "$BASE" "libvncclient.1.dylib"
    ln -sf "libvncclient.1.dylib" "libvncclient.dylib"
  else
    ln -sf "$BASE" "libvncclient.so.1"
    ln -sf "libvncclient.so.1" "libvncclient.so"
  fi )
# macOS: install_name portable, sinon pas d'embarquement dans le .app.
if [[ "$OS" == "Darwin" ]]; then
  install_name_tool -id "@rpath/libvncclient.1.dylib" "${OUT}/lib/${BASE}" 2>/dev/null || true
fi
# rfbconfig.h GENERE par-dessus: gen-vnc-offsets.c colle a CETTE construction.
cp "${SRC}/include/rfb/"*.h "${OUT}/include/rfb/" 2>/dev/null || true
cp "${BUILD}/include/rfb/rfbconfig.h" "${OUT}/include/rfb/rfbconfig.h"

# Empreinte lue par make-app.sh: sans elle, il rembarque une dylib perimee.
cat "${VDIR}/SHA256SUMS" "${REPO_ROOT}/scripts/build-libvnc.sh" \
    "${VDIR}"/patches/*.patch > "${WORK}/.stamp-input"
sha256_of "${WORK}/.stamp-input" > "${OUT}/.build-stamp"

echo "==> OK: ${OUT}/lib/${BASE}"
ls -l "${OUT}/lib/"
