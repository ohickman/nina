#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

[[ -d "$NINA_DIR" ]] || die "NINA_DIR not found."
require_index

require_interactive

echo
echo "Nina Repair"
echo "-----------"

declare -A seen_titles
declare -A duplicates

issues_found=0

shopt -s nullglob

for file in "$NINA_DIR"/*.md; do

    header=$(read_header "$file")
    title=$(header_field "$header" "Title")

    # -----------------------------------------
    # Missing title
    # -----------------------------------------

    if [[ -z "$title" ]]; then

        issues_found=1

        echo
        echo "Missing title in: $file"

        read -r -p "Enter title (or press Enter to skip): " new_title

        [[ -z "$new_title" ]] && continue

        tmp=$(make_temp_file)

        {
            printf "# %s\n\n" "$new_title"
            cat "$file"
        } > "$tmp"

        mv "$tmp" "$file"

        echo "Title added."

        continue
    fi

    canonical=$(canonical_title "$title")

    # -----------------------------------------
    # Duplicate titles
    # -----------------------------------------

    if [[ -n "${seen_titles[$canonical]}" ]]; then

        # First time we detect a duplicate, include the original file
        if [[ -z "${duplicates[$canonical]}" ]]; then
            duplicates["$canonical"]="${seen_titles[$canonical]}|"
        fi

        duplicates["$canonical"]+="$file|"

    else
        seen_titles["$canonical"]="$file"
    fi

    # -----------------------------------------
    # Invalid date (really lightweight rules)
    # -----------------------------------------

    date=$(header_field "$header" "Date")

    if [[ -n "$date" ]] && ! valid_date "$date"; then

        issues_found=1

        echo
        echo "Invalid date in: $file"
        echo "Current value: $date"

        read -r -p "Enter corrected date (YYYY-MM-DD) or Enter to remove: " new_date

        tmp=$(make_temp_file)

        if [[ -z "$new_date" ]]; then
            if sed '/^- Date:/d' "$file" > "$tmp" && [[ -s "$tmp" || ! -s "$file" ]]; then
                mv "$tmp" "$file"
                echo "Date updated."
            else
                rm -f "$tmp"
                error "Failed to update date — original file left unchanged."
            fi
        else
            escaped_date=$(printf '%s' "$new_date" | sed 's/[&/\]/\\&/g')
            if sed "s/^- Date:.*/- Date: $escaped_date/" "$file" > "$tmp" && [[ -s "$tmp" || ! -s "$file" ]]; then
                mv "$tmp" "$file"
                echo "Date updated."
            else
                rm -f "$tmp"
                error "Failed to update date — original file left unchanged."
            fi
        fi

    fi

done

# -----------------------------------------
# Resolve duplicate titles
# -----------------------------------------

for canon in "${!duplicates[@]}"; do

    issues_found=1

    echo
    echo "Duplicate title detected: $canon"
    echo

    files="${duplicates[$canon]}"
    files="${files%|}"

    IFS='|' read -ra list <<< "$files"

    # Sort files for deterministic display
    mapfile -t sorted_list < <(printf "%s\n" "${list[@]}" | sort)

    print_numbered_list "${sorted_list[@]}"

    echo
    read -r -p "Select article to rename (Enter to skip): " choice

    [[ -z "$choice" ]] && continue

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#list[@]} )); then
        echo "Invalid selection."
        continue
    fi

    file="${list[$((choice-1))]}"

    header=$(read_header "$file")
    old_title=$(header_field "$header" "Title")

    echo
    echo "Current title: $old_title"
    echo
    echo "Similar titles:"
    suggest_titles "$old_title" | sed 's/^/  /'

    while true; do

        echo
        read -r -p "Enter new title (or press Enter to cancel): " new_title
        [[ -z "$new_title" ]] && break

        new_title="$(normalize_display_title "$new_title")"
        canonical_new=$(canonical_title "$new_title")

        # Canonical collision
        existing=$(find_article_file "$canonical_new")

        if [[ -n "$existing" ]]; then
            echo
            warn "Title already exists:"
            echo "  $existing"
            echo
            echo "Similar titles:"
            suggest_titles "$new_title" | sed 's/^/  /'
            echo
            continue
        fi

        # Valid title
        tmp=$(make_temp_file)

        escaped_title=$(printf '%s' "$new_title" | sed 's/[&/\]/\\&/g')

        if sed "1s/^# .*/# $escaped_title/" "$file" > "$tmp" && [[ -s "$tmp" ]]; then
            mv "$tmp" "$file"
            echo "Title updated."
        else
            rm -f "$tmp"
            error "Failed to update title — original file left unchanged."
        fi
        break

    done

done

shopt -u nullglob

if [[ "$issues_found" == 0 ]]; then
    echo
    info "No repairable issues found."
    exit 0
fi

# -----------------------------------------
# Reindex
# -----------------------------------------

echo
read -r -p "Rebuild index now? (y/n): " ans

if [[ "$ans" =~ ^[Yy]$ ]]; then
    "$SCRIPT_DIR/nina" --index
fi

echo
echo "Repair complete."
