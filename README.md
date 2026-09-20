# sudo-watch

Background daemon that watches for `sudo`/`pkexec` processes stuck waiting
on a password prompt. If one goes unanswered for 20 seconds, it fires a
desktop notification and plays a sound, repeating every 10 seconds until
you respond (or the process goes away).

## How it works

Every 2 seconds it polls for `sudo`/`pkexec` processes. A process counts as
"waiting for a password" if it has no child process yet — once you enter
your password, sudo execs the target command, so a child appearing means
it's resolved. This avoids false positives for cached-credential or
`NOPASSWD` sudo calls, since those spawn a child almost immediately.

## Install

### As an Omarchy plugin (Quickshell service)

```sh
omarchy plugin add https://github.com/TaylorBurke/sudo-watch.git --enable
```

This runs the watcher as a Quickshell-supervised `service` plugin inside
`omarchy-shell` — no systemd unit involved. This path doesn't put
`sudo-watchctl` on `PATH` for you, but it's just a config-file editor and
works regardless of which install runs the watcher, so you can still use it:

```sh
ln -s ~/.config/omarchy/plugins/taylorburke.sudo-watch/bin/sudo-watchctl ~/.local/bin/sudo-watchctl
```

(assumes `~/.local/bin` is on `PATH`, which it is by default on Omarchy).
Or hand-edit `~/.config/sudo-watch/config` directly — same effect.

### Standalone (systemd --user service)

```sh
git clone https://github.com/TaylorBurke/sudo-watch.git
cd sudo-watch
./install.sh
```

This templates the systemd unit with the path you cloned into (so it works
regardless of where that is), enables it, and symlinks `sudo-watchctl` into
`~/.local/bin`.

## Configure

Use `sudo-watchctl` (symlinked to `~/.local/bin`) to change settings without
hand-editing the config file. Changes take effect within one poll interval —
no service restart needed.

```sh
sudo-watchctl status              # show current settings + service state
sudo-watchctl volume 150          # set base alert volume to 150%
sudo-watchctl escalate on         # ramp volume up on repeat alerts
sudo-watchctl volume-step 10      # +10% per repeat alert while escalating
sudo-watchctl volume-max 150      # cap escalated volume at 150%
sudo-watchctl threshold 20        # seconds before the first alert
sudo-watchctl repeat 10           # seconds between repeat alerts
sudo-watchctl sound /path/to.oga  # alert sound file
sudo-watchctl test                # preview the current alert sound/volume
```

Settings live in `~/.config/sudo-watch/config` as `SUDO_WATCH_*=value` lines,
the same names as the environment variables below (which are still honored
for one-off overrides, e.g. during testing):

| Variable | Default | Meaning |
|---|---|---|
| `SUDO_WATCH_POLL_INTERVAL` | `2` | Poll frequency, in seconds |
| `SUDO_WATCH_ALERT_THRESHOLD` | `20` | Seconds waiting before the first alert |
| `SUDO_WATCH_REPEAT_INTERVAL` | `10` | Seconds between repeat alerts |
| `SUDO_WATCH_SOUND` | `/usr/share/sounds/freedesktop/stereo/dialog-warning.oga` | Alert sound file |
| `SUDO_WATCH_VOLUME` | `100` | Base alert volume, as a percent |
| `SUDO_WATCH_VOLUME_ESCALATE` | `0` | `1` ramps volume up on repeat alerts, `0` keeps it flat |
| `SUDO_WATCH_VOLUME_STEP` | `10` | Percent added per repeat alert while escalating |
| `SUDO_WATCH_VOLUME_MAX` | `150` | Volume cap while escalating |
| `SUDO_WATCH_CONFIG` | `~/.config/sudo-watch/config` | Path to the config file itself |
| `SUDO_WATCH_LOCK` | `$XDG_RUNTIME_DIR/sudo-watch.lock` (falls back to `/tmp` if unset) | Path to the single-instance lock file |

Volume here is a linear percentage passed straight to `paplay --volume`
(software gain), not perceived loudness, which is logarithmic — going from
100% to 150% is only about +3.5dB, and human hearing typically needs ~3dB to
reliably notice a change at all. The 10%-per-repeat default is barely
audible; if you want repeats to actually sound louder, use a step of 30% or
more (e.g. `sudo-watchctl volume-step 30`).

## Logs

Standalone (systemd) install:

```sh
journalctl --user -u sudo-watch.service -f
```

Omarchy plugin install (no dedicated systemd unit — it logs through
`omarchy-shell`):

```sh
journalctl --user -f | grep sudo-watch
```

`sudo-watchctl status` reports which one is actually running the watcher
(`active (systemd)` or `active (plugin)`), which matters if you've tried
both at different times.

## Remove

Omarchy plugin install:

```sh
omarchy plugin remove taylorburke.sudo-watch
```

Standalone install:

```sh
cd sudo-watch   # the directory you cloned into
./uninstall.sh
```

This stops and disables the systemd service and removes the
`sudo-watchctl` symlink. It leaves `~/.config/sudo-watch/config` in
place; the script prints the command to remove that too if you want a
clean slate.

## Porting to macOS

This is Linux-only as written — it leans on `/proc`-backed `pgrep`/`ps`,
freedesktop `notify-send`, PulseAudio/PipeWire's `paplay`, and a
`systemd --user` service. The core polling loop (`bin/sudo-watch.sh`)
translates fine; only three pieces need swapping:

- **Notifications** — replace the `notify-send` call in `send_alert()` with
  `osascript -e 'display notification "…" with title "…"'`, or use
  [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) for
  more control (custom sound, click-to-focus).
- **Sound** — replace `paplay --volume=… "$SOUND"` with `afplay -v <0-1>
  "$SOUND"` (note `afplay`'s volume is a 0–1 float, not a percent like
  `paplay`'s 0–65536 scale — you'll need to rescale `PAPLAY_VOLUME`
  accordingly). System sounds live under `/System/Library/Sounds/*.aiff`.
- **Service management** — swap the `systemd/sudo-watch.service` unit for a
  `launchd` `.plist` in `~/Library/LaunchAgents/`, loaded with
  `launchctl load -w`. `sudo-watchctl status`'s
  `systemctl --user is-active` check would become a `launchctl list | grep
  sudo-watch` check.

`is_pending()` (no child process yet ⇒ still waiting on a password) and the
`sudo-watchctl` config-file/live-reload design need no changes — `pgrep -P`
and `ps -o cmd=` behave the same on macOS.
