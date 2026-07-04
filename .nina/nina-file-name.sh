#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# This script is meant to be composed with
# other Unix tools, e.g.:
#
#   mv "$(nina --file-name "My Article")" new_name.md
#
# so its contract is stricter than the rest
# of nina's commands:
#   - stdout contains the file path and
#     nothing else - no headers, no blank
#     lines, no trailing newline games
#   - all errors go to stderr only
#   - exit 0 on a single, unambiguous match;
#     non-zero otherwise
#   - never interactive, never prompts
#   - resolves by real title only - an alias is
#     deliberately NOT accepted here, matching the
#     mutating commands, since this primitive feeds
#     straight into tools like mv
# -----------------------------------------

TITLE="$1"

[[ -z "$TITLE" ]] && die 'Usage: nina --file-name "Article Title"'
require_index

TITLE="$(normalize_display_title "$TITLE")"
[[ -z "$TITLE" ]] && die "Invalid title."

CANONICAL_INPUT="$(canonical_title "$TITLE")"

mapfile -t matches < <(find_article_file "$CANONICAL_INPUT")

if (( ${#matches[@]} == 0 )); then
    die "Article not found: $TITLE"
fi

if (( ${#matches[@]} > 1 )); then
    # Should not be reachable under normal operation -
    # nina-index.sh excludes duplicate titles entirely -
    # but this script feeds directly into mv and similar
    # commands, so silently picking one of several matches
    # would be a worse failure than refusing outright.
    die "Multiple articles matched (index may be stale or hand-edited): $TITLE"
fi

printf '%s\n' "${matches[0]}"
