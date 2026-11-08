#!/usr/bin/env bash
#
# The sample wrapper in examples/private-layer/ must do what the README says a private layer
# does: install this repo with your data on top, create no starters, link the workspace file,
# and leave alone anything that isn't its own.
#
# Every case runs in a throwaway HOME laid out the way the README describes: a copy of this
# checkout at ~/src/dotfiles and a fake private repo at ~/src/my-config, built from the
# fictional accounts in tests/fixtures/identity. The copy is what lets a case rename the
# base checkout without touching this one.

set -uo pipefail
# A CODEX_HOME from the caller would point the wrapper at the real Codex folder. Only the case
# that needs it sets it.
unset CODEX_HOME

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$DOTFILES/examples/private-layer/setup.sh"
FIXTURE="$DOTFILES/tests/fixtures/identity"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; return 1; fi; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
T="$(cd "$T" && pwd -P)"     # macOS: /var is a link to /private/var
trap 'rm -rf "$T"' EXIT

# A home with the base copied in and a fake private repo beside it. Sets $H, $BASE, $PRIV.
make_home() {  # $1 = a name for the home
  H="$T/$1"; BASE="$H/src/dotfiles"; PRIV="$H/src/my-config"
  mkdir -p "$BASE" "$PRIV/workspace"
  (cd "$DOTFILES" && tar cf - --exclude=.git .) | (cd "$BASE" && tar xf -)
  cp -R "$FIXTURE/." "$PRIV/"
  printf '{"model": "fixture-model"}\n' > "$PRIV/settings-overlay.json"
  printf '# Workspace instructions for the fixture.\n' > "$PRIV/workspace/CLAUDE.md"
  cp "$BASE/examples/private-layer/setup.sh" "$PRIV/setup.sh"
}

# Runs the wrapper with nothing from the real environment but PATH. Leaves $OUT and $RC.
wrap() {  # $1 = HOME, $2.. = arguments; DOTFILES_BASE, WORKSPACE_DIR, CODEX_HOME and WRAP_LC_ALL (as LC_ALL) pass through when set
  local h="$1"; shift
  [ -n "$h" ] && [ "$h" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  OUT="$(env -i PATH="$PATH" HOME="$h" CLAUDE_SKILLS_DIR="$h/.claude/skills" \
      ${DOTFILES_BASE:+DOTFILES_BASE="$DOTFILES_BASE"} ${WORKSPACE_DIR:+WORKSPACE_DIR="$WORKSPACE_DIR"} \
      ${CODEX_HOME:+CODEX_HOME="$CODEX_HOME"} ${WRAP_LC_ALL:+LC_ALL="$WRAP_LC_ALL"} \
      bash "$h/src/my-config/setup.sh" "$@" 2>&1)"; RC=$?
}
show() { printf '%s\n' "$OUT" | sed 's/^/         /'; }

# Every path under a home, with each link's target and each file's checksum.
tree_snap() {
  (cd "$1" && find . -path ./src -prune -o -print | sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf '%s -> %s\n' "$p" "$(readlink "$p")"
    elif [ -f "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"
    else printf '%s/\n' "$p"; fi
  done)
  ls -l "$1/src/CLAUDE.md" 2>/dev/null | awk '{print $1, $NF}'
}
said() { case "$OUT" in *"$1"*) true ;; *) false ;; esac; }
json_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }

[ -x "$WRAPPER" ] || { echo "FAIL $WRAPPER is missing or not executable"; exit 1; }

echo "== a first run installs the base with the private layer on top =="
make_home first
wrap "$H"
check "it succeeds" "[ $RC -eq 0 ]" || show
check "the routing links into the private repo" "[ -L '$H/.config/git/config' ] && [ '$H/.config/git/config' -ef '$PRIV/git/config' ]"
check "  and so do the owners and an identity" "[ '$H/.config/git/owners' -ef '$PRIV/owners' ] && [ '$H/.config/git/identity-bob' -ef '$PRIV/git/identity-bob' ]"
check "  and the SSH aliases" "[ '$H/.ssh/config.d/github.conf' -ef '$PRIV/ssh/github.conf' ]"
check "the identity tools link into the base" "[ '$H/.local/bin/git-identity-check' -ef '$BASE/bin/git-identity-check' ]"
check "settings.json holds the overlay's key" "[ \"\$(json_get '$H/.claude/settings.json' model)\" = fixture-model ]"
check "the user instructions link into the base" "[ '$H/.claude/CLAUDE.md' -ef '$BASE/claude/CLAUDE.md' ]"
check "no starter files were created" "absent '$H/.config/dotfiles' && absent '$H/.config/git/accounts' && absent '$H/.config/git/repo-roots' && absent '$H/.config/tmux/local.conf'"
check "the workspace file is linked beside the checkouts" "[ -L '$H/src/CLAUDE.md' ] && [ \"\$(readlink '$H/src/CLAUDE.md')\" = '$PRIV/workspace/CLAUDE.md' ]"
check "nothing was moved aside" "[ -z \"\$(find '$H' -name '*.pre-dotfiles*' -print)\" ]"

echo "== a second run changes nothing =="
S0="$(tree_snap "$H")"
wrap "$H"
check "it succeeds" "[ $RC -eq 0 ]" || show
check "and the home is as it was" "[ \"\$(tree_snap '$H')\" = \"\$S0\" ]"

echo "== the checkouts are moved: --replace-links-from =="
mv "$BASE" "$H/src/dotfiles-renamed"
S0="$(tree_snap "$H")"
DOTFILES_BASE="$H/src/dotfiles-renamed" wrap "$H"
check "without the flag it refuses" "[ $RC -ne 0 ]"
check "  and writes nothing" "[ \"\$(tree_snap '$H')\" = \"\$S0\" ]"
DOTFILES_BASE="$H/src/dotfiles-renamed" wrap "$H" --replace-links-from "$BASE"
check "with the flag it succeeds" "[ $RC -eq 0 ]" || show
check "  and the links follow the new path" "[ '$H/.local/bin/gh-as' -ef '$H/src/dotfiles-renamed/bin/gh-as' ] && [ '$H/.claude/CLAUDE.md' -ef '$H/src/dotfiles-renamed/claude/CLAUDE.md' ]"
check "  and nothing was moved aside" "[ -z \"\$(find '$H' -name '*.pre-dotfiles*' -print)\" ]"
check "  and the routing still links into the private repo" "[ '$H/.config/git/config' -ef '$PRIV/git/config' ]"

echo "== both checkouts are moved together: --replace-links-from the folder that held them =="
make_home both
wrap "$H"
check "the first run succeeds" "[ $RC -eq 0 ]" || show
mv "$H/src" "$H/code"
H2="$H/code"
OUT="$(env -i PATH="$PATH" HOME="$H" CLAUDE_SKILLS_DIR="$H/.claude/skills" \
    bash "$H2/my-config/setup.sh" --replace-links-from "$H/src" 2>&1)"; RC=$?
check "with the old folder it succeeds" "[ $RC -eq 0 ]" || show
check "  and the routing follows the private repo" "[ '$H/.config/git/config' -ef '$H2/my-config/git/config' ]"
check "  and the tools follow the base" "[ '$H/.local/bin/gh-as' -ef '$H2/dotfiles/bin/gh-as' ]"
check "  and the workspace link was replaced" "[ \"\$(readlink '$H2/CLAUDE.md')\" = '$H2/my-config/workspace/CLAUDE.md' ]"
check "  and nothing was moved aside" "[ -z \"\$(find '$H' -name '*.pre-dotfiles*' -print)\" ]"

echo "== user instructions kept in the private repo =="
# The first home had no claude/CLAUDE.md, so it got the base's sample. Adding the file moves
# the machine over to it.
make_home userfile
wrap "$H"
check "without the file, the sample is installed" "[ $RC -eq 0 ] && [ '$H/.claude/CLAUDE.md' -ef '$BASE/claude/CLAUDE.md' ]" || show
mkdir -p "$PRIV/claude"; printf '# My own instructions.\n' > "$PRIV/claude/CLAUDE.md"
wrap "$H"
check "with it, ~/.claude/CLAUDE.md links to the repo's file" "[ $RC -eq 0 ] && [ \"\$(readlink '$H/.claude/CLAUDE.md')\" = '$PRIV/claude/CLAUDE.md' ]" || show
check "  and nothing was moved aside or kept" "[ -z \"\$(find '$H' -name '*.pre-dotfiles*' -print)\" ] && case \"\$OUT\" in *'Kept your'*) false ;; *) true ;; esac"
S0="$(tree_snap "$H")"; wrap "$H"
check "  and a second run changes nothing" "[ $RC -eq 0 ] && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]"

# AGENTS.md as the base generates it from files in the private repo, in order. Every file here
# ends in a newline, so a blank line is all that goes between two.
agents_want() {  # $@ = files under $PRIV, in order
  local f names="" first=1
  for f in "$@"; do names="${names:+$names, }~/src/my-config/$f"; done
  printf '<!-- Generated by setup.sh from %s. Edit the files named here, then run setup.sh again. -->\n' "$names"
  for f in "$@"; do [ "$first" = 1 ] || printf '\n'; first=0; cat "$PRIV/$f"; done
}
agents_is() { [ -f "$A" ] && [ ! -L "$A" ] && agents_want "$@" > "$T/want" && cmp -s "$A" "$T/want"; }
stamp() { python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_ino, s.st_mtime_ns)' "$1"; }

echo "== Codex's instructions: AGENTS.md generated from claude/CLAUDE.md and the rules =="
make_home codex
mkdir -p "$H/.codex" "$PRIV/claude/rules"; A="$H/.codex/AGENTS.md"; R="$H/.claude/rules"
printf '# Instructions for both tools.\n' > "$PRIV/claude/CLAUDE.md"
printf '# Rule c.\n' > "$PRIV/claude/rules/c.md"; printf '# Rule a.\n' > "$PRIV/claude/rules/a.md"
printf '# Rule B.\n' > "$PRIV/claude/rules/B.md"; printf 'not a rule\n' > "$PRIV/claude/rules/notes.txt"
wrap "$H"
check "it succeeds" "[ $RC -eq 0 ]" || show
check "  AGENTS.md holds claude/CLAUDE.md, then each rule in sorted order" "agents_is claude/CLAUDE.md claude/rules/B.md claude/rules/a.md claude/rules/c.md"
rules_linked() { local n; for n in "$@"; do [ "$(readlink "$R/$n.md")" = "$PRIV/claude/rules/$n.md" ] || return 1; done; }
check "  each rule is linked into ~/.claude/rules" "rules_linked B a c"
check "  and nothing else is" "[ \"\$(LC_ALL=C ls -A '$R' | tr '\n' ' ')\" = 'B.md a.md c.md ' ]"
check "  and the report names the rules and AGENTS.md" "said 'User rule linked:' && said '$R/a.md -> $PRIV/claude/rules/a.md' && said '$A: generated from'"
check "  and nothing else is in the Codex folder" "[ \"\$(ls -A '$H/.codex')\" = AGENTS.md ]"
S0="$(tree_snap "$H")"; ST="$(stamp "$A")"; wrap "$H"
check "a second run succeeds and changes nothing, AGENTS.md's mtime included" "[ $RC -eq 0 ] && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && [ \"\$(stamp '$A')\" = '$ST' ]" || show
# A locale that sorts B after a would change the order, and so the file, from machine to machine.
UTF8="$(locale -a 2>/dev/null | grep -i -m1 -E '^en_US\.utf-?8$' || true)"
if [ -n "$UTF8" ]; then
  WRAP_LC_ALL="$UTF8" wrap "$H"
  check "  and so does a run in the $UTF8 locale" "[ $RC -eq 0 ] && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && [ \"\$(stamp '$A')\" = '$ST' ]" || show
else
  echo "  (no en_US UTF-8 locale here: the sort order is checked in the C locale only)"
fi
printf '# Rule a, edited.\n' > "$PRIV/claude/rules/a.md"
check "an edit to a rule reaches Claude at once, through the link" "[ \"\$(cat '$R/a.md')\" = '# Rule a, edited.' ]"
wrap "$H"
check "  and Codex after a run" "[ $RC -eq 0 ] && agents_is claude/CLAUDE.md claude/rules/B.md claude/rules/a.md claude/rules/c.md" || show
rm "$PRIV/claude/rules/c.md"; wrap "$H"
check "a deleted rule: its link is removed" "[ $RC -eq 0 ] && absent '$R/c.md' && said 'User rule: removed the link $R/c.md'" || show
check "  and it leaves AGENTS.md" "agents_is claude/CLAUDE.md claude/rules/B.md claude/rules/a.md"
printf 'my own rule\n' > "$R/mine.md"; printf 'theirs\n' > "$H/theirs.md"; ln -s "$H/theirs.md" "$R/theirs.md"
S0="$(tree_snap "$H")"; wrap "$H"
check "a rule of your own in ~/.claude/rules is left alone, and not given to Codex" "[ $RC -eq 0 ] && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && ! said 'mine.md' && ! said 'theirs.md'" || show
ln -s "$H/src" "$H/src-link"; S0="$(tree_snap "$H")"
OUT="$(env -i PATH="$PATH" HOME="$H" bash "$H/src-link/my-config/setup.sh" 2>&1)"; RC=$?
check "a run started through a linked folder finds its own links" "[ $RC -eq 0 ] && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
rm "$H/src-link"
rm -r "$PRIV/claude"; cp "$A" "$T/agents-last"; wrap "$H"
check "with no claude/ at all, the rule links go" "[ $RC -eq 0 ] && absent '$R/B.md' && absent '$R/a.md' && [ -f '$R/mine.md' ]" || show
check "  and AGENTS.md is left as the last run made it" "cmp -s '$A' '$T/agents-last' && ! said 'AGENTS.md'"

echo "== Codex's instructions: rules alone, and where AGENTS.md goes =="
make_home rulesonly
mkdir -p "$H/.codex" "$PRIV/claude/rules"; A="$H/.codex/AGENTS.md"; printf '# Only rule.\n' > "$PRIV/claude/rules/only.md"
wrap "$H"
check "with rules and no claude/CLAUDE.md, AGENTS.md holds the rules" "[ $RC -eq 0 ] && agents_is claude/rules/only.md" || show
check "  and ~/.claude/CLAUDE.md is the base's sample" "[ '$H/.claude/CLAUDE.md' -ef '$BASE/claude/CLAUDE.md' ]"
make_home nocodex
mkdir -p "$PRIV/claude/rules"; printf '# Mine.\n' > "$PRIV/claude/CLAUDE.md"; printf '# Rule.\n' > "$PRIV/claude/rules/r.md"
wrap "$H"
check "with no Codex folder it succeeds and makes none" "[ $RC -eq 0 ] && absent '$H/.codex'" || show
check "  and the report says so" "said 'no Codex folder at $H/.codex'"
check "  and the rule is still linked" "[ \"\$(readlink '$H/.claude/rules/r.md')\" = '$PRIV/claude/rules/r.md' ]"
make_home codexhome
mkdir -p "$PRIV/claude" "$H/codex-elsewhere"; printf '# Mine.\n' > "$PRIV/claude/CLAUDE.md"; A="$H/codex-elsewhere/AGENTS.md"
CODEX_HOME="$H/codex-elsewhere" wrap "$H"
check "with CODEX_HOME set, AGENTS.md is generated there" "[ $RC -eq 0 ] && agents_is claude/CLAUDE.md" || show
check "  and no ~/.codex is made" "absent '$H/.codex'"
make_home nouserfile
mkdir -p "$H/.codex"; A="$H/.codex/AGENTS.md"
wrap "$H"
check "with no claude/ files, no AGENTS.md is made" "[ $RC -eq 0 ] && absent '$A' && ! said 'AGENTS.md'" || show
printf 'my own Codex notes\n' > "$A"; wrap "$H"
check "  and one of yours is left alone, not refused" "[ $RC -eq 0 ] && [ \"\$(cat '$A')\" = 'my own Codex notes' ]" || show

echo "== Codex's instructions: an AGENTS.md that isn't generated is refused =="
make_home codexown
mkdir -p "$H/.codex" "$PRIV/claude"; printf '# Mine.\n' > "$PRIV/claude/CLAUDE.md"; A="$H/.codex/AGENTS.md"
printf 'my own Codex notes\n' > "$A"; cp "$A" "$T/own"
wrap "$H"
check "a file of yours stops the plain run, naming it" "[ $RC -ne 0 ] && said '$A exists and was not generated by setup.sh'" || show
check "  before it writes anything" "absent '$H/.claude' && cmp -s '$A' '$T/own'"
cp "$PRIV/claude/CLAUDE.md" "$A"; cp "$A" "$T/own"; wrap "$H"
check "a copy with the same bytes is refused too" "[ $RC -ne 0 ] && said '$A exists' && cmp -s '$A' '$T/own' && [ ! -L '$A' ]"
rm -f "$A"; printf 'theirs\n' > "$H/theirs.md"; ln -s "$H/theirs.md" "$A"; wrap "$H"
check "a link to somewhere else is refused" "[ $RC -ne 0 ] && said '$A exists' && [ \"\$(readlink '$A')\" = '$H/theirs.md' ]"

echo "== Codex's instructions: a link at AGENTS.md is never the wrapper's =="
# The base counts no link there as its own, so even a link to claude/CLAUDE.md, the wrapper's own
# file, stops the run and is left in place.
make_home codexlink
mkdir -p "$H/.codex" "$PRIV/claude"; printf '# Mine.\n' > "$PRIV/claude/CLAUDE.md"; A="$H/.codex/AGENTS.md"
ln -s "$PRIV/claude/CLAUDE.md" "$A"; wrap "$H"
check "a link to claude/CLAUDE.md is refused, and left as it was" "[ $RC -ne 0 ] && said 'If $A is a link, move it aside first' && [ \"\$(readlink '$A')\" = '$PRIV/claude/CLAUDE.md' ]" || show
check "  and the source is untouched" "[ \"\$(cat '$PRIV/claude/CLAUDE.md')\" = '# Mine.' ] && [ ! -L '$PRIV/claude/CLAUDE.md' ]"
rm "$A"; ln -s ../src/my-config/claude/CLAUDE.md "$A"; wrap "$H"
check "  and so is a relative one" "[ $RC -ne 0 ] && said 'If $A is a link, move it aside first' && [ \"\$(readlink '$A')\" = ../src/my-config/claude/CLAUDE.md ]"
rm "$A"; ln -s "$PRIV/settings-overlay.json" "$A"; wrap "$H"
check "a link to another file in the repo is refused too" "[ $RC -ne 0 ] && said '$A exists and was not generated' && [ \"\$(readlink '$A')\" = '$PRIV/settings-overlay.json' ]"
rm "$A"; wrap "$H"
check "once the link is moved aside, the run generates the file" "[ $RC -eq 0 ] && agents_is claude/CLAUDE.md" || show
run_renamed() { OUT="$(env -i PATH="$PATH" HOME="$H" bash "$PRIV/setup.sh" "$@" 2>&1)"; RC=$?; }

echo "== a rule destination that isn't the wrapper's is refused =="
make_home ruleown
mkdir -p "$PRIV/claude/rules" "$H/.claude/rules"; printf '# Rule.\n' > "$PRIV/claude/rules/r.md"; RD="$H/.claude/rules/r.md"
printf 'my own rule\n' > "$RD"
S0="$(tree_snap "$H")"; wrap "$H"
check "a file of yours is refused, with nothing written" "[ $RC -ne 0 ] && said '$RD exists and is not this repo' && said 'Nothing was written' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
check "  and the message names no link target for a file" "! said 'it links to'"
rm "$RD"; ln -s ../../src/my-config/claude/rules/r.md "$RD"
S0="$(tree_snap "$H")"; wrap "$H"
check "a relative link to the same file is refused" "[ $RC -ne 0 ] && said '$RD exists' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
rm "$RD"; mkdir "$RD"; S0="$(tree_snap "$H")"; wrap "$H"
check "a folder there is refused" "[ $RC -ne 0 ] && said '$RD exists' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show

echo "== a source must be a real file in a real folder =="
# claude/ links to ~/.claude, which doesn't exist yet: the base run would create the source.
make_home codexcircle
mkdir -p "$H/.codex"; A="$H/.codex/AGENTS.md"
printf 'my own Codex notes\n' > "$A"; cp "$A" "$T/codexcircle-agents"
rm -rf "$PRIV/claude"; ln -s "$H/.claude" "$PRIV/claude"
S0="$(tree_snap "$H")"; wrap "$H"
check "a claude folder that is a link is refused, with nothing written" "[ $RC -ne 0 ] && said 'must be a real file in this repo' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && absent '$H/.claude'" || show
check "  and AGENTS.md survives byte for byte" "[ ! -L '$A' ] && cmp -s '$A' '$T/codexcircle-agents'"
# The same with the workspace folder, and a ~/src/CLAUDE.md of your own.
make_home wscircle
rm -rf "$PRIV/workspace"; ln -s "$H/.claude" "$PRIV/workspace"
printf 'my own workspace notes\n' > "$H/src/CLAUDE.md"; cp "$H/src/CLAUDE.md" "$T/wscircle-notes"
S0="$(tree_snap "$H")"; wrap "$H"
check "a workspace folder that is a link is refused, with nothing written" "[ $RC -ne 0 ] && said 'must be a real file in this repo' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && absent '$H/.claude'" || show
check "  and the workspace file survives byte for byte" "[ ! -L '$H/src/CLAUDE.md' ] && cmp -s '$H/src/CLAUDE.md' '$T/wscircle-notes'"
# claude/CLAUDE.md links to AGENTS.md, which links into the old checkout.
make_home codexloop
mkdir -p "$H/.codex" "$H/old"; A="$H/.codex/AGENTS.md"
printf 'old instructions\n' > "$H/old/instructions.md"; ln -s "$H/old/instructions.md" "$A"
mkdir -p "$PRIV/claude"; ln -s "$A" "$PRIV/claude/CLAUDE.md"
S0="$(tree_snap "$H")"; wrap "$H" --replace-links-from "$H/old"
check "a source that is a link is refused, with nothing written" "[ $RC -ne 0 ] && said 'must be a real file in this repo' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
check "  and AGENTS.md still links where it did" "[ \"\$(readlink '$A')\" = '$H/old/instructions.md' ] && [ \"\$(cat '$A')\" = 'old instructions' ]"
# claude/rules links to ~/.claude/rules, and a rule is a link.
make_home rulescircle
mkdir -p "$PRIV/claude"; ln -s "$H/.claude/rules" "$PRIV/claude/rules"
S0="$(tree_snap "$H")"; wrap "$H"
check "a rules folder that is a link is refused, with nothing written" "[ $RC -ne 0 ] && said 'must be a real file in this repo' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ] && absent '$H/.claude'" || show
make_home rulelink
mkdir -p "$PRIV/claude/rules"; printf '# Elsewhere.\n' > "$H/elsewhere.md"; ln -s "$H/elsewhere.md" "$PRIV/claude/rules/r.md"
S0="$(tree_snap "$H")"; wrap "$H"
check "a rule that is a link is refused, with nothing written" "[ $RC -ne 0 ] && said '$PRIV/claude/rules/r.md must be a real file' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show

echo "== the workspace link with no workspace/CLAUDE.md =="
make_home wsgone
wrap "$H"
check "the first run links it" "[ $RC -eq 0 ] && [ \"\$(readlink '$H/src/CLAUDE.md')\" = '$PRIV/workspace/CLAUDE.md' ]" || show
rm "$PRIV/workspace/CLAUDE.md"; wrap "$H"
check "  and once the file is deleted, the wrapper's own link is removed" "[ $RC -eq 0 ] && absent '$H/src/CLAUDE.md' && said 'Workspace instructions: removed the link'" || show
printf 'my own workspace notes\n' > "$H/src/CLAUDE.md"; wrap "$H"
check "  and a file of yours is left alone, not refused" "[ $RC -eq 0 ] && [ \"\$(cat '$H/src/CLAUDE.md')\" = 'my own workspace notes' ] && said 'Workspace instructions: left $H/src/CLAUDE.md alone'" || show

echo "== a link past a missing folder with .. is never the wrapper's =="
make_home codexdots
mkdir -p "$H/.codex" "$H/src/personal"; A="$H/.codex/AGENTS.md"
printf 'personal\n' > "$H/src/personal/AGENTS.md"
ln -s "$H/src/old/../personal/AGENTS.md" "$A"
wrap "$H" --replace-links-from "$H/src/old"
check "with no claude/ files, AGENTS.md is left alone" "[ $RC -eq 0 ] && [ \"\$(readlink '$A')\" = '$H/src/old/../personal/AGENTS.md' ]" || show
make_home wsdots
ln -s "$H/src/old/../personal.md" "$H/src/CLAUDE.md"
wrap "$H" --replace-links-from "$H/src/old"
check "a workspace link like it is refused" "[ $RC -ne 0 ] && said 'is not this repo' && [ \"\$(readlink '$H/src/CLAUDE.md')\" = '$H/src/old/../personal.md' ] && absent '$H/.claude'" || show
make_home ruledots
mkdir -p "$PRIV/claude/rules" "$H/.claude/rules"; printf '# Rule.\n' > "$PRIV/claude/rules/r.md"
ln -s "$H/src/old/../personal.md" "$H/.claude/rules/r.md"
wrap "$H" --replace-links-from "$H/src/old"
check "and so is a rule link like it" "[ $RC -ne 0 ] && said 'is not this repo' && [ \"\$(readlink '$H/.claude/rules/r.md')\" = '$H/src/old/../personal.md' ]" || show
# A link in the old checkout to a missing folder: the target names a file below the old path,
# but not the wrapper's file.
make_home codexjump
mkdir -p "$H/.codex" "$H/old"; A="$H/.codex/AGENTS.md"
ln -s "$H/personal-notes" "$H/old/jump"; ln -s "$H/old/jump/claude/CLAUDE.md" "$A"
wrap "$H" --replace-links-from "$H/old"
check "a link through a link in the old checkout is left alone" "[ $RC -eq 0 ] && [ \"\$(readlink '$A')\" = '$H/old/jump/claude/CLAUDE.md' ]" || show
S0="$(tree_snap "$H")"
for bad in old "$H/src/x/../old" "$H/./old"; do
  wrap "$H" --replace-links-from "$bad"
  check "--replace-links-from $bad is refused, with nothing written" "[ $RC -eq 2 ] && said 'absolute path with no . or ..' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
done

echo "== a link target is compared exactly, a trailing newline included =="
make_home rulenl
mkdir -p "$H/.claude/rules"; RD="$H/.claude/rules/r.md"; NL='
'
ln -s "$PRIV/claude/rules/r.md$NL" "$RD"
check "the setup: the target ends in a newline" "[ \"\$(python3 -c 'import os,sys; sys.stdout.write(os.readlink(sys.argv[1])+\"x\")' '$RD')\" = '$PRIV/claude/rules/r.md${NL}x' ]"
wrap "$H"
check "with no such rule, that link is left alone" "[ $RC -eq 0 ] && [ -L '$RD' ] && ! said 'removed the link'" || show
mkdir -p "$PRIV/claude/rules"; printf '# Rule.\n' > "$PRIV/claude/rules/r.md"
S0="$(tree_snap "$H")"; wrap "$H"
check "  and with it, refused, naming the target" "[ $RC -ne 0 ] && said '(it links to $PRIV/claude/rules/r.md$NL)' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show

echo "== a renamed private repo: the rule links follow it =="
# No identity data and no workspace file, so the rule link is the only link into the old path
# that the wrapper itself checks.
make_home rulemove
rm -rf "$PRIV/owners" "$PRIV/git" "$PRIV/ssh" "$PRIV/workspace"
mkdir -p "$PRIV/claude/rules" "$H/.codex"; printf '# Rule.\n' > "$PRIV/claude/rules/r.md"; RD="$H/.claude/rules/r.md"
wrap "$H"
check "the first run succeeds" "[ $RC -eq 0 ] && [ -L '$RD' ] && head -n 1 '$H/.codex/AGENTS.md' | grep -q '~/src/my-config/claude/rules/r.md'" || show
mv "$PRIV" "$H/src/my-config-renamed"; OLD="$PRIV"; PRIV="$H/src/my-config-renamed"
S0="$(tree_snap "$H")"; run_renamed
check "without the flag the old link is refused" "[ $RC -ne 0 ] && said '$RD exists and is not this repo' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
run_renamed --replace-links-from "$OLD/"
check "with the flag it follows the repo" "[ $RC -eq 0 ] && [ \"\$(readlink '$RD')\" = '$PRIV/claude/rules/r.md' ] && [ \"\$(cat '$RD')\" = '# Rule.' ]" || show
check "  and AGENTS.md is generated again, naming the new path" "head -n 1 '$H/.codex/AGENTS.md' | grep -q '~/src/my-config-renamed/claude/rules/r.md' && grep -qx '# Rule.' '$H/.codex/AGENTS.md'"
# Moved again, with the old path named through a link to the folder that held it. The links
# hold the physical path, so the old path counts in either spelling.
ln -s "$H/src" "$H/alias"; OLD="$H/alias/my-config-renamed"
mv "$PRIV" "$H/src/my-config-again"; PRIV="$H/src/my-config-again"
S0="$(tree_snap "$H")"; run_renamed
check "without the flag, the refusal names the link's target" "[ $RC -ne 0 ] && said '(it links to $H/src/my-config-renamed/claude/rules/r.md)' && [ \"\$(tree_snap '$H')\" = \"\$S0\" ]" || show
run_renamed --replace-links-from "$OLD"
check "an old path named through a linked folder counts too" "[ $RC -eq 0 ] && [ \"\$(readlink '$RD')\" = '$PRIV/claude/rules/r.md' ]" || show
# A link that holds the old path as given, as a wrapper started through the link once wrote it.
rm "$RD"; ln -s "$H/alias/my-config-before/claude/rules/r.md" "$RD"
run_renamed --replace-links-from "$H/alias/my-config-before"
check "  and so does a link that holds the old path as given" "[ $RC -eq 0 ] && [ \"\$(readlink '$RD')\" = '$PRIV/claude/rules/r.md' ]" || show

echo "== the README's sample workspace file =="
make_home sample
SAMPLE="$BASE/examples/private-layer/workspace-CLAUDE.md"
check "the sample ships" "[ -s '$SAMPLE' ]"
# The README's "Starting the repo" commands, run as written from an empty home that holds
# only the base, so a step dropped from the README fails here.
START="$(awk '/^### Starting the repo/{f=1} f&&/^```bash/{c=1;next} c&&/^```/{exit} c' "$DOTFILES/README.md")"
check "  and the README has start-up commands" "[ -n \"\$START\" ]"
H0="$T/start"; mkdir -p "$H0/src/dotfiles"
(cd "$DOTFILES" && tar cf - --exclude=.git .) | (cd "$H0/src/dotfiles" && tar xf -)
env -i PATH="$PATH" HOME="$H0" bash -e -c "$START" >/dev/null 2>&1; START_RC=$?
check "  and they run as written" "[ $START_RC -eq 0 ]"
check "  and leave the sample as workspace/CLAUDE.md" "cmp -s '$H0/src/my-config/workspace/CLAUDE.md' '$SAMPLE'"
check "  and the wrapper and overlay beside it" "[ -f '$H0/src/my-config/setup.sh' ] && [ -f '$H0/src/my-config/settings-overlay.json' ] && [ -f '$H0/src/my-config/owners' ]"
cp "$SAMPLE" "$PRIV/workspace/CLAUDE.md"
wrap "$H"
check "with the sample as the workspace file, the wrapper links it" "[ $RC -eq 0 ] && [ \"\$(readlink '$H/src/CLAUDE.md')\" = '$PRIV/workspace/CLAUDE.md' ] && cmp -s '$H/src/CLAUDE.md' '$SAMPLE'"

echo "== a workspace file that isn't the wrapper's is left alone =="
make_home ownfile
printf 'my own workspace notes\n' > "$H/src/CLAUDE.md"
wrap "$H"
check "it refuses" "[ $RC -ne 0 ] && case \"\$OUT\" in *'is not this repo'*) true ;; *) false ;; esac" || show
check "  and the file is untouched" "[ ! -L '$H/src/CLAUDE.md' ] && [ \"\$(cat '$H/src/CLAUDE.md')\" = 'my own workspace notes' ]"
check "  and nothing else was written" "absent '$H/.claude' && absent '$H/.config'"
rm -f "$H/src/CLAUDE.md"; ln -s "$H/elsewhere.md" "$H/src/CLAUDE.md"
wrap "$H"
check "a link to somewhere else is refused too" "[ $RC -ne 0 ] && [ \"\$(readlink '$H/src/CLAUDE.md')\" = '$H/elsewhere.md' ] && absent '$H/.claude'"

echo "== a workspace folder that is or holds the home folder is refused =="
make_home homews
WORKSPACE_DIR="$H" wrap "$H"
check "the home folder is refused" "[ $RC -ne 0 ] && absent '$H/CLAUDE.md' && absent '$H/.claude'"
WORKSPACE_DIR="$T" wrap "$H"
check "a folder holding it is refused" "[ $RC -ne 0 ] && absent '$T/CLAUDE.md' && absent '$H/.claude'"

echo "== a repo with no identity data: the identity install is skipped =="
make_home noident
rm -rf "$PRIV/owners" "$PRIV/git" "$PRIV/ssh"
wrap "$H"
check "it succeeds" "[ $RC -eq 0 ]" || show
check "  and says it skipped the identity install" "case \"\$OUT\" in *'No owners in'*'skipping the git identity install'*) true ;; *) false ;; esac"
check "  and installs no routing or tools" "absent '$H/.config/git/config' && absent '$H/.local/bin/gh-as'"
check "  and still applies the overlay and the workspace file" "[ \"\$(json_get '$H/.claude/settings.json' model)\" = fixture-model ] && [ -L '$H/src/CLAUDE.md' ]"
wrap "$H"
check "  and a second run succeeds" "[ $RC -eq 0 ]"

echo "== an owners file with only comments: the identity install is skipped too =="
make_home unfilled
rm -rf "$PRIV/owners" "$PRIV/git" "$PRIV/ssh"; cp -R "$BASE/starters/identity/." "$PRIV/"
check "the base itself refuses that folder" "! env -i PATH=\"\$PATH\" HOME='$H' bash '$BASE/setup.sh' --git-identity --identity-dir '$PRIV' >/dev/null 2>&1"
wrap "$H"
check "the wrapper succeeds" "[ $RC -eq 0 ] && case \"\$OUT\" in *'only comments'*) true ;; *) false ;; esac" || show
check "  and installs no routing" "absent '$H/.config/git/config' && [ \"\$(json_get '$H/.claude/settings.json' model)\" = fixture-model ]"

# The one-machine route: the layer in ~/.config/dotfiles, installed by plain runs of the base.
# Sets $H, $BASE, $PRIV, with $PRIV holding only the wrapper.
one_machine_home() {  # $1 = a name for the home
  make_home "$1"
  rm -rf "$PRIV"; mkdir -p "$PRIV" "$H/.config/dotfiles"
  cp "$BASE/examples/private-layer/setup.sh" "$PRIV/setup.sh"
  cp -R "$FIXTURE" "$H/.config/dotfiles/identity"
  printf '{"model": "fixture-model"}\n' > "$H/.config/dotfiles/settings-overlay.json"
  env -i PATH="$PATH" HOME="$H" bash "$BASE/setup.sh" >/dev/null 2>&1 \
    && env -i PATH="$PATH" HOME="$H" bash "$BASE/setup.sh" --git-identity >/dev/null 2>&1 \
    && [ "$H/.config/git/config" -ef "$H/.config/dotfiles/identity/git/config" ] \
    || { echo "FAIL the one-machine home could not be set up" >&2; exit 2; }
  # As the README says: start the repo from the files this machine already has.
  cp -R "$H/.config/dotfiles/identity/." "$PRIV/"
  cp "$H/.config/dotfiles/settings-overlay.json" "$PRIV/"
}
no_link_into() {  # $1 = home, $2 = folder: no link under the home points into the folder
  local l
  for l in $(find "$1" -path "$1/src" -prune -o -type l -print); do
    case "$(readlink "$l")" in "$2"/*) return 1 ;; esac
  done
  return 0
}

echo "== moving from files on one machine: unchanged copies switch over =="
one_machine_home move
wrap "$H"
check "the wrapper succeeds" "[ $RC -eq 0 ]" || show
check "  and the routing now links into the repo" "[ \"\$(readlink '$H/.config/git/config')\" = '$PRIV/git/config' ] && [ \"\$(readlink '$H/.ssh/config.d/github.conf')\" = '$PRIV/ssh/github.conf' ]"
check "  and nothing links into ~/.config/dotfiles" "no_link_into '$H' '$H/.config/dotfiles'"
check "  and the settings keep the overlay" "[ \"\$(json_get '$H/.claude/settings.json' model)\" = fixture-model ]"
check "  and the per-machine files stay" "[ -f '$H/.config/git/accounts' ] && [ -f '$H/.config/tmux/local.conf' ]"
# The README's check before deleting the old folder, taken from the README so the two agree.
LEFTOVER_CMD="$(grep -m1 '^ls -l ~/.claude ' "$DOTFILES/README.md")"
leftovers() { env -i PATH="$PATH" HOME="$H" bash -c "$LEFTOVER_CMD" 2>/dev/null; }
check "the README's leftover check is there" "[ -n \"\$LEFTOVER_CMD\" ]"
check "  and prints nothing once the switch is done" "[ -z \"\$(leftovers)\" ]"
# An identity taken out of owners earlier: the install never removes its link.
cp "$H/.config/dotfiles/identity/git/identity-bob" "$H/.config/dotfiles/identity/git/identity-old"
ln -s "$H/.config/dotfiles/identity/git/identity-old" "$H/.config/git/identity-old"
check "  and names a link left over" "case \"\$(leftovers)\" in *identity-old*) true ;; *) false ;; esac"
wrap "$H"
check "  which a wrapper run leaves in place" "[ $RC -eq 0 ] && [ -L '$H/.config/git/identity-old' ]"
rm "$H/.config/git/identity-old"
check "  and prints nothing once it is deleted" "[ -z \"\$(leftovers)\" ]"
rm -r "$H/.config/dotfiles"
wrap "$H"
check "after deleting the old folder, a run still succeeds" "[ $RC -eq 0 ] && absent '$H/.config/dotfiles'" || show

echo "== moving from files on one machine: a copy edited first needs the old folder named =="
one_machine_home moveedited
printf '# edited in the repo\n' >> "$PRIV/git/identity-bob"
S0="$(tree_snap "$H")"
wrap "$H"
check "without the flag it refuses" "[ $RC -ne 0 ] && case \"\$OUT\" in *identity-bob*) true ;; *) false ;; esac"
check "  and writes nothing" "[ \"\$(tree_snap '$H')\" = \"\$S0\" ]"
wrap "$H" --replace-links-from "$H/.config/dotfiles/identity"
check "with the old folder named it succeeds" "[ $RC -eq 0 ]" || show
check "  and every link moved to the repo" "[ '$H/.config/git/identity-bob' -ef '$PRIV/git/identity-bob' ] && no_link_into '$H' '$H/.config/dotfiles'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
