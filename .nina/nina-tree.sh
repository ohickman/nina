#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# TREE_CENTER_STYLE ("\033[1m", bold, by default) comes from
# ~/.nina/config, alongside the other STYLE variables the
# renderer uses - see the "Render" section below for where it's
# applied. Defaulted here so an existing config written before
# this variable existed still works - but only when the
# variable is truly absent. "${VAR:=default}" would also
# overwrite a config that deliberately sets
# TREE_CENTER_STYLE="" for no styling at all, since := treats
# "empty" and "unset" as the same case; "${VAR+isset}" is the
# form that actually distinguishes them.
# -----------------------------------------

if [[ -z "${TREE_CENTER_STYLE+isset}" ]]; then
    TREE_CENTER_STYLE="\033[1m"
fi

# -----------------------------------------
# Parse arguments
#
# Everything that isn't --depth/-d (and its value) is the
# title, same split nina-search.sh uses for --count/--explain -
# except --depth/-d also consumes a value, in either
# "--depth 3" or "--depth=3" form (and "-d 3" / "-d=3").
# -d/--date is a different flag at the top-level dispatcher
# (see the `nina` script), but that's a different command's
# argument space - by the time nina-tree.sh runs, "--tree" has
# already been matched, so -d here can only mean depth.
#
# TREE_DEPTH is the default when neither form is given.
# render_ancestors/render_descendants are already written as
# depth-parameterized recursion, so this argument just decides
# what value they're called with - no other change needed here
# to support it.
# -----------------------------------------

TREE_DEPTH=2
TITLE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --depth=*|-d=*)
            TREE_DEPTH="${1#*=}"
            shift
            ;;
        --depth|-d)
            TREE_DEPTH="$2"
            shift 2
            ;;
        *)
            TITLE="$1"
            shift
            ;;
    esac
done

[[ -z "$TITLE" ]] && die 'Usage: nina --tree "Article Title" [--depth N | -d N]'

MAX_TREE_DEPTH=10

if ! [[ "$TREE_DEPTH" =~ ^[0-9]+$ ]] || (( TREE_DEPTH < 1 )); then
    die "Invalid depth: $TREE_DEPTH (must be a whole number, 1 or greater)"
fi

if (( TREE_DEPTH > MAX_TREE_DEPTH )); then
    die "Depth $TREE_DEPTH too large (max $MAX_TREE_DEPTH) - large depths can blow up on densely linked or cyclic notes."
fi

require_index

# -----------------------------------------
# Resolve title to file (alias-aware) exactly
# as nina-link-list.sh and nina-backlinks.sh do.
# -----------------------------------------

canonical_input="$(canonical_title "$TITLE")"
FILE="$(resolve_article_file "$canonical_input")"

[[ -z "$FILE" ]] && die "Article not found: $TITLE"

# -----------------------------------------
# The center of the diagram is the article's
# real stored title (from its own header), not
# necessarily the casing/spacing the user typed
# or the alias they may have used to get here.
# Same technique nina-render.sh uses for
# CURRENT_TITLE.
# -----------------------------------------

CENTER_DISPLAY="$(normalize_display_title "$(header_field "$(read_header "$FILE")" Title)")"
CENTER_CANON="$(canonical_title "$CENTER_DISPLAY")"

# -----------------------------------------
# Load the whole link graph in one scan_links
# pass (see "scan_links Is a Single-Pass AWK
# Function" in the AI programming guide - a
# second call anywhere below would double the
# scan for no reason) into three lookup
# structures:
#
#   OUT_D[canon]   "display\tcanon\n" per article
#                  the key links to
#   IN_D[canon]    "display\tcanon\n" per article
#                  linking to the key
#   EDGE_SET[a\x1fb]  set to 1 when a direct edge
#                  a -> b exists, for O(1) checks
#
# \x1f (unit separator) joins the two halves of
# an EDGE_SET key - a byte that can't occur in a
# normalized title, so it can't collide the way a
# printable separator like "|" or "->" theoretically
# could if a title ever contained it literally.
# -----------------------------------------

declare -A OUT_D IN_D EDGE_SET

while IFS=$'\t' read -r s_disp s_canon t_disp t_canon; do
    [[ -z "$s_canon" ]] && continue
    OUT_D["$s_canon"]+="$t_disp"$'\t'"$t_canon"$'\n'
    IN_D["$t_canon"]+="$s_disp"$'\t'"$s_canon"$'\n'
    EDGE_SET["$s_canon"$'\x1f'"$t_canon"]=1
done < <(scan_links)

out_children() { printf '%s' "${OUT_D[$1]:-}"; }
in_parents()   { printf '%s' "${IN_D[$1]:-}"; }
has_edge()     { [[ -n "${EDGE_SET[$1$'\x1f'$2]:-}" ]]; }

# -----------------------------------------
# Numbered rows, in the exact order printed.
# ROW_TITLES is the array open_tree_menu()
# indexes into when the user enters a number;
# COUNTER is the bracket number of the row
# currently being printed. The center article
# is never added here - it has no bracket
# number, only the dot (see open_tree_menu's
# "0" handling in nina-lib.sh).
# -----------------------------------------

COUNTER=0
ROW_TITLES=()

print_row() {
    local prefix="$1" title="$2" marker="$3"
    COUNTER=$((COUNTER + 1))
    ROW_TITLES+=("$title")
    printf "[%4d] %s%s%s\n" "$COUNTER" "$prefix" "$title" "$marker"
}

# -----------------------------------------
# Ancestors (backlink side, drawn above center)
#
# Mirrors a standard downward tree: a node's own
# ancestors are printed ABOVE it rather than below,
# so the recursive call happens BEFORE printing the
# node's own row. The first sibling in each group
# opens the branch with "┌── " (nothing above it to
# connect to); every other sibling - including the
# last - uses "├── ", never "└── ", because the
# trunk never terminates on the ancestor side: it
# flows continuously down into whatever printed
# after it (a parent's own row, and ultimately the
# center row itself).
#
# CANON's own row is the CALLER's responsibility;
# this function only prints CANON's backlinks (and,
# recursively, theirs), which is why the top-level
# call is for CENTER_CANON and the center row is
# printed separately, after this returns.
#
# The marker fires when a node also has a direct
# edge back to its own immediate tree-parent (CANON
# here) - i.e. the two of them link to each other,
# not just one way. It's deliberately checked against
# the immediate parent rather than against the center
# itself, and skipped entirely when that parent IS the
# center (CANON == CENTER_CANON, true only for depth-1
# ancestors):
#
# a direct edge from the center to some node two hops
# away isn't a footnote on that node - it makes the
# node a first-degree connection of the center in its
# own right, exactly as real as the one being drawn
# through the intermediate node. A version of this
# marker that checked against the center directly was
# tried and discarded for that reason: it didn't just
# annotate the existing row, a node with such an edge
# is already, independently, returned by
# in_parents(CENTER_CANON) / out_children(CENTER_CANON)
# and so shows up as its own separate depth-1 row
# regardless of any marker logic - and that row brings
# its own depth-2 expansion with it, which in a corpus
# with a few such edges compounds into a diagram far
# larger than the two-hop neighborhood this view is
# supposed to be. None of that is wrong - it's a
# faithful reading of the corpus - it's just a
# different, noisier feature than "flag a mutual
# pair", so it isn't what the marker does here.
# Checking against the immediate parent instead never
# influences which nodes get discovered (that's fixed
# by in_parents/out_children(CENTER_CANON) alone) - it
# only annotates a node already on the page, so it can
# never trigger new rows. A genuine direct edge between
# the center and a farther node is still fully visible
# on its own terms: it simply appears as its own
# depth-1 row (via the ordinary discovery above), with
# no special-casing needed to show it.
# -----------------------------------------

render_ancestors() {
    local canon="$1" prefix="$2" remaining="$3"
    (( remaining <= 0 )) && return

    local -a nodes
    mapfile -t nodes < <(in_parents "$canon" | awk -F'\t' -v c="$CENTER_CANON" '$2 != c')

    local n=${#nodes[@]}
    local i disp c2 conn child_prefix marker

    for (( i = 0; i < n; i++ )); do
        IFS=$'\t' read -r disp c2 <<< "${nodes[$i]}"

        child_prefix="$prefix"
        if (( i == 0 )); then child_prefix+="    "; else child_prefix+="│   "; fi
        render_ancestors "$c2" "$child_prefix" "$((remaining - 1))"

        conn="$prefix"
        if (( i == 0 )); then conn+="┌── "; else conn+="├── "; fi

        marker=""
        if [[ "$canon" != "$CENTER_CANON" ]] && has_edge "$canon" "$c2"; then
            marker="  ▼"
        fi

        print_row "$conn" "$disp" "$marker"
    done
}

# -----------------------------------------
# Descendants (forward-link side, drawn below
# center) - an ordinary downward tree: a node's
# own row prints first, then its children, so the
# recursive call happens AFTER printing the node.
# Last sibling in each group closes the branch with
# "└── "; earlier siblings use "├── " and pass "│   "
# down to their own children so the trunk shows
# through; the last sibling passes plain spaces,
# since nothing follows it at that level.
#
# The marker is the mirror of the ancestor-side one
# above: it fires when a node also links directly back
# to its own immediate tree-parent (CANON here), and is
# skipped when that parent IS the center (depth-1
# descendants), for the same reason - see the comment
# above render_ancestors for the full explanation.
# -----------------------------------------

render_descendants() {
    local canon="$1" prefix="$2" remaining="$3"
    (( remaining <= 0 )) && return

    local -a nodes
    mapfile -t nodes < <(out_children "$canon" | awk -F'\t' -v c="$CENTER_CANON" '$2 != c')

    local n=${#nodes[@]}
    local i disp c2 conn child_prefix marker is_last

    for (( i = 0; i < n; i++ )); do
        IFS=$'\t' read -r disp c2 <<< "${nodes[$i]}"
        is_last=0; (( i == n - 1 )) && is_last=1

        conn="$prefix"
        if (( is_last )); then conn+="└── "; else conn+="├── "; fi

        marker=""
        if [[ "$canon" != "$CENTER_CANON" ]] && has_edge "$c2" "$canon"; then
            marker="  ▲"
        fi

        print_row "$conn" "$disp" "$marker"

        child_prefix="$prefix"
        if (( is_last )); then child_prefix+="    "; else child_prefix+="│   "; fi
        render_descendants "$c2" "$child_prefix" "$((remaining - 1))"
    done
}

# -----------------------------------------
# Same open-by-number contract as
# open_article_menu in nina-lib.sh, extended with
# a "0" case for the CENTER article. Kept here
# rather than in the shared library: nothing else
# in nina has a numbered list with an unnumbered-
# turned-"0" entry to open, so there's no second
# caller to justify sharing it - if that changes,
# it can move to nina-lib.sh then.
#
# center: the article to open on "0" - shown with
#         its own "[   0]" row in the tree itself,
#         so the prompt below doesn't need to
#         explain what "0" means
# titles:  same as open_article_menu - the
#          numbered list, 1-indexed
# -----------------------------------------

open_tree_menu() {
    local center="$1"; shift
    local titles=("$@")

    [[ -t 0 && -t 1 ]] || return 0

    echo
    read -r -p "Open article number (Enter to exit): " choice

    [[ -z "$choice" ]] && return 0

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if (( choice == 0 )); then
            exec "$NINA_LIB_DIR/nina" "$center"
        elif (( choice <= ${#titles[@]} )); then
            exec "$NINA_LIB_DIR/nina" "${titles[$((choice-1))]}"
        else
            warn "Invalid selection."
        fi
    else
        warn "Invalid selection."
    fi
}

# -----------------------------------------
# Render
#
# The center row is printed with the same "[%4d]"
# bracket used for every other row - just with 0,
# rather than a symbol that needs its own
# explanation - since 0 already has to mean "the
# current article" for open_tree_menu's sake (see
# above); showing that same number here means
# there's nothing extra to tell the user about it.
#
# It's set off from the numbered rows by a blank
# line on each side, each showing the bare trunk
# ("│") continuing through the gap - but only on
# the side that actually has a trunk to continue:
# an empty ancestor or descendant list prints no
# rows there at all, so there's nothing for a stray
# "│" to connect to.
# -----------------------------------------

echo
echo "---- Article Tree ----"
echo

render_ancestors "$CENTER_CANON" "" "$TREE_DEPTH"
ancestor_rows=$COUNTER
(( ancestor_rows > 0 )) && printf "%7s│\n" ""

center_title="$CENTER_DISPLAY"
if [[ -n "$TREE_CENTER_STYLE" ]]; then
    # TREE_CENTER_STYLE/RESET, like every style variable in
    # ~/.nina/config, are stored as literal backslash-escape
    # text (e.g. "\033[1m") - the same form nina-render.sh
    # passes to awk, whose -v assignment interprets C-style
    # escapes. Plain bash string interpolation does not, so
    # printf %b (which does interpret them, unlike %s) is
    # needed here to turn that text into real ESC bytes.
    style="$(printf '%b' "$TREE_CENTER_STYLE")"
    reset="$(printf '%b' "$RESET")"
    center_title="${style}${CENTER_DISPLAY}${reset}"
fi
printf "[%4d] %s%s\n" 0 "╞══ " "$center_title"

# has_descendants must be checked BEFORE render_descendants runs,
# not after - checking COUNTER's change afterward (the way the
# ancestor side does it, looking back once rendering is done) would
# put this print call after all the descendant rows were already
# printed, landing the blank/trunk line at the very end of the
# whole diagram instead of right after the center row. Checking
# center's own direct children directly, ahead of time, is what
# lets this line print in between, where it belongs.
has_descendants=false
[[ -n "$(out_children "$CENTER_CANON" | awk -F'\t' -v c="$CENTER_CANON" '$2 != c')" ]] && has_descendants=true
$has_descendants && printf "%7s│\n" ""

render_descendants "$CENTER_CANON" "" "$TREE_DEPTH"

if (( ${#ROW_TITLES[@]} == 0 )); then
    echo
    info "No linked articles in either direction."
fi

open_tree_menu "$CENTER_DISPLAY" "${ROW_TITLES[@]}"
