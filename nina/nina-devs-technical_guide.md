# Nina - Devs: Technical Guide
- Tags: nina dev

# Purpose of This Document
This document explains how nina works internally and how its major pieces fit together. It assumes you've read [[Nina - Devs: Design Philosophy]] - this document is about structure and mechanics, not goals; if something here seems to conflict with that document, the philosophy document is right.

It does not describe every function or every script in detail. A developer should be able to read this once and then comfortably begin exploring the code.

---

# Overview
nina is a command-line personal knowledge management system built around a simple architecture:
1. Markdown files store all user data
2. An index file accelerates queries
3. Small scripts perform individual tasks
4. A shared library enforces consistent data interpretation
5. User-installable macros and plugins extend article rendering

All program behavior emerges from these components. The system avoids complex frameworks, large dependencies, and persistent databases.

---

# Core Components

## The Dispatcher
The command invoked by the user is the dispatcher:
```nina
```nina (dispatcher)
```    ├─ navigation scripts
```    ├─ filtering scripts
```    ├─ maintenance scripts
```    └─ analysis scripts
The dispatcher examines command-line arguments and calls the appropriate script. From the user's perspective the system behaves like a single program, but internally each operation is implemented by a small script.

The dispatcher performs only one task: mapping command-line flags to scripts. It should remain simple and predictable. Logic should not accumulate here.

## Operational Scripts
Most functionality is implemented as small scripts. Each script typically performs a single operation: listing articles, filtering by tag or date, searching titles, analyzing link structure, creating or removing articles.

Operational scripts generally follow the same structure:
1. Determine the script directory
2. Load the shared library
3. Load the configuration file
4. Perform a specific operation
5. Display results to the user

Scripts should avoid reimplementing logic that already exists in the library.

## The Shared Library
The library is the core of the system's internal consistency. It provides shared functions used by many scripts: canonical title rules, slug generation, metadata parsing, link extraction, index lookups, utility helpers.

These functions define how the program interprets article data. When multiple scripts must interpret titles, links, or metadata in the same way, that logic belongs in the library.

## The Knowledge Base
The knowledge base is simply a directory of Markdown files. Each file represents an article. The filename is derived from the article title using a slug format, but the filename itself is not the canonical identifier - the article's title is. This lets users manipulate files directly while the program still reasons correctly about article relationships.

## Article Metadata
Articles begin with a structured header:

```# Article Title
```- Author: Name
```- Tags: tag1 tag2 tag3
```- Date: YYYY-MM-DD

The header provides metadata used by indexing and filtering tools. The body of the file contains Markdown text that may include internal links to other articles.
The article title line is mandatory, the other parts of the header are optional. Typically Date is not included in headers and the file's date is used in the index, but if a user wants a different date used for sorting and searching, as when migrating from another knowledge management system, the date field is provided.

## The Index
```index.tsv
is a generated metadata index containing each article's file path, title, author, modified date, and tags. It accelerates operations that would otherwise require scanning every article file: listing, searching, filtering by tag or date.

The index is always derived data. If it becomes invalid or missing, it can be rebuilt with `nina --index`.

## Macros and Plugins
Macros and plugins both let an article's text call out to a small, user-installable piece of logic - macros transform text only; plugins can additionally read other articles or reach the network, and run with a corresponding amount of additional sandboxing. Both follow the same source-to-artifact pattern as the index, for the same reason: validating every file on every render would be wasteful, so validation happens only when explicitly requested (`nina --macro`, `nina --plugin`), never on every render. See [[Nina - Devs: Macros]] and [[Nina - Devs: Plugins]] for the full mechanics.

---

# Link Model

Articles may reference each other using wiki-style links:
```[[Target Article]]
```[[Display Text|Target Article]]

These links are parsed by scanning article content and extracting the target titles. From this information the system can compute backlinks, orphan articles, dangling links, and link graphs.

---

# Rendering
Articles are displayed in the terminal using a custom Markdown renderer. The renderer intentionally avoids a full Markdown parser - input is processed one line at a time, with no multi-line state machine. Formatting decisions are based solely on the current line. See [[Nina - Devs: Design Philosophy]], Lightweight Parsing, for why this trade-off is deliberate.

This has a sharp, specific consequence worth knowing explicitly: a conventional-looking multi-line fenced code block is only protected on its first and last line, not the content in between. Protecting a multi-line block requires putting the fence marker at the start of every line in it.

Where the lightweight, stateless renderer means that standard Markdown cannot be rendered, an alternative is provided that should be easily recognizable by anyone familiar with common Markdown flavors.

---

# Typical Execution Flow

Most scripts follow a similar sequence: load configuration, ensure the index exists, query the index, optionally read article files directly, present results. For example, listing articles:

```read index.tsv
```sort results
```display table
```allow interactive navigation

The index is the primary data source for most commands.

---

# Link Scanning

Operations that analyze article relationships - backlinks, orphan detection, dangling link detection, graph generation - must read article files directly rather than relying on the index, since the index doesn't store link structure. These tools extract links from articles and compare them against the set of indexed titles.

---

# Error Handling

The system favors graceful degradation (see [[Nina - Devs: Design Philosophy]]). Problems such as duplicate titles, malformed metadata, or invalid dates should not render the entire program unusable. Scripts should skip problematic entries, report warnings, and provide repair tools rather than halting.

Several commands assist with maintenance:
```nina --doctor
```nina --repair
```nina --resync
```nina --macro
```nina --plugin

`--doctor` and `--repair` cover article metadata; `--resync` covers a filename that no longer matches its article's title; `--macro` and `--plugin` cover their respective manifests.

---

# Configuration

User configuration is stored in `~/.nina/config`. This file controls directory locations, rendering settings, behavior flags, and editor preferences. Scripts load it through the library so all components share the same settings.

---

# Directory Structure

Listed here is the default structure. Paths are set in the config file and may be modified.

```~/nina/                      Markdown articles
```~/nina/archive/              archived articles
```~/.nina/config               configuration
```~/.nina/index.tsv            metadata index
```~/.nina/macros/              macro files
```~/.nina/macros.tsv           generated macro manifest
```~/.nina/macros-dispatch.awk  generated macro dispatch code
```~/.nina/plugins/             plugin files
```~/.nina/plugins.tsv          generated plugin manifest

Articles are normal files and may be managed manually if necessary.

---

# System Invariants

The program relies on a few guarantees beyond what's already implied above:

## Titles Are Unique
Each article title must be unique after normalization. Comparison ignores case and collapses whitespace, so small formatting differences don't create duplicate entries.

## Scripts Do Not Mutate User Content - With Narrow, Confirmed Exceptions
This is the same principle [[Nina - Devs: Design Philosophy]] states; this section is the actual current list it points to.

* When archiving or restoring a file would overwrite an existing filename, the colliding file is renamed by appending a reserved, unambiguous disambiguation marker (`--` followed by a timestamp) rather than overwriting anything.
* When the interactive repair tool resolves a duplicate title, the user enters a new title and the script replaces the existing title line at the top of the file with it - it does not add a second title.
* `nina --resync` renames a file (using the same disambiguation marker listed above on a collision) so its filename matches its article's title, but only when the user selects that file from its interactive list and confirms.
* `nina --read`, when reading piped input rather than a named file, has no backing file at all - the data exists only as a temporary in-memory buffer for the duration of the command. If the user edits that buffer and the edit is saved, the script detects the change and prompts for a destination path before exiting; declining the prompt simply discards the edit. If a destination already exists, the same disambiguation marker is offered rather than silently overwriting it. This is the creation of a new file the user explicitly named at the moment of the prompt, not the rewrite of any existing one.

Stream mode has one known rough edge worth being upfront about: if the user's editor is used to save the buffer to a ''different'' path mid-edit (a "save as"), `less` has no way to detect this - it continues displaying the original temp buffer, unaware that a new file now exists elsewhere. Nothing is lost (the new file is real and on disk), but it won't be shown until `nina --read` is run again on that path directly. This is a known limitation of piping `less`'s `v` command through an arbitrary editor, not a bug in the save-prompt mechanism above. A fix is possible (an editor-wrapper that detects this and reloads the buffer) but was judged moderate-value/moderate-effort and deferred.

These are all narrow, user-visible, individually confirmed or directly requested actions - never a silent bulk rewrite.

A related but distinct category: `index.tsv`, `macros.tsv`/`macros-dispatch.awk`, and `plugins.tsv` are not user content at all. They are derived system files the program freely regenerates, the same way a compiler's output is not source code.

---

# Developer Workflow
A developer exploring the codebase should generally follow this order:
1. Read the dispatcher
2. Examine the shared library
3. Review the index generation script
4. Review the macro and plugin systems (see [[Nina - Devs: Macros]] and [[Nina - Devs: Plugins]])
5. Explore operational scripts

---

# Where Logic Should Live
The codebase separates logic into categories:

## Program logic
```belongs in individual scripts

## Data interpretation rules
```belong in the shared library

## User configuration
```belongs in the config file

## User-extensible rendering behavior, limited to transforming given text
```belongs in a macro file

## User-extensible rendering behavior that needs to read other articles or the network
```belongs in a plugin file

The last two are a distinct category from the other three: they are executable code, like program logic, but meant to be written and installed by a user, not a developer. A macro should never reach beyond its own argument text; a plugin's reach is wider but still deliberately bounded - see [[Nina - Devs: Macros]] and [[Nina - Devs: Plugins]].

---

# Performance Considerations
Most commands rely on the index file, which allows queries to run quickly even for large knowledge bases. Commands that must read article files directly may be slower but remain practical for typical personal knowledge bases. Avoid unnecessary scanning of Markdown files when the index already contains the required information.

---

# Guidelines for Adding Features
* Prefer small scripts over large ones
* Reuse library functions whenever possible
* Avoid rewriting user files automatically
* Preserve the plain-text data model
* Keep dependencies minimal

If a feature requires complex parsing or hidden state, it may not align with the goals of the project - see [[Nina - Devs: Design Philosophy]].

---

# Final Advice for New Developers
The system is intentionally simple. Most scripts are small and easy to read. If something seems complicated, it's often helpful to trace how the index is used and how the library interprets article data. Once these pieces are understood, the rest of the system follows.
