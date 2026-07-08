#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"

CONFIG_FILE="$HOME/.nina/config"

OK_COUNT=0
WARN_COUNT=0
ERROR_COUNT=0
INFO_COUNT=0

print_section() {
    echo
    echo "== $1 =="
}

ok() {
    echo "[OK]   $1"
    ((OK_COUNT++))
}

warn() {
    echo "[WARN] $1"
    ((WARN_COUNT++))
}

error() {
    echo "[ERROR] $1"
    ((ERROR_COUNT++))
}

info() {
    echo "[INFO] $1"
    ((INFO_COUNT++))
}

# ----------------------------------------
# Load Config
# ----------------------------------------

print_section "Configuration"

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Config file not found: $CONFIG_FILE"
else
    ok "Config file found"

    if bash -n "$CONFIG_FILE" 2>/dev/null; then
        ok "Config syntax valid"
        source "$CONFIG_FILE"
    else
        error "Config contains syntax errors"
    fi
fi

# ----------------------------------------
# Environment Checks
# ----------------------------------------

print_section "Environment"

for cmd in awk sed grep sort less stat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd found"
    else
        error "$cmd not found"
    fi
done

if command -v tput >/dev/null 2>&1; then
    ok "tput found"
else
    warn "tput not found (terminal width fallback in use)"
fi

if [[ -n "$EDITOR" ]]; then
    ok "EDITOR set to $EDITOR"
else
    warn "EDITOR not set"
fi

# ----------------------------------------
# File System Checks
# ----------------------------------------

print_section "File System"

if [[ -d "$NINA_DIR" ]]; then
    ok "NINA_DIR exists"
else
    error "NINA_DIR missing: $NINA_DIR"
fi

if [[ -w "$NINA_DIR" ]]; then
    ok "NINA_DIR writable"
else
    warn "NINA_DIR not writable"
fi

if [[ -f "$INDEX_FILE" ]]; then
    ok "Index file exists"
else
    warn "Index file missing"
fi

# ----------------------------------------
# Index Integrity
# ----------------------------------------

print_section "Index Integrity"

if [[ -f "$INDEX_FILE" ]]; then

    declare -A seen_titles
    declare -A dup_titles
    declare -A seen_slugs
    declare -A dup_slugs
    declare -A indexed_files

    missing_indexed_count=0

    # -------------------------------------
    # Index structure validation
    # -------------------------------------

    bad_rows=$(awk -F'\t' 'NF != 5 { print NR }' "$INDEX_FILE")

    if [[ -n "$bad_rows" ]]; then
        error "Malformed rows detected in index.tsv"
        printf "%s\n" "$bad_rows" | while read -r r; do
            echo "       row $r has incorrect column count"
            echo "       Run: nina --index"
        done
    else
        ok "Index column structure valid"
    fi

    # -------------------------------------
    # Scan index once
    # -------------------------------------

    while IFS=$'\t' read -r file title author modified tags; do

        indexed_files["$file"]=1

        # Check indexed file exists
        if [[ ! -f "$file" ]]; then
            error "Indexed file missing: $file"
            ((missing_indexed_count++))
        fi

        [[ -z "$title" ]] && continue

        # Canonical title collisions
        canon=$(canonical_title "$title")
        [[ -z "$canon" ]] && continue

        if [[ -n "${seen_titles[$canon]}" ]]; then
            dup_titles["$canon"]=1
        else
            seen_titles["$canon"]=1
        fi

        # Slug collisions
        slug=$(generate_slug "$title")

        if [[ -n "${seen_slugs[$slug]}" ]]; then
            dup_slugs["$slug"]=1
        else
            seen_slugs["$slug"]=1
        fi

    done < "$INDEX_FILE"

    # -------------------------------------
    # Duplicate titles
    # -------------------------------------

    if (( ${#dup_titles[@]} > 0 )); then
        printf "%s\n" "${!dup_titles[@]}" | sort |
        while read -r d; do
            error "Duplicate title detected: $d"
        done
    else
        ok "No duplicate titles in index"
    fi

    # -------------------------------------
    # Slug collisions
    # -------------------------------------

    if (( ${#dup_slugs[@]} > 0 )); then
        printf "%s\n" "${!dup_slugs[@]}" | sort |
        while read -r s; do
            error "Slug collision detected: $s"
        done
    else
        ok "No slug collisions detected"
    fi

    # -------------------------------------
    # Unindexed files
    # -------------------------------------

    shopt -s nullglob
    for file in "$NINA_DIR"/*.md; do
        [[ -z "${indexed_files[$file]}" ]] && warn "Unindexed file: $file"
    done
    shopt -u nullglob

    # -------------------------------------
    # Index drift detection
    #
    # Drift has two forms: a file that still
    # exists but was modified after the index
    # was built, and a file that no longer
    # exists at all (already detected above,
    # in missing_indexed_count). The loop below
    # only iterates files that currently exist
    # on disk, so it can never see a deletion on
    # its own - missing_indexed_count has to be
    # added in explicitly, or a deleted article
    # would correctly trigger "Indexed file
    # missing" above and then be contradicted by
    # an "Index appears up to date" a few lines
    # later.
    # -------------------------------------

    index_mtime=$(stat_mtime "$INDEX_FILE")

    drift_count=0

    shopt -s nullglob
    for file in "$NINA_DIR"/*.md; do
        file_mtime=$(stat_mtime "$file")
        (( file_mtime > index_mtime )) && ((drift_count++))
    done
    shopt -u nullglob

    drift_count=$(( drift_count + missing_indexed_count ))

    if (( drift_count > 0 )); then
        warn "$drift_count article(s) modified or removed since last indexing"
        echo "       Run: nina --index"
    else
        ok "Index appears up to date"
    fi

else
    warn "Skipping index checks (no index file)"
fi

# ----------------------------------------
# Macro Integrity
# ----------------------------------------

print_section "Macro Integrity"

MACROS_DIR="${MACROS_DIR:-$HOME/.nina/macros}"
MANIFEST_FILE="$HOME/.nina/macros.tsv"

if [[ -d "$MACROS_DIR" ]]; then

    declare -A manifest_files
    declare -A manifest_names
    declare -A disk_first_file_for_name
    declare -A disk_dup_names
    declare -A disk_first_file_for_function
    declare -A disk_dup_functions
    declare -A all_funcs_first_file
    declare -A all_funcs_dup_files

    # -------------------------------------
    # Read the manifest, if any, skipping its
    # auto-generated header comment lines
    # -------------------------------------

    if [[ -f "$MANIFEST_FILE" ]]; then
        while IFS=$'\t' read -r m_name m_function m_file; do
            [[ -z "$m_name" || "$m_name" == \#* ]] && continue
            manifest_files["$m_file"]="$m_name"
            manifest_names["$m_name"]="$m_file"
        done < "$MANIFEST_FILE"
    fi

    # -------------------------------------
    # Independently re-validate every macro
    # file on disk. This does not trust the
    # manifest at all - a user troubleshooting
    # a macro that isn't working needs the
    # actual reason, not just "not installed".
    # -------------------------------------

    invalid_count=0

    shopt -s nullglob
    for file in "$MACROS_DIR"/*.awk; do

        # -------------------------------------
        # Function-name extraction runs against
        # every file that is at least valid AWK,
        # even if it fails the rest of
        # validate_macro_file's checks (bad name,
        # entry-point mismatch). A file can be
        # individually invalid today and still
        # contain a helper function that collides
        # with a working macro - if we only
        # scanned fully-valid files, fixing the
        # name error and re-running `nina --macro`
        # could surface a brand new collision
        # `--doctor` never warned about.
        # -------------------------------------

        if awk -f "$file" 'BEGIN { exit }' /dev/null 2>/dev/null; then
            while IFS= read -r func_name; do
                [[ -z "$func_name" ]] && continue

                if [[ -z "${all_funcs_first_file[$func_name]}" ]]; then
                    all_funcs_first_file["$func_name"]="$file"
                elif [[ "${all_funcs_first_file[$func_name]}" != "$file" ]]; then
                    all_funcs_dup_files["$func_name"]+="|$file"
                fi
            done < <(grep -oE '^function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$file" | awk '{print $2}')
        fi

        validation_result=$(validate_macro_file "$file")

        if [[ $? -ne 0 ]]; then
            error "Invalid macro file: $file ($validation_result)"
            ((invalid_count++))
            continue
        fi

        IFS=$'\t' read -r disk_name disk_function <<< "$validation_result"

        # Collision detection, independent of
        # whatever the manifest currently says
        if [[ -z "${disk_first_file_for_name[$disk_name]}" ]]; then
            disk_first_file_for_name["$disk_name"]="$file"
        else
            disk_dup_names["$disk_name"]+="|$file"
        fi

        if [[ -z "${disk_first_file_for_function[$disk_function]}" ]]; then
            disk_first_file_for_function["$disk_function"]="$file"
        else
            disk_dup_functions["$disk_function"]+="|$file"
        fi

        # -------------------------------------
        # Is this valid file actually installed?
        # A file can be valid on its own and still
        # be excluded from the manifest, if it
        # collided with another file the last time
        # `nina --macro` ran.
        # -------------------------------------

        if [[ -z "${manifest_files[$file]}" ]]; then
            warn "Valid but not installed: $file (run: nina --macro)"
        fi

    done
    shopt -u nullglob

    if (( invalid_count == 0 )); then
        ok "No invalid macro files found"
    fi

    # -------------------------------------
    # Collisions found on disk right now,
    # independent of the manifest
    # -------------------------------------

    if (( ${#disk_dup_names[@]} > 0 )); then
        for dname in "${!disk_dup_names[@]}"; do
            error "Duplicate macro name on disk: $dname"
            echo "       ${disk_first_file_for_name[$dname]}"
            IFS='|' read -ra dfiles <<< "${disk_dup_names[$dname]#|}"
            for df in "${dfiles[@]}"; do echo "       $df"; done
        done
    else
        ok "No duplicate macro names on disk"
    fi

    if (( ${#disk_dup_functions[@]} > 0 )); then
        for dfunc in "${!disk_dup_functions[@]}"; do
            error "Two macro files derive the same function name: $dfunc"
            echo "       ${disk_first_file_for_function[$dfunc]}"
            IFS='|' read -ra dffiles <<< "${disk_dup_functions[$dfunc]#|}"
            for df in "${dffiles[@]}"; do echo "       $df"; done
        done
    else
        ok "No function-name collisions on disk"
    fi

    # -------------------------------------
    # Any function name - including helper
    # functions, not just each macro's entry
    # point - defined in more than one valid
    # macro file. This will break every macro
    # currently loaded, not just the two files
    # involved, since AWK has one global
    # function namespace across every loaded
    # file.
    # -------------------------------------

    if (( ${#all_funcs_dup_files[@]} > 0 )); then
        for fname in "${!all_funcs_dup_files[@]}"; do
            error "Function '$fname' is defined in more than one macro file - this will break every macro, not just these:"
            echo "       ${all_funcs_first_file[$fname]}"
            IFS='|' read -ra ffiles <<< "${all_funcs_dup_files[$fname]#|}"
            for ff in "${ffiles[@]}"; do echo "       $ff"; done
        done
    else
        ok "No function name (including helpers) is defined in more than one macro file"
    fi

    # -------------------------------------
    # Manifest entries with no file on disk
    # (file deleted/renamed since last
    # `nina --macro` run)
    # -------------------------------------

    stale_count=0

    for m_file in "${!manifest_files[@]}"; do
        if [[ ! -f "$m_file" ]]; then
            warn "Manifest entry has no file on disk: $m_file (${manifest_files[$m_file]})"
            ((stale_count++))
        fi
    done

    if (( stale_count == 0 && ${#manifest_files[@]} > 0 )); then
        ok "Every manifest entry has a matching file on disk"
    fi

    # -------------------------------------
    # Macro drift detection - a manifest
    # entry whose source file has been
    # modified since the manifest was built
    # -------------------------------------

    if [[ -f "$MANIFEST_FILE" ]]; then

        manifest_mtime=$(stat_mtime "$MANIFEST_FILE")
        macro_drift_count=0

        for m_file in "${!manifest_files[@]}"; do
            [[ -f "$m_file" ]] || continue
            file_mtime=$(stat_mtime "$m_file")
            (( file_mtime > manifest_mtime )) && ((macro_drift_count++))
        done

        if (( macro_drift_count > 0 )); then
            warn "$macro_drift_count macro file(s) modified since last \`nina --macro\` run"
            echo "       Run: nina --macro"
        else
            ok "Macro manifest appears up to date"
        fi

    else
        warn "No macro manifest found (run: nina --macro)"
    fi

else
    warn "Skipping macro checks (MACROS_DIR not found: $MACROS_DIR)"
fi

# ----------------------------------------
# Plugin Health
#
# Deliberately NOT calling validate_plugin_file
# from nina-plugin.sh - this section reimplements
# the same checks independently, on purpose. The
# point isn't to avoid code reuse for its own
# sake; it's that this script's whole job is to
# check the system's own work, and a validator
# that only ever calls the thing it's supposed to
# be checking can't catch a mistake made in that
# one shared place. Some drift between the two
# copies over time is an accepted cost of that.
# ----------------------------------------

print_section "Plugin Health"

PLUGINS_DIR="${PLUGINS_DIR:-$HOME/.nina/plugins}"
PLUGINS_MANIFEST_FILE="$HOME/.nina/plugins.tsv"

# -------------------------------------
# Independent re-validation. Mirrors the four
# install-time rules in nina-plugin.sh's
# validate_plugin_file: a name-declaring first
# line, no system()/getline/redirected print or
# printf anywhere in the file, and the file must
# actually run cleanly (not just parse) inside a
# time limit. Prints a reason on failure, prints
# nothing on success - the caller decides what to
# do with a pass.
# -------------------------------------

doctor_validate_plugin_file() {
    local file="$1"
    local first_line raw_name name

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

    if ! timeout 5 awk -f "$SCRIPT_DIR/nina-plugin-api.awk" -f "$file" < /dev/null > /dev/null 2>/dev/null; then
        echo "syntax error, runtime error, or did not terminate"
        return 1
    fi

    printf '%s\n' "$name"
    return 0
}

# -------------------------------------
# Independent capability detection. Separate
# checks for web access and corpus ("file")
# access, on purpose - the installed manifest
# only tracks one merged "needs the long
# timeout" flag (true if either applies), since
# that's all the renderer needs at runtime. A
# health report is a different audience that
# wants to know which is which.
# -------------------------------------

doctor_uses_web() {
    grep -qE '(^|[^A-Za-z0-9_])plugin_http_get([^A-Za-z0-9_]|$)' "$1"
}

doctor_uses_file_access() {
    grep -qE '(^|[^A-Za-z0-9_])(plugin_call_nina|plugin_backlinks|plugin_tags|plugin_links|plugin_read_article|plugin_read_article_body)([^A-Za-z0-9_]|$)' "$1"
}

if [[ -d "$PLUGINS_DIR" ]]; then

    declare -A plugin_manifest_path   # name -> installed file path, from plugins.tsv
    declare -A plugin_first_file      # name -> first file on disk claiming this name
    declare -A plugin_dup_names
    declare -A plugin_dup_files

    if [[ -f "$PLUGINS_MANIFEST_FILE" ]]; then
        while IFS=$'\t' read -r m_name m_file m_long_timeout m_hash; do
            [[ -z "$m_name" || "$m_name" == \#* ]] && continue
            plugin_manifest_path["$m_name"]="$m_file"
        done < "$PLUGINS_MANIFEST_FILE"
    fi

    invalid_count=0
    valid_installed_count=0
    valid_not_installed_count=0
    web_count=0
    file_access_count=0

    declare -a web_files
    declare -a file_access_files

    shopt -s nullglob

    for file in "$PLUGINS_DIR"/*.awk; do

        validation_result=$(doctor_validate_plugin_file "$file")

        if [[ $? -ne 0 ]]; then
            error "Invalid plugin file: $file ($validation_result)"
            ((invalid_count++))
            continue
        fi

        name="$validation_result"

        if [[ -z "${plugin_first_file[$name]}" ]]; then
            plugin_first_file["$name"]="$file"
        else
            plugin_dup_names["$name"]=1
            plugin_dup_files["$name"]+="|$file"
        fi

        if [[ "${plugin_manifest_path[$name]}" == "$file" ]]; then
            ((valid_installed_count++))
        else
            warn "Valid but not installed: $file (run: nina --plugin)"
            ((valid_not_installed_count++))
        fi

        if doctor_uses_web "$file"; then
            web_files+=("$file")
            ((web_count++))
        fi

        if doctor_uses_file_access "$file"; then
            file_access_files+=("$file")
            ((file_access_count++))
        fi

    done

    shopt -u nullglob

    if (( invalid_count == 0 )); then
        ok "No invalid plugin files found"
    fi

    if (( valid_not_installed_count == 0 )); then
        ok "No valid-but-uninstalled plugin files found"
    fi

    echo
    echo "       In folder:"
    echo "         Valid and installed:     $valid_installed_count"
    echo "         Invalid:                 $invalid_count"
    echo "         Valid and not installed: $valid_not_installed_count"
    echo
    echo "       Installed and contain:"
    echo "         Web requests:  $web_count"
    if (( web_count > 0 )); then
        for f in "${web_files[@]}"; do
            echo "           - $f"
        done
    fi
    echo "         File requests: $file_access_count"
    if (( file_access_count > 0 )); then
        for f in "${file_access_files[@]}"; do
            echo "           - $f"
        done
    fi

    # -------------------------------------
    # Duplicate names on disk - same concern,
    # same shape, as the macro check above. No
    # function-name-collision equivalent is
    # needed for plugins: each one runs as its
    # own process, so there's no shared
    # namespace for two plugins to collide in.
    # -------------------------------------

    if (( ${#plugin_dup_names[@]} > 0 )); then
        mapfile -t dup_names_sorted < <(printf "%s\n" "${!plugin_dup_names[@]}" | LC_ALL=C sort)
        for dname in "${dup_names_sorted[@]}"; do
            error "Duplicate plugin name on disk: $dname"
            files="${plugin_dup_files[$dname]}"
            files="${files#|}"
            echo "         ${plugin_first_file[$dname]}"
            IFS='|' read -ra dflist <<< "$files"
            for f in "${dflist[@]}"; do
                echo "         $f"
            done
        done
    else
        ok "No duplicate plugin names on disk"
    fi

    # -------------------------------------
    # Drift - is the manifest possibly stale,
    # independent of whether any individual
    # file currently fails validation. Same
    # check, same shape, as the macro section.
    # -------------------------------------

    if [[ -f "$PLUGINS_MANIFEST_FILE" ]]; then

        manifest_mtime=$(stat_mtime "$PLUGINS_MANIFEST_FILE")
        plugin_drift_count=0

        for p_file in "${plugin_manifest_path[@]}"; do
            [[ -f "$p_file" ]] || continue
            file_mtime=$(stat_mtime "$p_file")
            (( file_mtime > manifest_mtime )) && ((plugin_drift_count++))
        done

        if (( plugin_drift_count > 0 )); then
            warn "$plugin_drift_count plugin file(s) modified since last \`nina --plugin\` run"
            echo "       Run: nina --plugin"
        else
            ok "Plugin manifest appears up to date"
        fi

    else
        warn "No plugin manifest found (run: nina --plugin)"
    fi

    # -------------------------------------
    # Config flag status and the helpful
    # messages that follow from it. These are
    # plain facts about current settings, not
    # findings - reported with info(), which
    # doesn't affect the OK/WARN/ERROR tally.
    # -------------------------------------

    echo
    echo "       Config:"
    echo "         ENABLE_PLUGINS:    ${ENABLE_PLUGINS:-false}"
    echo "         PLUGIN_PERMIT_WEB: ${PLUGIN_PERMIT_WEB:-false}"

    if [[ "${ENABLE_PLUGINS:-false}" != "true" ]]; then
        info "Plugin expansion is currently disabled (ENABLE_PLUGINS is not true) - <<...>> in your articles is left as literal text"
    fi

    if (( web_count > 0 )) && [[ "${PLUGIN_PERMIT_WEB:-false}" != "true" ]]; then
        info "Web requests are currently disabled by config (PLUGIN_PERMIT_WEB is not true) - $web_count installed plugin(s) that ask for it will get nothing back"
    fi

    if (( valid_not_installed_count > 0 )); then
        info "Run \`nina --plugin\` to install new plugins found in $PLUGINS_DIR"
    fi

else
    warn "Skipping plugin checks (PLUGINS_DIR not found: $PLUGINS_DIR)"
fi

# ----------------------------------------
# Article Validation
# ----------------------------------------

print_section "Article Validation"

shopt -s nullglob

for file in "$NINA_DIR"/*.md; do

    # Raw escape characters
    if grep -q $'\e' "$file"; then
        warn "ANSI escape sequence found in $file"
    fi

    header=$(read_header "$file")

    # Title validation
    title=$(header_field "$header" "Title")

    if [[ -z "$title" ]]; then
        warn "Missing title header in $file"
    fi

    title_count=$(printf '%s\n' "$header" | grep -c '^#')

    if (( title_count > 1 )); then
        warn "Multiple title headers in $file"
    fi

    # Date validation
    date=$(header_field "$header" "Date")

    if [[ -n "$date" ]] && ! valid_date "$date"; then
        warn "Invalid date format in $file ($date)"
    fi

done

shopt -u nullglob

ok "Article scan complete"

# ----------------------------------------
# Summary
# ----------------------------------------

echo
echo "---- Summary ----"
echo "OK:     $OK_COUNT"
echo "WARN:   $WARN_COUNT"
echo "ERROR:  $ERROR_COUNT"
echo "INFO:   $INFO_COUNT"

if (( ERROR_COUNT > 0 )); then
    exit 2
elif (( WARN_COUNT > 0 )); then
    exit 1
else
    exit 0
fi
