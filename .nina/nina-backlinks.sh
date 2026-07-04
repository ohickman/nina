#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

TITLE="$1"

[[ -z "$TITLE" ]] && die 'Usage: nina --backlinks "Article Title"'
require_index

# -----------------------------------------
# Canonicalize input title
# -----------------------------------------

canonical_target=$(canonical_title "$TITLE")

# De-alias the query: backlinks of an alias means backlinks of
# the real article it names. Lines the query up with scan_links,
# which de-aliases link targets the same way. No-op when off.
canonical_target=$(dealias_canonical "$canonical_target")

# -----------------------------------------
# Scan articles for links pointing to target
# -----------------------------------------

matches=()
declare -A seen

while IFS=$'\t' read -r src src_canon target target_canon; do

    if [[ "$target_canon" == "$canonical_target" ]]; then
        if [[ -z "${seen[$src]}" ]]; then
            matches+=("$src")
            seen["$src"]=1
        fi
    fi

done < <(scan_links)

# -----------------------------------------
# Display results
# -----------------------------------------

if [[ ${#matches[@]} -eq 0 ]]; then
    info "No backlinks found."
    exit 0
else

    echo
    echo "---- Backlinks ----"

    print_numbered_list "${matches[@]}"

    echo
    open_article_menu "${matches[@]}"
fi