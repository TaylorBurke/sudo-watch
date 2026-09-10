#!/usr/bin/env bash
# Watches for sudo/pkexec processes stuck waiting on a password prompt
# (no child process spawned yet) and pings the user if unanswered.
set -uo pipefail

CONFIG_FILE="${SUDO_WATCH_CONFIG:-$HOME/.config/sudo-watch/config}"

declare -A first_seen
declare -A last_alert
declare -A alert_count

now() { date +%s; }

# Re-read config on every loop tick so `sudo-watchctl` changes (e.g. volume)
# take effect within one POLL_INTERVAL, no service restart needed.
load_config() {
	[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
	POLL_INTERVAL="${SUDO_WATCH_POLL_INTERVAL:-2}"
	ALERT_THRESHOLD="${SUDO_WATCH_ALERT_THRESHOLD:-20}"
	REPEAT_INTERVAL="${SUDO_WATCH_REPEAT_INTERVAL:-10}"
	SOUND="${SUDO_WATCH_SOUND:-/usr/share/sounds/freedesktop/stereo/dialog-warning.oga}"
	VOLUME_PERCENT="${SUDO_WATCH_VOLUME:-100}"
	VOLUME_ESCALATE="${SUDO_WATCH_VOLUME_ESCALATE:-0}"
	VOLUME_STEP="${SUDO_WATCH_VOLUME_STEP:-10}"
	VOLUME_MAX="${SUDO_WATCH_VOLUME_MAX:-150}"
}

is_pending() {
	# A sudo/pkexec process is "pending a password" if it has no
	# child process yet — once auth succeeds it execs the target command.
	local pid="$1"
	[[ -z "$(pgrep -P "$pid")" ]]
}

send_alert() {
	local pid="$1" cmd="$2" elapsed="$3" count="$4"
	local vol="$VOLUME_PERCENT"
	if [[ "$VOLUME_ESCALATE" == "1" ]]; then
		vol=$(( VOLUME_PERCENT + VOLUME_STEP * (count - 1) ))
		(( vol > VOLUME_MAX )) && vol="$VOLUME_MAX"
	fi
	notify-send -u critical -a "sudo-watch" \
		"Waiting on your password" \
		"${cmd} (pid ${pid}) has been waiting ${elapsed}s" 2>/dev/null
	[[ -f "$SOUND" ]] && paplay --volume="$(( vol * 65536 / 100 ))" "$SOUND" 2>/dev/null &
}

while true; do
	load_config
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
				alert_count["$pid"]=$(( ${alert_count[$pid]:-0} + 1 ))
				send_alert "$pid" "$cmd" "$elapsed" "${alert_count[$pid]}"
				last_alert["$pid"]="$t"
			fi
		fi
	done

	# Drop tracking for pids that exited or got a child (i.e. resolved).
	for pid in "${!first_seen[@]}"; do
		if [[ -z "${seen_this_round[$pid]:-}" ]] || ! is_pending "$pid"; then
			unset 'first_seen[$pid]'
			unset 'last_alert[$pid]'
			unset 'alert_count[$pid]'
		fi
	done

	sleep "$POLL_INTERVAL"
done
