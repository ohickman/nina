#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# Split a raw "Title" or "Title#Anchor" input
# into a resolved real title and an optional
# anchor.
#
# Thin wrapper around the shared anchor-split
# engine in nina-lib.sh (build_title_maps /
# resolve_split_target) - see that file for why
# '#' can't be trusted as a delimiter on sight,
# and for the backward-walk this performs. The
# same engine also backs nina-dangling,
# nina-backlinks, nina-orphan, and nina-graph, so
# a real title containing '#' (e.g. "C# Tricks")
# resolves identically - as itself - everywhere.
#
# On success, sets ANCHOR_TITLE (the matched
# prefix, in the user's original casing) and
# ANCHOR_TEXT (empty if the input needed no
# split) and returns 0. On failure - no prefix of
# the input resolves at all - leaves both empty
# and returns 1; the caller falls back to today's
# unchanged "not found" handling, using the
# original, full input as the attempted title.
# -----------------------------------------

split_title_anchor() {
    local input="$1" input_canon

    ANCHOR_TITLE=""
    ANCHOR_TEXT=""

    declare -A _view_title_map
    declare -A _view_alias_map
    build_title_maps _view_title_map _view_alias_map

    input_canon="$(canonical_title "$input")"
    resolve_split_target "$input" "$input_canon" _view_title_map _view_alias_map || return 1

    ANCHOR_TITLE="$NINA_SPLIT_PREFIX"
    ANCHOR_TEXT="$NINA_SPLIT_ANCHOR"
    return 0
}

# -----------------------------------------
# Look up ANCHOR_TEXT against the article's real
# headings and, on a match, print the heading's
# own verbatim text (not the caller's typed
# anchor) so a downstream less search is matched
# against text guaranteed to exist in the
# rendered output.
#
# Matching goes through canonical_title so minor
# case/whitespace differences are forgiven, the
# same tolerance titles already get elsewhere.
#
# Deliberately reads the raw file with no
# fenced-code protection, matching
# nina-render.awk's own documented behavior:
# a multi-line code fence is only protected on
# its first and last line, so an interior line
# that looks like a heading really does render as
# one. Being "smarter" than the renderer here
# would just create a second place that disagrees
# with what less actually displays.
#
# Multiple identical headings, in this article or
# otherwise: takes the first, same policy already
# agreed for less's own search behavior.
# -----------------------------------------

find_header_match() {
    local anchor_canonical="$1" file="$2"
    local header_text header_canonical

    while IFS= read -r header_text; do
        header_canonical="$(canonical_title "$header_text")"
        if [[ "$header_canonical" == "$anchor_canonical" ]]; then
            printf '%s\n' "$header_text"
            return 0
        fi
    done < <(grep -E '^#{1,6} ' "$file" | sed -E 's/^#{1,6} //')

    return 1
}

# -----------------------------------------
# Escape text for use as a literal less search
# pattern. less's search is a regex (BRE or ERE
# depending on how it was built), so this escapes
# the superset of metacharacters either flavor
# treats specially, rather than assuming one.
# -----------------------------------------

escape_less_pattern() {
    printf '%s' "$1" | sed 's/[][\.*^$(){}+?|]/\\&/g'
}

# -----------------------------------------
# Validate input
# (a bit redundant, but perhaps clearer)
# -----------------------------------------

TITLE="$1"
[[ -z "$TITLE" ]] && die 'Usage: nina "Article Title[#Anchor]"'

TITLE="$(normalize_display_title "$TITLE")"
[[ -z "$TITLE" ]] && die "Invalid title."

# -----------------------------------------
# Split off an optional anchor. ANCHOR_TEXT is
# empty whenever the input needed no split - a
# plain title, exactly today's behavior. On
# failure TITLE is deliberately left as the full
# original input, so the existing "not found"
# flow below behaves exactly as it does today.
# -----------------------------------------

ANCHOR_TEXT=""
if split_title_anchor "$TITLE"; then
    TITLE="$ANCHOR_TITLE"
fi

CANONICAL_INPUT="$(canonical_title "$TITLE")"

# -----------------------------------------
# Resolve file from index (alias-aware).
#
# A real title always wins; an alias is consulted
# only on a main-index miss. See resolve_article_file
# in nina-lib.sh. The link list below is invoked with
# the user's input as-is - nina-link-list resolves an
# alias the same way, so it need not be rewritten here.
# -----------------------------------------

FILE="$(resolve_article_file "$CANONICAL_INPUT")"

# -----------------------------------------
# Handle missing article
# -----------------------------------------

if [[ -z "$FILE" ]]; then

    similar="$(suggest_titles "$TITLE")"

    if [[ -n "$similar" ]]; then
        echo
        echo "Did you mean:"
        echo "$similar" | sed 's/^/  /'
    fi

    if [[ "$ENABLE_CREATE_PROMPT" == true ]]; then
        read -r -p "Article not found. Create it? (y/n): " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            "$SCRIPT_DIR/nina" -n "$TITLE"
        fi
    else
        echo "Article not found: $TITLE"
    fi
    exit 1
fi

# -----------------------------------------
# Resolve the anchor, if any, into a literal
# search pattern for less. Two forms:
#
#   Title#Heading text    - look up a real
#     heading and jump to its own exact wording.
#   Title#:~:text=phrase   - skip the heading
#     lookup and search for the phrase itself,
#     mirroring a browser's URL text fragment
#     syntax rather than inventing new syntax.
#
# Either way this ends up as a plain-text search
# against the rendered stream, never a jump to a
# precomputed line number - see the comment above
# find_header_match for why line numbers can't be
# trusted here.
#
# A bare anchor that matches no heading is NOT
# silently treated as a body-text search - that
# would make a typo fail quietly, landing wherever
# the words happen to appear rather than erroring.
# It opens the article anyway (unjumped) with a
# warning, so a mistyped heading is loud, not
# silently wrong.
# -----------------------------------------

SEARCH_PATTERN=""

if [[ -n "$ANCHOR_TEXT" ]]; then

    if [[ "$ANCHOR_TEXT" == ":~:text="* ]]; then
        raw_text="${ANCHOR_TEXT#:~:text=}"
    else
        raw_text="$(find_header_match "$(canonical_title "$ANCHOR_TEXT")" "$FILE")"
        if [[ -z "$raw_text" ]]; then
            echo
            echo "No heading found matching \"$ANCHOR_TEXT\" in \"$TITLE\"."
            headers="$(grep -E '^#{1,6} ' "$FILE" | sed -E 's/^#{1,6} //')"
            if [[ -n "$headers" ]]; then
                echo "Headings in this article:"
                echo "$headers" | sed 's/^/  /'
            fi
            echo "Opening without jumping. (Use \"#:~:text=...\" to search body text instead of a heading.)"
        fi
    fi

    [[ -n "$raw_text" ]] && SEARCH_PATTERN="$(escape_less_pattern "$raw_text")"
fi

# -----------------------------------------
# Render via less using LESSOPEN. A resolved
# search pattern is handed to less as a startup
# command (+/pattern) so the view opens already
# jumped to, and highlighting, the match - the
# same mechanism '/' triggers interactively,
# just supplied up front.
# -----------------------------------------

if [[ -n "$SEARCH_PATTERN" ]]; then
    LESSOPEN="|$SCRIPT_DIR/nina-render.sh %s" less -R "+/$SEARCH_PATTERN" "$FILE"
else
    LESSOPEN="|$SCRIPT_DIR/nina-render.sh %s" less -R "$FILE"
fi

echo

# -----------------------------------------
# Optional link list
# -----------------------------------------

if [[ "$SHOW_LINK_LIST" == true ]]; then
    "$SCRIPT_DIR/nina" --links "$TITLE"
fi
