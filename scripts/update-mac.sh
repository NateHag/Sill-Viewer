#!/bin/bash
# Updates this Mac's Sill Viewer and Sill Desktop Host from GitHub.
#
#   scripts/update-mac.sh             update what is installed, if GitHub has a newer version
#   scripts/update-mac.sh viewer      only Sill Viewer (its Update button runs this)
#   scripts/update-mac.sh host        only Sill Desktop Host
#   scripts/update-mac.sh --force     rebuild what is installed now, new or not
#   scripts/update-mac.sh --install   automatic updates: also every hour, and at login
#   scripts/update-mac.sh --uninstall no automatic updates
#
# Automatic updates are off unless --install turned them on. Each app carries its version (SillBuild
# in its Info.plist: the newest commit that changed its folder); an app is rebuilt when GitHub's
# newest commit for that folder is a different one.
#
# Settings (optional) in ~/.config/sill-update.conf, for example:
#   SILL_SIGN_IDENTITY=9D27156C1AC1D290E02566C43F80A92F18FCCC11
# The log is ~/Library/Logs/sill-update.log.
set -u
REPO="${SILL_UPDATE_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
# Run from a copy: git merge below may change this file, and bash reads a script while it runs.
if [ -z "${SILL_UPDATE_REPO:-}" ]; then
    copy="$(mktemp -t sill-update)" && cp "$0" "$copy" && SILL_UPDATE_REPO="$REPO" exec /bin/bash "$copy" "$@"
fi
LABEL=io.github.natehag.sill-update
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/sill-update.log"
AUTO="$HOME/.config/sill-update-auto"     # exists only when the user chose automatic updates
mkdir -p "$(dirname "$LOG")"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$PLIST" "$AUTO"
    echo "Automatic updates are off. Sill Viewer shows when an update is available."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    exit 0
fi
if [ "${1:-}" = "--install" ]; then
    mkdir -p "$(dirname "$AUTO")" && : > "$AUTO"
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
    echo "Automatic updates are on: every hour and at login. Log: $LOG"
    exit 0
fi

force=0; only=""
case "${1:-}" in
    --force) force=1 ;;
    viewer|host) only="$1" ;;
esac
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.cargo/bin:$PATH"
[ -f "$HOME/.config/sill-update.conf" ] && . "$HOME/.config/sill-update.conf"
export SILL_SIGN_IDENTITY="${SILL_SIGN_IDENTITY:-}"
[ -z "$SILL_SIGN_IDENTITY" ] && unset SILL_SIGN_IDENTITY
export SILL_NO_ZIP=1          # no downloads/ zip from these builds: the folder stays as GitHub has it
stamp() { date "+%Y-%m-%d %H:%M:%S"; }

# Automatic updates used to be on for everyone. Now they are a choice: a launchd job without that
# choice recorded is turned off (once), at the end of this run.
migrate=0
if [ ! -e "$AUTO" ] && [ -e "$PLIST" ]; then migrate=1; fi
finish() {
    if [ $migrate = 1 ]; then
        echo "$(stamp) automatic updates are now off by default; Sill Viewer shows when an update is available"
        echo "$(stamp)   to turn them on again: $REPO/scripts/update-mac.sh --install"
        rm -f "$PLIST"
        launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true   # last: it stops this job
    fi
    exit "${1:-0}"
}

cd "$REPO" || exit 1
old="$(git rev-parse HEAD)"
if ! git fetch -q origin main; then echo "$(stamp) no connection to GitHub; trying later"; finish 0; fi
new="$(git rev-parse origin/main)"
if [ "$old" != "$new" ]; then
    if ! git merge -q --ff-only origin/main; then
        echo "$(stamp) this copy has local changes; not updating (git status shows them)"
        finish 1
    fi
    echo "$(stamp) updated $old -> $new"
fi

# The version an app has, and the newest for its folder.
installed() { /usr/libexec/PlistBuddy -c "Print :SillBuild" "$1/Contents/Info.plist" 2>/dev/null || echo none; }
newest() { git log -1 --format=%H -- "$1"; }
wants() {   # wants <viewer|host> <app> <folder>
    [ -d "$2" ] || return 1
    [ -z "$only" ] || [ "$only" = "$1" ] || return 1
    [ $force = 1 ] || [ "$(installed "$2")" != "$(newest "$3")" ]
}

viewer_app="/Applications/Sill Viewer.app"
host_app="/Applications/SillDesktopHost.app"
if wants viewer "$viewer_app" viewer; then
    was_running=0; pgrep -x sill-viewer >/dev/null && was_running=1
    echo "$(stamp) building Sill Viewer ($(installed "$viewer_app" | cut -c1-7) -> $(newest viewer | cut -c1-7))"
    if (cd viewer && ./build-mac.sh); then
        echo "$(stamp) Sill Viewer installed"
        if [ $was_running = 1 ] || [ "$only" = viewer ]; then open "$viewer_app" 2>/dev/null || true; fi
    else
        echo "$(stamp) Sill Viewer build FAILED"
    fi
fi
if wants host "$host_app" mac-host; then
    # Sign with the certificate the installed host has: macOS ties Screen Recording, Accessibility
    # and Local Network to the signature, so a different one (or none) loses them all.
    signer="$(codesign -dv --verbose=2 "$host_app" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    ident="${SILL_SIGN_IDENTITY:-}"
    if [ -z "$ident" ] && [ -n "$signer" ]; then
        ident="$(security find-identity -v -p codesigning 2>/dev/null | awk -v a="\"$signer\"" 'index($0, a) { print $2; exit }')"
    fi
    if [ -z "$ident" ]; then
        echo "$(stamp) host NOT updated: no signing certificate in the keychain matches the installed host"
        echo "$(stamp)   (installed signer: ${signer:-none}); set SILL_SIGN_IDENTITY in ~/.config/sill-update.conf"
    else
        echo "$(stamp) building Sill Desktop Host ($(installed "$host_app" | cut -c1-7) -> $(newest mac-host | cut -c1-7)), signed by ${signer:-$ident}"
        if (cd mac-host && SILL_SIGN_IDENTITY="$ident" Scripts/make-app.sh --install --open); then
            echo "$(stamp) Sill Desktop Host installed"
        else
            echo "$(stamp) Sill Desktop Host build FAILED"
        fi
    fi
fi
# Sill's own app answers as this Mac too, and viewers may reach it instead of this host.
if [ -d "$host_app" ] && pgrep -f 'Sill\.app/Contents/MacOS/Sill$' >/dev/null; then
    pkill -f 'Sill\.app/Contents/MacOS/Sill$' || true
    echo "$(stamp) quit Sill.app (it hides this host); delete /Applications/Sill.app to stop it for good"
    open "$host_app" 2>/dev/null || true
fi
finish 0
