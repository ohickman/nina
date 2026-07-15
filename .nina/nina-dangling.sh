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
# --count takes priority over --tsv/--dot if given alongside
# either (matches its previous behavior: an early exit with just
# the integer, before any display code ran at all).
# -----------------------------------------

COUNT_MODE=false
FORMAT="text"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --count) COUNT_MODE=true; shift ;;
        --tsv)   FORMAT="tsv"; shift ;;
        --dot)   FORMAT="dot"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
done

require_index

declare -A title_map
declare -A alias_map

# dangling_srcs[target_canon]        "src_display\x1f..." - every
#                                    referencing article's own
#                                    stored title, in first-seen
#                                    order
# dangling_srcs_canon[target_canon]  "src_canon\x1f..." - parallel
#                                    to dangling_srcs, same order,
#                                    same \x1f split points
# dangling_display[target_canon]     the dangling target's own
#                                    raw link text, first-seen
#                                    casing (see the scan loop
#                                    below for why this is safe
#                                    to use directly)
declare -A dangling_srcs
declare -A dangling_srcs_canon
declare -A dangling_display
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
#
# "target" (scan_links' third column) is safe to store and print
# directly, same guarantee "Titles Are Delimiter-Safe" gives a
# real title: nina-scan-links.awk runs it through the same
# whitespace-collapsing normalize_display() step a real title
# gets before it's ever emitted, so it can't carry a literal tab
# or newline by the time it reaches here - it just isn't
# guaranteed to name a real article, which is exactly what
# "dangling" means. Kept in its first-seen casing (not
# canonicalized) as dangling_display, since that's far more
# legible than the lowercased comparison form in a --dot label
# or a --tsv column meant for a person to read.
# -----------------------------------------

while IFS=$'\t' read -r src src_canon target target_canon; do

    is_dangling=true

    if resolve_split_target "$target" "$target_canon" title_map alias_map; then
        is_dangling=false
    fi

    if [[ "$is_dangling" == true ]]; then
        key="$target_canon"$'\x1f'"$src"
        if [[ -z "${seen[$key]}" ]]; then
            dangling_srcs["$target_canon"]+="$src"$'\x1f'
            dangling_srcs_canon["$target_canon"]+="$src_canon"$'\x1f'
            seen["$key"]=1
        fi
        [[ -z "${dangling_display[$target_canon]:-}" ]] && dangling_display["$target_canon"]="$target"
    fi

done < <(scan_links)

# -----------------------------------------
# Return count or display results
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    echo "${#dangling_srcs[@]}"
    exit 0
fi

# -----------------------------------------
# tsv mode - one row per (dangling target, referencing article)
# pair, the same grain the human table already shows - see
# "Machine-Readable Output (--tsv)" in [[Nina - Devs: Technical
# Guide]]. target_display/target_canon are a superset of what the
# table shows (the table only ever printed the canonical form);
# source_canon/source_display follow the same canon/display pair
# convention every other --tsv mode uses for a real title. Header
# is load-bearing - emitted even when there are zero dangling
# links, same as everywhere else in the contract.
# -----------------------------------------

if [[ "$FORMAT" == "tsv" ]]; then
    printf '#target_canon\ttarget_display\tsource_canon\tsource_display\n'
    for target in "${!dangling_srcs[@]}"; do
        refs="${dangling_srcs[$target]%$'\x1f'}"
        refs_canon="${dangling_srcs_canon[$target]%$'\x1f'}"
        IFS=$'\x1f' read -ra sources <<< "$refs"
        IFS=$'\x1f' read -ra sources_canon <<< "$refs_canon"
        for i in "${!sources[@]}"; do
            printf '%s\t%s\t%s\t%s\n' \
                "$target" "${dangling_display[$target]}" \
                "${sources_canon[$i]}" "${sources[$i]}"
        done
    done
    exit 0
fi

# -----------------------------------------
# dot mode - problem-node style, per [[Nina - Devs: Graph Output
# Standard (--dot)]]: a dangling target isn't a real article, so there's
# no relationship to draw an edge for - each one is a standalone
# node, styled with the config's problem color, labeled with
# " (missing)" appended so it's visually obvious in the rendered
# image that this isn't a real article. No dot_edge calls at all,
# same documented exception --orphan --dot follows.
# -----------------------------------------

if [[ "$FORMAT" == "dot" ]]; then
    dot_comment "nina --dangling --dot"
    dot_graph_open "nina_dangling" true
    for target in "${!dangling_srcs[@]}"; do
        dot_node "${dangling_display[$target]} (missing)" \
            "style=\"rounded,filled\", fillcolor=\"$DOT_PROBLEM_NODE_COLOR\""
    done
    dot_graph_close
    exit 0
fi

printf "\n"

printf "%-30s %-30s\n" \
    "DANGLING LINK" "REFERENCED IN"

printf "%-30s %-30s\n" \
    "------------------------------" \
    "------------------------------"

for target in "${!dangling_srcs[@]}"; do

    refs="${dangling_srcs[$target]}"
    refs="${refs%$'\x1f'}"

    IFS=$'\x1f' read -ra sources <<< "$refs"

    for src in "${sources[@]}"; do
        printf "%-30s %-30s\n" \
        "$(trim_string "$target" 30)" \
        "$(trim_string "$src" 30)"
    done

done
