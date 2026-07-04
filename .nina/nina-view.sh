#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# Validate input
# (a bit redundant, but perhaps clearer)
# -----------------------------------------

TITLE="$1"
[[ -z "$TITLE" ]] && die 'Usage: nina "Article Title"'

TITLE="$(normalize_display_title "$TITLE")"
[[ -z "$TITLE" ]] && die "Invalid title."

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
# Render via less using LESSOPEN
# -----------------------------------------

LESSOPEN="|$SCRIPT_DIR/nina-render.sh %s" less -R "$FILE"

echo

# -----------------------------------------
# Optional link list
# -----------------------------------------

if [[ "$SHOW_LINK_LIST" == true ]]; then
    "$SCRIPT_DIR/nina" --links "$TITLE"
fi