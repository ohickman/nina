#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config


# -----------------------------------------
# Interactive restore menu
# -----------------------------------------

interactive_restore() {

    [[ -d "$ARCHIVE_DIR" ]] || die "Archive directory not found: $ARCHIVE_DIR"

    shopt -s nullglob
    files=("$ARCHIVE_DIR"/*.md)
    shopt -u nullglob

    (( ${#files[@]} == 0 )) && {
        info "Archive is empty."
        return 0
    }

    rows=()

    for file in "${files[@]}"; do

        header=$(read_header "$file")

        raw_title=$(header_field "$header" "Title")
        title="$(normalize_display_title "$raw_title")"

        tags=$(header_field "$header" "Tags")
        doc_date=$(header_field "$header" "Date")

        if valid_date "$doc_date"; then
            modified="$doc_date"
        else
            modified=$(stat -c %y "$file" | cut -d' ' -f1)
        fi

        rows+=("$file"$'\t'"$title"$'\t'"$modified"$'\t'"$tags")

    done

    printf "\n"

    table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
    table_header

    for i in "${!rows[@]}"; do

        IFS=$'\t' read -r file title modified tags <<< "${rows[$i]}"

        table_row $((i+1)) "$title" "$modified" "$tags"

    done

    echo
    read -p "Restore article number (Enter to cancel): " choice

    [[ -z "$choice" ]] && return 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#rows[@]} )); then
        error "Invalid selection."
        return 1
    fi

    IFS=$'\t' read -r FILE TITLE _ <<< "${rows[$((choice-1))]}"

    restore_selected_file "$FILE" "$TITLE"
}


# -----------------------------------------
# Restore selected file
# -----------------------------------------

restore_selected_file() {

    FILE="$1"
    TITLE="$2"

    canonical_input=$(canonical_title "$TITLE")

    while true; do

        existing=$(find_article_file "$canonical_input")

        [[ -z "$existing" ]] && break

        echo
        warn "Title collision detected with an active article."

        echo "Existing article:"
        echo "  $existing"

        # -----------------------------------------
        # Show similar titles
        # -----------------------------------------

        similar=$(suggest_titles "$TITLE")

        if [[ -n "$similar" ]]; then
            echo
            echo "Similar titles:"
            echo "$similar" | sed 's/^/  /'
        fi

        echo
        echo " [1] Edit title"
        echo " [2] Abort"
        echo

        read -p "Choice: " opt

        case "$opt" in

            1)

                "${EDITOR:-${VISUAL:-vi}}" "$FILE"

                header=$(read_header "$FILE")

                raw_title=$(header_field "$header" "Title")
                TITLE="$(normalize_display_title "$raw_title")"

                canonical_input=$(canonical_title "$TITLE")
                ;;

            *)
                error "Restore aborted."
                return 1
                ;;
        esac

    done


    base=$(basename "$FILE")
    dest="$NINA_DIR/$base"

    # Rename if filename collision exists
    if [[ -f "$dest" ]]; then
        dest="$NINA_DIR/$(add_disambiguation_suffix "${base%.md}").md"
    fi

    mv "$FILE" "$dest" || die "Restore failed."

    echo
    echo "[SUCCESS] Restored: $dest"

    if [[ "$AUTO_REINDEX" == true ]]; then
        "$SCRIPT_DIR/nina" --index || die "Reindex failed."
    fi
}


# -----------------------------------------
# CLI Restore Mode
# -----------------------------------------

TITLE="$1"

if [[ -z "$TITLE" ]]; then
    interactive_restore
    exit $?
fi

[[ -d "$ARCHIVE_DIR" ]] || die "Archive directory not found: $ARCHIVE_DIR"


# -----------------------------------------
# Find archived versions
# -----------------------------------------

slug=$(generate_slug "$TITLE")
[[ -z "$slug" ]] && die "Invalid title."

shopt -s nullglob
matches=("$ARCHIVE_DIR/${slug}"*.md)
shopt -u nullglob

(( ${#matches[@]} == 0 )) && die "No archived versions found for: $TITLE"


# -----------------------------------------
# Sort newest first
# -----------------------------------------

for i in "${!matches[@]}"; do
    matches[$i]="$(stat -c %Y "${matches[$i]}")|${matches[$i]}"
done

IFS=$'\n' matches=($(printf "%s\n" "${matches[@]}" | sort -rn))
unset IFS

for i in "${!matches[@]}"; do
    matches[$i]="${matches[$i]#*|}"
done


# -----------------------------------------
# Choose version if multiple
# -----------------------------------------

if (( ${#matches[@]} > 1 )); then

    echo
    echo "Multiple archived versions found:"
    echo

    print_numbered_list "${matches[@]##*/}"

    echo
    read -p "Select version number to restore: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#matches[@]} )); then
        die "Invalid selection."
    fi

    FILE="${matches[$((choice-1))]}"

else

    FILE="${matches[0]}"

fi


dest="$NINA_DIR/$(basename "$FILE")"


# -----------------------------------------
# Prevent canonical title collision
# -----------------------------------------

require_index

canonical_input=$(canonical_title "$TITLE")

existing=$(find_article_file "$canonical_input")

[[ -n "$existing" ]] && die "An active article with this title already exists."


# -----------------------------------------
# Restore file
# -----------------------------------------

if [[ -f "$dest" ]]; then
    dest="$NINA_DIR/$(add_disambiguation_suffix "$(basename "${FILE%.md}")").md"
fi

mv "$FILE" "$dest" || die "Restore failed."

echo "[SUCCESS] Restored to: $dest"


# -----------------------------------------
# Optional reindex
# -----------------------------------------

if [[ "$AUTO_REINDEX" == true ]]; then
    "$SCRIPT_DIR/nina" --index || die "Reindex failed."
fi

exit 0