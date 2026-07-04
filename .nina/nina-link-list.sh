#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

TITLE="$1"

[[ -z "$TITLE" ]] && die 'Usage: nina --links "Article Title"'

require_index

# -----------------------------------------
# Resolve title to file (alias-aware).
#
# A real title wins; an alias resolves only on a
# main-index miss. This is what lets `nina --links
# <alias>` work, and what nina-view relies on when
# it forwards the user's input here unchanged.
# -----------------------------------------

canonical_input="$(canonical_title "$TITLE")"
FILE="$(resolve_article_file "$canonical_input")"

[[ -z "$FILE" ]] && die "Article not found: $TITLE"

# -----------------------------------------
# Extract unique internal links
# -----------------------------------------

mapfile -t links < <(
    extract_links "$FILE" |
    while read -r link; do
        target="$(link_target "$link")"
        target="$(normalize_display_title "$target")"
        printf '%s\n' "$target"
    done |
    dedup_titles
)

if [[ ${#links[@]} -eq 0 ]]; then
    echo "No linked articles."
    exit 0
fi

echo "---- Linked Articles ----"

print_numbered_list "${links[@]}"

open_article_menu "${links[@]}"