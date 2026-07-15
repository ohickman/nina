#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

TSV_MODE=false
for arg in "$@"; do
    case "$arg" in
        --tsv) TSV_MODE=true ;;
    esac
done

require_index

if [[ "$TSV_MODE" != true ]]; then
    printf "\nNina Statistics\n"
    printf -- "---------------\n"
fi

# -----------------------------------------
# Basic counts
# -----------------------------------------

article_count=$(wc -l < "$INDEX_FILE")

tag_count=$(awk -F'\t' '
{
    if ($5 != "") {
        n = split($5, tags, ",")
        for (i = 1; i <= n; i++)
            seen[tags[i]] = 1
    }
}
END { print length(seen) }
' "$INDEX_FILE")

author_count=$(awk -F'\t' '
{
    if ($3 != "")
        seen[$3] = 1
}
END { print length(seen) }
' "$INDEX_FILE")

# -----------------------------------------
# Average tags per article
# -----------------------------------------

avg_tags=$(awk -F'\t' '
{
    if ($5 == "")
        next

    n = split($5, tags, ",")
    total += n
    articles++
}
END {
    if (articles > 0)
        printf "%.1f", total / articles
    else
        print "0"
}
' "$INDEX_FILE")

# -----------------------------------------
# Date range
# -----------------------------------------

oldest=$(awk -F'\t' 'NR==1 || $4 < min { min=$4 } END { print min }' "$INDEX_FILE")
newest=$(awk -F'\t' 'NR==1 || $4 > max { max=$4 } END { print max }' "$INDEX_FILE")

# -----------------------------------------
# Orphan and dangling counts
#
# Previously called `nina --orphan --count` and `nina --dangling --count`
# as two separate subprocesses, each launching a shell, loading config,
# and running a full scan_links pass. On a ~1000-article corpus that was
# roughly 40s of the total stats runtime.
#
# Now we:
#   1. Build the set of indexed canonical titles once, using the stream
#      form of canonical_title() - a single pipeline pass with no
#      per-row subprocess forks.
#   1b. Build a map of existing aliases to the real title they resolve
#      to (through alias_titles()/alias_lookup(), the only sanctioned
#      reader of index-alias.tsv's format - not a raw read here).
#   2. Call scan_links exactly once.
#   3. Derive both counts from that one pass.
#
# Orphan:   an indexed article whose canonical title never appears -
#           directly, or as the resolved title of an anchored/aliased
#           link (see below) - as a link target in any article.
# Dangling: a unique link target that, after the same anchor-split
#           attempt, still matches no indexed article's canonical
#           title.
#
# A link target like "Title#Heading" only equals its own target_canon
# as a whole, never the real title's canonical form on its own - so a
# target's own canonical form is tried first, unsplit, exactly the
# original single hash lookup, same cost as before for the common
# case. Only a target that both contains '#' and fails that lookup
# walks backward through its anchor split (same algorithm as
# nina-view.sh, nina-dangling.sh, nina-backlinks.sh, and nina-graph.sh),
# stopping at the first (longest) prefix that resolves to a real title
# or alias. A target with no '#' at all never enters that branch, so
# this stays a single hash lookup per link exactly as before for the
# corpus's ordinary, non-anchored links.
# -----------------------------------------

# Step 1: index every article's canonical title
declare -A _idx _ref _dangle _alias

while IFS= read -r _canon; do
    _idx["$_canon"]=1
done < <(cut -d$'\t' -f2 "$INDEX_FILE" | canonical_title)

# Step 1b: index every alias's real-title canonical form
while IFS= read -r _alias_name; do
    _a_canon="$(canonical_title "$_alias_name")"
    _a_title="$(alias_lookup "$_a_canon")"
    [[ -n "$_a_title" ]] && _alias["$_a_canon"]="$(canonical_title "$_a_title")"
done < <(alias_titles)

# Step 2 & 3: single scan_links pass, accumulate both counts
while IFS=$'\t' read -r _src _src_c _tgt _tgt_c; do

    _resolved="$_tgt_c"
    _is_dangling=true

    if [[ -n "${_idx[$_tgt_c]:-}" ]]; then
        _is_dangling=false
    elif [[ "$_tgt" == *"#"* ]]; then
        _remaining="${_tgt%#*}"
        while true; do
            _cand="$(canonical_title "$_remaining")"

            if [[ -n "${_idx[$_cand]:-}" ]]; then
                _resolved="$_cand"
                _is_dangling=false
                break
            fi

            if [[ -n "${_alias[$_cand]:-}" ]]; then
                _resolved="${_alias[$_cand]}"
                _is_dangling=false
                break
            fi

            [[ "$_remaining" == *"#"* ]] || break
            _remaining="${_remaining%#*}"
        done
    fi

    if [[ "$_is_dangling" == false ]]; then
        _ref["$_resolved"]=1
    else
        _dangle["$_tgt_c"]=1
    fi

done < <(scan_links)

# Orphans: indexed articles never referenced as a link target
orphan_count=0
for _canon in "${!_idx[@]}"; do
    [[ -z "${_ref[$_canon]:-}" ]] && (( orphan_count++ ))
done

dangling_count="${#_dangle[@]}"

unset _idx _ref _dangle _alias _src _src_c _tgt _tgt_c _canon \
      _alias_name _a_canon _a_title _resolved _is_dangling _remaining _cand

# -----------------------------------------
# Installed macros
#
# Read straight from the manifest - stats
# describes the working system as a user
# experiences it, it doesn't re-validate
# anything. An invalid macro file is
# --doctor's concern, not this script's.
# -----------------------------------------

MANIFEST_FILE="$HOME/.nina/macros.tsv"

if [[ -f "$MANIFEST_FILE" ]]; then
    macro_count=$(grep -vc '^#' "$MANIFEST_FILE")
else
    macro_count=0
fi

# -----------------------------------------
# Installed plugins
#
# Same philosophy as the macro count above:
# read straight from the manifest, don't
# re-validate anything here. The third
# manifest column (needs_long_timeout) is
# already a fact about each installed
# plugin - whether it can reach the network
# or the rest of the corpus - so showing the
# split costs nothing extra and doesn't
# cross into --doctor's territory of
# actually re-checking plugin files.
# -----------------------------------------

PLUGINS_MANIFEST_FILE="$HOME/.nina/plugins.tsv"

if [[ -f "$PLUGINS_MANIFEST_FILE" ]]; then
    plugin_count=$(grep -vc '^#' "$PLUGINS_MANIFEST_FILE")
    plugin_reach_count=$(awk -F'\t' '!/^#/ && $3 == "1" { n++ } END { print n+0 }' "$PLUGINS_MANIFEST_FILE")
else
    plugin_count=0
    plugin_reach_count=0
fi

plugins_enabled="${ENABLE_PLUGINS:-false}"

# -----------------------------------------
# tsv mode - flat metric/value pairs for the TUI's generic list
# renderer (and any other machine consumer) - see "The
# canon/display Pair" in the technical guide's --tsv section.
# There's no canon/display pair here (no titles are being
# listed), so the header is just metric/value.
#
# Top Tags is deliberately NOT included: it's a frequency-sorted
# top-10 preview of the same data nina-tag-list.sh already owns
# in full (alphabetically, all tags, not just the top 10) - a
# machine consumer that wants tag counts belongs there, not
# scraping a truncated preview out of this table. Skipping the
# aggregation here also means tsv mode never pays for work whose
# only consumer, the human display below, isn't going to run.
#
# plugins_enabled is its own row rather than folded into
# installed_plugins's value as descriptive text (the human
# display below does that, e.g. "8 (plugin expansion disabled)")
# - a machine field should just be the number.
# -----------------------------------------

if [[ "$TSV_MODE" == true ]]; then
    printf '#metric\tvalue\n'
    printf 'articles\t%s\n' "$article_count"
    printf 'distinct_tags\t%s\n' "$tag_count"
    printf 'unique_authors\t%s\n' "$author_count"
    printf 'avg_tags_per_article\t%s\n' "$avg_tags"
    printf 'oldest_article_date\t%s\n' "$oldest"
    printf 'newest_article_date\t%s\n' "$newest"
    printf 'orphan_articles\t%s\n' "$orphan_count"
    printf 'dangling_links\t%s\n' "$dangling_count"
    printf 'installed_macros\t%s\n' "$macro_count"
    printf 'installed_plugins\t%s\n' "$plugin_count"
    printf 'plugins_enabled\t%s\n' "$plugins_enabled"
    printf 'plugins_reaching_network_or_corpus\t%s\n' "$plugin_reach_count"
    exit 0
fi

# -----------------------------------------
# Find most frequent tags
# -----------------------------------------

printf "\nTop Tags:\n"

awk -F'\t' '
{
    if ($5 != "") {
        n = split($5, tags, ",")
        for (i = 1; i <= n; i++)
            count[tags[i]]++
    }
}
END {
    for (tag in count)
        printf "%s\t%d\n", tag, count[tag]
}
' "$INDEX_FILE" |
sort -k2,2nr | head -10 |
while IFS=$'\t' read -r tag count; do
    printf "  %-16s %5d\n" "$tag" "$count"
done
printf "\n"
# -----------------------------------------
# Display summary
# -----------------------------------------

printf "%-20s %s\n" "Articles:" "$article_count"
printf "%-20s %s\n" "Tags:" "$tag_count"
printf "%-20s %s\n" "Unique Authors:" "$author_count"
printf "\n"

printf "%-20s %s\n" "Average tags/article:" "$avg_tags"
printf "\n"

printf "%-20s %s\n" "Oldest article:" "$oldest"
printf "%-20s %s\n" "Newest article:" "$newest"
printf "\n"

printf "%-20s %s\n" "Orphan articles:" "$orphan_count"
printf "%-20s %s\n" "Dangling links:" "$dangling_count"
printf "\n"

printf "%-20s %s\n" "Installed macros:" "$macro_count"

if [[ "$plugins_enabled" == "true" ]]; then
    printf "%-20s %s\n" "Installed plugins:" "$plugin_count"
else
    printf "%-20s %s\n" "Installed plugins:" "$plugin_count (plugin expansion disabled)"
fi

printf "%-20s %s\n" "  reaching network/corpus:" "$plugin_reach_count"

printf "\n"