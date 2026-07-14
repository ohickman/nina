#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

COUNT_MODE=false
TSV_MODE=false
DOT_MODE=false
for arg in "$@"; do
    case "$arg" in
        --count) COUNT_MODE=true ;;
        --tsv)   TSV_MODE=true ;;
        --dot)   DOT_MODE=true ;;
    esac
done

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
orphans_canon=()

while IFS= read -r title; do

    canonical="$(canonical_title "$title")"

    if [[ -z "${referenced[$canonical]}" ]]; then
        orphans+=("$title")
        orphans_canon+=("$canonical")
    fi

done < <(index_titles)

# -----------------------------------------
# tsv mode - for the TUI's generic list renderer (and any other
# machine consumer) - see "The canon/display Pair" in the
# technical guide's --tsv section. orphans_canon already holds
# each row's canonical form, computed above as part of identifying
# orphans in the first place - not recomputed here. Always emits
# the header, even with zero rows, checked before --count so a
# combination of both (unlikely, but not forbidden) favors the
# machine-readable answer. --dot (below) follows the same
# priority for the same reason.
# -----------------------------------------

if [[ "$TSV_MODE" == true ]]; then
    printf '#canon\tdisplay\n'
    for i in "${!orphans[@]}"; do
        printf '%s\t%s\n' "${orphans_canon[$i]}" "${orphans[$i]}"
    done
    exit 0
fi

# -----------------------------------------
# dot mode - problem-node style, per [[Nina - Devs: Graph Output
# Standard]]: an orphan has no incoming links TO draw - that's
# the whole point of it being orphaned - so there's no
# relationship to draw an edge for. Each orphan is a standalone
# node, styled with the config's problem color, same documented
# exception --dangling --dot follows. Unlike a dangling target,
# an orphan IS a real article, just an unreferenced one, so its
# label is left plain - no "(missing)"-style suffix, which would
# misdescribe it.
# -----------------------------------------

if [[ "$DOT_MODE" == true ]]; then
    dot_comment "nina --orphan --dot"
    dot_graph_open "nina_orphan" true
    for orphan in "${orphans[@]}"; do
        dot_node "$orphan" "style=\"rounded,filled\", fillcolor=\"$DOT_PROBLEM_NODE_COLOR\""
    done
    dot_graph_close
    exit 0
fi

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
