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
wrap() {  # $1 = HOME, $2.. = arguments; DOTFILES_BASE and WORKSPACE_DIR pass through when set
  local h="$1"; shift
  [ -n "$h" ] && [ "$h" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  OUT="$(env -i PATH="$PATH" HOME="$h" CLAUDE_SKILLS_DIR="$h/.claude/skills" \
      ${DOTFILES_BASE:+DOTFILES_BASE="$DOTFILES_BASE"} ${WORKSPACE_DIR:+WORKSPACE_DIR="$WORKSPACE_DIR"} \
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
