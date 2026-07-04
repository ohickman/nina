#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

printf "\nNina Statistics\n"
printf -- "---------------\n"

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
#   2. Call scan_links exactly once.
#   3. Derive both counts from that one pass.
#
# Orphan:   an indexed article whose canonical title never appears as a
#           link target in any article.
# Dangling: a unique link target whose canonical form doesn't match any
#           indexed article's canonical title.
# -----------------------------------------

# Step 1: index every article's canonical title
declare -A _idx _ref _dangle

while IFS= read -r _canon; do
    _idx["$_canon"]=1
done < <(cut -d$'\t' -f2 "$INDEX_FILE" | canonical_title)

# Step 2 & 3: single scan_links pass, accumulate both counts
while IFS=$'\t' read -r _src _src_c _tgt _tgt_c; do
    _ref["$_tgt_c"]=1
    [[ -z "${_idx[$_tgt_c]:-}" ]] && _dangle["$_tgt_c"]=1
done < <(scan_links)

# Orphans: indexed articles never referenced as a link target
orphan_count=0
for _canon in "${!_idx[@]}"; do
    [[ -z "${_ref[$_canon]:-}" ]] && (( orphan_count++ ))
done

dangling_count="${#_dangle[@]}"

unset _idx _ref _dangle _src _src_c _tgt _tgt_c _canon

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