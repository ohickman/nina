#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

printf "\n"

table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
table_header

# -----------------------------------------
# Sort and display
# -----------------------------------------

titles=()

i=0

while IFS=$'\t' read -r title modified tags; do

    ((i++))
    titles+=("$title")

    table_row "$i" "$title" "$modified" "$tags"

done < <(index_display_rows)

# -----------------------------------------
# Interactive navigation
# -----------------------------------------

if [[ -t 1 ]]; then
    open_article_menu "${titles[@]}"
fi