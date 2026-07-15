#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# Argument parsing
#
# Same split nina-backlinks.sh uses: everything that isn't
# --tsv/--dot is the title. TITLE was previously just "$1" (no
# flag support at all) - this preserves "one title, however many
# words, as a single shell argument" for the common case while
# adding the two new flags anywhere in the argument list.
# -----------------------------------------

FORMAT="text"
TITLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tsv) FORMAT="tsv"; shift ;;
        --dot) FORMAT="dot"; shift ;;
        *) TITLE="$1"; shift ;;
    esac
done

[[ -z "$TITLE" ]] && die 'Usage: nina --links "Article Title" [--tsv|--dot]'

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

# SOURCE_DISPLAY: the article's real stored title (from its own
# header), not necessarily the casing/spacing the person typed or
# the alias they used to get here - same technique nina-tree.sh
# uses for CENTER_DISPLAY. Only needed for --dot's source node
# label; text mode already worked fine off whatever TITLE named.
SOURCE_DISPLAY="$(normalize_display_title "$(header_field "$(read_header "$FILE")" Title)")"

# -----------------------------------------
# Extract unique internal links
#
# Deliberately NOT resolved through resolve_split_target the way
# nina-graph.sh/nina-backlinks.sh/nina-orphan.sh/nina-dangling.sh
# resolve a scanned link's target - this command's whole job is
# to show exactly what this article's own [[...]] links say, only
# deduplicated by literal-text canonical form (dedup_titles), not
# folded onto whichever real article (if any) an anchor or alias
# ultimately points to. --tsv and --dot below report the same raw
# list, not a resolved one, for that reason this command's own
# meaning doesn't change just because it grew machine-readable
#output formats.
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

# -----------------------------------------
# tsv mode - one row per linked target, in the same order and
# with the same text extract_links/dedup_titles already produce
# for the human list - see "Machine-Readable Output (--tsv)" in
# [[Nina - Devs: Technical Guide]]. canon is computed fresh via
# canonical_title() rather than stored during dedup_titles (which
# only needs it transiently to compare), matching the canon/
# display pair convention every other --tsv mode uses. Header is
# load-bearing - emitted even when there are zero linked articles.
# -----------------------------------------

if [[ "$FORMAT" == "tsv" ]]; then
    printf '#canon\tdisplay\n'
    for target in "${links[@]}"; do
        printf '%s\t%s\n' "$(canonical_title "$target")" "$target"
    done
    exit 0
fi

# -----------------------------------------
# dot mode - directed, single source -> each direct outbound
# target (see [[Nina - Devs: Graph Output Standard (--dot)]]). The
# shallowest relationship graph in nina: one hop, # one source.
# No natural per-edge strength (this command shows which articles
# are linked, not how many times or how strongly - dedup_titles
# already collapses repeats), so a constant strength of 1 is
# passed, same reasoning as nina-graph.sh. The source is declared
# explicitly via dot_node so it's still visible as its own node
# even with zero outbound links.
# -----------------------------------------

if [[ "$FORMAT" == "dot" ]]; then
    dot_comment "nina --links \"$TITLE\" --dot"
    dot_graph_open "nina_links" true
    dot_node "$SOURCE_DISPLAY"
    for target in "${links[@]}"; do
        dot_edge "$SOURCE_DISPLAY" "$target" 1 true
    done
    dot_graph_close
    exit 0
fi

if [[ ${#links[@]} -eq 0 ]]; then
    echo "No linked articles."
    exit 0
fi

echo "---- Linked Articles ----"

print_numbered_list "${links[@]}"

open_article_menu "${links[@]}"
