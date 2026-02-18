#!/usr/bin/env bash
set -Eeuo pipefail

# Claude Skills Refresher
# Description: Refresh all Claude skill repositories under the skills directory
# Usage: ./refresh-claude-skills.sh [-n] [-v] [-c FILE] [-h]

# Source shared utilities
SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPTDIR
# shellcheck source=__utils.sh
. "$SCRIPTDIR/__utils.sh"

SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
REPOS_CACHE_DIR=""
DRY_RUN=false
VERBOSE=false
CLONE_FILE=""
DEFAULT_CLONE_FILE="$SCRIPTDIR/data/claude-skill-clone-list.txt"

usage() {
	cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -n, --dry-run        Show what would be done, don't run git commands
  -v, --verbose        Print more output
  -c, --clone-file F   Read clone list from file (lines: <git-url> [subpath])
  -h, --help           Show this help

Description:
  Refresh all Claude skill repositories located under $SKILLS_DIR.
  For each repo the script will fetch, prune remotes and try to pull
  updates (using rebase + autostash). It will also init/update submodules.

  Clone file format:
    <git-url>              Clone full repo into skills dir
    <git-url> <subpath>    Clone repo to .repos cache, symlink subpath
EOF
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-n | --dry-run)
			DRY_RUN=true
			shift
			;;
		-v | --verbose)
			VERBOSE=true
			shift
			;;
		-c | --clone-file)
			CLONE_FILE="$2"
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			die "Unknown option: $1"
			;;
		esac
	done
}

clone_full_repo() {
	local url="$1" target="$2"
	if [[ -d "$target" ]]; then
		debug "Repo already cloned: $target"
		return 0
	fi
	info "Cloning $url -> $target"
	if ! run_cmd git clone --recurse-submodules --shallow-submodules --depth 1 "$url" "$target" >/dev/null 2>&1; then
		warn "Clone failed for $target"
		failed=$((failed + 1))
		FAILED_LIST+=("$target")
		return 1
	fi
	return 0
}

clone_repos() {
	if [[ -z "$CLONE_FILE" ]]; then
		return
	fi

	if [[ ! -f "$CLONE_FILE" ]]; then
		die "Clone file '$CLONE_FILE' not found" 2
	fi

	info "Cloning repositories from: $CLONE_FILE"
	while IFS= read -r line || [[ -n "$line" ]]; do
		# skip blank lines & comments
		[[ -z "$line" || "$line" =~ ^# ]] && continue
		url=$(awk '{print $1}' <<<"$line")
		subpath=$(awk '{print $2}' <<<"$line")
		repo_name=$(basename -s .git "$url")

		if [[ -n "$subpath" ]]; then
			# Subpath mode: clone full repo into .repos cache
			mkdir -p "$REPOS_CACHE_DIR"
			local cache_dir="$REPOS_CACHE_DIR/$repo_name"
			clone_full_repo "$url" "$cache_dir"
		else
			# Full repo mode: clone directly into skills dir
			local target="$SKILLS_DIR/$repo_name"
			if [[ -d "$target" ]]; then
				info "Exists, skipping clone: $target"
				skipped=$((skipped + 1))
				SKIPPED_LIST+=("$target")
			else
				clone_full_repo "$url" "$target"
			fi
		fi
	done <"$CLONE_FILE"
}

create_symlinks() {
	if [[ -z "$CLONE_FILE" ]]; then
		return
	fi

	info "Creating symlinks for subpath entries"
	while IFS= read -r line || [[ -n "$line" ]]; do
		# skip blank lines & comments
		[[ -z "$line" || "$line" =~ ^# ]] && continue
		url=$(awk '{print $1}' <<<"$line")
		subpath=$(awk '{print $2}' <<<"$line")
		repo_name=$(basename -s .git "$url")

		# Only process subpath entries
		[[ -z "$subpath" ]] && continue

		local cache_dir="$REPOS_CACHE_DIR/$repo_name"
		local src="$cache_dir/$subpath"
		if [[ ! -d "$src" ]]; then
			warn "Subpath '$subpath' not found in $repo_name"
			failed=$((failed + 1))
			FAILED_LIST+=("$repo_name/$subpath")
			continue
		fi

		local link="$SKILLS_DIR/$subpath"
		if [[ -L "$link" ]]; then
			info "Symlink exists, skipping: $link"
			skipped=$((skipped + 1))
			SKIPPED_LIST+=("$link")
		elif [[ -e "$link" ]]; then
			warn "Non-symlink already exists at $link, skipping"
			skipped=$((skipped + 1))
			SKIPPED_LIST+=("$link")
		else
			info "Linking $repo_name/$subpath -> $link"
			run_cmd ln -s "$src" "$link"
		fi
	done <"$CLONE_FILE"
}

refresh_repo() {
	local d="$1"
	local name
	name=$(basename "$d")

	if [[ ! -d "$d/.git" ]]; then
		info "Not a git repo, skipping: $name"
		notgit=$((notgit + 1))
		return
	fi

	info "Refreshing: $name"

	# fetch/prune tags & remotes
	if ! run_cmd git -C "$d" fetch --all --prune --tags --quiet; then
		warn "Fetch failed for $name"
	fi

	# remote prune
	if ! run_cmd git -C "$d" remote prune origin; then
		warn "Remote prune failed for $name"
	fi

	# try pull with rebase + autostash
	if [[ "$DRY_RUN" == true ]]; then
		debug "DRY RUN: would pull $name"
		skipped=$((skipped + 1))
		SKIPPED_LIST+=("$name")
	else
		local rc=0
		local out
		out=$(git -C "$d" pull --rebase --autostash 2>&1) || rc=$?
		if [[ "$rc" -eq 0 ]]; then
			if printf '%s' "$out" | grep -qE 'Already up to date|Already up-to-date'; then
				info "Up to date: $name"
				uptodate=$((uptodate + 1))
				UPTODATE_LIST+=("$name")
			else
				info "Updated: $name"
				updated=$((updated + 1))
				UPDATED_LIST+=("$name")
			fi
		else
			warn "Pull failed or merge conflict for $name. Attempting fallback operations."

			local rc2=0
			git -C "$d" fetch --all --prune --quiet 2>/dev/null || rc2=$?
			if [[ "$rc2" -eq 0 ]]; then
				local branch
				branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
				local rc3=0
				git -C "$d" rebase --autostash "origin/${branch}" 2>&1 || rc3=$?
				if [[ "$rc3" -eq 0 ]]; then
					info "Rebased: $name"
					updated=$((updated + 1))
					UPDATED_LIST+=("$name")
				else
					warn "Fallback rebase failed for $name"
					failed=$((failed + 1))
					FAILED_LIST+=("$name")
				fi
			else
				warn "Fetch failed during fallback for $name"
				failed=$((failed + 1))
				FAILED_LIST+=("$name")
			fi
		fi
	fi

	# update submodules if present
	if [[ -f "$d/.gitmodules" ]]; then
		info "Updating submodules for $name"
		run_cmd git -C "$d" submodule update --init --recursive --quiet
	fi

	# housekeeping
	run_cmd git -C "$d" gc --auto --quiet || true
}

print_summary() {
	printf '\nSummary:\n'
	printf '  Updated: %s\n' "$updated"
	printf '  Up-to-date: %s\n' "$uptodate"
	printf '  Skipped (exist): %s\n' "$skipped"
	printf '  Failed:  %s\n' "$failed"
	printf '  Not Git: %s\n' "$notgit"

	if [[ ${#UPDATED_LIST[@]} -gt 0 ]]; then
		printf '\nUpdated repos:\n'
		for i in "${UPDATED_LIST[@]}"; do printf '  - %s\n' "$i"; done
	fi
	if [[ ${#UPTODATE_LIST[@]} -gt 0 ]]; then
		printf '\nUp-to-date repos:\n'
		for i in "${UPTODATE_LIST[@]}"; do printf '  - %s\n' "$i"; done
	fi
	if [[ ${#SKIPPED_LIST[@]} -gt 0 ]]; then
		printf '\nSkipped:\n'
		for i in "${SKIPPED_LIST[@]}"; do printf '  - %s\n' "$i"; done
	fi
	if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
		printf '\nFailed repos:\n'
		for i in "${FAILED_LIST[@]}"; do printf '  - %s\n' "$i"; done
	fi

	if [[ "$DRY_RUN" == true ]]; then
		info "Dry run - no changes were made."
	fi
}

main() {
	parse_args "$@"

	# if user didn't pass -c and default file exists, use it
	if [[ -z "$CLONE_FILE" ]] && [[ -f "$DEFAULT_CLONE_FILE" ]]; then
		CLONE_FILE="$DEFAULT_CLONE_FILE"
		info "Using default clone file: $CLONE_FILE"
	fi

	mkdir -p "$SKILLS_DIR"
	REPOS_CACHE_DIR="$SKILLS_DIR/.repos"
	info "Using skills directory: $SKILLS_DIR"

	# counters
	updated=0
	uptodate=0
	skipped=0
	failed=0
	notgit=0

	# lists for detail output
	SKIPPED_LIST=()
	UPTODATE_LIST=()
	UPDATED_LIST=()
	FAILED_LIST=()

	clone_repos

	if [[ -d "$REPOS_CACHE_DIR" ]]; then
		for d in "$REPOS_CACHE_DIR"/*; do
			[[ -e "$d" ]] || continue
			refresh_repo "$d"
		done
	fi
	create_symlinks

	# Refresh direct repos (skip symlinks — those point into .repos)
	for d in "$SKILLS_DIR"/*; do
		[[ -e "$d" ]] || continue
		[[ -L "$d" ]] && continue
		refresh_repo "$d"
	done

	print_summary
}

main "$@"
