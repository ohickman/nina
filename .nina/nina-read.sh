#!/usr/bin/env bash

# -----------------------------------------
# nina-read.sh
#
# Render an arbitrary file - or piped stdin -
# through nina's rendering engine, without any
# involvement of index.tsv. This is deliberately
# NOT "view an article": there is no title, no
# canonical lookup, no backlinks. It just pumps
# bytes through nina-render.sh the way `cat`
# pumps bytes to a terminal.
#
# Invoked as:
#   nina --read some_file.txt
#   cat some_file.md | nina --read
#   cat some_file.md | nina            (dispatcher
#       routes a bare pipe with no argument here too)
# -----------------------------------------

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"
load_config

# -----------------------------------------
# Determine mode: a named file, or a stream
# on stdin. An empty argument with stdin still
# attached to a terminal is a plain usage error -
# nothing was named and nothing was piped.
# -----------------------------------------

FILE_ARG="$1"
MODE="file"
TEMP_FILE=""
ORIG_SNAPSHOT=""

if [[ -z "$FILE_ARG" ]]; then
    if [[ -t 0 ]]; then
        die 'Usage: nina --read <file>   (or pipe data: cat file | nina --read)'
    fi
    MODE="stream"
fi

# -----------------------------------------
# File mode: validate the named file directly.
# No path resolution beyond what the shell
# already does - same as `cat my_file.txt`
# already works from the caller's cwd, so does
# this.
# -----------------------------------------

if [[ "$MODE" == "file" ]]; then

    [[ -f "$FILE_ARG" ]] || die "File not found: $FILE_ARG"
    [[ -r "$FILE_ARG" ]] || die "File not readable: $FILE_ARG"

    FILE="$FILE_ARG"

# -----------------------------------------
# Stream mode: buffer stdin into a temp file,
# since everything downstream (binary check,
# less/LESSOPEN, link scan) needs a real path.
# A second, untouched snapshot lets us detect
# later whether the user edited the buffer via
# `v` inside less, since there is no original
# file to compare against.
# -----------------------------------------

else

    TEMP_FILE="$(make_temp_file)"
    ORIG_SNAPSHOT="$(make_temp_file)"

    trap 'rm -f "$TEMP_FILE" "$ORIG_SNAPSHOT"' EXIT

    cat > "$TEMP_FILE"
    cp "$TEMP_FILE" "$ORIG_SNAPSHOT"

    FILE="$TEMP_FILE"

fi

# -----------------------------------------
# Reject binary content.
#
# grep -I treats a file containing NUL bytes
# as binary and will not match it, so a true
# binary file fails the check below. An empty
# file has no lines for grep -I '' to match
# either, even though it is valid (empty) text -
# so size is checked first to avoid a false
# rejection there.
# -----------------------------------------

if [[ -s "$FILE" ]] && ! grep -Iq '' "$FILE"; then
    if [[ "$MODE" == "file" ]]; then
        die "Not a text file: $FILE_ARG"
    else
        die "Not a text stream."
    fi
fi

# -----------------------------------------
# Render via less using LESSOPEN, exactly as
# nina-view.sh does. less tracks $FILE as the
# real filename even though it is displaying
# nina-render.sh's piped output, so pressing
# `v` inside less opens the raw underlying file
# (the temp buffer, in stream mode) in $EDITOR,
# and saving it there triggers less to re-run
# nina-render.sh and redraw - no extra code
# needed for that to work in either mode.
# -----------------------------------------

LESSOPEN="|$SCRIPT_DIR/nina-render.sh %s" less -R "$FILE"

echo

# -----------------------------------------
# Optional link list.
#
# This intentionally does NOT call nina --links:
# that script resolves a title against index.tsv,
# which is exactly what --read must not do (a
# file passed to --read may not be, and is not
# expected to be, part of the knowledge base).
# Instead this does its own lightweight scan
# using only the non-index-aware library helpers
# (extract_links/link_target/normalize_display_title)
# and prints a flat, static list - no interactive
# menu, since these targets are not known to
# resolve to anything.
# -----------------------------------------

if [[ "$SHOW_LINK_LIST" == true ]]; then

    mapfile -t found_links < <(
        extract_links "$FILE" |
        while read -r link; do
            target="$(link_target "$link")"
            target="$(normalize_display_title "$target")"
            printf '%s\n' "$target"
        done |
        dedup_titles
    )

    echo
    if [[ ${#found_links[@]} -eq 0 ]]; then
        echo "No links found in this file."
    else
        echo "---- Links found in this file ----"
        print_numbered_list "${found_links[@]}"
    fi

fi

# -----------------------------------------
# Stream mode only: if the buffer was edited
# (via `v` inside less) and saved, there is no
# original file for that content to live in -
# it came from a pipe. Rather than silently
# discard it, detect the change and offer the
# user an explicit, confirmed place to save it.
#
# This is a deliberate, narrow, user-confirmed
# write of a NEW file the user explicitly names -
# not a rewrite of any existing user content -
# the same character as nina-new.sh's file
# creation, just reached via a different path.
# -----------------------------------------

if [[ "$MODE" == "stream" ]]; then

    if ! cmp -s "$TEMP_FILE" "$ORIG_SNAPSHOT"; then

        warn "This content came from a pipe and has no backing file - it will be lost unless you save it now."

        if : < /dev/tty 2>/dev/null; then

            read -r -p "Save edited content to (Enter to discard): " dest < /dev/tty

            if [[ -z "$dest" ]]; then
                warn "Discarded edited content - no file was written."
            else

                if [[ -e "$dest" ]]; then
                    read -r -p "File exists. Save with a disambiguation suffix instead? (y/n): " ans < /dev/tty
                    if [[ "$ans" =~ ^[Yy]$ ]]; then
                        dest_dir="$(dirname "$dest")"
                        dest_base="$(basename "$dest")"
                        if [[ "$dest_base" == *.* ]]; then
                            dest_stem="${dest_base%.*}"
                            dest_ext=".${dest_base##*.}"
                        else
                            dest_stem="$dest_base"
                            dest_ext=""
                        fi
                        dest="$dest_dir/$(add_disambiguation_suffix "$dest_stem")$dest_ext"
                    else
                        warn "Discarded edited content - no file was written."
                        dest=""
                    fi
                fi

                if [[ -n "$dest" ]]; then
                    if cp "$TEMP_FILE" "$dest"; then
                        info "Saved to: $dest"
                    else
                        error "Could not save to: $dest"
                    fi
                fi
            fi

        else
            warn "No terminal available to confirm a save destination - edited content discarded."
        fi

    fi

fi
