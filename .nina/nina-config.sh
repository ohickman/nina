#!/usr/bin/env bash

# -----------------------------------------
# Resolve script directory and load library
# -----------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nina-lib.sh"

CONFIG_FILE="$HOME/.nina/config"
mkdir -p "$(dirname "$CONFIG_FILE")"

# -----------------------------------------
# Create default config
# -----------------------------------------

create_default_config() {

cat <<'EOF' > "$CONFIG_FILE"
#################################
# PATHS
#################################

NINA_DIR="$HOME/nina"
INDEX_FILE="$HOME/.nina/index.tsv"
ALIAS_INDEX_FILE="$HOME/.nina/index-alias.tsv"
ARCHIVE_DIR="$HOME/nina/archive"
MACROS_DIR="$HOME/.nina/macros"
PLUGINS_DIR="$HOME/.nina/plugins"
EDITOR="nano"

#################################
# BEHAVIOR FLAGS
#################################

# Prompt to create article if not found
ENABLE_CREATE_PROMPT=true

# Rebuild index automatically after create/edit
AUTO_REINDEX=true

# Enable alias resolution. When on, the indexer builds
# a secondary alias->title index from any "- Alias:" header
# lines, letting an article be opened by an alternate name.
# Off by default.
ENABLE_ALIASES=false

# Show linked article list after viewing
SHOW_LINK_LIST=true

# Article removal mode: "archive", "delete", or "choose"
# archive - always archive, type 'archive' to confirm
# delete  - always delete permanently, type 'delete' to confirm
# choose  - user types either 'archive' or 'delete' at prompt
REMOVE_MODE="choose"

# Enable macro expansion ({{...}}) when rendering articles
ENABLE_MACROS=true

# Enable plugin expansion (<<...>>) when rendering articles.
# Off by default - plugins are a more powerful, less
# sandboxed capability than macros, and turning this on is
# a deliberate choice, not a default behavior.
ENABLE_PLUGINS=false

# Allow plugins to reach the network via plugin_http_get().
# Has no effect if ENABLE_PLUGINS is false. Read access to
# the corpus itself (plugin_call_nina() and its wrappers)
# is not gated by a flag - see Nina - Developer Technical
# Guide, "The Plugin System", for why.
PLUGIN_PERMIT_WEB=false

# Per-invocation time limit (seconds) for a plugin that
# references plugin_http_get() or plugin_call_nina() -
# either capability can leave the local process, so both
# get the longer budget.
PLUGIN_TIMEOUT=5

# Per-invocation time limit (seconds) for a plugin that
# does neither - pure in-memory work on the current
# article. Accepts fractional values (e.g. 0.5).
PLUGIN_NO_WEB_TIMEOUT=0.5

# Maximum bytes of output read back from a single plugin
# invocation. Output beyond this is silently truncated,
# never an error - see Nina - Developer Technical Guide.
PLUGIN_MAX_OUTPUT_BYTES=65536

# Virtual memory limit (KB) applied to a plugin's
# subprocess via ulimit -v, to bound runaway allocation
# even when a plugin never touches the network or disk.
PLUGIN_MAX_MEMORY_KB=262144

# Rendering options
ENABLE_COLOR=${ENABLE_COLOR:-true}
ENABLE_LINE_NUMBERS=false
LINE_NUMBER_STYLE="\033[38;5;240m"
LINE_NUMBER_SEPARATOR="  "

#################################
# RENDERING STYLES (ANSI)
#################################

if [[ "$ENABLE_COLOR" == true ]]; then
	RESET="\033[0m"

	# Headers
	H1_STYLE=" \033[1;4;15m    "
	H2_STYLE=" \033[1;4m\033[38;5;81m     "
	H3_STYLE=" \033[1;4m\033[38;5;45m      "
	H4_STYLE=" \033[1;4m\033[38;5;39m       "
	H5_STYLE=" \033[1;4m\033[38;5;75m        "
	H6_STYLE=" \033[1;4m\033[38;5;69m         "
	SUBTITLE_STYLE="\033[94m"

	# Line level
	BULLET_SYMBOL="•"
	TODO_SYMBOL="☐"
	DONE_SYMBOL="✘"
	TODO_DONE_STYLE="\033[37m\033[9m"
	BLOCK_QUOTE_SYMBOL="|"
	BLOCK_QUOTE_STYLE="\033[94m"
	INSERT_STYLE="\033[32m\033[4m"
	DELETE_STYLE="\033[31m\033[9m"
	ITEM_STYLE="\033[1m"
	DEFINITION_STYLE="    "

	# Inline
	BOLD_STYLE="\033[1m"
	ITALIC_STYLE="\033[3m"
	UNDERLINE_STYLE="\033[4m"
	CODE_STYLE="\033[37m"
	LINK_STYLE="\033[38;5;33m"
	HIGHLIGHT_STYLE="\033[30m\033[48;5;184m"
	STRIKEOUT_STYLE="\033[9m"

	# Admonitions / Callouts
	INFO_STYLE=" \033[1m\033[48;5;61m🛈 "
	NOTE_STYLE=" \033[30m\033[48;5;220m🛆 "
	TIP_STYLE=" \033[30m\033[48;5;83m➤ "
	TODO_STYLE=" \033[30m\033[48;5;153m✔ "
	FIXME_STYLE=" \033[1m\033[48;5;204m🏳 "
	WARNING_STYLE=" \033[1m\033[48;5;196m🛇 "

	# Horizontal Rules
	HR_SYMBOL="┈"
	HR_STYLE="\033[38;5;60m"

else
	RESET="\033[0m"

	# Headers
	H1_STYLE=" \033[1m"
	H2_STYLE="  \033[1m"
	H3_STYLE="   \033[1m"
	H4_STYLE="    \033[1m"
	H5_STYLE="     \033[1m"
	H6_STYLE="      \033[1m"
	SUBTITLE_STYLE=""

	# Line level
	BULLET_SYMBOL="*"
	TODO_SYMBOL="[ ]"
	DONE_SYMBOL="[x]"
	TODO_DONE_STYLE="\033[9m"
	BLOCK_QUOTE_SYMBOL="|"
	BLOCK_QUOTE_STYLE=""
	INSERT_STYLE="\033[4m"
	DELETE_STYLE="\033[9m"
	ITEM_STYLE="\033[1m"
	DEFINITION_STYLE="    "

	# Inline
	BOLD_STYLE="\033[1m"
	ITALIC_STYLE="\033[3m"
	UNDERLINE_STYLE="\033[4m"
	CODE_STYLE="\033[2m"
	LINK_STYLE="\033[4m"
	HIGHLIGHT_STYLE="\033[7m"
	STRIKEOUT_STYLE="\033[9m"

	# Admonitions / Callouts
	INFO_STYLE=" \033[7m"
	NOTE_STYLE=" \033[7m"
	TIP_STYLE=" \033[7m"
	TODO_STYLE=" \033[7m"
	FIXME_STYLE=" \033[7m"
	WARNING_STYLE=" \033[7m"

	# Horizontal Rules
	HR_SYMBOL="-"
	HR_STYLE=""
fi
EOF

    info "Default config created at $CONFIG_FILE"
}

# -----------------------------------------
# Create config if missing
# -----------------------------------------

if [[ ! -f "$CONFIG_FILE" ]]; then
    create_default_config
    info "A default configuration file has been created."
    info "To customize configuration file use 'nina --config --edit'"
    exit 0
fi

# -----------------------------------------
# RESET MODE
# (checked before sourcing, so reset still
#  works even if the current config is broken)
# -----------------------------------------

if [[ "$1" == "--reset" ]]; then
    echo
    warn "This will overwrite your current config with defaults."
    read -r -p "Type 'reset' to confirm: " confirm

    if [[ "$confirm" != "reset" ]]; then
        info "Aborted."
        exit 0
    fi

    backup="${CONFIG_FILE}.bak"
    cp "$CONFIG_FILE" "$backup" || die "Failed to back up existing config."
    info "Backup saved to: $backup"

    create_default_config

    echo
    info "Config reset. Edit to set your paths:"
    echo "  nina --config --edit"
    exit 0
fi

# -----------------------------------------
# Load configuration
# -----------------------------------------

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# -----------------------------------------
# VALIDATE MODE
# -----------------------------------------

if [[ "$1" == "--validate" ]]; then
    echo
    run "Validating config..."

    # Syntax check
    if ! bash -n "$CONFIG_FILE" 2>/dev/null; then
        error "Syntax error in config file"
        exit 2
    fi

    ok "Syntax valid"

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    missing=0

    for var in NINA_DIR INDEX_FILE; do
        if [[ -z "${!var}" ]]; then
            error "Required variable not set: $var"
            missing=1
        fi
    done

    if [[ $missing -eq 0 ]]; then
        ok "Required variables present"
        exit 0
    else
        exit 2
    fi
fi

# -----------------------------------------
# EDIT MODE
# -----------------------------------------

if [[ "$1" == "--edit" ]]; then
    editor="${EDITOR:-vi}"
    "$editor" "$CONFIG_FILE"
    exit $?
fi

# -----------------------------------------
# VIEW MODE
# -----------------------------------------

echo
echo "nina configuration:"
echo "-------------------"
echo
less "$CONFIG_FILE"