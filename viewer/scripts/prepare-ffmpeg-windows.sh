#!/bin/bash
# Prepares FFmpeg for cross-compiling the viewer to Windows on Linux (Ubuntu 24.04):
#   - the FFmpeg 8 DLLs from PyAV's Windows wheel (PyPI),
#   - the matching FFmpeg headers (n8.1.3 source, headers only),
#   - MinGW import libraries made from the DLLs (gendef + dlltool), so the program imports the
#     DLLs under their own names.
# Output: $1 (default ./ffmpeg-win) with include/, lib/ and dlls/. Then:
#   FFMPEG_WIN=$1 ./build-windows.sh
# Needs: python3-pip, git, mingw-w64, mingw-w64-tools, make, and Wine registered for .exe files
# (the FFmpeg Rust crate runs a small test program while it builds).
set -e
OUT=$(realpath -m "${1:-ffmpeg-win}")
WORK=$(mktemp -d)
mkdir -p "$OUT/lib" "$OUT/dlls"

python3 -m pip download "av==18.0.0" --platform win_amd64 --only-binary=:all: --no-deps -q -d "$WORK"
(cd "$WORK" && unzip -o -q av-*.whl 'av.libs/*')
cp "$WORK"/av.libs/*.dll "$OUT/dlls/"

git clone -q --depth 1 --branch n8.1.3 https://github.com/FFmpeg/FFmpeg "$WORK/ffmpeg"
(cd "$WORK/ffmpeg" && ./configure --prefix="$OUT" --enable-cross-compile --target-os=mingw32 --arch=x86_64 \
    --cross-prefix=x86_64-w64-mingw32- --disable-x86asm --disable-programs --disable-doc --enable-shared \
    --disable-static > /dev/null && make install-headers > /dev/null)

cd "$OUT/lib"
for lib in avcodec avdevice avfilter avformat avutil swresample swscale; do
    dll=$(ls "$OUT"/dlls/$lib-[0-9]*.dll)
    gendef - "$dll" > $lib.def 2>/dev/null
    x86_64-w64-mingw32-dlltool -d $lib.def -l lib$lib.dll.a -D "$(basename "$dll")"
done
rm -rf "$WORK"
echo "FFmpeg for Windows is ready in $OUT"
