#!/bin/bash
# Updates the Sill for Linux host from GitHub. No password needed.
#
#   update.sh             update if GitHub has a newer host (restarts it only when its code changed)
#   update.sh --force     install the newest host now
#   update.sh --setup     install this updater (as sill-linux-update), so the tray's "Update now"
#                         and a viewer's "Update host" work. Nothing updates by itself.
#   update.sh --install   automatic updates: also update every hour, and at login
#   update.sh --uninstall no automatic updates (Update now still works)
# Automatic updates are off unless --install turned them on. Log: journalctl --user -u sill-linux-update
set -eu
REPO=NateHag/Sill-Viewer
APP="$HOME/.local/share/sill-linux/app"
STATE="$HOME/.local/share/sill-linux/installed-commit"
UNIT="$HOME/.config/systemd/user"
AUTO="$HOME/.config/sill-linux/auto-update"     # exists only when the user chose automatic updates

setup() {
    mkdir -p "$HOME/.local/bin" "$UNIT"
    [ "$(realpath "$0")" = "$(realpath -m "$HOME/.local/bin/sill-linux-update")" ] || cp "$0" "$HOME/.local/bin/sill-linux-update"
    chmod +x "$HOME/.local/bin/sill-linux-update"
    cat > "$UNIT/sill-linux-update.service" <<U
[Unit]
Description=Update Sill for Linux from GitHub

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sill-linux-update
U
    systemctl --user daemon-reload
}

auto_off() {
    systemctl --user disable --now sill-linux-update.timer 2>/dev/null || true
    rm -f "$UNIT/sill-linux-update.timer" "$AUTO"
    systemctl --user daemon-reload
}

if [ "${1:-}" = "--uninstall" ]; then
    auto_off
    echo "Automatic updates are off. The tray's Update now still works."
    exit 0
fi
if [ "${1:-}" = "--setup" ]; then
    setup
    echo "The updater is installed. Nothing updates by itself; Sill shows when an update is available."
    exit 0
fi
if [ "${1:-}" = "--install" ]; then
    setup
    mkdir -p "$(dirname "$AUTO")" && : > "$AUTO"
    cat > "$UNIT/sill-linux-update.timer" <<U
[Unit]
Description=Check for Sill for Linux updates every hour

[Timer]
OnStartupSec=2min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
U
    systemctl --user daemon-reload
    systemctl --user enable --now sill-linux-update.timer
    echo "Automatic updates are on: every hour. Turn them off: sill-linux-update --uninstall"
    exit 0
fi

# Automatic updates used to be on for everyone. Now they are a choice: a timer without that choice
# recorded is turned off (once), after this run's update.
migrate=0
if [ ! -e "$AUTO" ] && [ -e "$UNIT/sill-linux-update.timer" ]; then migrate=1; fi

force=0; [ "${1:-}" = "--force" ] && force=1
sha="$(curl -fsSL -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$REPO/commits/main")" || {
    echo "no connection to GitHub; trying later"; exit 0; }
case "$sha" in [0-9a-f]*) ;; *) echo "unexpected answer from GitHub"; exit 0 ;; esac
migrate_now() {
    [ $migrate = 1 ] || return 0
    auto_off
    echo "automatic updates are now off by default; Sill shows when an update is available."
    echo "to turn them on again: sill-linux-update --install"
}
if [ "$sha" = "$(cat "$STATE" 2>/dev/null || true)" ] && [ $force = 0 ]; then migrate_now; exit 0; fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# By commit, not by branch: GitHub's cache could hand out an older file for a few minutes.
curl -fsSL -o "$tmp/host.tar.gz" "https://raw.githubusercontent.com/$REPO/$sha/downloads/sill-linux-host.tar.gz"
tar xzf "$tmp/host.tar.gz" -C "$tmp"
new="$tmp/sill-linux-host"
[ -d "$new/sill_linux" ] || { echo "the download has no sill_linux folder"; exit 1; }
find "$new" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

if [ $force = 1 ] || ! diff -rq -x __pycache__ "$new/sill_linux" "$APP/sill_linux" >/dev/null 2>&1; then
    mkdir -p "$APP"
    rm -rf "$APP/sill_linux.new"
    cp -r "$new/sill_linux" "$APP/sill_linux.new"
    rm -rf "$APP/sill_linux"
    mv "$APP/sill_linux.new" "$APP/sill_linux"
    systemctl --user restart sill-linux 2>/dev/null || true
    echo "host updated to ${sha:0:7} and restarted"
else
    echo "GitHub moved to ${sha:0:7}; the host's code is the same, so it keeps running"
fi
# The updater updates itself too.
if [ -f "$new/update.sh" ] && [ -f "$HOME/.local/bin/sill-linux-update" ]; then
    cp "$new/update.sh" "$HOME/.local/bin/sill-linux-update.new" && chmod +x "$HOME/.local/bin/sill-linux-update.new" \
        && mv "$HOME/.local/bin/sill-linux-update.new" "$HOME/.local/bin/sill-linux-update"
fi
echo "$sha" > "$STATE"
migrate_now
