#!/bin/bash
# Builds "Sill Viewer.app" on a Mac (Apple silicon or Intel) and puts it in /Applications.
#
#   ./build-mac.sh                      build, sign for this Mac only, install
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build-mac.sh
#                                       sign with your Developer ID (runs on other Macs)
#   SIGN_ID=... NOTARY_PROFILE=sill ./build-mac.sh
#                                       also notarize (see "NOTARIZE" in README.md)
#   NO_INSTALL=1 ./build-mac.sh         build only: target/Sill Viewer.app
#
# Installs what is missing: Homebrew's ffmpeg, pkg-config and dylibbundler, and Rust (rustup).
# The app carries its own copy of the FFmpeg libraries, so it does not need Homebrew to run.
set -e
cd "$(dirname "$0")"

# A new Homebrew is not on the PATH until the shell restarts: look in its usual places.
if ! command -v brew >/dev/null; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
fi
if ! command -v brew >/dev/null; then
    echo "Homebrew is needed first: https://brew.sh"
    exit 1
fi
for f in ffmpeg pkg-config dylibbundler; do
    brew list "$f" >/dev/null 2>&1 || brew install "$f"
done
if ! command -v cargo >/dev/null; then
    [ -f "$HOME/.cargo/env" ] || curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

export PKG_CONFIG_PATH="$(brew --prefix ffmpeg)/lib/pkgconfig:$PKG_CONFIG_PATH"
cargo build --release

VERSION=$(grep -m1 '^version' Cargo.toml | cut -d'"' -f2)
APP="target/Sill Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp target/release/sill-viewer "$APP/Contents/MacOS/sill-viewer"
cp macos/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sill Viewer</string>
  <key>CFBundleDisplayName</key><string>Sill Viewer</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-io.github.natehag.sillviewer}</string>
  <key>CFBundleExecutable</key><string>sill-viewer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Sill Viewer finds and connects to computers on your network.</string>
  <key>NSBonjourServices</key><array><string>_sill._tcp</string></array>
</dict></plist>
EOF

# Copy the FFmpeg libraries (and what they need) into the app, and point the program at them.
dylibbundler -of -b -x "$APP/Contents/MacOS/sill-viewer" -d "$APP/Contents/Frameworks" \
    -p @executable_path/../Frameworks/ >/dev/null

# Sign: every library first, then the app. With SIGN_ID: hardened runtime and a timestamp, as
# notarization needs. Without: ad-hoc, which runs on this Mac only.
if [ -n "$SIGN_ID" ]; then
    SIGN=(--force --timestamp --options runtime -s "$SIGN_ID")
else
    SIGN=(--force -s -)
fi
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign "${SIGN[@]}" "$lib"
done
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    [ -n "$SIGN_ID" ] || { echo "NOTARY_PROFILE needs SIGN_ID"; exit 1; }
    ZIP="target/SillViewer-mac.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

# A zip to share (made after stapling, so it carries the ticket).
rm -f target/SillViewer-mac.zip
ditto -c -k --keepParent "$APP" target/SillViewer-mac.zip

echo
echo "Built: $APP"
if [ -z "$NO_INSTALL" ]; then
    pkill -x sill-viewer 2>/dev/null || true
    rm -rf "/Applications/Sill Viewer.app"
    ditto "$APP" "/Applications/Sill Viewer.app"
    echo "Installed: /Applications/Sill Viewer.app"
    # Only one Sill Viewer in Launchpad and Spotlight: forget and remove the build copy (the zip
    # in target/ keeps it for other Macs).
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$PWD/$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Open it from Launchpad, Spotlight (Cmd+Space, \"Sill Viewer\") or the Applications folder."
fi
