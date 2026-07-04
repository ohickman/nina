#!/usr/bin/env bash

# -----------------------------------------
# nina-plugin-helper.sh
#
# Trusted helper invoked only by
# plugin_call_nina() in nina-plugin-api.awk.
# Not wired into the main `nina` dispatcher -
# this is internal plumbing, not a
# user-facing command.
#
# Implements a fixed, hand-picked allowlist
# of read-only operations against the index,
# each one a direct call into the existing
# nina-lib.sh functions the rest of the
# program already uses - never a constructed
# shell command built from article text.
#
# The article-derived argument (e.g. a
# title) arrives via NINA_ARG_FILE, a path
# to a temp file plugin_call_nina() wrote it
# to - it is never passed as a positional
# argument or interpolated into a command
# line, so there is nothing here for that
# text to inject into.
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

VERB="$1"

[[ -n "$NINA_ARG_FILE" && -f "$NINA_ARG_FILE" ]] || exit 1
[[ -f "$INDEX_FILE" ]] || exit 1

ARG="$(cat "$NINA_ARG_FILE")"
canonical_target="$(canonical_title "$ARG")"

# De-alias the query up front so every read-only verb below
# operates on the real article an alias names - including
# --backlinks, whose match must line up with scan_links, which
# de-aliases link targets the same way. A no-op when disabled.
canonical_target="$(dealias_canonical "$canonical_target")"

case "$VERB" in

    --backlinks)
        while IFS=$'\t' read -r src src_canon target target_canon; do
            [[ "$target_canon" == "$canonical_target" ]] && printf '%s\n' "$src"
        done < <(scan_links) | awk '!seen[$0]++'
        ;;

    --tags)
        # Resolved the same way every other verb is - via
        # find_article_file/canonical_target - rather than
        # re-matching on title text a second time. An earlier
        # version compared its own partial re-normalization of
        # the index's title column against canonical_target and
        # missed canonical_title's dash/quote normalization,
        # so a title containing an em-dash or curly quote would
        # silently fail to match even though it was correctly
        # indexed. Matching on the resolved file path instead is
        # exact - no characters to normalize, nothing to drift
        # out of sync with canonical_title in the future.
        FILE="$(find_article_file "$canonical_target")"
        [[ -z "$FILE" ]] && exit 1
        awk -F'\t' -v f="$FILE" '$1 == f { print $5 }' "$INDEX_FILE"
        ;;

    --links)
        # One line per distinct linked article, in the order
        # each target first appears, case-insensitive. This is
        # meant to be the simple, general-purpose answer to
        # "what does this article link to" - usable with no
        # cleanup on the plugin author's end. A plugin that
        # specifically wants raw occurrence counts (how many
        # times a target is linked, including repeats) can
        # still get that - the article's own text is already
        # available to it via stdin or plugin_read_article() -
        # it just isn't what this function is for.
        #
        # normalize_display_title() prints with no trailing
        # newline by design - every other call site uses it
        # inside "$(...)" command substitution, where that
        # doesn't matter. Here it's called once per link in a
        # loop, so each call's output needs its own newline
        # added explicitly, or consecutive titles run together
        # with no separator at all - the dedup step below only
        # works correctly once that's true.
        FILE="$(find_article_file "$canonical_target")"
        [[ -z "$FILE" ]] && exit 1
        extract_links "$FILE" |
        while IFS= read -r link; do
            target="$(link_target "$link")"
            printf '%s\n' "$(normalize_display_title "$target")"
        done | dedup_titles
        ;;

    --read)
        FILE="$(find_article_file "$canonical_target")"
        [[ -z "$FILE" ]] && exit 1
        cat "$FILE"
        ;;

    --read-body)
        FILE="$(find_article_file "$canonical_target")"
        [[ -z "$FILE" ]] && exit 1
        header_lines=$(read_header "$FILE" | wc -l)
        tail -n +"$((header_lines + 2))" "$FILE"
        ;;

    *)
        exit 1
        ;;

esac

exit 0
