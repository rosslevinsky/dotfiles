#!/usr/bin/env bash
#
# check_line_budget.sh must measure something real.
#
# Run bare on a machine with no instructions, it reports a session total of 0 and exits OK,
# which proves nothing. So this suite installs into a throwaway HOME and checks that the
# figures match the files: the instruction file this repo installs, a person's own in its
# place, and a workspace file above the repos, which another repo installs. It also checks
# that the limit fails.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUDGET="$DOTFILES/tests/check_line_budget.sh"
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/         /'; }

# The budget tool uses associative arrays. Stock macOS bash can't run it; CI must.
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  if [ -n "${CI:-}" ]; then
    echo "FAIL: needs Bash 4 or newer, and this is $BASH_VERSION" >&2; exit 1
  fi
  echo "SKIP: check_line_budget.sh needs Bash 4 or newer, and this is $BASH_VERSION"
  exit 0
fi

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT
H="$T/home"; W="$H/repos"
mkdir -p "$W/other/workspace" "$W/proj"
git init -q "$W/proj"

env -i PATH="$PATH" HOME="$H" CLAUDE_SKILLS_DIR="$H/.claude/skills" \
    bash "$DOTFILES/setup.sh" --no-starters >/dev/null 2>&1 || { echo "setup.sh failed" >&2; exit 1; }

budget() {  # Leaves the output in $OUT and the exit status in $RC.
  OUT="$(HOME="$H" WORKSPACE="$W" CLAUDE_SKILLS_DIR="$H/.claude/skills" bash "$BUDGET" "$@" 2>&1)"; RC=$?
}
has()   { case "$OUT" in *"$2"*) ok "$1" ;; *) bad "$1" ;; esac; }
total() { printf '%s\n' "$OUT" | awk '/session total/ {print $3; exit}'; }

USER_LINES="$(awk 'END{print NR}' "$DOTFILES/claude/CLAUDE.md")"
[ "$USER_LINES" -gt 0 ] || { echo "claude/CLAUDE.md is empty" >&2; exit 1; }

echo "== what this repo installs =="
budget "$W/proj"
[ "$RC" -eq 0 ] && ok "the installed file is within the limit" || bad "the installed file is within the limit"
has "the user file is reported" "~/.claude/CLAUDE.md"
[ "$(total)" = "$USER_LINES" ] && ok "the session total is that file's lines" || bad "the session total is that file's lines"

echo "== a workspace file another repo installs =="
printf 'one\ntwo\nthree\n' > "$W/other/workspace/CLAUDE.md"
ln -s "$W/other/workspace/CLAUDE.md" "$W/CLAUDE.md"
budget "$W/proj"
[ "$RC" -eq 0 ] && ok "it is within the limit" || bad "it is within the limit"
has "it is reported" "$W/CLAUDE.md"
[ "$(total)" = "$((USER_LINES + 3))" ] && ok "and it counts toward the session" || bad "and it counts toward the session"

echo "== with no argument: the workspace root and every repo in it =="
budget
has "the repo is listed" "proj"
has "the summary names the workspace" "under $W"

echo "== the limit =="
awk 'BEGIN{for(i=0;i<201;i++)print "line"}' > "$W/other/workspace/CLAUDE.md"
budget "$W/proj"
[ "$RC" -eq 1 ] && ok "a workspace file over the limit fails" || bad "a workspace file over the limit fails"
has "  and is named" "OVER 200"

echo "== a user file that is the person's own =="
# setup.sh leaves it in place, and it is what a session loads, so it is what gets measured.
H="$T/home-own"; W="$H/repos"; mkdir -p "$W/proj" "$H/.claude"; git init -q "$W/proj"
printf 'mine\nmine\n' > "$H/.claude/CLAUDE.md"
env -i PATH="$PATH" HOME="$H" CLAUDE_SKILLS_DIR="$H/.claude/skills" \
    bash "$DOTFILES/setup.sh" --no-starters >/dev/null 2>&1 || { echo "setup.sh failed" >&2; exit 1; }
budget "$W/proj"
[ "$RC" -eq 0 ] && ok "it is within the limit" || bad "it is within the limit"
has "it is reported" "~/.claude/CLAUDE.md"
[ "$(total)" = 2 ] && ok "the session total is that file's lines, not the sample's" || bad "the session total is that file's lines, not the sample's"
awk 'BEGIN{for(i=0;i<201;i++)print "line"}' > "$H/.claude/CLAUDE.md"
budget "$W/proj"
[ "$RC" -eq 1 ] && ok "over the limit it fails, like any file a session loads" || bad "over the limit it fails, like any file a session loads"
has "  and is named" "OVER 200"

echo "== a user rule another repo installs =="
# Rules in ~/.claude/rules load in every session, like the user file, so they count too.
mkdir -p "$H/.claude/rules"; printf 'rule\nrule\nrule\n' > "$H/.claude/rules/example.md"
printf 'mine\nmine\n' > "$H/.claude/CLAUDE.md"
budget "$W/proj"
[ "$RC" -eq 0 ] && ok "the rule is within the limit" || bad "the rule is within the limit"
has "it is reported" "~/.claude/rules/example.md"
[ "$(total)" = 5 ] && ok "and it counts toward the session" || bad "and it counts toward the session"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
