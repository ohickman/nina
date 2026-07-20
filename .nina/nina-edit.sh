#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

TITLE="$1"

[[ -z "$TITLE" ]] && die 'Usage: nina --edit "Article Title"'

# -----------------------------------------
# Resolve title using canonical rules
# -----------------------------------------

canonical_input=$(canonical_title "$TITLE")

FILE=$(resolve_article_file "$canonical_input")

if [[ -z "$FILE" ]]; then
    error "Article not found: $TITLE"

    similar="$(suggest_titles "$TITLE")"

    if [[ -n "$similar" ]]; then
        echo
        echo "Did you mean:"
        echo "$similar" | sed 's/^/  /'
    fi

    exit 1
fi

# -----------------------------------------
# Open in terminal editor (blocking)
# -----------------------------------------

editor="${EDITOR:-vi}"
"$editor" "$FILE"

# -----------------------------------------
# Reindex, then display the edited article
# -----------------------------------------

request_index

"$SCRIPT_DIR/nina" "$TITLE"
