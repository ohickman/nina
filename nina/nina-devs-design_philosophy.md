# Nina - Devs: Design Philosophy
- Tags: nina dev philosophy

# Purpose of This Document
This document gives new developers a quick understanding of the design philosophy and guiding principles behind nina. It is not a technical reference and does not describe individual scripts or functions - see [[Nina - Devs: Technical Guide]] for that. Instead, it explains the goals of the project and how design decisions should be approached when contributing to the codebase.

This document assumes you've read the user-facing documentation - [[Nina - User: Getting Started]] and [[Nina - User: Help]] - and know what nina does from a user's perspective. This document is about why it's built the way it is, not what it does.

A developer should be able to read this document in a few minutes and understand the mindset behind the system.

---

# Project Overview
This project is a command-line personal knowledge management system built around a simple idea: the knowledge base is a collection of Markdown files stored on the filesystem.

The program provides tools that help users work with those files:

* building and maintaining an index
* searching and filtering articles
* navigating between linked articles
* analyzing structure (links, orphans, statistics)
* rendering Markdown in the terminal

All interaction occurs through standard UNIX command-line workflows.

The system intentionally avoids databases, proprietary formats, or hidden storage layers. Every article exists as a normal Markdown file that the user can view, edit, copy, or move using ordinary tools.
---

# Core Philosophy

## Plain Text First
The Markdown files are the canonical representation of the knowledge base.

They are not generated data and should remain readable and editable outside of the program.

A user should always be able to:
* open an article in any editor
* move or copy files manually
* use standard UNIX tools on the data

The program exists to assist with organizing and navigating those files, not to control them.

---

# Derived Data Is Disposable
The system maintains an index file to speed up queries and navigation.

This index is derived data.

It can always be rebuilt from the Markdown files.

If the index is lost, corrupted, or deleted, the system should be able to regenerate it entirely from the articles.

This design removes the risk of catastrophic data loss and keeps the storage model simple.

The same principle is why macro and plugin manifests work the way they do - see [[Nina - Devs: Macros|Nina - Devs: Macros#The Source-to-Artifact Pattern]] and [[Nina - Devs: Plugins|Nina - Devs: Plugins#Validation and the Hash Check]].

---

# Scripts Interpret Data, They Do Not Own It
The program reads and interprets Markdown files but generally does not rewrite them.

Users retain ownership of their files.

Scripts should avoid modifying article content unless explicitly requested by the user.

When a change must be made automatically, it should be minimal, transparent, and easy for a user to undo manually.

A handful of narrow, user-confirmed exceptions exist today (filename disambiguation on a collision, replacing a title line during interactive repair, `nina --resync` renaming a file the user explicitly selected). See [[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Scripts Do Not Mutate User Content - With Narrow, Confirmed Exceptions]] for the current list - this document states the principle a feature should be measured against, not an inventory of every exception.

---

# Small Tools, Simple Behavior

The system is built as a collection of small scripts rather than a single large program.
Each script should perform one clear task and rely on shared library functions for common operations.

## Benefits of this approach:
* code is easy to read
* debugging is straightforward
* behavior is predictable
* contributors can understand the system quickly

When in doubt, prefer simple scripts over clever abstractions.

---

# UNIX-Native Design

The program is designed to behave like traditional command-line utilities.
Commands are driven by flags.
Output is text.
Programs compose naturally with standard tools.

Examples of this philosophy include:
* plain-text output suitable for piping
* predictable argument handling
* simple configuration files
* minimal dependencies

The goal is to make the program feel like a natural part of the UNIX environment.

---

# Lightweight Parsing

The renderer and other components intentionally avoid complex parsing.
Many operations process input one line at a time without maintaining large state machines.

This design keeps the system:
* fast
* portable
* easy to reason about

Some Markdown features may therefore be approximated rather than fully implemented. This trade-off is intentional. See [[Nina - Devs: Technical Guide|Nina - Devs: Technical Guide#Rendering]] for what this means concretely for the renderer.

---

# Graceful Degradation

The system favors resilience over strict enforcement.
If the knowledge base contains problems such as malformed metadata, duplicate titles, or missing links, the program should attempt to continue operating whenever possible.

Instead of halting execution, the program should:
* skip problematic entries
* issue warnings
* provide tools to diagnose and repair issues
This ensures that one damaged article does not render the entire system unusable.

This same instinct extends to user-installed extensions: an unrecognized macro or plugin call, or one that fails outright, is left as the literal text it was written as - never an error, never silently replaced with nothing. See [[Nina - Devs: Macros|Nina - Devs: Macros#:~:text=unrecognized macro name is left as literal text]] and [[Nina - Devs: Plugins|Nina - Devs: Plugins#Failure Handling]].

---

# Developer Guidelines

When proposing or implementing changes, consider the following questions:
* Does this preserve the plain-text data model?
* Does the system remain recoverable if derived data is deleted?
* Does the feature introduce complex parsing or hidden states?
* Does the change keep scripts understandable to a new contributor?
* Does the solution align with common UNIX command-line behavior?
If a feature requires heavy parsing, rewriting user files, or introducing complicated infrastructure, it probably conflicts with the goals of the project.

When an extension meets these tests and should be added to the code base, you next need to know where to put it:
* Is this interpreting data? > library
* Is this selecting rows? > query layer within scripts
* Is this implementing user behavior? > scripts
* Is this rendering behavior, limited to transforming the text it's given? > macros (see [[Nina - Devs: Macros]])
* Is this rendering behavior that needs to read other articles or reach the network? > plugins (see [[Nina - Devs: Plugins]])
---

# Final Thoughts
This project prioritizes clarity, durability, and simplicity over feature complexity.
The goal is not to replicate every capability of large knowledge systems, but to provide a reliable and transparent tool that works well within a terminal environment.
Good contributions keep the code easy to read, preserve user control over data, and maintain the philosophy that the knowledge base is ultimately just a directory of Markdown files.
