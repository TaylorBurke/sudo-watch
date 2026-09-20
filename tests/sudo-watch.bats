#!/usr/bin/env bats
# Tests for the watcher's logic functions (is_pending, load_config,
# send_alert, poll_once). Sourced rather than run as a subprocess so
# tests can call functions directly and inspect the tracking arrays;
# `main`'s lock-acquisition and outer loop are covered separately in
# tests/sudo-watch-lock.bats via real subprocess runs.

load 'test_helper'

SUDO_WATCH_SCRIPT="${BATS_TEST_DIRNAME}/../bin/sudo-watch.sh"

setup() {
	load_stub_dir
	export SUDO_WATCH_CONFIG="$BATS_TEST_TMPDIR/config"
	export SUDO_WATCH_LOCK="$BATS_TEST_TMPDIR/lock"

	# Silence side-effecting commands until a test stubs its own behavior.
	stub notify-send <<'SH'
#!/usr/bin/env bash
exit 0
SH
	stub paplay <<'SH'
#!/usr/bin/env bash
exit 0
SH
	stub ps <<'SH'
#!/usr/bin/env bash
echo "sudo apt upgrade"
SH

	source "$SUDO_WATCH_SCRIPT"

	# Deterministic clock: tests move time forward by setting FAKE_NOW.
	FAKE_NOW=1000
	now() { echo "$FAKE_NOW"; }

	load_config
}

# --- is_pending ---------------------------------------------------------

@test "is_pending: true when pgrep finds no child" {
	stub pgrep <<'SH'
#!/usr/bin/env bash
true
SH
	run is_pending 1234
	[ "$status" -eq 0 ]
}

@test "is_pending: false when pgrep finds a child" {
	stub pgrep <<'SH'
#!/usr/bin/env bash
echo 5678
SH
	run is_pending 1234
	[ "$status" -eq 1 ]
}

# --- load_config ---------------------------------------------------------

@test "load_config: applies defaults when unset" {
	[ "$POLL_INTERVAL" = "2" ]
	[ "$ALERT_THRESHOLD" = "20" ]
	[ "$REPEAT_INTERVAL" = "10" ]
	[ "$VOLUME_PERCENT" = "100" ]
	[ "$VOLUME_ESCALATE" = "0" ]
	[ "$VOLUME_STEP" = "10" ]
	[ "$VOLUME_MAX" = "150" ]
}

@test "load_config: reads overrides from the config file" {
	cat >"$SUDO_WATCH_CONFIG" <<'EOF'
SUDO_WATCH_VOLUME=60
SUDO_WATCH_ALERT_THRESHOLD=5
EOF
	load_config
	[ "$VOLUME_PERCENT" = "60" ]
	[ "$ALERT_THRESHOLD" = "5" ]
}

# --- send_alert ------------------------------------------------------------

@test "send_alert: uses base volume when escalation is off" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub paplay <<SH
#!/usr/bin/env bash
echo "\$@" >> "$log"
SH
	SOUND="$BATS_TEST_TMPDIR/sound.oga"
	: >"$SOUND"

	send_alert 111 "sudo ls" 25 1
	wait

	[[ "$(cat "$log")" == "--volume=65536"* ]]
}

@test "send_alert: escalates volume per repeat, capped at VOLUME_MAX" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub paplay <<SH
#!/usr/bin/env bash
echo "\$@" >> "$log"
SH
	VOLUME_ESCALATE=1
	VOLUME_PERCENT=100
	VOLUME_STEP=20
	VOLUME_MAX=130
	SOUND="$BATS_TEST_TMPDIR/sound.oga"
	: >"$SOUND"

	send_alert 111 "sudo ls" 25 1 # 100 + 20*0 = 100
	wait
	send_alert 111 "sudo ls" 35 2 # 100 + 20*1 = 120
	wait
	send_alert 111 "sudo ls" 45 3 # 100 + 20*2 = 140 -> capped at 130
	wait

	mapfile -t lines <"$log"
	[[ "${lines[0]}" == "--volume=65536"* ]]
	[[ "${lines[1]}" == "--volume=$((120 * 65536 / 100))"* ]]
	[[ "${lines[2]}" == "--volume=$((130 * 65536 / 100))"* ]]
}

@test "send_alert: skips playback when the sound file is missing" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub paplay <<SH
#!/usr/bin/env bash
echo called >> "$log"
SH
	SOUND="$BATS_TEST_TMPDIR/does-not-exist.oga"

	send_alert 111 "sudo ls" 25 1
	wait 2>/dev/null || true

	[ ! -f "$log" ]
}

# --- poll_once -------------------------------------------------------------

pgrep_pending_4242() {
	stub pgrep <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-x" ]] && { echo 4242; exit 0; }
[[ "$1" == "-P" ]] && exit 1
SH
}

@test "poll_once: no-op when no sudo/pkexec processes are running" {
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
	poll_once
	# Not `${#first_seen[@]}` directly: bash treats a never-populated
	# associative array as unbound under `set -u`, even though `${!arr[@]}`
	# (used here) doesn't hit that quirk.
	local keys=("${!first_seen[@]}")
	[ "${#keys[@]}" -eq 0 ]
}

@test "poll_once: ignores a pid that already has a child" {
	stub pgrep <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-x" ]] && { echo 4242; exit 0; }
[[ "$1" == "-P" ]] && { echo 9999; exit 0; }
SH
	poll_once
	[ -z "${first_seen[4242]:-}" ]
}

@test "poll_once: skips a pid whose cmdline can't be read" {
	pgrep_pending_4242
	stub ps <<'SH'
#!/usr/bin/env bash
exit 1
SH
	poll_once
	[ -z "${first_seen[4242]:-}" ]
}

@test "poll_once: tracks a pending pid but doesn't alert before the threshold" {
	pgrep_pending_4242
	local notify_log="$BATS_TEST_TMPDIR/notify.log"
	stub notify-send <<SH
#!/usr/bin/env bash
echo called >> "$notify_log"
SH

	poll_once

	[ "${first_seen[4242]}" = "1000" ]
	[ ! -f "$notify_log" ]
}

@test "poll_once: fires an alert once the threshold elapses, then respects the repeat interval" {
	pgrep_pending_4242
	local notify_log="$BATS_TEST_TMPDIR/notify.log"
	stub notify-send <<SH
#!/usr/bin/env bash
echo "\$*" >> "$notify_log"
SH

	poll_once # t=1000: first seen, no alert yet (threshold is 20s)

	FAKE_NOW=1021 # 21s later: past threshold, first alert
	poll_once
	[ "$(wc -l <"$notify_log")" -eq 1 ]
	[[ "$(cat "$notify_log")" == *"sudo apt upgrade"* ]]
	[ "${alert_count[4242]}" = "1" ]

	FAKE_NOW=1025 # only 4s after the alert: repeat interval (10s) not up
	poll_once
	[ "$(wc -l <"$notify_log")" -eq 1 ]

	FAKE_NOW=1032 # 11s after the alert: repeat interval elapsed
	poll_once
	[ "$(wc -l <"$notify_log")" -eq 2 ]
	[ "${alert_count[4242]}" = "2" ]
}

@test "poll_once: clears tracking once the process resolves (gets a child)" {
	pgrep_pending_4242
	poll_once
	[ -n "${first_seen[4242]:-}" ]

	stub pgrep <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-x" ]] && { echo 4242; exit 0; }
[[ "$1" == "-P" ]] && { echo 9999; exit 0; }
SH
	poll_once

	[ -z "${first_seen[4242]:-}" ]
	[ -z "${last_alert[4242]:-}" ]
	[ -z "${alert_count[4242]:-}" ]
}

@test "poll_once: clears tracking once the pid disappears" {
	pgrep_pending_4242
	poll_once
	[ -n "${first_seen[4242]:-}" ]

	stub pgrep <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-x" ]] && exit 1
SH
	poll_once

	[ -z "${first_seen[4242]:-}" ]
}
