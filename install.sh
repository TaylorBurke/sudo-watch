#!/usr/bin/env bash
# Installs sudo-watch as a systemd --user service and puts sudo-watchctl
# on PATH, using whatever directory this repo was cloned into.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/bin"

# The path is written into ExecStart=, where systemd splits on whitespace and
# expands %-specifiers, and it passes through a text substitution where
# characters like & and | are special. Allow-list the path instead of trying
# to escape for each layer, and refuse rather than emit a unit that runs
# something else.
if [[ ! "$REPO_DIR" =~ ^[A-Za-z0-9._/+@:,=-]+$ ]]; then
	echo "install.sh: refusing to install from '$REPO_DIR': path may only contain letters, digits and . _ / + @ : , = -" >&2
	exit 1
fi

sed "s|__SUDO_WATCH_DIR__|$REPO_DIR|g" \
	"$REPO_DIR/systemd/sudo-watch.service" \
	> "$HOME/.config/systemd/user/sudo-watch.service"

ln -sf "$REPO_DIR/bin/sudo-watchctl" "$HOME/.local/bin/sudo-watchctl"

systemctl --user daemon-reload
systemctl --user enable --now sudo-watch.service

echo "Installed. Run 'sudo-watchctl status' to verify."
