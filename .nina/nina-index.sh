#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

mkdir -p "$(dirname "$INDEX_FILE")"

TMP_INDEX=$(mktemp) || die "Failed to create temp file."

WARN_COUNT=0
SKIP_COUNT=0

declare -a SKIPPED_FILES

declare -A first_row
declare -A duplicate_titles
declare -A duplicate_files
declare -A alias_src        # canonical title -> newline-separated raw aliases

shopt -s nullglob

for file in "$NINA_DIR"/*.md; do

    # -----------------------------------------
    # Extract header block and normalize fields
    # -----------------------------------------

    header=$(read_header "$file")
    raw_title=$(header_field "$header" "Title")
    title="$(normalize_display_title "$raw_title")"
    canonical=$(canonical_title "$title")

    # -----------------------------------------
    # Validate title
    # -----------------------------------------

    if [[ -z "$canonical" ]]; then
        error "Malformed header in: $file (article not indexed)"
        ((SKIP_COUNT++))
        SKIPPED_FILES+=("$file")
        continue
    fi

    # -----------------------------------------
    # Extract author
    # -----------------------------------------

    author=$(header_field "$header" "Author")

    # -----------------------------------------
    # Extract and normalize tags
    # -----------------------------------------

    tags=$(header_field "$header" "Tags")

    if [[ -n "$tags" ]]; then
        tags=$(echo "$tags" \
            | tr 'A-Z' 'a-z' \
            | tr ',' ' ' \
            | tr -s ' ' \
            | tr ' ' '\n' \
            | grep -v '^$' \
            | sort -u \
            | paste -sd "," -)
    fi

    # -----------------------------------------
    # Date handling
    # -----------------------------------------

    doc_date="$(header_field "$header" "Date")"

    if valid_date "$doc_date"; then
        modified="$doc_date"
    else
        if [[ -n "$doc_date" ]]; then
            warn "Invalid date ignored in: $file ($doc_date)"
            ((WARN_COUNT++))
        fi

        modified=$(stat_date "$file" 2>/dev/null)
    fi

    # -----------------------------------------
    # Prepare index row
    # -----------------------------------------

    row=$(printf "%s\t%s\t%s\t%s\t%s" \
        "$file" "$title" "$author" "$modified" "$tags")

    # -----------------------------------------
    # Duplicate detection
    # -----------------------------------------

    if [[ -z "${first_row[$canonical]}" ]]; then
        first_row["$canonical"]="$row"
        duplicate_files["$canonical"]="$file"

        # Collect this article's alias declarations - one per
        # "- Alias:" header line. They are resolved into the
        # alias index in a second pass below, once the full set
        # of live titles is known. Gated so a disabled install
        # pays nothing for the extraction.
        if [[ "$ENABLE_ALIASES" == true ]]; then
            alias_src["$canonical"]=$(printf '%s\n' "$header" \
                | grep '^- Alias:' \
                | sed 's/^- Alias:[[:space:]]*//')
        fi
    else
        duplicate_titles["$canonical"]=1
        duplicate_files["$canonical"]+="|$file"
    fi

done

shopt -u nullglob

# -----------------------------------------
# Write valid rows to index
# -----------------------------------------

for canon in "${!first_row[@]}"; do

    if [[ -n "${duplicate_titles[$canon]}" ]]; then
        ((SKIP_COUNT++))
        continue
    fi

    printf "%s\n" "${first_row[$canon]}" >> "$TMP_INDEX"

done

# -----------------------------------------
# Report duplicate titles (sorted)
# -----------------------------------------

if (( ${#duplicate_titles[@]} > 0 )); then

    echo
        mapfile -t sorted_titles < <(printf "%s\n" "${!duplicate_titles[@]}" | LC_ALL=C sort)
    for canon in "${sorted_titles[@]}"; do

        error "Duplicate title detected: $canon"

        IFS='|' read -ra files <<< "${duplicate_files[$canon]}"

        for f in "${files[@]}"; do
            echo "  $f"
        done

        echo "  (articles not indexed)"
        echo

    done

    info "Resolve duplicates using:"
    echo "  nina --doctor"
    echo "  nina --repair"

fi

# -----------------------------------------
# Commit index atomically
# -----------------------------------------

mv "$TMP_INDEX" "$INDEX_FILE" || die "[ERROR] Failed to write index."
    "$SCRIPT_DIR/nina-completion.sh"

# -----------------------------------------
# Build the alias index (BETA - ENABLE_ALIASES)
#
# Maps each live alias to the real title it resolves to,
# one "alias<TAB>title" row per alias. It is consumed only
# through the library's alias resolver - there are no inline
# readers, so this file's shape is known in exactly one place.
#
# Two build-time collision rules keep the file unambiguous.
# The funnel checks the main index first, so a real title
# already wins at query time - these rules are hygiene that
# keep dead rows out of the file, not load-bearing correctness:
#   - an alias equal to any real title (even one dropped as a
#     duplicate) is shadowed and skipped; the title always wins.
#   - an alias claimed by two different articles is dropped
#     entirely, both of them.
#
# Runs after the main index is committed so a problem here can
# never block the primary output. When disabled, any stale file
# is removed so the file's existence always matches the flag.
# -----------------------------------------

if [[ "$ENABLE_ALIASES" == true ]]; then

    declare -A alias_target    # alias canonical -> target display title
    declare -A alias_display   # alias canonical -> alias display string
    declare -A alias_source    # alias canonical -> first-claiming file
    declare -A alias_dropped   # alias canonical -> 1 if claimed more than once

    for canon in "${!alias_src[@]}"; do

        # An article that lost a duplicate-title fight is not in
        # the index, so any alias pointing at it would be dead.
        [[ -n "${duplicate_titles[$canon]}" ]] && continue
        [[ -z "${alias_src[$canon]}" ]] && continue

        IFS=$'\t' read -r src_file target_title _ <<< "${first_row[$canon]}"

        while IFS= read -r raw_alias; do

            [[ -z "$raw_alias" ]] && continue

            a_display="$(normalize_display_title "$raw_alias")"
            a_canon="$(canonical_title "$a_display")"

            [[ -z "$a_canon" ]] && continue

            # Shadowed by a real title (indexed or dropped-duplicate).
            if [[ -n "${first_row[$a_canon]}" ]]; then
                warn "Alias '$a_display' shadowed by an existing title (in: $src_file); ignored."
                ((WARN_COUNT++))
                continue
            fi

            # Already claimed. If by the same article (a repeated
            # "- Alias:" line), ignore the repeat quietly. If by a
            # different article, it is a real collision - drop both.
            if [[ -n "${alias_target[$a_canon]}" || -n "${alias_dropped[$a_canon]}" ]]; then
                if [[ "${alias_source[$a_canon]}" != "$src_file" ]]; then
                    alias_dropped["$a_canon"]=1
                fi
                continue
            fi

            alias_target["$a_canon"]="$target_title"
            alias_display["$a_canon"]="$a_display"
            alias_source["$a_canon"]="$src_file"

        done <<< "${alias_src[$canon]}"

    done

    TMP_ALIAS=$(mktemp) || die "Failed to create temp file."

    for a_canon in "${!alias_target[@]}"; do

        if [[ -n "${alias_dropped[$a_canon]}" ]]; then
            warn "Alias '${alias_display[$a_canon]}' claimed by multiple articles; ignored."
            ((WARN_COUNT++))
            continue
        fi

        printf '%s\t%s\n' \
            "${alias_display[$a_canon]}" "${alias_target[$a_canon]}" >> "$TMP_ALIAS"

    done

    mv "$TMP_ALIAS" "$ALIAS_INDEX_FILE" \
        || warn "Failed to write alias index: $ALIAS_INDEX_FILE"

else
    rm -f "$ALIAS_INDEX_FILE"
fi

echo "Index updated successfully."

if (( WARN_COUNT > 0 )); then
    echo "$WARN_COUNT warning(s) encountered during indexing."
fi

if (( SKIP_COUNT > 0 )); then
    echo "$SKIP_COUNT article group(s) skipped due to errors."
fi

if (( ${#SKIPPED_FILES[@]} > 0 )); then
    echo
    info "Files skipped due to malformed headers:"
    for f in "${SKIPPED_FILES[@]}"; do
        echo "  $f"
    done
fi

if (( WARN_COUNT + SKIP_COUNT > 0 )); then
    echo
    info "Problems were encountered during indexing."
    info "Run 'nina --doctor' to review issues."
    info "Run 'nina --repair' to attempt interactive fixes."
fi

exit 0