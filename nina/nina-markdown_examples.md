# Nina - Markdown Examples
- Author: Oliver
- Tags: markdown, nina, help
- Alias: markdown

# Text deccoration
**Bold**                     `'''Bold'''`, `**Bold**`
''Italic''                   `''Italic''`, `\\Italic\\`, `*Italic*`
__Underline__                `__Underline__`
~~Strikeout~~                `~~Strikeout~~`
==Highlight==                `==Highlight==`
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
&forall;                        `\&forall;`
&part;                        `\&part;`
&exist;                        `\&exist;`
&isin;                        `\&isin;`
&sum;                        `\&sum;`
&frasl;                        `\&frasl;`
&radic;                        `\&radic;`
&infin;                        `\&infin;`
&int;                        `\&int;`
&there4;                        `\&there4;`
&sup;                        `\&sup;`
&perp;                        `\&perp;`
&sup1;                        `\&sup1;`
&sup2;                        `\&sup2;`
&sup3;                        `\&sup3;`
&fnof;                        `\&fnof;`
&real;                        `\&real;`
## Some of these are problematic
`U+02182`        U+02182
`\&#x2182;`       ↂ
`\&#8578;`        8
`\&#0x123;`       &#0x123;
`\&0x123;`        &0x123;
`\&#123;`         1
`\&123;`          &123;
`\&123;`          &123;
`\&x123;`         &x123;
`\&#124;`         1 
`\&#1234;`        1



# Headers
## Second level headers
### Third level headers
#### Fourth level header
##### Fifth level header
###### Sixth level header
-  Subtitle: `-`

# Macros
`{{| 75 30}}`75% progress bar, 50char wide:   {{| 75 30}} /% 2nd argument, width, is optional %/
`{{sparkline 34 24 88 50 40 20 22 50 55 60 70 80 90 75 50}}` Sparkline:  {{sparkline 34 24 88 50 40 20 22 50 55 60 70 80 90 75 50}}
`{{gauge 60 PSI 0 20 40 100 120 150}}` {{gauge 60 PSI 0 20 40 100 120 150}}
Days to go: {{days_to_go 2027-01-01}}
`{{date}}`: {{date}}, `{{time}}`: {{time}}
/% CO%ME/NTS! %/

# Admonitions / callouts
INFO:
NOTE:
TIP:
TODO:
FIXME:
WARNING:
/% {{merge|title}} {{split|title}} {{intigrate}} {{poor formatting}} {{contains errors}} {{obsolete}} {{fact checked}} {{not fact checked}} %/

# Lists and List-like Formatting

# Headers
## Second level headers
### Third level headers
#### Fourth level header
##### Fifth level header
###### Sixth level header
-  Subtitle: `-`

## Unordered Lists
* This is the ''first'' element of the list
** Nested item
***** Skipping levels isn't detected.

## Numbered Lists
1. First line
3. Unfortunately lines are not renumbered.

## Definition Lists
; Item `; Item`
: Definition `: Definition`
::: Deep inset `::: Deep inset`

## To Do lists
[]  things __are not__ done. (one or two spaces between bracket and text ok)
[ ] things __are__ not done. (space in bracket ok)
[x] things that __are__ done. (formatting ignored)
-[] nested item that __is not__ done.
-[x] nested item that __is__ done.
-[ ] open brackets

## Block Quotes
> Accept the moment
>> Act without expectation
