#!/usr/bin/env bash
# tmux-resurrect restore hook — re-launches assistants with their saved session IDs.
# Reads the sidecar JSON written by save-assistant-sessions.sh.
#
# Called automatically by tmux-resurrect after restore via:
#   set -g @resurrect-hook-post-restore-all '/path/to/restore-assistant-sessions.sh'

set -euo pipefail

# Source shared detection library (detect_tool, pane_has_assistant, posix_quote)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-detect.sh
source "$SCRIPT_DIR/lib-detect.sh"

# Follow tmux-resurrect's own save-dir resolution (resurrect_data_dir in
# lib-detect.sh) so we read the sidecar from wherever resurrect saved it.
RESURRECT_DIR="$(resurrect_data_dir)"
INPUT_FILE="${RESURRECT_DIR}/assistant-sessions.json"
LOG_FILE="${RESURRECT_DIR}/assistant-restore.log"

# Rotate log: keep only the most recent 500 lines
if [ -f "$LOG_FILE" ]; then
	tail -n 500 "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
fi

log() {
	local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
	echo "$msg" >&2
	echo "$msg" >>"$LOG_FILE"
}

# Block until a pane's interactive shell is actually ready to consume keystrokes.
#
# Why this exists: on a cold tmux start (continuum auto-restore), send-keys can
# fire while the pane's shell is still mid-init (oh-my-zsh, compinit, nvm,
# powerlevel10k instant-prompt, etc.). zsh resets the line editor (ZLE) and tty
# modes during startup, so keys typed before ZLE is live are silently discarded
# -- no echo, no error, no command. A fixed sleep can't fix this reliably: it's
# too short on a busy boot and wastes time on a fast one. Instead we probe the
# real condition -- type a unique marker and wait until it echoes back, proving
# the shell is at an interactive prompt and consuming input.
#
# The leading space before `echo` keeps the probe out of shell history when
# HIST_IGNORE_SPACE / HISTCONTROL=ignorespace is set. We clear the pane after a
# successful probe so the marker lines don't linger above the resumed TUI.
#
# Returns 0 once ready, 1 if it times out (caller proceeds anyway -- best effort).
wait_for_shell_ready() {
	local pane="$1"
	local marker="__ar_ready_${$}_$(echo "$pane" | tr -c 'A-Za-z0-9' '_')"
	local attempt=0
	# 50 attempts * 0.2s = 10s cap; generous for heavy zsh init, bounded so a
	# wedged pane never hangs the rest of the restore.
	while [ "$attempt" -lt 50 ]; do
		tmux send-keys -t "$pane" " echo $marker" Enter 2>/dev/null || return 1
		sleep 0.2
		# Match the *echoed output* of the command, not the typed command line
		# itself. Require the marker to appear at least twice would be ideal, but
		# a single hit after Enter already implies the shell ran it.
		if tmux capture-pane -pt "$pane" 2>/dev/null | grep -q "$marker"; then
			return 0
		fi
		attempt=$((attempt + 1))
	done
	return 1
}

if [ ! -f "$INPUT_FILE" ]; then
	log "no saved sessions found at $INPUT_FILE"
	exit 0
fi

# Read saved sessions
sessions=$(jq -r '.sessions // []' "$INPUT_FILE")
count=$(echo "$sessions" | jq 'length')

if [ "$count" -eq 0 ]; then
	log "no assistant sessions to restore"
	exit 0
fi

# Wait for panes to be fully initialized after resurrect restore.
# This is a coarse pre-settle only; per-pane shell readiness is guaranteed
# later by wait_for_shell_ready() before any resume command is sent.
sleep 2

log "restoring $count assistant session(s)..."

# Use a temp file to avoid subshell variable scoping issues with pipes
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT INT TERM
echo "$sessions" | jq -c '.[]' >"$tmpfile"

restored=0
while read -r entry; do
	pane=$(echo "$entry" | jq -r '.pane')
	tool=$(echo "$entry" | jq -r '.tool')
	session_id=$(echo "$entry" | jq -r '.session_id')
	cwd=$(echo "$entry" | jq -r '.cwd')
	cli_args=$(echo "$entry" | jq -r '.cli_args // empty')
	model=$(echo "$entry" | jq -r '.model // empty')
	env_json=$(echo "$entry" | jq -c '.env // {}')

	# Check if the target pane's session exists
	tmux_session="${pane%%:*}"
	if ! tmux has-session -t "$tmux_session" 2>/dev/null; then
		log "session '$tmux_session' does not exist, skipping pane $pane"
		continue
	fi

	# Check if the specific pane exists
	if ! tmux list-panes -t "$pane" >/dev/null 2>&1; then
		log "pane $pane does not exist, skipping"
		continue
	fi

	# Wait for at least one client to attach to this pane's session before
	# replaying. TUI tools that query the terminal at startup (OSC 11
	# background-color for theme detection, cursor-shape, hyperlinks, etc.)
	# get a null response if no terminal is attached when the query fires
	# — tmux silently drops the query because there's no client to forward
	# it to. crossterm-based tools cache that null response in a OnceLock
	# and never retry, so a single bad startup permanently locks the tool
	# to its fallback state for the lifetime of the process. Symptom seen
	# in the wild: codex's diff palette permanently dark on a light
	# terminal after every reboot, requiring a manual `codex resume` to
	# clear.
	#
	# Poll every 100ms, cap at 5s so we don't hang the rest of the restore
	# if the user never attaches a client. In normal boot flows where a
	# kitty/wezterm/etc auto-attaches via `tmux new-session -A`, the wait
	# resolves in < 200ms.
	client_wait=0
	while [ "$(tmux list-clients -t "$tmux_session" 2>/dev/null | wc -l)" -eq 0 ] && [ $client_wait -lt 50 ]; do
		sleep 0.1
		client_wait=$((client_wait + 1))
	done
	if [ $client_wait -ge 50 ]; then
		log "no client attached to session '$tmux_session' after 5s; replaying anyway (TUI startup queries may miss responses)"
	fi

	# Guard 1: skip if the pane is not running a shell.
	# After tmux-resurrect restore, panes should be running a shell (bash, zsh,
	# etc.). If something else is running (e.g., the user manually started vim,
	# or @resurrect-processes restored a non-assistant program), injecting
	# send-keys would feed commands into the wrong program.
	pane_cmd=$(tmux display-message -t "$pane" -p '#{pane_current_command}' 2>/dev/null || true)
	# Strip leading '-' from login shells (e.g., -bash -> bash, -zsh -> zsh)
	pane_cmd="${pane_cmd#-}"
	case "$pane_cmd" in
	bash | zsh | fish | sh | dash | ksh | tcsh | csh | nu) ;;
	*)
		log "pane $pane is running '$pane_cmd' (not a shell), skipping"
		continue
		;;
	esac

	# Guard 2: skip if the pane already has a running assistant (e.g., if
	# @resurrect-processes launched it, or user restarted manually).
	# Uses the same full tree walk + detect_tool() as the save script to
	# catch exec-replaced shells, wrappers (npx, env, direnv), and deep
	# process chains.
	pane_shell_pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null || true)
	if [ -n "$pane_shell_pid" ]; then
		existing=$(pane_has_assistant "$pane_shell_pid" || true)
		if [ -n "$existing" ]; then
			log "pane $pane already has a running assistant (pid $existing), skipping"
			continue
		fi
	fi

	# Build env prefix: only restore user-configured vars from
	# @assistant-resurrect-capture-env. Exclude built-in vars (tmux_pane, shell)
	# which would be stale or already present in the shell environment.
	env_prefix=""
	if [ -n "$env_json" ] && [ "$env_json" != "null" ] && [ "$env_json" != "{}" ]; then
		capture_env=$(tmux show-option -gqv @assistant-resurrect-capture-env 2>/dev/null || true)
		for var in $capture_env; do
			# Validate var name to prevent shell injection via crafted tmux option
			if ! [[ "$var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				log "skipping invalid env var name: $var"
				continue
			fi
			val=$(echo "$env_json" | jq -r --arg k "$var" '.[$k] // empty')
			if [ -n "$val" ]; then
				env_prefix="${env_prefix}${var}=$(posix_quote "$val") "
			fi
		done
	fi

	# Build the resume command for each tool.
	# Apply posix_quote to session_id defensively — IDs are alphanumeric in
	# practice, but a corrupt/tampered sidecar JSON could inject shell commands.
	safe_sid=$(posix_quote "$session_id")

	# Quote cli_args tokens and disable glob expansion while splitting, so
	# args like "claude-opus-4-6[1m]" are treated literally.
	safe_cli_args=""
	if [ -n "$cli_args" ]; then
		set -f
		for _arg in $cli_args; do
			safe_cli_args="${safe_cli_args} $(posix_quote "$_arg")"
		done
		set +f
	fi

	# Add --model from the sidecar model field if not already in cli_args.
	# Only for Claude — OpenCode and Codex don't support --model.
	safe_model_arg=""
	if [ -n "$model" ] && [ "$tool" = "claude" ]; then
		case "$cli_args" in
		*--model*) ;;
		*) safe_model_arg=" --model $(posix_quote "$model")" ;;
		esac
	fi

	resume_cmd=""
	case "$tool" in
	claude)
		if [ -n "$safe_cli_args" ] || [ -n "$safe_model_arg" ]; then
			resume_cmd="command claude${safe_cli_args}${safe_model_arg} --resume ${safe_sid}"
		else
			resume_cmd="command claude --resume ${safe_sid}"
		fi
		;;
	opencode)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command opencode${safe_cli_args} -s ${safe_sid}"
		else
			resume_cmd="command opencode -s ${safe_sid}"
		fi
		;;
	codex)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command codex${safe_cli_args} resume ${safe_sid}"
		else
			resume_cmd="command codex resume ${safe_sid}"
		fi
		;;
	pi)
		if [ -n "$safe_cli_args" ]; then
			resume_cmd="command pi${safe_cli_args} --session ${safe_sid}"
		else
			resume_cmd="command pi --session ${safe_sid}"
		fi
		;;
	*)
		log "unknown tool '$tool' for pane $pane, skipping"
		continue
		;;
	esac

	# Prepend env vars if present
	if [ -n "$env_prefix" ]; then
		resume_cmd="${env_prefix}${resume_cmd}"
	fi

	log "restoring $tool in $pane (session: $session_id, cmd: $resume_cmd)"

	# Wait until the shell is genuinely ready before sending anything. Without
	# this, keys can be swallowed mid-init on a cold continuum auto-restore (see
	# wait_for_shell_ready). On manual Ctrl+r the shell is already idle, so the
	# probe returns on its first attempt.
	if ! wait_for_shell_ready "$pane"; then
		log "pane $pane shell not ready after probe timeout; sending anyway (keys may be dropped)"
	fi

	# Clear the pane before launching: tmux-resurrect may have restored old
	# pane contents (captured terminal text from the previous session), plus the
	# readiness-probe markers. Without clearing, TUI tools like Claude show stale
	# output above the new instance. Uses tmux clear-history to wipe scrollback,
	# then sends 'clear' to reset the visible area.
	tmux send-keys -t "$pane" "clear" Enter
	tmux clear-history -t "$pane"
	sleep 0.3

	# Build the full command: cd to cwd (if it exists) then resume.
	# Use POSIX single-quote escaping (safe for bash, zsh, sh, dash, fish).
	if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
		safe_cwd=$(posix_quote "$cwd")
		tmux send-keys -t "$pane" "cd ${safe_cwd} 2>/dev/null; ${resume_cmd}" Enter
	else
		tmux send-keys -t "$pane" "${resume_cmd}" Enter
	fi

	restored=$((restored + 1))

	# Stagger launches to avoid overwhelming the system
	sleep 1
done <"$tmpfile"

rm -f "$tmpfile"

log "restored $restored of $count assistant session(s)"
