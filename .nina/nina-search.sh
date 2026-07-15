#!/usr/bin/env bash

# =====================================================
# nina-search.sh - full-text fuzzy search
#
# Searches the titles AND body text of every indexed
# article and ranks results by relevance.
#
# This replaced an earlier title-only literal search.
# Instead of a plain substring match, it scans article
# contents and scores each article using
# proximity-weighted matching:
#
#   - all query words on one line score high
#   - words close together score higher than words
#     far apart (character gap between them)
#   - words separated by sentence terminators (.!?)
#     are penalized - they're probably not the phrase
#     you meant
#   - matches in a title or header outrank matches in
#     body text
#
# This is the one place in nina that deliberately
# relaxes strict literal determinism in favor of
# ranked relevance. It is still fully deterministic
# (same query + same corpus = same ranking every
# time); it just isn't a literal substring match.
#
# It is a standalone script with no index changes and
# no new derived files. If it doesn't suit you, it can
# be replaced with a simpler search with no other
# knock-on effects.
#
# Usage:
#   nina --search <query words>
#   nina --search <query words> --count
#   nina --search <query words> --explain
#   nina --search <query words> --tsv
#   nina -s <query words>
# =====================================================

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# =====================================================
# SCORING WEIGHTS
#
# All ranking behavior is controlled by these knobs.
# Tweak freely - none of them change *which* articles
# match (that's decided by whether the query words
# appear at all), only how matches are *ranked*.
#
# The scoring function that consumes these lives in a
# single awk function (score_line, below) and can be
# swapped out wholesale without touching anything else
# in this script.
# =====================================================

# Base score for a line containing ALL query words.
FTS_ALL_WORDS_BASE=100

# Base score per query word for a line containing only
# SOME of the query words (partial match).
FTS_PARTIAL_WORD=8

# Proximity: when all words are present, this is the
# maximum bonus, earned when the words are adjacent.
# The bonus decays as the character gap between the
# first and last matched word grows.
FTS_PROXIMITY_BONUS=100

# How quickly the proximity bonus decays per character
# of gap between the matched words. Higher = faster
# decay = distance matters more. The bonus at a given
# gap is:  FTS_PROXIMITY_BONUS / (1 + gap * FTS_GAP_DECAY)
FTS_GAP_DECAY="0.15"

# Penalty subtracted for each sentence terminator (.!?)
# found between the first and last matched word on a
# line. Words split across sentences are probably not
# the phrase the user had in mind.
FTS_SENTENCE_PENALTY=40

# Location multipliers - a line's score is multiplied
# by one of these depending on where the line was found.
FTS_WEIGHT_TITLE="3.0"     # the article's title (from the index)
FTS_WEIGHT_HEADER="2.0"    # a markdown header line (#, ##, ...)
FTS_WEIGHT_BODY="1.0"      # ordinary body text

# =====================================================
# END WEIGHTS
# =====================================================

# -----------------------------------------
# Parse arguments
#
# Everything that isn't a recognized flag is part of
# the query. --count and --explain are flags.
# -----------------------------------------

COUNT_MODE=false
EXPLAIN_MODE=false
TSV_MODE=false
QUERY_PARTS=()

for arg in "$@"; do
    case "$arg" in
        --count)   COUNT_MODE=true ;;
        --explain) EXPLAIN_MODE=true ;;
        --tsv)     TSV_MODE=true ;;
        *)         QUERY_PARTS+=("$arg") ;;
    esac
done

QUERY="${QUERY_PARTS[*]}"

[[ -z "$QUERY" ]] && die 'Usage: nina --search <query words> [--count] [--explain] [--tsv]'
require_index

# Canonicalize the query the same way titles are canonicalized,
# so matching is case- and punctuation-insensitive in the same
# way the rest of nina is.
QUERY="$(canonical_title "$QUERY")"

# -----------------------------------------
# Score every article
#
# We feed awk two things:
#   1. the index (file paths + titles), via -v index_file
#   2. nothing on stdin - awk opens each article itself
#
# For each article, awk reads the file line by line,
# scores each line with score_line(), applies the
# location multiplier, and sums the result. Articles
# with a total score > 0 are emitted as:
#
#   score <TAB> title <TAB> modified <TAB> tags
#
# Output is sorted numerically by score (descending)
# by the shell after awk finishes.
# -----------------------------------------

score_output="$(
awk \
    -v index_file="$INDEX_FILE" \
    -v query="$QUERY" \
    -v W_ALL="$FTS_ALL_WORDS_BASE" \
    -v W_PARTIAL="$FTS_PARTIAL_WORD" \
    -v W_PROX="$FTS_PROXIMITY_BONUS" \
    -v GAP_DECAY="$FTS_GAP_DECAY" \
    -v W_SENTENCE="$FTS_SENTENCE_PENALTY" \
    -v M_TITLE="$FTS_WEIGHT_TITLE" \
    -v M_HEADER="$FTS_WEIGHT_HEADER" \
    -v M_BODY="$FTS_WEIGHT_BODY" \
    '
    # -------------------------------------------------
    # normalize(s)
    # Lowercases and collapses non-alphanumeric runs to
    # single spaces, so scoring compares words the same
    # way regardless of punctuation or capitalization.
    # A trailing/leading space is added so word-boundary
    # searches (" word ") always work at line ends.
    # -------------------------------------------------
    function normalize(s) {
        s = tolower(s)
        gsub(/[^a-z0-9]+/, " ", s)
        return " " s " "
    }

    # -------------------------------------------------
    # count_terminators(s)
    # Counts sentence terminators (. ! ?) in a string.
    # Used to penalize query words that span sentences.
    # -------------------------------------------------
    function count_terminators(s,   n, i, c) {
        n = 0
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "." || c == "!" || c == "?") n++
        }
        return n
    }

    # =================================================
    # score_line(raw_line, multiplier)
    #
    # THE SCORING FUNCTION. This is the swappable heart
    # of the ranking system. It receives:
    #   raw_line   - one line of article text (or title)
    #   multiplier - the location weight for this line
    # and returns a score >= 0 for how well the line
    # matches the query.
    #
    # To change ranking behavior wholesale, replace the
    # body of this function. Everything else in the
    # script is plumbing that does not care how the
    # score is computed.
    # =================================================
    function score_line(raw_line, multiplier,
                        line, i, w, present, found_count,
                        first_pos, last_pos, wpos, gap, between,
                        term_count, prox, base, raw_score) {

        line = normalize(raw_line)

        # Locate each query word on the line. Track how
        # many are present, and the earliest and latest
        # character positions of any matched word, so we
        # can measure how spread out the matches are.
        found_count = 0
        first_pos   = 0
        last_pos    = 0

        for (i = 1; i <= query_n; i++) {
            w = " " query_words[i] " "
            wpos = index(line, w)
            if (wpos > 0) {
                found_count++
                # position of the actual word (skip the leading space)
                wpos = wpos + 1
                if (first_pos == 0 || wpos < first_pos) first_pos = wpos
                if (wpos + length(query_words[i]) > last_pos)
                    last_pos = wpos + length(query_words[i])
            }
        }

        if (found_count == 0) return 0

        # PARTIAL MATCH: not all query words on this line.
        # Score modestly, proportional to how many matched.
        if (found_count < query_n) {
            raw_score = found_count * W_PARTIAL
            return raw_score * multiplier
        }

        # FULL MATCH: all query words present on this line.
        # Start from the base, add a proximity bonus that
        # decays with the character gap between the first
        # and last matched word, and subtract a penalty for
        # each sentence terminator sitting between them.
        base = W_ALL

        gap = last_pos - first_pos
        if (gap < 0) gap = 0
        prox = W_PROX / (1 + gap * GAP_DECAY)

        between    = substr(line, first_pos, last_pos - first_pos)
        term_count = count_terminators(between)

        raw_score = base + prox - (term_count * W_SENTENCE)
        if (raw_score < 0) raw_score = 0

        return raw_score * multiplier
    }

    BEGIN {
        # Split the query into individual words once.
        query_n = split(query, query_words, " ")

        # Read the whole index into memory: file paths,
        # titles, modified dates, tags. We iterate it in
        # the END block so getline on article files does
        # not collide with the main input stream.
        idx_n = 0
        while ((getline idx_line < index_file) > 0) {
            idx_n++
            split(idx_line, cols, "\t")
            idx_file[idx_n]     = cols[1]
            idx_title[idx_n]    = cols[2]
            idx_modified[idx_n] = cols[4]
            idx_tags[idx_n]     = cols[5]
        }
        close(index_file)

        for (a = 1; a <= idx_n; a++) {
            total = 0

            # Score the title (highest-weighted location).
            total += score_line(idx_title[a], M_TITLE)

            # Score each line of the article body.
            file = idx_file[a]
            while ((getline art_line < file) > 0) {
                gsub(/\r/, "", art_line)             # strip CR

                # Header lines start with one or more #.
                if (art_line ~ /^#+[ \t]/)
                    total += score_line(art_line, M_HEADER)
                else
                    total += score_line(art_line, M_BODY)
            }
            close(file)

            if (total > 0) {
                # Emit an integer score for clean numeric
                # sorting; the fractional part never
                # matters for ranking order at this scale.
                printf "%d\t%s\t%s\t%s\n",
                    int(total + 0.5),
                    idx_title[a],
                    idx_modified[a],
                    idx_tags[a]
            }
        }
    }
    ' < /dev/null | sort -t $'\t' -k1,1nr -k2,2f
)"

# -----------------------------------------
# Add the canon column. score_output so far is
# score/title/modified/tags straight from awk; this widens it to
# score/canon/display/modified/tags - see "The canon/display
# Pair" in the technical guide's --tsv section. Small enough
# result set (already filtered to score > 0 matches) that a
# per-row bash loop here is fine, same reasoning nina-similar.sh
# gives for doing the same thing.
# -----------------------------------------

score_output="$(
    while IFS=$'\t' read -r score title modified tags; do
        [[ -z "$title" ]] && continue
        canon="$(canonical_title "$title")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$score" "$canon" "$title" "$modified" "$tags"
    done <<< "$score_output"
)"

# -----------------------------------------
# tsv mode - for the TUI's generic list renderer (and any other
# machine consumer) - see "The canon/display Pair" in the
# technical guide's --tsv section. Always emits the header, even
# on zero matches. Checked before --count so a combination of
# both (unlikely, but not forbidden) favors the machine-readable
# answer, same priority nina-orphan.sh and nina-similar.sh use
# for the same reason.
# -----------------------------------------

if [[ "$TSV_MODE" == true ]]; then
    printf '#score\tcanon\tdisplay\tmodified\ttags\n'
    [[ -n "$score_output" ]] && printf '%s\n' "$score_output"
    exit 0
fi

# -----------------------------------------
# Count mode - just how many articles matched
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    if [[ -z "$score_output" ]]; then
        echo 0
    else
        printf '%s\n' "$score_output" | grep -c .
    fi
    exit 0
fi

# -----------------------------------------
# No matches
# -----------------------------------------

if [[ -z "$score_output" ]]; then
    info "No matching articles."
    exit 0
fi

# -----------------------------------------
# Display ranked results
# -----------------------------------------

printf "\n"
printf "Full-text search results for: %s\n" "$QUERY"
printf "\n"

if [[ "$EXPLAIN_MODE" == true ]]; then
    table_begin " #" 6 "SCORE" 8 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
else
    table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
fi
table_header

titles=()
i=0

while IFS=$'\t' read -r score _canon title modified tags; do

    [[ -z "$title" ]] && continue

    ((i++))
    titles+=("$title")

    tags="${tags//,/ }"

    if [[ "$EXPLAIN_MODE" == true ]]; then
        table_row "$i" "$score" "$title" "$modified" "$tags"
    else
        table_row "$i" "$title" "$modified" "$tags"
    fi

done < <(printf '%s\n' "$score_output")

open_article_menu "${titles[@]}"
