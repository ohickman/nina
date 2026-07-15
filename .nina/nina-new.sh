#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# Validate input
# -----------------------------------------

TITLE="$1"

[[ -z "$TITLE" ]] && die 'Usage: nina -n "Article Title"'

# Normalize (preserve case for display)
TITLE="$(normalize_display_title "$TITLE")"
[[ -z "$TITLE" ]] && die "Invalid title."

# -----------------------------------------
# Prevent canonical title collision
# -----------------------------------------

canonical_input="$(canonical_title "$TITLE")"

if [[ -f "$INDEX_FILE" ]]; then
    existing="$(find_article_file "$canonical_input")"

    if [[ -n "$existing" ]]; then

        echo
        error "An article with this title already exists:"
        echo "  $existing"
        echo
        echo "Titles must be unique (case and whitespace ignored)."

        # Suggest similar titles
        similar=$(suggest_titles "$TITLE")

        if [[ -n "$similar" ]]; then
            echo
            echo "Similar titles:"
            echo "$similar" | sed 's/^/  /'
        fi

        echo
        info "Try: nina --search \"$TITLE\""

        exit 1
    fi
fi

# -----------------------------------------
# Generate slug (filesystem-safe)
# -----------------------------------------

slug="$(generate_slug "$TITLE")"
[[ -z "$slug" ]] && die "Invalid title."

FILE="$NINA_DIR/${slug}.md"

# -----------------------------------------
# Prevent filename collision
# -----------------------------------------

if [[ -f "$FILE" ]]; then
    echo
    error "Filename collision detected."
    echo
    echo "The title \"$TITLE\" would create the file:"
    echo "  $FILE"
    echo
    echo "But that file already exists."
    echo
    echo "Titles that differ only by punctuation or spacing"
    echo "may produce identical filenames."
    echo
    echo "Choose a different title."
    exit 1
fi

# -----------------------------------------
# Create article file
# -----------------------------------------

mkdir -p "$NINA_DIR"

printf '# %s\n' "$TITLE" > "$FILE"
printf -- '- Author: %s\n' "$(whoami)" >> "$FILE"
printf -- '- Tags: \n\n' >> "$FILE"

# -----------------------------------------
# Open in terminal editor (blocking)
# -----------------------------------------

editor="${EDITOR:-vi}"
"$editor" "$FILE"

# -----------------------------------------
# Optional reindex
# -----------------------------------------

if [[ "$AUTO_REINDEX" == "true" ]]; then
    "$SCRIPT_DIR/nina" --index
fi

# -----------------------------------------
# View article
# -----------------------------------------

"$SCRIPT_DIR/nina" "$TITLE"