#!/usr/bin/env bash
# Reverses install.sh: stops and disables the systemd --user service and
# removes the sudo-watchctl symlink from PATH. Leaves the cloned repo and
# ~/.config/sudo-watch/config in place.
set -euo pipefail

systemctl --user disable --now sudo-watch.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/sudo-watch.service"
rm -f "$HOME/.local/bin/sudo-watchctl"

systemctl --user daemon-reload

echo "Uninstalled. Config at ~/.config/sudo-watch/config was left in place."
echo "Remove it too with: rm -rf ~/.config/sudo-watch"
