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

declare -A title_map
declare -A alias_map
declare -A dangling
declare -A seen

# -----------------------------------------
# Build the corpus title/alias maps via the
# shared library (nina-lib.sh: build_title_maps).
# -----------------------------------------

build_title_maps title_map alias_map

# -----------------------------------------
# Scan articles for links
#
# A target's own canonical form (target_canon,
# already computed once by scan_links) is tried
# first, unsplit, by resolve_split_target - the
# exact same fast path as before this change,
# zero extra cost, and it's also what makes a
# title that legitimately contains '#' resolve
# outright rather than ever being split. Only a
# target that both contains '#' AND fails that
# check pays for the backward walk through its
# '#' characters against title_map/alias_map -
# see resolve_split_target in nina-lib.sh for why
# that walk is safe to run over every
# dangling-looking link in the corpus (pure
# in-memory lookups, no per-link forking of
# resolve_article_file).
# -----------------------------------------

while IFS=$'\t' read -r src src_canon target target_canon; do

    is_dangling=true

    if resolve_split_target "$target" "$target_canon" title_map alias_map; then
        is_dangling=false
    fi

    if [[ "$is_dangling" == true ]]; then
        key="$target_canon"$'\x1f'"$src"
        if [[ -z "${seen[$key]}" ]]; then
            dangling["$target_canon"]+="$src"$'\x1f'
            seen["$key"]=1
        fi
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
    refs="${refs%$'\x1f'}"

    IFS=$'\x1f' read -ra sources <<< "$refs"

    for src in "${sources[@]}"; do
        printf "%-30s %-30s\n" \
        "$(trim_string "$target" 30)" \
        "$(trim_string "$src" 30)"
    done

done
