#!/usr/bin/env bash
# build-icu-ndk.sh — Build ICU 68.2 for x86_64-linux-android using NDK r23b.
#
# Produces libicudata_sv_apple.so, libicuuc_sv_apple.so, libicui18n_sv_apple.so
# in ./rootfs/system/lib64/, ready to be embedded by `make`.
#
# The Apple FairPlay libs (libCoreFoundation.so etc.) are x86_64 Android ELFs
# that run via hybris on Linux.  ICU must also be an x86_64 Android ELF so the
# Android linker can satisfy their DT_NEEDED libicuXX_sv_apple.so entries.
#
# Requires: docker with wrapper-build:latest (android-ndk-r23b at /app/android-ndk-r23b)
#
# Usage:
#   ./build-icu-ndk.sh
#
# Override:
#   ICU_VERSION=68.2 ./build-icu-ndk.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB64="$SCRIPT_DIR/rootfs/system/lib64"
ICU_VERSION="${ICU_VERSION:-68.2}"
ICU_MAJ="${ICU_VERSION%%.*}"
ICU_MIN="${ICU_VERSION##*.}"
ICU_UNDERSCORE="${ICU_MAJ}_${ICU_MIN}"
ICU_URL="https://github.com/unicode-org/icu/releases/download/release-${ICU_MAJ}-${ICU_MIN}/icu4c-${ICU_UNDERSCORE}-src.tgz"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/aml-icu-build"
ICU_TARBALL="$CACHE_DIR/icu4c-${ICU_UNDERSCORE}-src.tgz"

mkdir -p "$CACHE_DIR" "$LIB64"

echo "=== ICU $ICU_VERSION NDK build ==="
echo "  Target:  x86_64-linux-android31"
echo "  Soname:  libicuXX_sv_apple.so (unversioned symbols)"
echo "  Output:  $LIB64"

# ── Download ICU source ───────────────────────────────────────────────────────
if [ ! -f "$ICU_TARBALL" ]; then
    echo "Downloading ICU $ICU_VERSION from github.com/unicode-org/icu..."
    curl -fL "$ICU_URL" -o "$ICU_TARBALL"
fi

# ── Run build inside wrapper-build Docker container ─────────────────────────
docker run --rm -i \
    -v "$ICU_TARBALL:/icu-src.tgz:ro" \
    -v "$LIB64:/output" \
    wrapper-build:latest \
    bash -euo pipefail << 'DOCKEREOF'

NDK=/app/android-ndk-r23b
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
API=31
TARGET=x86_64-linux-android${API}

apt-get update -qq 2>&1 | tail -1
apt-get install -y -q patchelf 2>&1 | tail -1

export CC=$TOOLCHAIN/bin/${TARGET}-clang
export CXX=$TOOLCHAIN/bin/${TARGET}-clang++
export AR=$TOOLCHAIN/bin/llvm-ar
export RANLIB=$TOOLCHAIN/bin/llvm-ranlib
export STRIP=$TOOLCHAIN/bin/llvm-strip
export NM=$TOOLCHAIN/bin/llvm-nm

echo "  CC: $CC"
$CC --version 2>&1 | head -1

# Extract ICU source
mkdir -p /build
tar xzf /icu-src.tgz -C /build
ICU_SRC=$(ls -d /build/icu/source 2>/dev/null || echo "/build/icu/source")

# ── Phase 1: host build for cross-compile tools (icupkg, genrb, etc.) ────────
echo "--- Phase 1: host build ---"
mkdir -p /build/icu-host
cd /build/icu-host
unset CC CXX AR RANLIB STRIP NM
$ICU_SRC/configure \
    --disable-samples \
    --disable-tests \
    --enable-static=no \
    --enable-shared=yes \
    2>&1 | tail -3
make -j$(nproc) 2>&1 | tail -5
export LD_LIBRARY_PATH=/build/icu-host/lib:${LD_LIBRARY_PATH:-}

# ── Strip dat file using icupkg (no Python needed) ───────────────────────────
echo "--- Stripping ICU data package to whitelisted locales ---"
DAT_ORIG=$ICU_SRC/data/in/icudt68l.dat
DAT_STRIP=/build/icudt68l.dat

# Whitelisted locales (exact match after stripping path prefix and .res suffix)
KEEP="root en en_001 en_US en_AU en_CA en_GB fr fr_FR de de_DE ja ja_JP zh zh_Hans zh_Hant zh_CN zh_TW ko ko_KR es es_ES es_419 pt pt_BR pt_PT ru ru_RU it it_IT nl nl_NL pl pl_PL tr tr_TR ar ar_001 he he_IL hi hi_IN th th_TH sv sv_SE da da_DK fi fi_FI nb nb_NO cs cs_CZ hu hu_HU ro ro_RO sk sk_SK uk uk_UA id id_ID ms ms_MY vi vi_VN"

# Build remove list: any .res item whose locale is not in KEEP
# Items look like: "en.res", "brkitr/de.res", "coll/fr_FR.res"
# Also keep pool.res (ICU shared resource bundles — locale items depend on them)
# and zh_Hans_CN/zh_Hant_TW (likely-subtag expansions depended on by zh_CN/zh_TW coll)
KEEP_EXTRA="pool zh_Hans_CN zh_Hant_TW"

/build/icu-host/bin/icupkg -l "$DAT_ORIG" | awk -v keep="$KEEP" -v extra="$KEEP_EXTRA" '
BEGIN {
    split(keep, arr);  for (i in arr) keepset[arr[i]] = 1
    split(extra, arr2); for (i in arr2) keepset[arr2[i]] = 1
}
{
    item = $0
    # Extract basename: part after last /
    n = split(item, parts, "/")
    base = parts[n]
    # Strip .res suffix
    if (sub(/\.res$/, "", base)) {
        if (!(base in keepset)) {
            print item
        }
    }
    # Non-.res items (dicts, brk, nrm, etc.) — always keep (no print = no remove)
}
' > /build/remove.txt

echo "  Items to remove: $(wc -l < /build/remove.txt)"
echo "  Items to keep:   $(( $(/build/icu-host/bin/icupkg -l "$DAT_ORIG" | wc -l) - $(wc -l < /build/remove.txt) ))"

/build/icu-host/bin/icupkg -r /build/remove.txt "$DAT_ORIG" "$DAT_STRIP"
echo "  Original dat: $(du -sh "$DAT_ORIG" | cut -f1)  stripped dat: $(du -sh "$DAT_STRIP" | cut -f1)"

# Swap in stripped dat for the cross build
cp "$DAT_STRIP" "$DAT_ORIG.bak"
cp "$DAT_STRIP" "$DAT_ORIG"

# ── Phase 2: cross-build for x86_64-linux-android ────────────────────────────
echo "--- Phase 2: x86_64-android cross-build ---"
export CC=$TOOLCHAIN/bin/${TARGET}-clang
export CXX=$TOOLCHAIN/bin/${TARGET}-clang++
export AR=$TOOLCHAIN/bin/llvm-ar
export RANLIB=$TOOLCHAIN/bin/llvm-ranlib
export STRIP=$TOOLCHAIN/bin/llvm-strip
export NM=$TOOLCHAIN/bin/llvm-nm
export CFLAGS="-fPIC -Os -DANDROID -D__ANDROID_API__=${API}"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-fPIC -Wl,--no-undefined"

mkdir -p /build/icu-cross
cd /build/icu-cross
$ICU_SRC/configure \
    --host=x86_64-linux-android \
    --with-cross-build=/build/icu-host \
    --disable-samples \
    --disable-tests \
    --enable-static=no \
    --enable-shared=yes \
    --with-library-suffix=_sv_apple \
    --with-data-packaging=library \
    --prefix=/install \
    CPPFLAGS="-DU_DISABLE_RENAMING=1" \
    2>&1 | tail -5
make -j$(nproc) 2>&1 | tail -5
make install 2>&1 | tail -3

echo "--- Install contents ---"
ls -lh /install/lib/

# ── Fix sonames inside Docker (root can write), then copy outputs ─────────────
echo "--- Fixing sonames ---"
for lib in libicudata_sv_apple libicuuc_sv_apple libicui18n_sv_apple; do
    real=$(readlink -f /install/lib/${lib}.so)
    $STRIP --strip-unneeded "$real" -o /tmp/${lib}.so
done
# Set sonames to unversioned form (ICU libtool writes libXXX.so.68 as SONAME)
patchelf --set-soname libicudata_sv_apple.so  /tmp/libicudata_sv_apple.so
patchelf --set-soname libicuuc_sv_apple.so    /tmp/libicuuc_sv_apple.so
patchelf --set-soname libicui18n_sv_apple.so  /tmp/libicui18n_sv_apple.so
# Fix DT_NEEDED versioned references in uc and i18n
patchelf --replace-needed libicudata_sv_apple.so.68 libicudata_sv_apple.so /tmp/libicuuc_sv_apple.so
patchelf --replace-needed libicudata_sv_apple.so.68 libicudata_sv_apple.so /tmp/libicui18n_sv_apple.so
patchelf --replace-needed libicuuc_sv_apple.so.68   libicuuc_sv_apple.so  /tmp/libicui18n_sv_apple.so
# The NDK-built libs import __register_atfork, which the Android libc used at
# runtime does not export (it exports pthread_atfork).  pthread_atfork takes the
# same first three arguments and ignores the fourth, so retarget the import in
# .dynstr (same length, NUL padded) so the libs resolve against the real libc.
for lib in libicuuc_sv_apple libicui18n_sv_apple; do
    perl -0pi -e 's/__register_atfork\0/pthread_atfork\0\0\0\0/g' /tmp/${lib}.so
    if nm -D --undefined-only /tmp/${lib}.so | grep -q __register_atfork; then
        echo "ERROR: ${lib}.so still imports __register_atfork" >&2; exit 1
    fi
done
# Copy to output volume
for lib in libicudata_sv_apple libicuuc_sv_apple libicui18n_sv_apple; do
    cp /tmp/${lib}.so /output/${lib}.so
    echo "  -> ${lib}.so ($(du -sh /output/${lib}.so | cut -f1))  soname=$(patchelf --print-soname /output/${lib}.so)"
done

echo "--- ICU build + soname fix done ---"
DOCKEREOF

echo "=== ICU build complete ==="
for lib in libicudata_sv_apple libicuuc_sv_apple libicui18n_sv_apple; do
    printf "  %s  soname=%s\n" "$lib.so" \
        "$(readelf -d "$LIB64/$lib.so" 2>/dev/null | grep SONAME | grep -o '\[.*\]')"
done
ls -lh "$LIB64"/libicu*_sv_apple.so

echo ""
echo "Rebuild embedded blobs with:"
echo "  make clean && make"
