# =====================================================
# nina-plugin-api.awk
#
# Loaded alongside every plugin file, in the plugin's own
# fresh subprocess (see run_plugin() in nina-plugins.awk).
# This file is NOT subject to the plugin source
# restrictions enforced by validate_plugin_file (no
# system(), no getline, no redirected print/printf) - it is
# trusted nina code, the same as nina-render.awk or
# nina-macros.awk, and it is the ONLY code in this entire
# environment permitted to reach outside the current
# process.
#
# A plugin file calls these functions; it never constructs
# a shell command, opens a file by path, or touches the
# network on its own - those primitives are unavailable to
# it by the install-time checks in validate_plugin_file.
# Whatever capability a plugin has, it has it through one
# of the functions below.
# =====================================================

# -----------------------------------------
# Courtesy check only - NOT enforcement. A
# well-behaved plugin checks this first and
# skips network work entirely if false, to
# avoid wasted effort. plugin_http_get()
# re-checks PLUGIN_PERMIT_WEB itself
# regardless of whether this was called, so
# skipping this check costs a plugin
# performance, never safety.
# -----------------------------------------

function plugin_web_allowed() {
    return (ENVIRON["PLUGIN_PERMIT_WEB"] == "true") ? 1 : 0
}

# -----------------------------------------
# The only function in the plugin
# environment that can reach the network.
# Returns "" if web access is disallowed,
# the URL doesn't look like http(s), or the
# request fails or times out.
#
# Two independent protections, not one:
#   - shquote(url) prevents the value from
#     being interpreted by the shell
#   - the scheme check, plus "--" placed
#     before the URL in the curl invocation,
#     prevent curl itself from treating a
#     leading "-" as an option flag
# Shell-safety and argument-safety are
# different problems with different fixes -
# escaping the shell does not stop curl from
# reading "-o /etc/passwd" as two flags
# instead of one URL string.
# -----------------------------------------

function plugin_http_get(url,    cmd) {
    if (!plugin_web_allowed()) return ""
    if (url !~ /^https?:\/\//) return ""

    cmd = "curl -fsSL --max-time 5 -- " shquote(url) " 2>/dev/null"
    return slurp_cmd(cmd)
}

# -----------------------------------------
# The only function that can reach the rest
# of the knowledge base beyond the current
# article. "verb" must match one of a fixed
# set of literal strings, checked by exact
# equality (never a pattern match) before it
# is used for anything - so even though it
# is concatenated into a command below, its
# value is always provably one of these five
# harmless constants, never arbitrary text.
#
# "arg" (e.g. an article title) never
# touches that command line at all - it is
# written to a private temp file and read
# back by nina-plugin-helper.sh, the same
# "untrusted text only travels as file
# content" rule used throughout this system.
# -----------------------------------------

function plugin_call_nina(verb, arg,    argfile, cmd, result) {
    if (verb != "--backlinks" && verb != "--tags" &&
        verb != "--links"     && verb != "--read" &&
        verb != "--read-body") {
        return ""
    }

    argfile = make_tmp_path()
    print arg > argfile
    close(argfile)

    cmd = "NINA_ARG_FILE=" shquote(argfile) " " shquote(ENVIRON["NINA_PLUGIN_HELPER"]) " " verb

    result = slurp_cmd(cmd)
    system("rm -f " shquote(argfile))
    return result
}

# Convenience wrappers over plugin_call_nina(), named for
# what they do rather than the verb they happen to map to.

function plugin_backlinks(title)         { return plugin_call_nina("--backlinks", title) }
function plugin_tags(title)              { return plugin_call_nina("--tags",      title) }
function plugin_links(title)             { return plugin_call_nina("--links",     title) }
function plugin_read_article(title)      { return plugin_call_nina("--read",      title) }
function plugin_read_article_body(title) { return plugin_call_nina("--read-body", title) }

# -----------------------------------------
# The plugin's own <<name args>> argument
# string, read from the temp file
# nina-plugins.awk wrote it to - never via
# -v, since -v applies POSIX backslash-
# escape processing to its value and this
# string originates from article text nina
# does not get to silently reinterpret.
# -----------------------------------------

function plugin_args() {
    return slurp_file(ENVIRON["PLUGIN_ARGS_FILE"])
}

function plugin_current_file()  { return ENVIRON["CURRENT_FILE"] }
function plugin_current_title() { return ENVIRON["CURRENT_TITLE"] }

# -----------------------------------------
# The current date/time, in the same format
# macros already get via {{date}}/{{time}} -
# AWK has no portable way for a plugin to
# find this out on its own (systime()/
# strftime() are gawk-only and unavailable
# in mawk, and system()/getline are banned
# in plugin source), so nina computes it
# once, in the bash layer, the same as it
# already does for macros, and forwards it
# down through the environment.
# -----------------------------------------

function plugin_today() { return ENVIRON["TODAY"] }
function plugin_now()   { return ENVIRON["NOW"] }

# -----------------------------------------
# The terminal width nina computed for this
# render, in case a plugin wants to size its
# own output to it (a horizontal rule, a
# simple chart). Forwarded the same way as
# TODAY/NOW - already computed once in the
# bash layer, costs nothing extra to pass
# down here too.
# -----------------------------------------

function plugin_term_width() { return ENVIRON["TERM_WIDTH"] }

# -----------------------------------------
# Print a diagnostic message while writing a
# plugin, without it becoming part of the
# rendered article. A plugin file cannot do
# this on its own - any form of redirected
# print/printf is exactly what
# validate_plugin_file refuses to install, so
# there was previously no way to look at
# anything while debugging a plugin without
# it leaking into the document. This function
# lives in trusted code, not plugin source,
# so it's allowed to do what a plugin itself
# cannot: write to stderr instead of stdout.
# -----------------------------------------

function plugin_debug(msg) {
    print "[DEBUG] " msg | "cat 1>&2"
    close("cat 1>&2")
}

# -----------------------------------------
# Shared helpers - duplicated in
# nina-plugins.awk. The two files always run
# in separate AWK processes (this one only
# ever runs inside a plugin's own
# subprocess), so there is no shared-
# namespace collision risk in keeping a
# second small copy of each rather than
# adding a third -f file just for these.
#
# slurp_cmd()/slurp_file() read all output
# in a single getline call rather than line
# by line with repeated string concatenation,
# which is genuinely quadratic under mawk for
# large multi-line output (measured: ~18s for
# 100,000 lines the loop way, ~0.015s this
# way) - see the matching comment in
# nina-plugins.awk for the full explanation.
# This matters here specifically because
# plugin_read_article()/plugin_read_article_body()
# can return an arbitrarily large article, and
# plugin_http_get() can return an arbitrarily
# large response body.
# -----------------------------------------

function shquote(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

function slurp_cmd(cmd,    save_rs, content, got) {
    save_rs = RS
    RS = "\004\004NINA_PLUGIN_RS_SENTINEL\004\004"
    got = (cmd | getline content)
    close(cmd)
    RS = save_rs
    if (got <= 0) return ""
    sub(/\n$/, "", content)
    return content
}

function slurp_file(file,    save_rs, content, got) {
    if (file == "") return ""
    save_rs = RS
    RS = "\004\004NINA_PLUGIN_RS_SENTINEL\004\004"
    got = (getline content < file)
    close(file)
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
