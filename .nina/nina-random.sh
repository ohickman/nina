#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

# -----------------------------------------
# BSD;iOS compatibiity helper
# -----------------------------------------
random_line() {
    if command -v shuf >/dev/null 2>&1; then
        shuf -n 1 "$1"
    else
        sort -R "$1" | head -n 1
    fi
}

# -----------------------------------------
# Select random article
# -----------------------------------------

# TITLE="$(shuf -n 1 "$INDEX_FILE" | awk -F'\t' '{print $2}')" # Linux only version
TITLE="$(random_line "$INDEX_FILE" | awk -F'\t' '{print $2}')"

[[ -z "$TITLE" ]] && die "No articles found."

# -----------------------------------------
# Open article
# -----------------------------------------

"$SCRIPT_DIR/nina" "$TITLE"