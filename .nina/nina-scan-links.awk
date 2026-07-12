# =====================================================
# nina-scan-links.awk
#
# Extracts [[link]] references from every article in
# the corpus in a single awk process (no per-article or
# per-link subprocess forks).
#
# Invoked by scan_links() in nina-lib.sh as:
#   awk -f nina-scan-links.awk -v index_file=... \
#       -v alias_file=... -v apos=... \
#       -v en_dash=... -v em_dash=... -v minus_s=... \
#       -v ldq=... -v rdq=... -v lsq=... -v rsq=... \
#       /dev/null
#
# /dev/null is passed as awk's input file because all the
# real work happens in BEGIN; awk needs at least one named
# input to start but immediately gets EOF from /dev/null
# and exits cleanly.
#
# The variable `apos` holds a plain ASCII apostrophe. It is
# used as a gsub replacement for curly single quotes, because
# a literal ' inside an awk -f file works fine on its own,
# but this keeps the calling convention identical to before
# (apos was originally needed to avoid ending a bash
# single-quoted program string, which no longer applies now
# that the program lives in its own file - kept anyway so the
# caller in nina-lib.sh does not need to special-case it).
#
# The seven special-character variables (en_dash, em_dash,
# minus_s, ldq, rdq, lsq, rsq) are the UTF-8 byte sequences
# for the dash variants and curly quotes that canonical_title()
# in nina-lib.sh normalizes. They are passed via -v rather than
# embedded as literals here because embedding multi-byte UTF-8
# directly in an awk program can be silently corrupted by
# editing pipelines; printf + octal escapes in the shell
# generates the actual bytes, -v passes them to awk unchanged.
#
# Output: one tab-separated row per unique link, in the form
#   source_display TAB source_canon TAB target_display TAB target_canon
# =====================================================

# -----------------------------------------
# normalize_display(s)
# Collapses runs of whitespace to a single space
# and strips leading/trailing whitespace.
# Equivalent to normalize_display_title() in nina-lib.sh.
# -----------------------------------------
function normalize_display(s) {
    gsub(/[[:space:]]+/, " ", s)
    sub(/^ /,            "",  s)
    sub(/ $/,            "",  s)
    return s
}

# -----------------------------------------
# canonicalize(s)
# Produces the canonical comparison form of a title:
# normalized whitespace, dash variants collapsed to
# ASCII hyphen, curly quotes straightened, lowercased.
# Equivalent to canonical_title() in nina-lib.sh.
#
# Special characters are used as dynamic gsub patterns
# (string variables, not regex literals) - since none
# of their bytes are ASCII regex metacharacters they
# match literally, same as if they were regex literals.
# -----------------------------------------
function canonicalize(s) {
    s = normalize_display(s)
    gsub(en_dash, "-", s)    # en-dash    U+2013
    gsub(em_dash, "-", s)    # em-dash    U+2014
    gsub(minus_s, "-", s)    # minus sign U+2212
    gsub(ldq,  "\"", s)      # left double quote  U+201C
    gsub(rdq,  "\"", s)      # right double quote U+201D
    gsub(lsq,  apos, s)      # left single quote  U+2018
    gsub(rsq,  apos, s)      # right single quote U+2019
    return tolower(s)
}

# -----------------------------------------
# strip_delim(line, delim)
# Removes paired inline code spans (`` or `) from
# a line so that [[links]] written inside code spans
# are not extracted as real links.
# Identical logic to strip_delim() inside
# strip_code_for_link_scan() in nina-lib.sh.
# -----------------------------------------
function strip_delim(line, delim,
                     dlen, start, search_from, close_pos, result, p) {
    dlen   = length(delim)
    result = ""
    while (1) {
        start = index(line, delim)
        if (start == 0) break
        search_from = start + dlen
        close_pos   = 0
        while (1) {
            p = index(substr(line, search_from), delim)
            if (p == 0) break
            p = search_from + p - 1
            if (p == start + dlen) {
                # Adjacent delimiter pair - empty span, skip past it
                search_from = p + dlen
                continue
            }
            close_pos = p
            break
        }
        if (close_pos == 0) break
        result = result substr(line, 1, start - 1)
        line   = substr(line, close_pos + dlen)
    }
    return result line
}

# -----------------------------------------
# process_line(line, src_display, src_canon)
# Scans one article line for [[...]] links after
# code spans have already been stripped, and prints
# one tab-separated output row per unique link:
#   source_display TAB source_canon TAB target_display TAB target_canon
# Deduplication is done here rather than in a
# separate downstream awk pass.
# -----------------------------------------
function process_line(line, src_display, src_canon,
                      pos, open_idx, close_idx, content,
                      pipe_pos, tgt_raw, tgt_display, tgt_canon, key) {
    pos = 1
    while (1) {
        # Locate the next [[ on the line
        open_idx = index(substr(line, pos), "[[")
        if (open_idx == 0) break
        open_idx = pos + open_idx - 1

        # Locate the matching ]]
        close_idx = index(substr(line, open_idx + 2), "]]")
        if (close_idx == 0) break
        close_idx = open_idx + 2 + close_idx - 1

        # Everything between [[ and ]]
        content = substr(line, open_idx + 2, close_idx - (open_idx + 2))

        # [[Display Text|Target Title]] - target is after the pipe
        # [[Target Title]]              - target is the whole content
        pipe_pos = index(content, "|")
        if (pipe_pos > 0)
            tgt_raw = substr(content, pipe_pos + 1)
        else
            tgt_raw = content

        tgt_display = normalize_display(tgt_raw)
        tgt_canon   = canonicalize(tgt_display)

        # De-alias: a link whose target is an alias resolves
        # to the real article it names, so backlinks, dangling,
        # orphan and graph all see the true target rather than
        # the alias. A real title is never a key in this map,
        # so ordinary titles pass through untouched. The map is
        # empty when aliases are off, making this a no-op.
        if (tgt_canon in alias2title) {
            tgt_display = alias2title[tgt_canon]
            tgt_canon   = canonicalize(tgt_display)
        }

        if (tgt_display != "") {
            key = src_display "\t" src_canon "\t" tgt_display "\t" tgt_canon
            if (!seen[key]++)
                print key
        }

        # Advance the cursor past this link before searching for the next
        pos = close_idx + 2
    }
}

# -----------------------------------------
# load_alias_map()
# Populates alias2title[canonical_alias] = real_display_title
# from alias_file (alias TAB title per row). Left as a no-op
# when alias_file is empty (aliases off or index absent), so
# the de-alias step in process_line() never fires and output
# is unchanged with aliases off.
# -----------------------------------------
function load_alias_map(    a_line, acol, a_canon) {
    if (alias_file == "") return
    while ((getline a_line < alias_file) > 0) {
        split(a_line, acol, "\t")
        a_canon = canonicalize(acol[1])
        if (a_canon != "")
            alias2title[a_canon] = normalize_display(acol[2])
    }
    close(alias_file)
}

# -----------------------------------------
# scan_article(file, src_display, src_canon)
# Reads one article file line by line, strips code
# spans and full code-block lines, and hands each
# remaining line to process_line().
# -----------------------------------------
function scan_article(file, src_display, src_canon,    art_line) {
    while ((getline art_line < file) > 0) {
        gsub(/\r/, "", art_line)          # strip Windows CR
        if (art_line ~ /^```/) continue   # skip full code-block lines
        art_line = strip_delim(art_line, "``")  # strip ``double`` spans
        art_line = strip_delim(art_line, "`")   # strip `single` spans
        process_line(art_line, src_display, src_canon)
    }
    close(file)
}

# -----------------------------------------
# scan_index()
# Reads index_file (file TAB title TAB author TAB date TAB
# tags per row) and calls scan_article() for each article.
# -----------------------------------------
function scan_index(    idx_line, cols, file, src_display, src_canon) {
    while ((getline idx_line < index_file) > 0) {
        split(idx_line, cols, "\t")
        file        = cols[1]
        src_display = normalize_display(cols[2])
        src_canon   = canonicalize(src_display)
        scan_article(file, src_display, src_canon)
    }
    close(index_file)
}

BEGIN {
    load_alias_map()
    scan_index()
}
