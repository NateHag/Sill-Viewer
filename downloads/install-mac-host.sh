#!/bin/bash
# Installs the ready-made Sill Desktop Host (downloads/SillDesktopHost-mac.zip) on a Mac that cannot
# build it (no Xcode). Run from anywhere: ~/Sill-Viewer/downloads/install-mac-host.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
zip="$here/SillDesktopHost-mac.zip"
[ -f "$zip" ] || { echo "error: $zip is missing; run git pull" >&2; exit 1; }
tmp="$(mktemp -d)"
ditto -x -k "$zip" "$tmp"
# Quit the running host (this one, or Sill.app): two hosts would both answer as this Mac.
for pat in 'SillDesktopHost\.app/Contents/MacOS/SillDesktopHost' 'Sill\.app/Contents/MacOS/Sill$'; do
    if pgrep -f "$pat" >/dev/null; then
        pkill -TERM -f "$pat" || true
        for _ in $(seq 1 50); do pgrep -f "$pat" >/dev/null || break; sleep 0.1; done
    fi
done
rm -rf /Applications/SillDesktopHost.app
ditto "$tmp/SillDesktopHost.app" /Applications/SillDesktopHost.app
rm -rf "$tmp"
xattr -dr com.apple.quarantine /Applications/SillDesktopHost.app 2>/dev/null || true
echo "Installed /Applications/SillDesktopHost.app, signed by: $(codesign -dv --verbose=2 /Applications/SillDesktopHost.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
open /Applications/SillDesktopHost.app
