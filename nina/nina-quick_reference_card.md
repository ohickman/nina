# Nina - Quick Reference Card
- Tags: nina reference help

This card is deliberately bare. For what any of these actually do, see [[Nina - User: Help]] or [[Nina - User: Getting Started]]. For the structure-discovery commands and their `--tsv`/`--dot` output formats specifically, see [[Nina - User: Knowledge Insights]].

# Basics

```nina                          list all articles
```nina "Article Title"          open an article by title

# All Commands, Alphabetically

```Long form             Short    Action
```---------------------- -------- --------------------------------
```--backlinks <title>   -b       articles linking to <title>
```--config              --       show current config
```--config --edit       --       edit config in your editor
```--config --validate   --       check config for errors
```--dangling            --       links pointing to missing articles
```--date <when>         -d       list/filter articles by date
```--doctor              -D       check knowledge base health
```--file-name <title>   --       print an article's file path (for other scripts)
```--graph               -g       generate a link graph file
```--index               -i       rebuild the article index
```--links <title>       -l       articles linked from <title>
```--macro               --       install/validate macros
```--new <title>         -n       create a new article
```--orphan              --       articles nothing links to
```--plugin              --       install/validate plugins
```--random              -r       open a random article
```--read                --       render piped/stdin input
```--remove <title>      --       delete or archive an article
```--repair              --       interactively fix problems
```--restore [title]     --       restore an archived article
```--resync              --       rename a file to match its title
```--search <query>      -s       full-text search, ranked by relevance
```--stats               --       knowledge base statistics
```--tag [title]         -t       list all tags, or tags of one article
```--tag <tag> --count   --       count articles with a tag
```--tag-graph <mode>    --       tag relationships: cooccur, links, islands
```--tree <title>        --       links radiating out from one article

# By Category

```Viewing
```  nina                       list articles
```  nina "title"               open an article
```  -n, --new <title>          create a new article
```  -r, --random               open a random article
```  --read                     render piped/stdin input

```Search and Filter
```  -s, --search <query>       full-text search, ranked by relevance
```      --count                count matches instead of listing
```      --explain              show relevance score per result
```  -t, --tag [title]          list tags, or tags of one article
```  -t, --tag <tag> --count    count articles with a tag
```  -d, --date <when>          filter by date (see below)

```Connections
```  -l, --links <title>        what this article links to
```  -b, --backlinks <title>    what links to this article
```  --orphan                   nothing links to these
```  --dangling                 links to nothing
```  --graph, -g                export a link graph
```  --tree <title>             links radiating out from one article
```  --tag-graph <mode>         tag relationships: cooccur, links, islands
```  --stats                    overall statistics

```Maintenance
```  --doctor, -D               health check
```  --repair                   interactive fixes
```  --resync                   rename file to match title
```  --index, -i                rebuild the index
```  --config, --config --edit, --config --validate
```  --macro                    install/validate macros
```  --plugin                   install/validate plugins

```Archive
```  --remove <title>           delete or archive
```  --restore [title]          restore from archive

```For Other Scripts
```  --file-name <title>        print an article's file path

# Date Formats (for -d / --date)

```Single day      2026-03-14
```Month           2026-03
```Year            2026
```Range           2026-03-09..2026-03-14
```N-day window    2026-03-14+5
