#!/bin/bash
# Builds static FFmpeg libraries for the iPhone (ios) or the arm64 simulator (sim).
# Output: ffmpeg/<platform>/{include,lib}. Skips the build if the libraries exist (CI cache).
set -euo pipefail

PLAT="${1:?usage: build-ffmpeg.sh ios|sim}"
VER="n7.1.1"
ROOT="$(pwd)/ffmpeg"
OUT="$ROOT/$PLAT"

if [ -f "$OUT/lib/libavformat.a" ]; then
  echo "FFmpeg for $PLAT already built"
  exit 0
fi

mkdir -p "$ROOT/src"
if [ ! -d "$ROOT/src/FFmpeg" ]; then
  git clone --depth 1 --branch "$VER" https://github.com/FFmpeg/FFmpeg.git "$ROOT/src/FFmpeg"
fi

if [ "$PLAT" = ios ]; then
  SDK=iphoneos; MIN="-miphoneos-version-min=16.0"
else
  SDK=iphonesimulator; MIN="-mios-simulator-version-min=16.0"
fi
SYSROOT="$(xcrun -sdk $SDK --show-sdk-path)"

BUILD="$ROOT/build-$PLAT"
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD"

"$ROOT/src/FFmpeg/configure" \
  --prefix="$OUT" \
  --enable-cross-compile --target-os=darwin --arch=arm64 \
  --cc="xcrun -sdk $SDK clang" --sysroot="$SYSROOT" \
  --extra-cflags="-arch arm64 $MIN" --extra-ldflags="-arch arm64 $MIN" \
  --enable-static --disable-shared --enable-pic \
  --disable-programs --disable-doc --disable-debug \
  --disable-avdevice --disable-avfilter --disable-network \
  --disable-lzma --disable-sdl2 --disable-xlib --disable-securetransport \
  --disable-indevs --disable-outdevs --disable-hwaccels \
  --enable-videotoolbox --enable-audiotoolbox \
  --disable-encoders --enable-encoder=aac,h264_videotoolbox

make -j"$(sysctl -n hw.ncpu)"
make install
ls -la "$OUT/lib"
