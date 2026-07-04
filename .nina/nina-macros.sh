#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

MACROS_DIR="${MACROS_DIR:-$HOME/.nina/macros}"
MANIFEST_FILE="$HOME/.nina/macros.tsv"
DISPATCH_FILE="$HOME/.nina/macros-dispatch.awk"

mkdir -p "$MACROS_DIR"
mkdir -p "$(dirname "$MANIFEST_FILE")"

TMP_MANIFEST=$(make_temp_file) || die "Failed to create temp file."

SKIP_COUNT=0
declare -a SKIPPED_FILES
declare -a SKIPPED_REASONS

declare -A first_file_for_name
declare -A duplicate_names
declare -A duplicate_files

declare -A first_file_for_function
declare -A duplicate_functions
declare -A duplicate_function_files

# -----------------------------------------
# Record a skipped macro file with a reason
# -----------------------------------------

skip_macro() {
    local file="$1"
    local reason="$2"

    SKIPPED_FILES+=("$file")
    SKIPPED_REASONS+=("$reason")
    ((SKIP_COUNT++))
}

# -----------------------------------------
# Scan each macro file
# -----------------------------------------

shopt -s nullglob

TOTAL_FILES=0

for file in "$MACROS_DIR"/*.awk; do

    ((TOTAL_FILES++))

    # -----------------------------------------
    # Validation itself lives in nina-lib.sh's
    # validate_macro_file, shared with
    # nina --doctor so both tools agree on what
    # makes a macro file valid.
    # -----------------------------------------

    validation_result=$(validate_macro_file "$file")

    if [[ $? -ne 0 ]]; then
        skip_macro "$file" "$validation_result"
        continue
    fi

    IFS=$'\t' read -r name function_name <<< "$validation_result"

    # -----------------------------------------
    # Duplicate name detection (collect now,
    # report after the full scan, same pattern
    # nina-index.sh uses for duplicate titles)
    # -----------------------------------------

    if [[ -z "${first_file_for_name[$name]}" ]]; then
        first_file_for_name["$name"]="$file|$function_name"
    else
        duplicate_names["$name"]=1
        duplicate_files["$name"]+="|$file"
    fi

    # -----------------------------------------
    # Independent collision check on the derived
    # function name - two files can have
    # different macro names but still derive the
    # same function name (e.g. progress-bar.awk
    # and progress_bar.awk both sanitize to
    # macro_progress_bar). Either collision alone
    # is enough to exclude the file.
    # -----------------------------------------

    if [[ -z "${first_file_for_function[$function_name]}" ]]; then
        first_file_for_function["$function_name"]="$file"
    else
        duplicate_functions["$function_name"]=1
        duplicate_function_files["$function_name"]+="|$file"
    fi

done

shopt -u nullglob

# -----------------------------------------
# Write valid rows to manifest, excluding
# anything involved in a name collision. The
# FIRST file claiming a given name/function
# also needs excluding once a later file is
# found to collide with it - it was counted
# as skipped above (for the later file); here
# we just need to skip writing it, not count
# it again.
# -----------------------------------------

for name in "${!first_file_for_name[@]}"; do

    if [[ -n "${duplicate_names[$name]}" ]]; then
        continue
    fi

    IFS='|' read -r file function_name <<< "${first_file_for_name[$name]}"

    if [[ -n "${duplicate_functions[$function_name]}" ]]; then
        continue
    fi

    printf "%s\t%s\t%s\n" "$name" "$function_name" "$file" >> "$TMP_MANIFEST"

done

# -----------------------------------------
# Report duplicate names (sorted)
# -----------------------------------------

if (( ${#duplicate_names[@]} > 0 )); then

    echo
    mapfile -t sorted_names < <(printf "%s\n" "${!duplicate_names[@]}" | LC_ALL=C sort)

    for name in "${sorted_names[@]}"; do

        error "Duplicate macro name detected: $name"

        files="${duplicate_files[$name]}"
        files="${files#|}"
        IFS='|' read -ra flist <<< "$files"

        IFS='|' read -r first_file _ <<< "${first_file_for_name[$name]}"
        echo "  $first_file"

        for f in "${flist[@]}"; do
            echo "  $f"
        done

        echo "  (macro not loaded)"
        echo

    done

fi

# -----------------------------------------
# Report function-name collisions (sorted)
# -----------------------------------------

if (( ${#duplicate_functions[@]} > 0 )); then

    echo
    mapfile -t sorted_functions < <(printf "%s\n" "${!duplicate_functions[@]}" | LC_ALL=C sort)

    for fn in "${sorted_functions[@]}"; do

        error "Two macro files derive the same function name: $fn"

        files="${duplicate_function_files[$fn]}"
        files="${files#|}"
        IFS='|' read -ra flist <<< "$files"

        echo "  ${first_file_for_function[$fn]}"

        for f in "${flist[@]}"; do
            echo "  $f"
        done

        echo "  (neither macro loaded - rename one of these files)"
        echo

    done

fi

# -----------------------------------------
# Commit manifest atomically
#
# SKIP_COUNT is derived here, not tracked via
# manual increments scattered through the scan
# above - total files scanned minus rows
# actually written is the only count that can't
# drift from what really happened.
# -----------------------------------------

MANIFEST_ROWS=$(wc -l < "$TMP_MANIFEST")
SKIP_COUNT=$(( TOTAL_FILES - MANIFEST_ROWS ))

# -----------------------------------------
# Prepend an auto-generated notice - this
# happens after MANIFEST_ROWS is computed
# above, so the notice line is never counted
# as a macro row.
# -----------------------------------------

{
    echo "# This is an auto-generated system file. Manual changes may be overwritten."
    echo "# Run nina --macro to update this file."
    cat "$TMP_MANIFEST"
} > "${TMP_MANIFEST}.headed"
mv "${TMP_MANIFEST}.headed" "$TMP_MANIFEST"

mv "$TMP_MANIFEST" "$MANIFEST_FILE" || die "Failed to write macro manifest."

# -----------------------------------------
# Generate the dispatch chain once, here, as
# a persistent file - not regenerated on every
# render call. AWK has no indirect/dynamic
# function call mechanism, so this name-to-
# function lookup has to exist as real code
# somewhere; generating it from the manifest
# means no one ever hand-maintains it.
# -----------------------------------------

TMP_DISPATCH=$(make_temp_file) || die "Failed to create temp file."

{
    echo "function dispatch_macro(name, args) {"

    while IFS=$'\t' read -r macro_name macro_function macro_file; do
        [[ -z "$macro_name" || "$macro_name" == \#* ]] && continue

        # Escape backslashes and double-quotes so the
        # name embeds safely as an AWK string literal
        escaped_name=$(printf '%s' "$macro_name" | sed 's/\\/\\\\/g; s/"/\\"/g')

        echo "    if (name == \"$escaped_name\") return $macro_function(args)"
    done < "$MANIFEST_FILE"

    echo "    return \"\001UNKNOWN\001\""
    echo "}"
} > "$TMP_DISPATCH"

mv "$TMP_DISPATCH" "$DISPATCH_FILE" || die "Failed to write macro dispatch file."

echo "Macro manifest updated successfully."

if (( SKIP_COUNT > 0 )); then
    echo "$SKIP_COUNT macro(s) skipped due to errors."
fi

if (( ${#SKIPPED_FILES[@]} > 0 )); then
    echo
    info "Files skipped:"
    for i in "${!SKIPPED_FILES[@]}"; do
        echo "  ${SKIPPED_FILES[$i]} (${SKIPPED_REASONS[$i]})"
    done
fi

if (( SKIP_COUNT > 0 )); then
    echo
    info "Run 'nina --doctor' to review macro issues."
fi

exit 0
