#!/usr/bin/env bash
# Runs the bats suite under kcov and reports line coverage for the scripts
# under bin/.
#
# Only gates on bin/sudo-watch.sh's coverage. kcov's bash instrumentation
# reliably traces that file (a plain `if`/`for`/functions script) but
# noticeably undercounts bin/sudo-watchctl's `case`-dispatch structure,
# misreporting lines that the test suite demonstrably does exercise (see
# tests/README.md for how that was confirmed). sudo-watchctl's number is
# still printed for visibility, just not enforced.
#
# Requires: bats, kcov, jq (pacman -S bats kcov jq).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/tests/.coverage}"
THRESHOLD=98
GATED_FILE="$REPO_DIR/bin/sudo-watch.sh"

rm -rf "$OUT_DIR"

kcov \
	--include-pattern="$REPO_DIR/bin/sudo-watch.sh,$REPO_DIR/bin/sudo-watchctl" \
	"$OUT_DIR" \
	bats "$REPO_DIR/tests"

# kcov nests per-run output under a directory named after the traced
# command (normally "bats"); fall back to searching in case that changes.
summary="$OUT_DIR/bats/coverage.json"
[[ -f "$summary" ]] || summary="$(find "$OUT_DIR" -maxdepth 2 -name coverage.json | head -n1)"

if [[ -z "${summary:-}" || ! -f "$summary" ]]; then
	echo "coverage.sh: couldn't find kcov's coverage.json under $OUT_DIR" >&2
	exit 1
fi

jq -r '.files[] | "\(.file): \(.percent_covered)%"' "$summary"
echo "Full report: $(dirname "$summary")/index.html"

gated_percent="$(jq -r --arg f "$GATED_FILE" '.files[] | select(.file == $f) | .percent_covered' "$summary")"
echo "Gated: $GATED_FILE (target ${THRESHOLD}%)"

awk -v p="$gated_percent" -v t="$THRESHOLD" 'BEGIN { exit !(p >= t) }'
