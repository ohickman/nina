# Nina - User: Knowledge Insights
- Tags: nina help graph tree tag-graph structure

Three commands step back from individual articles and look at the shape of the whole knowledge base: `--graph` and `--tree` show how articles link to each other; `--tag-graph` shows how tags relate to each other. See [[Nina - User: Help]] for everything else, or [[Nina - Quick Reference Card]] for a compact printable list.

---

# At a Glance

```COMMAND                                      SHOWS
```-------                                      -----
```nina --graph                                 Every article link, as a Graphviz graph
```nina --tree "Title" [--depth N]              Links radiating out from one article
```nina --tag-graph cooccur [options]           Tags that tend to land on the same article
```nina --tag-graph links [options]             Which tags' articles link to which other tags' articles
```nina --tag-graph islands [options]           Clusters of articles cut off from the rest

---

# --graph

```nina --graph
Prints a Graphviz `digraph` of every `[[link]]` in your knowledge base to standard output - the whole corpus, no arguments. Save it and render it with Graphviz:
```nina --graph > links.dot
```dot -Tpng links.dot -o links.png
An article with no links in either direction won't appear in the graph at all - see `--orphan` below for the list of those.

---

# --tree

```nina --tree "Article Title" [--depth N | -d N]
Required: the article's title. Optional: `--depth`/`-d`, how many hops out to draw (default 2, max 10).

Draws that article's links radiating outward in both directions - backlinks above, forward links below. A `▲`/`▼` marks a node that also links directly back to its immediate parent in the tree, flagging a two-way connection rather than just the one-way path drawn to reach it. Interactive: enter a row's number to open that article, `0` for the center article, or Enter to exit.

---

# --tag-graph

```nina --tag-graph <cooccur|links|islands> [--table|--tree|--tsv|--dot] [--top N] [--min N] [--tag TAG]
Required: exactly one mode (`cooccur`, `links`, or `islands`). Everything else is optional and shared across all three modes:

```OPTION                              DEFAULT           MEANING
```------                              -------           -------
```--table / --tree / --tsv / --dot   --table           output format
```--top N                            25                max rows/islands shown (0 = unlimited)
```--min N                            1 (islands: 2)    minimum count/size to include
```--tag TAG                          (none)            restrict to one tag

## cooccur
Which tags are applied to the same article together, regardless of any links - one count per article per pair of tags it carries.
```nina --tag-graph cooccur
```nina --tag-graph cooccur --tag python
With `--tag`, only pairs involving that tag are kept; `--tree` then shows it as one ranked list of its co-tags.

## links
Rolls the article link graph (the same links `--graph` draws) up to the tag level: for every real link, every tag on the source article is paired with every tag on the target article. A tag paired with itself (`c++ → c++`) means articles carrying that tag mostly link to other articles that also carry it.
```nina --tag-graph links
```nina --tag-graph links --tag c++ --tree

## islands
Connected components of the article link graph - link direction is ignored here, since the question is only "is there any path at all between these two articles". A component with no path to any other component is an island. `--min` defaults to 2 for this mode specifically: a single unlinked article is an ordinary orphan, not an island - pass `--min 1` to see those too.
```nina --tag-graph islands
```nina --tag-graph islands --tag c++ --min 1
With `--tag`, the whole search is restricted to the subgraph of articles carrying that tag before components are computed - "are all my C++ articles one connected web, or several separate pockets?"

## Output Formats
* `table` (default) - readable summary in the terminal.
* `tree` - a boxed listing, same visual language as `--tree` above.
* `tsv` - tab-separated rows, for piping into other tools.
* `dot` - Graphviz source, same convention as `--graph`; `islands` draws each component as its own labeled cluster.

---

# Other Ways to Discover Structure

`--graph`, `--tree`, and `--tag-graph` are one family for seeing the corpus as a whole rather than one article at a time. A few more commands, covered in [[Nina - User: Help]], already answer related questions:

* `--orphan` - articles nothing links to
* `--dangling` - links pointing at articles that don't exist
* `--backlinks "Title"` - what links to one article
* `--stats` - corpus-wide counts

This is the natural home for any further structure-discovery tools too, as they get built.
