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

Environment variables (set via a systemd drop-in or edit the unit):

- `SUDO_WATCH_POLL_INTERVAL` — poll frequency in seconds (default 2)
- `SUDO_WATCH_ALERT_THRESHOLD` — seconds before first alert (default 20)
- `SUDO_WATCH_REPEAT_INTERVAL` — seconds between repeat alerts (default 10)
- `SUDO_WATCH_SOUND` — path to the sound file to play (default freedesktop
  dialog-warning)
- `SUDO_WATCH_VOLUME` — alert volume as a percent, e.g. `50` for half, `150`
  for 150% (default 100)

## Logs

```sh
journalctl --user -u sudo-watch.service -f
```
