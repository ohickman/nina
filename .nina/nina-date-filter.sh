#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

DATE_QUERY="$1"

COUNT_MODE=false

if [[ "$1" == "--count" ]]; then
    COUNT_MODE=true
    DATE_QUERY=""
elif [[ "$2" == "--count" ]]; then
    COUNT_MODE=true
fi

require_index

# -----------------------------------------
# Parse date query into start/end range
# -----------------------------------------

# -----------------------------------------
# Pure-bash date arithmetic
#
# These functions replace GNU `date -d`, which does not exist on
# BSD/macOS (BSD date uses a completely different -v syntax).
# Since the index stores ISO 8601 dates and all range filtering is
# plain string comparison, the only date *arithmetic* nina needs is:
#   - the last day of a given month  (for month queries like 2026-02)
#   - a date plus/minus N days       (for span queries like 2026-06-15+7)
# Both are simple, well-defined calculations - no external command
# needed at all.
# -----------------------------------------

# days_in_month YEAR MONTH
# Prints the number of days in the given month, handling leap years.
# Leap year rule: divisible by 4, except centuries unless divisible
# by 400 (1900 was not a leap year, 2000 was).
# The 10#$2 forces base-10 interpretation so "08" and "09" don't get
# read as invalid octal numbers.

days_in_month() {
    local year=$((10#$1)) month=$((10#$2))

    case $month in
        1|3|5|7|8|10|12) echo 31 ;;
        4|6|9|11)        echo 30 ;;
        2)
            if (( year % 4 == 0 && ( year % 100 != 0 || year % 400 == 0 ) )); then
                echo 29
            else
                echo 28
            fi
            ;;
        *) echo 0 ;;  # invalid month - caller validates
    esac
}

# date_to_jdn YYYY-MM-DD
# Converts a calendar date to a Julian Day Number - a plain count of
# days since a fixed epoch, which turns date arithmetic into ordinary
# integer arithmetic. This is the standard Fliegel & Van Flandern
# algorithm; the (14 - month)/12 trick shifts the year to start in
# March so leap days fall at the end of the shifted year and need no
# special casing.

date_to_jdn() {
    local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2}))
    local a=$(( (14 - m) / 12 ))
    local yy=$(( y + 4800 - a ))
    local mm=$(( m + 12*a - 3 ))
    echo $(( d + (153*mm + 2)/5 + 365*yy + yy/4 - yy/100 + yy/400 - 32045 ))
}

# jdn_to_date JDN
# The inverse of date_to_jdn: converts a Julian Day Number back to an
# ISO 8601 date string.

jdn_to_date() {
    local jdn=$1
    local a=$(( jdn + 32044 ))
    local b=$(( (4*a + 3) / 146097 ))
    local c=$(( a - (146097*b)/4 ))
    local d=$(( (4*c + 3) / 1461 ))
    local e=$(( c - (1461*d)/4 ))
    local m=$(( (5*e + 2) / 153 ))
    local day=$((   e - (153*m + 2)/5 + 1 ))
    local month=$(( m + 3 - 12*(m/10) ))
    local year=$((  100*b + d - 4800 + m/10 ))
    printf '%04d-%02d-%02d\n' "$year" "$month" "$day"
}

# date_add_days YYYY-MM-DD N
# Prints the date N days after (or before, if N is negative) the
# given date. Replaces `date -d "$base + $span days" +%F`.

date_add_days() {
    local jdn
    jdn=$(date_to_jdn "$1")
    jdn_to_date $(( jdn + $2 ))
}

parse_date_query() {

    local q="$1"

    if [[ "$q" == *".."* ]]; then
        start="${q%%..*}"
        end="${q##*..}"
        return
    fi

    if [[ "$q" == *"+"* ]]; then
        base="${q%%+*}"
        span="${q##*+}"

        # Validate before doing arithmetic - the old `date -d` call
        # would have caught malformed input by failing; the pure-bash
        # functions need the caller to check.
        [[ "$base" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Invalid date format."
        [[ "$span" =~ ^[0-9]+$ ]] || die "Invalid span: expected a number of days."

        start=$(date_add_days "$base" "-$span")
        end=$(date_add_days "$base" "$span")
        return
    fi

    if [[ "$q" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        start="$q"
        end="$q"
        return
    fi

    if [[ "$q" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        start="$q-01"
        end="$q-$(days_in_month "${q:0:4}" "${q:5:2}")"
        return
    fi

    if [[ "$q" =~ ^[0-9]{4}$ ]]; then
        start="$q-01-01"
        end="$q-12-31"
        return
    fi

    die "Invalid date format."
}

# -----------------------------------------
# Determine date range
# -----------------------------------------

if [[ -z "$DATE_QUERY" ]]; then
    start="0000-00-00"
    end="9999-12-31"
else
    parse_date_query "$DATE_QUERY"
fi

# -----------------------------------------
# Count mode - report the number of matching
# articles instead of listing them
# -----------------------------------------

if [[ "$COUNT_MODE" == true ]]; then
    # Only the date column is needed; the range test is a plain string
    # comparison because ISO 8601 dates sort chronologically.
    index_dates | awk -v start="$start" -v end="$end" '
    {
        if ($0 >= start && $0 <= end)
            count++
    }
    END { print count + 0 }
    '
    exit 0
fi

# -----------------------------------------
# Print table header
# -----------------------------------------

printf "\n"

table_begin " #" 6 "TITLE" 30 "MODIFIED" 12 "TAGS" 0
table_header

# -----------------------------------------
# Filter and display
# -----------------------------------------

titles=()
i=0

while IFS=$'\t' read -r title modified tags; do

    ((i++))
    titles+=("$title")

    tags="${tags//,/ }"

    table_row "$i" "$title" "$modified" "$tags"

done < <(
    # Row selection (date range) on the shared display projection,
    # then re-sorted newest-first. index_display_rows emits
    # "title TAB date TAB tags" with date always present and tags
    # trailing, so the read never hits an empty middle field.
    index_display_rows |
    while IFS=$'\t' read -r title date tags; do
        if ! [[ "$date" < "$start" ]] && ! [[ "$date" > "$end" ]]; then
            printf '%s\t%s\t%s\n' "$title" "$date" "$tags"
        fi
    done |
    sort -t $'\t' -r -k2,2
)

# -----------------------------------------
# Interactive navigation
# -----------------------------------------

if [[ -t 1 ]]; then
    open_article_menu "${titles[@]}"
fi