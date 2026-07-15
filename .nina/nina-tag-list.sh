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

# -----------------------------------------
# One tag occurrence per line via the accessor; the frequency
# count and defensive per-tag whitespace normalization are this
# script's own aggregation on that stream. Emits raw tag/count
# pairs, tab-separated, sorted alphabetically by tag - both
# --tsv mode and the human table below share this exact
# computation and ordering; only the formatting differs.
# -----------------------------------------

tag_counts="$(
    index_tags | awk '
    {
        tag = $0

        # Defensive normalization
        gsub(/[[:space:]]+/, " ", tag)
        sub(/^ /, "", tag)
        sub(/ $/, "", tag)

        if (tag != "")
            count[tag]++
    }
    END {
        for (tag in count)
            printf "%s\t%d\n", tag, count[tag]
    }
    ' | sort -k1,1
)"

# -----------------------------------------
# tsv mode - for the TUI's generic list renderer (and any other
# machine consumer) - see "Machine-Readable Output (--tsv)" in
# the technical guide. No canon/display pair here - a tag has no
# separate display form the way a title does, index_tags already
# yields it in its one true (lowercase, whitespace-collapsed)
# form - so the header is just tag/count. Tag values carry the
# same delimiter-safety guarantee titles do: nina-index.sh runs
# every tag through normalize_display_title() before it ever
# reaches the index (see the "sanitizes so tabs in field don't
# corrupt index" comment there), so no further escaping is
# needed here either. Always emits the header, even on an empty
# corpus.
# -----------------------------------------

if [[ "$TSV_MODE" == true ]]; then
    printf '#tag\tcount\n'
    [[ -n "$tag_counts" ]] && printf '%s\n' "$tag_counts"
    exit 0
fi

echo
echo "TAG                  FILES"
echo "-------------------- -----"

printf '%s\n' "$tag_counts" |
while IFS=$'\t' read -r tag count; do
    [[ -z "$tag" ]] && continue
    printf "%-20s %5d\n" "$tag" "$count"
done