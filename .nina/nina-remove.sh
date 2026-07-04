#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

require_interactive

TITLE="$1"

# -----------------------------------------
# Interactive selection if no title given
# -----------------------------------------

if [[ -z "$TITLE" ]]; then

    printf "\n"

    table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
    table_header

    titles=()
    i=0

    while IFS=$'\t' read -r t modified tags; do

        ((i++))
        titles+=("$t")

        table_row "$i" "$t" "$modified" "$tags"

    done < <(index_display_rows)

    if (( ${#titles[@]} == 0 )); then
        info "No articles found."
        exit 0
    fi

    echo
    read -r -p "Remove article number (Enter to cancel): " choice

    [[ -z "$choice" ]] && exit 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#titles[@]} )); then
        die "Invalid selection."
    fi

    TITLE="${titles[$((choice-1))]}"

fi

# -----------------------------------------
# Resolve title using canonical rules
# -----------------------------------------

canonical_input=$(canonical_title "$TITLE")

FILE=$(find_article_file "$canonical_input")

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

echo
info "Article found:"
echo "$FILE"
echo

# -----------------------------------------
# Determine action: archive, delete, or choose
# -----------------------------------------

case "$REMOVE_MODE" in

    archive)
        action="archive"
        read -r -p "Type 'archive' to confirm: " confirm
        [[ "$confirm" != "archive" ]] && { echo "Aborted."; exit 0; }
        ;;

    delete)
        action="delete"
        read -r -p "Type 'delete' to confirm: " confirm
        [[ "$confirm" != "delete" ]] && { echo "Aborted."; exit 0; }
        ;;

    choose)
        read -r -p "Type 'archive' or 'delete' to confirm: " confirm
        case "$confirm" in
            archive) action="archive" ;;
            delete)  action="delete"  ;;
            *)       echo "Aborted."; exit 0 ;;
        esac
        ;;

    *)
        die "Invalid REMOVE_MODE in config: '$REMOVE_MODE' (expected archive, delete, or choose)"
        ;;
esac

# -----------------------------------------
# Archive or delete
# -----------------------------------------

if [[ "$action" == "archive" ]]; then

    [[ -n "$ARCHIVE_DIR" ]] || die "ARCHIVE_DIR not set in config."

    mkdir -p "$ARCHIVE_DIR"

    base=$(basename "$FILE")
    dest="$ARCHIVE_DIR/$base"

    # Avoid filename overwrite
    if [[ -f "$dest" ]]; then
        dest="$ARCHIVE_DIR/$(add_disambiguation_suffix "${base%.md}").md"
    fi

    mv "$FILE" "$dest" || die "Failed to archive file."

    info "Archived to: $dest"

else
    [[ -f "$FILE" ]] || die "File not found: $FILE"
    rm "$FILE" || die "Failed to delete file."
    info "Deleted: $FILE"
fi

# -----------------------------------------
# Optional reindex
# -----------------------------------------

if [[ "$AUTO_REINDEX" == "true" ]]; then
    "$SCRIPT_DIR/nina" -i || die "Reindex failed."
    # echo "Index updated."
fi

exit 0
