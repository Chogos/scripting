#!/usr/bin/env bash
set -Eeuo pipefail

# Convert 'devbox global list' output into a devbox.json file
# Usage: ./devbox-global-list-to-json.sh

# Source shared utilities
SCRIPTDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPTDIR
# shellcheck source=__utils.sh
. "$SCRIPTDIR/__utils.sh"

ensure_commands devbox gum

OUTPUT_FILE="devbox.json"

# Get packages from devbox global list
PACKAGES_RAW=$(gum spin --spinner dot --title "Fetching global packages..." -- bash -c "devbox global list 2>/dev/null | sed -n 's/^\* \([^ ]*\).*/\1/p'")

if [[ -z "$PACKAGES_RAW" ]]; then
    gum style --foreground 1 "No global packages found. Use 'devbox global add <package>' to install packages globally." >&2
    exit 1
fi

# Convert to JSON array format
PACKAGES=""
while IFS= read -r pkg; do
    if [[ -n "$PACKAGES" ]]; then
        PACKAGES="$PACKAGES,
    \"$pkg\""
    else
        PACKAGES="\"$pkg\""
    fi
done <<< "$PACKAGES_RAW"

# Create devbox.json
if [[ -f "$OUTPUT_FILE" ]]; then
    if ! gum confirm "File $OUTPUT_FILE already exists. Override?"; then
        gum style --foreground 3 "Aborted."
        exit 0
    fi
fi
cat > "$OUTPUT_FILE" << EOF
{
  "\$schema": "https://raw.githubusercontent.com/jetify-com/devbox/0.16.0/.schema/devbox.schema.json",
  "packages": [
    $PACKAGES
  ],
  "shell": {
    "init_hook": [
      "echo 'Welcome to devbox!' > /dev/null"
    ],
    "scripts": {
      "test": [
        "echo \"Error: no test specified\" && exit 1"
      ]
    }
  }
}
EOF

gum style --foreground 2 "Created $OUTPUT_FILE successfully from global devbox packages!"
