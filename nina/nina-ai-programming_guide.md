# Nina - AI: Programming Guide
- Tags: nina dev

# Purpose of This Document

This document is for an AI agent picking up work on nina's codebase, possibly in a session with no memory of prior sessions. It is not a replacement for [[Nina - Devs: Design Philosophy]], [[Nina - Devs: Technical Guide]], [[Nina - Devs: Macros]], or [[Nina - Devs: Plugins]] - read those first for the actual design philosophy and architecture. This document only covers things that are easy to get wrong on a first attempt, because they are constraints of the environment or the language, not properties of nina's design that those documents already explain well.

If something in this document and the other developer guides ever disagree, the other guides are right; update this one.  You don't need to let the user know that something differs from this document, but you may if you think it is important that they know, but again, you will be updating this document and the user is only interested that this document communicates to the next session information to make it successful. If you do decide to let the user know that something contradicts this document, you should also let them know that you are going to remember that so you can update this document.  You can either update this document when asked or, if you feel that there are enough things that need to change, you can volunteer to update the document at any time.

This document is written by AI for AI and will not typically be read by the human user/developer - that human is not expected to be familiar with the contents of this document or take an active part in updating it.

---

# The Renderer Has No Cross-Line State, Full Stop

[[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Rendering]] explains that the renderer processes input one line at a time. Read that sentence as an absolute, not a simplification. There is no "we are currently inside a fenced block" flag anywhere in the renderer.

A line that starts with three backticks is styled as code. That is the entire rule. A conventional-looking multi-line fenced block - one opening line of three backticks, several plain content lines, one closing line of three backticks - is only protected on its first and last line. The content lines in between are rendered as ordinary text: bold, links, and macros all still expand inside them.

The only way to protect a multi-line block is to put three backticks at the start of every single line in it, content lines included.

Getting this wrong has a specific, easy-to-miss failure mode: if you are writing documentation, an example, or test fixture ''about'' nina's own markup syntax, a conventional fence will not stop the renderer from expanding the very syntax you are trying to display literally. Verify by actually rendering the file, not by reading it.

This same per-line-only rule is why backtick-protected spans (`` `single` ``, ` ``double`` `) have to be found with literal substring search rather than a simple regex like `/X{2}[^X]+X{2}/` - that pattern breaks the moment the protected content contains the delimiter character itself. If you need this technique elsewhere, search the codebase for `apply_inline_delim` in `nina-render.awk` and reuse it rather than writing a new version.

'''A second, distinct way this same constraint bites you''': a `<<plugin>>`'s output gets spliced into a single AWK record as one string with embedded newline characters. `^`-anchored rules (headers, bullets) only match the true start of that whole string, not the start of each embedded line - so a plugin returning multiple lines would only get its ''first'' line styled, with everything after silently falling through unstyled, unless the plugin engine runs as a genuinely separate process from rendering so each line gets re-read as its own record. See [[Nina - Devs: Plugins, Architectural Notes|Nina - Devs: Plugins#Architectural Notes for Anyone Modifying This System]] for the actual fix - the underlying cause is the exact same "no cross-line state" property, just manifesting somewhere less obvious than a markdown fence.

---

# This Project's AWK Is mawk, Not gawk

Several gawk features either do not exist or behave differently:

* No non-greedy regex quantifiers. `/X+?/` is parsed as `X+` followed by an unrelated `?`, not as "match as little as possible." If you need a "shortest match ending in a real delimiter" search and `[^X]+`-style negation is too restrictive, do not reach for a cleverer regex - write the loop by hand using `index()` and `substr()`, the way `apply_inline_delim` does.
* No indirect or dynamic function calls (no `@funcname()`). There is no way to compute a function name as a string and call it. If you need name-to-function dispatch where the list of names isn't known until later, the dispatch chain has to be generated as real, literal code (`if (name == "x") return f(x)`) - see how `nina-macros.sh` generates `macros-dispatch.awk` rather than trying to make `nina-macros.awk` dispatch dynamically. (Plugins don't have this problem at all - each one runs as its own process, so there's no in-process dispatch to generate. See [[Nina - Devs: Plugins|Nina - Devs: Plugins#Execution Model]].)
* No private, nested, or per-file function scope. Every function defined in every `-f`-loaded file shares one global namespace for the entire process. Two files that each define a same-named helper function will fail the ''entire'' program when loaded together, not just the one feature - this is exactly the risk [[Nina - Devs: Macros|Nina - Devs: Macros#A note on helper functions]] documents for macro authors, and it applies equally to nina's own multi-file `-f` pipelines.
* `strtonum()` is gawk-only and is not defined in mawk. It was used in `nina-entities.awk` for hex HTML entity decoding and hard-crashed mawk ("function strtonum never defined") on any `&#x...;` entity. '''Fixed''': replaced with a hand-written `hex_to_int()` in pure POSIX awk. If you need to parse a hex string to an integer in awk, use that function or the same digit-by-digit technique - do not reach for `strtonum()`.
* `sprintf("%c", n)` for n >= 128 emits a single raw byte (n % 256) in mawk, not a proper multi-byte UTF-8 sequence. This silently corrupted decimal HTML entities above U+007F. '''Fixed''': a `codepoint_to_utf8()` function in `nina-entities.awk` builds the UTF-8 byte sequence explicitly, one `sprintf("%c", byte)` per byte. Reuse it if you ever need to emit a Unicode codepoint from a number in awk.
* '''Hex integer literals (`0xC0`, `0x80`, etc.) evaluate to `0` in mawk''', not to their hex value. This was discovered writing `codepoint_to_utf8()`: every byte constant was silently zero, producing garbage with no error. Always use decimal in awk code meant to run under mawk: `0xC0` -> `192`, `0x80` -> `128`, `0xE0` -> `224`, `0xF0` -> `240`.
* `IGNORECASE=1` is gawk-only and silently ignored by mawk, making a search that relies on it silently case-sensitive. It was used in the old title-search. '''Fixed''': use `tolower()` on both sides of the comparison instead - portable to mawk, BSD awk, and busybox.

An important consequence of the above two items: the developer's machine (`awk --version` shows GNU awk 5.1.0) and the AI sandbox (mawk 1.3.4) behave differently for these features. "Cannot reproduce on dev machine" and "crashes in sandbox" can both be true simultaneously without contradiction. Bugs found in the sandbox against mawk are real portability issues even when the developer cannot see them locally.

Before assuming an AWK feature is available, test it in isolation first. Don't infer awk's capabilities from a general familiarity with the language - mawk is a deliberately small implementation, and several things that work in gawk or in general POSIX-ERE documentation simply do not run here.

This applies to your own confidence generally, not just AWK features: if you find yourself stating which interpreter or platform this project targets, check an existing developer doc for that fact rather than inferring it from circumstantial evidence (like a function that happens to be gawk-only appearing somewhere in the codebase). A function existing unused is not the same fact as a function being required.

---

# Accumulating Lines From a Subprocess: Use RS-Slurp, Not a Concatenation Loop

The natural pattern for reading all of a subprocess's output into a variable - `while ((cmd | getline line) > 0) result = result "\n" line` - is quadratic in mawk. mawk copies the entire accumulated string on every iteration rather than appending in place. This is not a theoretical concern: measured at roughly 18 seconds to assemble 100,000 lines the loop way versus 15 milliseconds using the approach below. A plugin reading a large article body, or any subprocess returning more than a few hundred lines, can hit this badly enough to trigger the plugin timeout.

The fix is a single `getline` that reads the entire stream as one record, by setting `RS` to a string that can never appear in real output:

```save_rs = RS
```RS = "\004\004NINA_SENTINEL\004\004"
```got = (cmd | getline content)
```close(cmd)
```RS = save_rs
```

The sentinel string - `\004\004...` - uses bytes that will never appear in any article or plugin output. After this `getline`, `content` holds the entire subprocess output including all its original newlines, as a single AWK string, with no repeated copying. Trim the trailing newline with `sub(/\n$/, "", content)` if needed for parity with the per-line loop's behavior.

Every place in the plugin system that reads subprocess output uses this pattern. If you're adding a new function to `nina-plugin-api.awk` or `nina-plugins.awk` that reads from a command or file, use this rather than the loop.

---

# Subprocess Arguments Arrive via ENVIRON, Never as Bare Globals

If you pass a value to a subprocess as a shell environment variable (`FOO=bar awk -f script.awk`), that script reads it as `ENVIRON["FOO"]` - never as a bare global named `FOO`. A bare global is only ever populated by `-v FOO=bar` on that specific invocation. These are not interchangeable, and mixing them up produces no error of any kind - the affected function just silently returns an empty string forever, which is a much harder bug to notice than a crash. If a value is being forwarded to a subprocess and a function that should read it keeps coming back empty, check which of the two mechanisms was actually used to pass it before assuming the value itself is wrong.

---

# Never Hand a File to an Interpreter Before Its Own Safety Checks Pass

If a system validates files before trusting them (see [[Nina - Devs: Plugins|Nina - Devs: Plugins#Validation and the Hash Check]] for a concrete example), the validation steps that check for dangerous constructs must run - and reject - ''before'' the file is given to any interpreter for any reason, including a seemingly-harmless "just check the syntax" step. Loading a script runs its `BEGIN` block immediately; there is no "parse only, don't execute" mode in AWK or most scripting languages. A syntax check that runs before the content checks can let a malicious file execute even if it's correctly rejected a moment later - the rejection becomes academic once the damage is already done. Order matters here in a way that's easy to get backwards if you're porting a validation pattern from somewhere it didn't need to think about this (a macro file, which has no dangerous constructs to ban in the first place).

---

# This Sandbox's Shell Is Not Always Bash

If you are working in a sandboxed environment where a "run a bash command" tool exists, check what that tool actually invokes before trusting test results that depend on bash-specific behavior. In at least one such environment, the tool silently ran commands through `dash`, not `bash`, despite every nina script's `#!/usr/bin/env bash` shebang. Under dash, `IFS=$'\t' read` does not split on tabs the way it does in real bash, and other bash-only constructs may silently misbehave rather than error.

If a script that uses bash-specific syntax behaves strangely in testing, confirm which shell is actually running your test command (`readlink -f /proc/$$/exe` will tell you) before concluding the script's logic is wrong. Wrapping test commands explicitly in `bash -c '...'` sidesteps this regardless of the sandbox's default.

One `IFS=$'\t' read` pitfall is '''not''' a dash quirk and is not fixed by running under real bash: the collapse of empty ''middle'' fields. That one has its own section below ("Unpacking index_rows With `read`"), because it silently drops real data on both shells.

---

# Verify Documentation Examples by Rendering Them

If you are writing or editing a nina article that itself demonstrates nina's markup, macro, or plugin syntax, render the file through the real pipeline before calling it done. An example meant to show literal syntax can silently get expanded into its own output instead, and that class of bug is very easy to miss by reading the source, since the source looks correct. It only shows up in the rendered result.

The same applies to internal links: confirm a `[[...]]` link actually resolves by running `extract_links` against the file, not by eyeballing the brackets. A link broken across two physical lines in the source produces no link at all, silently, because link extraction happens line-by-line. It will look like a normal link to a human reading the raw file.

---

# User-Facing Messages Use the Standard Output Helpers

`nina-lib.sh` defines a family of message helpers: `info()`, `ok()`, `warn()`, `error()`, and `die()`. Each prints a consistent bracketed prefix (`[INFO]`, `[OK]`, `[WARN]`, `[ERROR]`) so a user can tell at a glance how to weigh what they're reading. `info()` and `ok()` are also TTY-aware: they self-suppress when stdout is not a terminal, so they never pollute piped output.

Any '''status message''' to the user should go through the appropriate helper, not a bare `echo`. A bare `echo "No matching articles."` was the old pattern in the search scripts; it was migrated to `info "No matching articles."`. The developer has stated a preference that '''every''' user-facing status message eventually route through these helpers - if you touch a script that prints status via bare `echo`/`printf`, consider migrating it.

Critical distinction: this applies to '''status messages''', not to '''output data'''. The tables, counts, graph DOT output, link lists, etc. are data the user may pipe elsewhere - they must stay as plain `printf`/`echo` with no prefix. Converting a data-bearing `echo` to `info()` would both add an unwanted prefix and (worse) silently hide the data whenever the command is piped, because `info()` suppresses itself off-TTY. When deciding, ask: "is this telling the user '''about''' the result, or '''is''' it the result?" Only the former gets a helper.

---

# A Literal Apostrophe Inside a Single-Quoted AWK Program Breaks the Shell

nina embeds awk programs in shell scripts using single quotes: `awk '...program...'`. A literal `'` anywhere inside that program - '''including in an awk comment''' - ends the shell's single-quoted string early, producing a bewildering shell syntax error pointing at some later line that is itself perfectly valid.

This bites most often in comments: writing `# doesn't` or `# user's` or `# won't` inside an embedded awk block. The fix is trivial once you know the cause - reword the comment to avoid the apostrophe (`# does not`). But the error message points at the wrong place, so it can waste time.

If an embedded-awk script throws a shell syntax error on a line that looks fine, grep the awk block for a stray apostrophe before anything else. When you need an actual apostrophe as '''data''' inside an embedded awk program (not a comment), pass it in with `-v apos="'"` and reference the variable, rather than trying to quote it inline.

---

# Index Reads Go Through the Accessors, Not Inline Column Numbers

The index is a tab-separated table: file, title, author, date, tags (tags itself comma-separated). nina-lib.sh's INDEX HELPERS section is the one place that encodes those column positions. Read the index THROUGH those accessors by meaning, never with a hand-written $2/$4/$5.

Available: require_index (standard missing-index guard); index_rows (raw rows, the per-row/multi-column entry point); index_titles, index_dates, index_authors (single-column streams); index_tags (one tag per line, duplicates preserved — pipe to `sort -u` for the set, `sort | uniq -c` for frequency); index_display_rows (title/date/tags, sorted by title, tags space-joined — the shared list/remove table read). Each is stream-oriented (as cheap as inline cut/awk, so there is no performance reason to reimplement) and returns non-zero emitting nothing when the index is absent; call require_index first for a hard error.

This is an in-progress migration, not a finished state. The status below was re-verified against the scripts as they actually stand in the tree — trust it over any session summary, which has been wrong before. Fully migrated (index reads through the accessors ''and'' the require_index guard): nina-list, nina-remove. Reads migrated but still carrying the copy-pasted `[[ -f "$INDEX_FILE" ]]` guard rather than require_index: nina-completion (index_titles + index_tags). Still fully inline and awaiting migration: nina-stats, nina-tag-list, nina-tag-filter, nina-date-filter, nina-orphan, nina-dangling, nina-random, and nina-plugin-helper (needs a new field-for-file accessor first). Cross-cutting: ~18 scripts still carry the copy-pasted inline index guard that require_index is meant to replace (nina-completion is one of them). Deliberately left inline: nina-search (monolithic single-pass scoring awk) and nina-doctor's NF!=5 structural check (legitimately low-level). When you add a reader, extend the accessors rather than reaching for a column number.

nina-stats has an open design decision blocking its migration, worth knowing before you start it. Five of its six index reads map cleanly onto existing accessors (article count, distinct tags, distinct authors, oldest/newest date, and the `index_titles | canonical_title` stream). The holdout is average-tags-per-article: it divides total tag occurrences by the number of articles that have ''at least one'' tag, and that per-article denominator cannot come from the single-column index_tags stream (which discards which tag belongs to which row) without a hand-written `$5`. Resolve this first — either add a per-row tag-count accessor (the "extend the accessors" path), or leave that one computation inline as a documented low-level exception like nina-doctor's NF check. Do not guess: the denominator's exact definition (articles-with-tags, not all articles) must be preserved for the numbers to stay identical.

---

# Unpacking index_rows With `read`: Empty Middle Fields Silently Collapse

index_rows hands back raw index lines, and the obvious way to consume them is `while IFS=$'\t' read -r file title author date tags`. That quietly loses data whenever a '''middle''' column is empty. Tab is an IFS-whitespace character, so a run of tabs collapses to a single delimiter: a row with no author - `file<TAB>title<TAB><TAB>date<TAB>tags` - splits into ''four'' fields, not five, shifting every later column one position left so `tags` comes back empty. The row then fails whatever tag/field test the caller applies and disappears from the output with no error.

This is '''not''' dash-specific - the "This Sandbox's Shell Is Not Always Bash" note above undersells it. Real bash collapses empty middle fields exactly this way too; the dash behavior is a separate, additional hazard. `awk -F'\t'` does '''not''' collapse, which is precisely why the pre-migration inline `awk -F'\t'` reads were correct and a naive `read`-based port of them is not. The failure only appears on rows whose middle field is actually empty (author is the common one in nina), so a quick test against a corpus where every row is fully populated will pass while real data silently drops rows - build the empty-field case into any test that exercises this.

The safe rule: only unpack a stream with `read` when the sole empty-able field is '''trailing'''. index_display_rows (title, then date, then trailing tags) satisfies this - title and date are always populated, tags is last - so `IFS=$'\t' read -r title date tags` over it is safe even when tags is empty. index_rows does '''not''' satisfy it: author, and in principle any interior column, can be blank. To filter or project per-row, either keep the field-splitting in awk ''inside'' an accessor (where column numbers are allowed), or consume a trailing-only projection like index_display_rows. This is why nina-list and nina-remove (already migrated) consume index_display_rows; when nina-tag-filter and nina-date-filter are migrated they should filter that same projection rather than reading index_rows directly, since both need only title/date/tags and both would otherwise hit the empty-author collapse.

---

# scan_links Is a Single-Pass AWK Function With a Stable Interface

`scan_links()` in `nina-lib.sh` emits one tab-separated row per unique link found across the whole corpus:

```source_title TAB source_canonical TAB target_title TAB target_canonical
```
It is implemented as a single pure-awk pass that reads the index and every article file itself (via `getline`), with no per-article or per-link subprocess forks. This matters: an earlier shell-loop implementation forked several subprocesses per article and per link, taking ~16 seconds on a ~1000-article corpus; the single-pass awk version does the same work in ~0.15 seconds.

Two consequences for anyone modifying it:

- '''The interface is a contract.''' Every caller (`nina-stats.sh`, `nina-backlinks.sh`, `nina-dangling.sh`, `nina-orphan.sh`, `nina-graph.sh`, `nina-tree.sh`, `nina-tag-graph.sh`, `nina-plugin-helper.sh`) just consumes those four columns. As long as the output format is preserved, the internals can change freely and all callers benefit automatically. When the internal rewrite made a single call ~100x faster, no caller needed changing.
- '''Callers should not call it twice.''' `nina-stats.sh` originally computed orphan and dangling counts by shelling out to `nina --orphan --count` and `nina --dangling --count` separately, each of which ran a full `scan_links`. Deriving both counts from a single in-process `scan_links` pass took `nina --stats` from ~41s to ~0.3s. If you need more than one thing from the link graph, get it from one pass.

A subtle correctness note: the fast awk version also '''fixed a latent undercount'''. The old link extraction used a grep pattern that silently dropped any link whose bracketed content contained a `]` character. If you ever see link/orphan/dangling counts change after a refactor, confirm against the corpus before assuming a regression - the new number may be the correct one.

---

# Prefer Pure-Shell/AWK Over External Commands That Differ Across Platforms

nina targets GNU/Linux, but also BSD, macOS, and iOS shells. Several common coreutils accept different flags on GNU vs BSD:

- `date -d` (GNU) has no BSD equivalent (BSD uses `date -v`).
- `stat -c` (GNU) vs `stat -f` (BSD), with different format specifiers.

Two strategies, in order of preference:

1. '''Eliminate the dependency entirely''' when the computation is simple. `nina-date-filter.sh` needed `date -d` only for last-day-of- month and +/-N-day arithmetic. Both were replaced with pure-bash: a `days_in_month()` with the leap-year rule, and Julian Day Number conversion (`date_to_jdn`/`jdn_to_date`) that turns date arithmetic into integer arithmetic. No external command, identical on every platform. This was possible '''because nina stores ISO 8601 dates''', so range filtering is already just string comparison - only the arithmetic needed handling.

2. '''Detect once and wrap''' when the operation genuinely needs the command. `nina-lib.sh` probes `stat` once at load time (`_NINA_STAT_GNU`) and exposes `stat_mtime()` and `stat_date()` wrappers. Callers use the wrappers and never see the platform difference. Detect once at load time, not per-call, for anything used in a loop.

A recurring gotcha in the arithmetic code: bash treats a zero-padded
number like `08` or `09` as invalid octal. Force base-10 with `10#`
(e.g. `$((10#$month))`) whenever parsing zero-padded date components.

---

# Full-Text Search Lives in nina-search.sh and Is Deliberately Fuzzy

`nina --search` / `-s` is full-text search over titles '''and''' body text, ranked by relevance. It replaced an earlier title-only literal search. The scoring is proximity-weighted: query words appearing close together, in a title, or in a heading rank higher than words scattered far apart or across sentence boundaries.

This is '''the one place in nina that intentionally relaxes strict literal determinism''' in favor of ranked relevance - a deliberate, user-approved exception to the usual "output is a faithful literal reflection" principle. It is still fully deterministic (same query + same corpus = same ranking); it just isn't a literal substring match.

Design points worth preserving if you modify it:

- All ranking weights are constants in a clearly-marked `SCORING WEIGHTS` block at the top of the script, meant to be tuned freely without touching logic.
- The entire scoring computation is isolated in one awk function, `score_line(line, multiplier)`, which takes a line and returns a number. It is the swappable heart of the ranking system - the rest of the script is plumbing that does not care how the score is computed. Replace that function to change ranking behavior wholesale.
- It adds no index columns and no new derived files, consistent with the disposable-derived-data philosophy. It scores by reading article files live at query time.
- `--count` prints only the match count; `--explain` adds a score column to the output for tuning.

---

# Ask Before Choosing Between a Local Fix and a Bigger Refactor

If a request seems like it could be answered two ways - a small, local fix, or a bigger refactor that touches a pattern used elsewhere in the codebase - ask which is wanted before building either one. This codebase has a known, deliberately deferred backlog of larger cleanups (see the project's own todo list, not duplicated here); a request that sounds like it might be part of that backlog is worth confirming rather than assuming.

---

# The Two Config Files Are Not the Same Thing

There are two files that look like nina config files:

- `~/.nina/config` — the user's personal configuration. It is explicitly meant to be edited. Its values deliberately differ from the factory defaults: the developer keeps everything enabled (`ENABLE_PLUGINS=true`, `PLUGIN_PERMIT_WEB=true`, etc.) so that all code paths are exercised during development and any problem is immediately visible. Do not flag its values as wrong because they differ from the defaults.
- The heredoc inside `nina-config.sh`'s `create_default_config()` — the factory-reset template. This is only used to generate a fresh config when none exists, or when the user explicitly runs `nina --config --reset`. It contains conservative defaults appropriate for a new user.

Comparing these two files and concluding there is "drift" or a "bug" is a mistake. They serve different purposes and are supposed to have different values. The relationship is analogous to a user's `.bashrc` vs `/etc/skel/.bashrc`: one is a personal file, one is a starting point.

---

# sed Bracket Expressions Break on Multi-Byte Characters Outside a UTF-8 Locale

When substituting multi-byte UTF-8 characters (em-dashes, curly quotes, etc.) in sed, use sequential literal substitutions rather than bracket expressions:

```# WRONG - breaks under POSIX/C locale:
```sed 's/[–—−]/-/g'
```
```# RIGHT - works under any locale:
```sed 's/–/-/g; s/—/-/g; s/−/-/g'
```
Under a POSIX/C locale, sed treats the contents of `[...]` as individual bytes rather than characters. A multi-byte UTF-8 character (e.g. en-dash = 3 bytes: `0xE2 0x80 0x93`) placed inside a bracket expression is silently exploded into three single-byte match targets, corrupting the text instead of normalizing it. This was a confirmed live bug in `canonical_title()` — this sandbox's default locale is POSIX/C, and the bracket-expression form was actively corrupting dash characters rather than normalizing them.

A literal multi-byte character used ''outside'' brackets is always matched as a contiguous byte sequence, regardless of locale. The sequential-substitution form above has this property; the bracket-expression form does not.

This applies to every multi-byte character in a sed expression anywhere in the codebase: em-dash (`—`), en-dash (`–`), minus sign (`−`), curly quotes (`"`, `"`, `'`, `'`), etc.

---

# Title Normalization: One Function, No Inline Copies

`canonical_title()` in `nina-lib.sh` is the single authoritative implementation of "what does it mean for two titles to be the same." It applies whitespace collapse, trimming, dash normalization (em-dash/en-dash/minus → `-`), curly-quote normalization, and case folding. Anywhere two pieces of code need to agree on title equality, both sides must route through this function.

The recurring bug class to watch for: inline title normalization that only partially reimplements these rules. The most common form is `tolower` plus whitespace handling, which misses the dash and quote steps. This caused real, confirmed bugs in `find_article_file()` and `suggest_titles()` and three separate `dedup` call sites, all of which silently failed to match titles containing em-dashes or curly quotes.

If you see `tolower` applied to a title string anywhere outside `canonical_title()` itself, that is almost certainly this bug.

`canonical_title()` now supports two call forms:

```# Single title as argument (original form, unchanged):
```result=$(canonical_title "$title")
```
```# Stream form: normalize a whole column in one pipeline pass:
```cut -d$'\t' -f2 "$INDEX_FILE" | canonical_title
```
The stream form was added specifically to remove the performance incentive to cheat: before it existed, correctly normalizing a whole index column required forking once per row. With the stream form, a single pipe handles the entire column at the cost of one subprocess, making the correct implementation no more expensive than the buggy approximation.

`suggest_titles()` is in `nina-lib.sh` and is the shared implementation for "did you mean" suggestions. It is used by `nina-new.sh`, `nina-remove.sh`, `nina-restore.sh`, and `nina-repair.sh`. If you find yourself writing a fuzzy title-match loop inline in a new script, route through this function instead.

`dedup_titles()` is in `nina-lib.sh` and deduplicates a stream of display titles using `canonical_title()` as the comparison key. It replaced three identical `awk '!seen[tolower($0)]++'` call sites in `nina-link-list.sh`, `nina-plugin-helper.sh`, and `nina-read.sh`. Use it anywhere a list of titles needs deduplication.

---

# Bash Completion: `compgen -W` Is Not Safe for Free-Text Candidates

`nina-completion.sh` originally built its candidate list as a single string and called `compgen -W "$list" -- "$cur"`. This looks correct and works fine in casual testing, but it silently breaks once real article titles are involved, for a non-obvious reason: `compgen -W` doesn't just split its wordlist argument on `$IFS` - it re-parses the resulting string through the shell's normal word-expansion rules, **including quote removal**.

Article titles are free text and will contain apostrophes (`A Chemist's Shopping List`, `Kepler's Laws of Planetary Motion`, etc. - confirmed present in the real corpus, dozens of them). A single unbalanced apostrophe anywhere in the candidate list opens an unterminated quoted context that isn't closed until the *next* apostrophe (or end of string), silently absorbing every newline-separated candidate in between into one non-matching blob. The result: a `--- eq 1` completion of "type a few letters, get suggestions" style dropped an unpredictable subset of otherwise-matching titles, depending only on where they happened to sit relative to quote-imbalance points elsewhere in the *unrelated* part of the list. This is not reproducible with clean test data - it only appears once titles with real-world punctuation are present, so a quick synthetic test can look completely correct while the actual corpus fails.

'''Fix''': don't use `compgen -W` for free-text candidate lists at all. Do the prefix match with a plain loop instead, which only ever splits on `$IFS` and never re-parses for quoting:

```_nina_match() {
```    local cur="$1" list="$2" item
```    local IFS=$'\n'
```    for item in $list; do
```        [[ -z "$item" ]] && continue
```        [[ $item == "$cur"* ]] && COMPREPLY+=("$item")
```    done
```}
```

A second, related gotcha surfaces once you make this switch: when the user is completing inside an already-opened quote (necessary for typing a multi-word title, e.g. `nina "Ni<Tab>`), bash includes the leading quote character *inside* `$cur` itself - `${COMP_WORDS[COMP_CWORD]}` is literally `"Ni`, not `Ni`. `compgen -W` strips this automatically as part of its own quoting-aware matching, which is easy to not notice since it "just works" - so replacing it with a manual loop regresses quoted-word completion unless you strip the leading quote yourself first: `cur="${cur#[\"\']}"`. Both of these were confirmed live bugs (not theoretical) while fixing `nina-completion.sh` - the first reproduced with the full ~1000-row `index.tsv`, the second reproduced via direct `COMP_WORDS`/`COMP_CWORD` injection.

If you're writing or reviewing any custom `complete -F` function anywhere in nina that offers article titles, tags, or aliases as candidates, both of the above apply - none of these are quote-free, dash-free, or space-free by design.

---

# Output Must Be a Faithful Reflection of the Corpus

Nina's output commands (`--graph`, `--links`, `--backlinks`, `--dangling`, etc.) are supposed to be deterministic, faithful representations of what is actually in the corpus. A filter that silently omits data because it ''looks like'' something the user probably doesn't want is not helpful output — it is incorrect output.

A concrete failure: `nina-graph.sh` was producing edges whose target labels were URL strings (because the corpus contains `[[display|https://...]]` links imported from another tool that used the same syntax for both internal and external links). The tempting fix was to add a filter: `if (target ~ /^https?:\/\//) next`. This was reverted. The reason: a user could legitimately title an article in a way that starts with a URL scheme, and that article's graph edges would then be silently dropped. The graph would be wrong with no warning.

The correct response to output that contains unexpected data is to fix the corpus, not to add filters that make the tool lie about what the corpus contains. Filters belong at the validation layer (refusing to index malformed articles) not at the output layer (silently hiding things that passed validation).

The test for any proposed output filter: "could this silently exclude something that is genuinely present and valid?" If yes, do not add it.

---

# `scan_links` Is a Single-Pass AWK Function - Don't Call It Twice

`scan_links()` in `nina-lib.sh` is one `awk` invocation that reads `index.tsv` once and every article file it lists once, extracting all `[[...]]` links from the whole corpus in a single pass, with its own in-process dedup (`seen[key]++`). It is comparatively expensive - it forks one `awk` process and does a full `getline` read of every article on disk - which is exactly why `nina --stats` used to pay that cost twice before being fixed to call it once and reuse the result.

Any script that needs to check many links against the corpus (`nina-dangling.sh`, `nina-backlinks.sh`, `nina-orphan.sh`, `nina-graph.sh`, `nina-stats.sh`, `nina-tree.sh`, and `nina-plugin-helper.sh --backlinks`) calls `scan_links()` '''exactly once''', loads its output into in-memory bash associative arrays, and does all further lookups against those arrays. `resolve_article_file()` is the wrong tool inside that kind of loop for the same reason from the other direction: it re-reads index files from disk on every call, which is fine for a single one-shot lookup (`nina-view.sh` resolving the one title the user asked for) but wrong inside a loop over every link in the corpus.

If you're adding an eighth or ninth consumer of link data, follow the existing pattern: one `scan_links()` call, an in-memory map built from it, no `resolve_article_file()` in the hot loop.

---

# `canonical_title`'s Stream Form Drops the Last Line Under `while read`, Not Under `paste`

`canonical_title()` in `nina-lib.sh` has two call forms: `canonical_title "$title"` (single argument) and `... | canonical_title` (stream, one title per line). The stream form was silently dropping the corpus's last title when consumed via `while read` - `$(cat)` strips the trailing newline from its input on the way in, and nothing restored it on the way out, so a `while IFS= read -r line` loop downstream never saw a final newline to trigger its last read. Fixed at the source, with a guard so genuinely empty input still produces empty output unchanged.

`| paste` consumers were never affected - `paste` doesn't care about a missing trailing newline - so this was never a problem for those call sites. But it's worth checking which pattern a new stream-form consumer uses: if you pipe `canonical_title`'s stream form into anything that reads line-by-line and stops at EOF without a trailing newline, confirm the last line actually arrives before trusting the output.

---

# Titles Have Zero Character Restrictions - Never Assume Any Character Is a Safe Delimiter

`canonical_title()` places no restriction on what characters a title may contain - not `#`, not anything else. This means no naive split (`cut -d'#'`, a bash `${var%#*}` used blindly, a regex boundary) can be trusted to separate "the title" from "everything after it" in a title-derived string, because a legitimate title can contain the exact character you'd otherwise use as a delimiter (a real article titled "C# Tricks" is the standard example in this codebase).

The only reliable test is "does this candidate resolve against the real index" - which is why `Title#Anchor` navigation (`nina-view.sh`'s `split_title_anchor()`, and the matching backward-split logic duplicated across `nina-dangling.sh`, `nina-backlinks.sh`, `nina-orphan.sh`, `nina-graph.sh`, `nina-stats.sh`, `nina-tree.sh`, and `nina-plugin-helper.sh --backlinks`) always tries the whole input unsplit first, and only walks backward through successive `#` characters - testing the growing prefix against the real index each time - when the whole string fails to resolve. A title that legitimately contains `#` wins outright, on the first check, before any splitting is attempted.

If you're adding a new place that parses a title out of a larger string, don't assume any character is safe to split on. Route through the same backward-search-against-the-real-index pattern, or through `split_title_anchor()` itself if the shape of the problem matches it closely enough.

This duplication across seven-going-on-eight call sites is '''deliberate''', not an oversight worth "cleaning up": each site has a different performance shape (a one-shot resolve vs. a hot loop over every link in the corpus), and the codebase's stated preference is small duplicated scripts over one abstraction trying to serve every shape. Don't centralize this into a shared function without raising it as its own decision first.

---

# `scan_links`'s De-Alias Step Only Fires on a Whole-String Match

`process_line()` inside `scan_links()` rewrites a link target to its real title '''when the entire target text is an alias''', before any anchor-splitting happens downstream (aliases and anchors are unrelated features that happen to interact here). A target like `Alias#Heading` passes through un-dealiased, because `"alias#heading"` is not equal to the alias's own canonical form - only `"alias"` on its own would match.

This means every site that does the backward-anchor-split described above also needs its own alias check on each candidate prefix it tries, in addition to checking the plain existing-title set - it is not redundant with `scan_links`'s own de-aliasing, because that de-aliasing already had its one chance (the whole-string check) and missed. Build the alias lookup the same way the fixed sites do: through `alias_titles()`/`alias_lookup()`, never by reading `index-alias.tsv` directly - `alias_lookup`'s own header comment calls itself out as the only sanctioned reader of that file's format.

---

# `less +/pattern` Is a Regex, Not Literal Text - Escape Before Handing It Search Terms

Anything passed to `less +/pattern` (used by `nina-view.sh` to jump to a heading or phrase inside an opened article) is interpreted as a regular expression by `less`, not matched literally. A heading like "Section 2.1 (Draft)" contains three regex metacharacters (`.`, `(`, `)`) that would silently change what gets matched, or fail to match at all, if handed to `less` unescaped.

`escape_less_pattern()` in `nina-view.sh` exists for exactly this - anything derived from user or corpus text (a heading string, a `#:~:text=` phrase) needs to go through it, or an equivalent, before being interpolated into a `less +/...` invocation. Do not assume a search string is "probably plain enough" to skip this; titles and headings are free text with no character restrictions (see above).

---

# The Renderer Can Emit Fewer Output Lines Than the Source File Has

`nina-render.awk` drops a comment-only line (`/% ... %/` with nothing else on the line) entirely - a bare `next` with no corresponding `print` - rather than rendering it as a blank line. This means a line number in the raw source file and the same content's line number in rendered output are '''not guaranteed to match''', and can silently diverge by however many comment-only lines precede it.

Any future code that wants to jump to a specific spot in rendered output (the way `nina-view.sh`'s anchor navigation does) has to search for text and let `less` find it, rather than computing a target line number from the raw file and asking `less` to jump there directly. This is also why `nina-view.sh` opens `less` with `+/pattern` instead of a computed `+N`.

---

# A Dispatcher Case That Fans Out to Two Scripts by Inspecting an Argument Needs Updating When Either Script's Flags Change

The main `nina` dispatcher is a flat `case "$1" in ... run some-script.sh` table for almost every command - one flag, one script, no branching inside the dispatcher itself. `--tag|-t` is currently the '''only''' exception: it inspects `$2` directly to decide which of two different scripts to run, before either script gets a chance to parse its own arguments:

```--tag|-t)
```    if [[ -z "$2" ]]; then
```        run nina-tag-list.sh
```    else
```        run nina-tag-filter.sh
```    fi
```    ;;

This broke silently when `--tsv` was added to `nina-tag-list.sh`: `nina --tag --tsv` has a non-empty `$2` (`"--tsv"`), so the dispatcher routed it to `nina-tag-filter.sh` instead - which then received `--tsv` as its args, set its own `TSV_MODE=true`, found no tag argument, and died with a usage error. Testing `nina-tag-list.sh --tsv` directly worked perfectly; the bug only existed one layer up, in the routing decision, and nothing about the sub-script's own correctness would ever surface it. '''Fix''': the condition has to know about every flag that legitimately belongs to the "empty-`$2`" side, not just literal emptiness:

```    if [[ -z "$2" || "$2" == "--tsv" ]]; then

If you give a script that's on the receiving end of one of these argument-shape fan-outs a new flag, grep the dispatcher itself for how it's routed there - don't assume the sub-script's own arg-parsing is the only place that needs updating. If a future command gets this same two-scripts-behind-one-flag treatment, the same hazard applies to it.

A smaller, related discovery from the same code: `run()` is defined as `run() { "$SCRIPT_DIR/$1" "${ARGS[@]}"; }`, where `ARGS` is computed '''once''', globally, from the dispatcher's own `$@`. Any argument explicitly passed to `run` at a call site (`run nina-tag-filter.sh "${@:2}"`, as the buggy branch above actually read) is silently ignored - `run` never looks at its own `$2` onward, only at the pre-computed `ARGS`. This isn't wrong, just easy to misread as meaningful; don't assume passing something different to `run` changes what the sub-script receives.

---

# The --tsv / --dot / --count Priority Convention

Several scripts accept more than one of `--tsv`, `--dot`, and `--count` on the same command line (a person is unlikely to combine them, but nothing stops it). The established convention, first set by `nina-orphan.sh` and followed by every script that gained a second flag afterward (`nina-similar.sh`, `nina-search.sh`, `nina-date-filter.sh`, `nina-tag-filter.sh`, `nina-stats.sh`, `nina-tag-list.sh`), is: check `--tsv` (and `--dot`, where it exists) '''before''' `--count`, so combining flags always favors the machine-readable answer over a bare number. Each of those scripts carries a short comment at its `--tsv`/`--dot` block explaining this, referencing the same reasoning back to `nina-orphan.sh`.

`--count`'s own implementation is not required to share code with `--tsv`/display - in several scripts it deliberately doesn't, because a cheaper path exists that the fuller modes can't use. `nina-date-filter.sh`'s `--count` reads only the date column via `index_dates`; its `--tsv` and plain-display modes need title and tags too, so they read `index_display_rows` instead and duplicate the date-range test rather than share it with `--count`. This is intentional, not drift to unify - see "scan_links Is a Single-Pass AWK Function" above for the general principle (get everything from one pass '''when a shared pass is genuinely usable'''), and use judgment about when a mode's cheaper subset of the same data justifies its own independent path instead.

If you're adding `--tsv` (or `--dot`) to a script that already has `--count`, put the new block '''before''' the existing count check, and say why in a one-line comment the same way the existing scripts do - it's not obvious from reading the code alone that this ordering is deliberate rather than incidental.

---

# Not Every --tsv Mode Has a canon/display Pair

[[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Machine-Readable Output (--tsv)]] recommends putting a natural `canon`/`display` pair early in a `--tsv` mode's columns. That guidance is specifically about '''title-derived''' data - it doesn't mean every `--tsv` table needs two columns that look like it.

Two counter-examples worth knowing before reaching for the pattern reflexively:

- `nina --stats --tsv` has no titles in it at all - it's a flat `metric`/`value` table of scalar summary numbers (article count, average tags per article, and so on). There is nothing to pair a canon with.
- `nina --tag --tsv` (routed to `nina-tag-list.sh`) lists tags, not articles. A tag has exactly one true form - `index_tags()` already yields it lowercase and whitespace-collapsed - so there's no separate "display" casing the way a title has (`Apple Pie` vs. its canonical `apple pie`). A `canon`/`display` pair here would just be the same string twice. Its header is `tag`/`count`.

Commands that actually list articles (`nina-search.sh`, `nina-similar.sh`, `nina-date-filter.sh`, `nina-tag-filter.sh`) do get a real `canon`/`display` pair, because their rows really do come from titles that have both a normalized form and a human-facing display form. Before adding one out of habit, ask whether the row is actually about a title - if it isn't, a plain, honestly-named column (or a flat `metric`/`value` table) is the more accurate contract.

A related fact worth knowing if you're deciding whether a new `--tsv` column needs sanitizing before it's safe to print: [[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Titles Are Delimiter-Safe]] documents the tab/newline-safety guarantee by name for '''titles''' only, but `nina-index.sh` actually runs the `Tags` header field through the exact same `normalize_display_title()` call before writing it to the index (with its own comment there: "sanitizes so tabs in field don't corrupt index"). So a `tag` column built from `index_tags()` carries the identical guarantee, even though the invariant section never says the word "tags." Don't assume a written guarantee's scope is its actual scope - check which function a field really passes through, not just which named invariant seems closest.

---

# After a Document Is Renamed, Grep the Whole Tree for the Old Title - Not Just the Obvious Referrer

When [[Nina - Devs: Graph Output Standard (--dot)]]'s title gained its `(--dot)` suffix, a plain-text search for the '''old''' bare title turned up stale `[[...]]` cross-references in seven separate files - `nina-orphan.sh`, `nina-similar.sh`, `nina-link-list.sh`, `nina-lib.sh`, `nina-tag-graph.sh`, `nina-dangling.sh`, and `nina-backlinks.sh` - none of which were the file anyone was actually looking at when the rename happened. Checking only the one or two files that seemed like the obvious place a reference might live would have left most of these stale indefinitely.

If you rename or re-title a document that other files link to, treat it like renaming a function: grep the entire tree for the old title string, not just the files already open for some other reason. Comments accumulate cross-references over a project's whole history, in files that have nothing else to do with the document being renamed.

