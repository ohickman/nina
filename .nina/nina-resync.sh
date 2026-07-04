#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

[[ -d "$NINA_DIR" ]] || die "NINA_DIR not found: $NINA_DIR"

require_interactive

# -----------------------------------------
# This script intentionally does NOT use
# index.tsv. It reads titles directly from
# the .md files in NINA_DIR, so it stays
# correct even for articles the user has
# staged but not yet reindexed (e.g. files
# they don't want visible to other users
# until a deliberate `nina --index` run).
# -----------------------------------------

renamed_count=0

# -----------------------------------------
# One-time scan: read every article's title
# directly from disk and find mismatches.
# This is the only full pass over NINA_DIR -
# the loop below operates entirely on this
# in-memory list, removing entries as they're
# resolved, so renaming several articles in
# one run doesn't cost a full rescan each time.
# -----------------------------------------

mismatches=()   # "title|file|expected_slug" per row

printf "Scanning %s now...\n" "$NINA_DIR"

shopt -s nullglob

for file in "$NINA_DIR"/*.md; do

    header="$(read_header "$file")"
    raw_title="$(header_field "$header" "Title")"

    [[ -z "$raw_title" ]] && continue

    title="$(normalize_display_title "$raw_title")"

    stem="$(basename "$file" .md)"
    actual_stem="$(strip_disambiguation_suffix "$stem")"

    proposed_slug="$(generate_slug "$title")"
    expected_stem="$(strip_disambiguation_suffix "$proposed_slug")"

    if [[ "$expected_stem" != "$actual_stem" ]]; then
        mismatches+=("$title"$'\t'"$file"$'\t'"$proposed_slug")
    fi

done

shopt -u nullglob

if (( ${#mismatches[@]} == 0 )); then
    info "No mismatches found. Every filename matches its article's title."
    exit 0
fi

# -----------------------------------------
# Main loop: list current mismatches, prompt,
# rename, and remove the resolved entry from
# the in-memory list - no rescan needed.
# -----------------------------------------

while (( ${#mismatches[@]} > 0 )); do

    echo

    table_begin " #" 6 "TITLE" 30 "FILENAME" 0
    table_header

    for i in "${!mismatches[@]}"; do
        IFS=$'\t' read -r m_title m_file m_slug <<< "${mismatches[$i]}"
        table_row "$((i+1))" "$m_title" "$(basename "$m_file")"
    done

    echo
    read -r -p "Select article to rename (Enter to exit): " choice

    [[ -z "$choice" ]] && break

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#mismatches[@]} )); then
        warn "Invalid selection."
        continue
    fi

    index=$((choice-1))
    IFS=$'\t' read -r sel_title sel_file sel_slug <<< "${mismatches[$index]}"

    new_file="$(dirname "$sel_file")/${sel_slug}.md"

    # Disambiguate if the proposed name is already taken by
    # some other, unrelated file - the rename always succeeds;
    # the user can manually rename further if they don't like
    # the resulting suffix.
    if [[ -e "$new_file" ]]; then
        new_file="$(dirname "$sel_file")/$(add_disambiguation_suffix "$sel_slug").md" #" (closing quote hack for syntax highlighters)
    fi

    echo
    echo "Change file name to: $(basename "$new_file")"
    read -r -p "Type 'rename' to accept (Enter to cancel): " confirm

    if [[ "$confirm" != "rename" ]]; then
        echo "Skipped."
        continue
    fi

    if mv "$sel_file" "$new_file"; then
        info "Renamed to: $(basename "$new_file")"
        ((renamed_count++))
        unset 'mismatches[index]'
        mismatches=("${mismatches[@]}")   # re-pack array indices
    else
        error "Rename failed for: $sel_file"
    fi

done

# -----------------------------------------
# Final summary - this script does not
# reindex itself, since it may rename many
# files in one run and reindexing after each
# one would be wasteful, and because the
# user may be deliberately staging files
# they don't want indexed yet.
# -----------------------------------------

echo

if (( renamed_count > 0 )); then
    if (( renamed_count == 1 )); then
        echo "1 file renamed."
    else
        echo "$renamed_count files renamed."
    fi
    echo "Run 'nina --index' to update the index."
else
    echo "No files renamed."
fi

exit 0
