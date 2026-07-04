#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

require_index

echo
echo "TAG                  FILES"
echo "-------------------- -----"

# One tag occurrence per line via the accessor; the frequency
# count, defensive per-tag whitespace normalization, and display
# formatting are this script's own aggregation on that stream.
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
        printf "%-20s %5d\n", tag, count[tag]
}
' | sort -k1,1