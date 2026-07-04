# Nina - User: Getting Started
- Tags: nina help

# Your Data Is Always Yours
Before anything else: nina stores every note as a plain Markdown text file on your own computer. There is no database, nothing hidden, nothing locked away. You can open any article in any text editor, copy it, move it, back it up, or read it with nina gone entirely - the program is a convenience for browsing and organizing your notes, not a container for them. Nothing you write is ever transformed into a format only nina can read.

With that out of the way - here's enough to get started today. For everything beyond this, see [[Nina - User: Help]].

---

# The Basic Idea
Your knowledge base is a collection of articles, each one a Markdown file. You can think of it like a personal encyclopedia. Articles can link to each other, carry tags, and include dates.

---

# Listing and Opening Articles
```nina
lists all your articles. Type the number shown next to one to open it.

You can also open an article directly by its title:
```nina "Article Title"

To exit an article simply hit `q`.

# Creating a New Article
```nina -n "Article Title"
opens a new file in your text editor with a header already filled in:
```# Article Title
```- Author: YourName
```- Tags:
Write your notes below it. Saving and exiting adds it to your knowledge base.

# Editing Articles
While viewing an article hit `Ctrl + v` to open the editor. When you save your work and exit the editor you will return to viewing the article.

If you change the title of an article or change the tags, nina will not know until the index is updated.  The index is updated with:
```nina --index

# Searching
```nina -s keyword
searches the full text of your articles - titles and body - case-insensitively, and lists matches ranked by relevance. Give it several words to find articles where they appear together:
```nina -s protein folding

# Tags
Add tags to an article's header:
```- Tags: lab equipment protocol
See every tag in use with `nina -t`, or every article with one specific tag using `nina -t sometag`.

# Linking Articles Together
Use double brackets to link to another article:
```See [[Centrifuge Setup]] before starting.
Open the linked article from the article's link list while viewing it.

---

# A Few Tips
* Keep titles short - they're how you'll refer to articles everywhere, including from the command line.
* Tags make filtering later much easier than it feels worth doing on day one.
* If you ever forget everything else, `nina` alone always gets you back to your list of articles.

# What's Next
[[Nina - User: Help]] covers every command in depth - dates, archiving, link analysis, health checks, and more. [[Nina - User: Macros and Plugins]] covers the (optional) system for adding small bits of computed content to your articles. [[Nina - Quick Reference Card]] is a compact, printable command list once you don't need the explanations anymore.
