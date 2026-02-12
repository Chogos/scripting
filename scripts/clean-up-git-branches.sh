#!/usr/bin/env bash
set -Eeuo pipefail

# Git Merged Branch Cleanup
# Description: Deletes local branches that have been merged into the default branch
# Usage: ./clean-up-git-branches.sh [-f] [-h]

# Source shared utilities
SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPTDIR
# shellcheck source=__utils.sh
. "$SCRIPTDIR/__utils.sh"

# shellcheck disable=SC2155
readonly SCRIPT_NAME="$(basename "${0}")"
readonly PROTECTED_BRANCHES="main|master|develop"

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Deletes local branches that have been merged into the default branch.
Protects ${PROTECTED_BRANCHES//|/, } and the currently checked-out branch.

OPTIONS:
    -f, --force    Skip confirmation prompt
    -h, --help     Show this help message

EXAMPLES:
    ${SCRIPT_NAME}            # Interactive mode with confirmation
    ${SCRIPT_NAME} -f         # Delete without confirmation
EOF
}

# Determine the default branch from origin/HEAD
get_default_branch() {
    local raw_ref
    raw_ref="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"

    if [[ -z "${raw_ref}" ]]; then
        die "Could not determine default branch. Run: git remote set-head origin --auto"
    fi

    printf '%s' "${raw_ref#refs/remotes/origin/}"
}

main() {
    local force=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    ensure_commands git

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "Not inside a git repository"
    fi

    local default_branch
    default_branch="$(get_default_branch)"

    local current_branch
    current_branch="$(git branch --show-current)"

    local merged_branches
    merged_branches="$(git branch --merged "${default_branch}" --format='%(refname:short)' \
        | grep -vE "^(${PROTECTED_BRANCHES}|${default_branch}|${current_branch})\$" || true)"

    if [[ -z "${merged_branches}" ]]; then
        info "No merged branches to clean up."
        exit 0
    fi

    local branch_count
    branch_count="$(printf '%s\n' "${merged_branches}" | wc -l | tr -d ' ')"

    info "Found ${branch_count} branch(es) merged into ${default_branch}:"
    while IFS= read -r branch; do
        printf "  %s\n" "${branch}"
    done <<< "${merged_branches}"
    printf '\n'

    if [[ "${force}" -eq 0 ]]; then
        if ! confirm "Delete these branches?"; then
            warn "Aborted."
            exit 0
        fi
    fi

    while IFS= read -r branch; do
        if git branch -d "${branch}" >/dev/null 2>&1; then
            info "Deleted ${branch}"
        else
            warn "Failed to delete ${branch}"
        fi
    done <<< "${merged_branches}"

    info "Done."
}

main "$@"
