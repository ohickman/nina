# Nina - Markdown Examples
- Author: Oliver
- Tags: markdown, nina, help
- Alias: markdown

# Text deccoration
**Bold**                    `'''Bold'''`, `**Bold**`
''Italic''                  `''Italic''`, `\\Italic\\`, `*Italic*`
__Underline__               `__Underline__`
~~Strikeout~~               `~~Strikeout~~`
==Highlight==               `==Highlight==`
++Added++                   `++Added++`
--Removed--                 `--Removed--`

# Unparsed Text
`Code` Bracketed in single backtick
``Unparsed`` Bracketed in double backtick
```Full line code ==highlight== ~~strike~~ preceeded by three backticks
```
# Links
[[link]]                    `[[link]]`
[[display|link]]                 `[[display|link]]`
[external](example.com)  `[external](example.com)`

# HTML Characters
Most named characters supported
&forall;   `\&forall;`            &part;   `\&part;`
&exist;   `\&exist;`             &sum;   `\&sum;`
&radic;   `\&radic;`             &there4;   `\&there4;`
&fnof;   `\&fnof;`              &real;   `\&real;`

# Macros
`{{| 75% 30}}`:                  {{| 75 30}} /% 2nd argument (width) optional, % also optional. %/
`{{sparkline 8 6 7 5 3 0 9}}`:   {{sparkline 8 6 7 5 3 0 9}}
`{{gauge 5 bar 0 1 2 8 9 15}}`:  {{gauge 5 bar 0 1 2 8 9 15}} /% Units argument optional %/
`{{days_to_go 1970-01-01}}`:     {{days_to_go 1970-01-01}}
`{{date}}`: {{date}}           `{{time}}`: {{time}}
/% CO%ME/NTS! %/

# Admonitions / callouts
INFO: following text rendered __normally__
NOTE:
TIP:
TODO:
FIXME:
WARNING:

# Full-line Formatting
View the source of this document to reval formatting codes.

## Lists and List-like Formatting

# Headers
## Second level headers
### Third level headers
#### Fourth level header
##### Fifth level header
###### Sixth level header
-  Subtitle

### Unordered Lists
* This is the ''first'' element of the list
** Nested item
***** Skipping levels isn't detected.

### Numbered Lists
1. First line
3. Unfortunately lines are not renumbered.

### Definition Lists
; Item `; Item`
: Definition `: Definition`
::: Deep inset `::: Deep inset`

### To Do lists
[]  things __are not__ done. (one or two spaces between bracket and text ok)
[ ] things __are__ not done. (space in bracket ok)
[x] things that __are__ done. (formatting ignored)
-[] nested item that __is not__ done.
-[x] nested item that __is__ done.
-[ ] open brackets

### Block Quotes
> Accept the moment
>> Act without expectation
