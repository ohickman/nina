# =====================================================
# nina-tree.awk
#
# Builds and renders the two-sided ancestor/descendant tree
# used by `nina --tree`: the current article in the middle,
# articles that link to it above, articles it links to below.
#
# Input (stdin): scan_links() output, unmodified -
#   source_display TAB source_canon TAB target_display TAB target_canon
#
# Required -v variables:
#   center_display - display title of the current article
#   center_canon   - canonical title of the current article
#   depth          - how many link-hops to show on each side (>=1)
#
# Output (stdout): one row per line to draw, tab-separated:
#   NUMBER TAB PRETTY_LINE TAB RAW_TITLE
#
# NUMBER is "0" for the center row (RAW_TITLE is center_display,
# PRETTY_LINE has no tree connector - just the bullet gutter).
# Every other row is numbered sequentially from 1, top to bottom,
# skipping the center. The driving shell script prints PRETTY_LINE
# verbatim and uses NUMBER/RAW_TITLE to build its navigation map -
# it never has to re-parse the tree-drawing characters back into a
# title, which keeps "what to display" and "what to navigate to"
# from ever drifting apart.
#
# -----------------------------------------------------
# THE MIRRORED-TREE RULE (read this before touching either
# build_* function)
# -----------------------------------------------------
# The descending half (below the center) is an ordinary top-down
# tree: for each node, print it, then recurse into its own
# children before moving to the next sibling (pre-order). The
# last sibling gets the closing corner "└──"; every other sibling
# gets "├──"; a non-last sibling's own children get a "│" continu-
# ation bar in their indent prefix (there's more content below at
# this level), a last sibling's children get plain spaces instead.
#
# The ascending half (above the center) is the SAME tree turned
# upside down - built from the reverse-link graph (a node's
# "children" here are the articles that link to it) - but it is
# NOT rendered by just running the descending algorithm on that
# reversed graph. Read top-to-bottom, the ascending half has to
# get farther from the center as you go UP, which means each
# node's own further ancestors must appear ABOVE it on screen -
# i.e. printed BEFORE it, not after. So build_ascending recurses
# into a node's parents FIRST and only emits the node's own line
# AFTER that recursive call returns (post-order, not pre-order).
# Sibling order is left exactly as scan_links naturally produced
# it - it is NOT reversed anywhere.
#
# The corner/bar logic mirrors too, but around "first" instead of
# "last": since going further from the center now means going UP
# instead of down, it's the FIRST sibling (the one with nothing
# above it) that gets the open corner - "┌──" instead of "└──" -
# and it's a NON-first sibling (something is above it) whose own
# ancestors get the "│" continuation bar; the first sibling's
# ancestors get plain spaces, since there's nothing further out
# for the bar to visually connect to.
#
# Both of these were verified line-by-line against a worked
# example before being written up here - if you change either
# function, re-derive against a concrete multi-branch example
# rather than trusting it "looks symmetric".
# -----------------------------------------------------
#
# A note on characters: the tree-drawing glyphs and arrow markers
# below are multi-byte UTF-8, written literally into this file
# (safe here - this is a real file loaded with -f, not a string
# embedded in a bash single-quoted awk program; see nina-entities.awk
# for the same approach already working in this codebase). What is
# NOT safe under mawk is passing any of these strings through a
# sprintf field-width specifier like "%6s": mawk pads by BYTE count,
# not by display column, so a 3-byte character like "●" would only
# get 3 padding bytes instead of the 5 spaces a single display
# column needs. Every fixed-width gutter below is therefore built
# from literal, hand-counted spaces instead of a width specifier.
# =====================================================

BEGIN {
    FS = "\t"

    if (depth < 1) depth = 1

    asc_n = 0
    desc_n = 0
}

# -----------------------------------------------
# Load one edge per input line. Two adjacency lists are built,
# each preserving first-seen order:
#   fwd_*  - forward: source canon -> its target(s)
#   rev_*  - reverse: target canon -> its source(s)
# edge_exists[a, b] records that a direct a->b link exists at
# all, regardless of depth; it's how the arrow markers check for
# a reciprocal link with the center without re-scanning anything.
#
# Deduplication here is keyed on the canon pair only (not the full
# scan_links row), so two literal links to the same article that
# happen to use different display-text spellings collapse into a
# single tree node - consistent with canonical_title() being the
# one standard for "is this the same article" everywhere else in
# nina, not a new exception.
# -----------------------------------------------
{
    src_d = $1; src_c = $2; tgt_d = $3; tgt_c = $4

    edge_exists[src_c, tgt_c] = 1

    # A reciprocal link between the center and some depth-1 node
    # is exactly the relationship the arrow markers exist to show
    # - but that same reciprocal edge, followed one hop further,
    # would otherwise rediscover the center itself as a "child" of
    # that node (its own grandparent/grandchild), which is never
    # useful to draw as a plain numbered entry: the center already
    # has its own fixed spot (the ● line), and re-showing it deeper
    # in the tree would just be confusing, not additional
    # information - the reciprocal fact is already carried by the
    # arrow on the depth-1 node's own line.
    #
    # So: an edge whose target is the center is never recorded as
    # a forward "child" entry for its source (unless the source
    # *is* the center - that's the ordinary, wanted depth-1 lookup,
    # fwd_count[center_canon]). Symmetrically, an edge whose source
    # is the center is never recorded as a reverse "parent" entry
    # for its target (unless the target *is* the center -
    # rev_count[center_canon], also wanted). Either lookup keyed
    # directly on center_canon is untouched; only "center reappears
    # as someone else's neighbor" entries are suppressed, and they
    # are suppressed at load time so sibling counts (is_last/
    # is_first) never see the filtered-out entry in the first place.
    skip_fwd = (tgt_c == center_canon && src_c != center_canon)
    skip_rev = (src_c == center_canon && tgt_c != center_canon)

    if (!skip_fwd && !((src_c, tgt_c) in fwd_seen)) {
        fwd_seen[src_c, tgt_c] = 1
        n = ++fwd_count[src_c]
        fwd_target_canon[src_c, n]   = tgt_c
        fwd_target_display[src_c, n] = tgt_d
    }

    if (!skip_rev && !((tgt_c, src_c) in rev_seen)) {
        rev_seen[tgt_c, src_c] = 1
        m = ++rev_count[tgt_c]
        rev_source_canon[tgt_c, m]   = src_c
        rev_source_display[tgt_c, m] = src_d
    }
}

# -----------------------------------------------
# Descending half: ordinary pre-order tree over the forward
# adjacency list. See the file header for why this is pre-order
# (emit self, then recurse) while the ascending half is not.
# -----------------------------------------------
function build_descending(canon, prefix, remaining,    n, i, c_canon, c_display, is_last, connector, child_prefix, arrow) {
    n = fwd_count[canon]

    for (i = 1; i <= n; i++) {
        c_canon   = fwd_target_canon[canon, i]
        c_display = fwd_target_display[canon, i]
        is_last   = (i == n)

        if (is_last) {
            connector    = "└── "
            child_prefix = prefix "    "
        } else {
            connector    = "├── "
            child_prefix = prefix "│   "
        }

        # Does this specific node link directly back up to the
        # center? (Not implied by its own position in the tree -
        # only the center->...->node chain is.) Point the arrow
        # up, toward where the center sits on screen.
        arrow = ((c_canon, center_canon) in edge_exists) ? " \342\226\262" : ""

        desc_n++
        desc_line[desc_n]  = prefix connector c_display arrow
        desc_title[desc_n] = c_display

        if (remaining > 1)
            build_descending(c_canon, child_prefix, remaining - 1)
    }
}

# -----------------------------------------------
# Ascending half: post-order tree over the reverse adjacency
# list - recurse into a node's own further ancestors FIRST (so
# they land above it on screen), then emit the node's own line.
# See the file header for the corner/bar mirroring rule.
# -----------------------------------------------
function build_ascending(canon, prefix, remaining,    n, i, c_canon, c_display, is_first, connector, child_prefix, arrow) {
    n = rev_count[canon]

    for (i = 1; i <= n; i++) {
        c_canon   = rev_source_canon[canon, i]
        c_display = rev_source_display[canon, i]
        is_first  = (i == 1)

        if (is_first) {
            connector    = "┌── "
            child_prefix = prefix "    "
        } else {
            connector    = "├── "
            child_prefix = prefix "│   "
        }

        if (remaining > 1)
            build_ascending(c_canon, child_prefix, remaining - 1)

        # Does the center link directly down to this specific
        # node? Point the arrow down, toward the center below it.
        arrow = ((center_canon, c_canon) in edge_exists) ? " \342\226\274" : ""

        asc_n++
        asc_line[asc_n]  = prefix connector c_display arrow
        asc_title[asc_n] = c_display
    }
}

END {
    build_ascending(center_canon, "", depth)
    build_descending(center_canon, "", depth)

    num = 0

    for (i = 1; i <= asc_n; i++) {
        num++
        printf "%d\t[%s] %s\t%s\n", num, pad_num(num), asc_line[i], asc_title[i]
    }

    # Center row: same 7-column gutter width as the numbered rows
    # ("[" + 4-wide number + "]" + one space = 7), built from
    # literal spaces rather than a sprintf width - see file header.
    printf "0\t     \342\227\217 %s\t%s\n", center_display, center_display

    for (i = 1; i <= desc_n; i++) {
        num++
        printf "%d\t[%s] %s\t%s\n", num, pad_num(num), desc_line[i], desc_title[i]
    }
}

# Right-justify a row number in a 4-character field, ASCII-only
# (plain digits), so sprintf's byte-based width is safe to use
# here even though it isn't for the UTF-8 glyphs elsewhere.
function pad_num(n) {
    return sprintf("%4d", n)
}
