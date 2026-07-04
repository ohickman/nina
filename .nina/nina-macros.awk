# =====================================================
# nina-macros.awk
#
# THE MACRO CONTRACT
# -------------------
# A macro is written as {{name}} or {{name arg1 arg2 ...}}
# in an article. "name" is the first whitespace-separated
# token inside the braces; everything after it is passed
# to the macro as a single argument string.
#
# Each macro is one pure function: text in, text out. A
# macro never has side effects, never holds state between
# calls, and never invokes another macro. This is
# deliberately NOT a scripting environment.
#
# An unrecognized macro name is left untouched as literal
# text, not treated as an error - same graceful-degradation
# principle the rest of nina follows for malformed input.
#
# THIS FILE only contains the generic mechanics of finding
# {{...}} in a line and handing it off to dispatch_macro().
# It deliberately contains NO macro-specific logic and NO
# hardcoded list of macro names - those live elsewhere:
#
#   - Macros themselves are individual files in MACROS_DIR
#     (default ~/.nina/macros). Each file is plain AWK,
#     whose first line must be a comment declaring the
#     macro's name (e.g. "# |" or "# date") - everything
#     after "#" on that line, trimmed, is the name a user
#     types in {{...}}. The file must define a function
#     named macro_<sanitized-filename>, e.g. a file named
#     progress-bar.awk must define macro_progress_bar.
#
#   - `nina --macro` (nina-macros.sh) scans MACROS_DIR,
#     validates each file, and writes a manifest
#     (~/.nina/macros.tsv) of name/function/filepath for
#     every macro that passed validation. This step is not
#     interactive and never repairs anything - same
#     contract as `nina --index`.
#
#   - nina-render.sh reads that manifest at render time and
#     generates the actual dispatch_macro() function from
#     it (a name == "x" / call-the-function chain), since
#     AWK has no mechanism for indirect/dynamic function
#     calls - some piece of code has to name every callable
#     function explicitly, and that code is generated, not
#     hand-maintained, so adding a macro never requires
#     editing this file or any chain by hand.
#
# TO ADD A NEW MACRO:
#   Drop a new, valid .awk file into MACROS_DIR, then run
#   `nina --macro`. Nothing in this file ever needs to
#   change.
#
# A NOTE ON HELPER FUNCTIONS:
#   AWK has one single global function namespace across
#   every loaded file - there is no per-file privacy. A
#   macro file may define helper functions freely, but if
#   two different macro files happen to define a
#   same-named helper, loading both will break the entire
#   program, not just one macro. The filename-derived
#   entry-point naming convention avoids this for entry
#   points; it cannot protect against two authors choosing
#   the same name for a private helper. Prefix your helpers
#   defensively (e.g. with your macro's own name) if you
#   write more than a trivial one-function macro.
# =====================================================

# -----------------------------------------
# Expand all macros found in `line`.
# Call this once per line from nina-render.awk.
#
# Unrecognized macros are swapped for a
# placeholder during expansion (not left in
# place), then restored to their original
# literal text afterward - otherwise the
# {{...}} text would still match the same
# while loop's pattern on the next pass and
# loop forever.
#
# dispatch_macro(name, args) is NOT defined in
# this file - it is generated at render time
# from the macro manifest. See nina-render.sh.
# -----------------------------------------

function expand_macros(line,    start, full, inner, n, parts, name, args, i, replacement, unknown_count, unknown_placeholders, key) {
    unknown_count = 0
    delete unknown_placeholders

    while (match(line, /\{\{[^}]*\}\}/)) {
        full = substr(line, RSTART, RLENGTH)
        inner = substr(line, RSTART + 2, RLENGTH - 4)

        n = split(inner, parts, " ")
        name = parts[1]

        args = ""
        for (i = 2; i <= n; i++)
            args = args (i > 2 ? " " : "") parts[i]

        replacement = dispatch_macro(name, args)

        if (replacement == "\001UNKNOWN\001") {
            key = "\034M" unknown_count "\035"
            unknown_placeholders[key] = full
            replacement = key
            unknown_count++
        }

        line = substr(line, 1, RSTART - 1) replacement substr(line, RSTART + RLENGTH)
    }

    for (key in unknown_placeholders)
        gsub(key, unknown_placeholders[key], line)

    return line
}
