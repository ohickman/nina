#!/usr/bin/env bash

# =====================================================
# nina-similar.sh - find articles with related content
#
# --graph, --tree, and --tag-graph all trace explicit
# links and tags. This finds relationships the author
# never wrote down: articles that share a lot of
# distinctive vocabulary, whether or not either one
# links to or tags the other.
#
# HOW IT SCORES (BM25)
#
# A naive "shared word count" is dominated by words
# that are common in English generally (or common
# across THIS corpus specifically) - "the", "however",
# but also domain-wide words like "article" or
# "system" if this corpus is full of technical notes.
# Those need to contribute close to nothing.
#
# BM25 fixes this the same way a search engine does:
#   - a word's weight falls as MORE articles contain it
#     (IDF - a word in 900 of 1000 articles is nearly
#     worthless for telling articles apart; a word in
#     4 of 1000 is a strong signal)
#   - a word's contribution to a single article SATURATES
#     rather than growing linearly - an article that
#     says "eigenvalue" 40 times is not 40x more "about"
#     eigenvalues than one that says it once
#   - articles are compared on a level field regardless
#     of length, so a long article doesn't win purely by
#     containing more words
#
# This still doesn't know what any word MEANS - it's
# frequency statistics, not semantics - but it's the
# standard, well-understood way to let corpus-wide word
# frequency do the work of a stopword list instead of
# hand-maintaining one. See nina --search's score_line
# for the sibling approach used for literal queries.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#
# It scores one target article against every other
# article and returns the top matches - it does not
# cluster the whole corpus, and it does not distinguish
# WHY two articles are similar (that's still your job,
# by reading them). A corpus-wide word is corpus-wide;
# this has no notion of "common within a sub-topic but
# rare outside it". If two articles share only very
# common connecting words, they will simply score low
# and not appear.
#
# Usage:
#   nina --similar "article title"
#   nina --similar "article title" --count 20
#   nina --similar "article title" --explain
#   nina --similar "article title" --tsv
#   nina --similar "article title" --dot
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
# None of them change which articles are ELIGIBLE to
# match (any shared term can contribute something) -
# only how strongly a shared term counts and how many
# results are shown. The scoring itself lives in a
# single awk function (bm25_term_weight, below) and can
# be swapped out wholesale without touching the rest of
# this script.
# =====================================================

# Term-frequency saturation. Controls how quickly a
# repeated word inside ONE article stops adding score.
# Standard BM25 value is 1.2-2.0. Lower = saturates
# faster (the 2nd occurrence of a word matters a lot
# less than the 1st); higher = closer to raw linear
# counting.
SIM_K1="1.5"

# Length normalization. 0 = ignore article length
# entirely; 1 = fully normalize (a word in a short
# article counts proportionally more than the same
# word in a long one). Standard BM25 value is 0.75.
SIM_B="0.75"

# Minimum number of articles a term must appear in to
# be considered at all. Filters out one-off typos and
# accidental tokens (numbers, code fragments) that
# would otherwise get an enormous, noisy IDF weight
# from appearing in just one place.
SIM_MIN_DF=2

# Maximum FRACTION of the corpus a term may appear in
# before it's dropped as a de facto stopword. At 1000
# articles and the default 0.5, a word in more than 500
# articles contributes nothing - this is what stands in
# for a hand-maintained stopword list.
SIM_MAX_DF_RATIO="0.5"

# Minimum token length. Filters stray single/double
# character fragments left over from punctuation
# stripping; not a stemmer, just noise control.
SIM_MIN_WORD_LEN=3

# How many results to show by default (overridden by
# --count on the command line).
SIM_DEFAULT_COUNT=15

# =====================================================
# END WEIGHTS
# =====================================================

# -----------------------------------------
# Parse arguments
# -----------------------------------------

EXPLAIN_MODE=false
FORMAT="text"
RESULT_COUNT="$SIM_DEFAULT_COUNT"
TITLE_PARTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --explain) EXPLAIN_MODE=true; shift ;;
        --tsv)     FORMAT="tsv"; shift ;;
        --dot)     FORMAT="dot"; shift ;;
        --count)
            [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]] || die "--count requires a number"
            RESULT_COUNT="$2"
            shift 2
            ;;
        *) TITLE_PARTS+=("$1"); shift ;;
    esac
done

QUERY_TITLE="${TITLE_PARTS[*]}"
[[ -z "$QUERY_TITLE" ]] && die 'Usage: nina --similar "article title" [--count N] [--explain] [--tsv|--dot]'

require_index

CANONICAL="$(canonical_title "$QUERY_TITLE")"

# Alias-aware, like nina-view.sh, nina-link-list.sh, and
# nina-tree.sh: this is a read-only "open this" lookup, not one
# of the mutating commands or --file-name, so it belongs on
# resolve_article_file rather than find_article_file. See the
# comment above resolve_article_file() in nina-lib.sh.
TARGET_FILE="$(resolve_article_file "$CANONICAL")"
[[ -z "$TARGET_FILE" ]] && die "No article found with title: $QUERY_TITLE"

# QUERY_DISPLAY: the article's real stored title (from its own
# header), not necessarily the casing/spacing the person typed -
# same technique nina-tree.sh uses for CENTER_DISPLAY. Only
# needed for --dot's node label; text/tsv modes already show
# results relative to whatever QUERY_TITLE the person typed, via
# normalize_display_title() below at print time.
QUERY_DISPLAY="$(normalize_display_title "$(header_field "$(read_header "$TARGET_FILE")" Title)")"

# -----------------------------------------
# Score every other article against the target
#
# Single awk pass, three phases inside BEGIN:
#   1. read the index, tokenize every article once,
#      building per-article term counts and corpus-wide
#      document frequencies
#   2. compute IDF per term from those document
#      frequencies, applying the min/max df cutoffs
#   3. score every article against the target using
#      BM25, emit non-zero scores
#
# Output: score <TAB> title <TAB> modified <TAB> tags
# (canon is added afterward, over the already-limited result set -
# see the block right after the sort/head line below)
# -----------------------------------------

score_output="$(
awk \
    -v index_file="$INDEX_FILE" \
    -v target_file="$TARGET_FILE" \
    -v K1="$SIM_K1" \
    -v B="$SIM_B" \
    -v MIN_DF="$SIM_MIN_DF" \
    -v MAX_DF_RATIO="$SIM_MAX_DF_RATIO" \
    -v MIN_WORD_LEN="$SIM_MIN_WORD_LEN" \
    '
    # -------------------------------------------------
    # tokenize(text, terms)
    # Lowercases, strips to alphanumerics, splits on
    # whitespace, and fills terms[] with words meeting
    # the minimum length. Returns the token count
    # (article length, for BM25 length normalization).
    # -------------------------------------------------
    function tokenize(text, terms,   n, i, w, count) {
        text = tolower(text)
        gsub(/[^a-z0-9]+/, " ", text)
        n = split(text, raw, " ")
        count = 0
        for (i = 1; i <= n; i++) {
            w = raw[i]
            if (length(w) >= MIN_WORD_LEN) {
                count++
                terms[count] = w
            }
        }
        return count
    }

    # =================================================
    # bm25_term_weight(tf, idf, doclen, avgdoclen)
    #
    # THE SCORING FUNCTION. Given how many times a term
    # occurs in an article (tf), the terms corpus-wide
    # weight (idf), and the articles length relative to
    # the corpus average, returns that terms contribution
    # to this articles score. Swap this out to change
    # ranking behavior wholesale - everything else here
    # is plumbing that does not care how the number is
    # produced.
    # =================================================
    function bm25_term_weight(tf, idf, doclen, avgdoclen,   denom) {
        denom = tf + K1 * (1 - B + B * (doclen / avgdoclen))
        return idf * (tf * (K1 + 1)) / denom
    }

    BEGIN {
        # ---- Phase 1: read index, tokenize every article ----
        idx_n = 0
        while ((getline idx_line < index_file) > 0) {
            idx_n++
            split(idx_line, cols, "\t")
            idx_file[idx_n]     = cols[1]
            idx_title[idx_n]    = cols[2]
            idx_modified[idx_n] = cols[4]
            idx_tags[idx_n]     = cols[5]
            if (cols[1] == target_file) target_idx = idx_n
        }
        close(index_file)

        if (!target_idx) {
            print "__NOTARGET__"
            exit
        }

        total_len = 0
        for (a = 1; a <= idx_n; a++) {
            file = idx_file[a]
            body = ""
            while ((getline art_line < file) > 0) {
                gsub(/\r/, "", art_line)
                body = body " " art_line
            }
            close(file)

            n_terms = 0
            split("", terms)   # reset
            doclen = tokenize(body, terms)
            doc_len[a] = doclen
            total_len += doclen

            # per-article term frequency, and mark this
            # article as one that contains the term (for
            # document frequency, counted once per doc
            # regardless of how many times it recurs here)
            split("", seen_in_doc)
            for (i = 1; i <= doclen; i++) {
                w = terms[i]
                tf[a, w]++
                if (!(w in seen_in_doc)) {
                    seen_in_doc[w] = 1
                    df[w]++
                }
            }
        }
        avg_doc_len = (idx_n > 0) ? total_len / idx_n : 0

        # ---- Phase 2: IDF per term, with df cutoffs ----
        # BM25 IDF (Robertson-Sparck Jones), floored at a
        # small positive value so a term appearing in
        # slightly more than half the corpus contributes
        # a little rather than going negative and
        # penalizing articles for containing it.
        max_df = idx_n * MAX_DF_RATIO
        for (w in df) {
            if (df[w] < MIN_DF || df[w] > max_df) continue
            idf_val = log((idx_n - df[w] + 0.5) / (df[w] + 0.5) + 1)
            idf[w] = idf_val
        }

        # ---- Phase 3: score every article against target ----
        # Walk the terms that actually occur in the target
        # article (no need to consider terms absent from
        # it - they cannot contribute to similarity with
        # it), and for each OTHER article that also
        # contains the term, accumulate its BM25 weight.
        for (key in tf) {
            split(key, parts, SUBSEP)
            # only care about terms present in the target
        }
        # (re-tokenize target explicitly for clarity/order)
        split("", target_terms_arr)
        target_doclen = doc_len[target_idx]
        for (w in idf) {
            if ((target_idx, w) in tf) target_present[w] = 1
        }

        for (a = 1; a <= idx_n; a++) {
            if (a == target_idx) continue
            score = 0
            for (w in target_present) {
                if (!((a, w) in tf)) continue
                score += bm25_term_weight(tf[a, w], idf[w], doc_len[a], avg_doc_len)
            }
            if (score > 0) {
                printf "%.4f\t%s\t%s\t%s\n",
                    score, idx_title[a], idx_modified[a], idx_tags[a]
            }
        }
    }
    ' < /dev/null
)"

if [[ "$score_output" == "__NOTARGET__" ]]; then
    die "Target article is not present in the index. Run: nina --index"
fi

score_output="$(printf '%s\n' "$score_output" | sort -t $'\t' -k1,1nr -k2,2f | head -n "$RESULT_COUNT")"

# -----------------------------------------
# No matches - tsv/dot still owe a consumer a valid, parseable
# zero-row/zero-edge answer (the header, or the comment+open+
# node+close skeleton), same as everywhere else in the --tsv/
# --dot contracts. Only text mode substitutes a human message.
# -----------------------------------------

if [[ -z "$score_output" ]]; then
    case "$FORMAT" in
        tsv)
            printf '#score\tcanon\tdisplay\tmodified\ttags\n'
            ;;
        dot)
            dot_comment "nina --similar \"$QUERY_TITLE\" --count $RESULT_COUNT --dot"
            dot_graph_open "nina_similar" false
            dot_node "$QUERY_DISPLAY"
            dot_graph_close
            ;;
        *)
            info "No sufficiently similar articles found."
            ;;
    esac
    exit 0
fi

# -----------------------------------------
# Add each result's canonical title, via nina-lib.sh's own
# canonical_title() - never reimplemented in awk, so canon values
# match every other tool exactly. This only runs over the already-
# limited result set (at most RESULT_COUNT rows), not the whole
# corpus - the expensive corpus-wide work already happened once,
# inside the awk pass above. A handful of canonical_title() calls
# over an already-filtered top-N list is not the per-article
# subprocess-fork pattern the codebase avoids elsewhere; that
# concern is about looping the whole corpus, not a top 15-20.
#
# New column order: score, canon, display, modified, tags - see
# "The canon/display Pair" in the technical guide's --tsv section.
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
# machine consumer). Emits the required header line before the
# rows - an earlier version of this mode omitted it, which broke
# the general --tsv contract (every mode must start with a
# #-prefixed header), not just the canon/display naming rule.
# -----------------------------------------

if [[ "$FORMAT" == "tsv" ]]; then
    printf '#score\tcanon\tdisplay\tmodified\ttags\n'
    printf '%s\n' "$score_output"
    exit 0
fi

# -----------------------------------------
# dot mode - undirected, since similarity is inherently
# symmetric (see [[Nina - Devs: Graph Output Standard (--dot)]],
# "Graph Direction and Rankdir"): the BM25 score used here is
# specifically "how similar is every other article TO the
# query", not a mutual score, but the relationship it reports -
# these two articles share a lot of distinctive vocabulary - has
# no direction, so it's drawn the same way --tag-graph cooccur
# draws co-occurrence.
#
# Unlike every other --dot mode so far, this one has a genuine
# per-edge strength - the BM25 score itself - so, unlike
# nina-graph.sh's constant-1 edges, dot_weight here actually
# differentiates edges by real similarity strength. The score is
# passed as dot_edge's STRENGTH (drives penwidth, full
# precision) with an explicit two-decimal LABEL, exactly the
# case the standard doc calls out under dot_edge: "the
# --similar's score rounded to two decimals while the underlying
# value has more precision".
# -----------------------------------------

if [[ "$FORMAT" == "dot" ]]; then
    dot_comment "nina --similar \"$QUERY_TITLE\" --count $RESULT_COUNT --dot"
    dot_graph_open "nina_similar" false
    dot_node "$QUERY_DISPLAY"
    while IFS=$'\t' read -r score _canon title _modified _tags; do
        [[ -z "$title" ]] && continue
        dot_edge "$QUERY_DISPLAY" "$title" "$score" false "$(printf '%.2f' "$score")"
    done < <(printf '%s\n' "$score_output")
    dot_graph_close
    exit 0
fi

# -----------------------------------------
# Display ranked results
# -----------------------------------------

printf "\n"
printf "Articles similar to: %s\n" "$(normalize_display_title "$QUERY_TITLE")"
printf "\n"

if [[ "$EXPLAIN_MODE" == true ]]; then
    table_begin " #" 6 "SCORE" 10 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
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
        table_row "$i" "$(printf '%.2f' "$score")" "$title" "$modified" "$tags"
    else
        table_row "$i" "$title" "$modified" "$tags"
    fi

done < <(printf '%s\n' "$score_output")

open_article_menu "${titles[@]}"
