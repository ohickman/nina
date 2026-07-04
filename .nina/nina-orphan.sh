#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

COUNT_MODE=false
[[ "$1" == "--count" ]] && COUNT_MODE=true

require_index

declare -A referenced

# -----------------------------------------
# Scan all articles for outbound links
# -----------------------------------------

while IFS=$'\t' read -r src src_canon target target_canon; do
    referenced["$target_canon"]=1
done < <(scan_links)

# -----------------------------------------
# Identify orphan articles
# -----------------------------------------

orphans=()

while IFS= read -r title; do

    canonical="$(canonical_title "$title")"

    if [[ -z "${referenced[$canonical]}" ]]; then
        orphans+=("$title")
    fi

done < <(index_titles)

# -----------------------------------------
# Return count or display results
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    echo "${#orphans[@]}"
    exit 0
fi

if [[ ${#orphans[@]} -eq 0 ]]; then
    info "No orphan articles found."
    exit 0
else

echo
echo "---- Orphan Articles ----"

print_numbered_list "${orphans[@]}"

open_article_menu "${orphans[@]}"
fi