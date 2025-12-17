SHELL := /usr/bin/env bash

.PHONY: lint
lint:
	@echo "Running ShellCheck on scripting/"
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not found in PATH; please install it (brew install shellcheck / apt-get install shellcheck)"; exit 2; \
	fi
	@git ls-files 'scripting/**/*.sh' 'scripting/*.sh' | xargs -r shellcheck -x
