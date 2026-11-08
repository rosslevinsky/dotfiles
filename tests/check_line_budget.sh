#!/usr/bin/env bash
#
# What a Claude Code session would load, and whether it fits.
#
# The user file is measured whoever wrote it: a person's own, which setup.sh leaves in
# place, costs a session the same as the sample does.
#
# Claude walks up the directory tree from the working directory collecting every
# CLAUDE.md and CLAUDE.local.md it passes, then adds the user-scope file and any
# user rules. All of it is concatenated — nothing overrides anything — so the
# only figure that matters is the total, and per-file size is what governs how
# well any single instruction is followed.
#
# Two limits, and they are not the same kind of thing:
#   per file  200 lines   Anthropic's guidance. A FAILURE.
#   session   400 lines   ours, and nothing sits behind the exact number. A WARNING.
#
# Demoting the session total is not a relaxation. Kept as a failure it invites the
# fix that is always available and always wrong — cutting prose until the number
# drops — when the honest fix is moving file-conditional content into a `paths:`
# rule so it stops loading at startup at all.
#
# Only UNCONDITIONAL instructions count. A rule carrying `paths:` frontmatter
# loads when Claude opens a matching file, not at startup, so counting it here
# would measure a session's peak rather than what every session pays.
#
# SKILL DESCRIPTIONS COUNT. Every installed skill's `name` + `description` frontmatter
# is resident in every session — that is how Claude decides a skill is relevant, so it
# cannot be deferred the way a rule can — and it can outweigh the instruction files.
# The session limit includes them.
#
# Skill BODIES are not counted, and should not be: the body loads only when the
# skill is invoked. Only the frontmatter is resident.
#
# Plugin skills are resident too and are NOT counted here. Which ones load depends
# on `enabledPlugins` in settings.json, while the on-disk tree under ~/.claude/plugins
# carries disabled plugins and duplicate cache/marketplace copies of the same skill —
# so any count taken from disk would be confidently wrong. Add them yourself if you
# enable any.
#
# Lines AND words, because they disagree: of two files, the shorter by lines can be the
# longer by words, and a limit on lines alone rewards reflowing.
#
# A file reachable by two paths is loaded ONCE, and this reports it without counting
# it twice. Installed from this repo, the user file is a symlink into it, so a session held
# inside claude/ meets it as the user file and again as an ancestor CLAUDE.md. Claude Code
# deduplicates by real path. It is still worth reporting: a file arriving by two names
# is worth knowing about whether or not it is charged twice.
#
# A workspace file is measured like any other ancestor, whichever repo installed it.
# This repo installs none.
#
# Usage: check_line_budget.sh [dir ...]
#
# With no argument it measures the workspace root and every git repository in it.
# That is the point: run against directories someone typed by hand, the answer is a
# fact about the typing, and a session over the limit elsewhere goes unseen.

set -uo pipefail

PER_FILE=200
SESSION=400

# Where installed skills live. Overridable so a test can point at a fixture, and so
# the count follows a non-default install rather than silently reporting zero.
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$(cd "$HERE/../.." && pwd)}"

# ---------------------------------------------------------------- measurement

DETAIL=()            # rendered lines for the current session
sess_lines=0
sess_words=0
sess_files=0
sess_over=0
sess_dupes=0
declare -A SEEN      # realpath -> the label it was first counted under

measure() {          # $1 = path, $2 = label
  [ -f "$1" ] || return 0

  local n w real note=""
  # awk, not `wc -l`: a file whose last line has no newline is still a line.
  n="$(awk 'END{print NR}' "$1")"
  w="$(wc -w < "$1" | tr -d ' ')"
  real="$(readlink -f "$1")"

  if head -5 "$1" | grep -q '^paths:'; then
    DETAIL+=("$(printf '  %-52s %4s %6s  (conditional — not counted)' "$2" "$n" "$w")")
    return 0
  fi

  if [ -n "${SEEN[$real]:-}" ]; then
    sess_dupes=$((sess_dupes + 1))
    DETAIL+=("$(printf '  %-52s %4s %6s  (same file as %s — loaded once)' \
                       "$2" "$n" "$w" "${SEEN[$real]}")")
    return 0
  fi
  SEEN["$real"]="$2"

  sess_files=$((sess_files + 1))
  sess_lines=$((sess_lines + n))
  sess_words=$((sess_words + w))

  if [ "$n" -gt "$PER_FILE" ]; then
    sess_over=$((sess_over + 1))
    note="  OVER $PER_FILE$note"
  fi

  DETAIL+=("$(printf '  %-52s %4d %6d%s' "$2" "$n" "$w" "$note")")
}

measure_skills() {   # Resident cost of every installed skill's frontmatter.
  [ -d "$SKILLS_DIR" ] || return 0

  local f n w count=0 lines=0 words=0
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    # Only the frontmatter block. `name` and `description` are the whole of it, and
    # they are what Claude reads to decide a skill applies; the body loads on use.
    # Most descriptions wrap over several physical lines, so the line figure
    # understates them and the word figure is the one to read.
    read -r n w < <(awk 'NR==1&&/^---/{f=1;next} f&&/^---/{exit} f{l++; c+=NF} END{print l+0, c+0}' "$f")
    count=$((count + 1)); lines=$((lines + n)); words=$((words + w))
  done
  [ "$count" -gt 0 ] || return 0

  sess_files=$((sess_files + count))
  sess_lines=$((sess_lines + lines))
  sess_words=$((sess_words + words))
  DETAIL+=("$(printf '  %-52s %4d %6d  (%d skills, resident every session)' \
                     "skill descriptions" "$lines" "$words" "$count")")
}

session() {          # $1 = directory. Fills DETAIL and the sess_* counters.
  local dir="$1" d r
  DETAIL=(); sess_lines=0; sess_words=0; sess_files=0; sess_over=0; sess_dupes=0
  SEEN=()

  measure "$HOME/.claude/CLAUDE.md" "~/.claude/CLAUDE.md"
  for r in "$HOME"/.claude/rules/*.md; do
    [ -e "$r" ] && measure "$r" "~/.claude/rules/$(basename "$r")"
  done
  measure_skills

  # Ancestors, root-first, matching the order Claude reads them.
  local ancestors=()
  d="$dir"
  while [ "$d" != "/" ]; do ancestors=("$d" "${ancestors[@]}"); d="$(dirname "$d")"; done
  for d in "${ancestors[@]}"; do
    measure "$d/CLAUDE.md" "${d#"$WORKSPACE/"}/CLAUDE.md"
    measure "$d/CLAUDE.local.md" "${d#"$WORKSPACE/"}/CLAUDE.local.md"
    # A repo rule without `paths:` frontmatter loads at startup like any other
    # instruction. Nothing here stops one being added, so it is measured.
    # $HOME is skipped: its .claude/rules IS the user scope, counted above, and
    # counting it again here would report a duplicate that no session pays.
    if [ "$d" != "$HOME" ]; then
      for r in "$d"/.claude/rules/*.md; do
        [ -e "$r" ] && measure "$r" "${d#"$WORKSPACE/"}/.claude/rules/$(basename "$r")"
      done
    fi
  done
}

# ---------------------------------------------------------------------- report

detail_block() {     # $1 = directory heading
  local line
  echo "Session in $1"
  for line in "${DETAIL[@]}"; do echo "$line"; done
  echo "  ----"
  printf '  %-52s %4d %6d  (limit %d lines)\n' "session total" "$sess_lines" "$sess_words" "$SESSION"
}

targets=()
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    if [ -d "$arg" ]; then
      targets+=("$(cd "$arg" && pwd)")
    else
      echo "no such directory: $arg" >&2
      exit 2
    fi
  done
else
  targets+=("$WORKSPACE")
  for d in "$WORKSPACE"/*/; do
    d="${d%/}"
    # `-e .git` is not the test: an empty .git directory left behind by a
    # removed checkout answers yes and is not a repository.
    git -C "$d" rev-parse --show-toplevel >/dev/null 2>&1 && targets+=("$d")
  done
fi

fail_files=0
warn_sessions=0
noted_dupes=0
summary=()
details=()

for dir in "${targets[@]}"; do
  session "$dir"
  flags=""
  [ "$sess_over"  -gt 0 ] && { fail_files=$((fail_files + sess_over)); flags="${flags} FAIL:file>$PER_FILE"; }
  [ "$sess_lines" -gt "$SESSION" ] && { warn_sessions=$((warn_sessions + 1)); flags="${flags} WARN:session>$SESSION"; }
  [ "$sess_dupes" -gt 0 ] && { noted_dupes=$((noted_dupes + sess_dupes)); flags="${flags} note:two-paths"; }

  summary+=("$(printf '  %-40s %3d %6d %7d %s' "${dir#"$WORKSPACE/"}" "$sess_files" "$sess_lines" "$sess_words" "$flags")")
  if [ "${#targets[@]}" -eq 1 ] || [ -n "$flags" ]; then
    details+=("$(detail_block "$dir")" "")
  fi
done

if [ "${#targets[@]}" -gt 1 ]; then
  printf 'What each session pays, under %s\n\n' "$WORKSPACE"
  printf '  %-40s %3s %6s %7s\n' "DIRECTORY" "N" "LINES" "WORDS"
  printf '%s\n' "${summary[@]}"
  echo
fi
[ "${#details[@]}" -gt 0 ] && printf '%s\n' "${details[@]}"

rc=0
[ "$fail_files" -gt 0 ] && { echo "FAIL: $fail_files file(s) over $PER_FILE lines"; rc=1; }
[ "$warn_sessions" -gt 0 ] && echo "WARN: $warn_sessions session(s) over $SESSION lines — move file-conditional content into a paths: rule, do not trim prose"
[ "$noted_dupes" -gt 0 ] && echo "NOTE: $noted_dupes file(s) reachable by two paths — Claude Code loads each once, so each is counted once"
[ "$rc" -eq 0 ] && [ "$warn_sessions" -eq 0 ] && echo "OK"
exit $rc
