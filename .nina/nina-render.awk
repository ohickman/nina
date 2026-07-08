BEGIN {
    line_number = 0
}

# -----------------------------------------
# Apply inline styling for a symmetric
# delimiter pair, e.g. '''bold''', ~~strike~~.
#
# Unlike a plain regex such as /X{2}[^X]+X{2}/,
# this correctly handles a single delimiter
# character appearing INSIDE the formatted
# text (e.g. ~~Strik~eout~~), since it searches
# for the closing delimiter as a literal
# substring rather than excluding the delimiter
# character from the content entirely.
#
# A run of delimiter characters immediately
# after the opening delimiter (empty content,
# e.g. the """ in ''''''') is skipped rather
# than treated as a valid close, so adjacent
# separately-formatted regions on the same
# line are not merged into one.
#
# delim:  the delimiter string, e.g. "'''"
# style:  the ANSI style to apply
# reset:  the reset sequence
# Returns the line with all matching spans
# replaced.
# -----------------------------------------
function apply_inline_delim(line, delim, style, reset,    dlen, start, search_from, close_pos, result, p, n_delim) {
    # Guard: a single line built almost entirely out of one delimiter
    # character is never a real formatting span - bail out to the
    # unmodified line rather than let the O(n^2) scan below run on it.
    if (length(line) > 5000 && index(line, delim) > 0) {
        n_delim = gsub(delim, delim, line)   # count occurrences (gsub returns count; line unchanged since replacement == pattern)
        if (n_delim > 500) return line
    }

    dlen = length(delim)
    result = ""

    while (1) {
        start = index(line, delim)
        if (start == 0) break

        search_from = start + dlen
        close_pos = 0

        while (1) {
            p = index(substr(line, search_from), delim)
            if (p == 0) break
            p = search_from + p - 1   # absolute position of this candidate close

            if (p == start + dlen) {
                # Empty content (closing run immediately adjacent to
                # opening) - not a valid close, keep searching past it
                search_from = p + dlen
                continue
            }

            close_pos = p
            break
        }

        if (close_pos == 0) break   # no valid closing delimiter; leave the rest of the line untouched

        result = result substr(line, 1, start - 1) style \
                 substr(line, start + dlen, close_pos - (start + dlen)) reset
        line = substr(line, close_pos + dlen)
    }

    return result line
}

# -----------------------------------------
# Horizontal Rule
# -----------------------------------------
/^---$/ {

    available_width = TERM_WIDTH

    if (ENABLE_LINE_NUMBERS == "true")
        available_width -= 6

    hr = ""
    for (i = 0; i < available_width; i++)
        hr = hr HR_SYMBOL

    styled_hr = HR_STYLE hr RESET

    if (ENABLE_LINE_NUMBERS == "true") {
        line_number++
        printf "%s%4d%s%s%s\n",
            LINE_NUMBER_STYLE,
            line_number,
            RESET,
            LINE_NUMBER_SEPARATOR,
            styled_hr
    } else {
        print styled_hr
    }

    next
}

{
    line = $0

    # Strip raw ESC bytes from the source line before any styling is
    # applied. nina's own ANSI sequences are built later from the
    # *_STYLE variables, not present in $0 here, so this can never
    # remove nina's own output - only escape/OSC bytes that were
    # already present in the note content (e.g. pasted or imported
    # from an untrusted source), which `less -R` would otherwise pass
    # straight through to the real terminal.
    gsub(/\033/, "", line)

    is_full_code = 0
    line_number++

    # Reset per-line state
    delete literal_store
    delete code_blocks
    delete code_placeholders

    is_done = 0

    #################################
    # COMMENT REMOVAL
    #################################

    original_line = line

    while (match(line, /\/%([^%]|%[^/])*%\//)) {
        prefix = substr(line, 1, RSTART-1)
        suffix = substr(line, RSTART+RLENGTH)
        line = prefix suffix
    }

    if (line != original_line) {
        temp = line
        gsub(/[[:space:]]+/, "", temp)
        if (temp == "")
            next
    }

    #################################
    # BLOCK-LEVEL TRANSFORMS
    #################################

	# Full-line code block
	#if (line ~ /^```[ ]?/) {
	#	text = substr(line, 4)
	#	line = CODE_STYLE text RESET
	#	is_full_code = 1
	#}

	if (line ~ /^```[ ]?/) {
		text = substr(line, 4)
		line = CODE_STYLE text RESET

		# Jump directly to print section
		if (ENABLE_LINE_NUMBERS=="true") {
		    printf "%s%4d%s%s%s\n",
		        LINE_NUMBER_STYLE,
		        line_number,
		        RESET,
		        LINE_NUMBER_SEPARATOR,
		        line
		} else {
		    print line
		}

		next
	}


    if (line ~ /^(INFO|NOTE|TIP|TODO|FIXME|WARNING):/) {
        split(line, parts, ":")
        tag = parts[1]
        rest = substr(line, length(tag)+2)

        if (tag == "INFO")    style = INFO_STYLE
        if (tag == "NOTE")    style = NOTE_STYLE
        if (tag == "TIP")     style = TIP_STYLE
        if (tag == "TODO")    style = TODO_STYLE
        if (tag == "FIXME")   style = FIXME_STYLE
        if (tag == "WARNING") style = WARNING_STYLE

        line = style tag ":" RESET " " rest
    }

    # Headers
    else if (line ~ /^###### /) line = H6_STYLE substr(line,8) "  " RESET
    else if (line ~ /^##### /)  line = H5_STYLE substr(line,7) "  " RESET
    else if (line ~ /^#### /)   line = H4_STYLE substr(line,6) "  " RESET
    else if (line ~ /^### /)    line = H3_STYLE substr(line,5) "  " RESET
    else if (line ~ /^## /)     line = H2_STYLE substr(line,4) "  " RESET
    else if (line ~ /^# /)      line = H1_STYLE substr(line,3) "  " RESET
    else if (line ~ /^- /)      line = SUBTITLE_STYLE substr(line,3) RESET


    # Nested checklist depth is indicated by leading '-' characters:
    # [ ] task
    # -[ ] subtask
    # --[ ] deeper task

	# To-do - incomplete
    else if (match(line, /^(-*)[ ]*\[[ ]*\][ ]+/)) {

        prefix = substr(line, RSTART, RLENGTH)
        depth = gsub("-", "", prefix)

        indent = " "
        for (i = 0; i < depth; i++)
            indent = indent "  "

        line = indent TODO_SYMBOL "  " substr(line, RLENGTH+1)
    }
    #else if (match(line, /^\[[ ]*\][ ]+/)) {
    #    line = " " TODO_SYMBOL "  " substr(line, RLENGTH+1)
    #}

    # To-do - done
    else if (match(line, /^(-*)[ ]*\[[xX][ ]*\][ ]+/)) {

        prefix = substr(line, RSTART, RLENGTH)
        depth = gsub("-", "", prefix)

        indent = " "
        for (i = 0; i < depth; i++)
            indent = indent "  "

        line = indent DONE_SYMBOL "  " substr(line, RLENGTH+1)
        is_done = 1
    }
    #else if (match(line, /^\[[xX][ ]*\][ ]+/)) {
    #    line = " " DONE_SYMBOL "  " substr(line, RLENGTH+1)
    #    is_done = 1
    #}

    # Bulleted lists
    else if (line ~ /^\*{1,15}[ ]+/) {
        match(line, /^\*+/)
        level = RLENGTH
        text = substr(line, level+2)

        indent = " "
        for (i=1;i<level;i++) indent = indent "  "

        line = indent BULLET_SYMBOL " " text
    }

    # Numbered lists
    else if (line ~ /^[0-9]+\./) {
        match(line, /^[0-9]+\./)
        number = substr(line, RSTART, RLENGTH)
        rest = substr(line, RLENGTH+2)
        line = " " number "  " rest
    }

    # Block quote
    else if (line ~ /^>{1,5}[ ]+/) {
        match(line, /^>+/)
        level = RLENGTH
        text = substr(line, level+2)

        indent = "    │ "
        for (i=1;i<level;i++) indent = indent "   │ "

        line = BLOCK_QUOTE_STYLE indent text RESET
    }

    # Definition list - items
    else if (line ~ /^; /)
        line = ITEM_STYLE substr(line,3) RESET

    # Definiition list definitions - deep indent
    else if (line ~ /^:+[ ]+/) {
        match(line, /^:+/)
        level = RLENGTH
        text = substr(line, level+2)

        indent = ""
        for (i=0; i<level; i++) indent = indent DEFINITION_STYLE

        line = indent text RESET
    }


    #################################
    # INLINE PROTECTION
    #################################

    literal_count = 0
    code_count = 0

    # Match and protect string literals
    while (1) {
        start = index(line, "``")
        if (start == 0) break

        search_from = start + 2
        close_pos = 0

        while (1) {
            p = index(substr(line, search_from), "``")
            if (p == 0) break
            p = search_from + p - 1

            if (p == start + 2) {
                search_from = p + 2
                continue
            }

            close_pos = p
            break
        }

        if (close_pos == 0) break

        literal = substr(line, start + 2, close_pos - (start + 2))
        placeholder = "\034L" literal_count "\035"
        literal_store[placeholder] = literal
        line = substr(line, 1, start - 1) placeholder substr(line, close_pos + 2)
        literal_count++
    }

    # Match and protect inline code
    while (1) {
        start = index(line, "`")
        if (start == 0) break

        search_from = start + 1
        close_pos = 0

        while (1) {
            p = index(substr(line, search_from), "`")
            if (p == 0) break
            p = search_from + p - 1

            if (p == start + 1) {
                search_from = p + 1
                continue
            }

            close_pos = p
            break
        }

        if (close_pos == 0) break

        code_text = substr(line, start + 1, close_pos - (start + 1))
        placeholder = "\034C" code_count "\035"
        code_blocks[code_count] = code_text
        code_placeholders[code_count] = placeholder
        line = substr(line, 1, start - 1) placeholder substr(line, close_pos + 1)
        code_count++
    }

    #################################
    # HTML CHaracter / Entity handling
    #################################

    line = replace_entities(line)

    #################################
    # INLINE TRANSFORMS
    #################################

    #################################
    # MACROS (see nina-macros.awk)
    #################################

    line = expand_macros(line)

    # Bold
    line = apply_inline_delim(line, "'''", BOLD_STYLE, RESET)
    line = apply_inline_delim(line, "**", BOLD_STYLE, RESET)

    # Italic
    line = apply_inline_delim(line, "''", ITALIC_STYLE, RESET)
    line = apply_inline_delim(line, "//", ITALIC_STYLE, RESET)
    line = apply_inline_delim(line, "*", ITALIC_STYLE, RESET)

    # Highlight
    line = apply_inline_delim(line, "==", HIGHLIGHT_STYLE, RESET)

    # Strikeout
    line = apply_inline_delim(line, "~~", STRIKEOUT_STYLE, RESET)

    # Delete style
    line = apply_inline_delim(line, "--", DELETE_STYLE, RESET)

    # Insert style
    line = apply_inline_delim(line, "++", INSERT_STYLE, RESET)

    # Underline style
    line = apply_inline_delim(line, "__", UNDERLINE_STYLE, RESET)

	# Internal links [[display|Article]] or [[Article]]
	while (match(line, /\[\[[^]]+\]\]/)) {

		full = substr(line, RSTART+2, RLENGTH-4)

		# Determine display text
		if (index(full, "|")) {
		    split(full, parts, "|")
		    display = parts[1]
		} else {
		    display = full
		}

		replacement = LINK_STYLE display RESET

		line = substr(line, 1, RSTART-1) \
		       replacement \
		       substr(line, RSTART+RLENGTH)
	}

    # External links
    while (match(line, /\[[^]]+\]\(/)) {

        start = RSTART
        prefix = substr(line, 1, start-1)

        full = substr(line, start)

        # extract link text
        match(full, /^\[([^]]+)\]\(/)
        text = substr(full, 2, RLENGTH-3)

        url_start = RLENGTH + 1

        depth = 1
        i = url_start

        while (i <= length(full) && depth > 0) {
            c = substr(full, i, 1)

            if (c == "(")
                depth++
            else if (c == ")")
                depth--

            i++
        }

        url = substr(full, url_start, i-url_start-1)

        rest = substr(full, i)

        replacement = LINK_STYLE text " (" url ")" RESET

        line = prefix replacement rest
    }

    #################################
    # RESTORE PROTECTED SPANS
    #################################

    for (i=0;i<code_count;i++)
        gsub(code_placeholders[i], CODE_STYLE code_blocks[i] RESET, line)

    for (key in literal_store)
        gsub(key, literal_store[key], line)

    #################################
    # DONE TODO FINAL STYLE
    #################################

    if (is_done) {
        gsub(/\033\[[0-9;]+m/, "", line)
        line = TODO_DONE_STYLE line RESET
    }

    #################################
    # PRINT
    #################################

    if (ENABLE_LINE_NUMBERS=="true") {
        printf "%s%4d%s%s%s\n",
            LINE_NUMBER_STYLE,
            line_number,
            RESET,
            LINE_NUMBER_SEPARATOR,
            line
    } else {
        print line
    }

    next
}
