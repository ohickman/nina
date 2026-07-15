# Nina - User: Help
- Tags: nina help
- Alias: --help

This is the full command reference. For a first introduction, see [[Nina - User: Getting Started]]. For a compact, printable list once you know what everything does, see [[Nina - Quick Reference Card]]. For a closer look at `--graph`, `--tree`, and `--tag-graph`, see [[Nina - User: Knowledge Insights]].

---

# Titles and Naming

* Each article must have a unique title. Blank titles, and duplicate titles, are not indexed.
* Uniqueness ignores leading/trailing spaces, collapses multiple spaces into one, and is not case-sensitive - `My Article` and `my   article` are the same title.
* Titles with spaces need quotation marks on the command line: `nina "my article"`.

---

# Opening, Creating, and Listing

Open an article by title:
```nina title
If it doesn't exist, you may be prompted to create it - controlled by your config file.

Create an article directly:
```nina -n [title]
or
`1`nina --new [title]

List all articles, sorted by title:
```nina
Sorted by date instead with `-d`/`--date` (see Date Filtering below for everything `-d` accepts).

Search the full text of your articles - titles and body - with `--search`/`-s` (case-insensitive):
```nina --search linux
Multiple words rank articles higher when the words appear close together, in a title, or in a heading:
```nina --search kernel modules
Count matches instead of listing them:
```nina --search linux --count
See the relevance score for each result:
```nina --search linux --explain

---

# Date Filtering
`-d`/`--date` accepts several forms:

```Single day                    2026-03-09
```A whole month                 2026-03
```A whole year                  2026
```A custom range                2026-02-14..2026-03-09
```N days before/after a date    2026-03-09+5

With no value, `-d` lists articles sorted by date instead of title.

---

# Tags

Add tags on a header line:
```- Tags: tag1 tag2 tag3
Tags can't contain spaces, are separated by a space or comma, and are not case-sensitive.

List every tag in use:
```nina --tag
List tags within one article:
```nina --tag "My Article"
Count articles carrying a tag, instead of listing them:
```nina --tag sometag --count

---

# Connections

Links within an article, pointing out:
```nina --links "article title"
Links from other articles, pointing in (backlinks):
```nina --backlinks "article title"
Articles nothing else links to:
```nina --orphan
Links pointing to articles that don't exist:
```nina --dangling

# Statistics and Graphs
```nina --stats
```nina --graph
`--graph` produces a file suitable for graph-visualization tools.

Links radiating out from one article, a few hops in each direction:
```nina --tree "article title"

How tags relate to each other - by co-occurring on the same article, by how their articles link to each other, or by which articles form disconnected clusters:
```nina --tag-graph cooccur
```nina --tag-graph links
```nina --tag-graph islands
See [[Nina - User: Knowledge Insights]] for the full set of options.

---

# Maintenance

Scan for problems with the environment, config, and article files:
```nina --doctor
Interactively fix what it finds:
```nina --repair

Rebuild the article index from scratch:
```nina --index
You shouldn't normally need this - nina keeps the index current automatically - but it's there if something seems out of sync, or if you change the title or tags of an existing article.

View, edit, or validate your configuration:
```nina --config
```nina --config --edit
```nina --config --validate
```nina --config --reset
The last one backs up your current config and replaces it with a fresh, default one - useful if it's gotten into a state you'd rather not untangle by hand. You will be prompted to type `reset` to confirm.

If a file's name no longer matches its article's title, you can bring them back in sync with an interactive tool where you will be pompted before each file is renamed:
```nina --resync
This will help you articles on your file system because the file names will match the titles in your articles.

Install or update your macros and plugins (small bits of computed content you can add to articles - see [[Nina - User: Macros and Plugins|Nina - User: Macros and Plugins#Installing and Enabling]]):
```nina --macro
```nina --plugin

---

# Archive

The config `REMOVE_MODE` has three options that set the behavior of nina when removing files from the knowledge base
* `archive`   An article's file is removed from the knowledge base and moved into the archive set by `ARCHIVE_DIR`.
* `delete`    An article's file is deleted. Note: with most command-line tools, there is no "trash" or "recycle", the files are gone.
* `choose`    You are prompted to decide to delete or archive an article's file. This is the default behavior.

In all cases you will be prompted to type "archive" or "delete" to confirm your choice.

Archived articles are not indexed, cannot be opened with nina, and don't appear in link searches, backlinks, or `--links`/`--backlinks` results, until restored.

Remove one specific article:
```nina --remove [title]
If not title is given an interactive mode will open and you can select an article by number.
Restore one specific article:
```nina --restore "article name"
Or list everything in the archive and choose:
```nina --restore
An article can only be restored if its title is still unique - if not, you'll be prompted to rename it.

---

# Aliases

Aliases let an article be opened, linked to, and tab-completed under names other than its real title. The feature is off by default; turn it on with `ENABLE_ALIASES=true` in your config.

Add one or more alternate names to an article's header:
```- Alias: --help
```- Alias: help command

Each `- Alias:` line adds one alias. Once you add or change aliases, rebuild the index (`nina --index`) so they take effect.

A few rules to keep in mind:
* If an alias collides with any article's real title, the real title always wins and the alias is ignored.
* If two different articles claim the same alias, the alias is dropped for both, and `nina --index` will warn you about it.
* Aliases only resolve when *opening* an article or *linking* to one (`[[Alias Name]]` in article text resolves the same as a real title). Commands that modify the knowledge base directly - `--new`, `--remove`, `--file-name` - accept only real titles, not aliases, to keep those operations unambiguous.

---

# For Scripts Outside Nina

Get the file path for an article by title, for use by other tools:
```nina --file-name "article title"

---

# Other

Open a random article:
```nina --random

Open any markdown file that isn't in nina with its file path.  You can also edit and save just as you would when viewing articles in nina.
```nina --read my_file.md
---

# If You Forget Everything Else
```nina
always lists your articles and lets you navigate from there.
