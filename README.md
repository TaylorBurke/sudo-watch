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

```sh
systemctl --user link ~/Work/dev/sudo-watch/systemd/sudo-watch.service
systemctl --user enable --now sudo-watch.service
```

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

- `SUDO_WATCH_POLL_INTERVAL` — poll frequency in seconds (default 2)
- `SUDO_WATCH_ALERT_THRESHOLD` — seconds before first alert (default 20)
- `SUDO_WATCH_REPEAT_INTERVAL` — seconds between repeat alerts (default 10)
- `SUDO_WATCH_SOUND` — path to the sound file to play (default freedesktop
  dialog-warning)
- `SUDO_WATCH_VOLUME` — base alert volume as a percent (default 100)
- `SUDO_WATCH_VOLUME_ESCALATE` — `1` to ramp volume up on repeat alerts,
  `0` to keep it flat (default 0)
- `SUDO_WATCH_VOLUME_STEP` — percent added per repeat alert when escalating
  (default 10)
- `SUDO_WATCH_VOLUME_MAX` — volume cap when escalating (default 150)

## Logs

```sh
journalctl --user -u sudo-watch.service -f
```
