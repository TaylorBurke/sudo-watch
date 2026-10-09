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
	export SUDO_WATCH_LOCK="$BATS_TEST_TMPDIR/lock"
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

@test "status: detects the plugin watcher by its held lock" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	flock "$SUDO_WATCH_LOCK" sleep 5 &
	local holder=$!
	sleep 0.3
	run main status
	kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
	local squeezed
	squeezed="$(squeeze "$output")"
	[[ "$squeezed" == *"Service: active (plugin)"* ]]
}

@test "status: an unrelated process mentioning the script name is not a watcher" {
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 0
SH
	run main status
	[[ "$(squeeze "$output")" == *"Service: not active"* ]]
}

# --- security regressions -------------------------------------------------

@test "sound: a path with sed/regex metacharacters is stored literally" {
	local f="$BATS_TEST_TMPDIR/we|ird&name\\1.oga"
	: > "$f"
	run main sound "$f"
	[ "$status" -eq 0 ]
	run main sound
	[ "$output" = "$f" ]
}

@test "sound: rejects a path containing a newline" {
	local f="$BATS_TEST_TMPDIR/a"$'\n'"SUDO_WATCH_VOLUME=999"
	: > "$f"
	run main sound "$f"
	[ "$status" -ne 0 ]
	[ ! -f "$SUDO_WATCH_CONFIG" ] || ! grep -q '^SUDO_WATCH_VOLUME=999' "$SUDO_WATCH_CONFIG"
}

@test "test: a malicious volume in the config is never evaluated as arithmetic" {
	local marker="$BATS_TEST_TMPDIR/pwned"
	echo "SUDO_WATCH_VOLUME=BASH_VERSINFO[\$(touch $marker)]" > "$SUDO_WATCH_CONFIG"
	stub paplay <<'SH'
#!/usr/bin/env bash
exit 0
SH
	run main test
	[ ! -e "$marker" ]
	run main volume
	[ "$output" = "100" ]
}

@test "volume: values above the ceiling are rejected" {
	run main volume 501
	[ "$status" -eq 1 ]
	run main volume-max 9999
	[ "$status" -eq 1 ]
	run main volume 500
	[ "$status" -eq 0 ]
}

@test "test: clamps an out-of-range configured volume" {
	local log="$BATS_TEST_TMPDIR/paplay.log"
	stub paplay <<SH
#!/usr/bin/env bash
echo "\$@" >> "$log"
SH
	echo "SUDO_WATCH_VOLUME=999999999" > "$SUDO_WATCH_CONFIG"
	run main test
	[[ "$(cat "$log")" == "--volume=327680"* ]]
}

@test "get_kv: strips quotes/CR like the watcher and drops control characters" {
	printf 'SUDO_WATCH_VOLUME="50"\r\nSUDO_WATCH_SOUND=a\033[31mb\n' > "$SUDO_WATCH_CONFIG"
	run main volume
	[ "$output" = "50" ]
	run main sound
	[ "$output" = "a[31mb" ]
}

@test "set_kv: concurrent writers don't lose updates" {
	for i in 1 2 3 4 5 6 7 8; do
		( main volume-step "$i" >/dev/null; main repeat "$((i + 10))" >/dev/null ) &
	done
	wait
	grep -q '^SUDO_WATCH_VOLUME_STEP=' "$SUDO_WATCH_CONFIG"
	grep -q '^SUDO_WATCH_REPEAT_INTERVAL=' "$SUDO_WATCH_CONFIG"
	[ "$(grep -c '^SUDO_WATCH_VOLUME_STEP=' "$SUDO_WATCH_CONFIG")" -eq 1 ]
	[ "$(grep -c '^SUDO_WATCH_REPEAT_INTERVAL=' "$SUDO_WATCH_CONFIG")" -eq 1 ]
}

@test "numeric settings: rejects absurdly long numbers" {
	run main volume 12345678901234567890
	[ "$status" -eq 1 ]
}

@test "set_kv: refuses control characters in a value" {
	run set_kv SUDO_WATCH_SOUND $'x\ny'
	[ "$status" -ne 0 ]
}

@test "config is created private (0600) in a private (0700) dir" {
	CONFIG_FILE="$BATS_TEST_TMPDIR/newdir/config"
	main volume 50 >/dev/null
	[ "$(stat -c %a "$CONFIG_FILE")" = "600" ]
	[ "$(stat -c %a "$(dirname "$CONFIG_FILE")")" = "700" ]
}

@test "set_kv: writes through a symlinked config instead of replacing it" {
	echo "SUDO_WATCH_VOLUME=10" > "$BATS_TEST_TMPDIR/real"
	ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/link"
	CONFIG_FILE="$BATS_TEST_TMPDIR/link"
	main volume 33 >/dev/null
	[ -L "$BATS_TEST_TMPDIR/link" ]
	grep -qx 'SUDO_WATCH_VOLUME=33' "$BATS_TEST_TMPDIR/real"
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

# --- max-alerts ---------------------------------------------------------

@test "max-alerts: defaults to 10" {
	run main max-alerts
	[ "$output" = "10" ]
}

@test "max-alerts: sets a number, and 'unlimited' or 0 mean unlimited" {
	main max-alerts 3 >/dev/null
	run main max-alerts
	[ "$output" = "3" ]
	main max-alerts unlimited >/dev/null
	run main max-alerts
	[ "$output" = "unlimited" ]
	grep -qx 'SUDO_WATCH_MAX_ALERTS=0' "$SUDO_WATCH_CONFIG"
	main max-alerts 0 >/dev/null
	run main max-alerts
	[ "$output" = "unlimited" ]
}

@test "max-alerts: rejects junk" {
	run main max-alerts lots
	[ "$status" -eq 1 ]
	run main max-alerts -1
	[ "$status" -eq 1 ]
}

# --- widget on/off ---------------------------------------------------------

make_shell_json() {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	cat > "$SHELL_CONFIG" <<'JSON'
{"bar":{"layout":{"left":[{"id":"omarchy.menu"}],"right":[{"id":"omarchy.tray"},{"id":"taylorburke.sudo-watch"},{"id":"widget.torrents","x":1}]}},"plugins":[{"id":"taylorburke.sudo-watch"}]}
JSON
}

@test "widget status: reports on/off from the bar layout" {
	make_shell_json
	run main widget status
	[ "$output" = "on" ]
	run main widget
	[ "$output" = "on" ]
	echo '{"bar":{"layout":{"right":[]}}}' > "$SHELL_CONFIG"
	run main widget status
	[ "$output" = "off" ]
}

@test "widget off: removes only this widget, keeps the rest, leaves the plugin enabled, and backs up" {
	make_shell_json
	run main widget off
	[ "$status" -eq 0 ]
	run main widget status
	[ "$output" = "off" ]
	jq -e '.bar.layout.right | map(.id) == ["omarchy.tray","widget.torrents"]' "$SHELL_CONFIG"
	jq -e '.bar.layout.left[0].id == "omarchy.menu"' "$SHELL_CONFIG"
	jq -e '.plugins | map(.id) | index("taylorburke.sudo-watch")' "$SHELL_CONFIG"
	ls "$SHELL_CONFIG".bak.sudo-watch-* >/dev/null
}

@test "widget off: is a no-op when already off" {
	make_shell_json
	main widget off >/dev/null
	local n; n="$(ls "$BATS_TEST_TMPDIR"/shell.json.bak.* | wc -l)"
	run main widget off
	[[ "$output" == *"already off"* ]]
	[ "$(ls "$BATS_TEST_TMPDIR"/shell.json.bak.* | wc -l)" -eq "$n" ]
}

@test "widget off: refuses to touch a shell.json that isn't valid JSON" {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	echo 'not json taylorburke.sudo-watch' > "$SHELL_CONFIG"
	run main widget off
	[ "$(cat "$SHELL_CONFIG")" = "not json taylorburke.sudo-watch" ]
}

@test "widget on: adds it to the right section when it has no saved spot" {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	echo '{"bar":{"layout":{"right":[{"id":"a"},{"id":"b"}]}},"plugins":[{"id":"taylorburke.sudo-watch"}]}' > "$SHELL_CONFIG"
	run main widget on
	[ "$status" -eq 0 ]
	jq -e '.bar.layout.right | map(.id) == ["a","b","taylorburke.sudo-watch"]' "$SHELL_CONFIG"
	run main widget status
	[ "$output" = "on" ]
}

@test "widget on: works even though the plugin is listed under plugins (omarchy bar put does not)" {
	make_shell_json
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	main widget off >/dev/null
	run main widget on
	[ "$status" -eq 0 ]
	run main widget status
	[ "$output" = "on" ]
}

@test "widget off then on: restores the same position, section and settings" {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	echo '{"bar":{"layout":{"left":[{"id":"m"}],"center":[{"id":"c"},{"id":"taylorburke.sudo-watch","barText":"none"},{"id":"d"}],"right":[{"id":"r"}]}}}' > "$SHELL_CONFIG"
	main widget off >/dev/null
	jq -e '.bar.layout.center | map(.id) == ["c","d"]' "$SHELL_CONFIG"
	main widget on >/dev/null
	jq -e '.bar.layout.center | map(.id) == ["c","taylorburke.sudo-watch","d"]' "$SHELL_CONFIG"
	jq -e '.bar.layout.center[1].barText == "none"' "$SHELL_CONFIG"
	jq -e '.bar.layout.right | map(.id) == ["r"]' "$SHELL_CONFIG"
}

@test "widget on: falls back to the end of the section if its old neighbour is gone" {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	echo '{"bar":{"layout":{"right":[{"id":"a"},{"id":"taylorburke.sudo-watch"},{"id":"b"}]}}}' > "$SHELL_CONFIG"
	main widget off >/dev/null
	echo '{"bar":{"layout":{"right":[{"id":"b"},{"id":"z"}]}}}' > "$SHELL_CONFIG"
	main widget on >/dev/null
	jq -e '.bar.layout.right | map(.id) == ["b","z","taylorburke.sudo-watch"]' "$SHELL_CONFIG"
}

@test "widget on: ignores a corrupt or mismatched saved position" {
	SHELL_CONFIG="$BATS_TEST_TMPDIR/shell.json"
	WIDGET_STATE="$BATS_TEST_TMPDIR/pos.json"
	echo '{"bar":{"layout":{"right":[{"id":"a"}]}}}' > "$SHELL_CONFIG"
	echo '{"section":"../../etc","entry":{"id":"evil"},"after":null}' > "$WIDGET_STATE"
	run main widget on
	[ "$status" -eq 0 ]
	jq -e '.bar.layout.right | map(.id) == ["a","taylorburke.sudo-watch"]' "$SHELL_CONFIG"
	jq -e '.bar.layout | keys == ["right"]' "$SHELL_CONFIG"
}

@test "widget: rejects an unknown argument" {
	run main widget sideways
	[ "$status" -eq 1 ]
}
