# Nina - Devs: Plugins
- Tags: nina dev plugins

# Purpose of This Document
This is the architecture and API reference for plugins, aimed at developers - both authoring plugins and modifying the plugin engine itself. For the user-facing contract - what plugins are, how to install one, what ships by default - see [[Nina - User: Macros and Plugins]]. This document assumes you've read that and [[Nina - Devs: Macros]], since plugins are easiest to understand as "what a macro can't do, and why that gap needed closing carefully."

---

# Why Plugins Are a Separate System, Not an Extension of Macros
[[Nina - Devs: Design Philosophy|Nina - Devs: Design Philosophy#Developer Guidelines]] and [[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Where Logic Should Live]] both place "user-installable rendering behavior" in its own category, distinct from program logic, library logic, and configuration - the same starting point [[Nina - Devs: Macros|Nina - Devs: Macros#Why Macros Exist As Their Own Category]] argues from for macros specifically.
A macro only ever sees the argument text typed after its own name - it cannot read another article and cannot touch the network. A plugin can do both, and can never write to anything. That's not a convention plugin authors are asked to follow; it's enforced at install time, before a plugin file is ever allowed to run.

Given that bigger capability surface, plugins are written `<<name>>` rather than `{{name}}`, so the two are never ambiguous in an article's source, and a plugin's safety model is built from first principles rather than reusing the macro system's - the things that make a macro safe (it can only transform text it was handed) don't apply once network and corpus access exist.

---

# The Capability Model

* '''No write primitive exists, anywhere.''' Not a setting that happens to be off - there is no code path that allows it.
* '''A plugin file may not contain''' `system(`, `getline` '''in any form, or a''' `print`'''/'''`printf` '''statement with''' `>`''',''' `>>`''', or''' `|` '''redirection.''' These three constructs are the only native ways an AWK program can reach the filesystem or another process. Closing all three turns "does this plugin reach outside the sandbox" from a guess into a fact - the only way out left is whichever function the trusted API provides.
* '''Corpus access is title-based, not path-based.''' `plugin_read_article()` and its relatives resolve through the same `canonical_title`/`find_article_file` machinery the rest of nina uses, scoped to indexed articles - never an arbitrary filesystem path.
* '''Network access is gated through one function''', `plugin_http_get()`, the only piece of code permitted to call `system()` internally. It lives in trusted, plugin-author-unreachable code and is exempt from the bans above - those bans apply to plugin ''source'', not to nina's own infrastructure.
* `plugin_web_allowed()` '''is a courtesy, not enforcement.''' `plugin_http_get()` checks `PLUGIN_PERMIT_WEB` itself regardless of whether a plugin bothered to call the courtesy function first.
* '''Untrusted text never enters a constructed shell string.''' Plugin arguments and titles travel via temp file or environment variable, never string-concatenated into a command - this is what makes a title containing shell metacharacters harmless rather than an injection path.

---

# Execution Model

* Each `<<name args>>` invocation runs as its own fresh AWK subprocess - no shared function namespace the way macros have, so two plugins are free to define same-named helpers without conflict.
* The article being rendered arrives on the plugin's stdin. Context (current file, current title, the date/time, terminal width) arrives via environment variables, read fresh every render - no caching, so a config edit takes effect on the very next render with no reinstall step.
* Resolution is a single left-to-right forward scan with the cursor advancing past each `<<...>>` as it's handled - no rescan-from-start, so no placeholder/restore trick is needed the way `{{}}` expansion needs one.
* A plugin's output is final once produced - never re-scanned for further `<<...>>` calls, mirroring the rule that macros never invoke other macros.
* Plugin expansion runs as a genuinely separate process from rendering, piped into the render pass rather than combined into one shared AWK invocation. This is required, not stylistic - see Architectural Notes below.

---

# The Trusted API

Available to every plugin via the shared API file loaded alongside it:

__Function__                         __Purpose__
`plugin_args()`                    the text typed after the plugin's name
`plugin_current_file()`            path to the article being rendered
`plugin_current_title()`           title of the article being rendered
`plugin_today() / plugin_now()`    current date/time, same source as {{date}}/{{time}}
`plugin_term_width()`              the terminal width nina is rendering for
`plugin_debug(message)`            write a diagnostic line to stderr only - never reaches the article
`plugin_backlinks(title)`          articles linking to `title`, deduplicated
`plugin_tags(title)`               tags of `title`
`plugin_links(title)`              articles linked from `title`, deduplicated
`plugin_read_article(title)`       full text of `title`
`plugin_read_article_body(title)`  text of `title` with its header stripped
`plugin_web_allowed()`             whether PLUGIN_PERMIT_WEB is on
`plugin_http_get(url)`             response body of an HTTP(S) request, or "" if disallowed/failed
`plugin_call_nina(verb, arg)`      the function the five corpus-read wrappers above are built on

`plugin_call_nina()` is a fixed allowlist mapping verbs (`--backlinks`, `--tags`, `--links`, `--read`, `--read-body`) to existing library function calls made in-process - never a constructed shell command line. New corpus-read capability gets added by extending this allowlist deliberately, not by giving a plugin a more general escape hatch.

---

# Validation and the Hash Check

`nina --plugin` validates every file in `PLUGINS_DIR` before it's trusted to run, in a specific order that matters:

1. The textual bans above (`system(`, `getline`, redirected `print`/`printf`) are checked first, on the raw source, before the file is ever handed to AWK for any reason - including the syntax check in step 2. A file's `BEGIN` block runs the moment AWK loads it; there is no "parse only, don't execute" mode, so a dangerous file must be rejected on text alone, never by running it and seeing what happens.
2. Only once a file passes those bans is it actually executed, briefly and under a timeout, to confirm it's valid AWK that runs cleanly rather than hanging - this also catches an infinite loop that uses none of the banned constructs, which step 1 can't.
3. A sha256 hash of the file is recorded in the manifest alongside its name and capability flags.

That hash is rechecked before every single invocation, not just at install time. If a plugin's file has changed since it was last validated - edited, replaced, anything - the hash won't match, and the plugin is refused: treated exactly like a timeout or crash, original `<<...>>` text left untouched, a warning printed to stderr. This closes the gap between "this file was approved" and "this file is what's actually running" - a path on disk can be edited after validation, and the manifest alone has no way to notice without re-checking.

Reasons a plugin file can be rejected by `nina --plugin`:

* '''Missing or invalid name.uy:''' The first line isn't a name-declaring comment, or the name is empty, contains a space, or contains `>`.
* '''Uses''' `system()`''',''' `getline`''', or redirected''' `print`'''/'''`printf`.''' Refused outright regardless of what it's used for - see The Capability Model above for why all three are banned unconditionally.
* '''Syntax error, runtime error, or did not terminate.''' Checked by actually running the file briefly under a timeout, not just parsing it - this is what catches an infinite loop that uses none of the banned constructs.

`nina --plugin` prints the filename and reason for every plugin it rejects, and does not affect any other plugin's installation.

`nina --doctor` gives a fuller health report, building its own independent copy of this same validation rather than calling `nina --plugin`'s - the same "check our own work, don't just trust the thing being checked" reasoning [[Nina - Devs: Macros|Nina - Devs: Macros#When a Macro Fails to Install]] uses for its own doctor integration. Beyond valid/invalid/installed counts, it separately reports which installed plugins reference the network or corpus-read functions, and flags the specific, easily-missed case where capable plugins exist but the corresponding config flag (`PLUGIN_PERMIT_WEB`, or `ENABLE_PLUGINS` itself) is off - a plain fact about current configuration, not a warning, since nothing is actually wrong.

---

# Failure Handling

Every one of these is handled identically: the original `<<name args>>` text is left untouched in the rendered article, nothing is silently replaced with empty output, and a diagnostic goes to stderr only.

* Unrecognized plugin name
* Hash mismatch (file changed since validation)
* Timeout
* Nonzero exit / crash

Two timeouts exist - `PLUGIN_TIMEOUT` for a plugin that references the network or corpus-read functions (either can leave the local process), `PLUGIN_NO_WEB_TIMEOUT` for one that does neither. Output beyond `PLUGIN_MAX_OUTPUT_BYTES` is truncated, not treated as an error. A memory ceiling (`PLUGIN_MAX_MEMORY_KB`, applied via `ulimit -v`) bounds a plugin that just allocates in a loop, independent of whether it touches the network or corpus at all.

---

# Architectural Notes for Anyone Modifying This System

A few hard-won lessons, in case you're changing this code rather than just using it:

'''Plugin expansion must run as a separate process from rendering.''' A plugin's multi-line output gets spliced into a line as one string with embedded newlines. If expansion and rendering shared a single AWK process, the renderer's per-record, `^`-anchored styling rules (headers, bullets) would only ever fire against the first line of that string - `^` matches the true start of a string, not the start of each embedded line within it. Piping plugin expansion's output into a fresh AWK invocation forces every embedded line to be re-read as its own genuine record, which is what lets each one be styled independently. See [[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Rendering]] for the same one-line-at-a-time constraint as it applies to the renderer generally.

'''Environment variables are not AWK globals.''' Values passed to a plugin's subprocess as shell environment variables (current title, current file, the date/time) are only reachable via `ENVIRON["NAME"]` inside that subprocess - never as a bare global of the same name. A bare global is only populated by `-v` on that specific invocation. Getting this backwards produces no error - every affected function just silently returns an empty string.

'''Protected regions (hidden comments, backtick spans) have to be independently respected by the plugin scanner.''' The renderer protects these regions downstream of where plugin expansion runs, so none of that protection exists yet at the point a `<<...>>` call is found unless it's separately replicated. The fix masks comment spans and backtick-delimited spans with a filler character before scanning for `<<`/`>>` tokens, while always extracting the real output text from the unmasked original line - so a plugin call sitting inside a comment or inline code span is never mistaken for a real one, without altering what the renderer later does with that region.

---

# Reference

`~/.nina/plugins/`               where plugin files live
`~/.nina/plugins.tsv`            generated manifest (don't edit by hand)

`nina --plugin`                  scan, validate, and install plugins

`PLUGINS_DIR`                    config variable - where to look for plugin files
`ENABLE_PLUGINS`                 config variable - turn plugin expansion on/off
`PLUGIN_PERMIT_WEB`              config variable - allow plugins to reach the network
`PLUGIN_TIMEOUT`                 config variable - time limit for network/corpus-reaching plugins
`PLUGIN_NO_WEB_TIMEOUT`          config variable - time limit for purely local plugins
`PLUGIN_MAX_OUTPUT_BYTES`        config variable - output truncation point
`PLUGIN_MAX_MEMORY_KB`           config variable - memory ceiling per invocation
