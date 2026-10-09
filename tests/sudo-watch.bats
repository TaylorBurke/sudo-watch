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

@test "load_config: never executes the config file" {
	local marker="$BATS_TEST_TMPDIR/pwned"
	{
		echo "SUDO_WATCH_VOLUME=\$(touch $marker)"
		echo "\$(touch $marker)"
		echo "touch $marker"
		echo "SUDO_WATCH_ALERT_THRESHOLD=7; touch $marker"
		echo "SUDO_WATCH_REPEAT_INTERVAL=\`touch $marker\`"
	} >"$SUDO_WATCH_CONFIG"
	load_config
	[ ! -e "$marker" ]
	[ "$VOLUME_PERCENT" = "100" ]
	[ "$ALERT_THRESHOLD" = "20" ]
	[ "$REPEAT_INTERVAL" = "10" ]
}

@test "load_config: ignores keys outside the SUDO_WATCH_ namespace" {
	printf 'PATH=/nonexistent\nSUDO_WATCH_VOLUME=60\n' >"$SUDO_WATCH_CONFIG"
	local before="$PATH"
	load_config
	[ "$PATH" = "$before" ]
	[ "$VOLUME_PERCENT" = "60" ]
}

@test "load_config: non-numeric or oversized numbers fall back to defaults" {
	printf 'SUDO_WATCH_VOLUME=loud\nSUDO_WATCH_VOLUME_MAX=99999999999999999999\nSUDO_WATCH_POLL_INTERVAL=0\n' >"$SUDO_WATCH_CONFIG"
	load_config
	[ "$VOLUME_PERCENT" = "100" ]
	[ "$VOLUME_MAX" = "150" ]
	[ "$POLL_INTERVAL" = "2" ]
}

@test "load_config: strips surrounding quotes and CRLF endings" {
	printf 'SUDO_WATCH_VOLUME="70"\r\nSUDO_WATCH_SOUND='"'"'/x y.oga'"'"'\r\n' >"$SUDO_WATCH_CONFIG"
	load_config
	[ "$VOLUME_PERCENT" = "70" ]
	[ "$SOUND" = "/x y.oga" ]
}

@test "load_config: rejects a poll interval beyond one hour" {
	printf 'SUDO_WATCH_POLL_INTERVAL=999999999\n' >"$SUDO_WATCH_CONFIG"
	load_config
	[ "$POLL_INTERVAL" = "2" ]
}

@test "send_alert: clamps volume to a hard ceiling regardless of config" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub notify-send <<'SH'
#!/usr/bin/env bash
exit 0
SH
	stub paplay <<SH
#!/usr/bin/env bash
echo "\$@" >> "$log"
SH
	SOUND="$BATS_TEST_TMPDIR/s.oga"; : > "$SOUND"
	VOLUME_PERCENT=999999999; VOLUME_ESCALATE=0
	send_alert 99 sudo 5 1
	sleep 0.3
	[[ "$(cat "$log")" == "--volume=327680"* ]]
}

@test "load_config: environment applies when the config lacks the key" {
	SUDO_WATCH_VOLUME=42 load_config
	[ "$VOLUME_PERCENT" = "42" ]
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

@test "send_alert: ends option parsing and escapes markup in the process command" {
	local log="$BATS_TEST_TMPDIR/notify.log"
	stub notify-send <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
SH
	SOUND=/nonexistent
	send_alert 99 'sudo <b>x</b> & --hint=string:x:y' 5 1
	grep -qx -- '--' "$log"
	grep -q 'sudo &lt;b&gt;x&lt;/b&gt; &amp; --hint=string:x:y' "$log"
	! grep -q '<b>' "$log"
}

@test "send_alert: passes the sound path after -- so a leading dash isn't an option" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub notify-send <<'SH'
#!/usr/bin/env bash
exit 0
SH
	stub paplay <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$log"
SH
	cd "$BATS_TEST_TMPDIR"
	: > ./-evil.oga
	SOUND="./-evil.oga"
	send_alert 99 sudo 5 1
	sleep 0.3
	[ "$(sed -n 2p "$log")" = "--" ]
}

@test "poll_once: stops alerting after MAX_ALERTS (default 10) for one prompt" {
	pgrep_pending_4242
	local notify_log="$BATS_TEST_TMPDIR/notify.log"
	stub notify-send <<SH
#!/usr/bin/env bash
echo x >> "$notify_log"
SH
	SOUND=/nonexistent
	poll_once                      # t=1000 first seen
	for i in $(seq 1 15); do
		FAKE_NOW=$((1021 + (i - 1) * 11))
		poll_once
	done
	[ "$(wc -l <"$notify_log")" -eq 10 ]
	[ "${alert_count[4242]}" = "10" ]
}

@test "poll_once: MAX_ALERTS=0 means unlimited" {
	pgrep_pending_4242
	local notify_log="$BATS_TEST_TMPDIR/notify.log"
	stub notify-send <<SH
#!/usr/bin/env bash
echo x >> "$notify_log"
SH
	SOUND=/nonexistent
	MAX_ALERTS=0
	poll_once
	for i in $(seq 1 15); do
		FAKE_NOW=$((1021 + (i - 1) * 11))
		poll_once
	done
	[ "$(wc -l <"$notify_log")" -eq 15 ]
}

@test "load_config: MAX_ALERTS defaults to 10 and reads the config" {
	[ "$MAX_ALERTS" = "10" ]
	printf 'SUDO_WATCH_MAX_ALERTS=0\n' >"$SUDO_WATCH_CONFIG"
	load_config
	[ "$MAX_ALERTS" = "0" ]
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
