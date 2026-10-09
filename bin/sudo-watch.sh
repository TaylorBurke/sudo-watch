#!/usr/bin/env bash
# Watches for sudo/pkexec processes stuck waiting on a password prompt
# (no child process spawned yet) and pings the user if unanswered.
set -uo pipefail

CONFIG_FILE="${SUDO_WATCH_CONFIG:-$HOME/.config/sudo-watch/config}"

# -g: stay global even if this script is `source`d from inside a function
# (e.g. bats test setup), instead of scoping to whatever sourced it.
declare -gA first_seen
declare -gA last_alert
declare -gA alert_count

now() { date +%s; }

# Config is parsed as data, never `source`d: the file is just KEY=value
# lines, so anything that can write it must not get code execution as the
# user. Only the known keys below are honored; values are taken literally
# (no expansion, no command substitution), and numeric keys that aren't plain
# non-negative integers fall back to their defaults.
declare -gA cfg=()

parse_config() {
	cfg=()
	[[ -f "$CONFIG_FILE" ]] || return 0
	local line key val
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%$'\r'}"
		[[ "$line" =~ ^(SUDO_WATCH_[A-Z_]+)=(.*)$ ]] || continue
		key="${BASH_REMATCH[1]}"
		val="${BASH_REMATCH[2]}"
		# Strip one matching pair of surrounding quotes (hand-edited configs).
		if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
			val="${BASH_REMATCH[1]}"
		fi
		cfg["$key"]="$val"
	done <"$CONFIG_FILE"
}

# cfg_num KEY DEFAULT: config value, else environment, else default; must be
# a non-negative integer or the default is used.
cfg_num() {
	local key="$1" default="$2" val
	val="${cfg[$key]-${!key-}}"
	[[ "$val" =~ ^[0-9]{1,9}$ ]] && echo "$((10#$val))" || echo "$default"
}

# Re-read config on every loop tick so `sudo-watchctl` changes (e.g. volume)
# take effect within one POLL_INTERVAL, no service restart needed.
load_config() {
	parse_config
	POLL_INTERVAL="$(cfg_num SUDO_WATCH_POLL_INTERVAL 2)"
	# 1..3600s: 0 would spin, and a huge value would park the loop for years.
	(( POLL_INTERVAL > 0 && POLL_INTERVAL <= 3600 )) || POLL_INTERVAL=2
	ALERT_THRESHOLD="$(cfg_num SUDO_WATCH_ALERT_THRESHOLD 20)"
	REPEAT_INTERVAL="$(cfg_num SUDO_WATCH_REPEAT_INTERVAL 10)"
	# Alerts per waiting prompt before they stop; 0 = unlimited.
	MAX_ALERTS="$(cfg_num SUDO_WATCH_MAX_ALERTS 10)"
	SOUND="${cfg[SUDO_WATCH_SOUND]-${SUDO_WATCH_SOUND:-/usr/share/sounds/freedesktop/stereo/dialog-warning.oga}}"
	VOLUME_PERCENT="$(cfg_num SUDO_WATCH_VOLUME 100)"
	VOLUME_ESCALATE="$(cfg_num SUDO_WATCH_VOLUME_ESCALATE 0)"
	VOLUME_STEP="$(cfg_num SUDO_WATCH_VOLUME_STEP 10)"
	VOLUME_MAX="$(cfg_num SUDO_WATCH_VOLUME_MAX 150)"
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
	# Hard ceiling regardless of config: paplay's volume is a 32-bit value.
	(( vol > 500 )) && vol=500
	# cmd is the watched process's own argv, i.e. attacker-influenced text:
	# escape markup (notification daemons render it) and end option parsing
	# with `--` so an argv0 like "--hint=..." can't be read as a flag.
	# (`\&` because bash >= 5.2 treats a bare & in a replacement as the match.)
	cmd="${cmd//&/\&amp;}"; cmd="${cmd//</\&lt;}"; cmd="${cmd//>/\&gt;}"
	notify-send -u critical -a "sudo-watch" -- \
		"Waiting on your password" \
		"${cmd} (pid ${pid}) has been waiting ${elapsed}s" 2>/dev/null
	[[ -f "$SOUND" ]] && paplay --volume="$(( vol * 65536 / 100 ))" -- "$SOUND" 2>/dev/null 9>&- &
}

# One iteration of the poll loop, split out from main() so it can be
# exercised directly in tests without an infinite loop or a real sleep.
poll_once() {
	local current_pids t pid cmd elapsed last

	current_pids="$(pgrep -x 'sudo|pkexec' 2>/dev/null || true)"
	t="$(now)"

	declare -A seen_this_round
	for pid in $current_pids; do
		seen_this_round["$pid"]=1
		is_pending "$pid" || continue

		# `|| true`: the pid can legitimately disappear between pgrep and ps
		# (resolved or exited); don't let that non-zero status propagate.
		cmd="$(ps -o cmd= -p "$pid" 2>/dev/null)" || true
		[[ -z "$cmd" ]] && continue

		if [[ -z "${first_seen[$pid]:-}" ]]; then
			first_seen["$pid"]="$t"
		fi

		elapsed=$(( t - first_seen["$pid"] ))
		if (( elapsed >= ALERT_THRESHOLD )); then
			last="${last_alert[$pid]:-0}"
			if (( t - last >= REPEAT_INTERVAL )) \
				&& (( MAX_ALERTS == 0 || ${alert_count[$pid]:-0} < MAX_ALERTS )); then
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
}

main() {
	# Only one instance should actively poll/alert at a time. Without this,
	# installing both the Omarchy plugin and the standalone systemd service
	# (the README lists this as a supported "alongside" combo) runs two
	# independent watchers against the same sudo/pkexec processes, so every
	# alert fires twice. Block on a lock instead of exiting on contention: if
	# the instance currently holding it stops, this one takes over rather than
	# needing a manual restart, and Restart=on-failure / the Quickshell plugin's
	# onExited handler never see a "failure" to loop on.
	# Never fall back to a shared dir like /tmp: a predictable name there lets
	# another user pre-create or symlink it. Open in append mode so a symlink
	# can't be used to truncate some other file.
	local lock_file="${SUDO_WATCH_LOCK:-${XDG_RUNTIME_DIR:-$HOME/.cache}/sudo-watch.lock}"
	mkdir -p "$(dirname "$lock_file")"
	# Created 0600 so no other process can open it just to hold the flock.
	local old_umask
	old_umask="$(umask)"; umask 077
	exec 9>>"$lock_file"
	umask "$old_umask"
	if ! flock -n 9; then
		echo "sudo-watch: another instance is already watching (lock: $lock_file); waiting to take over" >&2
		flock 9
		echo "sudo-watch: acquired lock, now active" >&2
	fi

	while true; do
		load_config
		poll_once
		# 9>&-: don't leak the lock fd into the child, or an orphaned sleep
		# would keep the single-instance lock held after the watcher dies.
		sleep "$POLL_INTERVAL" 9>&-
	done
}

# Only run when executed directly, not when sourced (e.g. by tests) — lets
# tests load is_pending/load_config/send_alert/poll_once in isolation.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
