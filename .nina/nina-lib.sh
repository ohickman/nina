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
die()   {            printf "[ERROR] %s: %s\n" "$SCRIPT_NAME" "$*" >&2; exit 1; }
error() {            printf "[ERROR] %s: %s\n" "$SCRIPT_NAME" "$*" >&2; }
warn()  {            printf "[WARN]  %s: %s\n" "$SCRIPT_NAME" "$*" >&2; }
info()  { $IS_TTY && printf "[INFO]  %s\n" "$*"; }
ok()    { $IS_TTY && printf "[OK]    %s\n" "$*"; }

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
    printf '%s' "$stream" \
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
    # This rewrite does the same work inside a single awk process:
    # - reads index.tsv via getline in BEGIN
    # - reads each article file via getline (no tr/grep/sed subprocesses)
    # - performs all title normalization as pure awk string operations
    # - deduplicates output rows in-process (replacing the trailing
    #   awk '!seen[$0]++' pipeline stage)
    #
    # /dev/null is passed as awk's input file because all the real work
    # happens in BEGIN; awk needs at least one named input to start but
    # immediately gets EOF from /dev/null and exits cleanly.
    #
    # The variable `apos` (passed via -v) holds a plain ASCII apostrophe.
    # It is used as a gsub replacement for curly single quotes, because
    # a literal ' inside the awk '...' string would end the bash
    # single-quoted block prematurely.

    # The seven special-character variables below are the UTF-8 byte sequences
    # for the dash variants and curly quotes that canonical_title() normalizes.
    # They are passed via -v rather than embedded in the awk program string
    # because embedding multi-byte UTF-8 inside awk '...' causes them to be
    # silently corrupted by the editing pipeline. Using printf + octal escapes
    # in the shell generates the actual bytes, -v passes them to awk unchanged
    # (no awk escape processing applies to raw non-ASCII bytes), and the awk
    # program itself stays pure ASCII. `apos` (plain apostrophe) is handled the
    # same way to avoid ending the bash single-quoted awk program string.

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

    awk -v index_file="$INDEX_FILE" \
        -v alias_file="$alias_file" \
        -v apos="'"     \
        -v en_dash="$en_dash" \
        -v em_dash="$em_dash" \
        -v minus_s="$minus_s" \
        -v ldq="$ldq"   \
        -v rdq="$rdq"   \
        -v lsq="$lsq"   \
        -v rsq="$rsq"   \
        '

    # -----------------------------------------------
    # normalize_display(s)
    # Collapses runs of whitespace to a single space
    # and strips leading/trailing whitespace.
    # Equivalent to normalize_display_title() in nina-lib.sh.
    # -----------------------------------------------
    function normalize_display(s) {
        gsub(/[[:space:]]+/, " ", s)
        sub(/^ /,            "",  s)
        sub(/ $/,            "",  s)
        return s
    }

    # -----------------------------------------------
    # canonicalize(s)
    # Produces the canonical comparison form of a title:
    # normalized whitespace, dash variants collapsed to
    # ASCII hyphen, curly quotes straightened, lowercased.
    # Equivalent to canonical_title() in nina-lib.sh.
    #
    # Special characters are used as dynamic gsub patterns
    # (string variables, not regex literals) - since none
    # of their bytes are ASCII regex metacharacters they
    # match literally, same as if they were regex literals.
    # -----------------------------------------------
    function canonicalize(s) {
        s = normalize_display(s)
        gsub(en_dash, "-", s)    # en-dash    U+2013
        gsub(em_dash, "-", s)    # em-dash    U+2014
        gsub(minus_s, "-", s)    # minus sign U+2212
        gsub(ldq,  "\"", s)      # left double quote  U+201C
        gsub(rdq,  "\"", s)      # right double quote U+201D
        gsub(lsq,  apos, s)      # left single quote  U+2018
        gsub(rsq,  apos, s)      # right single quote U+2019
        return tolower(s)
    }

    # -----------------------------------------------
    # strip_delim(line, delim)
    # Removes paired inline code spans (`` or `) from
    # a line so that [[links]] written inside code spans
    # are not extracted as real links.
    # Identical logic to strip_delim() inside
    # strip_code_for_link_scan() in nina-lib.sh.
    # -----------------------------------------------
    function strip_delim(line, delim,
                         dlen, start, search_from, close_pos, result, p) {
        dlen   = length(delim)
        result = ""
        while (1) {
            start = index(line, delim)
            if (start == 0) break
            search_from = start + dlen
            close_pos   = 0
            while (1) {
                p = index(substr(line, search_from), delim)
                if (p == 0) break
                p = search_from + p - 1
                if (p == start + dlen) {
                    # Adjacent delimiter pair - empty span, skip past it
                    search_from = p + dlen
                    continue
                }
                close_pos = p
                break
            }
            if (close_pos == 0) break
            result = result substr(line, 1, start - 1)
            line   = substr(line, close_pos + dlen)
        }
        return result line
    }

    # -----------------------------------------------
    # process_line(line, src_display, src_canon)
    # Scans one article line for [[...]] links after
    # code spans have already been stripped, and prints
    # one tab-separated output row per unique link:
    #   source_display TAB source_canon TAB target_display TAB target_canon
    # Deduplication is done here rather than in a
    # separate downstream awk pass.
    # -----------------------------------------------
    function process_line(line, src_display, src_canon,
                          pos, open_idx, close_idx, content,
                          pipe_pos, tgt_raw, tgt_display, tgt_canon, key) {
        pos = 1
        while (1) {
            # Locate the next [[ on the line
            open_idx = index(substr(line, pos), "[[")
            if (open_idx == 0) break
            open_idx = pos + open_idx - 1

            # Locate the matching ]]
            close_idx = index(substr(line, open_idx + 2), "]]")
            if (close_idx == 0) break
            close_idx = open_idx + 2 + close_idx - 1

            # Everything between [[ and ]]
            content = substr(line, open_idx + 2, close_idx - (open_idx + 2))

            # [[Display Text|Target Title]] - target is after the pipe
            # [[Target Title]]              - target is the whole content
            pipe_pos = index(content, "|")
            if (pipe_pos > 0)
                tgt_raw = substr(content, pipe_pos + 1)
            else
                tgt_raw = content

            tgt_display = normalize_display(tgt_raw)
            tgt_canon   = canonicalize(tgt_display)

            # De-alias: a link whose target is an alias resolves
            # to the real article it names, so backlinks, dangling,
            # orphan and graph all see the true target rather than
            # the alias. A real title is never a key in this map,
            # so ordinary titles pass through untouched. The map is
            # empty when aliases are off, making this a no-op.
            if (tgt_canon in alias2title) {
                tgt_display = alias2title[tgt_canon]
                tgt_canon   = canonicalize(tgt_display)
            }

            if (tgt_display != "") {
                key = src_display "\t" src_canon "\t" tgt_display "\t" tgt_canon
                if (!seen[key]++)
                    print key
            }

            # Advance the cursor past this link before searching for the next
            pos = close_idx + 2
        }
    }

    BEGIN {

        # Load the alias -> real-title map, keyed by the alias
        # canonical form. Empty alias_file (aliases off or index
        # absent) skips this, leaving alias2title empty so the
        # de-alias step in process_line never fires.
        if (alias_file != "") {
            while ((getline a_line < alias_file) > 0) {
                split(a_line, acol, "\t")
                a_canon = canonicalize(acol[1])
                if (a_canon != "")
                    alias2title[a_canon] = normalize_display(acol[2])
            }
            close(alias_file)
        }

        while ((getline idx_line < index_file) > 0) {

            # Index columns: file TAB title TAB author TAB date TAB tags
            split(idx_line, cols, "\t")
            file        = cols[1]
            src_display = normalize_display(cols[2])
            src_canon   = canonicalize(src_display)

            # Read and process each line of this article file
            while ((getline art_line < file) > 0) {
                gsub(/\r/, "", art_line)          # strip Windows CR
                if (art_line ~ /^```/) continue   # skip full code-block lines
                art_line = strip_delim(art_line, "``")  # strip ``double`` spans
                art_line = strip_delim(art_line, "`")   # strip `single` spans
                process_line(art_line, src_display, src_canon)
            }
            close(file)
        }
        close(index_file)
    }

    ' /dev/null
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
# nina-link-list, ...).
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

# -----------------------------------------
# Interoperability helpers for BSD and iOS
# -----------------------------------------

