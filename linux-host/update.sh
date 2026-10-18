#!/bin/bash
# Keeps the Sill for Linux host up to date with GitHub. No password needed.
#
#   update.sh             update if GitHub has a newer host (restarts it only when its code changed)
#   update.sh --force     install the newest host now
#   update.sh --install   also check every hour, and at login, from now on
#   update.sh --uninstall stop the hourly check
# Log: journalctl --user -u sill-linux-update
set -eu
REPO=NateHag/Sill-Viewer
APP="$HOME/.local/share/sill-linux/app"
STATE="$HOME/.local/share/sill-linux/installed-commit"
UNIT="$HOME/.config/systemd/user"

if [ "${1:-}" = "--uninstall" ]; then
    systemctl --user disable --now sill-linux-update.timer 2>/dev/null || true
    rm -f "$UNIT/sill-linux-update.timer" "$UNIT/sill-linux-update.service"
    systemctl --user daemon-reload
    echo "The hourly update check is off."
    exit 0
fi
if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/.local/bin" "$UNIT"
    cp "$0" "$HOME/.local/bin/sill-linux-update" 2>/dev/null || true
    chmod +x "$HOME/.local/bin/sill-linux-update"
    cat > "$UNIT/sill-linux-update.service" <<U
[Unit]
Description=Update Sill for Linux from GitHub

[Service]
Type=oneshot
ExecStart=%h/.local/bin/sill-linux-update
U
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
    echo "This computer now checks for updates every hour. Log: journalctl --user -u sill-linux-update"
    exit 0
fi

force=0; [ "${1:-}" = "--force" ] && force=1
sha="$(curl -fsSL -H "Accept: application/vnd.github.sha" "https://api.github.com/repos/$REPO/commits/main")" || {
    echo "no connection to GitHub; trying later"; exit 0; }
case "$sha" in [0-9a-f]*) ;; *) echo "unexpected answer from GitHub"; exit 0 ;; esac
if [ "$sha" = "$(cat "$STATE" 2>/dev/null || true)" ] && [ $force = 0 ]; then exit 0; fi

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
