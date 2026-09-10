#!/usr/bin/env bash
# Installs sudo-watch as a systemd --user service and puts sudo-watchctl
# on PATH, using whatever directory this repo was cloned into.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/bin"

sed "s|__SUDO_WATCH_DIR__|$REPO_DIR|g" \
	"$REPO_DIR/systemd/sudo-watch.service" \
	> "$HOME/.config/systemd/user/sudo-watch.service"

ln -sf "$REPO_DIR/bin/sudo-watchctl" "$HOME/.local/bin/sudo-watchctl"

systemctl --user daemon-reload
systemctl --user enable --now sudo-watch.service

echo "Installed. Run 'sudo-watchctl status' to verify."
