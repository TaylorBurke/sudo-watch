#!/usr/bin/env bats
# Tests for bin/sudo-watchctl, the config CLI. Sourced (not run as a
# subprocess) so kcov can reliably trace it and so main() runs in-process;
# see tests/sudo-watch.bats for why (kcov/bats' `run` don't reliably trace
# many repeated subprocess exec()s of the same script).

load 'test_helper'

SUDO_WATCHCTL="${BATS_TEST_DIRNAME}/../bin/sudo-watchctl"

setup() {
	load_stub_dir
	export SUDO_WATCH_CONFIG="$BATS_TEST_TMPDIR/config"
	source "$SUDO_WATCHCTL"
}

# Collapses runs of spaces so status-output assertions don't depend on the
# exact column alignment used for display.
squeeze() {
	tr -s ' ' <<<"$1"
}

@test "volume: defaults to 100 when unset" {
	run main volume
	[ "$status" -eq 0 ]
	[ "$output" = "100" ]
}

@test "volume: sets and persists a value" {
	run main volume 75
	[ "$status" -eq 0 ]
	[[ "$output" == *"75%"* ]]
	run main volume
	[ "$output" = "75" ]
}

@test "volume: rejects non-numeric input" {
	run main volume abc
	[ "$status" -eq 1 ]
	[[ "$output" == *"must be a non-negative integer"* ]]
}

@test "volume: setting twice updates rather than duplicating the key" {
	main volume 50 >/dev/null
	main volume 60 >/dev/null
	[ "$(grep -c '^SUDO_WATCH_VOLUME=' "$SUDO_WATCH_CONFIG")" -eq 1 ]
	run main volume
	[ "$output" = "60" ]
}

@test "escalate: defaults to off" {
	run main escalate
	[ "$output" = "off" ]
}

@test "escalate: turns on and off" {
	run main escalate on
	[[ "$output" == *"on"* ]]
	run main escalate
	[ "$output" = "on" ]

	run main escalate off
	[[ "$output" == *"off"* ]]
	run main escalate
	[ "$output" = "off" ]
}

@test "escalate: rejects an invalid argument" {
	run main escalate maybe
	[ "$status" -eq 1 ]
	[[ "$output" == *"expects 'on' or 'off'"* ]]
}

@test "volume-step: gets the default and sets a new value" {
	run main volume-step
	[ "$output" = "10" ]
	run main volume-step 20
	[[ "$output" == *"20%"* ]]
	run main volume-step
	[ "$output" = "20" ]
}

@test "volume-step: rejects non-numeric input" {
	run main volume-step abc
	[ "$status" -eq 1 ]
}

@test "volume-max: gets the default and sets a new value" {
	run main volume-max
	[ "$output" = "150" ]
	run main volume-max 200
	[[ "$output" == *"200%"* ]]
	run main volume-max
	[ "$output" = "200" ]
}

@test "volume-max: rejects non-numeric input" {
	run main volume-max abc
	[ "$status" -eq 1 ]
}

@test "threshold: gets the default and sets a new value" {
	run main threshold
	[ "$output" = "20" ]
	run main threshold 30
	[[ "$output" == *"30s"* ]]
	run main threshold
	[ "$output" = "30" ]
}

@test "threshold: rejects non-numeric input" {
	run main threshold abc
	[ "$status" -eq 1 ]
}

@test "repeat: gets the default and sets a new value" {
	run main repeat
	[ "$output" = "10" ]
	run main repeat 15
	[[ "$output" == *"15s"* ]]
	run main repeat
	[ "$output" = "15" ]
}

@test "repeat: rejects non-numeric input" {
	run main repeat abc
	[ "$status" -eq 1 ]
}

@test "sound: defaults to the freedesktop sound" {
	run main sound
	[[ "$output" == *"dialog-warning.oga" ]]
}

@test "sound: sets to an existing file" {
	local f="$BATS_TEST_TMPDIR/beep.oga"
	: >"$f"
	run main sound "$f"
	[ "$status" -eq 0 ]
	run main sound
	[ "$output" = "$f" ]
}

@test "sound: rejects a nonexistent file" {
	run main sound /no/such/file
	[ "$status" -eq 1 ]
	[[ "$output" == *"no such file"* ]]
}

@test "status: reports escalation off and no active service" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
	run main status
	[ "$status" -eq 0 ]
	local squeezed
	squeezed="$(squeeze "$output")"
	[[ "$squeezed" == *"Escalate: off"* ]]
	[[ "$squeezed" == *"Service: not active"* ]]
}

@test "status: detects an active systemd service" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
[[ "$1" == "--user" && "$2" == "is-active" ]] && exit 0
exit 1
SH
	run main status
	local squeezed
	squeezed="$(squeeze "$output")"
	[[ "$squeezed" == *"Service: active (systemd)"* ]]
}

@test "status: falls back to detecting the plugin process" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 0
SH
	run main status
	local squeezed
	squeezed="$(squeeze "$output")"
	[[ "$squeezed" == *"Service: active (plugin)"* ]]
}

@test "status: shows escalation detail when on" {
	main escalate on >/dev/null
	main volume-step 25 >/dev/null
	main volume-max 175 >/dev/null
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
	run main status
	local squeezed
	squeezed="$(squeeze "$output")"
	[[ "$squeezed" == *"Escalate: on (+25% per repeat, cap 175%)"* ]]
}

@test "test: plays the configured sound at the configured volume" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub paplay <<SH
#!/usr/bin/env bash
echo "\$@" >> "$log"
SH
	main volume 50 >/dev/null
	run main test
	[ "$status" -eq 0 ]
	[[ "$(cat "$log")" == "--volume=32768"* ]]
}

@test "help: prints usage for -h, --help, and help" {
	for flag in -h --help help; do
		run main "$flag"
		[ "$status" -eq 0 ]
		[[ "$output" == *"Usage: sudo-watchctl"* ]]
	done
}

@test "unknown command exits non-zero and prints usage" {
	run main bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown command: bogus"* ]]
	[[ "$output" == *"Usage: sudo-watchctl"* ]]
}

@test "no command defaults to status" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
	run main
	[ "$status" -eq 0 ]
	[[ "$output" == *"Config file:"* ]]
}
