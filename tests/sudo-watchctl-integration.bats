#!/usr/bin/env bats
# A couple of real-subprocess runs of sudo-watchctl, to exercise the
# `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` guard itself
# (tests/sudo-watchctl.bats sources the script and calls main() directly,
# which never touches that line).

load 'test_helper'

SUDO_WATCHCTL="${BATS_TEST_DIRNAME}/../bin/sudo-watchctl"

setup() {
	load_stub_dir
	export SUDO_WATCH_CONFIG="$BATS_TEST_TMPDIR/config"
	stub systemctl <<'SH'
#!/usr/bin/env bash
exit 1
SH
	stub pgrep <<'SH'
#!/usr/bin/env bash
exit 1
SH
}

@test "runs directly as a script and prints status" {
	run "$SUDO_WATCHCTL" status
	[ "$status" -eq 0 ]
	[[ "$output" == *"Config file:"* ]]
}

@test "runs directly and rejects an unknown command" {
	run "$SUDO_WATCHCTL" bogus
	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown command: bogus"* ]]
}
