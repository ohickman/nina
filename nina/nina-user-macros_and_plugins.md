# Nina - User: Macros and Plugins
- Tags: nina help macros plugins

Articles can contain small pieces of text that get replaced with computed content when you view them. There are two systems for this, and they look different on purpose so you can always tell which is which:

```{{name}}
A '''macro''' - transforms text only. Cannot read other articles, cannot reach the network.

```<<name>>
A '''plugin''' - can read other articles in your knowledge base, and - if enabled in the config file - reach the internet. Plugins can never write to files, ever.

By default, in the config file, macros are enabled by and plugins are disabled.

---

# What Ships With Nina

Two macros:
* '''sparkline''' - turns a list of numbers into a tiny inline bar chart, like `{{sparkline 1 5 3 8 2}}` will produce: {{sparkline 1 5 3 8 2}}. 
* '''progress-bar''' (its name is `|`) - draws a filled progress bar, like `{{| 30%}}`.

Two plugins:
* '''TOC''' - inserts a bulleted outline of the current article's headers: `<<TOC>>`.
* '''intro''' - a small demonstration plugin showing off some of what a plugin can do (reading the article, the time, links, and - if you've enabled it - a live web request). This is included as an example to copy from if you are writing your own.

If a macro or plugin name isn't recognized - or isn't installed - whatever you typed is left exactly as written, never an error.

---

# Installing and Enabling

Both systems work the same way: drop a file into a directory, run a command to validate and install it, then turn it on in your config.

`~/.nina/macros/`      macro files go here
`~/.nina/plugins/`     plugin files go here

`nina --macro`         validate and install macros
`nina --plugin`        validate and install plugins

`ENABLE_MACROS=true`   in `~/.nina/config`, turns macros on
`ENABLE_PLUGINS=true`  in `~/.nina/config`, turns plugins on

Installing doesn't enable - plugins are off by default. If a flag is off, or you've never run the install command, every `{{...}}` or `<<...>>` in your articles is just left as literal text. Nothing breaks either way.

# Plugins and the Network

A plugin can only reach the internet if you separately turn on:
`PLUGIN_PERMIT_WEB=true`
in your config. This is off by default even when plugins themselves are enabled - a plugin can be installed and running while still being unable to make a network requests, until you decide otherwise.

---

# If a Macro Crashes

A macro is supposed to handle bad input itself - if you mistype a macro's arguments, a well-written macro returns a short, readable error message in place of its normal output, right where the `{{...}}` was, with the rest of the article rendering normally below it.

Occasionally a macro won't catch a bad input case and the underlying AWK process will crash instead. When that happens, rendering stops at that point - everything above the crash is still shown, but nothing below it renders. Nina prints a message explaining that rendering stopped partway through and suggesting `nina --doctor` or `nina --macro` as next steps, so you have a clear way to find and fix the macro responsible, rather than just watching the screen stop with no explanation.

This is a known limitation of how macros run today, not something nina is expected to fully recover from - see [[Nina - Devs: Macros|Nina - Devs: Macros#When a Macro Crashes at Render Time]] if you're curious why.

# Uninstalling Macros and Plugins

Uninstalling is similar to installing: delete the macro or plugin from its directory, then run `nina --macro` or `nina --plugin`. Anywhere an article calls the uninstalled macro or plugin simply be displayed as text `{{...}}` or `<<...>>`.

---

# If Something Isn't Working
```nina --doctor
checks the health of your installed macros and plugins alongside everything else - which files failed validation and why, whether anything's changed on disk since you last ran `nina --macro`/`nina --plugin`, and the current state of the relevant config flags. Worth running first if a `{{...}}` or `<<...>>` you expected to work is just sitting there as literal text.

---

# If You Want to Write Your Own

That's developer territory - see [[Nina - Devs: Macros]] or [[Nina - Devs: Plugins]] for the authoring contract, the safety rules, and the available functions.
