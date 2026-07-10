#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

# =====================================================
# nina-tag-graph.sh
#
# Three views onto how tags (and the articles carrying
# them) relate to one another:
#
#   cooccur  - which tags are frequently applied to the
#              SAME article together (e.g. "c++" and
#              "programming" both showing up on many
#              articles), regardless of any links.
#
#   links    - which tags articles LINK FROM tend to
#              point at which tags the target articles
#              carry, aggregated across the whole corpus.
#              This is scan_links (the same data
#              nina --graph draws) rolled up from the
#              article level to the tag level.
#
#   islands  - connected components of the article link
#              graph (links treated as undirected purely
#              for reachability), so a cluster of
#              articles that only ever link to each
#              other - and never to anything outside the
#              cluster - shows up as its own group. An
#              optional --tag restricts this to the
#              subgraph induced by one tag, e.g. "are all
#              the 'c++' articles one connected web, or
#              several separate pockets?"
#
# Every mode shares the same four output formats:
#   table (default) - a readable summary in the terminal
#   tree             - a boxed, nina-tree-style listing
#   tsv              - plain tab-separated rows, for
#                      piping into other tools
#   dot              - Graphviz source, same convention
#                      as nina --graph, for `dot -Tpng`
# =====================================================

# -----------------------------------------
# Usage / argument parsing
#
# The mode (cooccur|links|islands) is a required
# positional argument, mirroring how nina --tag already
# splits on "is there a second argument" rather than
# using its own named flag for the tag itself.
# -----------------------------------------

usage() {
    die 'Usage: nina --tag-graph <cooccur|links|islands> [--table|--tree|--tsv|--dot] [--top N] [--min N] [--tag TAG]'
}

MODE="${1:-}"
case "$MODE" in
    cooccur|links|islands) shift ;;
    *) usage ;;
esac

FORMAT="table"
TOP=25
MIN=""
TAG_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --table)     FORMAT="table"; shift ;;
        --tree)      FORMAT="tree";  shift ;;
        --tsv)       FORMAT="tsv";   shift ;;
        --dot)       FORMAT="dot";   shift ;;
        --top=*)     TOP="${1#*=}"; shift ;;
        --top)       TOP="$2"; shift 2 ;;
        --min=*)     MIN="${1#*=}"; shift ;;
        --min)       MIN="$2"; shift 2 ;;
        --tag=*)     TAG_FILTER="$(canonical_tag "${1#*=}")"; shift ;;
        --tag)       TAG_FILTER="$(canonical_tag "$2")"; shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ "$TOP" =~ ^[0-9]+$ ]] || die "Invalid --top value: $TOP (must be a whole number, 0 for unlimited)"
[[ -n "$MIN" && ! "$MIN" =~ ^[0-9]+$ ]] && die "Invalid --min value: $MIN (must be a whole number)"

# MIN's default depends on what it's counting: a co-occurrence
# or link count of 1 is still worth showing, but a "component"
# of size 1 is just an ordinary orphan article, not an island -
# so islands defaults to hiding singletons unless asked for them
# with --min 1.
if [[ -z "$MIN" ]]; then
    if [[ "$MODE" == "islands" ]]; then MIN=2; else MIN=1; fi
fi

# -----------------------------------------
# Shared small helpers
# -----------------------------------------

# limit_rows: `head -n N`, but N=0 means unlimited.
limit_rows() {
    if (( TOP > 0 )); then
        head -n "$TOP"
    else
        cat
    fi
}

# scaled_weight COUNT
# Maps a raw count onto a modest Graphviz penwidth range
# so heavily-weighted edges are visually heavier without
# a handful of outlier counts making everything else look
# like a hairline by comparison.
scaled_weight() {
    awk -v c="$1" 'BEGIN { w = 1 + c/5; if (w > 6) w = 6; printf "%.1f", w }'
}

# Heading style for --tree output, same override pattern
# nina-tree.sh uses for TREE_CENTER_STYLE: read from config
# if the person set it, otherwise default to bold. ":+isset"
# form (not ":=") so a config that deliberately sets this to
# "" for no styling is respected rather than clobbered.
if [[ -z "${TAG_GRAPH_HEADER_STYLE+isset}" ]]; then
    TAG_GRAPH_HEADER_STYLE="\033[1m"
fi
_style="$(printf '%b' "$TAG_GRAPH_HEADER_STYLE")"
_reset="$(printf '%b' "$RESET")"

# render_tree_grouped LABEL1 LABEL2
# Reads "from TAB to TAB count" rows from stdin (any order),
# groups them by "from", sorts each group's neighbors by count
# descending, caps each group at TOP rows, and prints a
# nina-tree-flavored box listing:
#
#   c++
#   ├── programming              14
#   └── strings                   3
#
# This is deliberately one level deep (a tag and its direct
# neighbors) rather than a recursive tree like nina --tree:
# tag adjacency isn't a hierarchy, so a flat "here's what this
# tag connects to, ranked" view is the honest shape of the
# data, not an arbitrary depth limit.
render_tree_grouped() {
    local tmp
    tmp="$(make_temp_file)"
    cat > "$tmp"

    if [[ ! -s "$tmp" ]]; then
        info "No results."
        rm -f "$tmp"
        return
    fi

    local from
    while IFS= read -r from; do
        local -a rows
        if (( TOP > 0 )); then
            mapfile -t rows < <(awk -F'\t' -v f="$from" '$1 == f' "$tmp" | sort -t $'\t' -k3,3nr | head -n "$TOP")
        else
            mapfile -t rows < <(awk -F'\t' -v f="$from" '$1 == f' "$tmp" | sort -t $'\t' -k3,3nr)
        fi

        printf '%s%s%s\n' "$_style" "$from" "$_reset"

        local n=${#rows[@]} i=0 to cnt conn
        for row in "${rows[@]}"; do
            ((i++))
            IFS=$'\t' read -r _ to cnt <<< "$row"
            conn="├── "; (( i == n )) && conn="└── "
            printf '%s%-28s %s\n' "$conn" "$to" "$cnt"
        done
        echo
    done < <(cut -f1 "$tmp" | sort -u)

    rm -f "$tmp"
}

# =====================================================
# MODE: cooccur
#
# For every article, every unordered pair of distinct
# tags it carries counts as one co-occurrence. A tag
# applied to only one article of a pair never generates
# a row for that pair - this deliberately mirrors what
# the person described: "programming" not being on the
# operator-overloading article doesn't hide the fact
# that "c++" and "operator_overloading" (say) tend to
# travel together; it only means "programming" isn't
# part of that particular pair.
# =====================================================

if [[ "$MODE" == "cooccur" ]]; then

    pairs="$(awk -F'\t' -v tagfilter="$TAG_FILTER" '
    {
        if ($5 == "") next

        n = split($5, raw, ",")
        m = 0
        delete seen
        for (i = 1; i <= n; i++) {
            tag = raw[i]
            gsub(/^[ \t]+|[ \t]+$/, "", tag)
            if (tag == "" || (tag in seen)) continue
            seen[tag] = 1
            tags[++m] = tag
        }

        for (i = 1; i <= m; i++) {
            for (j = i + 1; j <= m; j++) {
                a = tags[i]; b = tags[j]
                if (a > b) { t = a; a = b; b = t }
                if (tagfilter != "" && a != tagfilter && b != tagfilter) continue
                key = a SUBSEP b
                count[key]++
            }
        }
    }
    END {
        for (key in count) {
            split(key, p, SUBSEP)
            printf "%s\t%s\t%d\n", p[1], p[2], count[key]
        }
    }' "$INDEX_FILE" | awk -F'\t' -v min="$MIN" '$3 >= min' | sort -t $'\t' -k3,3nr -k1,1 -k2,2)"

    case "$FORMAT" in
        table)
            table_begin " #" 6 "TAG A" 20 "TAG B" 20 "TOGETHER ON" 0
            table_header
            i=0
            while IFS=$'\t' read -r a b c; do
                [[ -z "$a" ]] && continue
                ((i++))
                table_row "$i" "$a" "$b" "$c articles"
            done < <(printf '%s\n' "$pairs" | limit_rows)
            (( i == 0 )) && info "No co-occurring tag pairs found."
            ;;
        tsv)
            printf '%s\n' "$pairs" | limit_rows
            ;;
        tree)
            # Mirror every pair into both directions so grouping by
            # "from" gives each tag its full neighbor list. When a
            # --tag filter is active, only that tag's own group is
            # worth showing as a root - without this, the mirrored
            # rows would also produce a one-line group for every
            # *other* tag in the pair list, each pointing back at
            # the filter tag alone, which is noise the person didn't
            # ask for.
            {
                printf '%s\n' "$pairs" | awk -F'\t' '{ print $1"\t"$2"\t"$3; print $2"\t"$1"\t"$3 }'
            } | awk -F'\t' -v f="$TAG_FILTER" 'f == "" || $1 == f' | render_tree_grouped
            ;;
        dot)
            echo "graph nina_cooccur {"
            echo "    rankdir=LR;"
            echo "    node [shape=box, style=rounded];"
            while IFS=$'\t' read -r a b c; do
                [[ -z "$a" ]] && continue
                printf '    "%s" -- "%s" [label="%s", penwidth=%s];\n' "$a" "$b" "$c" "$(scaled_weight "$c")"
            done < <(printf '%s\n' "$pairs" | limit_rows)
            echo "}"
            ;;
    esac

    exit 0
fi

# =====================================================
# MODE: links
#
# Rolls scan_links (article -> article, the same data
# nina --graph draws) up to the tag level: for every real
# link, every tag on the source article is paired with
# every tag on the target article, and each such (from
# tag, to tag) pair is counted once per link. A self-pair
# (same tag on both sides) is kept rather than skipped -
# "articles tagged c++ mostly link to other articles
# also tagged c++" is exactly the kind of cohesion signal
# this mode exists to surface.
#
# Tag lookup is done by canonical title, matching the
# same paste+canonical_title technique find_article_file
# uses, rather than re-deriving canonicalization rules by
# hand in awk - see canonical_title's own comment on why
# a second hand-written copy of those rules is a bug
# magnet.
# =====================================================

if [[ "$MODE" == "links" ]]; then

    declare -A TAGS_OF
    while IFS=$'\t' read -r canon tags; do
        [[ -z "$canon" ]] && continue
        TAGS_OF["$canon"]="$tags"
    done < <(paste <(cut -d $'\t' -f2 "$INDEX_FILE" | canonical_title) \
                    <(cut -d $'\t' -f5 "$INDEX_FILE"))

    tmp_edges="$(make_temp_file)"

    while IFS=$'\t' read -r _s_disp s_canon _t_disp t_canon; do
        [[ -z "$s_canon" ]] && continue
        src_tags="${TAGS_OF[$s_canon]:-}"
        tgt_tags="${TAGS_OF[$t_canon]:-}"
        [[ -z "$src_tags" || -z "$tgt_tags" ]] && continue

        IFS=',' read -ra src_arr <<< "$src_tags"
        IFS=',' read -ra tgt_arr <<< "$tgt_tags"

        for st in "${src_arr[@]}"; do
            [[ -z "$st" ]] && continue
            for tt in "${tgt_arr[@]}"; do
                [[ -z "$tt" ]] && continue
                if [[ -n "$TAG_FILTER" && "$st" != "$TAG_FILTER" && "$tt" != "$TAG_FILTER" ]]; then
                    continue
                fi
                printf '%s\t%s\n' "$st" "$tt" >> "$tmp_edges"
            done
        done
    done < <(scan_links)

    edges="$(sort "$tmp_edges" | uniq -c | awk -v min="$MIN" '{ if ($1 >= min) printf "%s\t%s\t%s\n", $2, $3, $1 }' | sort -t $'\t' -k3,3nr -k1,1 -k2,2)"
    rm -f "$tmp_edges"

    case "$FORMAT" in
        table)
            table_begin " #" 6 "FROM TAG" 20 "TO TAG" 20 "LINKS" 0
            table_header
            i=0
            while IFS=$'\t' read -r a b c; do
                [[ -z "$a" ]] && continue
                ((i++))
                table_row "$i" "$a" "$b" "$c"
            done < <(printf '%s\n' "$edges" | limit_rows)
            (( i == 0 )) && info "No tag-to-tag links found."
            ;;
        tsv)
            printf '%s\n' "$edges" | limit_rows
            ;;
        tree)
            # Same reasoning as the cooccur tree branch: with a
            # --tag filter active, only show that tag's own
            # outgoing-edge group, not a one-line group for every
            # other tag that merely links (or is linked) to it.
            printf '%s\n' "$edges" | awk -F'\t' -v f="$TAG_FILTER" 'f == "" || $1 == f' | render_tree_grouped
            ;;
        dot)
            echo "digraph nina_tag_links {"
            echo "    rankdir=LR;"
            echo "    node [shape=box, style=rounded];"
            while IFS=$'\t' read -r a b c; do
                [[ -z "$a" ]] && continue
                printf '    "%s" -> "%s" [label="%s", penwidth=%s];\n' "$a" "$b" "$c" "$(scaled_weight "$c")"
            done < <(printf '%s\n' "$edges" | limit_rows)
            echo "}"
            ;;
    esac

    exit 0
fi

# =====================================================
# MODE: islands
#
# Connected components of the article link graph. Links
# are treated as undirected purely for reachability - a
# one-way link still means the two articles are part of
# the same web when you're asking "can you get from one
# to the other by following links at all", which is the
# question an "island" answers. The real direction of
# each link is still what's drawn in --dot output; only
# the union-find step ignores it.
#
# --tag restricts the node set to articles carrying that
# tag before computing components, so "islands within
# c++" and "islands across the whole corpus" are the same
# code path with a different starting node set.
# =====================================================

if [[ "$MODE" == "islands" ]]; then

    declare -A DISP_OF TAGS_OF PARENT

    while IFS=$'\t' read -r canon disp tags; do
        [[ -z "$canon" ]] && continue
        DISP_OF["$canon"]="$disp"
        TAGS_OF["$canon"]="$tags"
    done < <(paste <(cut -d $'\t' -f2 "$INDEX_FILE" | canonical_title) \
                    <(cut -d $'\t' -f2 "$INDEX_FILE") \
                    <(cut -d $'\t' -f5 "$INDEX_FILE"))

    tag_has() {
        # No filter set - every article is in scope.
        [[ -z "$TAG_FILTER" ]] && return 0
        local spaced=" ${1//,/ } "
        [[ "$spaced" == *" $TAG_FILTER "* ]]
    }

    for canon in "${!DISP_OF[@]}"; do
        tag_has "${TAGS_OF[$canon]}" || continue
        PARENT["$canon"]="$canon"
    done

    if (( ${#PARENT[@]} == 0 )); then
        if [[ -n "$TAG_FILTER" ]]; then
            info "No articles tagged '$TAG_FILTER'."
        else
            info "No articles in the index."
        fi
        exit 0
    fi

    find_root() {
        local x="$1"
        while [[ "${PARENT[$x]}" != "$x" ]]; do
            PARENT["$x"]="${PARENT[${PARENT[$x]}]}"
            x="${PARENT[$x]}"
        done
        printf '%s' "$x"
    }

    union_nodes() {
        local ra rb
        ra="$(find_root "$1")"
        rb="$(find_root "$2")"
        [[ "$ra" == "$rb" ]] && return
        PARENT["$ra"]="$rb"
    }

    # Edges kept for later (dot output only): both endpoints
    # have to be in the filtered node set, or the edge leaves
    # the induced subgraph the person asked about.
    kept_src=()
    kept_tgt=()

    while IFS=$'\t' read -r _s_disp s_canon _t_disp t_canon; do
        [[ -n "${PARENT[$s_canon]:-}" && -n "${PARENT[$t_canon]:-}" ]] || continue
        union_nodes "$s_canon" "$t_canon"
        kept_src+=("$s_canon")
        kept_tgt+=("$t_canon")
    done < <(scan_links)

    # Group every in-scope node under its component root.
    declare -A GROUP_MEMBERS GROUP_SIZE
    for canon in "${!PARENT[@]}"; do
        root="$(find_root "$canon")"
        GROUP_MEMBERS["$root"]+="${DISP_OF[$canon]}"$'\n'
        GROUP_SIZE["$root"]=$(( ${GROUP_SIZE["$root"]:-0} + 1 ))
    done

    # Roots ordered largest-component-first, filtered by MIN,
    # capped by TOP - "TOP" here means "how many components",
    # not "how many rows", since a component's own member list
    # isn't truncated (a 40-article island half-shown would be
    # a strange kind of answer to "is this one island or two").
    roots_ranked="$(for root in "${!GROUP_SIZE[@]}"; do
        printf '%s\t%s\n' "${GROUP_SIZE[$root]}" "$root"
    done | awk -v min="$MIN" '$1 >= min' | sort -t $'\t' -k1,1nr | limit_rows)"

    if [[ -z "$roots_ranked" ]]; then
        info "No islands of $MIN or more connected articles found. Try --min 1 to include single-article islands."
        exit 0
    fi

    case "$FORMAT" in
        table|tree)
            comp_i=0
            while IFS=$'\t' read -r size root; do
                [[ -z "$root" ]] && continue
                ((comp_i++))
                if [[ "$FORMAT" == "tree" ]]; then
                    printf '%s%s (%s article%s)%s\n' "$_style" "Island $comp_i" "$size" "$([[ $size == 1 ]] || printf 's')" "$_reset"
                    mapfile -t members < <(printf '%s' "${GROUP_MEMBERS[$root]}" | sort -f)
                    n=${#members[@]}
                    for (( k = 0; k < n; k++ )); do
                        if (( k == n - 1 )); then
                            printf '└── %s\n' "${members[$k]}"
                        else
                            printf '├── %s\n' "${members[$k]}"
                        fi
                    done
                    echo
                else
                    printf 'Island %d (%d article%s):\n' "$comp_i" "$size" "$([[ $size == 1 ]] || printf 's')"
                    printf '%s' "${GROUP_MEMBERS[$root]}" | sort -f | sed 's/^/  - /'
                    echo
                fi
            done <<< "$roots_ranked"
            ;;
        tsv)
            comp_i=0
            while IFS=$'\t' read -r size root; do
                [[ -z "$root" ]] && continue
                ((comp_i++))
                printf '%s' "${GROUP_MEMBERS[$root]}" | sort -f | while IFS= read -r title; do
                    [[ -z "$title" ]] && continue
                    printf '%d\t%d\t%s\n' "$comp_i" "$size" "$title"
                done
            done <<< "$roots_ranked"
            ;;
        dot)
            echo "digraph nina_islands {"
            echo "    rankdir=LR;"
            echo "    node [shape=box, style=rounded];"
            comp_i=0
            while IFS=$'\t' read -r size root; do
                [[ -z "$root" ]] && continue
                ((comp_i++))
                printf '    subgraph cluster_%d {\n' "$comp_i"
                printf '        label="Island %d (%d article%s)";\n' "$comp_i" "$size" "$([[ $size == 1 ]] || printf 's')"
                mapfile -t members < <(printf '%s' "${GROUP_MEMBERS[$root]}" | sort -f)
                for m in "${members[@]}"; do
                    [[ -z "$m" ]] && continue
                    printf '        "%s";\n' "$m"
                done
                printf '    }\n'
            done <<< "$roots_ranked"

            for (( e = 0; e < ${#kept_src[@]}; e++ )); do
                printf '    "%s" -> "%s";\n' "${DISP_OF[${kept_src[$e]}]}" "${DISP_OF[${kept_tgt[$e]}]}"
            done
            echo "}"
            ;;
    esac

    exit 0
fi
