#!/bin/sh
# Soprano's stand-in on a remote machine. Soprano copies it to ~/.soprano/<hash>/soprano and
# runs every pane on that machine through `attach`; agent hooks call it as $SOPRANO_BIN.
#
#   soprano attach [--generation <id>] <session> <dir> <tmux.conf> <command>
#       Attaches to (or starts) the tmux session that keeps the pane's program running while
#       the connection is down. With --generation (a restart), a session another generation
#       started ends first. Without tmux the command runs directly.
#   soprano agent-event <state> [options]
#       What `soprano agent-event` does locally, reported in-band as OSC 7501 (the Program
#       Status Protocol) to the pane's terminal instead of over the app's socket.
#   soprano shell
#       The account's login shell, with Soprano's agent stand-ins ($SOPRANO_AGENT_BIN) first
#       on PATH once the shell's own startup files have run.
set -u

state_dir="$HOME/.soprano/state"
# A command run over ssh gets the system PATH only; tmux from Homebrew or Linuxbrew lives
# outside it.
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.nix-profile/bin"
export PATH
# SOPRANO_TMUX names another tmux (tests point it at a missing one).
tmux=${SOPRANO_TMUX:-tmux}

b64() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# Writes an OSC 7501 report to the pane and keeps it for the next attach, which replays it:
# a report written while no client was attached never reached the app.
emit() {
    report=$1
    if [ -n "${SOPRANO_TMUX_SESSION:-}" ]; then
        mkdir -p "$state_dir" 2>/dev/null
        if [ "$2" = clear ]; then
            rm -f "$state_dir/$SOPRANO_TMUX_SESSION"
        else
            printf '\033]%s\033\\' "$report" > "$state_dir/$SOPRANO_TMUX_SESSION" 2>/dev/null
        fi
    fi
    tty=${SOPRANO_TTY:-/dev/tty}
    {
        if [ -n "${TMUX:-}" ]; then
            # tmux passes a DCS-wrapped sequence on to the terminal (allow-passthrough).
            printf '\033Ptmux;\033\033]%s\033\033\\\033\\' "$report" > "$tty"
        else
            printf '\033]%s\033\\' "$report" > "$tty"
        fi
    } 2>/dev/null
}

agent_event() {
    [ $# -ge 1 ] || exit 0
    event=$1
    shift
    app=${SOPRANO_AGENT_PROFILE:-}
    title=${SOPRANO_AGENT_NAME:-}
    body=""
    reason=""
    payload=""
    from_stdin=0
    while [ $# -gt 0 ]; do
        case $1 in
            --notify) shift ;;
            --message-from-stdin) from_stdin=1; shift ;;
            --profile|--title|--body|--pid|--reason|--message-json)
                [ $# -ge 2 ] || break
                case $1 in
                    --profile) app=$2 ;;
                    --title) title=$2 ;;
                    --body) body=$2 ;;
                    --reason) reason=$2 ;;
                    --message-json) payload="$payload $2" ;;
                esac
                shift 2
                ;;
            # Codex appends its payload as one trailing argument.
            *) payload="$payload $1"; shift ;;
        esac
    done
    if [ "$from_stdin" = 1 ]; then
        payload="$payload $(cat)"
    fi
    # Why the agent waits, from the payload's type fields (as `waiting_reason` in the app).
    if [ -z "$reason" ]; then
        compact=$(printf '%s' "$payload" | tr -d ' \t\r\n')
        case $compact in
            *'"notification_type":"permission_prompt"'*|*'"hook_event_name":"PermissionRequest"'*) reason=approval ;;
            *'"notification_type":"elicitation_dialog"'*) reason=question ;;
            *'"notification_type":"idle_prompt"'*|*'"hook_event_name":"Stop"'*|*'"type":"agent-turn-complete"'*) reason=turn ;;
        esac
    fi
    case $event in
        ready) state=idle ;;
        running) state=working ;;
        error) state=error ;;
        stopped) state=clear ;;
        needs-input)
            case $reason in
                approval) state=blocked:kind=permission ;;
                question) state=blocked:kind=question ;;
                turn) state=done ;;
                *) state=blocked ;;
            esac
            ;;
        *) exit 0 ;;
    esac
    report="7501;state=$state"
    case $app in
        ''|*[!A-Za-z0-9_.,+/=-]*) ;;
        *) report="$report:app=$app" ;;
    esac
    [ -n "$title" ] && report="$report:title=$(b64 "$title")"
    [ -n "$body" ] && report="$report:msg=$(b64 "$body")"
    emit "$report" "$state"
}

attach() {
    generation=""
    if [ "${1:-}" = --generation ] && [ $# -ge 2 ]; then
        generation=$2
        shift 2
    fi
    [ $# -eq 4 ] || { echo "usage: soprano attach [--generation <id>] <session> <dir> <tmux.conf> <command>" >&2; exit 2; }
    session=$1
    dir=$2
    conf=$3
    command=$4
    case $dir in
        '~') dir=$HOME ;;
        '~/'*) dir="$HOME/${dir#\~/}" ;;
    esac
    [ -d "$dir" ] || dir=$HOME
    cd "$dir" || exit 1
    export SOPRANO_TMUX_SESSION="$session"
    # tmux sets SHELL to its default-shell (/bin/sh here) in the session; the program runs in
    # the account's login shell, so its rc files (PATH to the agent CLIs) load.
    login_shell=${SHELL:-/bin/sh}
    case $login_shell in *"'"*) login_shell=/bin/sh ;; esac
    command="SHELL='$login_shell'; export SHELL; $command"
    if ! command -v "$tmux" >/dev/null 2>&1; then
        printf '\033[2mSoprano: tmux is not installed here, so this pane stops when the connection drops.\033[0m\r\n'
        exec /bin/sh -c "$command"
    fi
    # A restart ends what an earlier start left running; its own reconnects attach.
    if [ -n "$generation" ] && "$tmux" -L soprano has-session -t "=$session" 2>/dev/null; then
        current=$("$tmux" -L soprano show-options -qv -t "=$session:" @soprano_generation 2>/dev/null)
        if [ "$current" != "$generation" ]; then
            "$tmux" -L soprano kill-session -t "=$session"
            rm -f "$state_dir/$session"
        fi
    fi
    # The status the agent reported while no client was attached.
    [ -f "$state_dir/$session" ] && cat "$state_dir/$session"
    # A private server, so its settings never touch the user's own tmux. The session starts
    # detached at the pane's size, marked with the restart that started it, then attaches.
    if ! "$tmux" -L soprano has-session -t "=$session" 2>/dev/null; then
        set -- $(stty size 2>/dev/null)
        rows=${1:-0} cols=${2:-0}
        [ "$rows" -gt 0 ] 2>/dev/null || rows=24
        [ "$cols" -gt 0 ] 2>/dev/null || cols=80
        # A stop sent meanwhile sees the restart's mark, or no session at all.
        "$tmux" -u -L soprano -f "$conf" new-session -d -s "$session" -c "$dir" -x "$cols" -y "$rows" "$command" \
            \; set-option -q -t "=$session:" @soprano_generation "${generation:-0}" || exit 1
    fi
    "$tmux" -L soprano source-file -q "$conf"
    # -u: the pane's text is UTF-8 even when ssh passed no language setting along.
    "$tmux" -u -L soprano attach-session -t "=$session"
    status=$?
    # The session ended (its program exited), not the connection.
    [ "$status" -eq 0 ] && rm -f "$state_dir/$session"
    exit "$status"
}

shell() {
    bin=${SOPRANO_AGENT_BIN:-}
    login=${SHELL:-/bin/sh}
    if [ -z "$bin" ] || [ ! -d "$bin" ]; then
        exec "$login" -l
    fi
    case ${login##*/} in
        zsh)
            # zsh reads $ZDOTDIR/.zshenv first; Soprano's hands over to the user's files.
            if [ -n "${ZDOTDIR+x}" ]; then
                SOPRANO_USER_ZDOTDIR=$ZDOTDIR
                export SOPRANO_USER_ZDOTDIR
            fi
            ZDOTDIR=$bin
            export ZDOTDIR
            exec "$login" -l
            ;;
        bash) exec "$login" --rcfile "$bin/bashrc" -i ;;
        # fish runs -C after its configuration.
        fish) exec "$login" -l -C 'set -gx PATH $SOPRANO_AGENT_BIN $PATH' ;;
        *)
            PATH="$bin:$PATH"
            export PATH
            exec "$login" -l
            ;;
    esac
}

case ${1:-} in
    agent-event) shift; agent_event "$@" ;;
    attach) shift; attach "$@" ;;
    shell) shell ;;
    ''|help|-h|--help) echo "Soprano's remote helper: soprano attach|agent-event|shell" >&2; exit 2 ;;
    # What the app itself answers (navigate-pane, navigation-passthrough, browser, markdown)
    # has no app to reach here; like the CLI outside a Soprano pane, it does nothing.
    *) exit 0 ;;
esac
