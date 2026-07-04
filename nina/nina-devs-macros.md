# Nina - Devs: Macros
- Tags: nina dev macros

# Purpose of This Document
This is the authoring and architecture reference for macros, aimed at developers. For the user-facing contract - what macros are, how to install one, what ships by default - see [[Nina - User: Macros and Plugins]]. This document assumes you've read that and explains the mechanics and the reasoning behind them.

---

# Why Macros Exist As Their Own Category
[[Nina - Devs: Design Philosophy]] and [[Nina - Devs: Technical Guide]] both place "user-installable rendering behavior" in its own category, distinct from program logic, library logic, and configuration. A macro is executable code, like a script, but it's meant to be written and installed by a user rather than a developer, and its reach is deliberately narrow: a macro only ever sees the argument text typed after its own name. It cannot read other articles, cannot reach the network, and has no access to program state. [[Nina - Devs: Plugins]] exists precisely because that narrowness is sometimes too limiting - a plugin is the answer when a macro's reach genuinely isn't enough.

# The Source-to-Artifact Pattern
Macros follow the same pattern as the index: validating every macro file on every render would be wasteful, so validation happens only when explicitly requested, via `nina --macro`, never automatically.

* Each macro is one plain AWK file in `MACROS_DIR`.
* `nina --macro` scans that directory, validates every file it finds, and writes two generated artifacts: a manifest (`macros.tsv`) listing every macro that passed validation, and a dispatch file (`macros-dispatch.awk`) containing the name-to-function lookup the renderer calls at render time.
* The renderer never validates anything itself - it reads the generated dispatch file and loads exactly the macro files the manifest lists. A macro is only as current as the last time `nina --macro` was run, the same way the index is only as current as the last `nina --index` run.
* A macro file that fails validation is excluded, not repaired; `nina --macro` reports why - identical in spirit to how `nina --index` handles a damaged article.

AWK has no mechanism for indirect or dynamic function calls - no way to compute a function name as a string and call it. This is why the dispatch file has to be generated, literal code (`if (name == "x") return macro_x(args)`) rather than something the renderer computes on the fly. It's the one place in the codebase where generated ''code'', not just generated data, is the derived artifact.

---

# Writing a Macro

A macro file is a plain AWK script. A reasonable way to learn the shape is to read one of the shipped examples - `sparkline.awk` or `progress-bar.awk` - rather than starting from nothing.

A macro file has exactly two requirements:

## 1. The first line must be a comment naming the macro

Everything after `#`, trimmed of leading/trailing spaces, is the name a person types inside `{{...}}`. A macro name cannot contain a space or a `}` - either would make it impossible for nina to tell where the name ends. The name is matched exactly as written.

## 2. The file must define a specific function name

The function nina calls is derived from the ''filename'', not anything written inside the file: take the filename without `.awk`, replace every character that isn't a letter, digit, or underscore with an underscore, and prefix with `macro_`.

```Filename               Required function name
```--------               -----------------------
```date.awk               macro_date
```progress-bar.awk       macro_progress_bar
```my.macro.awk           macro_my_macro

The function must accept exactly one argument (the text typed after the macro's name), even if it ignores it, and must `return` the replacement text. A macro is a pure text transform - it should never have side effects, and should never depend on anything beyond its own argument and the handful of built-in values nina provides (`TODAY`, `NOW`).

For a worked example, here's the real shape of the shipped `progress-bar.awk` (invoked as `{{| 30%}}` or `{{| 30% 10}}` - the macro's name is literally `|`):

```# |
```
```function macro_progress_bar(args, ...) {
```    n = split(args, parts, " ")
```    pct = parts[1]
```    ...
```    return bar
```}

The internals aren't worth memorizing - what matters for authoring purposes is the shape: name comment, one function, one argument string in, one string out.

## A note on validating input

A macro receives raw, untrusted text - a user can mistype arguments, paste the wrong thing, or leave a `{{...}}` example unprotected by backticks in their own notes and have it rendered as a real macro call. AWK has no exception handling: a fatal runtime error (division by zero, an out-of-range array reference, and so on) kills the entire render process immediately, not just the one macro call. Everything already printed stays on screen; everything after the crash point never renders, and there is no way for nina to recover mid-render once that happens.

This means input validation is the macro author's responsibility, not something the engine can safely do generically on a macro's behalf - the engine can't know what "valid input" means for an arbitrary macro's argument format. A macro should check that it received the arguments it expects (right count, right type) ''before'' doing any arithmetic or indexing that could fault, and return a short, readable error string instead - the same way an unrecognized macro name is left as literal text rather than treated as an error. For example:

```if (argc < 8) {
```    return "{{gauge: expected at least 8 arguments, got " argc "}}"
```}
```if (value_str !~ /^-?[0-9]+(\.[0-9]+)?$/) {
```    return "{{gauge: non-numeric value - usage: {{gauge value min ...}}}}"
```}

nina still detects the case where a macro crashes anyway - see [[Nina - User: Macros and Plugins]] for what the user sees when that happens - but that's a backstop, not a substitute for validating input in the macro itself. A macro that validates its own arguments degrades gracefully; a macro that doesn't can take down the entire render with it.

## A note on helper functions

AWK has no private, nested, or per-file function scope - every function name in every loaded macro file shares one global process-wide namespace. If your macro needs helper functions, give them distinctive names (prefixed with your macro's own name, for example) so they don't collide with some other macro author's helper. A collision between two macro files' function names - the main function or a helper - prevents '''all''' macros from loading, not just the two that collided.

---

# When a Macro Fails to Install

`nina --macro` never refuses to finish and never asks the user to fix anything interactively - it decides which files it can trust, reports why on anything it couldn't, and moves on, the same way `nina --index` handles a damaged article. A macro that fails to install does not affect any other macro.

Reasons a macro file can be rejected:

* '''Syntax error.''' Not valid AWK at all.
* '''Missing or invalid name.''' First line isn't a name-declaring comment, or the name is empty, contains a space, or contains `}`.
* '''Function not found.''' The file doesn't define the exact function name its filename requires.
* '''Duplicate macro name.''' Two files declare the same name. Neither loads until one is renamed or removed.
* '''Duplicate function name.''' Two files derive the same function name from their filenames (`progress-bar.awk` and `progress_bar.awk` both derive `macro_progress_bar`). Neither loads until one is renamed.

`nina --doctor` gives a fuller health report, including macros that have changed on disk since `nina --macro` was last run - it duplicates `nina --macro`'s validation logic independently on purpose, rather than calling it, the same reasoning as in [[Nina - Devs: Plugins]] for why its health check is built the same way.

---

# When a Macro Crashes at Render Time

Install-time validation (`nina --macro`) and render-time failure are two different things. A macro can pass every install-time check - valid syntax, correct name, correct function - and still crash later if it's given input it didn't account for, because validation only confirms the file is well-formed AWK, not that its logic handles every possible argument string.

`nina-render.awk` runs as a single AWK process alongside every loaded macro file, so there is no per-macro isolation: a fatal error in any one macro's function kills that whole process. There's no `try`/`catch` in AWK and no way for nina to intercept the failure and resume rendering from the next line - the renderer's design is a deliberate single-pass pipeline (see [[Nina - Devs: Technical Guide]]), and adding per-macro isolation would mean spawning a subprocess per `{{...}}` call or splitting macro expansion into a separate pre-pass, either of which trades away the simplicity and performance of the current design for a failure mode that's better prevented than caught (see the validation note above).

What nina does instead: `nina-render.sh` checks the AWK process's exit status after the pipeline finishes. A non-zero exit means something crashed mid-render, and nina prints a message via the same `error()` function used elsewhere for unrecoverable problems, pointing the user at `nina --doctor` and `nina --macro` as next steps. This doesn't recover the lost output - whatever rendered before the crash stays on screen, whatever was after it is simply never shown - but it replaces a silent, unexplained stop with a clear signal that something went wrong and where to look.

This is why the validation guidance above matters: the engine-side message tells the user '''that''' something crashed, not '''which''' macro or '''why'''. A macro that validates its own input and returns a readable error string gives the user both, inline, in the article, with the rest of the render still intact.

---

# Reference

```~/.nina/macros/              where macro files live
```~/.nina/macros.tsv           generated manifest (don't edit by hand)
```~/.nina/macros-dispatch.awk  generated dispatch logic (don't edit by hand)

```nina --macro                 scan, validate, and install macros

```MACROS_DIR                   config variable - where to look for macro files
```ENABLE_MACROS                config variable - turn macro expansion on/off
