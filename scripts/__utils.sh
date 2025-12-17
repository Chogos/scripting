#!/usr/bin/env bash
# Shared shell utilities for small scripts
# - Logging: info/warn/error/debug with optional colors
# - Safe command runner that respects DRY_RUN and VERBOSE
# - Command availability checks (ensure_commands)
# - Temporary file helpers with automatic cleanup
# - Prompt helpers (confirm, prompt, read_secret)
# - Small helpers (safe_cd, require_root)

## Colors and formatting (only when output is a terminal)
_is_tty() { [[ -t 2 ]]; }
if _is_tty && command -v tput >/dev/null 2>&1; then
	RED=$(tput setaf 1)
	GREEN=$(tput setaf 2)
	YELLOW=$(tput setaf 3)
	BLUE=$(tput setaf 4)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    RESET=""
fi

_log() {
	local level=$1; shift
	local color="${RESET}"
	case "$level" in
		ERROR) color="$RED" ;;
		WARN)  color="$YELLOW" ;;
		INFO)  color="$GREEN" ;;
		DEBUG) color="$BLUE" ;;
	esac
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	printf "%s%s [%s] %s%s\n" "$color" "$ts" "$level" "$*" "$RESET" >&2
}

info()  { _log INFO "$*"; }
warn()  { _log WARN "$*"; }
error() { _log ERROR "$*"; }

# debug only prints when VERBOSE=true or DEBUG=1
debug() {
	if [[ "${VERBOSE:-false}" == true || "${DEBUG:-0}" -ne 0 ]]; then
		_log DEBUG "$*"
	fi
}

# die: print an error and exit with provided status (default 1)
die() {
	local exit_code=1
	if [[ ${#} -gt 1 && ${!#} =~ ^[0-9]+$ ]]; then
		exit_code=${!#}
		set -- "${@:1:$(($#-1))}"
	fi
	error "$*"
	exit "$exit_code"
}

# run_cmd: execute a command safely.
# - Preserves arguments (no eval)
# - Honors DRY_RUN and VERBOSE
# Example: run_cmd ls -l /tmp
run_cmd() {
	if [[ ${#} -eq 0 ]]; then
		die "run_cmd: no command provided" 2
	fi

	if [[ "${DRY_RUN:-false}" == true ]]; then
		info "DRY-RUN: $*"
		return 0
	fi

	if [[ "${VERBOSE:-false}" == true ]]; then
		info "+ $*"
	fi

	# Use "exec"-style invocation to preserve args exactly
	"$@"
}

# run_shell: run a raw shell string (uses bash -c) — only when necessary
# Use with caution, prefer run_cmd for safety.
run_shell() {
	if [[ ${#} -eq 0 ]]; then
		die "run_shell: no command provided" 2
	fi
	local cmd="$*"
	if [[ "${DRY_RUN:-false}" == true ]]; then
		info "DRY-RUN (shell): $cmd"
		return 0
	fi
	if [[ "${VERBOSE:-false}" == true ]]; then
		info "+ bash -c '$cmd'"
	fi
	bash -c "$cmd"
}

# ensure_commands: fail early if required commands are missing
# Example: ensure_commands git curl
ensure_commands() {
	local missing=()
	local cmd
	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done
	if [[ ${#missing[@]} -ne 0 ]]; then
		error "Missing required commands: ${missing[*]}"
		return 2
	fi
}

# Temporary file helpers
__TMP_FILES=()

# register an arbitrary file to be cleaned up on exit
register_temp_file() {
	__TMP_FILES+=("$1")
}

# create a temp file in a portable way and register it for cleanup
mktemp_file() {
	local tmp
	# try portable mktemp usage
	if tmp=$(mktemp 2>/dev/null); then
		:
	elif tmp=$(mktemp -t tmp 2>/dev/null); then
		:
	else
		die "mktemp unavailable or failed"
	fi
	register_temp_file "$tmp"
	printf "%s" "$tmp"
}

_cleanup_temp_files() {
	local f
	for f in "${__TMP_FILES[@]:-}"; do
		if [[ -e "$f" ]]; then
			rm -f -- "$f" || debug "failed to remove temp file: $f"
		fi
	done
}

_register_tempfile_trap() {
	# only register once
	if [[ -z "${__TMP_TRAP_REGISTERED:-}" ]]; then
		trap _cleanup_temp_files EXIT
		__TMP_TRAP_REGISTERED=1
	fi
}
_register_tempfile_trap

# confirm: prompt user for yes/no. Returns 0 on yes, 1 on no.
# Usage: if confirm "Continue?"; then ... fi
confirm() {
	local prompt="${1:-Are you sure?}"
	local default=${2:-no}
	local yn
	local default_hint
	if [[ "$default" == "yes" ]]; then
		default_hint="Y/n"
	else
		default_hint="y/N"
	fi
	while true; do
		printf "%s [%s] " "$prompt" "$default_hint" >&2
		read -r yn
		yn=${yn:-$default}
		case "$yn" in
			[Yy]|[Yy][Ee][Ss]) return 0 ;;
			[Nn]|[Nn][Oo]) return 1 ;;
			*) printf "Please answer yes or no.\n" >&2 ;;
		esac
	done
}

# prompt: read a value with optional default
# Usage: name=$(prompt "Enter name" "default")
prompt() {
	local message="$1"
	local default_value="${2:-}"
	local value
	if [[ -n "$default_value" ]]; then
		printf "%s [%s]: " "$message" "$default_value" >&2
	else
		printf "%s: " "$message" >&2
	fi
	read -r value
	if [[ -z "$value" ]]; then
		printf "%s" "$default_value"
	else
		printf "%s" "$value"
	fi
}

# read_secret: read a value without echoing to the terminal
read_secret() {
	local message="${1:-Enter secret}";
	printf "%s: " "$message" >&2
	# shellcheck disable=SC2162
	IFS= read -r -s secret
	printf "\n"
	printf "%s" "$secret"
}

# safe_cd: cd to directory or die with a helpful message
safe_cd() {
	local dir="$1"
	[[ -d "$dir" ]] || die "safe_cd: directory not found: $dir"
	cd -- "$dir" || die "safe_cd: failed to cd to $dir"
}

# is_root: returns 0 if running as root
is_root() { [[ ${EUID:-0} -eq 0 ]]; }

# require_root: exit if not running as root
require_root() {
	if ! is_root; then
		die "This script must be run as root" 1
	fi
}

# small helper to safely join path segments (no duplicate slashes)
join_path() {
	local first="$1"; shift
	local part
	for part in "$@"; do
		first="${first%/}/${part##/}"
	done
	printf "%s" "$first"
}

