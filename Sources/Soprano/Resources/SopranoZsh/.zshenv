# Soprano starts the shell a pane falls back to after its agent exits with
# ZDOTDIR pointing here. Agents are quit with Ctrl+C, often pressed more than
# once, and a SIGINT that lands while zsh sources its startup files aborts
# them: no theme, no plugins, no aliases. Ignore SIGINT until the first
# prompt, then hand over to the user's own startup files.
#
# Everything is quoted against aliases, as in Ghostty's integration.

# Restore the user's ZDOTDIR before zsh reads any further startup file.
if [[ -n "${SOPRANO_ZSH_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$SOPRANO_ZSH_ZDOTDIR"
    'builtin' 'unset' 'SOPRANO_ZSH_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi

if [[ -o 'interactive' ]]; then
    'builtin' 'trap' '' INT
    _soprano_startup_finished() {
        precmd_functions=(${precmd_functions:#_soprano_startup_finished})
        'builtin' 'unfunction' _soprano_startup_finished
        # Hand Ctrl+C back unless a startup file set its own INT trap. `trap`
        # lists nothing inside $(...), so its output goes through a file.
        'builtin' 'local' traps_file="${TMPDIR:-/tmp}/soprano-traps.$$"
        'builtin' 'trap' >| "$traps_file" 2>/dev/null
        if [[ ! -r "$traps_file" || "$(<"$traps_file")" == *"trap -- '' INT"* ]]; then
            'builtin' 'trap' - INT
        fi
        'command' 'rm' -f -- "$traps_file"
    }
    'builtin' 'typeset' -ga precmd_functions
    precmd_functions+=(_soprano_startup_finished)
fi

# Zsh treats an unset ZDOTDIR as HOME and ignores unreadable rc files.
'builtin' 'typeset' _soprano_file=${ZDOTDIR-$HOME}"/.zshenv"
[[ ! -r "$_soprano_file" ]] || 'builtin' 'source' '--' "$_soprano_file"
'builtin' 'unset' '_soprano_file'
