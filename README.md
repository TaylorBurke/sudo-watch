# sudo-watch

Background daemon that watches for `sudo`/`pkexec` processes stuck waiting
on a password prompt. If one goes unanswered for 20 seconds, it fires a
desktop notification and plays a sound, repeating every 10 seconds until
you respond, the process goes away, or the per-prompt alert limit is
reached (10 by default, or unlimited if you prefer).

## How it works

Every 2 seconds it polls for `sudo`/`pkexec` processes. A process counts as
"waiting for a password" if it has no child process yet — once you enter
your password, sudo execs the target command, so a child appearing means
it's resolved. This avoids false positives for cached-credential or
`NOPASSWD` sudo calls, since those spawn a child almost immediately.

Alerts are counted per waiting prompt. After `SUDO_WATCH_MAX_ALERTS` of
them (default 10) that prompt goes quiet; a new `sudo` starts a fresh
count. Set it to `0` or run `sudo-watchctl max-alerts unlimited` to keep
alerting until you respond.

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

## Bar widget (Omarchy plugin install)

The plugin also provides a bar widget: a lock icon that dims when the
watcher isn't running. Hover for the watcher's status; click to open a popup
with:

- alert volume, plus the escalation toggle (with step and cap)
- first-alert and repeat timers
- the maximum number of alerts per waiting prompt (`0` = unlimited)
- a test-sound button

Turn the widget on or off from the command line:

```sh
sudo-watchctl widget            # on / off
sudo-watchctl widget on         # add it to the right side of the bar
sudo-watchctl widget off        # remove it from the bar
```

`widget off` only removes the icon. The watcher keeps running and alerting;
it does **not** disable the plugin (which would also stop the alerts). Before
changing `~/.config/omarchy/shell.json` it saves a backup next to it
(`shell.json.bak.sudo-watch-<timestamp>`), and it only ever removes this
widget's entry, and remembers where the icon was (in
`~/.config/sudo-watch/widget-position.json`) so `widget on` puts it back in
the same spot, falling back to the end of the right side if that spot is
gone. (It edits the layout itself rather than calling `omarchy bar put`,
which does nothing for a plugin that is also listed under `plugins`.) You can
move it afterwards with `omarchy bar move taylorburke.sudo-watch --section
center`, or add it from Omarchy's bar settings.

The widget has no logic of its own: every control runs `sudo-watchctl` with
an argument list (no shell), passing only bounded integers or `on`/`off`, so
the CLI remains the single place that validates and writes the config.

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
sudo-watchctl max-alerts 10       # stop after this many alerts per prompt
sudo-watchctl max-alerts unlimited  # ...or never stop (same as 0)
sudo-watchctl widget on|off       # add/remove the bar widget (see above)
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
| `SUDO_WATCH_MAX_ALERTS` | `10` | Alerts per waiting prompt before they stop; `0` = unlimited |
| `SUDO_WATCH_SOUND` | `/usr/share/sounds/freedesktop/stereo/dialog-warning.oga` | Alert sound file |
| `SUDO_WATCH_VOLUME` | `100` | Base alert volume, as a percent |
| `SUDO_WATCH_VOLUME_ESCALATE` | `0` | `1` ramps volume up on repeat alerts, `0` keeps it flat |
| `SUDO_WATCH_VOLUME_STEP` | `10` | Percent added per repeat alert while escalating |
| `SUDO_WATCH_VOLUME_MAX` | `150` | Volume cap while escalating |
| `SUDO_WATCH_CONFIG` | `~/.config/sudo-watch/config` | Path to the config file itself |
| `SUDO_WATCH_LOCK` | `$XDG_RUNTIME_DIR/sudo-watch.lock` (falls back to `~/.cache` if unset) | Path to the single-instance lock file |

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

## Testing

Tests live in `tests/` (bats-core) and are inert for anyone who installs
the plugin — nothing in `manifest.json` or `Service.qml` references them,
so they never run outside development.

```sh
sudo pacman -S --needed bats bats-assert bats-support bats-file kcov jq
bats tests/                 # run the suite
./tests/coverage.sh         # run under kcov, report line coverage for bin/
```

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
