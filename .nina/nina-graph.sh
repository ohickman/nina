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
    printf '    "%s" -> "%s";\n' "$src" "$target"
done

echo "}"