#!/usr/bin/env bash
# =====================================================
# nina-lib.sh
#
# Shared library for the nina command suite.
#
# This file defines:
#   - system utilities
#   - configuration loading
#   - canonical title rules
#   - metadata parsing
#   - link extraction
#
# All scripts rely on these functions to ensure
# consistent interpretation of the knowledge base.
# =====================================================

# -----------------------------------------
# Script directory (absolute path)
# -----------------------------------------

NINA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###########################################
#             SYSTEM UTILITIES            #
###########################################
# -----------------------------------------
# Create temporary file safely
# Returns path to new temp file
# -----------------------------------------

make_temp_file() {
    mktemp 2>/dev/null || mktemp -t nina_tmp
}

# -----------------------------------------
# Error helpers
# -----------------------------------------
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"
IS_TTY=false
[[ -t 1 ]] && IS_TTY=true
# _nina_tagged_line TAG MESSAGE
# Single source of truth for the "[TAG]   message" column
# alignment used across every status helper below. Tag is
# left-padded to 7 columns plus one separating space, so
# "[ERROR]" (7 chars) and "[OK]" (4 chars) both land their
# message text in the same column. Exposed (not "_"-private
# in practice) so callers with their own display/counting
# needs - e.g. nina-doctor, which tallies OK/WARN/ERROR/INFO
# counts and must always print regardless of $IS_TTY - can
# reuse the exact same formatting instead of re-deriving it.
_nina_tagged_line() { printf "%-7s %s\n" "$1" "$2"; }

die()   {            _nina_tagged_line "[ERROR]" "$SCRIPT_NAME: $*" >&2; exit 1; }
error() {            _nina_tagged_line "[ERROR]" "$SCRIPT_NAME: $*" >&2; }
warn()  {            _nina_tagged_line "[WARN]"  "$SCRIPT_NAME: $*" >&2; }
info()  { $IS_TTY && _nina_tagged_line "[INFO]"  "$*"; }
ok()    { $IS_TTY && _nina_tagged_line "[OK]"    "$*"; }
run()   { $IS_TTY && _nina_tagged_line "[RUN]"   "$*"; }

# detail [--level N] MESSAGE
# Indented continuation/detail line meant to sit under a
# preceding tagged message (ok/warn/error/info/run) - e.g. a
# file path, a suggested follow-up command, or a sub-item in
# a summary list. Indentation is derived from the same 8-column
# width _nina_tagged_line uses for the "[TAG]   " prefix, so a
# detail line always lines up under the tag's message text
# without any caller having to hand-count spaces (and without
# drifting if that width ever changes). Level 1 (default) is
# that base alignment; each additional level nests 2 spaces
# further, for a sub-item under a sub-item.
detail() {
    local level=1
    if [[ "$1" == "--level" ]]; then
        level="$2"
        shift 2
    fi
    local indent=$(( 8 + (level - 1) * 2 ))
    printf "%*s%s\n" "$indent" "" "$*"
}

###########################################
#              CONFIGURATION              #
###########################################
# -----------------------------------------
# Load configuration file
# -----------------------------------------

load_config() {
    local config_file="$HOME/.nina/config"

    if [[ -f "$config_file" ]]; then
        # shellcheck disable=SC1090
        source "$config_file"
    else
        error "Config file not found: $config_file" >&2
        info "Try running 'nina --config' to repair."        
        exit 1
    fi

    # The alias index lives beside the main index. Default it
    # here, once, so every consumer (the indexer that writes it,
    # alias_lookup and scan_links that read it) shares one
    # definition and an older config that predates the setting
    # still resolves to the right path.
    : "${ALIAS_INDEX_FILE:=${INDEX_FILE%/*}/index-alias.tsv}"
}

###########################################
#              IDENTITY RULES             #
###########################################
# -----------------------------------------
# Normalize title (preserve case)
# - collapse whitespace
# - trim ends
# -----------------------------------------

normalize_display_title() {
    printf '%s' "$1" \
        | sed 's/[[:space:]]\+/ /g' \
        | sed 's/^ //; s/ $//'
}

# -----------------------------------------
# Canonical title (for comparison only)
# - collapse whitespace
# - trim ends
# - normalize dash variants
# - normalize smart quotes
# - case fold
#
# Two call forms, same single implementation:
#   canonical_title "$title"   - normalize one title given as an argument
#   ... | canonical_title      - normalize a stream of titles, one per line
#                                 (e.g. a whole index.tsv title column)
# Both forms run the exact same sed/tr pipeline; the stream form exists so
# every place that needs to compare many titles at once (find_article_file,
# suggest_titles) can canonicalize the whole column in a single pass rather
# than re-deriving canonicalization rules inline, or re-forking this
# pipeline once per row.
# -----------------------------------------

canonical_title() {
    local stream
    if [[ $# -gt 0 ]]; then
        stream="$1"
    else
        stream="$(cat)"
    fi

    # The dash/quote substitutions below intentionally use a chain of
    # single-character substitutions instead of one sed bracket expression
    # (e.g. 's/[–—−]/-/g'). Under a non-UTF-8 (POSIX/C) locale, sed treats
    # a bracket expression's contents as individual locale-defined
    # "collating elements" - in the C locale, that means individual bytes -
    # so a multi-byte UTF-8 character placed inside [...] gets silently
    # exploded into several single-byte match targets instead of being
    # matched as one character, corrupting the text instead of normalizing
    # it. A literal multi-byte character used outside a bracket expression
    # is still matched as a contiguous byte sequence regardless of locale,
    # which is why this form is safe everywhere the bracket form was not.
    # $(cat) above strips every trailing newline from piped stream
    # input, and this pipeline never adds one back - so the stream
    # form's last output line was never newline-terminated. Harmless
    # to every current caller that reads the result via $(...)
    # (command substitution strips trailing newlines anyway, single-
    # argument callers use exactly one), but a genuine bug for a
    # `while read` loop consuming the stream form directly: bash's
    # `read` returns non-zero on a final line with no trailing
    # newline, which ends the loop *before* running its body for
    # that line, silently dropping the corpus's last title. Restoring
    # the newline is guarded on non-empty input so genuinely empty
    # input still produces empty output, unchanged from today - $(cat)
    # can't distinguish "no lines" from "only a trailing newline", and
    # this isn't the place to resolve that.
    if [[ -n "$stream" ]]; then
        printf '%s\n' "$stream"
    fi \
        | sed 's/[[:space:]]\+/ /g' \
        | sed 's/^ //; s/ $//' \
        | sed 's/–/-/g; s/—/-/g; s/−/-/g' \
        | sed 's/“/"/g; s/”/"/g' \
        | sed "s/‘/'/g; s/’/'/g" \
        | tr '[:upper:]' '[:lower:]'
}

# -----------------------------------------
# Generate slug (UTF-8 safe)
# - normalized
# - spaces → underscore
# - remove forward slash
# - illegal/reserved filesystem characters → hyphen
#   (preserves a "stronger break" artifact, since these
#   characters are often used as a harder separator than
#   a plain space)
# - control characters stripped (no word-break meaning)
# - trims leading/trailing separators left behind by the above
# - reserved Windows device names (CON, AUX, NUL, COM1-9,
#   LPT1-9) get a disambiguation suffix, since these names
#   can't be created at all on Windows/exFAT regardless of
#   content
# - truncated to leave room for a disambiguation suffix (see
#   add_disambiguation_suffix), cut on a UTF-8 character
#   boundary so the result stays valid UTF-8
# -----------------------------------------

generate_slug() {
    local slug

    slug=$(canonical_title "$1" \
        | tr ' ' '_' \
        | tr -d '\000-\037' \
        | sed 's#[/\\:*?"<>|]#-#g' \
        | sed 's/[_-]*-[_-]*/-/g' \
        | sed 's/_\+/_/g' \
        | sed 's/^[_-]\+//; s/[_-]\+$//')

    # Truncate to 237 bytes, then back off until valid UTF-8
    slug=$(printf '%s' "$slug" | head -c 237)
    while [[ -n "$slug" ]] && ! printf '%s' "$slug" | iconv -f utf-8 -t utf-8 >/dev/null 2>&1; do
        slug="${slug%?}"
    done

    # Disambiguate reserved Windows device names
    case "$(printf '%s' "$slug" | tr '[:lower:]' '[:upper:]')" in
        CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])
            slug="$(add_disambiguation_suffix "$slug")" #" (quote hack for Mousepad syntax highlighting)
            ;;
    esac

    printf '%s' "$slug"
}

# -----------------------------------------
# Append a disambiguation suffix to a slug
# or filename stem.
#
# Uses "--" as the separator, since a run of
# hyphens (or mixed hyphen/underscore) always
# collapses to a single "-" in generate_slug -
# meaning "--" can never occur in a slug
# derived from a title. This makes "--" a safe,
# unambiguous, reserved marker: anything after
# the LAST "--" in a filename is a disambiguation
# suffix, not user title content.
#
# Input: a slug/stem
# Output: "<stem>--<timestamp>"
# -----------------------------------------

add_disambiguation_suffix() {
    printf '%s--%s' "$1" "$(date +%Y%m%d%H%M%S)"
}

# -----------------------------------------
# Strip a disambiguation suffix (if present)
# from a slug or filename stem, by removing
# everything from the last "--" onward.
#
# Input: a slug/stem, possibly suffixed
# Output: the stem with any suffix removed
# -----------------------------------------

strip_disambiguation_suffix() {
    printf '%s' "$1" | sed -E 's/--[0-9]{14}$//'
}

###########################################
#         PLUGIN SOURCE HANDLING          #
###########################################
# -----------------------------------------
# Join backslash-newline line continuations
# so a plugin's security checks (in
# nina-plugin.sh and nina-doctor.sh) see AWK's
# logical lines, not its physical lines.
#
# AWK honors backslash-newline continuation,
# so `print "x" \` followed by `> "file"` on
# the next physical line is one logical
# statement. A line-at-a-time grep check for
# banned print/printf redirection can be
# blind to this: the print token and the
# redirect operator end up on different
# physical lines even though AWK executes
# them as one. Both validators must scan the
# joined form to close this gap - kept here,
# once, so a future fix to the joining logic
# itself only has to happen in one place.
#
# Input: a plugin source file path
# Output: the file's content with backslash-
#         newline continuations joined
# -----------------------------------------

plugin_source_logical_lines() {
    sed ':a;/\\$/{N;s/\\\n//;ta}' "$1"
}

###########################################
#            ARTICLE METADATA             #
###########################################
# -----------------------------------------
# Extract article header block from MD
# -----------------------------------------

read_header() {
    awk '
        { sub(/\r$/, "") } # Fix CRLF on windows files
        NR==1 && /^[[:space:]]*$/ { next }
        NR==1 && !/^#/ { exit }
        /^[[:space:]]*$/ { exit }
        { print }
    ' "$1"
}

# -----------------------------------------
# Extract specific field from header
# -----------------------------------------

header_field() {

    local header="$1"
    local field="$2"

    if [[ "$field" == "Title" ]]; then
        printf '%s\n' "$header" |
        grep -m1 '^#' |
        sed 's/^# *//'
    else
        printf '%s\n' "$header" |
        grep -m1 "^- $field:" |
        sed "s/^- $field:[[:space:]]*//"
    fi
}

# -----------------------------------------
# Extract specific field from header
# -----------------------------------------

canonical_tag() {
    printf '%s' "$1" \
        | tr 'A-Z' 'a-z' \
        | tr -s ' ' \
        | sed 's/^ *//; s/ *$//'
}

###########################################
###########################################
#              LINK HANDLING              #
###########################################
# -----------------------------------------
# Strip code from a stream before link
# scanning. This is a one-way drop, not a
# protect-and-restore: the stripped stream is
# only ever used to search for links and is
# never written back out or rendered, so
# there is no placeholder/restoration step.
#
# - Full-line code (a line starting with
#   ```): the whole line is dropped. This
#   matches nina-render.awk's own model -
#   there is no multi-line fence state here
#   either; each ``` line stands alone, and a
#   conventional-looking multi-line block is
#   just several such lines in a row.
# - Single- and double-backtick inline spans:
#   dropped per line, using literal substring
#   search (not regex) so a stray backtick
#   inside the span doesn't break the match -
#   same technique used for inline styling in
#   nina-render.awk.
#
# Input: a stream (stdin)
# Output: the stream with all code removed
# -----------------------------------------

strip_code_for_link_scan() {
    awk '
    /^```/ { next }

    {
        line = $0
        line = strip_delim(line, "``")
        line = strip_delim(line, "`")
        print line
    }

    function strip_delim(line, delim,    dlen, start, search_from, close_pos, result, p) {
        dlen = length(delim)
        result = ""

        while (1) {
            start = index(line, delim)
            if (start == 0) break

            search_from = start + dlen
            close_pos = 0

            while (1) {
                p = index(substr(line, search_from), delim)
                if (p == 0) break
                p = search_from + p - 1

                if (p == start + dlen) {
                    search_from = p + dlen
                    continue
                }

                close_pos = p
                break
            }

            if (close_pos == 0) break

            result = result substr(line, 1, start - 1)
            line = substr(line, close_pos + dlen)
        }

        return result line
    }
    '
}

# -----------------------------------------
# Read internal links, interpret target
# [[display text|Target Title]]
#
# Code (fenced blocks and inline spans) is
# stripped before searching, so a link
# written inside code is not treated as a
# real link. See strip_code_for_link_scan.
# -----------------------------------------

extract_links() {
    tr -d '\r' < "$1" |
    strip_code_for_link_scan |
    grep -o '\[\[[^]]\+\]\]' |
    sed 's/\[\[\(.*\)\]\]/\1/'
}

# -----------------------------------------
# Resolve link target
# Supports [[target]] and [[text|target]]
# -----------------------------------------

link_target() {
    local link="$1"

    if [[ "$link" == *"|"* ]]; then
        printf '%s\n' "${link#*|}"
    else
        printf '%s\n' "$link"
    fi
}

# -----------------------------------------
# Read inks, output source title, canonical and target canonical
# -----------------------------------------

scan_links() {

    [[ -f "$INDEX_FILE" ]] || die "Index file not found."

    # The previous implementation ran a bash loop over every index row and
    # forked several subprocesses per article (normalize_display_title,
    # canonical_title, extract_links = tr + awk + grep + sed) and more
    # per link found (link_target, normalize_display_title, canonical_title).
    # On a ~1000-article corpus that is thousands of forks and ~20 seconds
    # per call; anything that calls scan_links twice (e.g. nina --stats)
    # paid that cost twice.
    #
    # The actual link-scanning logic lives in nina-scan-links.awk (a single
    # awk process: reads index.tsv and every article file via getline, does
    # all title normalization as pure awk string operations, and deduplicates
    # output rows in-process). This function's job is just to compute the
    # inputs that logic needs and hand them off via -v.

    # The seven special-character variables below are the UTF-8 byte sequences
    # for the dash variants and curly quotes that canonical_title() normalizes.
    # They are passed via -v rather than embedded as literals in the awk file
    # because embedding multi-byte UTF-8 directly in an awk program can be
    # silently corrupted by editing pipelines. Using printf + octal escapes
    # in the shell generates the actual bytes, -v passes them to awk unchanged
    # (no awk escape processing applies to raw non-ASCII bytes). `apos` (plain
    # apostrophe) is passed the same way for consistency, and is used as a
    # gsub replacement for curly single quotes.

    local en_dash em_dash minus_s ldq rdq lsq rsq
    en_dash=$(printf '\342\200\223')   # U+2013 –
    em_dash=$(printf '\342\200\224')   # U+2014 —
    minus_s=$(printf '\342\210\222')   # U+2212 −
    ldq=$(printf '\342\200\234')       # U+201C "
    rdq=$(printf '\342\200\235')       # U+201D "
    lsq=$(printf '\342\200\230')       # U+2018 '
    rsq=$(printf '\342\200\231')       # U+2019 '

    # The alias index (alias TAB title), passed to awk so link
    # targets that are aliases can be rewritten to the real title
    # they resolve to (see process_line). Left empty - and thus
    # skipped entirely - when aliases are disabled or the file is
    # absent, so scan_links output is unchanged with aliases off.
    local alias_file=""
    [[ "$ENABLE_ALIASES" == true && -f "$ALIAS_INDEX_FILE" ]] && alias_file="$ALIAS_INDEX_FILE"

    awk -f "$NINA_LIB_DIR/nina-scan-links.awk" \
        -v index_file="$INDEX_FILE" \
        -v alias_file="$alias_file" \
        -v apos="'"     \
        -v en_dash="$en_dash" \
        -v em_dash="$em_dash" \
        -v minus_s="$minus_s" \
        -v ldq="$ldq"   \
        -v rdq="$rdq"   \
        -v lsq="$lsq"   \
        -v rsq="$rsq"   \
        /dev/null
}

# -----------------------------------------
# Deduplicate a stream of display titles
#
# Keeps the first occurrence of each title,
# comparing by canonical_title() rather than
# the literal display text - so two links
# that point to the same article but differ
# only by capitalization, whitespace, a dash
# variant, or a smart-quote variant are
# recognized as duplicates instead of both
# being kept.
#
# This replaced three near-identical inline
# `awk '!seen[tolower($0)]++'` call sites
# (nina-link-list.sh, nina-plugin-helper.sh,
# nina-read.sh) that each only folded case,
# missing the same dash/quote normalization
# gap found in find_article_file and
# suggest_titles. One shared implementation
# means the next such call site reuses this
# instead of writing a fourth copy.
#
# Input: a stream of display titles, one per line
# Output: the same titles, first occurrence of
#         each canonical form, original order
#         preserved
# -----------------------------------------

dedup_titles() {
    local line canon
    declare -A seen

    while IFS= read -r line; do
        canon="$(canonical_title "$line")"
        if [[ -z "${seen[$canon]:-}" ]]; then
            seen["$canon"]=1
            printf '%s\n' "$line"
        fi
    done
}

###########################################
#          GRAPH OUTPUT (--dot)           #
###########################################
# -----------------------------------------
# Shared helpers behind every command's --dot mode. See
# [[Nina - Devs: Graph Output Standard (--dot)]] for the full contract
# these implement - node/edge styling, penwidth scaling, and
# escaping all live here once so a --dot mode never invents its
# own answer to "how do I draw this". DOT_* config variables
# (DOT_PENWIDTH_MIN/MAX/SCALE, DOT_NODE_SHAPE, DOT_NODE_STYLE,
# DOT_FONTNAME, DOT_FONTSIZE, DOT_RANKDIR, DOT_SHOW_EDGE_LABELS,
# DOT_PROBLEM_NODE_COLOR) are loaded by load_config from the
# GRAPH OUTPUT block in ~/.nina/config.
# -----------------------------------------

# dot_comment TEXT
# Prints a single "// TEXT" line - DOT's real comment syntax,
# not the "#"-prefixed line-discard form (that one exists for
# C-preprocessor line markers, not as documented comment
# syntax). Every --dot mode calls this exactly once, before
# dot_graph_open, to emit the mandatory self-describing header
# naming the command that produced the output - required even
# on a graph with zero edges, same reasoning as the --tsv
# header being required on zero rows.
dot_comment() {
    printf '// %s\n' "$1"
}

# dot_escape TEXT
# Escapes backslashes and double quotes so TEXT is safe inside
# a quoted Graphviz label or node ID ('\' -> '\\', '"' -> '\"').
# Every node name and every label that isn't a bare number must
# go through this before being printed.
dot_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# dot_weight STRENGTH
# Maps a raw strength value (a link count, a co-occurrence
# count, a --similar score) onto a Graphviz penwidth via:
#     penwidth = min(DOT_PENWIDTH_MAX, DOT_PENWIDTH_MIN + STRENGTH / DOT_PENWIDTH_SCALE)
# so a heavily-weighted edge is visually heavier without one
# outlier making every other edge in the same graph look like a
# hairline by comparison. Accepts a float (a --similar score)
# as readily as an integer (a link count).
dot_weight() {
    awk -v s="$1" -v min="$DOT_PENWIDTH_MIN" -v max="$DOT_PENWIDTH_MAX" -v scale="$DOT_PENWIDTH_SCALE" \
        'BEGIN { w = min + s/scale; if (w > max) w = max; printf "%.1f", w }'
}

# dot_graph_open NAME DIRECTED
# Prints the opening line and shared graph-level attributes.
# DIRECTED is "true" or "false" and picks digraph (->) vs graph
# (--) - see "Graph Direction and Rankdir" in the standard doc:
# directed for a relationship with a real direction (article A
# links to B), undirected for an inherently symmetric one
# (co-occurring tags, mutual similarity). Call dot_comment
# first, separately - this function does not print the header
# comment itself.
dot_graph_open() {
    local name="$1" directed="$2"
    if [[ "$directed" == true ]]; then
        echo "digraph $name {"
    else
        echo "graph $name {"
    fi
    echo "    rankdir=$DOT_RANKDIR;"
    echo "    node [shape=$DOT_NODE_SHAPE, style=$DOT_NODE_STYLE, fontname=\"$DOT_FONTNAME\", fontsize=$DOT_FONTSIZE];"
    echo
}

# dot_graph_close
# Just "}" - exists mainly so every command closes the same way
# and a future change (a trailing comment, say) has one place
# to happen.
dot_graph_close() {
    echo "}"
}

# dot_edge FROM TO STRENGTH DIRECTED [LABEL]
# The workhorse. Escapes both endpoints, computes the penwidth
# via dot_weight, and prints one edge line. LABEL defaults to
# STRENGTH itself; pass an explicit LABEL when the raw strength
# isn't what should be displayed (e.g. a --similar score
# rounded to two decimals while the underlying value has more
# precision). Respects DOT_SHOW_EDGE_LABELS.
dot_edge() {
    local from="$1" to="$2" strength="$3" directed="$4" label="${5:-$3}"
    local arrow="->"; [[ "$directed" != true ]] && arrow="--"
    local ef et w
    ef="$(dot_escape "$from")"
    et="$(dot_escape "$to")"
    w="$(dot_weight "$strength")"
    if [[ "$DOT_SHOW_EDGE_LABELS" == true ]]; then
        printf '    "%s" %s "%s" [label="%s", penwidth=%s];\n' "$ef" "$arrow" "$et" "$label" "$w"
    else
        printf '    "%s" %s "%s" [penwidth=%s];\n' "$ef" "$arrow" "$et" "$w"
    fi
}

# dot_node NAME [EXTRA_ATTRS]
# Prints a standalone node declaration, with optional extra
# Graphviz attributes appended verbatim (used by the
# problem-node modes - --orphan, --dangling - to add
# fillcolor). A plain relationship graph never needs to call
# this: nodes that appear in an edge are declared implicitly by
# Graphviz itself.
dot_node() {
    local name="$1" extra="${2:-}"
    printf '    "%s"%s;\n' "$(dot_escape "$name")" "${extra:+ [$extra]}"
}

###########################################
#            NAVIGATION HELPERS           #
###########################################

open_article_menu() {
    local titles=("$@")

    [[ -t 0 && -t 1 ]] || return 0

    echo
    read -r -p "Open article number (Enter to exit): " choice

    [[ -z "$choice" ]] && return 0

    if [[ "$choice" =~ ^[0-9]+$ ]] &&
       (( choice >= 1 && choice <= ${#titles[@]} )); then
        exec "$NINA_LIB_DIR/nina" "${titles[$((choice-1))]}"
    else
        warn "Invalid selection."
    fi
}

# -----------------------------------------
# Print a simple numbered list: one
# " [N] value" line per argument, N starting
# at 1.
#
# This is the flat bracketed-index list style
# used by the relationship/link commands
# (backlinks, orphan, link-list, read, ...)
# that show a plain list of titles rather than
# the full --list table, and it is exactly the
# format the open_article_menu prompt reads
# back - so the two are almost always used as a
# pair. It was previously an identical
# `for i in "${!arr[@]}"; do printf ...; done`
# loop copy-pasted into each of those scripts;
# this is the single implementation they share,
# the same consolidation already done for the
# table renderer and the open-by-number menu.
#
# Callers pass the already-final display
# strings as positional arguments. This
# function only formats - it does not sort,
# deduplicate, or resolve anything.
# -----------------------------------------

print_numbered_list() {
    local i=1 item
    for item in "$@"; do
        printf ' [%d] %s\n' "$i" "$item"
        i=$((i + 1))
    done
}

# -----------------------------------------
# Require an interactive terminal, or die.
#
# For scripts whose confirmation prompts
# exist specifically to gate a destructive
# action (archiving/deleting an article,
# rewriting an article's content, renaming a
# file) - not for scripts whose prompts are
# pure menus/disambiguation with no
# destructive failure mode, or whose actions
# are purely additive or already collision-
# safe (creating, restoring without a
# collision). Those don't need this guard;
# see nina-new.sh and nina-restore.sh.
#
# A user can always operate on their files
# directly (mv, rm, an editor) - this guard
# only refuses to perform a destructive
# action *unconfirmed*, it never blocks
# access to the underlying data.
# -----------------------------------------

require_interactive() {
    [[ -t 0 && -t 1 ]] && return 0
    die "This command requires an interactive terminal and cannot run non-interactively."
}

###########################################
#              OTHER HELPERS              #
###########################################
# -----------------------------------------
# Trim string for fixed-width display
# Adds ellipsis if truncated
# -----------------------------------------

trim_string() {

    local text="$1"
    local width="${2:-30}"

    if (( ${#text} <= width )); then
        printf "%s" "$text"
    else
        printf "%s…" "${text:0:width-1}"
    fi
}

###########################################
#            TABLE RENDERING              #
###########################################
# -----------------------------------------
# Shared article-list table renderer.
#
# Nina lists articles in several places
# (--list, --tag, --date, --search). They all
# print the same style of table: a header row,
# a separator row of dashes, then one
# "[   N] title  modified  tags" row per
# article, with an interactive open-by-number
# menu at the end.
#
# This used to be copy-pasted printf blocks in
# every one of those scripts, with the column
# widths and dash strings duplicated by hand -
# exactly the kind of "same thing implemented
# in four places, free to silently drift"
# situation the project tries to avoid. These
# three functions are the single implementation
# they now all share.
#
# The table is data-driven: the caller declares
# the columns once with table_begin, then calls
# table_header once and table_row per article.
# Adding a new column in the future is a matter
# of adding one "name width" pair to the
# table_begin call - no printf strings to edit.
#
# The very first column is always the bracketed
# row index ("[   N]"). That style is fixed on
# purpose: every list in nina uses it, it's part
# of the tool's visual identity, and the
# interactive open-by-number menu depends on it.
# Callers do NOT pass a value for it - table_row
# generates it from the index argument.
#
# Usage:
#   table_begin "#" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
#   table_header
#   table_row 1 "Some Title" "2026-01-01" "tag1 tag2"
#   table_row 2 ...
#
# A column width of 0 means "flexible": the
# column is neither padded nor trimmed. Use it
# for the last column (typically tags) so it can
# run to whatever length it needs.
# -----------------------------------------

# Column state, set by table_begin and read by
# table_header / table_row. Underscore-prefixed
# because these are internal shared state, not
# a public part of the interface.
_NINA_TABLE_HEADERS=()
_NINA_TABLE_WIDTHS=()

# table_begin NAME WIDTH [NAME WIDTH ...]
# Declare the table's columns. Arguments come in
# name/width pairs. The first pair is the index
# column (its NAME is the header text shown above
# the "[   N]" cells, conventionally "#").
table_begin() {
    _NINA_TABLE_HEADERS=()
    _NINA_TABLE_WIDTHS=()
    while (( $# >= 2 )); do
        _NINA_TABLE_HEADERS+=("$1")
        _NINA_TABLE_WIDTHS+=("$2")
        shift 2
    done
}

# Internal: build a printf format string from the
# declared column widths. A width of 0 becomes a
# bare %s (no padding); any other width N becomes
# %-Ns (left-justified, padded).
_table_format() {
    local fmt="" w
    for w in "${_NINA_TABLE_WIDTHS[@]}"; do
        if (( w == 0 )); then
            fmt+="%s "
        else
            fmt+="%-${w}s "
        fi
    done
    printf '%s' "${fmt% }"
}

# table_header
# Print the header row and the dashed separator
# row, both sized to the declared columns.
table_header() {
    local fmt
    fmt="$(_table_format)"

    # Header text row.
    # shellcheck disable=SC2059
    printf "$fmt\n" "${_NINA_TABLE_HEADERS[@]}"

    # Separator row: a run of dashes per column,
    # each sized to that column's width. A flexible
    # (width 0) column gets a fixed 16-dash bar so
    # the separator still shows up under it.
    local seps=() w bar j dashcount
    for w in "${_NINA_TABLE_WIDTHS[@]}"; do
        dashcount=$w
        (( w == 0 )) && dashcount=16
        bar=""
        for (( j=0; j<dashcount; j++ )); do
            bar+="-"
        done
        seps+=("$bar")
    done
    # shellcheck disable=SC2059
    printf "$fmt\n" "${seps[@]}"
}

# table_row INDEX CELL [CELL ...]
# Print one data row. INDEX is the row number,
# rendered as the fixed "[   N]" first column.
# The remaining CELL arguments fill the other
# columns in order; each is trimmed to its
# declared width (a width-0 column is left as-is).
table_row() {
    local idx="$1"; shift

    # The bracketed index cell, padded to the first
    # column's declared width.
    local first_w="${_NINA_TABLE_WIDTHS[0]}"
    local index_cell
    printf -v index_cell "[%4d]" "$idx"

    # Trim each remaining cell to its column width.
    # Column 0 is the index (handled above), so the
    # cells map to widths starting at index 1.
    local cells=() i=1 val w
    for val in "$@"; do
        w="${_NINA_TABLE_WIDTHS[$i]}"
        if (( w == 0 )); then
            cells+=("$val")
        else
            cells+=("$(trim_string "$val" "$w")")
        fi
        ((i++))
    done

    # Format string for the non-index columns only.
    local fmt_rest="" first=true
    for w in "${_NINA_TABLE_WIDTHS[@]}"; do
        if $first; then first=false; continue; fi
        if (( w == 0 )); then
            fmt_rest+="%s "
        else
            fmt_rest+="%-${w}s "
        fi
    done
    fmt_rest="${fmt_rest% }"

    # shellcheck disable=SC2059
    printf "%-${first_w}s $fmt_rest\n" "$index_cell" "${cells[@]}"
}

# -----------------------------------------
# Suggest similar article titles
#
# Performs simple substring matching
# against canonical titles in the index.
#
# Canonicalizes the index's title column
# through canonical_title() (stream form),
# the same function used to build the query
# itself - see find_article_file for why this
# matters: a hand-written partial copy of the
# same rules here previously missed the
# dash/quote normalization step, so titles
# differing only by a dash or quote variant
# silently never appeared as a suggestion.
#
# Input: title query
# Output: matching titles
# -----------------------------------------

suggest_titles() {

    local query="$1"
    local canonical_query
    canonical_query="$(canonical_title "$query")"

    [[ -f "$INDEX_FILE" ]] || return 1

    paste <(cut -d $'\t' -f2 "$INDEX_FILE") \
          <(cut -d $'\t' -f2 "$INDEX_FILE" | canonical_title) |
    awk -F'\t' -v q="$canonical_query" '
    {
        title=$1
        canon=$2

        if (index(canon,q) || index(q,canon))
            print title
    }
    ' | sort -f | head -5
}

# -----------------------------------------
# Light-weight date recognition, validation
# -----------------------------------------

valid_date() {
    local date="$1"
    [[ "$date" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]
}

###########################################
#            MACRO VALIDATION             #
###########################################
# -----------------------------------------
# Validate a single macro file and derive
# its name and entry-point function name.
#
# Shared by `nina --macro` (which builds the
# macro manifest from this) and `nina --doctor`
# (which re-validates every macro file against
# the real directory, independent of whatever
# the manifest currently says, so a user
# troubleshooting "my macro isn't working" gets
# the actual reason rather than just "not
# installed").
#
# A macro file must:
#   1. Parse as valid AWK.
#   2. Have a first line that is a comment;
#      everything after "#", trimmed, is the
#      macro's name. The name must be non-empty
#      and contain neither whitespace nor "}".
#   3. Define a function named macro_<X>, where
#      <X> is the filename (without .awk)
#      with every character that isn't a
#      letter, digit, or underscore replaced
#      with an underscore. This function name
#      is derived from the filename, not
#      declared in the file, so it is
#      guaranteed unique without the file's
#      author needing to coordinate with anyone.
#
# Input: path to a macro file
# Output (stdout):
#   On success: "<name>\t<function_name>", exit 0
#   On failure: a human-readable rejection
#               reason, exit 1
# -----------------------------------------

validate_macro_file() {
    local file="$1"
    local first_line raw_name name stem function_name

    if ! awk -f "$file" 'BEGIN { exit }' /dev/null 2>/dev/null; then
        echo "syntax error"
        return 1
    fi

    first_line=$(head -n 1 "$file")

    if [[ "$first_line" != \#* ]]; then
        echo "first line is not a comment declaring the macro name"
        return 1
    fi

    raw_name="${first_line#\#}"
    name=$(printf '%s' "$raw_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [[ -z "$name" ]]; then
        echo "missing or empty macro name"
        return 1
    fi

    if [[ "$name" == *[[:space:]]* ]]; then
        echo "macro name contains whitespace: '$name'"
        return 1
    fi

    if [[ "$name" == *"}"* ]]; then
        echo "macro name contains '}': '$name'"
        return 1
    fi

    stem=$(basename "$file" .awk)
    function_name="macro_$(printf '%s' "$stem" | sed 's/[^A-Za-z0-9_]/_/g')"

    if ! grep -q "^function[[:space:]]\+$function_name[[:space:]]*(" "$file"; then
        echo "expected function '$function_name' (derived from filename) not found in file"
        return 1
    fi

    printf '%s\t%s\n' "$name" "$function_name"
    return 0
}

###########################################
#              INDEX HELPERS              #
###########################################

# -----------------------------------------
# Index accessors
#
# The index is a tab-separated table with one
# row per article and a fixed column order:
#
#   file  title  author  date  tags
#
# where the tags column is itself a comma-
# separated list. These accessors are the one
# place that encodes those facts. Every other
# script should read the index THROUGH them,
# by meaning (titles, dates, tags, rows) rather
# than by hand-written column numbers, so that
# a future change to the index layout is a
# change to this section alone.
#
# They are stream-oriented on purpose: each
# emits its result down a pipe in a single pass,
# so routing through the library is no more
# expensive than an inline cut/awk - there is no
# performance reason to reimplement a read
# inline. Callers do their own aggregation
# (sort, uniq -c, filtering) on the stream.
#
# Each returns non-zero and emits nothing when
# the index is absent; a caller that wants a
# hard error should call require_index first.
# -----------------------------------------

# Die with the standard message when the index
# is missing. Replaces the copy of this guard
# duplicated at the top of most command scripts.
require_index() {
    [[ -f "$INDEX_FILE" ]] || die "Index file not found. Run: nina --index"
}

# Reindex, but only if the config opts in. Replaces the
# copy of this AUTO_REINDEX check duplicated at the end
# of most command scripts that mutate an article. Relies
# on SCRIPT_DIR being set by the caller, as it already is
# everywhere this runs.
request_index() {
    if [[ "$AUTO_REINDEX" == "true" ]]; then
        nohup "$SCRIPT_DIR/nina" --index >/dev/null &
        disown
    fi
}

# Raw rows, verbatim, columns in schema order.
# The entry point for callers that genuinely need
# more than one column together (iterate with
# `while IFS=$'\t' read -r file title author date tags`).
# Single-column callers should prefer the named
# accessors below rather than re-deriving a column.
index_rows() {
    [[ -f "$INDEX_FILE" ]] || return 1
    cat "$INDEX_FILE"
}

# All article titles, one per line, in index order.
index_titles() {
    [[ -f "$INDEX_FILE" ]] || return 1
    cut -d $'\t' -f2 "$INDEX_FILE"
}

# All article dates (ISO 8601), one per line, in index order.
index_dates() {
    [[ -f "$INDEX_FILE" ]] || return 1
    cut -d $'\t' -f4 "$INDEX_FILE"
}

# Every tag occurrence, one per line, in index order with
# duplicates preserved - so a caller can count frequency with
# `index_tags | sort | uniq -c`, or take the distinct set with
# `index_tags | sort -u`. This is the only place that knows
# tags live in column 5 and are comma-delimited; no caller
# should split a tags field itself. Empty tokens are skipped.
index_tags() {
    [[ -f "$INDEX_FILE" ]] || return 1
    awk -F'\t' '
    {
        n = split($5, t, ",")
        for (i = 1; i <= n; i++)
            if (t[i] != "")
                print t[i]
    }' "$INDEX_FILE"
}

# All article authors, one per line, in index order.
# Emitted verbatim, including empty values for articles with
# no author; a caller wanting distinct non-empty authors uses
# `index_authors | grep -v '^$' | sort -u`.
index_authors() {
    [[ -f "$INDEX_FILE" ]] || return 1
    cut -d $'\t' -f3 "$INDEX_FILE"
}

# Display-table rows: "title TAB date TAB tags", one per
# article, sorted case-insensitively by title, with the tags
# field rendered space-separated for a table cell. This is the
# shared read behind the interactive listing table (nina --list
# and the nina --remove picker); it owns the column selection,
# the display sort, and the tag formatting so those callers hold
# no index-column knowledge of their own.
index_display_rows() {
    [[ -f "$INDEX_FILE" ]] || return 1
    awk -F'\t' '
    {
        tags = $5
        gsub(/,/, " ", tags)
        printf "%s\t%s\t%s\n", $2, $4, tags
    }' "$INDEX_FILE" |
    sort -f -t $'\t' -k1,1
}

# -----------------------------------------
# Resolve canonical article title to file path
#
# Performs case-insensitive lookup using the
# same canonicalization rules used by the
# indexer. Returns the first matching file
# path from index.tsv or nothing if not found.
#
# The index's title column is normalized
# through canonical_title() (stream form) -
# the exact same function used to build the
# search term itself - rather than a second,
# hand-written partial copy of the same rules.
# Two near-identical normalization
# implementations that can silently drift
# apart (one missing the dash/quote rules) was
# the root cause of a real bug here; routing
# both sides through one function closes that
# entire class of drift, not just this instance.
#
# Input: canonical title
# Output: article file path
# -----------------------------------------

find_article_file() {
    local canonical="$1"

    [[ -f "$INDEX_FILE" ]] || return 1

    paste <(cut -d $'\t' -f1 "$INDEX_FILE") \
          <(cut -d $'\t' -f2 "$INDEX_FILE" | canonical_title) |
    awk -F'\t' -v target="$canonical" '$2 == target { print $1 }'
}

# -----------------------------------------
# Resolve an alias to its real title.
#
# This is the single reader of the alias index
# (index-alias.tsv, "alias<TAB>title" rows, built
# by nina-index.sh when ENABLE_ALIASES is on).
# Given a canonical input, it prints the display
# title the alias points to, or nothing.
#
# It is the ONLY place that knows the alias index's
# location and format - every consumer resolves
# aliases through this function rather than reading
# the file directly, so that knowledge lives in one
# spot. Alias resolution is deliberately a fallback:
# a caller looks up the main index first and only
# consults this on a miss, so a real title always
# outranks an alias for free (see nina-view.sh).
#
# Returns non-zero and prints nothing when aliases
# are disabled or the index is absent, so callers
# degrade cleanly to title-only resolution.
# -----------------------------------------

alias_lookup() {
    local canonical="$1"

    [[ "$ENABLE_ALIASES" == true ]] || return 1
    [[ -f "$ALIAS_INDEX_FILE" ]] || return 1

    # Columns: alias TAB title. Canonicalize the alias column
    # at query time (mirroring find_article_file) and emit the
    # stored display title of the first match.
    paste <(cut -d $'\t' -f1 "$ALIAS_INDEX_FILE" | canonical_title) \
          <(cut -d $'\t' -f2 "$ALIAS_INDEX_FILE") |
    awk -F'\t' -v target="$canonical" '$1 == target { print $2; exit }'
}

# -----------------------------------------
# All alias names, one per line, in alias-index
# order. The enumeration counterpart to
# alias_lookup() - that function resolves one
# known alias to its title; this one lists every
# alias that exists, for callers like completion
# that need to offer candidates rather than
# resolve a specific query.
#
# Returns non-zero and prints nothing when
# aliases are disabled or the index is absent,
# so callers degrade cleanly to titles only.
# -----------------------------------------

alias_titles() {
    [[ "$ENABLE_ALIASES" == true ]] || return 1
    [[ -f "$ALIAS_INDEX_FILE" ]] || return 1

    cut -d $'\t' -f1 "$ALIAS_INDEX_FILE"
}




# -----------------------------------------
# Resolve a canonical input to an article file,
# alias-aware. The shared entry point for the
# read-only "open this" paths (nina-view,
# nina-link-list, nina-tree, nina-similar).
#
# The main index is consulted first and a hit is
# returned immediately, so a real title always
# outranks an alias. Only on a miss is the alias
# index consulted, resolving alias -> real title
# and then looking that title up in the main index.
# Prints the file path, or nothing (and returns
# non-zero) when neither a title nor an alias matches.
#
# Note this is deliberately NOT what the mutating
# commands (new/remove/repair/restore) or the strict
# scripting primitive (nina --file-name) use - those
# resolve by real title only, via find_article_file.
# -----------------------------------------

resolve_article_file() {
    local canonical="$1"
    local file resolved

    file="$(find_article_file "$canonical")"
    if [[ -n "$file" ]]; then
        printf '%s\n' "$file"
        return 0
    fi

    resolved="$(alias_lookup "$canonical")" || return 1
    [[ -n "$resolved" ]] || return 1

    find_article_file "$(canonical_title "$resolved")"
}

# -----------------------------------------
# De-alias a canonical query to the canonical form
# of the real article it identifies.
#
# Returns the input unchanged when it is already a
# real title (main index wins) or matches nothing;
# returns the alias's target canonical when it is an
# alias. This is the query-side counterpart to the
# target de-aliasing scan_links does: commands that
# match a user-supplied title against scan_links
# output (nina --backlinks, the plugin --backlinks
# verb) run their query through here first so an
# alias query lines up with the de-aliased targets.
# A no-op when aliases are disabled.
# -----------------------------------------

dealias_canonical() {
    local canonical="$1" resolved

    # A real title always wins - leave it untouched.
    [[ -n "$(find_article_file "$canonical")" ]] && { printf '%s\n' "$canonical"; return 0; }

    resolved="$(alias_lookup "$canonical")"
    if [[ -n "$resolved" ]]; then
        canonical_title "$resolved"
    else
        printf '%s\n' "$canonical"
    fi
}

###########################################
#     ANCHOR / DEEP-LINK RESOLUTION       #
###########################################
#
# A "Title#Anchor" string - a scanned [[link]] target, or a
# user-typed `nina "Title#Anchor"` query - cannot be split on
# sight: canonical_title() places no restriction on '#', so a
# real title may legitimately contain one (e.g. "C# Tricks").
# The only reliable signal is whether a candidate resolves
# against the real index, so every consumer that supports
# anchors walks backward through each '#' in the string, from
# none removed to all of them, testing the growing prefix each
# time and stopping at the first (and therefore longest) match.
# The whole string is always tried first, unsplit, so a title
# that legitimately contains '#' always wins outright over any
# anchor interpretation.
#
# This exact walk is needed by nina-view (resolving what the
# user typed), nina-dangling, nina-backlinks, nina-orphan, and
# nina-graph (each resolving a scanned link's target against
# the corpus). The two functions below are the single shared
# implementation of that walk; no caller should re-derive it.

# -----------------------------------------
# Always-empty associative array, used as
# resolve_split_target()'s default alias map so
# a caller with no alias map to offer can omit
# the argument entirely rather than having to
# declare and pass an empty array of its own.
# -----------------------------------------
declare -gA _NINA_EMPTY_MAP=()

# -----------------------------------------
# build_title_maps <title_map_name> [<alias_map_name>]
#
# Populates the caller's associative arrays (passed by name -
# bash nameref, so the caller must `declare -A` them first)
# with the corpus-wide lookups every anchor-splitting consumer
# previously rebuilt independently:
#
#   title_map_name[canonical title]  = display title
#   alias_map_name[canonical alias]  = canonical form of the
#                                       real title it resolves to
#
# title_map_name is built through canonical_title's stream
# form - one pass over the whole title column, rather than one
# fork per title - matching the efficiency canonical_title's
# own header comment recommends for exactly this situation.
#
# alias_map_name is optional; omit it for a caller that only
# ever needs real titles. When given, it costs one forking
# alias_lookup() call per alias (the corpus typically has few),
# and degrades to leaving the map untouched when aliases are
# disabled or the alias index is absent - alias_titles() itself
# already prints nothing in that case, so the loop body simply
# never runs.
# -----------------------------------------
build_title_maps() {
    local -n _btm_title_map="$1"
    local _alias_map_name="${2:-}"

    local canonical title
    while IFS=$'\t' read -r canonical title; do
        _btm_title_map["$canonical"]="$title"
    done < <(paste <(index_titles | canonical_title) <(index_titles))

    [[ -n "$_alias_map_name" ]] || return 0

    local -n _btm_alias_map="$_alias_map_name"
    local alias_name alias_canon real_title
    while IFS= read -r alias_name; do
        alias_canon="$(canonical_title "$alias_name")"
        real_title="$(alias_lookup "$alias_canon")"
        [[ -n "$real_title" ]] && _btm_alias_map["$alias_canon"]="$(canonical_title "$real_title")"
    done < <(alias_titles)
}

# -----------------------------------------
# resolve_split_target <raw> <raw_canon> <title_map_name> [<alias_map_name>]
#
# The shared backward-walk described above. <raw> is the full
# "Title" or "Title#Anchor" string as typed or scanned,
# verbatim. <raw_canon> is its own whole-string canonical form -
# scan_links already computes this for a scanned link
# (target_canon); a fresh `canonical_title "$raw"` call supplies
# it for a typed query - passed in rather than recomputed here
# so the zero-split common case costs no extra fork. title_map_name
# and alias_map_name are arrays already populated by
# build_title_maps(); alias_map_name may be omitted, in which
# case only real titles are considered.
#
# Deliberately reports its result through global variables
# rather than printing, and must therefore be called directly -
# `resolve_split_target ...` - never wrapped in a command
# substitution like `x="$(resolve_split_target ...)"`. Command
# substitution forks a subshell in bash even when the function
# body itself forks nothing, which would reintroduce, once per
# call, exactly the per-link forking cost this function exists
# to eliminate for its hot-loop callers (nina-dangling,
# nina-backlinks, nina-orphan, nina-graph all call this once per
# link in a corpus-wide scan). Every lookup in the walk is a
# plain in-memory array access - nothing here forks at all
# except canonical_title() on each further candidate once a '#'
# split is actually being tried, exactly the cost the original
# per-script implementations already paid.
#
# On success, sets the following and returns 0:
#   NINA_SPLIT_CANON   - the real article's own canonical form
#                         (never an alias's)
#   NINA_SPLIT_DISPLAY - the real article's display title
#   NINA_SPLIT_PREFIX  - the exact substring of <raw> that
#                         resolved, verbatim casing, before
#                         canonicalization. nina-view uses this
#                         to carry the user's original typing
#                         forward into resolve_article_file
#                         rather than losing case here.
#   NINA_SPLIT_ANCHOR  - the trailing text after
#                         NINA_SPLIT_PREFIX, empty when the
#                         whole input matched unsplit (the
#                         common case)
#
# On failure - no prefix of <raw> resolves at all, against
# either map - all four are left empty and the function returns
# 1. These are transient output, valid only until the next call;
# a caller in a loop must consume them before calling again.
# -----------------------------------------
resolve_split_target() {
    local raw="$1" raw_canon="$2" _title_map_name="$3" _alias_map_name="${4:-_NINA_EMPTY_MAP}"
    local -n _rst_title_map="$_title_map_name"
    local -n _rst_alias_map="$_alias_map_name"

    local remaining="$raw" remaining_canon="$raw_canon"
    local anchor="" last_part alias_target

    NINA_SPLIT_CANON=""
    NINA_SPLIT_DISPLAY=""
    NINA_SPLIT_PREFIX=""
    NINA_SPLIT_ANCHOR=""

    while true; do

        if [[ -n "${_rst_title_map[$remaining_canon]:-}" ]]; then
            NINA_SPLIT_CANON="$remaining_canon"
            NINA_SPLIT_DISPLAY="${_rst_title_map[$remaining_canon]}"
            NINA_SPLIT_PREFIX="$remaining"
            NINA_SPLIT_ANCHOR="$anchor"
            return 0
        fi

        if [[ -n "${_rst_alias_map[$remaining_canon]:-}" ]]; then
            alias_target="${_rst_alias_map[$remaining_canon]}"
            NINA_SPLIT_CANON="$alias_target"
            NINA_SPLIT_DISPLAY="${_rst_title_map[$alias_target]:-}"
            NINA_SPLIT_PREFIX="$remaining"
            NINA_SPLIT_ANCHOR="$anchor"
            return 0
        fi

        [[ "$remaining" == *"#"* ]] || break

        last_part="${remaining##*#}"
        if [[ -z "$anchor" ]]; then
            anchor="$last_part"
        else
            anchor="${last_part}#${anchor}"
        fi
        remaining="${remaining%#*}"
        remaining_canon="$(canonical_title "$remaining")"

    done

    return 1
}

# -----------------------------------------
# Interoperability helpers for BSD and iOS
#
# GNU stat (Linux) and BSD stat (macOS/iOS)
# take completely different flags, and there
# is no single invocation that works
# unmodified on both. Probe once here, at
# library load time, rather than per-call,
# and expose stat_mtime()/stat_date()
# wrappers so callers never see the platform
# difference.
# -----------------------------------------

if stat -c '%Y' . >/dev/null 2>&1; then
    _NINA_STAT_GNU=true
else
    _NINA_STAT_GNU=false
fi

# stat_mtime FILE
# Prints the file's modification time as a
# Unix epoch integer, suitable for numeric
# comparisons (e.g. drift checks in --doctor).
stat_mtime() {
    if [[ "$_NINA_STAT_GNU" == true ]]; then
        stat -c '%Y' "$1" 2>/dev/null
    else
        stat -f '%m' "$1" 2>/dev/null
    fi
}

# stat_date FILE
# Prints the file's modification time as
# YYYY-MM-DD, matching the format valid_date()
# expects (used as a fallback "Date" field
# when indexing an article with none set).
stat_date() {
    if [[ "$_NINA_STAT_GNU" == true ]]; then
        stat -c '%y' "$1" 2>/dev/null | cut -d' ' -f1
    else
        stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null
    fi
}

