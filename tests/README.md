# Tests

bats-core tests for `bin/sudo-watch.sh` and `bin/sudo-watchctl`. Inert for
anyone who installs the plugin — nothing in `manifest.json` or
`Service.qml` references this directory.

```sh
sudo pacman -S --needed bats bats-assert bats-support bats-file kcov jq
bats tests/                 # run the suite
./tests/coverage.sh         # run under kcov, report line coverage for bin/
```

- `sudo-watch.bats` / `sudo-watchctl.bats` — source the scripts and call
  their functions (`poll_once`, `main`, etc.) directly, rather than
  running them as subprocesses. This is required for kcov to trace them
  reliably (see below), and also makes the daemon's tracking-array state
  directly inspectable between calls.
- `sudo-watch-lock.bats` / `sudo-watchctl-integration.bats` — a handful of
  real-subprocess runs to exercise the pieces that only exist when the
  script is actually executed (the `main()` lock-acquisition path, and the
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]` entry guard itself).
- `test_helper.bash` — stubs external commands (`pgrep`, `ps`, `notify-send`,
  `paplay`, `systemctl`) on a per-test `PATH` so tests don't touch the real
  system.

## A known kcov limitation

`tests/coverage.sh` only gates on `bin/sudo-watch.sh`'s line coverage.
kcov (v43) traces that file reliably, but noticeably undercounts
`bin/sudo-watchctl` (~39% reported vs. every branch actually being
exercised) — its `case`-statement dispatch with nested `if`s appears to
confuse kcov's bash instrumentation. This was confirmed with an isolated
throwaway script of the same shape (sourced, `case`-dispatched, called via
a function), which kcov also misreported despite guaranteed execution of
every line.

So for `sudo-watchctl`, coverage confidence comes from the 44 passing
tests plus a manual line-by-line audit (every get/set/validate path for
every subcommand, every `status` branch, help, and the unknown-command
path all have a corresponding test) — not from kcov's percentage.
