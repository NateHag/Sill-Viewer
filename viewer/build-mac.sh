#!/bin/bash
# Builds "Sill Viewer.app" on a Mac (Apple silicon or Intel).
# Installs what is missing: Homebrew's ffmpeg and pkg-config, and Rust (rustup).
set -e
cd "$(dirname "$0")"

if ! command -v brew >/dev/null; then
    echo "Homebrew is needed first: https://brew.sh"
    exit 1
fi
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
brew list pkg-config >/dev/null 2>&1 || brew install pkg-config
if ! command -v cargo >/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi

export PKG_CONFIG_PATH="$(brew --prefix ffmpeg)/lib/pkgconfig:$PKG_CONFIG_PATH"
cargo build --release

APP="target/Sill Viewer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp target/release/sill-viewer "$APP/Contents/MacOS/sill-viewer"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sill Viewer</string>
  <key>CFBundleDisplayName</key><string>Sill Viewer</string>
  <key>CFBundleIdentifier</key><string>local.sill.viewer</string>
  <key>CFBundleExecutable</key><string>sill-viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Sill Viewer finds and connects to computers on your network.</string>
  <key>NSBonjourServices</key><array><string>_sill._tcp</string></array>
</dict></plist>
EOF
codesign --force --deep -s - "$APP" 2>/dev/null || true
echo
echo "Built: $APP"
echo "Open it with:  open \"$APP\"   (or drag it to Applications)"
