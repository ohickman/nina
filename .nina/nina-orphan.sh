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

# -----------------------------------------
# Build the corpus title/alias maps via the
# shared library (nina-lib.sh: build_title_maps).
# Needed for the same reason as nina-backlinks.sh
# and nina-dangling.sh: a link like
# "Title#Heading" only equals target_canon as a
# whole, never the real title's own canonical
# form, so recording it as a raw, unsplit key
# would never count as a reference to the real
# article - an anchor-only-linked article would
# look orphaned even though it plainly isn't.
# -----------------------------------------

declare -A title_map
declare -A alias_map

build_title_maps title_map alias_map

declare -A referenced

# -----------------------------------------
# Scan all articles for outbound links
#
# resolve_split_target records a target's own
# canonical form first, unsplit - identical cost
# to before for the common case. Only a target
# that both contains '#' and fails that check
# walks its anchor split (see resolve_split_target
# in nina-lib.sh), marking the real title it
# resolves to (never the raw, anchor-still-
# attached string) as referenced. A target that
# resolves to nothing marks nothing, same as
# today - it was always harmless noise here,
# since only real titles are ever queried against
# this set below.
# -----------------------------------------

while IFS=$'\t' read -r src src_canon target target_canon; do

    if resolve_split_target "$target" "$target_canon" title_map alias_map; then
        referenced["$NINA_SPLIT_CANON"]=1
    fi

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
