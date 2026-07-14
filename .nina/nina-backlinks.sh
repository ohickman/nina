#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

FORMAT="text"
TITLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tsv) FORMAT="tsv"; shift ;;
        --dot) FORMAT="dot"; shift ;;
        *) TITLE="$1"; shift ;;
    esac
done

[[ -z "$TITLE" ]] && die 'Usage: nina --backlinks "Article Title" [--tsv|--dot]'
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
matches_canon=()
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
        matches_canon+=("$src_canon")
        seen["$src"]=1
    fi

done < <(scan_links)

# -----------------------------------------
# tsv mode - for the TUI's generic list renderer (and any other
# machine consumer) - see "The canon/display Pair" in the
# technical guide's --tsv section. matches_canon already holds
# each row's canonical form, captured above from scan_links'
# own output rather than recomputed here. Always emits the
# header, even with zero rows, so an empty result set is a valid,
# parseable answer rather than something a consumer has to
# special-case.
# -----------------------------------------

if [[ "$FORMAT" == "tsv" ]]; then
    printf '#canon\tdisplay\n'
    for i in "${!matches[@]}"; do
        printf '%s\t%s\n' "${matches_canon[$i]}" "${matches[$i]}"
    done
    exit 0
fi

# -----------------------------------------
# dot mode - directed, one edge per linking article -> the
# queried title (see [[Nina - Devs: Graph Output Standard]]).
# No natural per-edge strength (a source article either links to
# the target or it doesn't - scan_links/matches already dedup to
# one row per linking article, see the "seen" guard above), so a
# constant strength of 1 is passed, same reasoning as
# nina-graph.sh. The queried title is looked up in title_map by
# its own canonical form so the node label is the article's real
# stored title rather than however the person typed/cased it;
# falls back to the raw input for a target that isn't an actual
# article in the corpus (a backlinks query against a dangling
# reference is still a valid question to ask). Declared explicitly
# via dot_node so it's still visible as its own node even with
# zero backlinks, same reasoning as nina-tree.sh's center node.
# -----------------------------------------

if [[ "$FORMAT" == "dot" ]]; then
    target_display="${title_map[$canonical_target]:-$TITLE}"
    dot_comment "nina --backlinks \"$TITLE\" --dot"
    dot_graph_open "nina_backlinks" true
    dot_node "$target_display"
    for i in "${!matches[@]}"; do
        dot_edge "${matches[$i]}" "$target_display" 1 true
    done
    dot_graph_close
    exit 0
fi

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
