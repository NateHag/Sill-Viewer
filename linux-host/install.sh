#!/bin/bash
# Installs Sill for Linux for this user: packages, the app, and a service that starts at login.
set -e
cd "$(dirname "$0")"

echo "==> Installing packages (asks for your password)"
sudo apt-get update -qq
sudo apt-get install -y \
    python3-gi python3-openssl python3-cryptography python3-zeroconf \
    gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-pipewire \
    libnotify-bin qrencode avahi-daemon iproute2 gir1.2-gtk-4.0 \
    gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1

echo "==> Installing the app"
APP="$HOME/.local/share/sill-linux/app"
rm -rf "$APP"
mkdir -p "$APP" "$HOME/.local/bin" "$HOME/.config/systemd/user"
cp -r sill_linux "$APP/"
cat > "$HOME/.local/bin/sill-linux" <<EOF
#!/bin/sh
PYTHONPATH="$APP" exec /usr/bin/python3 -m sill_linux "\$@"
EOF
chmod +x "$HOME/.local/bin/sill-linux"

cat > "$HOME/.config/systemd/user/sill-linux.service" <<'EOF'
[Unit]
Description=Sill host: stream this desktop to the Sill app on iPhone and iPad
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/sill-linux run
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

cat > "$HOME/.config/systemd/user/sill-linux-tray.service" <<'UNIT'
[Unit]
Description=Sill tray icon
After=graphical-session.target sill-linux.service
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/sill-linux tray
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
UNIT

echo "==> Checking this computer"
"$HOME/.local/bin/sill-linux" check || true

echo "==> Starting the service"
systemctl --user daemon-reload
systemctl --user enable sill-linux.service sill-linux-tray.service
systemctl --user restart sill-linux.service sill-linux-tray.service
sleep 2
systemctl --user --no-pager status sill-linux.service | head -5

echo "==> Updates"
echo "Sill shows when an update is available. You choose when to install it."
read -r -p "Install updates by themselves instead, every hour? [y/N] " a </dev/tty || a=n
case "$a" in [yY]*) ./update.sh --install ;; *) ./update.sh --setup ;; esac

echo "==> Display watchdog (restarts GDM if the desktop gets stuck on a black screen)"
display-watchdog/install.sh

echo
echo "Done. On your iPad, open Sill. Tap this computer. Then type the code from the notification."
echo "Log:  journalctl --user -u sill-linux -f"
