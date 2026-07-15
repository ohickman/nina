#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

TAG=""
COUNT_MODE=false
TSV_MODE=false

for arg in "$@"; do
    case "$arg" in
        --count) COUNT_MODE=true ;;
        --tsv)   TSV_MODE=true ;;
        *)       TAG="$arg" ;;
    esac
done

[[ -z "$TAG" ]] && die "Usage: nina -t <tag> [--count] [--tsv]"
require_index

# -----------------------------------------
# Canonicalize input tag
# -----------------------------------------

canonical_tag="$(canonical_tag "$TAG")"

# -----------------------------------------
# tsv mode - for the TUI's generic list renderer (and any other
# machine consumer) - see "The canon/display Pair" in the
# technical guide's --tsv section. Always emits the header, even
# on zero matches. Checked before --count so a combination of
# both (unlikely, but not forbidden) favors the machine-readable
# answer, same priority nina-search.sh and others use for the
# same reason. Same row-selection test as count mode and the
# display loop below, each kept as its own independent pass.
# -----------------------------------------

if [[ "$TSV_MODE" == true ]]; then
    printf '#canon\tdisplay\tmodified\ttags\n'
    while IFS=$'\t' read -r title modified tags; do
        [[ " $tags " == *" $canonical_tag "* ]] || continue
        canon="$(canonical_title "$title")"
        printf '%s\t%s\t%s\t%s\n' "$canon" "$title" "$modified" "$tags"
    done < <(index_display_rows)
    exit 0
fi

# -----------------------------------------
# Count mode - print matching article count
# and exit, same pattern as --orphan --count
# and --dangling --count
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    # index_display_rows gives one "title TAB date TAB tags" row per
    # article with tags already space-joined; whether an article
    # carries the tag is this script's row selection. Wrapping both
    # sides in spaces makes " $tag " an exact whole-token match, so
    # "c" never matches inside "c++". (Index tags are lowercase and
    # space-free, matching canonical_tag's normalization.)
    count=0
    while IFS=$'\t' read -r title modified tags; do
        [[ " $tags " == *" $canonical_tag "* ]] && ((count++))
    done < <(index_display_rows)
    echo "$count"
    exit 0
fi

printf "\n"

table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
table_header

titles=()
i=0

# -----------------------------------------
# Filter matching articles
# -----------------------------------------

# index_display_rows is already sorted case-insensitively by title
# (matching the old `sort -f`), so filtering it in place preserves
# the original ordering; tags arrive space-joined for the table.
while IFS=$'\t' read -r title modified tags; do

    [[ " $tags " == *" $canonical_tag "* ]] || continue

    ((i++))
    titles+=("$title")

    table_row "$i" "$title" "$modified" "$tags"

done < <(index_display_rows)

# -----------------------------------------
# Interactive navigation
# -----------------------------------------

[[ -t 1 ]] && open_article_menu "${titles[@]}"