# =====================================================
# nina-plugins.awk
#
# THE PLUGIN CONTRACT
# --------------------
# A plugin is written as <<name>> or <<name arg1 arg2 ...>>
# in an article. "name" is the first whitespace-separated
# token inside the angle brackets; everything after it is
# passed to the plugin as a single argument string, via
# plugin_args() in nina-plugin-api.awk - never via -v,
# since -v applies POSIX backslash-escape processing to
# its value, and this string originates from article text
# nina does not get to silently reinterpret.
#
# Unlike a {{macro}}, a plugin is not a function called
# inside this process - it is a complete, separate AWK
# program, run as its own fresh subprocess for every single
# invocation, with the article being rendered supplied on
# its stdin. Whatever that subprocess prints to its own
# stdout (unredirected - redirected print/printf is one of
# the things validate_plugin_file refuses to install)
# becomes the replacement text.
#
# Scanning is a single left-to-right pass per line,
# advancing a cursor past each <<...>> as it is handled -
# whether that call is replaced (recognized plugin name) or
# left as literal text (unrecognized name). Because the
# cursor never revisits text it has already passed, no
# placeholder/restore step is needed here the way {{}}
# expansion needs one in nina-macros.awk's expand_macros()
# (that loop re-searches the whole line from the start on
# every iteration, so an unrecognized {{...}} would be
# found again on the next pass if it weren't temporarily
# swapped out first).
#
# A plugin's own output is NOT re-scanned for further
# <<...>> calls - same "no recursion" rule {{}} macros
# already follow. Any {{...}} found inside a plugin's
# output, by contrast, IS expanded normally, since
# nina-macros.awk's expand_macros() runs downstream over
# the line as a whole, after this file's rule has already
# substituted the plugin's text into it.
#
# This file is trusted nina code, the same as
# nina-render.awk or nina-macros.awk - it is not subject to
# the system()/getline/redirected-print restrictions that
# validate_plugin_file enforces on files in PLUGINS_DIR.
# That restriction exists for plugin *source*, not for the
# program that runs plugins.
# =====================================================

BEGIN {
    if (PLUGINS_MANIFEST != "") {
        while ((getline pline < PLUGINS_MANIFEST) > 0) {
            if (pline == "" || pline ~ /^#/) continue
            split(pline, pcols, "\t")
            plugin_file[pcols[1]] = pcols[2]
            plugin_long_timeout[pcols[1]] = (pcols[3] == "1")
            plugin_hash[pcols[1]] = pcols[4]
        }
        close(PLUGINS_MANIFEST)
    }
}

{
    # A line beginning with three backticks is a protected
    # code line in nina-render.awk's own rules (see the
    # /^```[ ]?/ check there, which short-circuits straight to
    # printing before macro expansion ever runs on that line).
    # Plugin expansion has to honor the exact same check here,
    # independently, since this rule runs as its own pass
    # before nina-render.awk ever sees the line - without this,
    # a line demonstrating literal <<plugin>> syntax inside a
    # code example would be genuinely expanded rather than
    # shown as written, the same failure mode macros are
    # already protected against.
    if ($0 !~ /^```[ ]?/)
        $0 = expand_plugins($0)

    # This file now runs as its own standalone process (see
    # nina-render.sh), piping its output into a fresh awk
    # invocation that loads nina-render.awk - not combined
    # with it in one shared process the way it used to be.
    # That second process is what re-reads this output as
    # genuine, separate input records, which is the entire
    # point of the split: a multi-line plugin result spliced
    # into $0 as one string with embedded newlines is still
    # only ONE record as far as anything checking ^ in this
    # process is concerned. Printing it here and letting the
    # next process read it fresh is what turns each embedded
    # line back into something nina-render.awk's per-record,
    # ^-anchored rules (headers, bullets, etc.) can see and
    # style individually, the same as if a person had typed
    # each line directly into the article.
    print
}

# -----------------------------------------
# Expand all <<...>> plugin calls found in
# `line`. Call this once per line, before
# nina-render.awk's own rules run, so any
# styling and {{}} expansion happens on the
# already-substituted text.
# -----------------------------------------

function expand_plugins(line,    masked, result, pos, open_idx, close_idx, full, inner, n, parts, name, args, i, plugin_result) {
    masked = mask_protected_regions(line)

    result = ""
    pos = 1

    while (1) {
        open_idx = index(substr(masked, pos), "<<")

        if (open_idx == 0) {
            result = result substr(line, pos)
            break
        }

        open_idx = pos + open_idx - 1

        close_idx = index(substr(masked, open_idx + 2), ">>")

        if (close_idx == 0) {
            # No closing ">>" anywhere after this point on the
            # line - everything from here on is literal text.
            result = result substr(line, pos)
            break
        }

        close_idx = open_idx + 2 + close_idx - 1

        # Copy through everything before the "<<" untouched -
        # from the real line, never from the masked copy.
        result = result substr(line, pos, open_idx - pos)

        full  = substr(line, open_idx, close_idx + 2 - open_idx)
        inner = substr(line, open_idx + 2, close_idx - (open_idx + 2))

        n = split(inner, parts, " ")
        name = parts[1]

        args = ""
        for (i = 2; i <= n; i++)
            args = args (i > 2 ? " " : "") parts[i]

        if (name in plugin_file) {
            plugin_result = run_plugin(name, args)
            # A failed or timed-out plugin is treated exactly like
            # an unrecognized name: the call is left as literal
            # text, never silently replaced with empty output.
            result = result ((plugin_result == "\001PLUGIN_FAILED\001") ? full : plugin_result)
        } else {
            result = result full   # unrecognized name - leave as literal text
        }

        pos = close_idx + 2   # advance past this call; never revisit it
    }

    return result
}

# -----------------------------------------
# Build a same-length copy of `line` with every
# hidden comment, double-backtick literal span,
# and single-backtick code span filled with "#"
# characters - used only to decide where real
# "<<"/">>" tokens are; the real text is always
# read from the original line, never from this
# copy. "#" can never combine into "<" or ">",
# so nothing inside a masked span can ever be
# mistaken for a plugin call boundary, and
# nothing outside one is touched.
#
# Mirrors three matching rules nina-render.awk
# already applies downstream - this file runs
# before any of them ever see the line, so none
# of that protection exists yet at this point
# unless it's independently replicated here:
#   - hidden comments are deleted entirely
#     (the /%([^%]|%[^/])*%\/ regex, exact copy)
#   - double backticks ("literal" spans) are
#     matched first
#   - single backticks (code spans) are matched
#     second, in that order, for the same reason
#     nina-render.awk orders them this way: doing
#     single backticks first would let a double-
#     backtick pair be misread as two singles
# Lengths, not styling or storage, are all that
# matter here, so the matching loops below are
# simplified to find-and-mask only.
# -----------------------------------------

function mask_protected_regions(line,    masked, fill, start, search_from, close_pos, p) {
    masked = line

    while (match(masked, /\/%([^%]|%[^\/])*%\//)) {
        fill = make_fill(RLENGTH)
        masked = substr(masked, 1, RSTART - 1) fill substr(masked, RSTART + RLENGTH)
    }

    while (1) {
        start = index(masked, "``")
        if (start == 0) break

        search_from = start + 2
        close_pos = 0

        while (1) {
            p = index(substr(masked, search_from), "``")
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

        fill = make_fill(close_pos + 2 - start)
        masked = substr(masked, 1, start - 1) fill substr(masked, close_pos + 2)
    }

    while (1) {
        start = index(masked, "`")
        if (start == 0) break

        search_from = start + 1
        close_pos = 0

        while (1) {
            p = index(substr(masked, search_from), "`")
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

        fill = make_fill(close_pos + 1 - start)
        masked = substr(masked, 1, start - 1) fill substr(masked, close_pos + 1)
    }

    return masked
}

function make_fill(n,    s, i) {
    s = ""
    for (i = 0; i < n; i++) s = s "#"
    return s
}

# -----------------------------------------
# Run a single plugin as its own fresh AWK
# subprocess and capture its stdout as the
# replacement text.
#
# The plugin's own arguments are written to
# a private temp file rather than embedded
# into the constructed shell command line -
# article text never becomes part of a shell
# string anywhere in this system; it only
# ever travels as file content, or as a
# value already safely inside the process
# environment.
#
# Deliberately NOT piped through "| head -c"
# the way an earlier version of this function
# did: close()'s exit status on a piped
# command reflects only the LAST stage of the
# pipe, so a timed-out or crashed plugin's
# real exit status would be masked by head's
# own (almost always successful) exit code.
# The byte cap is instead applied to the
# already-captured string below, which keeps
# the exit status meaningful and lets a
# failed/timed-out invocation be told apart
# from a successful one that simply produced
# a lot of text.
# -----------------------------------------

function run_plugin(name, args,    argfile, timeout_secs, cmd, result, status, current_hash) {
    # -----------------------------------------
    # Refuse to run a plugin whose file has
    # changed since it was last validated.
    # Installing records a hash of exactly the
    # bytes that were checked; a path on disk
    # can be edited or replaced afterward with
    # no way for the manifest alone to notice -
    # this closes that gap by re-checking at the
    # one moment it actually matters, right
    # before the file would run, rather than
    # only when nina --plugin happens to be run
    # again. Treated exactly like any other
    # failed invocation: literal text stays,
    # nothing executes, a warning explains why.
    # -----------------------------------------

    current_hash = file_hash(plugin_file[name])

    if (current_hash == "" || current_hash != plugin_hash[name]) {
        warn_plugin_hash_mismatch(name)
        return "\001PLUGIN_FAILED\001"
    }

    timeout_secs = plugin_long_timeout[name] ? PLUGIN_TIMEOUT : PLUGIN_NO_WEB_TIMEOUT

    argfile = make_tmp_path()
    print args > argfile
    close(argfile)

    cmd = "PLUGIN_ARGS_FILE=" shquote(argfile) \
        " PLUGIN_PERMIT_WEB=" shquote(PLUGIN_PERMIT_WEB) \
        " CURRENT_FILE="       shquote(CURRENT_FILE) \
        " CURRENT_TITLE="      shquote(CURRENT_TITLE) \
        " TODAY="              shquote(TODAY) \
        " NOW="                shquote(NOW) \
        " TERM_WIDTH="         shquote(TERM_WIDTH) \
        " NINA_PLUGIN_HELPER=" shquote(NINA_PLUGIN_HELPER) \
        " timeout " timeout_secs \
        " sh -c " shquote("ulimit -v " PLUGIN_MAX_MEMORY_KB " 2>/dev/null; exec awk -f " shquote(API_FILE) " -f " shquote(plugin_file[name])) \
        " < " shquote(CURRENT_FILE)

    result = slurp_cmd(cmd)
    status = LAST_SLURP_STATUS

    system("rm -f " shquote(argfile))

    if (status != 0) {
        warn_plugin_failure(name, status)
        return "\001PLUGIN_FAILED\001"
    }

    if (length(result) > PLUGIN_MAX_OUTPUT_BYTES)
        result = substr(result, 1, PLUGIN_MAX_OUTPUT_BYTES)

    return result
}

# -----------------------------------------
# Diagnostic only - never written into the
# rendered document. Distinguishes a timeout
# (124, the exit status `timeout` itself uses
# when it had to kill the process) from any
# other nonzero exit, so the message in the
# terminal is specific without that detail
# ever reaching an article.
# -----------------------------------------

function warn_plugin_failure(name, status,    msg) {
    msg = "[WARN]  nina-plugins: plugin '" name "' "
    msg = msg (status == 124 ? "timed out" : "exited with status " status)
    print msg | "cat 1>&2"
    close("cat 1>&2")
}

# -----------------------------------------
# sha256sum's own output is "HASH  filename" -
# only the first field is needed here. Returns
# "" if the file can't be read at all (e.g. it
# was deleted after installation), which the
# caller treats the same as a mismatch - no
# hash to compare against is not a pass.
# -----------------------------------------

function file_hash(file,    cmd, line, parts) {
    cmd = "sha256sum " shquote(file) " 2>/dev/null"
    if ((cmd | getline line) > 0) {
        close(cmd)
        split(line, parts, " ")
        return parts[1]
    }
    close(cmd)
    return ""
}

function warn_plugin_hash_mismatch(name,    msg) {
    msg = "[WARN]  nina-plugins: plugin '" name "' has changed since it was installed (hash mismatch) - run nina --plugin to re-validate it"
    print msg | "cat 1>&2"
    close("cat 1>&2")
}

# -----------------------------------------
# Shared helpers - duplicated in
# nina-plugin-api.awk rather than split into
# a third -f file. The two files always run
# in separate AWK processes (this one only
# ever runs in the main render process; that
# one only ever runs inside a plugin's own
# subprocess), so there is no shared-
# namespace collision risk in keeping a
# second small copy of each.
# -----------------------------------------

function shquote(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

# -----------------------------------------
# Read all of a subprocess's stdout in a
# single getline call, rather than line by
# line with repeated string concatenation.
#
# Concatenating onto a string in a loop
# ("result = result line") forces some AWK
# implementations to copy the whole
# accumulated string on every iteration -
# under mawk this is genuinely quadratic
# (measured: ~18s to assemble 100,000 lines
# the loop way, ~0.015s the way below for
# the same data). Since a plugin's output
# size is bounded only by PLUGIN_MAX_OUTPUT_BYTES,
# not by line count, this is not a
# theoretical concern - a plugin like
# Backlinks on a heavily-linked article, or
# TOC on a long document, can plausibly
# produce enough lines to trigger it.
#
# The technique: set RS to a string that
# cannot appear in real output, so a single
# getline reads everything up to EOF as one
# record, with the original newlines already
# embedded in it as ordinary characters - no
# rejoining needed afterward. The trailing
# newline a plugin's last print() leaves
# behind is trimmed for parity with the
# previous line-by-line behavior, which never
# added a separator after the final line.
#
# LAST_SLURP_STATUS is set as a side effect
# (close()'s exit status) since the single
# getline call here doesn't have an obvious
# place to also return it.
# -----------------------------------------

function slurp_cmd(cmd,    save_rs, content, got) {
    save_rs = RS
    RS = "\004\004NINA_PLUGIN_RS_SENTINEL\004\004"
    got = (cmd | getline content)
    LAST_SLURP_STATUS = close(cmd)
    RS = save_rs
    if (got <= 0) return ""
    sub(/\n$/, "", content)
    return content
}

function make_tmp_path(    cmd, p) {
    cmd = "mktemp 2>/dev/null"
    cmd | getline p
    close(cmd)
    return p
}
