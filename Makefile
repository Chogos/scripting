SHELL := /usr/bin/env bash

.PHONY: lint
lint:
	@echo "Running ShellCheck..."
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not found in PATH; please install it (brew install shellcheck / apt-get install shellcheck)"; exit 2; \
	fi
	@git ls-files 'scripts/**/*.sh' 'scripts/*.sh' | xargs -r shellcheck -x

.PHONY: new-script
new-script:
	@if [ -z "$(NAME)" ]; then echo "Usage: make new-script NAME=my-script"; exit 1; fi
	@cp scripts/__template.sh "scripts/$(NAME).sh"
	@chmod +x "scripts/$(NAME).sh"
	@echo "Created scripts/$(NAME).sh from template"

.PHONY: list
list:
	@echo "Available scripts:"
	@ls -1 scripts/*.sh | grep -v '__' | sed 's|scripts/||'
