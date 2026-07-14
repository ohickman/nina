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

`--dot` is the default and needs no flag; `--tsv` gets you the same edges as plain tab-separated rows (`src_canon`, `src`, `target_canon`, `target`) instead, for piping into other tools:
```nina --graph --tsv

---

# --tree

```nina --tree "Article Title" [--depth N | -d N] [--tsv|--dot]
Required: the article's title. Optional: `--depth`/`-d`, how many hops out to draw (default 2, max 10).

Draws that article's links radiating outward in both directions - backlinks above, forward links below. A `▲`/`▼` marks a node that also links directly back to its immediate parent in the tree, flagging a two-way connection rather than just the one-way path drawn to reach it. Interactive: enter a row's number to open that article, `0` for the center article, or Enter to exit.

```OPTION    MEANING
```------    -------
```--tsv    one row per node, including the center - columns: row, direction, depth, canon, display, mutual
```--dot    Graphviz source - one edge per row, in that row's own real link direction (see below)

`--dot` draws a directed graph: an ancestor row's edge points *toward* the center (that's what makes it an ancestor - it links to whatever's one step closer in), and a descendant row's edge points *away* from it. It uses `rankdir=TB` rather than the usual left-to-right default, since this view is naturally vertical - ancestors above, descendants below - same as the text-mode layout above.
```nina --tree "Article Title" --dot | dot -Tpng -o tree.png

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

# Rendering `--dot` Output

Every `--dot` mode across nina - `--graph`, `--tree`, `--tag-graph`, and several of the commands below - produces the same kind of thing: plain Graphviz source, starting with a `//`-comment line naming the command that produced it, so a saved `.dot` file is still identifiable later even out of context. Pipe it into Graphviz's own tools to get an actual picture:

```nina --tree "Article Title" --dot | dot -Tpng -o tree.png
```nina --graph --dot | sfdp -Tpng -o corpus.png

`dot` lays out hierarchical/directed structure predictably; `sfdp` is more forgiving on a large or densely-connected graph and often a better first try for a whole-corpus `--graph`/`--tag-graph` export. Both read the same input - try whichever gives a more readable layout for what you're looking at.

Edge thickness (`penwidth`) always means the same thing regardless of which command produced it: a stronger relationship - a link count, a co-occurrence count, a `--similar` score - draws a heavier line, scaled by `DOT_PENWIDTH_MIN`/`MAX`/`SCALE` in the config file. Node shape, color, and font are also config-driven (`DOT_NODE_SHAPE`, `DOT_FONTNAME`, and so on). See `nina_conf(5)`, GRAPH OUTPUT (--dot), for the full list of knobs.

---

# Other Ways to Discover Structure

`--graph`, `--tree`, and `--tag-graph` are one family for seeing the corpus as a whole rather than one article at a time. A few more commands, covered in [[Nina - User: Help]], already answer related questions - and, like the three above, most of them also support `--tsv` (plain rows, for piping) and `--dot` (a Graphviz picture) alongside their normal terminal output:

* `--orphan` - articles nothing links to. `--dot` draws each as a standalone, color-flagged node.
* `--dangling` - links pointing at articles that don't exist. `--dot` draws each as a standalone node labeled " (missing)".
* `--backlinks "Title"` - what links to one article. `--dot` draws a small directed graph, everything pointing at that one title.
* `--links "Title"` - what one article links to, unresolved (exactly as written, anchors and all). `--dot` draws a small directed graph, one source fanning out.
* `--similar "Title"` - articles with a lot of shared distinctive vocabulary, whether or not they're linked or tagged alike at all - a relationship the other commands here can't see, since none of them read article *content*. `--dot` draws it as an undirected graph, edge thickness reflecting how similar each match actually is.
* `--stats` - corpus-wide counts.

This is the natural home for any further structure-discovery tools too, as they get built.
