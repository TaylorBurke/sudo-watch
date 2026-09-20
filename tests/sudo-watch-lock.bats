#!/usr/bin/env bats
# Integration tests for main()'s single-instance lock. Unlike
# tests/sudo-watch.bats (which sources the script to test functions in
# isolation), these run bin/sudo-watch.sh as a real subprocess since the
# lock/takeover behavior only exists in main()'s flock handling. They use
# real sleeps to coordinate two processes, so they're slower than the rest
# of the suite (a couple seconds each).

load 'test_helper'

SUDO_WATCH_SCRIPT="${BATS_TEST_DIRNAME}/../bin/sudo-watch.sh"

setup() {
	load_stub_dir
	# Keep the polling loop quiet and fast; no sudo/pkexec processes to find.
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
	export SUDO_WATCH_CONFIG="$BATS_TEST_TMPDIR/config"
	export SUDO_WATCH_POLL_INTERVAL=1
}

@test "main: acquires the lock immediately when uncontended and starts polling" {
	local lock="$BATS_TEST_TMPDIR/lock"
	local log="$BATS_TEST_TMPDIR/out.log"
	export SUDO_WATCH_LOCK="$lock"

	timeout 2 bash "$SUDO_WATCH_SCRIPT" >"$log" 2>&1 &
	local pid=$!
	sleep 0.5
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true

	[ -e "$lock" ]
	! grep -q "already watching" "$log"
}

@test "main: waits for a held lock, then takes over once it's released" {
	local lock="$BATS_TEST_TMPDIR/lock"
	local log="$BATS_TEST_TMPDIR/out.log"
	export SUDO_WATCH_LOCK="$lock"

	# Hold the lock in the background to force the script into the
	# "waiting to take over" branch, then release it after a short delay.
	bash -c '
		exec 8>"'"$lock"'"
		flock 8
		sleep 1.5
	' &
	local holder_pid=$!
	sleep 0.3 # give the holder time to actually acquire the flock first

	timeout 4 bash "$SUDO_WATCH_SCRIPT" >"$log" 2>&1 &
	local watch_pid=$!

	wait "$holder_pid"
	sleep 0.5 # give sudo-watch.sh a moment to notice and take over
	kill "$watch_pid" 2>/dev/null || true
	wait "$watch_pid" 2>/dev/null || true

	grep -q "another instance is already watching" "$log"
	grep -q "acquired lock, now active" "$log"
}
