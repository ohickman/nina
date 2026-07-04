# -----------------------------------------
# Nina Bash Completion
# -----------------------------------------

# Resolve script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load library if available (silent)
[[ -f "$SCRIPT_DIR/nina-lib.sh" ]] && source "$SCRIPT_DIR/nina-lib.sh"

# Load config silently
CONFIG_FILE="$HOME/.nina/config"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# -----------------------------------------
# Match a $cur prefix against a newline-separated
# list of candidates, appending hits to COMPREPLY.
#
# This deliberately does NOT use `compgen -W`.
# compgen -W re-parses its wordlist argument through
# the shell's normal word-expansion rules, including
# quote removal - so a single unbalanced quote or
# apostrophe anywhere in the list (e.g. an article
# titled "A Chemist's Shopping List") opens an
# unterminated quoted context that silently swallows
# every subsequent newline-separated entry until the
# next quote character balances it out, dropping
# unrelated candidates with no error. Article titles
# are free text and can't be assumed quote-free, so
# matching is done with a plain loop and a glob
# comparison instead, which only ever splits on $IFS
# and never re-parses for quoting.
# -----------------------------------------

_nina_match() {
    local cur="$1" list="$2" item
    local IFS=$'\n'
    for item in $list; do
        [[ -z "$item" ]] && continue
        [[ $item == "$cur"* ]] && COMPREPLY+=("$item")
    done
}

_nina_complete()
{
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # When completing inside an already-opened quote (needed for
    # titles containing spaces), bash includes that leading quote
    # character in $cur itself - e.g. typing nina "Ni<Tab> gives
    # cur=[\"Ni], not [Ni]. compgen -W used to strip this
    # automatically as part of its own quoting-aware matching;
    # since _nina_match does a plain literal comparison instead,
    # it has to strip it here to match candidates the same way.
    cur="${cur#[\"\']}"

    # Known flags
    local flags="--config --backlinks -b --dangling --date -d \
                 --doctor -D --file-name --graph -g --index -i \
                 --links -l --macro --new -n --orphan --plugin \
                 --random -r --read --remove --repair --restore \
                 --resync --search -s --stats --tag -t"

    # If completing first argument, suggest flags + titles + aliases
    if [[ $COMP_CWORD -eq 1 ]]; then
        # Newline-separated so titles/aliases containing spaces
        # (or quotes - see _nina_match above) are matched as
        # single candidates.
        local suggestions
        suggestions=$(tr ' ' '\n' <<< "$flags")

        # Add titles if index exists
        if [[ -f "$INDEX_FILE" ]]; then
            suggestions+=$'\n'"$(index_titles)"
        fi

        # Add aliases if enabled and alias index exists
        if [[ "$ENABLE_ALIASES" == true && -f "$ALIAS_INDEX_FILE" ]]; then
            suggestions+=$'\n'"$(alias_titles)"
        fi

        _nina_match "$cur" "$suggestions"
        return 0
    fi

    # If previous argument expects a title
    case "$prev" in
        --remove|--restore|--links|-l)
            if [[ -f "$INDEX_FILE" ]]; then
                _nina_match "$cur" "$(index_titles)"
            fi
            return 0
            ;;
    esac

    # If previous argument expects a tag
    case "$prev" in
        --tag|-t)
            if [[ -f "$INDEX_FILE" ]]; then
                _nina_match "$cur" "$(index_tags | sort -u)"
            fi
            return 0
            ;;
    esac
}

complete -F _nina_complete nina
complete -F _nina_complete ./nina
