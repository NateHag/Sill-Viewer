#!/bin/bash
# Installs the display watchdog: restarts GDM when the GNOME desktop is stuck with a black monitor.
#   install.sh             install and start it (asks for your password)
#   install.sh --dry-run   install it so it only logs what it would do
#   install.sh --uninstall remove it
# Log: journalctl -u sill-display-watchdog
set -eu
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall" ]; then
    sudo systemctl disable --now sill-display-watchdog 2>/dev/null || true
    sudo rm -f /etc/systemd/system/sill-display-watchdog.service /usr/local/sbin/sill-display-watchdog
    sudo rm -rf /var/lib/sill-display-watchdog
    sudo systemctl daemon-reload
    echo "The display watchdog is removed."
    exit 0
fi
args=""
[ "${1:-}" = "--dry-run" ] && args=" --dry-run"

sudo install -m 755 sill-display-watchdog /usr/local/sbin/sill-display-watchdog
sudo tee /etc/systemd/system/sill-display-watchdog.service >/dev/null <<EOF
[Unit]
Description=Sill display watchdog: restart GDM when the GNOME desktop is stuck (black monitor)
After=gdm.service

[Service]
ExecStart=/usr/local/sbin/sill-display-watchdog$args
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable sill-display-watchdog
sudo systemctl restart sill-display-watchdog
echo "The display watchdog is running${args}. Log: journalctl -u sill-display-watchdog"
