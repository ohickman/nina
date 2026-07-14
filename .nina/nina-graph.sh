#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

# -----------------------------------------
# Argument parsing
#
# --dot is the long-standing default (this command predates
# --tsv existing at all) and stays the default so a bare
# `nina --graph` keeps working unchanged for anyone already
# piping it into `dot`/`sfdp`. --tsv is available alongside it
# for machine consumers that want the same edge set as plain
# rows instead of Graphviz source.
# -----------------------------------------

FORMAT="dot"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dot) FORMAT="dot"; shift ;;
        --tsv) FORMAT="tsv"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

# -----------------------------------------
# Build the corpus title/alias maps via the
# shared library (nina-lib.sh: build_title_maps).
#
# This script draws one edge per link using the
# target's own display text as the node label -
# an anchored link like "Other Article#Some
# Heading" would otherwise become its own node,
# splitting a real article's incoming edges
# across two labels instead of merging them onto
# one. resolve_split_target below resolves the
# anchor to the real article's own display title
# for exactly that reason.
# -----------------------------------------

declare -A title_map
declare -A alias_map

build_title_maps title_map alias_map

if [[ "$FORMAT" == "dot" ]]; then
    dot_comment "nina --graph --dot"
    dot_graph_open "nina" true
fi

if [[ "$FORMAT" == "tsv" ]]; then
    printf '#src_canon\tsrc\ttarget_canon\ttarget\n'
fi

# -----------------------------------------
# resolve_split_target uses a target already
# matching a real title as-is - identical cost to
# before for the common case - and otherwise
# walks its anchor split (see resolve_split_target
# in nina-lib.sh), swapping in the real article's
# own display title as the edge's endpoint. A
# target that resolves to nothing keeps its raw
# display text unchanged, same as today - still
# visibly a dangling-looking node, not silently
# merged into anything.
#
# This graph only means to show article-to-
# article connectivity, not link count, so two
# links from the same source that resolve to
# the same real target - e.g. a plain [[Title]]
# and an anchored [[Title#Heading]] side by side
# in one article - are one edge, not two. Dedup
# is keyed on the RESOLVED pair (src_canon,
# resolved target's own canonical form) and lives
# entirely in this loop - it does not touch
# scan_links's own dedup, which stays keyed on
# raw pre-resolution text for the other five
# consumers that need it that way.
# -----------------------------------------

declare -A printed_edge

while IFS=$'\t' read -r src src_canon target target_canon; do

    resolved_target="$target"
    resolved_target_canon="$target_canon"

    # Only resolve through the split when the raw target doesn't
    # already match a real title directly - preserves the
    # as-typed link text for the common, unanchored case, same
    # as before this was moved to the shared library.
    if [[ -z "${title_map[$target_canon]:-}" ]] && resolve_split_target "$target" "$target_canon" title_map alias_map; then
        resolved_target="$NINA_SPLIT_DISPLAY"
        resolved_target_canon="$NINA_SPLIT_CANON"
    fi

    edge_key="$src_canon"$'\x1f'"$resolved_target_canon"
    [[ -n "${printed_edge[$edge_key]:-}" ]] && continue
    printed_edge["$edge_key"]=1

    case "$FORMAT" in
        dot)
            # --graph only ever shows article-to-article
            # connectivity, never a link count (see the dedup
            # comment above) - there is no natural per-edge
            # strength to weight or label with here, unlike
            # every other --dot mode. A constant strength of 1
            # is passed so this graph still renders through the
            # same dot_edge() every relationship graph uses
            # (uniform penwidth floor, honors DOT_SHOW_EDGE_LABELS
            # like everything else) rather than hand-rolling a
            # one-off unweighted edge line here.
            dot_edge "$src" "$resolved_target" 1 true
            ;;
        tsv)
            printf '%s\t%s\t%s\t%s\n' "$src_canon" "$src" "$resolved_target_canon" "$resolved_target"
            ;;
    esac
done < <(scan_links)

[[ "$FORMAT" == "dot" ]] && dot_graph_close

exit 0
