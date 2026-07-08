#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

echo "digraph nina {"
echo "    rankdir=LR;"
echo

scan_links | while IFS=$'\t' read -r src src_canon target target_canon; do
    dot_src=$(printf '%s' "$src" | sed 's/\\/\\\\/g; s/"/\\"/g')
    dot_target=$(printf '%s' "$target" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '    "%s" -> "%s";\n' "$dot_src" "$dot_target"
done

echo "}"
