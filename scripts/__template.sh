#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Script template for small utilities
# - Uses: shared utilities from `__utils.sh` (info, debug, die, run_cmd, etc.)
# - Provides: usage text, safe option parsing, dry-run support, verbose mode,
#   debug flag, optional root requirement, examples that demonstrate the utils
# ---------------------------------------------------------------------------

# Default modes
DRY_RUN=false
VERBOSE=false
DEBUG=0
REQUIRE_ROOT=false

# Source shared utilities
SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPTDIR
UTILS_FILE="$SCRIPTDIR/__utils.sh"
readonly UTILS_FILE
if [[ -f "$UTILS_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$UTILS_FILE"
else
    echo "ERROR: missing required utilities file: $UTILS_FILE" >&2
    echo "Please ensure __utils.sh is present or run this script from the repository scripts directory." >&2
    exit 1
fi

usage() {
    cat <<'USAGE'
Usage: script.sh [options] [--] [args...]

Options:
  -n, --dry-run        Print actions but do not execute them
  -v, --verbose        Enable verbose logging (also enables debug output via DEBUG env)
  -d, --debug          Enable debug messages (sets DEBUG=1)
  -r, --require-root   Require root privileges (exits if not root)
  -h, --help           Show this help and exit

This is a template script. Fill in or replace the 'run' function with your
script-specific logic. The example run() below demonstrates common helpers
from `__utils.sh` such as: run_cmd, mktemp_file, prompt, confirm, and ensure_commands.

Examples:
  # Dry-run the script
  script.sh --dry-run

  # Run with verbose logging
  script.sh --verbose
USAGE
}

# If DEBUG is enabled, enable shell tracing to aid troubleshooting
if [[ "${DEBUG:-0}" -ne 0 ]]; then
    set -x
fi

parse_args() {
    # support long and short options
    while [[ ${#} -gt 0 ]]; do
        case "$1" in
        -n | --dry-run)
            DRY_RUN=true
            shift
            ;;
        -v | --verbose)
            VERBOSE=true
            shift
            ;;
        -d | --debug)
            DEBUG=1
            shift
            ;;
        -r | --require-root)
            REQUIRE_ROOT=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            # positional arguments begin
            break
            ;;
        esac
    done
    # Positional args (if any) will remain in "$@"
}

cleanup() {
    # Optionally override for script-specific cleanup.
    if [[ "$VERBOSE" == true ]]; then
        info "cleanup: completed"
    fi
}

# Track if an error was already reported by the ERR trap to avoid duplicate messages
ERROR_OCCURRED=false
on_error() {
    ERROR_OCCURRED=true
    local exit_code=${1:-$?}
    local frame
    frame=$(caller 0 || true)
    # Prefer using echo here to avoid depending on utilities that may be the cause of the error
    echo "ERROR: command failed at ${frame:-unknown} (exit code ${exit_code})" >&2
}
trap 'on_error $?' ERR

on_exit() {
    local exit_code=${1:-$?}
    cleanup
    if [[ $exit_code -ne 0 ]]; then
        if [[ "$ERROR_OCCURRED" == true ]]; then
            # An error message was already printed by on_error; just exit with the same code
            exit "$exit_code"
        else
            die "Script exited with status $exit_code"
        fi
    fi
}
trap 'on_exit $?' EXIT

run() {
    # Example: check if root is required
    if [[ "$REQUIRE_ROOT" == true ]]; then
        require_root
    fi

    # Ensure some basic commands are available (safe to call even if ensure_commands
    # isn't present in the environment that sourced this template)
    if declare -f ensure_commands >/dev/null 2>&1; then
        ensure_commands bash printf cat rm
    fi

    # Create a temporary file (mktemp_file registers it for cleanup automatically)
    local tmp
    tmp=$(mktemp_file) || die "failed to create temporary file"
    info "Using temporary file: $tmp"

    # Use run_cmd to respect DRY_RUN/VERBOSE
    # Avoid shell redirection being evaluated before run_cmd (this would bypass DRY-RUN).
    # Wrap the work in a shell string executed by run_cmd instead.
    run_cmd bash -c "printf '%s\n' \"Hello from the template at \$(date -u +'%Y-%m-%dT%H:%M:%SZ')\" > '$tmp'"

    # Show the file contents using run_cmd
    run_cmd cat "$tmp"

    # Interactive example: prompt and confirm
    local name
    name=$(prompt "Enter your name" "guest")
    info "Hello, $name"

    if confirm "Remove temp file $tmp?" "no"; then
        run_cmd rm -f "$tmp"
        info "Removed $tmp"
    else
        info "Left $tmp for inspection"
    fi

    # Additional script logic goes here.
}

main() {
    parse_args "$@"

    # Expose DEBUG to utilities that check it
    export DEBUG

    if [[ "$VERBOSE" == true ]]; then
        info "Running with VERBOSE=true"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "Running in DRY-RUN mode"
    fi

    if [[ "$DEBUG" -ne 0 ]]; then
        debug "Debug mode enabled"
    fi

    run "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
