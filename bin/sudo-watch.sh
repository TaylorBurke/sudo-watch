#!/usr/bin/env bash
# Watches for sudo/pkexec processes stuck waiting on a password prompt
# (no child process spawned yet) and pings the user if unanswered.
set -uo pipefail

POLL_INTERVAL="${SUDO_WATCH_POLL_INTERVAL:-2}"
ALERT_THRESHOLD="${SUDO_WATCH_ALERT_THRESHOLD:-20}"
REPEAT_INTERVAL="${SUDO_WATCH_REPEAT_INTERVAL:-10}"
SOUND="${SUDO_WATCH_SOUND:-/usr/share/sounds/freedesktop/stereo/dialog-warning.oga}"
VOLUME_PERCENT="${SUDO_WATCH_VOLUME:-100}"
PAPLAY_VOLUME=$(( VOLUME_PERCENT * 65536 / 100 ))

declare -A first_seen
declare -A last_alert

now() { date +%s; }

is_pending() {
	# A sudo/pkexec process is "pending a password" if it has no
	# child process yet — once auth succeeds it execs the target command.
	local pid="$1"
	[[ -z "$(pgrep -P "$pid")" ]]
}

send_alert() {
	local pid="$1" cmd="$2" elapsed="$3"
	notify-send -u critical -a "sudo-watch" \
		"Waiting on your password" \
		"${cmd} (pid ${pid}) has been waiting ${elapsed}s" 2>/dev/null
	[[ -f "$SOUND" ]] && paplay --volume="$PAPLAY_VOLUME" "$SOUND" 2>/dev/null &
}

while true; do
	current_pids="$(pgrep -x 'sudo|pkexec' 2>/dev/null || true)"
	t="$(now)"

	declare -A seen_this_round
	for pid in $current_pids; do
		seen_this_round["$pid"]=1
		is_pending "$pid" || continue

		cmd="$(ps -o cmd= -p "$pid" 2>/dev/null)"
		[[ -z "$cmd" ]] && continue

		if [[ -z "${first_seen[$pid]:-}" ]]; then
			first_seen["$pid"]="$t"
		fi

		elapsed=$(( t - first_seen["$pid"] ))
		if (( elapsed >= ALERT_THRESHOLD )); then
			last="${last_alert[$pid]:-0}"
			if (( t - last >= REPEAT_INTERVAL )); then
				send_alert "$pid" "$cmd" "$elapsed"
				last_alert["$pid"]="$t"
			fi
		fi
	done

	# Drop tracking for pids that exited or got a child (i.e. resolved).
	for pid in "${!first_seen[@]}"; do
		if [[ -z "${seen_this_round[$pid]:-}" ]] || ! is_pending "$pid"; then
			unset 'first_seen[$pid]'
			unset 'last_alert[$pid]'
		fi
	done

	sleep "$POLL_INTERVAL"
done
