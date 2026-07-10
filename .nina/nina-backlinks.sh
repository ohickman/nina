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
# Build the corpus title/alias maps via the
# shared library (nina-lib.sh: build_title_maps).
# Needed for the same reason nina-dangling.sh
# needs them: a link target like "Title#Heading"
# only equals target_canon as a whole, not the
# real title's canonical form, so matching it
# against a query requires the same backward
# search resolve_split_target performs.
# -----------------------------------------

declare -A title_map
declare -A alias_map

build_title_maps title_map alias_map

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
#
# resolve_split_target tries a link's own
# target_canon first, unsplit, against the maps -
# identical cost to before for the common case,
# no forking. Only a target that both contains
# '#' and fails that check walks backward through
# its anchor split (see resolve_split_target in
# nina-lib.sh), resolving to the real article's
# own canonical form, which is then compared
# against the query.
# -----------------------------------------

matches=()
declare -A seen

while IFS=$'\t' read -r src src_canon target target_canon; do

    is_match=false

    if [[ "$target_canon" == "$canonical_target" ]]; then
        is_match=true
    elif [[ "$target" == *"#"* ]] && resolve_split_target "$target" "$target_canon" title_map alias_map; then
        [[ "$NINA_SPLIT_CANON" == "$canonical_target" ]] && is_match=true
    fi

    if [[ "$is_match" == true && -z "${seen[$src]}" ]]; then
        matches+=("$src")
        seen["$src"]=1
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
