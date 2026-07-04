# nina
Nina Indexed Note Application - A personal knowledge management system

Nina is a knowledge management system built around a couple core philosophies:
1) Knowledge is stored in individual Markdown (.md) files.
2) The .mds shall remain readable, editable, accessible to the user.  Always.
3) Nina does not overwrite user data (except in very limited, explicitly communicated instances)
4) Nina is here to help the user find, sort, edit, view their markdown files.

Knowledge management systems come and go and with Nina you will never lose access to your knowledge base because the project is not maintained.  You always retain full control over your files and may edit them with any text editor and use any scripting or command line tools on them just as you can with any other text file.

# Installation
1) By default program files are in `.nina`, data files are in `nina`.  Place both of these directories and their contents in your home directory.
2) Make the shell scripts in `.nina` executable by navigating to that folder and running `chmod +x *.sh`.
3) Add nina to your `$PATH` and allow auto-completion of article titles:
Open `.bashrc` in a text editor, such as `nano`:
```nano ~/.bashrc
At the very end of the file add the following lines:
```# Nina
```## enable auto complete of articles:
```source "$HOME/.nina/nina-completion.sh"
```## Add nina to PATH:
```export PATH="$PATH:~/.nina/"
Save the file and exit (`Ctrl+x`), then reload `.bashrc` by running:
```source ~/.bashrc
4) Create a default config file:
```nina --config
5) Build the index that the program needs to find files:
```nina --index
6) Install any macros:
```nina --macros
and plugins with
```nina --plugins

Nina is now installed.

# Help and Instructions
Nina comes with several help files.  To view them:
```nina "Nina - User: Help
or
```nina "Nina - User: Getting Started"
These help files are markdown files and live in the same directory as your knowledge base.  You can view, edit, or delete them just as you would any other article in your knowledge base.
While viewing the help file you can type `q` to exit or `v` to edit it.

# Markdown and Formatting
Nina is a simple, stateless program and so not all markdown is supported.  To see the markdown that is supported:
```nina "Nina - Markdown Examples"

# Config file 
The config file contains a number of variables and settings to control how Nina works.
You may want to enable two configurations that are off by default:
```ENABLE_ALIASES
and
```ENABLE_PLUGINS
To do this:
```nina --config --edit
Then navigate with the arrow keys and change the relevant lines to match:
```ENABLE_ALIASES=true
and
```ENABLE_PLUGINS=true
With aliases enabled you can open Nina - Markdown Examples with
```nina markdown
and you can open Nina – User: Help with
```nina --help

# Compatibility 
Nina should work in any POSIX compliant machine with no additional dependencies.
I have not tested nina on BSD or macOS, but I believe it should work on them.
The Windows PowerShell port is incomplete, but I hope to have it available soon.  Until then you will need to use WSL to run it on Windows.
