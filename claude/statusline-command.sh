#!/bin/bash
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
effort=$(echo "$input" | jq -r '.effort.level // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# --- colors (ANSI) ---
DIM='\033[2m'
BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
MAGENTA='\033[35m'
RESET='\033[0m'

# --- host: short name, so you can tell which machine a session is on ---
# Bash sets $HOSTNAME itself, so this works where the `hostname` program is not installed.
host="${HOSTNAME%%.*}"

# --- directory, shown relative to $HOME with ~ ---
dir="$cwd"
case "$dir" in
    "$HOME") dir="~" ;;
    "$HOME"/*) dir="~${dir#$HOME}" ;;
esac
[ -z "$dir" ] && dir="/"

# --- git branch (if inside a repo) ---
branch=""
if [ -n "$cwd" ]; then
    branch=$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null)
    if [ -z "$branch" ]; then
        # detached HEAD: show short commit
        branch=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
        [ -n "$branch" ] && branch="detached@$branch"
    fi
fi

# --- segments: each one is kept whole; a line breaks only between them ---
# Two parallel arrays: the plain text measures the width, the colored text is printed.
plain=()
colored=()
add() { plain+=("$1"); colored+=("$2"); }

[ -n "$host" ] && add "$host" "${YELLOW}${host}${RESET}"
add "$dir" "${CYAN}${BOLD}${dir}${RESET}"
[ -n "$branch" ] && add " $branch" "${GREEN} ${branch}${RESET}"
if [ -n "$model" ]; then
    p="$model"; c="${MAGENTA}${BOLD}${model}${RESET}"
    if [ -n "$effort" ]; then p="$p $effort"; c="$c ${DIM}${effort}${RESET}"; fi
    add "$p" "$c"
fi
if [ -n "$used" ]; then
    used_int=$(printf "%.0f" "$used")
    add "ctx:${used_int}%" "${DIM}ctx:${used_int}%${RESET}"
fi

# --- wrap to the terminal width ---
# Claude Code passes the width in $COLUMNS. Without it, assume wide: one line, as before.
# The margin leaves room for the padding Claude Code draws around the status line.
# Widths are counted in characters, so a path with double-width characters (CJK) can
# still overflow by a few cells.
width=$(( ${COLUMNS:-1000} - 4 ))
sep="  "
out=""
line_len=0
for i in "${!plain[@]}"; do
    len=${#plain[$i]}
    if [ "$line_len" -eq 0 ]; then
        out="${out}${colored[$i]}"
        line_len=$len
    elif [ $(( line_len + ${#sep} + len )) -le "$width" ]; then
        out="${out}${sep}${colored[$i]}"
        line_len=$(( line_len + ${#sep} + len ))
    else
        out="${out}\n${colored[$i]}"
        line_len=$len
    fi
done

printf '%b' "$out"
