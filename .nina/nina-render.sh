#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

FILE="$1"
[[ -z "$FILE" ]] && die "No file provided to renderer."

# -----------------------------------------
# Detect terminal width
# -----------------------------------------

if command -v tput >/dev/null 2>&1; then
    TERM_WIDTH=$(tput cols 2>/dev/null)
fi

if [[ -z "$TERM_WIDTH" || "$TERM_WIDTH" -le 0 ]]; then
    TERM_WIDTH=80
fi

# -----------------------------------------
# Detect color capability
# -----------------------------------------

if [[ "$COLORTERM" == *"truecolor"* ]]; then
    COLOR_DEPTH=24
elif [[ "$TERM" == *"256color"* ]]; then
    COLOR_DEPTH=256
else
    COLOR_DEPTH=16
fi

# -----------------------------------------
# Date/time for {{date}}/{{time}}-style
# macros - computed once here rather than
# once per line.
# -----------------------------------------

TODAY=$(date +%Y-%m-%d)
NOW=$(date +%H:%M:%S)

# -----------------------------------------
# Macro support (optional)
#
# If ENABLE_MACROS is false, or the macro
# manifest doesn't exist or is empty, macros
# are skipped entirely - nina-macros.awk's
# expand_macros() is still loaded (it's cheap,
# generic plumbing), but with no macro files
# and a fallback dispatch_macro, every {{...}}
# in an article is simply left as literal
# text, same as any other unrecognized macro.
#
# The dispatch chain itself (name -> function
# lookup) is generated once by `nina --macro`
# (nina-macros.sh), not regenerated here on
# every render call - this file only reads
# the manifest to know which macro .awk files
# to load, and loads the pre-built dispatch
# file alongside them.
# -----------------------------------------

MANIFEST_FILE="$HOME/.nina/macros.tsv"
DISPATCH_FILE="$HOME/.nina/macros-dispatch.awk"
FALLBACK_DISPATCH=""

MACRO_AWK_FILES=()

if [[ "$ENABLE_MACROS" == "true" && -s "$MANIFEST_FILE" && -s "$DISPATCH_FILE" ]]; then

    while IFS=$'\t' read -r macro_name macro_function macro_file; do
        [[ -z "$macro_name" || "$macro_name" == \#* ]] && continue
        MACRO_AWK_FILES+=("$macro_file")
    done < "$MANIFEST_FILE"

    ACTIVE_DISPATCH_FILE="$DISPATCH_FILE"

else

    # No usable manifest/dispatch file (macros
    # disabled, never ingested, or empty) - a
    # dispatch_macro() must still exist, since
    # expand_macros() always calls it.
    FALLBACK_DISPATCH=$(make_temp_file)
    printf 'function dispatch_macro(name, args) { return "\001UNKNOWN\001" }\n' > "$FALLBACK_DISPATCH"
    ACTIVE_DISPATCH_FILE="$FALLBACK_DISPATCH"

fi

# Build a proper, separately-quoted -f <file>
# pair per macro file (a string substitution
# like ${arr[@]/#/-f} would glue "-f" directly
# onto the path with no space, which awk can't
# parse as a flag).
MACRO_F_FLAGS=()
for macro_file in "${MACRO_AWK_FILES[@]}"; do
    MACRO_F_FLAGS+=("-f" "$macro_file")
done

# -----------------------------------------
# Plugin support (optional)
#
# Plugins are <<name args>> calls, expanded
# in their own pre-pass before nina-render.awk
# and macro expansion ever see the line - see
# nina-plugins.awk for why this has to be a
# distinct, earlier stage than {{}} expansion
# (a plugin needs the whole document and the
# rest of the corpus available to it; a macro
# only ever sees the one line it was called on).
#
# Disabled by default (ENABLE_PLUGINS unset or
# false): nina-plugins.awk is simply never
# loaded, so every <<...>> in an article is left
# untouched as literal text, same graceful-
# degradation behavior as an unrecognized macro.
# -----------------------------------------

ENABLE_PLUGINS="${ENABLE_PLUGINS:-false}"
PLUGINS_MANIFEST_FILE="$HOME/.nina/plugins.tsv"
PLUGIN_API_FILE="$SCRIPT_DIR/nina-plugin-api.awk"
PLUGIN_HELPER_FILE="$SCRIPT_DIR/nina-plugin-helper.sh"

PLUGIN_PERMIT_WEB="${PLUGIN_PERMIT_WEB:-false}"
PLUGIN_TIMEOUT="${PLUGIN_TIMEOUT:-5}"
PLUGIN_NO_WEB_TIMEOUT="${PLUGIN_NO_WEB_TIMEOUT:-0.5}"
PLUGIN_MAX_OUTPUT_BYTES="${PLUGIN_MAX_OUTPUT_BYTES:-65536}"
PLUGIN_MAX_MEMORY_KB="${PLUGIN_MAX_MEMORY_KB:-262144}"

# CURRENT_FILE / CURRENT_TITLE are made available to every
# plugin (via nina-plugin-api.awk's plugin_current_file()/
# plugin_current_title(), and as the stdin source for the
# plugin's own subprocess) the same way the rest of nina
# already resolves an article's title from its header.

CURRENT_FILE="$FILE"
CURRENT_TITLE="$(normalize_display_title "$(header_field "$(read_header "$FILE")" Title)")"

# -----------------------------------------
# Invoke AWK renderer
# -----------------------------------------

# -----------------------------------------
# Two separate awk processes, not one combined
# invocation - this is required, not stylistic.
#
# A plugin's multi-line output gets spliced into
# $0 as a single string with embedded newlines.
# If plugin expansion and rendering shared one
# process the way they used to, that string would
# still be exactly one input record as far as
# nina-render.awk's per-record, ^-anchored rules
# (headers, bullets, etc.) are concerned - ^ only
# matches the true start of the whole string, not
# the start of each embedded line, so only the
# first line of a plugin's output would ever get
# styled. Piping plugin expansion's output into a
# fresh awk invocation forces every embedded line
# to be re-read as its own genuine record, which is
# what lets each one be styled independently again -
# the same as if a person had typed each line
# directly into the article.
#
# When plugins are disabled, PLUGIN_PASS is just
# `cat` - a single, uniform pipeline shape either
# way, at the cost of one negligible extra process.
# -----------------------------------------

if [[ "$ENABLE_PLUGINS" == "true" && -s "$PLUGINS_MANIFEST_FILE" ]]; then
    PLUGIN_PASS=(
        awk
        -v PLUGINS_MANIFEST="$PLUGINS_MANIFEST_FILE"
        -v API_FILE="$PLUGIN_API_FILE"
        -v NINA_PLUGIN_HELPER="$PLUGIN_HELPER_FILE"
        -v PLUGIN_PERMIT_WEB="$PLUGIN_PERMIT_WEB"
        -v PLUGIN_TIMEOUT="$PLUGIN_TIMEOUT"
        -v PLUGIN_NO_WEB_TIMEOUT="$PLUGIN_NO_WEB_TIMEOUT"
        -v PLUGIN_MAX_OUTPUT_BYTES="$PLUGIN_MAX_OUTPUT_BYTES"
        -v PLUGIN_MAX_MEMORY_KB="$PLUGIN_MAX_MEMORY_KB"
        -v CURRENT_FILE="$CURRENT_FILE"
        -v CURRENT_TITLE="$CURRENT_TITLE"
        -v TODAY="$TODAY"
        -v NOW="$NOW"
        -v TERM_WIDTH="$TERM_WIDTH"
        -f "$SCRIPT_DIR/nina-plugins.awk"
    )
else
    PLUGIN_PASS=(cat)
fi

tr -d '\r' < "$FILE" | "${PLUGIN_PASS[@]}" | awk \
-v COLOR_DEPTH="$COLOR_DEPTH" \
-v TERM_WIDTH="$TERM_WIDTH" \
-v ENABLE_LINE_NUMBERS="$ENABLE_LINE_NUMBERS" \
-v LINE_NUMBER_STYLE="$LINE_NUMBER_STYLE" \
-v LINE_NUMBER_SEPARATOR="$LINE_NUMBER_SEPARATOR" \
-v RESET="$RESET" \
-v H1_STYLE="$H1_STYLE" \
-v H2_STYLE="$H2_STYLE" \
-v H3_STYLE="$H3_STYLE" \
-v H4_STYLE="$H4_STYLE" \
-v H5_STYLE="$H5_STYLE" \
-v H6_STYLE="$H6_STYLE" \
-v SUBTITLE_STYLE="$SUBTITLE_STYLE" \
-v BULLET_SYMBOL="$BULLET_SYMBOL" \
-v TODO_SYMBOL="$TODO_SYMBOL" \
-v DONE_SYMBOL="$DONE_SYMBOL" \
-v TODO_DONE_STYLE="$TODO_DONE_STYLE" \
-v BLOCK_QUOTE_SYMBOL="$BLOCK_QUOTE_SYMBOL" \
-v BLOCK_QUOTE_STYLE="$BLOCK_QUOTE_STYLE" \
-v INSERT_STYLE="$INSERT_STYLE" \
-v DELETE_STYLE="$DELETE_STYLE" \
-v ITEM_STYLE="$ITEM_STYLE" \
-v DEFINITION_STYLE="$DEFINITION_STYLE" \
-v BOLD_STYLE="$BOLD_STYLE" \
-v ITALIC_STYLE="$ITALIC_STYLE" \
-v UNDERLINE_STYLE="$UNDERLINE_STYLE" \
-v CODE_STYLE="$CODE_STYLE" \
-v LINK_STYLE="$LINK_STYLE" \
-v HIGHLIGHT_STYLE="$HIGHLIGHT_STYLE" \
-v STRIKEOUT_STYLE="$STRIKEOUT_STYLE" \
-v INFO_STYLE="$INFO_STYLE" \
-v NOTE_STYLE="$NOTE_STYLE" \
-v TIP_STYLE="$TIP_STYLE" \
-v TODO_STYLE="$TODO_STYLE" \
-v FIXME_STYLE="$FIXME_STYLE" \
-v WARNING_STYLE="$WARNING_STYLE" \
-v HR_SYMBOL="$HR_SYMBOL" \
-v HR_STYLE="$HR_STYLE" \
-v TODAY="$TODAY" \
-v NOW="$NOW" \
-f "$SCRIPT_DIR/nina-render.awk" \
-f "$SCRIPT_DIR/nina-macros.awk" \
-f "$ACTIVE_DISPATCH_FILE" \
"${MACRO_F_FLAGS[@]}" \
-f "$SCRIPT_DIR/nina-entities.awk"

RENDER_STATUS=$?

# Only the fallback dispatch is a temp file -
# the real dispatch file is persistent, built
# once by `nina --macro`, and must not be
# deleted here.
[[ -n "$FALLBACK_DISPATCH" ]] && rm -f "$FALLBACK_DISPATCH"

exit $RENDER_STATUS
