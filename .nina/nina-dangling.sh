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

declare -A existing
declare -A dangling
declare -A seen

# -----------------------------------------
# Build set of existing articles
# -----------------------------------------

while IFS= read -r title; do
    canonical="$(canonical_title "$title")"
    existing["$canonical"]=1
done < <(index_titles)

# -----------------------------------------
# Scan articles for links
# -----------------------------------------

while IFS=$'\t' read -r src src_canon target target_canon; do

    key="$target_canon|$src"

    if [[ -z "${existing[$target_canon]}" && -z "${seen[$key]}" ]]; then
        dangling["$target_canon"]+="$src|"
        seen["$key"]=1
    fi

done < <(scan_links)

# -----------------------------------------
# Return count or display results
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    echo "${#dangling[@]}"
    exit 0
fi

printf "\n"

printf "%-30s %-30s\n" \
    "DANGLING LINK" "REFERENCED IN"

printf "%-30s %-30s\n" \
    "------------------------------" \
    "------------------------------"

for target in "${!dangling[@]}"; do

    refs="${dangling[$target]}"
    refs="${refs%|}"

    IFS='|' read -ra sources <<< "$refs"

    for src in "${sources[@]}"; do
        printf "%-30s %-30s\n" \
        "$(trim_string "$target" 30)" \
        "$(trim_string "$src" 30)"
    done

done