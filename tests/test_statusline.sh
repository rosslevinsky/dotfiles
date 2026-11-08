#!/usr/bin/env bash
#
# The status line must fit the terminal. Claude Code passes the width in $COLUMNS, and the
# script breaks between segments when the next one would overflow. A line that overflows is
# wrapped by the terminal mid-word instead, which is what this replaced.
#
# The fixture directory is outside any git repository, so no branch segment appears and
# every character is ASCII: the length checks then mean the same thing under any locale.
# HOME is set to its parent so it renders as the short `~/w`. A raw mktemp path would not
# do: on macOS it is /var/folders/.../T/tmp.XXXX, longer than the narrow widths tested, and
# a single segment is never split.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DOTFILES/claude/statusline-command.sh"
PASS=0; FAIL=0
check(){ if eval "$2"; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; fi; }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir "$ROOT/w"
INPUT="{\"workspace\":{\"current_dir\":\"$ROOT/w\"},\"model\":{\"display_name\":\"Sonnet (1M context)\"},\"effort\":{\"level\":\"medium\"},\"context_window\":{\"used_percentage\":12.4}}"
SEGMENTS=("testhost" "~/w" "Sonnet (1M context) medium" "ctx:12%")

# $1 = COLUMNS, or "unset". Prints the status line with the color codes removed, plus a
# trailing newline, and fails if the script did.
render() {
    local out
    if [ "$1" = unset ]; then
        out="$(printf '%s' "$INPUT" | env -u COLUMNS HOME="$ROOT" HOSTNAME=testhost.example bash "$SCRIPT")" || return 1
    else
        out="$(printf '%s' "$INPUT" | COLUMNS="$1" HOME="$ROOT" HOSTNAME=testhost.example bash "$SCRIPT")" || return 1
    fi
    printf '%s\n' "$out" | sed $'s/\x1b\\[[0-9;]*m//g'
}
lines()   { render "$1" | wc -l | tr -d ' '; }
longest() { render "$1" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }'; }
# Every expected segment appears whole, on one line.
has_all() {
    local out seg; out="$(render "$1")" || return 1
    for seg in "${SEGMENTS[@]}"; do
        printf '%s\n' "$out" | grep -F -- "$seg" >/dev/null || return 1
    done
}

echo "== the script runs =="
check "exits 0"                          "render 300 >/dev/null"

echo "== wide terminal: one line =="
check "one line at 300 columns"          "[ \"\$(lines 300)\" -eq 1 ]"
check "one line with COLUMNS unset"      "[ \"\$(lines unset)\" -eq 1 ]"

echo "== narrow terminal: wraps, never overflows =="
for c in 45 30 27; do  # whole line is 50; longest segment is 26
    check "more than one line at $c columns" "[ \"\$(lines $c)\" -gt 1 ]"
    check "no line longer than $c at $c"     "[ \"\$(longest $c)\" -le $c ]"
done

echo "== content =="
check "short hostname comes first"       "render 300 | head -1 | grep '^testhost  ' >/dev/null"
for c in 300 30; do
    check "every segment present at $c"  "has_all $c"
done

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
