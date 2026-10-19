#!/bin/bash
# Packs downloads/sill-linux-host.tar.gz from linux-host/, with sill_linux/BUILD set to the newest
# commit that changed linux-host/. The host compares that with GitHub to show "Update available".
# Commit the changes to linux-host/ first, then run this, then commit the download.
set -e
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain -- linux-host)" ]; then
    echo "linux-host/ has changes that are not committed; commit them first" >&2
    exit 1
fi
build="$(git log -1 --format=%H -- linux-host)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
d="$tmp/sill-linux-host"
mkdir -p "$d"
cp -r linux-host/sill_linux linux-host/README.md linux-host/update.sh linux-host/install.sh "$d/"
mkdir -p "$d/display-watchdog"
cp linux-host/display-watchdog/sill-display-watchdog linux-host/display-watchdog/install.sh "$d/display-watchdog/"
find "$d" -name __pycache__ -prune -exec rm -rf {} +
echo "$build" > "$d/sill_linux/BUILD"
(cd "$tmp" && tar czf sill-linux-host.tar.gz --owner=0 --group=0 sill-linux-host)
cp "$tmp/sill-linux-host.tar.gz" downloads/
echo "packed downloads/sill-linux-host.tar.gz, version ${build:0:7}"
