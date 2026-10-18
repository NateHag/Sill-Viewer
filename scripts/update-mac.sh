#!/bin/bash
# Keeps this Mac's Sill Viewer and Sill Desktop Host up to date with GitHub.
#
#   scripts/update-mac.sh             update what is installed, if GitHub has something new
#   scripts/update-mac.sh --force     rebuild what is installed now, new or not
#   scripts/update-mac.sh --install   also check every hour, and at login, from now on
#   scripts/update-mac.sh --uninstall stop the hourly check
#
# Settings (optional) in ~/.config/sill-update.conf, for example:
#   SILL_SIGN_IDENTITY=9D27156C1AC1D290E02566C43F80A92F18FCCC11
# The log is ~/Library/Logs/sill-update.log.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=io.github.natehag.sill-update
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/sill-update.log"
mkdir -p "$(dirname "$LOG")"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "The hourly update check is off."
    exit 0
fi
if [ "${1:-}" = "--install" ]; then
    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$REPO/scripts/update-mac.sh</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "This Mac now checks for updates every hour and at login. Log: $LOG"
    exit 0
fi

force=0; [ "${1:-}" = "--force" ] && force=1
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:$PATH"
[ -f "$HOME/.config/sill-update.conf" ] && . "$HOME/.config/sill-update.conf"
export SILL_SIGN_IDENTITY="${SILL_SIGN_IDENTITY:-}"
[ -z "$SILL_SIGN_IDENTITY" ] && unset SILL_SIGN_IDENTITY
export SILL_NO_ZIP=1          # no downloads/ zip from these builds: the folder stays as GitHub has it
stamp() { date "+%Y-%m-%d %H:%M:%S"; }

cd "$REPO" || exit 1
old="$(git rev-parse HEAD)"
if ! git fetch -q origin main; then echo "$(stamp) no connection to GitHub; trying later"; exit 0; fi
new="$(git rev-parse origin/main)"
if [ "$old" = "$new" ] && [ $force = 0 ]; then exit 0; fi
if [ "$old" != "$new" ]; then
    if ! git merge -q --ff-only origin/main; then
        echo "$(stamp) this copy has local changes; not updating (git status shows them)"
        exit 1
    fi
    echo "$(stamp) updated $old -> $new"
fi
changed="$(git diff --name-only "$old" "$new")"

viewer_app="/Applications/Sill Viewer.app"
host_app="/Applications/SillDesktopHost.app"
if [ -d "$viewer_app" ] && { [ $force = 1 ] || grep -q '^viewer/' <<<"$changed"; }; then
    echo "$(stamp) building Sill Viewer"
    if (cd viewer && ./build-mac.sh); then echo "$(stamp) Sill Viewer installed"; else echo "$(stamp) Sill Viewer build FAILED"; fi
fi
if [ -d "$host_app" ] && { [ $force = 1 ] || grep -q '^mac-host/' <<<"$changed"; }; then
    echo "$(stamp) building Sill Desktop Host"
    if (cd mac-host && Scripts/make-app.sh --install --open); then echo "$(stamp) Sill Desktop Host installed"
    else echo "$(stamp) Sill Desktop Host build FAILED"; fi
fi
# Sill's own app answers as this Mac too, and viewers may reach it instead of this host.
if [ -d "$host_app" ] && pgrep -f 'Sill\.app/Contents/MacOS/Sill$' >/dev/null; then
    pkill -f 'Sill\.app/Contents/MacOS/Sill$' || true
    echo "$(stamp) quit Sill.app (it hides this host); delete /Applications/Sill.app to stop it for good"
    open "$host_app" 2>/dev/null || true
fi
exit 0
