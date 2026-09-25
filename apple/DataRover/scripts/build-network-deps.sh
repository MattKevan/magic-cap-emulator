#!/bin/bash
set -euo pipefail

# Build static libslirp and its GLib/PCRE2 dependencies for all Apple targets.
# Requires Xcode command line tools, CMake, Meson, Ninja, pkg-config and curl.
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/build/apple-network-deps"
SRC="$ROOT/build/apple-network-src"
WORK="$ROOT/build/apple-network-work"
for tool in xcrun clang clang++ cmake meson ninja pkg-config curl shasum; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

PCRE_VERSION=10.48
PCRE_SHA=ebcc25aadf2a51fa1fefa9b8bc9e7a79b3dae86870a0f1152a22e42befd46888
GLIB_VERSION=2.90.0
GLIB_SHA=17d15cac2af80a33271127408e0abc2748eb297c595c2a26409e81e14e7d1b8f
SLIRP_VERSION=4.9.5
SLIRP_SHA=f43e68b60b580647574ec4a0e2b6c600a56281e6c39f79426510832dc810f483
mkdir -p "$SRC" "$WORK" "$OUT"

fetch() {
  local name="$1" url="$2" expected="$3" file="$SRC/$1"
  if [[ ! -f "$file" ]]; then curl --fail --location --retry 3 "$url" --output "$file"; fi
  echo "$expected  $file" | shasum -a 256 --check --status || {
    echo "Checksum mismatch for $file" >&2; rm -f "$file"; exit 1;
  }
}
fetch "pcre2-$PCRE_VERSION.tar.gz" "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz" "$PCRE_SHA"
fetch "glib-$GLIB_VERSION.tar.xz" "https://download.gnome.org/sources/glib/${GLIB_VERSION%.*}/glib-$GLIB_VERSION.tar.xz" "$GLIB_SHA"
fetch "libslirp-$SLIRP_VERSION.tar.gz" "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VERSION/libslirp-v$SLIRP_VERSION.tar.gz" "$SLIRP_SHA"

mkdir -p "$SRC/pcre2" "$SRC/glib" "$SRC/libslirp"
tar -xf "$SRC/pcre2-$PCRE_VERSION.tar.gz" -C "$SRC/pcre2" --strip-components=1
tar -xf "$SRC/glib-$GLIB_VERSION.tar.xz" -C "$SRC/glib" --strip-components=1
tar -xf "$SRC/libslirp-$SLIRP_VERSION.tar.gz" -C "$SRC/libslirp" --strip-components=1

build_slice() {
  local platform="$1" sdk="$2" triple="$3" sdkroot="$4"
  local prefix="$OUT/$platform" build="$WORK/$platform"
  local subsystem=ios
  [[ "$sdk" == macosx ]] && subsystem=macos
  mkdir -p "$prefix" "$build"
  cat > "$build/apple-cross.ini" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$sdk', 'clang', '-target', '$triple', '-isysroot', '$sdkroot']
cpp = ['xcrun', '--sdk', '$sdk', 'clang++', '-target', '$triple', '-isysroot', '$sdkroot']
ar = ['xcrun', '--sdk', '$sdk', 'ar']
strip = ['xcrun', '--sdk', '$sdk', 'strip']
pkg-config = 'pkg-config'

[host_machine]
system = 'darwin'
subsystem = '$subsystem'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$sdkroot'
EOF
  export SDKROOT="$sdkroot" CC="xcrun --sdk $sdk clang -target $triple -isysroot $sdkroot" CXX="xcrun --sdk $sdk clang++ -target $triple -isysroot $sdkroot"
  export CFLAGS="-O2 -fPIC -arch arm64 -target $triple -isysroot $sdkroot"
  export CXXFLAGS="$CFLAGS" LDFLAGS="-arch arm64 -target $triple -isysroot $sdkroot"

  local cmake_system=iOS
  [[ "$sdk" == macosx ]] && cmake_system=Darwin
  cmake -S "$SRC/pcre2" -B "$build/pcre2" -G Ninja \
    -DCMAKE_SYSTEM_NAME="$cmake_system" -DCMAKE_OSX_SYSROOT="$sdkroot" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DBUILD_SHARED_LIBS=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  cmake --build "$build/pcre2" --target install

  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  meson setup "$build/glib" "$SRC/glib" --cross-file "$build/apple-cross.ini" --prefix "$prefix" \
    --default-library=static --buildtype=release -Dtests=false -Dinstalled_tests=false \
    -Dintrospection=disabled -Ddocumentation=false -Dnls=disabled -Dlibmount=disabled \
    -Dselinux=disabled -Dlibelf=disabled -Dman-pages=disabled -Dsysprof=disabled
  meson compile -C "$build/glib"
  meson install -C "$build/glib"

  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  meson setup "$build/slirp" "$SRC/libslirp" --cross-file "$build/apple-cross.ini" --prefix "$prefix" \
    --default-library=static --buildtype=release -Dtests=false
  meson compile -C "$build/slirp"
  meson install -C "$build/slirp"
}

build_slice iphoneos iphoneos arm64-apple-ios26.0 "$(xcrun --sdk iphoneos --show-sdk-path)"
build_slice iphonesimulator iphonesimulator arm64-apple-ios26.0-simulator "$(xcrun --sdk iphonesimulator --show-sdk-path)"
build_slice macosx macosx arm64-apple-macosx26.0 "$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "$OUT/THIRD_PARTY_LICENSES"
cp "$SRC/pcre2/LICENCE" "$OUT/THIRD_PARTY_LICENSES/PCRE2-LICENCE"
cp "$SRC/glib/COPYING" "$OUT/THIRD_PARTY_LICENSES/GLib-COPYING"
cp "$SRC/libslirp/COPYING" "$OUT/THIRD_PARTY_LICENSES/libslirp-COPYING"

echo "Static Apple networking dependencies installed under $OUT/{iphoneos,iphonesimulator,macosx}."
echo "License notices are in $OUT/THIRD_PARTY_LICENSES; include them in distributed app builds."
