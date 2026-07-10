#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

PLUGINS_DIR="${PLUGINS_DIR:-$HOME/.nina/plugins}"
MANIFEST_FILE="$HOME/.nina/plugins.tsv"

mkdir -p "$PLUGINS_DIR"
mkdir -p "$(dirname "$MANIFEST_FILE")"

TMP_MANIFEST=$(make_temp_file) || die "Failed to create temp file."

SKIP_COUNT=0
declare -a SKIPPED_FILES
declare -a SKIPPED_REASONS

declare -A first_file_for_name
declare -A duplicate_names
declare -A duplicate_files

# -----------------------------------------
# Validate a single plugin (.awk) file.
#
# Lives here, not in nina-lib.sh: unlike
# validate_macro_file (genuinely shared by
# nina-macros.sh and nina-doctor.sh), this
# has exactly one caller.  nina-doctor.sh
# reimplements its own validation logic as
# a second check against the validation 
# logic in this script.
#
# Unlike a macro file, a plugin has no
# required entry-point function name - a
# plugin is run as its own complete AWK
# program against the article on stdin, and
# whatever it prints to stdout (unredirected)
# *is* its output. There is no in-process
# dispatch to wire up, so there is nothing
# here resembling dispatch_macro()'s
# function-name-collision concern.
#
# What a plugin file may NOT contain is
# checked instead, since that is the actual
# safety boundary for this system:
#   - system()              -> arbitrary command execution
#   - getline (any form)    -> arbitrary file/command read
#   - print/printf redirect -> arbitrary file/command write
# These three are the only native doors AWK
# has to the filesystem and the OS, so
# closing all three turns "does this plugin
# reach outside the sandbox" from a guess
# into a fact: the only way out left is
# whichever function nina-plugin-api.awk
# provides, since that file is the one
# piece of code these checks do not apply
# to (see nina-developer_technical_guide.md,
# "The Plugin System").
#
# Word-boundary checks below use a portable
# (^|[^A-Za-z0-9_]) / ([^A-Za-z0-9_]|$)
# pattern rather than \< \> or \b, since
# those are GNU extensions and nina aims to
# behave the same way under any POSIX-ish
# grep, consistent with the project's BSD
# and iOS interoperability goals elsewhere
# in nina-lib.sh.
#
# On success, prints "name<TAB>needs_long_timeout"
# (needs_long_timeout is "1" if the file
# references plugin_http_get or
# plugin_call_nina, "0" otherwise) and
# returns 0. On failure, prints a reason and
# returns 1.
# -----------------------------------------

validate_plugin_file() {
    local file="$1"
    local first_line raw_name name needs_long_timeout

    first_line=$(head -n 1 "$file")

    if [[ "$first_line" != \#* ]]; then
        echo "first line is not a comment declaring the plugin name"
        return 1
    fi

    raw_name="${first_line#\#}"
    name=$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [[ -z "$name" ]]; then
        echo "missing or empty plugin name"
        return 1
    fi

    if [[ "$name" == *[[:space:]]* ]]; then
        echo "plugin name contains whitespace: '$name'"
        return 1
    fi

    if [[ "$name" == *">"* ]]; then
        echo "plugin name contains '>': '$name'"
        return 1
    fi

    # -----------------------------------------
    # Security checks run BEFORE the file is ever
    # handed to awk for any reason, including the
    # syntax check below. A file's BEGIN block (or
    # any top-level rule) runs the moment awk loads
    # it - there is no "parse only, don't execute"
    # mode - so a file containing system(), getline,
    # or a redirected print/printf must be rejected
    # on its source text alone, never by first
    # running it and seeing what happens.
    # -----------------------------------------

    if grep -qE '(^|[^A-Za-z0-9_])system[[:space:]]*\(' "$file"; then
        echo "plugin uses system() - not permitted"
        return 1
    fi

    if grep -qE '(^|[^A-Za-z0-9_])getline([^A-Za-z0-9_]|$)' "$file"; then
        echo "plugin uses getline - not permitted"
        return 1
    fi

    if plugin_source_logical_lines "$file" \
        | grep -nE '(^|[^A-Za-z0-9_])print(f)?([^A-Za-z0-9_]|$)' \
        | grep -qE '(>>?|\|)'; then
        echo "plugin uses print/printf redirection - not permitted"
        return 1
    fi

    # -----------------------------------------
    # Only now is it safe to actually run the file -
    # the three checks above guarantee it has no
    # native way to touch the filesystem, the
    # network, or any other process. The API file
    # is loaded alongside it, exactly as it will be
    # at real render time (see run_plugin() in
    # nina-plugins.awk) - a plugin is never expected
    # to be syntactically self-contained on its own,
    # since calls to plugin_args(), plugin_backlinks(),
    # etc. are only defined there. Input is /dev/null
    # (so a plugin with a real main loop hits EOF
    # immediately rather than this check needing to
    # supply a fake input file), stdout/stderr are
    # discarded (this check only cares about the exit
    # status), and it's time-bounded in case the file
    # parses fine but hangs (e.g. an unconditional
    # infinite loop with no I/O at all, which the
    # bans above do nothing to prevent).
    # -----------------------------------------

    if ! timeout 5 awk -f "$SCRIPT_DIR/nina-plugin-api.awk" -f "$file" < /dev/null > /dev/null 2>/dev/null; then
        echo "syntax error, runtime error, or did not terminate"
        return 1
    fi

    needs_long_timeout=0
    if grep -qE '(^|[^A-Za-z0-9_])(plugin_http_get|plugin_call_nina|plugin_backlinks|plugin_tags|plugin_links|plugin_read_article|plugin_read_article_body)([^A-Za-z0-9_]|$)' "$file"; then
        needs_long_timeout=1
    fi

    printf '%s\t%s\n' "$name" "$needs_long_timeout"
    return 0
}

# -----------------------------------------
# Record a skipped plugin file with a reason
# -----------------------------------------

skip_plugin() {
    local file="$1"
    local reason="$2"

    SKIPPED_FILES+=("$file")
    SKIPPED_REASONS+=("$reason")
    ((SKIP_COUNT++))
}

# -----------------------------------------
# Scan each plugin file
#
# Validation itself lives in nina-lib.sh's
# validate_plugin_file, shared with
# nina --doctor for the same reason
# validate_macro_file is shared - one place
# decides what makes a file installable.
# -----------------------------------------

shopt -s nullglob

TOTAL_FILES=0

for file in "$PLUGINS_DIR"/*.awk; do

    ((TOTAL_FILES++))

    validation_result=$(validate_plugin_file "$file")

    if [[ $? -ne 0 ]]; then
        skip_plugin "$file" "$validation_result"
        continue
    fi

    IFS=$'\t' read -r name needs_long_timeout <<< "$validation_result"

    # -----------------------------------------
    # Record the hash of exactly the bytes that
    # were just validated. nina-plugins.awk
    # recomputes this at the moment a plugin is
    # about to run and refuses to execute on a
    # mismatch - this is what closes the gap
    # between "this file was approved" and "this
    # file is what actually runs": a path on
    # disk can be edited or replaced after
    # validation, and the manifest alone has no
    # way to notice. The cost is one extra
    # sha256sum per plugin invocation (measured
    # at roughly a millisecond on a real plugin
    # file - negligible against everything else
    # a render already does), paid only for
    # plugins an article actually calls, not for
    # every plugin installed.
    # -----------------------------------------

    hash=$(sha256sum "$file" | cut -d' ' -f1)

    # -----------------------------------------
    # Duplicate name detection (collect now,
    # report after the full scan - same
    # pattern nina-macros.sh and nina-index.sh
    # use for their own duplicate checks).
    # -----------------------------------------

    if [[ -z "${first_file_for_name[$name]}" ]]; then
        first_file_for_name["$name"]="$file|$needs_long_timeout|$hash"
    else
        duplicate_names["$name"]=1
        duplicate_files["$name"]+="|$file"
    fi

done

shopt -u nullglob

# -----------------------------------------
# Write valid rows to manifest, excluding
# anything involved in a name collision.
# -----------------------------------------

for name in "${!first_file_for_name[@]}"; do

    if [[ -n "${duplicate_names[$name]}" ]]; then
        continue
    fi

    IFS='|' read -r file needs_long_timeout hash <<< "${first_file_for_name[$name]}"

    printf "%s\t%s\t%s\t%s\n" "$name" "$file" "$needs_long_timeout" "$hash" >> "$TMP_MANIFEST"

done

# -----------------------------------------
# Report duplicate names (sorted)
# -----------------------------------------

if (( ${#duplicate_names[@]} > 0 )); then

    echo
    mapfile -t sorted_names < <(printf "%s\n" "${!duplicate_names[@]}" | LC_ALL=C sort)

    for name in "${sorted_names[@]}"; do

        error "Duplicate plugin name detected: $name"

        files="${duplicate_files[$name]}"
        files="${files#|}"
        IFS='|' read -ra flist <<< "$files"

        IFS='|' read -r first_file _ <<< "${first_file_for_name[$name]}"
        echo "  $first_file"

        for f in "${flist[@]}"; do
            echo "  $f"
        done

        echo "  (plugin not loaded)"
        echo

    done

fi

# -----------------------------------------
# Commit manifest atomically
# -----------------------------------------

MANIFEST_ROWS=$(wc -l < "$TMP_MANIFEST")
SKIP_COUNT=$(( TOTAL_FILES - MANIFEST_ROWS ))

{
    echo "# This is an auto-generated system file. Manual changes may be overwritten."
    echo "# Run nina --plugin to update this file."
    echo "# Columns: name <TAB> file <TAB> needs_long_timeout <TAB> sha256"
    echo "# needs_long_timeout is 1 if the plugin references plugin_http_get"
    echo "# or plugin_call_nina (either capability can leave the local"
    echo "# process and is therefore allowed PLUGIN_TIMEOUT instead of"
    echo "# PLUGIN_NO_WEB_TIMEOUT)."
    echo "# sha256 is the hash of the file at the time it was installed -"
    echo "# nina-plugins.awk recomputes this before every invocation and"
    echo "# refuses to run a plugin whose file no longer matches."
    cat "$TMP_MANIFEST"
} > "${TMP_MANIFEST}.headed"
mv "${TMP_MANIFEST}.headed" "$TMP_MANIFEST"

mv "$TMP_MANIFEST" "$MANIFEST_FILE" || die "Failed to write plugin manifest."

info "$MANIFEST_ROWS plugin(s) installed."

if (( SKIP_COUNT > 0 )); then
    info "$SKIP_COUNT plugin(s) skipped due to errors."
fi

if (( ${#SKIPPED_FILES[@]} > 0 )); then
    echo
    echo "Files skipped:"
    for i in "${!SKIPPED_FILES[@]}"; do
        echo "  ${SKIPPED_FILES[$i]} (${SKIPPED_REASONS[$i]})"
    done
fi

if (( SKIP_COUNT > 0 )); then
    echo
    info "Run 'nina --doctor' to review plugin issues."
fi

exit 0
