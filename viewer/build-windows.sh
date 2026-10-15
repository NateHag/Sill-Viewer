#!/bin/bash
# Cross-compiles Sill Viewer for Windows (x86_64) on Linux, with MinGW, and packs a zip with the
# FFmpeg DLLs. Needs: mingw-w64, mingw-w64-tools, clang, the Rust target x86_64-pc-windows-gnu, and
# FFMPEG_WIN: a folder with include/ (FFmpeg 8 or 9 headers), lib/ (import libraries) and dlls/.
set -e
cd "$(dirname "$0")"
: "${FFMPEG_WIN:?set FFMPEG_WIN}"
export FFMPEG_DIR="$FFMPEG_WIN"
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
export CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
export AR_x86_64_pc_windows_gnu=x86_64-w64-mingw32-ar
# FFmpeg's D3D11/D3D12 headers include d3d12video.h (MinGW has none) and headers that pull in
# windows.h and its AMX types, which Rust cannot bind. The crate defines the few types it needs
# itself, so empty files are enough. Only the bindings see these; the program is built as usual.
STUBS="$PWD/target/win-stubs"; mkdir -p "$STUBS"; for h in d3d11.h d3d12.h d3d12sdklayers.h d3d12video.h initguid.h; do : > "$STUBS/$h"; done
export BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu="--target=x86_64-w64-mingw32 -I$STUBS -I/usr/x86_64-w64-mingw32/include"
export WINEPATH="$FFMPEG_WIN/dlls" WINEDEBUG=-all
cargo build --release --target x86_64-pc-windows-gnu
OUT=target/SillViewer-windows
rm -rf "$OUT" && mkdir -p "$OUT"
cp target/x86_64-pc-windows-gnu/release/sill-viewer.exe "$OUT/Sill Viewer.exe"
cp "$FFMPEG_WIN"/dlls/*.dll "$OUT/"
for d in libgcc_s_seh-1.dll libwinpthread-1.dll; do
    f=$(x86_64-w64-mingw32-gcc -print-file-name=$d); [ -f "$f" ] && cp "$f" "$OUT/" || true
done
cp README.md "$OUT/README.txt"
(cd target && rm -f SillViewer-windows.zip && zip -qr SillViewer-windows.zip SillViewer-windows)
echo "built target/SillViewer-windows.zip"
