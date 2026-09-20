# Shared setup for sudo-watch bats tests: stubs external commands on PATH
# and isolates each test's config/lock files under BATS_TEST_TMPDIR.

# Prepends a per-test stub directory to PATH so tests can fake out
# pgrep/ps/notify-send/paplay/systemctl without touching the real system.
load_stub_dir() {
	STUB_DIR="$BATS_TEST_TMPDIR/stubs"
	mkdir -p "$STUB_DIR"
	PATH="$STUB_DIR:$PATH"
}

# Writes an executable stub named $1 with the script read from stdin, e.g.:
#   stub pgrep <<'SH'
#   #!/usr/bin/env bash
#   echo 4242
#   SH
stub() {
	local name="$1"
	cat >"$STUB_DIR/$name"
	chmod +x "$STUB_DIR/$name"
}
