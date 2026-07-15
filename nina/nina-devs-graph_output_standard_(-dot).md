# Nina - Devs: Graph Output Standard (--dot)

This is the `--dot` counterpart to "Machine-Readable Output (--tsv)" in
[[Nina - Devs: Technical Guide]]. That section is the contract structured
data consumers (nina itself, a future TUI/GUI, `awk`, etc.) depend on. This
section is the contract Graphviz output depends on, so that every command's
`--dot` mode looks like it came from the same program instead of six
people's separate guesses at what a graph should look like.

This standard was written when only two commands shipped `--dot` output
(`nina --graph`, `nina --tag-graph --dot`), each written independently
before the standard existed and disagreeing with each other in small ways
- only one of them escaped quotes and backslashes in labels, for
instance. Bringing both onto the shared helpers below, alongside every
`--dot` mode added since, was part of adopting this standard, not a
separate cleanup - see "Migration Note (Completed)" at the end of this
document.

---

# Why This Needs To Be a Standard At All

A `--tsv` mode has one job: be correct, parseable data. A `--dot` mode has
two: be correct, parseable Graphviz *and* look like it belongs to the same
tool as every other graph nina draws. Node shapes, edge weight scaling,
label conventions, escaping - if each command invents its own answer, the
person piping five different `--dot` outputs into `dot -Tpng` gets five
different visual languages, and the "which articles are strongly related"
signal that edge weight is supposed to carry stops being comparable across
commands. This standard exists so that signal is uniform: a penwidth of 4
means the same relative strength whether it came from `--similar`,
`--tag-graph links`, or `--backlinks`.

---

# Self-Describing Header Comment

Every `--dot` mode's first line of output identifies what produced it,
mirroring the way every `--tsv` mode's first line is a header naming its
columns:

```
// nina --tree --depth 2 "Article Title" --dot
digraph nina_tree {
```

Use DOT's actual comment syntax - `//` - not a `#`-prefixed line. DOT
discards lines starting with `#` too, but that behavior exists for
C-preprocessor line markers, not as a documented comment form; `//` and
`/* */` are the real comment syntax, defined the same way in every
conformant parser (`dot`, `neato`, `sfdp`, `fdp`, `circo`, `twopi`, and
libraries built on the same grammar), so there's no reason to depend on
the more incidental of the two mechanisms.

This line is mandatory on every mode, including a graph with zero edges -
same reasoning as the `--tsv` header being required on zero rows. A person
piping `--dot` output somewhere, or finding a saved `.dot` file later,
should be able to tell what generated it without needing to already know.

Print it via the `dot_comment` helper (see below), once, before
`dot_graph_open`.

---

# Config Variables

This standard adds a section to `~/.nina/config`, alongside the existing
`RENDERING STYLES` block:

```
#################################
# GRAPH OUTPUT (--dot)
#################################

# Edge penwidth scaling. A raw strength value (a link count, a
# co-occurrence count, a --similar score) maps onto a penwidth via:
#     penwidth = min(DOT_PENWIDTH_MAX, DOT_PENWIDTH_MIN + strength / DOT_PENWIDTH_SCALE)
# MIN keeps even a single-count edge visibly a line, not a hairline.
# MAX keeps one outlier edge from making every other edge in the same
# graph look like a hairline by comparison. SCALE controls how quickly
# a rising strength approaches MAX - a smaller SCALE saturates sooner.
DOT_PENWIDTH_MIN=1.0
DOT_PENWIDTH_MAX=6.0
DOT_PENWIDTH_SCALE=5

# Node appearance, shared by every --dot mode.
DOT_NODE_SHAPE="box"
DOT_NODE_STYLE="rounded"
DOT_FONTNAME="Helvetica"
DOT_FONTSIZE=10

# Default layout direction. Individual commands may override this
# (see "Graph Direction and Rankdir" below) but should not invent a
# different default of their own.
DOT_RANKDIR="LR"

# Whether edges are labeled with their raw strength value. Off this
# just draws unlabeled weighted lines - some people will prefer the
# uncluttered look once the corpus gets large.
DOT_SHOW_EDGE_LABELS=true

# Fill color for a node --orphan --dot or --dangling --dot draws to
# call out a problem node (see "Problem-Node Modules" below). Not
# used by any of the "real relationship" graphs.
DOT_PROBLEM_NODE_COLOR="#f8d7da"
```

These live in the same file, loaded the same way, as every other config
value - no new loading mechanism.

---

# Shared Library Helpers

Everything below lives in `nina-lib.sh` so every `--dot` mode calls
the same code instead of re-implementing it. This is the same reasoning
[[Nina - Devs: Technical Guide]] already gives for `canonical_title()`
under "a second hand-written copy of those rules is a bug magnet" -
escaping and weight scaling are exactly that kind of rule.

## `dot_comment TEXT`
Prints a single `// TEXT` line. Used once per invocation, before
`dot_graph_open`, to emit the mandatory self-describing header (see
"Self-Describing Header Comment" above):

```bash
dot_comment() {
    printf '// %s\n' "$1"
}
```

## `dot_escape TEXT`
Escapes backslashes and double quotes so `TEXT` is safe inside a quoted
Graphviz label or node ID (`\` -> `\\`, `"` -> `\"`). Every node name and
every label that isn't a bare number goes through this before it's
printed - including titles. Adopting this was a real behavior change for
`--tag-graph`'s pre-standard output, which didn't escape at all: a tag or
title containing a `"` used to produce broken dot source.

## `dot_weight STRENGTH`
Replaced the old local `scaled_weight()` that used to live in
`nina-tag-graph.sh`, generalized to read `DOT_PENWIDTH_MIN` /
`DOT_PENWIDTH_MAX` / `DOT_PENWIDTH_SCALE` from config instead of
hardcoding `1`, `6`, and `5`. Accepts a float (a `--similar` score) as
readily as an integer (a link count):

```bash
dot_weight() {
    awk -v s="$1" -v min="$DOT_PENWIDTH_MIN" -v max="$DOT_PENWIDTH_MAX" -v scale="$DOT_PENWIDTH_SCALE" \
        'BEGIN { w = min + s/scale; if (w > max) w = max; printf "%.1f", w }'
}
```

## `dot_graph_open NAME DIRECTED`
Prints the opening line and shared graph-level attributes. `DIRECTED` is
`true` or `false` and picks `digraph` vs `graph` (see "Graph Direction"
below). Call `dot_comment` first, separately - this function does not print
the header comment itself:

```bash
dot_graph_open() {
    local name="$1" directed="$2"
    if [[ "$directed" == true ]]; then
        echo "digraph $name {"
    else
        echo "graph $name {"
    fi
    echo "    rankdir=$DOT_RANKDIR;"
    echo "    node [shape=$DOT_NODE_SHAPE, style=$DOT_NODE_STYLE, fontname=\"$DOT_FONTNAME\", fontsize=$DOT_FONTSIZE];"
    echo
}
```

## `dot_graph_close`
Just `echo "}"` - exists mainly so every command closes the same way and a
future change (a trailing comment, say) has one place to happen.

## `dot_edge FROM TO STRENGTH DIRECTED [LABEL]`
The workhorse. Escapes both endpoints, computes the penwidth, and prints
one edge line. `LABEL` defaults to `STRENGTH` itself; pass an explicit
`LABEL` when the raw strength isn't what should be displayed (e.g.
`--similar`'s score rounded to two decimals while the underlying value
has more precision):

```bash
dot_edge() {
    local from="$1" to="$2" strength="$3" directed="$4" label="${5:-$3}"
    local arrow="->"; [[ "$directed" != true ]] && arrow="--"
    local ef et w
    ef="$(dot_escape "$from")"
    et="$(dot_escape "$to")"
    w="$(dot_weight "$strength")"
    if [[ "$DOT_SHOW_EDGE_LABELS" == true ]]; then
        printf '    "%s" %s "%s" [label="%s", penwidth=%s];\n' "$ef" "$arrow" "$et" "$label" "$w"
    else
        printf '    "%s" %s "%s" [penwidth=%s];\n' "$ef" "$arrow" "$et" "$w"
    fi
}
```

## `dot_node NAME [EXTRA_ATTRS]`
Prints a standalone node declaration with optional extra Graphviz
attributes appended verbatim (used by the problem-node modules below to
add `fillcolor`). A plain relationship graph never needs to call this -
nodes that appear in an edge are declared implicitly by Graphviz itself,
same as today.

```bash
dot_node() {
    local name="$1" extra="${2:-}"
    printf '    "%s"%s;\n' "$(dot_escape "$name")" "${extra:+ [$extra]}"
}
```

---

# Graph Direction and Rankdir

Whether a mode emits `digraph` (directed, `->`) or `graph` (undirected,
`--`) follows the same rule already implicit in `--graph` and
`--tag-graph` before this standard existed, made explicit and now applied
to every mode:

* **Directed** when the underlying relationship has a real direction:
  article A links to article B, tag A's articles link to tag B's
  (`--graph`, `--tag-graph links`, `--links`, `--backlinks`).
* **Undirected** when the relationship is inherently symmetric:
  co-occurring tags, mutual similarity scores (`--tag-graph cooccur`,
  `--similar`).

`rankdir` stays `LR` by default per `DOT_RANKDIR` for every mode. A
command is free to override it locally (e.g. `--tree --dot`, radiating
from a center node, may read better with a different layout) but should
say so explicitly in its own comment line (see "Self-Describing Header
Comment" above), not silently diverge.

---

# Problem-Node Modules (`--orphan`, `--dangling`)

`--orphan` and `--dangling` aren't relationship graphs - an orphan has no
incoming links *to* draw, and a dangling link's target doesn't exist as a
node at all. Their `--dot` output does not use `dot_edge`. Instead it
declares each flagged item as a standalone node via `dot_node`, styled
with the config's problem color:

```bash
dot_node "$title" "style=\"rounded,filled\", fillcolor=\"$DOT_PROBLEM_NODE_COLOR\""
```

For `--dangling` specifically, where the "node" is a link target that has
no corresponding article, label it distinctly (e.g. append " (missing)"
to the node label) so it's visually obvious in the rendered image that
this isn't a real article - it's a link pointing at nothing.

Neither mode produces edges. This is a deliberate, documented exception to
"every `--dot` mode is a graph of edges" - noted here so the next person
implementing one of these doesn't go looking for a relationship to draw
that doesn't exist.

---

# Naming Convention

Every `--dot` mode's `digraph`/`graph` name follows `nina_<command>` or
`nina_<command>_<mode>`, matching what `--graph` (`nina`) and
`--tag-graph` (`nina_cooccur`, `nina_tag_links`) already do:

| Command | Graph name |
|---|---|
| `--graph` | `nina` (existing, unchanged) |
| `--tag-graph cooccur --dot` | `nina_cooccur` (existing, unchanged) |
| `--tag-graph links --dot` | `nina_tag_links` (existing, unchanged) |
| `--tag-graph islands --dot` | `nina_islands` |
| `--tree --dot` | `nina_tree` |
| `--backlinks --dot` | `nina_backlinks` |
| `--orphan --dot` | `nina_orphan` |
| `--similar --dot` | `nina_similar` |
| `--links --dot` | `nina_links` |
| `--dangling --dot` | `nina_dangling` |

---

# What This Standard Does Not Cover

Colors, dark backgrounds, and layout engine choice (`dot` vs `sfdp` vs
`neato`) are a rendering-time decision the person makes when they run
`dot -Tpng` / `sfdp -Tpng` on the output, not something nina's `--dot`
modes should hardcode. `bgcolor` is deliberately absent from
`dot_graph_open` for this reason - it belongs to the person's own render
step, not to source that different people will render different ways.

---

# Migration Note (Completed)

`--graph` and `--tag-graph --dot` predate this standard and were the two
commands it had to be retrofitted onto without changing what they draw.
Both now call the shared helpers above, along with every other `--dot`
mode added since. The node and edge *sets* either command produces for a
given corpus are unchanged from before the migration - what changed is
the escaping (now correct instead of absent, for `--tag-graph`), the
source of the styling constants (config instead of hardcoded), and the
addition of the mandatory header comment line.
