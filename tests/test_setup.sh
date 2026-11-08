#!/usr/bin/env bash
#
# setup.sh must produce the same result on a machine that has never seen it.
#
# Every case runs against a throwaway HOME, and each asserts the redirection before
# invoking anything. setup.sh installs no skills — that is itself asserted
# below — but it still writes symlinks all over ~/.claude, so a run with HOME unset
# would rewrite the live setup.
#
# The negative cases matter more than the positive ones. A setup.sh that created
# every link unconditionally would pass "the file is there" and fail the machine
# it was written for.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$DOTFILES/tests/fixtures/identity"
PASS=0
FAIL=0
LIVE_SNAP="$(mktemp)"

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# A link that exists but dangles is still a link: `-L` alone would pass on a
# target that was never created, so resolution is what gets asserted.
resolves() { [ -L "$1" ] && [ -e "$1" ]; }

# `! -e` alone passes for a DANGLING symlink — the link is there, its target is not,
# and the absence check would call that success. Absent means neither.
absent()   { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# An exit code is the whole assertion here, so it gets its own predicate rather than
# being escaped through `check`'s eval, which can compare the wrong `$?` and report a
# failure that is the test's, not the script's.
exits_with() { local want="$1"; shift; "$@" >/dev/null 2>&1; [ "$?" -eq "$want" ]; }

# Output is captured before matching rather than piped into `grep -q`. Under this file's
# `set -o pipefail` that pipeline FAILS even when the match succeeds: grep -q exits at the
# first hit, setup.sh takes SIGPIPE, and pipefail reports the pipeline by its worst member.
# It reads as the guard not firing when the guard fired.

# The real HOME must be byte-identical before and after. Comparing only that the test
# HOME differs from it restates a precondition and proves nothing about what ran.
live_snapshot() {
  for f in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json" \
           "$HOME/.claude/hooks/guard-codex-exec.py"; do
    printf '%s %s\n' "$f" "$(readlink "$f" 2>/dev/null || echo none)"
  done
  ls -1 "$HOME/.claude/skills" 2>/dev/null | sort
  printf '%s %s\n' "$HOME/.codex/AGENTS.md" "$(readlink "$HOME/.codex/AGENTS.md" 2>/dev/null || echo none)"
  cksum < "$HOME/.codex/config.toml" 2>/dev/null || echo none
  # A file beside this checkout, by INODE as well as target: a run that deleted and
  # re-linked it would leave the target identical, and only the inode shows it.
  W="$(dirname "$DOTFILES")/CLAUDE.md"
  printf '%s %s %s\n' "$W" "$(readlink "$W" 2>/dev/null || echo none)" "$(ls -di "$W" 2>/dev/null | awk '{print $1}')"
  # The identity component's destinations, and the files it must never write.
  for f in "$HOME/.gitconfig" "$HOME/.ssh/config" "$HOME/.ssh/allowed_signers" \
           "$HOME"/.config/git/* "$HOME"/.ssh/config.d/* \
           "$HOME/.local/bin/gh-as" "$HOME/.local/bin/git-identity-check"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    printf '%s %s %s\n' "$f" "$(readlink "$f" 2>/dev/null || echo file)" "$(cksum < "$f" 2>/dev/null || echo unreadable)"
  done
}

# The hook returns a JSON decision. Grepping its prose for "deny" passes on any message
# that merely contains the word — including one explaining why something was allowed.
hook_decision() {
  printf '%s' "$1" | python3 "$DOTFILES/claude/hooks/guard-codex-exec.py" 2>/dev/null \
    | python3 -c "import json,sys; d=sys.stdin.read().strip(); print(json.loads(d)['hookSpecificOutput']['permissionDecision'] if d else 'allow')" 2>/dev/null || echo parse-error
}

new_home() {
  local h; h="$(mktemp -d)"
  printf '%s' "$h"
}

run_setup() {
  # $1 = HOME, $2.. = extra setup.sh flags
  [ -n "$1" ] && [ "$1" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  local h="$1"; shift
  env -i PATH="$PATH" HOME="$h" CLAUDE_SKILLS_DIR="$h/.claude/skills" \
      bash "$DOTFILES/setup.sh" "$@" >/dev/null 2>&1
}

# Same run, stdout kept. Needed because what the script SAYS about skills is now the
# whole of what it does about them.
setup_output() {
  [ -n "$1" ] && [ "$1" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  env -i PATH="$PATH" HOME="$1" CLAUDE_SKILLS_DIR="$1/.claude/skills" \
      bash "$DOTFILES/setup.sh" 2>&1
}

live_snapshot > "$LIVE_SNAP"

echo "== a plain run: every link is created and resolves =="
H="$(new_home)"; mkdir -p "$H/repos"
run_setup "$H"
check "user CLAUDE.md resolves"        "resolves '$H/.claude/CLAUDE.md'"
check "no user rules are installed"    "absent '$H/.claude/rules'"
check "guard hook resolves"            "resolves '$H/.claude/hooks/guard-codex-exec.py'"
check "settings.json is a real file"   "[ -f '$H/.claude/settings.json' ] && [ ! -L '$H/.claude/settings.json' ]"
check "live HOME untouched"            "[ \"\$(cat $LIVE_SNAP)\" = \"\$(live_snapshot)\" ]"

echo "== skills are reported, never installed =="
# A count above zero can't tell installed from downgraded, so the assertion is not that
# skills exist. setup.sh installs none, so the thing to assert is that it installs none
# and says so, without pointing at any one project's installer.
check "installs no skills"             "[ \"\$(ls -1 '$H/.claude/skills' 2>/dev/null | wc -l)\" -eq 0 ]"
# Captured, not piped into grep -q: see the note above live_snapshot.
check "says none are installed"        "case \"\$(setup_output '$H')\" in *'Skills: none installed'*'does not install them'*) true ;; *) false ;; esac"
check "names no installer command"     "case \"\$(setup_output '$H')\" in *'install.py'*|*'install.sh'*) false ;; *) true ;; esac"
mkdir -p "$H/.claude/skills/demo"; printf -- '---\nname: demo\ndescription: a fixture\n---\n' > "$H/.claude/skills/demo/SKILL.md"
check "counts skills that are there"   "case \"\$(setup_output '$H')\" in *'Skills: 1 installed'*) true ;; *) false ;; esac"
rm -rf "$H/.claude/skills"
check "still exits 0 with no skills"   "setup_output '$H' >/dev/null"
check "live skills untouched"          "[ \"\$(cat $LIVE_SNAP)\" = \"\$(live_snapshot)\" ]"

echo "== a base install creates no workspace file and needs no moved file =="
# The file above the repos names the installer's own projects, so it belongs to whichever
# repo holds those. The base must not create it wherever the repos are, and must not need
# anything that lives outside this checkout's shipped folders.
# The copy holds setup.sh and only the folders it installs from.
HB0="$(new_home)"; mkdir -p "$HB0/src/dotfiles"
(cd "$DOTFILES" && cp -R setup.sh bin claude codex starters tmux "$HB0/src/dotfiles/")
env -i PATH="$PATH" HOME="$HB0" WORKSPACE_DIR="$HB0/src" \
    CLAUDE_SKILLS_DIR="$HB0/.claude/skills" bash "$HB0/src/dotfiles/setup.sh" >/dev/null 2>&1; rc=$?
check "setup.sh exits 0 with only the files it installs" "[ $rc -eq 0 ]"
check "the user file still went in"    "resolves '$HB0/.claude/CLAUDE.md'"
check "nothing at WORKSPACE_DIR, even when it is set" "absent '$HB0/src/CLAUDE.md'"
check "nothing beside the checkout"    "absent '$HB0/src/dotfiles/../CLAUDE.md'"
check "nothing in \$HOME"              "absent '$HB0/CLAUDE.md'"
# A person's own file there is theirs: not replaced, not moved aside.
printf 'my own workspace notes\n' > "$HB0/src/CLAUDE.md"
env -i PATH="$PATH" HOME="$HB0" \
    CLAUDE_SKILLS_DIR="$HB0/.claude/skills" bash "$HB0/src/dotfiles/setup.sh" >/dev/null 2>&1
check "a workspace file already there is left alone" "[ \"\$(cat '$HB0/src/CLAUDE.md')\" = 'my own workspace notes' ] && absent '$HB0/src/CLAUDE.md.pre-dotfiles'"
check "the base names no workspace file" "! grep -qE 'WORKSPACE_DIR|workspace/CLAUDE' '$DOTFILES/setup.sh'"

echo "== idempotent =="
H4="$(new_home)"; mkdir -p "$H4/repos"
run_setup "$H4"
# Compares link TARGETS, not just names: a second run that repointed a link at a
# different file would leave the name list identical and the setup wrong.
# readlink gives the link target, empty for a regular file — so this alone would compare
# names only under --copy and miss changed content. A checksum of each file's bytes is
# appended for that reason, and both modes are exercised.
#
# Only POSIX find, readlink and cksum: the GNU-only `find -printf` and `md5sum` fail on
# macOS, where both snapshots would come out identical and empty, and the check would pass
# without comparing anything. The non-empty checks below catch that.
snap(){ (cd "$1" && find . -maxdepth 4 \( -type l -o -type f \) | sort | while IFS= read -r f; do
           printf '%s -> %s %s\n' "$f" "$(readlink "$f" 2>/dev/null)" "$(cksum < "$f" 2>/dev/null || echo dangling)"
         done); }
A="$(snap "$H4")"
run_setup "$H4"
B="$(snap "$H4")"
check "link snapshot is not empty"     "case \"\$A\" in *'CLAUDE.md -> /'*) true ;; *) false ;; esac"
check "two link runs are identical"    "[ \"\$A\" = \"\$B\" ]"

H5="$(new_home)"; mkdir -p "$H5/repos"
run_setup "$H5" --copy
C="$(snap "$H5")"
run_setup "$H5" --copy
D="$(snap "$H5")"
check "copy snapshot is not empty"     "case \"\$C\" in *'settings.json -> '*) true ;; *) false ;; esac"
check "two copy runs are identical"    "[ \"\$C\" = \"\$D\" ]"

echo "== the guard hook denies an unguarded codex exec =="
# A PreToolUse hook only fires inside a Claude Code session, so a shell test
# cannot trigger one. The script's own behavior is what is asserted here.
PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"codex exec -s read-only \"hi\""}}'
check "unguarded run is denied"        "[ \"\$(hook_decision \"\$PAYLOAD\")\" = deny ]"
GUARDED='{"tool_name":"Bash","tool_input":{"command":"timeout 60 codex exec -s read-only \"hi\" < /dev/null"}}'
check "guarded run is allowed"         "[ \"\$(hook_decision \"\$GUARDED\")\" != deny ]"

echo "== the base settings hold what a stranger needs, and no blanket permission =="
base_get() { python3 -c "import json,sys;d=json.load(open('$DOTFILES/claude/settings.json'));print(eval(sys.argv[1]))" "$1" 2>/dev/null; }
check "the guard hook is wired"            "base_get \"d['hooks']['PreToolUse'][0]['hooks'][0]['command']\" | grep -q guard-codex-exec.py"
check "the status line is wired"           "base_get \"d['statusLine']['command']\" | grep -q statusline-command.sh"
check "no permissions block"               "[ \"\$(base_get \"'permissions' in d\")\" = False ]"
check "no skipping of permission prompts"  "[ \"\$(base_get \"[k for k in d if k.lower().startswith('skip')]\")\" = '[]' ]"
for key in attribution model effortLevel modelSettings theme tui voice voiceEnabled spinnerVerbs enabledPlugins extraKnownMarketplaces deniedMcpServers env; do
  check "no personal choice: $key"         "[ \"\$(base_get \"'$key' in d\")\" = False ]"
done

echo "== --copy installs real files, not links =="
# A copy install is what a work machine or a container wants: the checkout is not
# staying, so a symlink into it would dangle the moment it goes. The assertion is
# that NO symlink survives anywhere under HOME -- checking one file would pass on a
# run that copied one thing and linked the rest.
HC="$(new_home)"; mkdir -p "$HC/repos"
run_setup "$HC" --copy
check "copy mode leaves no symlinks"   "[ \"\$(find '$HC' -type l | wc -l)\" -eq 0 ]"
check "copy mode still creates files"  "[ -f '$HC/.claude/CLAUDE.md' ] && [ -f '$HC/.tmux.conf' ]"
check "copy keeps the exec bit"        "[ -x '$HC/.claude/statusline-command.sh' ]"
check "copy content matches source"    "cmp -s '$DOTFILES/claude/CLAUDE.md' '$HC/.claude/CLAUDE.md'"

echo "== the two modes convert in both directions =="
# Both modes rm the destination first, so a machine can switch without being cleaned
# out by hand. Without the rm, ln -sf over a regular file fails and cp over a symlink
# writes THROUGH it into this repository -- which would edit the source.
run_setup "$HC"
check "copy -> link replaces files"    "[ -L '$HC/.claude/CLAUDE.md' ]"
run_setup "$HC" --copy
check "link -> copy replaces links"    "[ ! -L '$HC/.claude/CLAUDE.md' ] && [ -f '$HC/.claude/CLAUDE.md' ]"
check "source was never written through" "cmp -s '$DOTFILES/claude/CLAUDE.md' '$HC/.claude/CLAUDE.md'"

echo "== a checkout cloned straight into \$HOME still installs =="
# A CLAUDE.md at $HOME is read from every directory on the machine, not just the repos, so
# this is the placement that matters most, and the rest of the install must still work.
HH="$(new_home)"
cp -r "$DOTFILES" "$HH/dotfiles"
env -i PATH="$PATH" HOME="$HH" \
    CLAUDE_SKILLS_DIR="$HH/.claude/skills" bash "$HH/dotfiles/setup.sh" >/dev/null 2>&1
check "no CLAUDE.md at \$HOME"             "absent '$HH/CLAUDE.md'"
check "the rest still installed"           "resolves '$HH/.claude/CLAUDE.md'"
check "and it still exits 0"               "exits_with 0 env -i PATH=\"$PATH\" HOME=\"$HH\" CLAUDE_SKILLS_DIR=\"$HH/.claude/skills\" bash \"$HH/dotfiles/setup.sh\""

echo "== the whole work-machine path, in one go =="
# --copy AND repos in a folder of the installer's choosing, which is what a
# work machine actually is. Each is asserted on its own elsewhere; the combination is what
# someone will really run.
HW2="$(new_home)"; mkdir -p "$HW2/code"
cp -r "$DOTFILES" "$HW2/code/dotfiles"
env -i PATH="$PATH" HOME="$HW2" \
    CLAUDE_SKILLS_DIR="$HW2/.claude/skills" bash "$HW2/code/dotfiles/setup.sh" --copy >/dev/null 2>&1
check "no symlinks anywhere"           "[ \"\$(find '$HW2' -type l | wc -l)\" -eq 0 ]"
check "no workspace file beside the repos" "absent '$HW2/code/CLAUDE.md'"
check "nothing in \$HOME"              "absent '$HW2/CLAUDE.md'"
check "user file and hook present"     "[ -f '$HW2/.claude/CLAUDE.md' ] && [ -f '$HW2/.claude/hooks/guard-codex-exec.py' ]"
check "no skills installed"            "[ \"\$(ls -1 '$HW2/.claude/skills' 2>/dev/null | wc -l)\" -eq 0 ]"

echo "== an incomplete checkout fails in BOTH modes =="
# ln -sf points at a missing source without complaint, exits 0, and leaves a dangling
# link the report then lists as installed. cp fails. Without the source check the two
# modes would disagree about the same broken checkout, and the silent one is the default.
BR="$(new_home)"; mkdir -p "$BR/repos"
cp -r "$DOTFILES" "$BR/repos/dotfiles"
rm -f "$BR/repos/dotfiles/tmux/tmux.conf"
for m in "" "--copy"; do
  HB="$(new_home)"
  label="${m:---link}"
  check "$label refuses an incomplete checkout" \
        "exits_with 1 env -i PATH=\"$PATH\" HOME=\"$HB\" CLAUDE_SKILLS_DIR=\"$HB/.claude/skills\" bash \"$BR/repos/dotfiles/setup.sh\" $m"
  check "$label leaves no dangling link"        "absent '$HB/.tmux.conf'"
done

echo "== Codex: shared config keys =="
# The shipped file sets no key, so a machine keeps its own values. The merge itself is checked
# on a copy of the checkout whose file sets two.
H6="$(new_home)"; mkdir -p "$H6/.codex"
printf '%s\n' 'model = "old-model"' 'approvals_reviewer = "keep-me"' '' \
    '[projects."/somewhere"]' 'trust_level = "trusted"' > "$H6/.codex/config.toml"
CFG="$H6/.codex/config.toml"; SUM="$(cksum < "$CFG")"
run_setup "$H6"
check "the shipped keys leave the file as it was" "[ \"\$(cksum < '$CFG')\" = '$SUM' ]"
check "  and Codex's AGENTS.md is not created"   "absent '$H6/.codex/AGENTS.md'"
HNK="$(new_home)"; mkdir -p "$HNK/.codex"; NKOUT="$(setup_output "$HNK")"
check "with no shared keys, an absent config.toml stays absent" "absent '$HNK/.codex/config.toml'"
case "$NKOUT" in *'sets no shared Codex keys'*) ok "  and the report says no keys are configured" ;; *) bad "  and the report says no keys are configured" ;; esac
case "$NKOUT" in *'shared keys from'*) bad "  and doesn't claim keys were set" ;; *) ok "  and doesn't claim keys were set" ;; esac
printf 'model = "mine"' > "$HNK/.codex/config.toml"; NK0="$(cksum < "$HNK/.codex/config.toml")"; run_setup "$HNK"
check "  and one with no final newline is byte-identical" "[ \"\$(cksum < '$HNK/.codex/config.toml')\" = '$NK0' ]"
H6C="$(new_home)"; cp -R "$DOTFILES" "$H6C/dot"
printf '%s\n' 'model = "example-model"' 'model_reasoning_effort = "medium"' > "$H6C/dot/codex/config.toml"
cp_setup() { env -i PATH="$PATH" HOME="${CP_HOME:-$H6}" CLAUDE_SKILLS_DIR="$H6/.claude/skills" bash "$H6C/dot/setup.sh" "$@" 2>&1; }
KOUT="$(cp_setup)"
case "$KOUT" in *"config.toml: shared keys from $H6C/dot/codex/config.toml set"*) ok "with shared keys the report says they were set" ;; *) bad "with shared keys the report says they were set" ;; esac
check "a shared key replaces the machine's"    "grep -qx 'model = \"example-model\"' '$CFG'"
check "  and the old value is gone"             "! grep -q old-model '$CFG'"
check "a missing key is added"                  "grep -qx 'model_reasoning_effort = \"medium\"' '$CFG'"
check "  at the top level"                      "[ \"\$(grep -n '^model_reasoning_effort' '$CFG' | cut -d: -f1)\" -lt \"\$(grep -n '^\\[' '$CFG' | head -1 | cut -d: -f1)\" ]"
check "an unshared key is kept"                 "grep -qx 'approvals_reviewer = \"keep-me\"' '$CFG'"
check "trust entries are kept"                  "grep -qx '\\[projects.\"/somewhere\"\\]' '$CFG' && grep -qx 'trust_level = \"trusted\"' '$CFG'"
SUM="$(cksum < "$CFG")"; cp_setup >/dev/null
check "a second run changes nothing"            "[ \"\$(cksum < '$CFG')\" = '$SUM' ]"
run_setup "$H6"
check "a key taken out of the shared file keeps its value" "grep -qx 'model = \"example-model\"' '$CFG'"

echo "== Codex: an AGENTS.md is never touched =="
printf 'my own instructions\n' > "$H6/.codex/AGENTS.md"
run_setup "$H6"
check "kept as it was"                  "[ \"\$(cat '$H6/.codex/AGENTS.md')\" = 'my own instructions' ] && absent '$H6/.codex/AGENTS.md.pre-dotfiles'"
H7="$(new_home)"; mkdir -p "$H7/.codex"
CP_HOME="$H7" cp_setup --copy >/dev/null
check "a new config.toml is created, and private" "[ -f '$H7/.codex/config.toml' ] && [ -z \"\$(find '$H7/.codex' -name config.toml -perm -004)\" ]"

echo "== Codex: a machine without Codex gets no ~/.codex =="
H8="$(new_home)"
run_setup "$H8"
check "no ~/.codex created"             "absent '$H8/.codex'"
check "live HOME untouched"             "[ \"\$(cat $LIVE_SNAP)\" = \"\$(live_snapshot)\" ]"

echo "== the report doesn't call a generated file a link =="
HRP="$(new_home)"; ROUT="$(setup_output "$HRP")"
case "$ROUT" in *'Dotfiles installed:'*) ok "the heading covers both kinds" ;; *) bad "the heading covers both kinds" ;; esac
case "$ROUT" in *'symlinks created'*) bad "no heading calls them all links" ;; *) ok "no heading calls them all links" ;; esac
case "$ROUT" in *'settings.json: generated from'*) ok "settings.json is reported as generated" ;; *) bad "settings.json is reported as generated" ;; esac
case "$ROUT" in *'settings.json ->'*) bad "settings.json has no arrow" ;; *) ok "settings.json has no arrow" ;; esac

echo "== bad flags are rejected, not ignored =="
check "unknown flag exits 2"           "exits_with 2 bash '$DOTFILES/setup.sh' --nonsense"
check "--help exits 0"                 "bash '$DOTFILES/setup.sh' --help >/dev/null 2>&1"

echo "== --git-identity: the identity component, opt-in, links only =="
# The component installs only with the flag, only as links, and nothing else. Its
# preflight checks everything before the first write, so a refusal leaves no trace.
COMPONENT=".config/git/config .config/git/owners .config/git/identity-alice .config/git/identity-acme
.config/git/identity-bob .config/git/identity-carol .config/git/allowed_signers
.ssh/config.d/github.conf .local/bin/gh-as .local/bin/git-identity-audit .local/bin/git-identity-check"
src_of() {  # destination (relative to HOME) -> source, under this checkout or the data folder
  case "$1" in
    .config/git/owners)   echo "$FIXTURE/owners" ;;
    .config/git/*)        echo "$FIXTURE/git/${1#.config/git/}" ;;
    .ssh/config.d/*)      echo "$FIXTURE/ssh/${1#.ssh/config.d/}" ;;
    .local/bin/*)         echo "$DOTFILES/bin/${1#.local/bin/}" ;;
  esac
}
run_identity() {  # $1 = HOME, $2.. = extra flags; extra env goes in front of the call
  [ -n "$1" ] && [ "$1" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  local h="$1"; shift
  env -i PATH="$PATH" HOME="$h" ${IDENT_ENV:-} \
      bash "${IDENT_SETUP:-$DOTFILES/setup.sh}" --git-identity --identity-dir "${IDENT_DIR:-$FIXTURE}" "$@" 2>&1
}
# Files, links AND directories: a refusal that creates an empty directory has written.
tree_snap() { (cd "$1" && find . | sort; snap "$1"); }
none_of_component() {  # $1 = HOME
  local d; for d in $COMPONENT; do [ -e "$1/$d" ] || [ -L "$1/$d" ] && return 1; done; return 0
}

check "plain link run installs no component"  "none_of_component '$H'"
check "plain copy run installs no component"  "none_of_component '$H5'"

HI="$(new_home)"; mkdir -p "$HI/.codex"; printf 'model = "keep"\n' > "$HI/.codex/config.toml"
CODEX_BEFORE="$(cksum < "$HI/.codex/config.toml")"
OUT_I="$(run_identity "$HI")"; RC_I=$?
check "--git-identity exits 0"                "[ $RC_I -eq 0 ]"
for d in $COMPONENT; do
  check "links ~/$d to the checkout"          "[ \"\$(readlink '$HI/$d')\" = '$(src_of "$d")' ] && resolves '$HI/$d'"
done
check "no Claude files"                       "absent '$HI/.claude'"
check "no tmux file"                          "absent '$HI/.tmux.conf'"
check "no workspace file"                     "absent '$HI/repos/CLAUDE.md'"
check "Codex config untouched"                "[ \"\$(cksum < '$HI/.codex/config.toml')\" = '$CODEX_BEFORE' ] && absent '$HI/.codex/AGENTS.md'"
check "reports the missing Include line"      "printf '%s' \"\$OUT_I\" | grep -q 'Include config.d/github.conf'"
I1="$(snap "$HI")"; run_identity "$HI" >/dev/null; I2="$(snap "$HI")"
check "identity snapshot is not empty"        "case \"\$I1\" in *'github.conf -> /'*) true ;; *) false ;; esac"
check "two --git-identity runs are identical" "[ \"\$I1\" = \"\$I2\" ]"

HR="$(new_home)"; printf '[user]\n\temail = leak@example.com\n' > "$HR/.gitconfig"
printf 'Host github.com\n    IdentityFile ~/.ssh/id_old\n' > "$HR/.ssh_config_seed"; mkdir -p "$HR/.ssh"; mv "$HR/.ssh_config_seed" "$HR/.ssh/config"
OUT_R="$(run_identity "$HR")"
check "reports an identity left in ~/.gitconfig" "printf '%s' \"\$OUT_R\" | grep -q 'user.email'"
check "reports a GitHub Host block in ~/.ssh/config" "printf '%s' \"\$OUT_R\" | grep -qi 'Host github.com'"
check "never edits ~/.gitconfig"              "grep -q leak@example.com '$HR/.gitconfig'"

echo "== --git-identity refusals leave nothing behind =="
HX="$(new_home)"; X0="$(tree_snap "$HX")"
run_identity "$HX" --copy >/dev/null; RC=$?
check "--copy with --git-identity is refused" "[ $RC -ne 0 ]"
check "  and writes nothing"                  "[ \"\$(tree_snap '$HX')\" = \"\$X0\" ] && none_of_component '$HX'"

HL="$(new_home)"; mkdir -p "$HL/.local/bin"; printf '#!/bin/sh\necho mine\n' > "$HL/.local/bin/git-identity-check"
L0="$(tree_snap "$HL")"; run_identity "$HL" >/dev/null; RC=$?
check "a foreign file at the LAST destination is refused" "[ $RC -ne 0 ]"
check "  and nothing at all was written"      "[ \"\$(tree_snap '$HL')\" = \"\$L0\" ]"

HF="$(new_home)"; mkdir -p "$HF/.config/git"; printf '[core]\n\tpager = less\n' > "$HF/.config/git/config"
F0="$(cksum < "$HF/.config/git/config")"; run_identity "$HF" >/dev/null; RC=$?
check "an existing foreign ~/.config/git/config is refused" "[ $RC -ne 0 ]"
check "  and left byte-identical"             "[ \"\$(cksum < '$HF/.config/git/config')\" = '$F0' ] && [ ! -L '$HF/.config/git/config' ]"

HG="$(new_home)"; G0="$(tree_snap "$HG")"
IDENT_ENV="GIT_CONFIG_GLOBAL=$HG/other" run_identity "$HG" >/dev/null; RC=$?
check "GIT_CONFIG_GLOBAL is refused"          "[ $RC -ne 0 ] && [ \"\$(tree_snap '$HG')\" = \"\$G0\" ]"
IDENT_ENV="XDG_CONFIG_HOME=$HG/elsewhere" run_identity "$HG" >/dev/null; RC=$?
check "a non-default XDG_CONFIG_HOME is refused" "[ $RC -ne 0 ] && [ \"\$(tree_snap '$HG')\" = \"\$G0\" ]"

HB="$(new_home)"; mkdir -p "$HB/repos"; cp -R "$DOTFILES" "$HB/repos/dotfiles"; rm -f "$HB/repos/dotfiles/bin/gh-as"
HBH="$(new_home)"; B0="$(tree_snap "$HBH")"
IDENT_SETUP="$HB/repos/dotfiles/setup.sh" run_identity "$HBH" >/dev/null; RC=$?
check "an incomplete checkout fails in preflight" "[ $RC -ne 0 ]"
check "  and writes nothing"                  "[ \"\$(tree_snap '$HBH')\" = \"\$B0\" ]"

IDENT_ENV="GIT_CONFIG_GLOBAL=" run_identity "$HG" >/dev/null; RC=$?
check "an empty-but-set GIT_CONFIG_GLOBAL is refused" "[ $RC -ne 0 ] && [ \"\$(tree_snap '$HG')\" = \"\$G0\" ]"

# A parent that resolves INTO the checkout makes each source its own destination. The
# install would delete the tracked file, then link it to itself.
HS="$(new_home)"; mkdir -p "$HS/repos"; cp -R "$DOTFILES" "$HS/repos/dotfiles"
mkdir -p "$HS/.local"; ln -s "$HS/repos/dotfiles/bin" "$HS/.local/bin"
S0="$(cksum < "$HS/repos/dotfiles/bin/gh-as")"
IDENT_SETUP="$HS/repos/dotfiles/setup.sh" run_identity "$HS" >/dev/null; RC=$?
check "a destination that resolves into the checkout is refused" "[ $RC -ne 0 ]"
check "  and the tracked source is intact" "[ -f '$HS/repos/dotfiles/bin/gh-as' ] && [ ! -L '$HS/repos/dotfiles/bin/gh-as' ] && [ \"\$(cksum < '$HS/repos/dotfiles/bin/gh-as')\" = '$S0' ]"
# The same for the data folder, whose files are just as much the source.
HS2="$(new_home)"; cp -R "$FIXTURE" "$HS2/data"; mkdir -p "$HS2/.config"; ln -s "$HS2/data/git" "$HS2/.config/git"
S1="$(cksum < "$HS2/data/git/config")"
IDENT_DIR="$HS2/data" run_identity "$HS2" >/dev/null; RC=$?
check "a destination that resolves into the data folder is refused" "[ $RC -ne 0 ]"
check "  and the data is intact" "[ -f '$HS2/data/git/config' ] && [ ! -L '$HS2/data/git/config' ] && [ \"\$(cksum < '$HS2/data/git/config')\" = '$S1' ]"

HD2="$(new_home)"; mkdir -p "$HD2/.local"; ln -s "$HD2/nowhere" "$HD2/.local/bin"; D0="$(tree_snap "$HD2")"
run_identity "$HD2" >/dev/null; RC=$?
check "a dangling parent symlink is refused" "[ $RC -ne 0 ]"
check "  and nothing at all was written" "[ \"\$(tree_snap '$HD2')\" = \"\$D0\" ]"

echo "== --identity-dir: the component comes from the data folder =="
# Copied in, so each case can damage its own copy.
data_copy() { local d; d="$(mktemp -d)"; cp -R "$FIXTURE"/. "$d/"; printf '%s' "$d"; }
# The data can be anywhere, including where the default is.
HN2="$(new_home)"; mkdir -p "$HN2/.config/dotfiles"; cp -R "$FIXTURE" "$HN2/.config/dotfiles/identity"
OUT_N="$(env -i PATH="$PATH" HOME="$HN2" bash "$DOTFILES/setup.sh" --git-identity 2>&1)"; RC=$?
check "the default folder is ~/.config/dotfiles/identity" "[ $RC -eq 0 ] && [ \"\$(readlink '$HN2/.config/git/owners')\" = '$HN2/.config/dotfiles/identity/owners' ]"
HN3="$(new_home)"; N0="$(tree_snap "$HN3")"
OUT_N="$(env -i PATH="$PATH" HOME="$HN3" bash "$DOTFILES/setup.sh" --git-identity 2>&1)"; RC=$?
check "no data folder is refused"             "[ $RC -ne 0 ] && printf '%s' \"\$OUT_N\" | grep -q '$HN3/.config/dotfiles/identity'"
check "  and nothing at all was written"      "[ \"\$(tree_snap '$HN3')\" = \"\$N0\" ]"
# A relative path would make every link dangle from anywhere but where it was typed.
HN4="$(new_home)"; cp -R "$FIXTURE" "$HN4/my data"
(cd "$HN4" && IDENT_DIR="my data" run_identity "$HN4" >/dev/null); RC=$?
check "a relative folder, with a space, installs absolute links" "[ $RC -eq 0 ] && [ \"\$(readlink '$HN4/.config/git/owners')\" = '$(cd "$HN4" && pwd -P)/my data/owners' ] && resolves '$HN4/.ssh/config.d/github.conf'"
# A folder's identity files are the ones its owners file lists: another set must install.
DA="$(data_copy)"
printf 'owner dave github-dave identity-dave\nalias github-dave dave\n' >> "$DA/owners"
cp "$DA/git/identity-bob" "$DA/git/identity-dave"
HN5="$(new_home)"; IDENT_DIR="$DA" run_identity "$HN5" >/dev/null; RC=$?
check "installs what the owners file lists"   "[ $RC -eq 0 ] && resolves '$HN5/.config/git/identity-dave'"
# Two owners may share one identity file, and it installs once.
DS="$(data_copy)"; printf 'owner beta github-alice identity-alice\n' >> "$DS/owners"
HN6="$(new_home)"; OUT_N="$(IDENT_DIR="$DS" run_identity "$HN6")"; RC=$?
check "an identity file two owners share installs once" "[ $RC -eq 0 ] && [ \"\$(printf '%s\n' \"\$OUT_N\" | grep -c 'git/identity-alice ->')\" -eq 1 ]"
# The SSH report checks the aliases this folder declares, not a list of its own.
DK="$(data_copy)"; printf 'alias github-dave dave\n' >> "$DK/owners"
HN7="$(new_home)"; mkdir -p "$HN7/.ssh"; printf 'Host github-dave\n    IdentityFile ~/.ssh/id_other\n' > "$HN7/.ssh/config"
OUT_P="$(IDENT_DIR="$DK" run_identity "$HN7")"
check "the report covers an alias from the owners file" "printf '%s' \"\$OUT_P\" | grep -q 'reaches github-dave'"
HN8="$(new_home)"; mkdir -p "$HN8/.ssh"; printf 'Host github-dave\n    IdentityFile ~/.ssh/id_other\n' > "$HN8/.ssh/config"
OUT_P="$(run_identity "$HN8")"
check "  and not one the folder doesn't declare" "! printf '%s' \"\$OUT_P\" | grep -q 'adds an IdentityFile'"

echo "== --identity-dir refusals come before any write =="
# Each damages a copy of the data, and the destinations start empty: a parse that only
# failed after the first link would leave a machine half-routed.
refused_data() {  # $1 = label, $2 = text the refusal must contain; uses $DD
  local h h0 out rc; h="$(new_home)"; h0="$(tree_snap "$h")"
  out="$(IDENT_DIR="$DD" run_identity "$h")"; rc=$?
  check "$1 is refused"                       "[ $rc -ne 0 ]"
  case "$out" in *"$2"*) ok "  and says so" ;; *) bad "  and says so"; printf '         missing: %s\n         got: %s\n' "$2" "$out" ;; esac
  check "  and nothing at all was written"    "[ \"\$(tree_snap '$h')\" = \"\$(printf '%s' '$h0')\" ]"
}
DD="$(data_copy)"; rm "$DD/owners";                    refused_data "a folder with no owners file" "owners"
DD="$(data_copy)"; printf '# nothing yet\n' > "$DD/owners"; refused_data "a comment-only owners file" "no owners"
DD="$(data_copy)"; printf 'owner one two\n' >> "$DD/owners"; refused_data "a short owner line" "owner one two"
DD="$(data_copy)"; printf 'owner x github-alice ../identity-alice\n' >> "$DD/owners"; refused_data "an identity file outside the folder" "../identity-alice"
DD="$(data_copy)"; printf 'alias github-x\n' >> "$DD/owners"; refused_data "a short alias line" "alias github-x"
DD="$(data_copy)"; printf 'nonsense\n' >> "$DD/owners"; refused_data "an unknown keyword" "nonsense"
DD="$(data_copy)"; printf 'owner alice github-alice identity-alice\n' >> "$DD/owners"; refused_data "a repeated owner" "owner alice"
DD="$(data_copy)"; printf 'alias github-bob bob\n' >> "$DD/owners"; refused_data "a repeated alias" "alias github-bob"
DD="$(data_copy)"; printf 'owner x github-nobody identity-alice\n' >> "$DD/owners"; refused_data "an owner using an undeclared alias" "github-nobody"
DD="$(data_copy)"; grep -v '^alias github.com' "$DD/owners" > "$DD/o"; mv "$DD/o" "$DD/owners"; refused_data "no alias for plain github.com" "github.com"
DD="$(data_copy)"; rm "$DD/git/identity-bob";          refused_data "a listed identity file that is missing" "identity-bob"
DD="$(data_copy)"; rm "$DD/git/config";                refused_data "a folder with no git/config" "git/config"
DD="$(data_copy)"; rm "$DD/git/allowed_signers";       refused_data "a folder with no signer list" "allowed_signers"
DD="$(data_copy)"; rm "$DD/ssh/github.conf";           refused_data "a folder with no SSH aliases" "github.conf"

check "--identity-dir with no value exits 2"  "exits_with 2 bash '$DOTFILES/setup.sh' --git-identity --identity-dir"
check "an empty --identity-dir exits 2"       "exits_with 2 bash '$DOTFILES/setup.sh' --git-identity --identity-dir ''"
HN9="$(new_home)"; N9="$(tree_snap "$HN9")"
env -i PATH="$PATH" HOME="$HN9" bash "$DOTFILES/setup.sh" --identity-dir "$FIXTURE" >/dev/null 2>&1; RC=$?
check "--identity-dir without --git-identity exits 2" "[ $RC -eq 2 ]"
check "  and writes nothing"                  "[ \"\$(tree_snap '$HN9')\" = \"\$N9\" ]"

DD="$(data_copy)"; printf 'alias github-dave alice\n' >> "$DD/owners"; refused_data "an alias naming another account" "alias github-dave alice"

echo "== a source that reaches a destination is refused before any write =="
# A data file linked to the file it would be installed over looks identical through
# `cmp`, so it passes as this repo's. install_file would then delete the real file and
# leave a link pointing at itself.
reaches_refused() {  # $1 = label, $2 = HOME, $3 = source tree, $4 = the real file at risk
  local saved h0 s0 out rc; saved="$(mktemp)"; cp -p "$4" "$saved"
  h0="$(tree_snap "$2")"; s0="$(tree_snap "$3")"
  out="$(IDENT_DIR="${REACH_DATA:-$3}" run_identity "$2")"; rc=$?
  check "$1 is refused"                       "[ $rc -ne 0 ]"
  case "$out" in *"nothing was written"*"reaches"*) ok "  and says so" ;; *) bad "  and says so"; printf '         got: %s\n' "$out" ;; esac
  if [ ! -L "$4" ] && cmp -s "$saved" "$4"; then ok "  and the real file is byte-identical"; else bad "  and the real file is byte-identical"; fi
  if [ "$(tree_snap "$2")" = "$h0" ]; then ok "  and nothing was written in HOME"; else bad "  and nothing was written in HOME"; fi
  if [ "$(tree_snap "$3")" = "$s0" ]; then ok "  and the source tree is unchanged"; else bad "  and the source tree is unchanged"; fi
  rm -f "$saved"
}
# A throwaway HOME already holding the real owners file, and a data copy to link from.
reach_setup() {
  RH="$(new_home)"; RD="$(data_copy)"; mkdir -p "$RH/.config/git"
  cp "$FIXTURE/owners" "$RH/.config/git/owners"; rm "$RD/owners"
}
reach_setup; ln -s "$RH/.config/git/owners" "$RD/owners"
reaches_refused "a source linked straight to its destination" "$RH" "$RD" "$RH/.config/git/owners"
reach_setup; ln -s .config/git/owners "$RH/hop"; ln -s "$RH/hop" "$RD/owners"
reaches_refused "a source reaching it through a chain with a relative link" "$RH" "$RD" "$RH/.config/git/owners"
reach_setup; ln -s .config/git "$RH/dirlink"; ln -s "$RH/dirlink/owners" "$RD/owners"
reaches_refused "a source reaching it through a linked folder" "$RH" "$RD" "$RH/.config/git/owners"
# `..` after a linked folder climbs from where the link points, not from where it sits.
reach_setup; mkdir -p "$RH/.config/git/sub"; ln -s .config/git/sub "$RH/bridge"; ln -s "$RH/bridge/../owners" "$RD/owners"
reaches_refused "a source reaching it through .. after a linked folder" "$RH" "$RD" "$RH/.config/git/owners"
# Here the source itself is not a link: a folder above it is.
RH="$(new_home)"; RD="$(data_copy)"; mkdir -p "$RH/.config"
mv "$RD/git" "$RH/.config/git"; ln -s "$RH/.config/git" "$RD/git"
reaches_refused "a data folder whose git/ is the destination folder" "$RH" "$RD" "$RH/.config/git/config"
# Another file's destination is just as much at risk once that file installs.
RH="$(new_home)"; RD="$(data_copy)"; mkdir -p "$RH/.config/git"
cp "$RD/git/identity-bob" "$RH/.config/git/identity-bob"
rm "$RD/git/identity-acme"; ln -s "$RH/.config/git/identity-bob" "$RD/git/identity-acme"
reaches_refused "a source reaching another file's destination" "$RH" "$RD" "$RH/.config/git/identity-bob"
# The checkout's sources get the same check as the data folder's.
RH="$(new_home)"; RC_DIR="$(new_home)/dotfiles"; cp -R "$DOTFILES" "$RC_DIR"; mkdir -p "$RH/.local/bin"
mv "$RC_DIR/bin/gh-as" "$RH/.local/bin/gh-as"; ln -s "$RH/.local/bin/gh-as" "$RC_DIR/bin/gh-as"
REACH_DATA="$FIXTURE" IDENT_SETUP="$RC_DIR/setup.sh" reaches_refused "a checkout file linked to its destination" "$RH" "$RC_DIR" "$RH/.local/bin/gh-as"
# A source may still be a link to a file somewhere else, on the first run and on a re-run.
reach_setup; mkdir -p "$RH/private"; cp "$FIXTURE/owners" "$RH/private/owners"; ln -s "$RH/private/owners" "$RD/owners"; rm "$RH/.config/git/owners"
IDENT_DIR="$RD" run_identity "$RH" >/dev/null; RC=$?
check "a source linked elsewhere still installs" "[ $RC -eq 0 ] && [ \"\$(readlink '$RH/.config/git/owners')\" = '$RD/owners' ] && cmp -s '$FIXTURE/owners' '$RH/.config/git/owners'"
IDENT_DIR="$RD" run_identity "$RH" >/dev/null; RC=$?
check "  and re-installs, keeping its real file" "[ $RC -eq 0 ] && [ -f '$RH/private/owners' ] && [ ! -L '$RH/private/owners' ] && cmp -s '$FIXTURE/owners' '$RH/.config/git/owners'"

echo "== --git-identity reports: the Include line, parsed like ssh does =="
report_for() {  # $1 = ~/.ssh/config content; leaves the output in $OUT_P
  local h; h="$(new_home)"; mkdir -p "$h/.ssh"; printf '%b' "$1" > "$h/.ssh/config"
  OUT_P="$(run_identity "$h")"
}
asks_include()     { case "$OUT_P" in *"Missing: in ~/.ssh/config"*) return 0 ;; esac; return 1; }
report_for 'Include config.d/github.conf\nHost x\n';           check "plain Include accepted"            "! asks_include"
report_for 'Include="config.d/github.conf"\nHost x\n';         check "quoted Include= accepted"          "! asks_include"
report_for 'Include config.d/github.conf.bak\n';               check "a .bak name is not the Include"    "asks_include"
report_for 'Include other.conf # config.d/github.conf\n';      check "a trailing comment is not the Include" "asks_include"
report_for 'Host=x\nInclude config.d/github.conf\n';           check "an Include after Host=x is reported" "asks_include"
report_for 'Include other/config.d/github.conf\n';            check "another folder's github.conf is not the Include" "asks_include"
report_for 'Host github-include\n';                            check "a Host named github-include is not the Include" "asks_include"
report_for 'Include ~/.ssh/config.d/github.conf\n';            check "the ~/.ssh/ spelling is accepted"   "! asks_include"
warns_keys() { case "$OUT_P" in *"adds an IdentityFile"*) return 0 ;; esac; return 1; }
report_for 'IdentityFile ~/.ssh/id_global\nInclude config.d/github.conf\n'
check "a global IdentityFile is reported"        "warns_keys"
report_for 'Include config.d/github.conf\nHost *.com\n    IdentityFile ~/.ssh/id_com\n'
check "Host *.com with an IdentityFile is reported" "warns_keys"
report_for 'Include config.d/github.conf\nHost * !github*\n    IdentityFile ~/.ssh/id_other\n'
check "Host * !github* is NOT reported"          "! warns_keys"
check "  nor called a GitHub Host block"          "! printf '%s' \"\$OUT_P\" | grep -q 'GitHub Host block'"
report_for 'Include config.d/github.conf\nHost example.com\n    IdentityFile ~/.ssh/id_example\n'
check "an unrelated host's IdentityFile is NOT reported" "! warns_keys"
HM="$(new_home)"; mkdir -p "$HM/.local/bin"; chmod 600 "$HM/.local/bin"; M0="$(cd "$HM" && find . -path ./.local/bin -prune -o -print | sort)"
run_identity "$HM" >/dev/null; RC=$?
check "a parent that can't be searched is refused" "[ $RC -ne 0 ]"
check "  and nothing was written" "[ \"\$(cd '$HM' && find . -path ./.local/bin -prune -o -print | sort)\" = \"\$M0\" ]"
chmod 755 "$HM/.local/bin"
report_for 'Host=github.com\n    IdentityFile ~/.ssh/id_old\n'
check "Host=github.com is reported"     "printf '%s' \"\$OUT_P\" | grep -q 'GitHub Host block'"
report_for 'Host *\n    IdentityFile ~/.ssh/id_any\n'
check "a Host * IdentityFile is reported" "warns_keys"
HP="$(new_home)"; printf '[url "git@github.com:"]\n\tpushInsteadOf = https://github.com/\n' > "$HP/.gitconfig"
OUT_P="$(run_identity "$HP")"
check "a leftover pushInsteadOf is reported" "printf '%s' \"\$OUT_P\" | grep -qi 'pushinsteadof'"

# Shared by the settings, starter and link cases below. Leaves the output in $OUT and the
# exit status in $RC, because each assertion needs both.
plain() {  # $1 = HOME, $2.. = flags; IDENT_SETUP names another checkout's setup.sh
  [ -n "$1" ] && [ "$1" != "$HOME" ] || { echo "REFUSING: test HOME is unset or live" >&2; exit 2; }
  local h="$1"; shift
  OUT="$(env -i PATH="$PATH" HOME="$h" \
      CLAUDE_SKILLS_DIR="$h/.claude/skills" bash "${IDENT_SETUP:-$DOTFILES/setup.sh}" "$@" 2>&1)"; RC=$?
}
out_has()   { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
# Plain JSON equality, written here rather than borrowed from merge_settings.py, so a bug
# there can't excuse itself.
json_eq() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' "$1" "$2"; }
json_get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$1" "$2"; }
real_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
BASE="$DOTFILES/claude/settings.json"
OVERLAY_AT=".config/dotfiles/settings-overlay.json"
set_overlay() { mkdir -p "$1/.config/dotfiles"; printf '%s\n' "$2" > "$1/$OVERLAY_AT"; }
# A live edit, the way Claude Code makes one: a whole new valid file, keys reordered.
# Refuses a link: a run that left one in place must not edit the checkout's base through it.
live_edit() { [ ! -L "$1/.claude/settings.json" ] || { bad "live_edit: settings.json is still a link"; return 1; }; python3 -c '
import json,sys
p=sys.argv[1]+"/.claude/settings.json"; d=json.load(open(p)); d[sys.argv[2]]=sys.argv[3]
d=dict(sorted(d.items(),reverse=True)); open(p,"w").write(json.dumps(d,indent=4))' "$1" "$2" "$3"; }

echo "== settings: the first run replaces the symlink, without calling it drift =="
BASE0="$(cksum < "$BASE")"
S1="$(new_home)"; mkdir -p "$S1/.claude"; ln -s "$BASE" "$S1/.claude/settings.json"
plain "$S1"
check "replaces an existing symlink, exit 0" "[ $RC -eq 0 ]"
check "  with a real file"                   "real_file '$S1/.claude/settings.json'"
check "  holding the base, with no overlay"  "json_eq '$S1/.claude/settings.json' '$BASE'"
check "  and the result is recorded beside it" "real_file '$S1/.claude/settings.json.generated' && json_eq '$S1/.claude/settings.json.generated' '$BASE'"
check "  and the base was not written through" "[ \"\$(cksum < '$BASE')\" = '$BASE0' ]"
check "a fresh machine gets a real file too" "S0=\"\$(new_home)\"; plain \"\$S0\"; [ \$RC -eq 0 ] && real_file \"\$S0/.claude/settings.json\""
S1B="$(cksum < "$S1/.claude/settings.json")"; plain "$S1"
check "a second run changes nothing"         "[ $RC -eq 0 ] && [ \"\$(cksum < '$S1/.claude/settings.json')\" = '$S1B' ]"

echo "== settings: the overlay is layered on the base =="
S2="$(new_home)"; set_overlay "$S2" '{"model":"overlay-model","statusLine":{"extra":"1"}}'
plain "$S2"
check "an overlay value wins"                "[ \"\$(json_get '$S2/.claude/settings.json' model)\" = overlay-model ]"
check "  and objects merge"                  "python3 -c \"import json;d=json.load(open('$S2/.claude/settings.json'));b=json.load(open('$BASE'));assert d['statusLine']['extra']=='1' and b['statusLine'] and all(d['statusLine'][k]==v for k,v in b['statusLine'].items())\""
S2M="$(new_home)"; plain "$S2M" --no-starters; S2E="$(new_home)"; set_overlay "$S2E" '{}'; plain "$S2E" --no-starters
check "missing and empty overlays give the same bytes" "cmp -s '$S2M/.claude/settings.json' '$S2E/.claude/settings.json'"
S2C="$(new_home)"; printf '{"model":"named"}' > "$S2C/mine.json"; plain "$S2C" --settings-overlay "$S2C/mine.json"
check "--settings-overlay names another file" "[ \"\$(json_get '$S2C/.claude/settings.json' model)\" = named ]"
check "  and no starter overlay appears"      "absent '$S2C/$OVERLAY_AT'"
S2X="$(new_home)"; X0="$(tree_snap "$S2X")"; plain "$S2X" --settings-overlay "$S2X/typo.json"
check "a named overlay that is missing is refused" "[ $RC -eq 2 ] && out_has '$S2X/typo.json'"
check "  and nothing was written"             "[ \"\$(tree_snap '$S2X')\" = \"\$X0\" ]"
S2B="$(new_home)"; set_overlay "$S2B" '{broken'; X0="$(tree_snap "$S2B")"; plain "$S2B"
check "a broken overlay stops the run"        "[ $RC -ne 0 ] && out_has 'settings-overlay.json'"
check "  and nothing was written"             "[ \"\$(tree_snap '$S2B')\" = \"\$X0\" ]"
# The overlay is an input, so it must never be the file that setup writes.
for out in settings.json settings.json.generated; do
  S2O="$(new_home)"; mkdir -p "$S2O/.claude"; printf '{"model":"mine"}' > "$S2O/.claude/$out"; O0="$(tree_snap "$S2O")"
  plain "$S2O" --settings-overlay "$S2O/.claude/$out"
  check "an overlay that is $out is refused" "[ $RC -eq 2 ] && [ \"\$(tree_snap '$S2O')\" = \"\$O0\" ]"
done
S2L="$(new_home)"; mkdir -p "$S2L/.claude"; printf '{"model":"mine"}' > "$S2L/.claude/settings.json.generated"; ln -s "$S2L/.claude/settings.json.generated" "$S2L/link.json"
plain "$S2L" --settings-overlay "$S2L/link.json"
check "an overlay linked to the record is refused" "[ $RC -eq 2 ] && [ \"\$(cat '$S2L/.claude/settings.json.generated')\" = '{\"model\":\"mine\"}' ]"
check "--settings-overlay with no value exits 2" "exits_with 2 bash '$DOTFILES/setup.sh' --settings-overlay"
check "--settings-overlay with --git-identity exits 2" "exits_with 2 bash '$DOTFILES/setup.sh' --git-identity --settings-overlay /x"
check "--force-settings with --git-identity exits 2"   "exits_with 2 bash '$DOTFILES/setup.sh' --git-identity --force-settings"

echo "== settings: a layer change with no live edit applies without force =="
S3="$(new_home)"; set_overlay "$S3" '{"model":"one"}'; plain "$S3"
set_overlay "$S3" '{"model":"two"}'; plain "$S3"
check "an overlay change applies"            "[ $RC -eq 0 ] && [ \"\$(json_get '$S3/.claude/settings.json' model)\" = two ]"
check "  and the record follows"             "json_eq '$S3/.claude/settings.json' '$S3/.claude/settings.json.generated'"
S3C="$(new_home)"; cp -R "$DOTFILES" "$S3C/dot"; IDENT_SETUP="$S3C/dot/setup.sh" plain "$S3C"
python3 -c "import json;p='$S3C/dot/claude/settings.json';d=json.load(open(p));d['fromBase']=True;json.dump(d,open(p,'w'))"
IDENT_SETUP="$S3C/dot/setup.sh" plain "$S3C"
check "a base change applies"                "[ $RC -eq 0 ] && [ \"\$(json_get '$S3C/.claude/settings.json' fromBase)\" = True ]"

echo "== settings: a reordering alone is not a change =="
S4="$(new_home)"; plain "$S4"
[ ! -L "$S4/.claude/settings.json" ] && python3 -c "import json;p='$S4/.claude/settings.json';d=json.load(open(p));open(p,'w').write(json.dumps(dict(sorted(d.items(),reverse=True))))"
S4B="$(cksum < "$S4/.claude/settings.json")"; plain "$S4"
check "a reordered file does not stop the run" "[ $RC -eq 0 ]"
check "  and is left as it is"               "[ \"\$(cksum < '$S4/.claude/settings.json')\" = '$S4B' ]"

echo "== settings: a live edit stops the run before anything is written =="
S5="$(new_home)"; set_overlay "$S5" '{"model":"one"}'; plain "$S5"; live_edit "$S5" liveKey liveValue
rm -f "$S5/.tmux.conf" "$S5/.config/tmux/local.conf"
S5B="$(cksum < "$S5/.claude/settings.json")"; S5R="$(cksum < "$S5/.claude/settings.json.generated")"
plain "$S5"
check "a live edit with no layer change stops" "[ $RC -eq 1 ]"
check "  and shows the difference"           "out_has liveKey && out_has liveValue"
check "  and says how to go on"              "out_has --force-settings && out_has settings-overlay.json"
check "  leaving the file untouched"         "[ \"\$(cksum < '$S5/.claude/settings.json')\" = '$S5B' ] && [ \"\$(cksum < '$S5/.claude/settings.json.generated')\" = '$S5R' ]"
check "  and writing nothing else"           "absent '$S5/.tmux.conf' && absent '$S5/.config/tmux/local.conf'"
set_overlay "$S5" '{"model":"two"}'; plain "$S5"
check "a live edit AND a layer change stop"  "[ $RC -eq 1 ] && [ \"\$(cksum < '$S5/.claude/settings.json')\" = '$S5B' ] && [ \"\$(json_get '$S5/.claude/settings.json' model)\" = one ]"
plain "$S5" --force-settings
check "--force-settings overrides"           "[ $RC -eq 0 ] && [ \"\$(json_get '$S5/.claude/settings.json' model)\" = two ] && [ \"\$(json_get '$S5/.claude/settings.json' liveKey)\" = None ]"
check "  showing what it discarded"          "out_has liveKey"
check "  and the record follows"             "json_eq '$S5/.claude/settings.json' '$S5/.claude/settings.json.generated'"
plain "$S5"
check "  and the next run has no drift"      "[ $RC -eq 0 ]"

echo "== settings: moving the change to the overlay clears the stop =="
S6="$(new_home)"; set_overlay "$S6" '{}'; plain "$S6"; live_edit "$S6" movedKey movedValue
plain "$S6"; check "stops before the move" "[ $RC -eq 1 ]"
set_overlay "$S6" '{"movedKey":"movedValue"}'; plain "$S6"
check "applies after the move, with no force" "[ $RC -eq 0 ] && [ \"\$(json_get '$S6/.claude/settings.json' movedKey)\" = movedValue ]"
check "  and the record follows"             "json_eq '$S6/.claude/settings.json' '$S6/.claude/settings.json.generated'"
plain "$S6"; check "  and stays clean"       "[ $RC -eq 0 ]"

echo "== settings: files with no record, and files that can't be read =="
S7="$(new_home)"; mkdir -p "$S7/.claude"; printf '{"mine":1}\n' > "$S7/.claude/settings.json"; plain "$S7"
check "someone's own file, no record, stops"  "[ $RC -eq 1 ] && [ \"\$(cat '$S7/.claude/settings.json')\" = '{\"mine\":1}' ] && absent '$S7/.claude/settings.json.generated'"
S7C="$(new_home)"; mkdir -p "$S7C/.claude"; cp "$BASE" "$S7C/.claude/settings.json"; set_overlay "$S7C" '{"model":"m"}'; plain "$S7C"
check "a copy of the base, no record, is replaced" "[ $RC -eq 0 ] && [ \"\$(json_get '$S7C/.claude/settings.json' model)\" = m ]"
S7J="$(new_home)"; plain "$S7J"; printf '{broken' > "$S7J/.claude/settings.json"; plain "$S7J"
check "a live file that isn't JSON stops"     "[ $RC -eq 1 ] && [ \"\$(cat '$S7J/.claude/settings.json')\" = '{broken' ]"
plain "$S7J" --force-settings
check "  and --force-settings replaces it"    "[ $RC -eq 0 ] && json_eq '$S7J/.claude/settings.json' '$BASE'"
S7D="$(new_home)"; plain "$S7D"; rm "$S7D/.claude/settings.json"; plain "$S7D"
check "a deleted live file is generated again" "[ $RC -eq 0 ] && json_eq '$S7D/.claude/settings.json' '$BASE'"
S7F="$(new_home)"; mkdir -p "$S7F/.claude/settings.json"; plain "$S7F" --force-settings
check "a folder in its place stops, even forced" "[ $RC -ne 0 ] && [ -d '$S7F/.claude/settings.json' ]"

echo "== settings: a link to anything else is refused =="
S8="$(new_home)"; mkdir -p "$S8/.claude"; printf '{"theirs":1}\n' > "$S8/theirs.json"; ln -s "$S8/theirs.json" "$S8/.claude/settings.json"; plain "$S8"
check "a link elsewhere stops"                "[ $RC -eq 1 ] && [ \"\$(readlink '$S8/.claude/settings.json')\" = '$S8/theirs.json' ]"
S8S="$(new_home)"; mkdir -p "$S8S/.claude"; ln -s "$S8S/gone/claude/settings.json" "$S8S/.claude/settings.json"; plain "$S8S"
check "a dangling link elsewhere stops"       "[ $RC -eq 1 ] && [ -L '$S8S/.claude/settings.json' ]"
plain "$S8" --force-settings
check "  --force-settings replaces the link"  "[ $RC -eq 0 ] && real_file '$S8/.claude/settings.json'"
check "  and never writes through it"         "[ \"\$(cat '$S8/theirs.json')\" = '{\"theirs\":1}' ]"

echo "== settings: --copy =="
# Generated the same way in both modes: a link is not an option for either, and a generated
# file never needed the checkout after the run, which is what --copy is for.
S9="$(new_home)"; set_overlay "$S9" '{"model":"m"}'; plain "$S9" --copy
check "--copy generates the same real file"   "[ $RC -eq 0 ] && real_file '$S9/.claude/settings.json' && [ \"\$(json_get '$S9/.claude/settings.json' model)\" = m ]"
check "  and records it"                      "real_file '$S9/.claude/settings.json.generated'"
live_edit "$S9" copyKey v; plain "$S9" --copy
check "  and stops on a live edit"            "[ $RC -eq 1 ] && [ \"\$(json_get '$S9/.claude/settings.json' copyKey)\" = v ]"
plain "$S9" --copy --force-settings
check "  and --force-settings overrides"      "[ $RC -eq 0 ] && [ \"\$(json_get '$S9/.claude/settings.json' copyKey)\" = None ]"
plain "$S9"
check "switching modes is not drift"          "[ $RC -eq 0 ] && real_file '$S9/.claude/settings.json' && [ -L '$S9/.claude/CLAUDE.md' ]"
S9L="$(new_home)"; mkdir -p "$S9L/.claude"; ln -s "$BASE" "$S9L/.claude/settings.json"; plain "$S9L" --copy
check "--copy over an existing symlink replaces it" "[ $RC -eq 0 ] && real_file '$S9L/.claude/settings.json'"

echo "== settings: with no python3 the file is left alone and the report says so =="
NP="$(mktemp -d)"
for t in bash env dirname basename rm ln cp mkdir cmp readlink mktemp mv chmod cat; do ln -s "$(command -v "$t")" "$NP/$t"; done
S10="$(new_home)"; mkdir -p "$S10/.claude"; ln -s "$BASE" "$S10/.claude/settings.json"
OUT="$(env -i PATH="$NP" HOME="$S10" CLAUDE_SKILLS_DIR="$S10/.claude/skills" "$NP/bash" "$DOTFILES/setup.sh" 2>&1)"; RC=$?
check "the install still finishes"            "[ $RC -eq 0 ] && [ -L '$S10/.claude/CLAUDE.md' ]"
check "  the link stays as it was"            "[ \"\$(readlink '$S10/.claude/settings.json')\" = '$BASE' ]"
check "  and the report says why"             "out_has 'settings.json not generated'"
rm -rf "$NP"

echo "== starters: created when absent, named, never overwritten =="
IDENTITY_STARTERS=".config/dotfiles/identity/owners .config/dotfiles/identity/git/config
.config/dotfiles/identity/git/identity-alice .config/dotfiles/identity/git/allowed_signers
.config/dotfiles/identity/ssh/github.conf"
COMMENTED_STARTERS="$IDENTITY_STARTERS .config/git/accounts .config/git/repo-roots .config/tmux/local.conf
.config/dotfiles/settings-overlay.README"
ALL_STARTERS="$COMMENTED_STARTERS $OVERLAY_AT"
starters_snap() { local f; for f in $ALL_STARTERS; do printf '%s %s\n' "$f" "$(cksum < "$1/$f" 2>/dev/null || echo absent)"; done; }
T1="$(new_home)"; plain "$T1"; T1OUT="$OUT"
for f in $ALL_STARTERS; do
  check "creates ~/$f"                        "real_file '$T1/$f'"
  check "  and names it"                      "case \"\$T1OUT\" in *'~/$f'*) true ;; *) false ;; esac"
done
for f in $COMMENTED_STARTERS; do
  # Nothing but comments and blank lines, so an unedited file can do nothing.
  check "~/$f is only comments"               "[ -z \"\$(grep -v '^#' '$T1/$f' | grep -v '^[[:space:]]*\$')\" ]"
  check "  and says how to fill it in and check it" "grep -q '^# To fill in:' '$T1/$f' && grep -q '^# To check:' '$T1/$f'"
done
check "the starter overlay is an empty object" "[ \"\$(python3 -c \"import json;print(json.load(open('$T1/$OVERLAY_AT')))\")\" = '{}' ]"
check "the starters name no date"             "! grep -rEq '(19|20)[0-9]{2}-[0-9]{2}' '$DOTFILES/starters'"
T1S="$(starters_snap "$T1")"; plain "$T1"
check "a re-run leaves them byte-identical"   "[ \"\$(starters_snap '$T1')\" = \"\$T1S\" ]"
check "  and names none as created"           "! out_has 'identity/owners'"
for f in $ALL_STARTERS; do printf '# edited by the installer\n' >> "$T1/$f"; done
printf '{"edited":true}\n' > "$T1/$OVERLAY_AT"
T1S="$(starters_snap "$T1")"; plain "$T1"
check "edited ones survive a re-run too"      "[ \"\$(starters_snap '$T1')\" = \"\$T1S\" ]"
plain "$T1" --copy
check "  and a --copy run"                    "[ \"\$(starters_snap '$T1')\" = \"\$T1S\" ]"
plain "$T1" --force-settings
check "  and a forced run"                    "[ \"\$(starters_snap '$T1')\" = \"\$T1S\" ]"
T2="$(new_home)"; mkdir -p "$T2/.config/git" "$T2/.config/tmux"
printf 'alice\n' > "$T2/.config/git/accounts"; ln -s "$T2/gone" "$T2/.config/tmux/local.conf"; plain "$T2"
check "a file already there is kept"          "[ \"\$(cat '$T2/.config/git/accounts')\" = alice ]"
check "  and not called created"              "! out_has '~/.config/git/accounts'"
check "a dangling link already there is kept" "[ \"\$(readlink '$T2/.config/tmux/local.conf')\" = '$T2/gone' ]"
T3="$(new_home)"; plain "$T3" --no-starters
check "--no-starters creates none"            "absent '$T3/.config/dotfiles' && absent '$T3/.config/git' && absent '$T3/.config/tmux'"
check "  and the install still finishes"      "[ $RC -eq 0 ] && real_file '$T3/.claude/settings.json'"
T3C="$(new_home)"; plain "$T3C" --copy
check "--copy creates them as real files too" "real_file '$T3C/.config/dotfiles/identity/owners' && [ \"\$(find '$T3C' -type l | wc -l)\" -eq 0 ]"
T3I="$(new_home)"; IDENT_DIR="$FIXTURE" run_identity "$T3I" --no-starters >/dev/null; RC=$?
check "--no-starters is accepted with --git-identity" "[ $RC -eq 0 ] && absent '$T3I/.config/dotfiles'"
T3N="$(new_home)"; IDENT_DIR="$FIXTURE" run_identity "$T3N" >/dev/null
check "--git-identity creates no starters"    "absent '$T3N/.config/dotfiles' && absent '$T3N/.config/git/accounts' && absent '$T3N/.config/tmux'"
T3B="$(new_home)"; printf 'x' > "$T3B/.config"; plain "$T3B"
check "a starter that can't be created is reported, not fatal" "[ $RC -eq 0 ] && out_has 'could not be created' && real_file '$T3B/.claude/settings.json'"

echo "== starters: left unedited they change nothing =="
T4="$(new_home)"; plain "$T4"
check "settings are the base's"               "json_eq '$T4/.claude/settings.json' '$BASE'"
check "no routing was installed"              "none_of_component '$T4'"
OUT="$(env -i PATH="$PATH" HOME="$T4" bash "$DOTFILES/setup.sh" --git-identity 2>&1)"; RC=$?
check "--git-identity refuses: no owners"     "[ $RC -ne 0 ] && out_has 'has no owners'"
check "  and leaves routing uninstalled"      "none_of_component '$T4'"
check "  and leaves the starters"             "real_file '$T4/.config/dotfiles/identity/owners'"
OUT="$(env -i PATH="$PATH" HOME="$T4" python3 "$DOTFILES/bin/git-identity-check" 2>&1)"; RC=$?
check "the check fails on a missing owners file" "[ $RC -eq 1 ] && out_has 'FAIL [owners]'"
cp "$T4/.config/dotfiles/identity/owners" "$T4/.config/git/owners"
OUT="$(env -i PATH="$PATH" HOME="$T4" python3 "$DOTFILES/bin/git-identity-check" 2>&1)"; RC=$?
check "  and on the unedited one: no owners"  "[ $RC -eq 1 ] && out_has 'has no owners'"
if command -v tmux >/dev/null 2>&1; then
  OUT="$(env -i PATH="$PATH" HOME="$T4" tmux -f "$T4/.tmux.conf" -L "starter-$$" start-server \; show-options -gqv @plugin \; kill-server 2>&1)"
  check "tmux reads the unedited local.conf without complaint" "! out_has 'local.conf'"
fi

echo "== starters: following only their comments gives a passing setup =="
# Each step is what a comment says to do, applied mechanically: remove the `#> ` from the
# suggested lines, change alice to your account, add the public key, make the key. Nothing
# here comes from the fixtures. The one departure is the SSH config: ssh reads the real home
# whatever HOME says, so the Include is absolute and passed with -F, as in the check's suite.
follow() {  # $1 = file: uncomment and rename the suggestions
  sed -e 's/^#> //' -e 's/alice/dana/g' -e 's/Alice/Dana/g' "$1" > "$1.new" && mv "$1.new" "$1"
}
F="$(new_home)"; plain "$F"; FD="$F/.config/dotfiles/identity"
check "every suggestion is marked #> "        "grep -q '^#> owner alice github-alice identity-alice' '$FD/owners' && grep -q '^#> alias github.com alice' '$FD/owners'"
for f in "$FD/owners" "$FD/git/config" "$FD/git/identity-alice" "$FD/git/allowed_signers" "$FD/ssh/github.conf" \
         "$F/.config/git/accounts" "$F/.config/git/repo-roots"; do
  follow "$f"
done
mv "$FD/git/identity-alice" "$FD/git/identity-dana"
mkdir -p "$F/.ssh"; ssh-keygen -q -t ed25519 -N '' -C test-key -f "$F/.ssh/id_ed25519_dana"
PUB="$(cat "$F/.ssh/id_ed25519_dana.pub")"
sed "s|<your public key>|$PUB|" "$FD/git/allowed_signers" > "$FD/git/allowed_signers.new" && mv "$FD/git/allowed_signers.new" "$FD/git/allowed_signers"
OUT="$(env -i PATH="$PATH" HOME="$F" bash "$DOTFILES/setup.sh" --git-identity 2>&1)"; RC=$?
check "--git-identity accepts the folder"     "[ $RC -eq 0 ] && resolves '$F/.config/git/identity-dana' && resolves '$F/.ssh/config.d/github.conf'"
printf 'Include %s/.ssh/config.d/github.conf\n' "$F" > "$F/.ssh/config"
mkdir -p "$F/code/dana/proj"
fgit() { env -i PATH="$PATH" HOME="$F" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
fgit -C "$F/code/dana/proj" init -q; fgit -C "$F/code/dana/proj" remote add origin git@github.com:dana/proj.git
OUT="$(env -i PATH="$PATH" HOME="$F" GIT_CONFIG_NOSYSTEM=1 GIT_IDENTITY_CHECK_SSH_CONFIG="$F/.ssh/config" "$F/.local/bin/git-identity-check" --verbose 2>&1)"; RC=$?
check "git-identity-check passes"             "[ $RC -eq 0 ] && out_has 'all checks passed'"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | sed 's/^/         /'
check "  and finds the installer's repo"      "out_has 'scanned $F/code/dana/proj' && out_has 'scanned 1 repos'"
check "  which resolves to the installer's identity" "[ \"\$(fgit -C '$F/code/dana/proj' config user.email)\" = 1001+dana@users.noreply.github.com ]"
check "  and routes through the installer's alias" "[ \"\$(fgit -C '$F/code/dana/proj' ls-remote --get-url origin)\" = git@github-dana:dana/proj.git ]"
check "the signer list holds the key"         "grep -qF \"\$PUB\" '$FD/git/allowed_signers'"
check "the starters themselves stay real files" "real_file '$F/.config/git/accounts' && real_file '$F/.config/git/repo-roots'"

echo "== tmux: an optional local file, read last =="
check "tmux.conf's last command sources it, ignoring a missing file" "[ \"\$(grep -v '^[[:space:]]*\$' '$DOTFILES/tmux/tmux.conf' | grep -v '^#' | tail -1)\" = 'source-file -q ~/.config/tmux/local.conf' ]"
if command -v tmux >/dev/null 2>&1; then
  TM="$(new_home)"; mkdir -p "$TM/.config/tmux"; printf 'set -g @from-local yes\nset -g status-position top\n' > "$TM/.config/tmux/local.conf"
  OUT="$(env -i PATH="$PATH" HOME="$TM" tmux -f "$DOTFILES/tmux/tmux.conf" -L "local-$$" start-server \; show-options -gv @from-local \; kill-server 2>&1)"
  check "tmux reads the local file"           "out_has yes"
else
  echo "  (tmux not installed: the file is checked by its text only)"
fi

echo "== --replace-links-from: links into the old checkout count as this repo's =="
# The real order of events: a machine installed from a checkout, whose folder was then
# renamed, so every link dangles. The data folder moves too: `<old>/git/config` is
# `<private>/git/config` afterwards.
old_machine() {  # sets LH (HOME), LOLD (the old path, now gone), LPRIV (the new data folder)
  LH="$(new_home)"; mkdir -p "$LH/src" "$LH/repos" "$LH/.codex"; LOLD="$(cd "$LH/src" && pwd -P)/olddot"
  cp -R "$DOTFILES" "$LOLD"
  cp -R "$FIXTURE/git" "$FIXTURE/ssh" "$LOLD/"; cp "$FIXTURE/owners" "$LOLD/owners"
  rm -f "$LH/.claude/settings.json"; mkdir -p "$LH/.claude"
  IDENT_SETUP="$LOLD/setup.sh" plain "$LH" --no-starters
  # What a machine installed by an older setup.sh holds, whatever this one now does: a
  # link for the settings, and a workspace link into the old checkout.
  ln -s "$LOLD/workspace/CLAUDE.md" "$LH/repos/CLAUDE.md"
  rm -f "$LH/.claude/settings.json" "$LH/.claude/settings.json.generated"; ln -s "$LOLD/claude/settings.json" "$LH/.claude/settings.json"
  IDENT_SETUP="$LOLD/setup.sh" IDENT_DIR="$LOLD" run_identity "$LH" >/dev/null || bad "old machine: identity install"
  LPRIV="$LH/private"; mkdir -p "$LPRIV"; cp -R "$FIXTURE"/. "$LPRIV/"
  mv "$LOLD" "$LOLD-renamed"
}
PLAIN_LINKS=".claude/settings.json .claude/statusline-command.sh .claude/hooks/guard-codex-exec.py .claude/CLAUDE.md .tmux.conf"
old_machine
check "the staged links really dangle"        "[ -L '$LH/.config/git/config' ] && [ ! -e '$LH/.config/git/config' ] && [ -L '$LH/.tmux.conf' ] && [ ! -e '$LH/.tmux.conf' ] && [ -L '$LH/.claude/settings.json' ] && [ ! -e '$LH/.claude/settings.json' ]"
# Not touched, in every run: these only look related.
ln -s "$LOLD/README.md" "$LH/my-note"; ln -s "$LOLD-backup/x" "$LH/my-sibling"
ln -s "$LOLD/git/extra" "$LH/.config/git/extra"
L0="$(tree_snap "$LH")"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH")"; RC=$?
check "without the flag --git-identity refuses them" "[ $RC -ne 0 ] && out_has 'exists and is not this'"
check "  and nothing was written"             "[ \"\$(tree_snap '$LH')\" = \"\$L0\" ]"
plain "$LH" --no-starters
check "without the flag settings.json is refused" "[ $RC -eq 1 ] && out_has --replace-links-from"
check "  and nothing was written"             "[ \"\$(tree_snap '$LH')\" = \"\$L0\" ]"
plain "$LH" --no-starters --replace-links-from "$LOLD"
check "the plain run with the flag succeeds"  "[ $RC -eq 0 ]"
check "  and leaves a workspace link for the repo that owns it" "[ \"\$(readlink '$LH/repos/CLAUDE.md')\" = '$LOLD/workspace/CLAUDE.md' ]"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | sed 's/^/         /'
for d in $PLAIN_LINKS; do
  check "  ~/$d no longer points at the old path" "[ -e '$LH/$d' ] && ! { [ -L '$LH/$d' ] && case \"\$(readlink '$LH/$d')\" in '$LOLD'/*) true ;; *) false ;; esac; }"
done
check "  settings.json is a real file"        "real_file '$LH/.claude/settings.json' && json_eq '$LH/.claude/settings.json' '$BASE'"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
check "the identity run with the flag succeeds" "[ $RC -eq 0 ]"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | sed 's/^/         /'
for d in .config/git/config .config/git/identity-alice .config/git/identity-acme .config/git/identity-bob .config/git/identity-carol .config/git/allowed_signers .config/git/owners .ssh/config.d/github.conf; do
  case "$d" in
    .config/git/owners) w="$LPRIV/owners" ;;
    .config/git/*)      w="$LPRIV/git/${d#.config/git/}" ;;
    .ssh/config.d/*)    w="$LPRIV/ssh/${d#.ssh/config.d/}" ;;
  esac
  check "  ~/$d moved to the new data folder" "[ -L '$LH/$d' ] && [ '$LH/$d' -ef '$w' ]"
done
for d in .local/bin/gh-as .local/bin/git-identity-audit .local/bin/git-identity-check; do
  check "  ~/$d moved to this checkout"       "[ -L '$LH/$d' ] && [ '$LH/$d' -ef '$DOTFILES/bin/${d#.local/bin/}' ]"
done
check "a link that only looks related is left" "[ \"\$(readlink '$LH/my-sibling')\" = '$LOLD-backup/x' ]"
check "a link into the old path at no destination is left" "[ \"\$(readlink '$LH/my-note')\" = '$LOLD/README.md' ] && [ \"\$(readlink '$LH/.config/git/extra')\" = '$LOLD/git/extra' ]"

echo "== --replace-links-from: anything else is still refused =="
for bad_target in "$LOLD-backup/git/config" "/elsewhere/git/config" "$LOLD/../elsewhere/config"; do
  old_machine; rm -f "$LH/.config/git/config"; ln -s "$bad_target" "$LH/.config/git/config"
  L0="$(tree_snap "$LH")"; OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
  check "a link to $(basename "$(dirname "$(dirname "$bad_target")")")/... is refused" "[ $RC -ne 0 ] && out_has '.config/git/config exists'"
  check "  and nothing was written"           "[ \"\$(tree_snap '$LH')\" = \"\$L0\" ]"
done
old_machine; rm -f "$LH/.config/git/owners"; printf 'mine\n' > "$LH/.config/git/owners"; L0="$(tree_snap "$LH")"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
check "a real file at a destination is refused" "[ $RC -ne 0 ] && [ \"\$(tree_snap '$LH')\" = \"\$L0\" ]"
old_machine; rm -f "$LH/.claude/settings.json"; ln -s /elsewhere/settings.json "$LH/.claude/settings.json"; plain "$LH" --no-starters --replace-links-from "$LOLD"
check "a settings link elsewhere is still refused" "[ $RC -eq 1 ] && [ \"\$(readlink '$LH/.claude/settings.json')\" = /elsewhere/settings.json ]"

echo "== --replace-links-from: spellings of the same path =="
# Under macOS's /var -> /private/var, setup.sh records physical paths while a person may
# type either, and the old folder no longer exists to resolve. Staged with a link of our own.
old_machine; ALIAS="$(new_home)/alias"; ln -s "$LH/src" "$ALIAS"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$ALIAS/olddot")"; RC=$?
check "the old path through a linked folder is recognized" "[ $RC -eq 0 ]"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | sed 's/^/         /'
old_machine; ALIAS="$(new_home)/alias"; ln -s "$LH/src" "$ALIAS"; rm -f "$LH/.config/git/config"; ln -s "$ALIAS/olddot/git/config" "$LH/.config/git/config"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
check "a link spelled through a linked folder is recognized" "[ $RC -eq 0 ]"
old_machine; rm -f "$LH/.config/git/config"; (cd "$LH/.config/git" && ln -s ../../src/olddot/git/config config)
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD/")"; RC=$?
check "a relative link, and a trailing slash, are recognized" "[ $RC -eq 0 ]"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT" | sed 's/^/         /'
old_machine; mkdir -p "$LOLD"; printf 'different\n' > "$LOLD/other"; rm -f "$LH/.config/git/owners"; ln -s "$LOLD/other" "$LH/.config/git/owners"
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
check "a live link into the old path is recognized too" "[ $RC -eq 0 ] && [ '$LH/.config/git/owners' -ef '$LPRIV/owners' ]"
check "  and its target is not removed"       "[ \"\$(cat '$LOLD/other')\" = different ]"

echo "== --replace-links-from: paths it must not accept =="
FLAGH="$(new_home)"
flag_refused() {  # $1 = label, $2 = path
  local h0; h0="$(tree_snap "$FLAGH")"
  env -i PATH="$PATH" HOME="$FLAGH" bash "$DOTFILES/setup.sh" --replace-links-from "$2" >/dev/null 2>&1; RC=$?
  check "$1 exits 2"                          "[ $RC -eq 2 ]"
  check "  and writes nothing"                "[ \"\$(tree_snap '$FLAGH')\" = \"\$(printf '%s' '$h0')\" ]"
}
flag_refused "a relative path" "old/checkout"
flag_refused "/" "/"
flag_refused "the home folder" "$FLAGH"
flag_refused "a folder above home" "$(dirname "$FLAGH")"
flag_refused "this checkout" "$DOTFILES"
flag_refused "a folder holding this checkout" "$(dirname "$DOTFILES")"
check "--replace-links-from with no value exits 2" "exits_with 2 bash '$DOTFILES/setup.sh' --replace-links-from"
check "--help names every new flag" "case \"\$(bash '$DOTFILES/setup.sh' --help)\" in *--settings-overlay*--user-instructions*--force-settings*--no-starters*--replace-links-from*) true ;; *) false ;; esac"

echo "== settings: an edit already in the new result is not drift =="
# A live edit moved to the overlay while the base changes on its own.
# The live file then differs from both the record and the result, and holds nothing to lose.
drift_home() {  # sets DH (HOME), DSET (its setup.sh), DB (its base), DL (the live file)
  DH="$(new_home)"; cp -R "$DOTFILES" "$DH/dot"; DSET="$DH/dot/setup.sh"; DB="$DH/dot/claude/settings.json"
  DL="$DH/.claude/settings.json"; set_overlay "$DH" '{}'; IDENT_SETUP="$DSET" plain "$DH"
}
edit_json() {  # $1 = file, $2 = python statements over d
  python3 -c "import json,sys;p=sys.argv[1];d=json.load(open(p));$2;open(p,'w').write(json.dumps(d,indent=2))" "$1"
}
drift_home; live_edit "$DH" movedKey movedValue
set_overlay "$DH" '{"movedKey":"movedValue"}'; edit_json "$DB" "d['fromBase']=True"
IDENT_SETUP="$DSET" plain "$DH"
check "a moved edit plus a base change clears, with no force" "[ $RC -eq 0 ]"
check "  and writes the new result"           "[ \"\$(json_get '$DL' movedKey)\" = movedValue ] && [ \"\$(json_get '$DL' fromBase)\" = True ]"
check "  and the record follows"              "json_eq '$DL' '$DL.generated'"
drift_home; live_edit "$DH" stayKey stayValue; edit_json "$DB" "d['fromBase']=True"
LIVE0="$(cksum < "$DL")"; IDENT_SETUP="$DSET" plain "$DH"
check "a live edit not in the overlay still stops" "[ $RC -eq 1 ] && out_has stayKey && [ \"\$(cksum < '$DL')\" = '$LIVE0' ]"
check "  and doesn't list the base's change as the edit" "! out_has fromBase"
drift_home; edit_json "$DL" "d.pop('statusLine')"; LIVE0="$(cksum < "$DL")"; IDENT_SETUP="$DSET" plain "$DH"
check "a key deleted live and still in the result stops" "[ $RC -eq 1 ] && out_has statusLine && [ \"\$(cksum < '$DL')\" = '$LIVE0' ]"
drift_home; edit_json "$DL" "d.pop('statusLine')"; edit_json "$DB" "d.pop('statusLine')"; IDENT_SETUP="$DSET" plain "$DH"
check "a key deleted live and gone from the result clears" "[ $RC -eq 0 ] && json_eq '$DL' '$DB'"
drift_home; edit_json "$DL" "d['statusLine']['liveNested']=1"; set_overlay "$DH" '{"statusLine":{"liveNested":1}}'; edit_json "$DB" "d['fromBase']=True"; IDENT_SETUP="$DSET" plain "$DH"
check "a nested edit in the result clears"    "[ $RC -eq 0 ] && [ \"\$(json_get '$DL' fromBase)\" = True ]"
drift_home; edit_json "$DL" "d['statusLine']['liveNested']=1"; edit_json "$DB" "d['fromBase']=True"; IDENT_SETUP="$DSET" plain "$DH"
check "a nested edit not in the result stops" "[ $RC -eq 1 ] && out_has statusLine.liveNested"
# A first install over a file of your own: once the overlay holds every value in it, the
# result adds only the base's keys, and nothing of yours is lost.
S7R="$(new_home)"; mkdir -p "$S7R/.claude"; printf '{"mine":1,"nest":{"a":1}}\n' > "$S7R/.claude/settings.json"; set_overlay "$S7R" '{"mine":1,"nest":{"a":1}}'; plain "$S7R"
check "no record: a file whose values are all in the overlay applies" "[ $RC -eq 0 ] && real_file '$S7R/.claude/settings.json.generated' && [ \"\$(json_get '$S7R/.claude/settings.json' mine)\" = 1 ] && [ \"\$(json_get '$S7R/.claude/settings.json' statusLine)\" != None ]"
S7P="$(new_home)"; mkdir -p "$S7P/.claude"; printf '{"mine":1,"theirs":2,"nest":{"a":1,"b":2}}\n' > "$S7P/.claude/settings.json"; set_overlay "$S7P" '{"mine":1,"nest":{"a":1}}'; P0="$(cksum < "$S7P/.claude/settings.json")"; plain "$S7P"
check "no record: a value left out of the overlay still stops" "[ $RC -eq 1 ] && out_has '+ theirs: 2' && out_has '+ nest.b: 2' && ! out_has '+ mine' && [ \"\$(cksum < '$S7P/.claude/settings.json')\" = '$P0' ] && absent '$S7P/.claude/settings.json.generated'"
S7V="$(new_home)"; mkdir -p "$S7V/.claude"; printf '{"mine":1}\n' > "$S7V/.claude/settings.json"; set_overlay "$S7V" '{"mine":2}'; plain "$S7V"
check "no record: a value the overlay changes still stops" "[ $RC -eq 1 ] && out_has '+ mine: 1'"
S7S="$(new_home)"; plain "$S7S"; rm "$S7S/.claude/settings.json.generated"; plain "$S7S"
check "no record: a file equal to the result applies" "[ $RC -eq 0 ] && real_file '$S7S/.claude/settings.json.generated'"

echo "== ordinary destinations: nobody's file is lost =="
# Each destination the plain run installs, by path under HOME.
TMUX_SRC="$DOTFILES/tmux/tmux.conf"; CM_SRC="$DOTFILES/claude/CLAUDE.md"
same_bytes() { cmp -s "$1" "$2" && [ ! -L "$2" ]; }
backups() { find "$1" -name '*.pre-dotfiles*' | wc -l | tr -d ' '; }
B1="$(new_home)"; mkdir -p "$B1/.claude/hooks" "$B1/repos"; KEEP="$(mktemp -d)"
for d in .tmux.conf .claude/CLAUDE.md .claude/hooks/guard-codex-exec.py; do
  printf 'my own %s\n' "$d" > "$B1/$d"; mkdir -p "$KEEP/$(dirname "$d")"; cp -p "$B1/$d" "$KEEP/$d"
done
printf 'elsewhere\n' > "$B1/theirs"; ln -s "$B1/theirs" "$B1/.claude/statusline-command.sh"
plain "$B1"
check "a run over someone's files exits 0"    "[ $RC -eq 0 ]"
for d in .claude/hooks/guard-codex-exec.py; do
  check "~/$d is kept, byte-identical"        "same_bytes '$KEEP/$d' '$B1/$d.pre-dotfiles'"
  check "  the install went in"               "resolves '$B1/$d'"
  check "  and the report names both"         "out_has '$B1/$d -> $B1/$d.pre-dotfiles'"
done
check "an unrelated link keeps its target"    "[ \"\$(readlink '$B1/.claude/statusline-command.sh.pre-dotfiles')\" = '$B1/theirs' ]"
check "  its target is untouched"             "[ \"\$(cat '$B1/theirs')\" = elsewhere ]"
check "  and the report names it"             "out_has '$B1/.claude/statusline-command.sh -> $B1/.claude/statusline-command.sh.pre-dotfiles'"
check "the checkout was not written through"  "! grep -q 'my own' '$TMUX_SRC' '$CM_SRC'"
N="$(backups "$B1")"; B1S="$(tree_snap "$B1")"; plain "$B1"
check "a second run makes no further backup"  "[ \"\$(backups '$B1')\" = '$N' ] && [ \"\$(tree_snap '$B1')\" = \"\$B1S\" ]"
check "  and reports none"                    "! out_has 'Moved aside'"

# An ordinary destination other than the two kept files, for the move-aside mechanics.
SL=.claude/statusline-command.sh; SL_SRC=claude/statusline-command.sh
B2="$(new_home)"; mkdir -p "$B2/.claude"; printf 'first\n' > "$B2/$SL"; plain "$B2"
rm -f "$B2/$SL"; printf 'second\n' > "$B2/$SL"; plain "$B2"
check "a taken backup name goes to .1"        "[ \"\$(cat '$B2/$SL.pre-dotfiles')\" = first ] && [ \"\$(cat '$B2/$SL.pre-dotfiles.1')\" = second ]"
check "  and the report names .1"             "out_has '$SL.pre-dotfiles.1'"
rm -f "$B2/$SL"; ln -s "$B2/gone" "$B2/$SL.pre-dotfiles.2"; printf 'third\n' > "$B2/$SL"; plain "$B2"
check "a dangling link holds a backup name too" "[ \"\$(readlink '$B2/$SL.pre-dotfiles.2')\" = '$B2/gone' ] && [ \"\$(cat '$B2/$SL.pre-dotfiles.3')\" = third ]"

B3="$(new_home)"; mkdir -p "$B3/.claude"; printf 'same bytes, not ours\n' > "$B3/twin"
cp -R "$DOTFILES" "$B3/dot"; cp "$B3/twin" "$B3/dot/$SL_SRC"; ln -s "$B3/twin" "$B3/$SL"
IDENT_SETUP="$B3/dot/setup.sh" plain "$B3"
check "a link to a byte-identical file is not ours" "[ \"\$(readlink '$B3/$SL.pre-dotfiles')\" = '$B3/twin' ] && [ -L '$B3/$SL' ] && [ '$B3/$SL' -ef '$B3/dot/$SL_SRC' ]"
B3F="$(new_home)"; mkdir -p "$B3F/.claude" "$B3F/dirlink-target"; ln -s "$B3F/dirlink-target" "$B3F/$SL"; plain "$B3F"
check "a link to a folder moves as a link"    "[ \"\$(readlink '$B3F/$SL.pre-dotfiles')\" = '$B3F/dirlink-target' ] && [ -z \"\$(ls -A '$B3F/dirlink-target')\" ]"
B3D="$(new_home)"; mkdir -p "$B3D/$SL"; printf x > "$B3D/$SL/inside"; plain "$B3D"
check "a folder moves aside whole"            "[ $RC -eq 0 ] && [ -f '$B3D/$SL.pre-dotfiles/inside' ] && resolves '$B3D/$SL'"

echo "== ~/.claude/CLAUDE.md and ~/.tmux.conf: a person's own is left in place =="
# Both are files a person writes for themselves, and the repo's versions are samples. A kept
# file's name and sample path are what the report must give, on every run it stays.
kept_ok() {  # $1 = label, $2 = home, $3 = destination under HOME, $4 = source, $5 = sample's folder
  check "$1: nothing moved aside"             "[ \"\$(backups '$2')\" = 0 ]"
  check "  the report names it and the sample" "out_has 'Kept your ~/$3. The sample is at $5/$4.'"
  check "  and doesn't list it as installed"  "! out_has '~/$3 -> ' && ! out_has '~/$3 = '"
}
kept_pair() {  # $1 = label, $2 = setup flag or empty, $3 = how to plant, given the home and a path
  local d src h before
  for d in .claude/CLAUDE.md .tmux.conf; do
    case "$d" in .tmux.conf) src=tmux/tmux.conf ;; *) src=claude/CLAUDE.md ;; esac
    h="$(new_home)"; mkdir -p "$h/.claude"; "$3" "$h" "$d"; before="$(ls -ld "$h/$d" | awk '{print $1}') $(readlink "$h/$d" 2>/dev/null) $(cksum < "$h/$d" 2>/dev/null)"
    plain "$h" $2
    check "$1 at ~/$d: the run exits 0"       "[ $RC -eq 0 ]"
    check "  it is untouched"                 "[ \"\$(ls -ld '$h/$d' | awk '{print \$1}') \$(readlink '$h/$d' 2>/dev/null) \$(cksum < '$h/$d' 2>/dev/null)\" = \"\$(printf '%s' '$before')\" ]"
    kept_ok "  $1" "$h" "$d" "$src" "$DOTFILES"
    plain "$h" $2
    check "  a second run says so again"      "[ $RC -eq 0 ] && out_has 'Kept your ~/$d.' && [ \"\$(backups '$h')\" = 0 ]"
  done
}
plant_file()     { printf 'my own\n' > "$1/$2"; }
plant_link()     { printf 'theirs\n' > "$1/theirs"; ln -s "$1/theirs" "$1/$2"; }
plant_dangling() { ln -s "$1/gone" "$1/$2"; }
plant_twin()     { case "$2" in .tmux.conf) cp "$DOTFILES/tmux/tmux.conf" "$1/twin" ;; *) cp "$DOTFILES/claude/CLAUDE.md" "$1/twin" ;; esac; ln -s "$1/twin" "$1/$2"; }
kept_pair "a real file"                   ""       plant_file
kept_pair "a real file under --copy"      "--copy" plant_file
kept_pair "a link elsewhere"              ""       plant_link
kept_pair "a link elsewhere under --copy" "--copy" plant_link
kept_pair "a dangling link"               ""       plant_dangling
kept_pair "a link to a byte-identical file" ""     plant_twin
B3K="$(new_home)"; mkdir -p "$B3K/.tmux.conf"; printf x > "$B3K/.tmux.conf/inside"; plain "$B3K"
check "a folder at ~/.tmux.conf stays"        "[ $RC -eq 0 ] && [ -f '$B3K/.tmux.conf/inside' ] && [ \"\$(backups '$B3K')\" = 0 ] && out_has 'Kept your ~/.tmux.conf.'"
B3O="$(new_home)"; mkdir -p "$B3O/.claude"; printf 'mine\n' > "$B3O/.tmux.conf"; plain "$B3O"
check "the other one still installs"          "[ '$B3O/.claude/CLAUDE.md' -ef '$DOTFILES/claude/CLAUDE.md' ] && out_has '~/.claude/CLAUDE.md -> ' && ! out_has 'Kept your ~/.claude/CLAUDE.md'"
for d in .claude/CLAUDE.md .tmux.conf; do
  case "$d" in .tmux.conf) src=tmux/tmux.conf ;; *) src=claude/CLAUDE.md ;; esac
  B3C="$(new_home)"; mkdir -p "$B3C/.claude"; cp "$DOTFILES/$src" "$B3C/$d"; plain "$B3C"
  check "a byte-identical copy of ~/$d is ours" "[ -L '$B3C/$d' ] && [ '$B3C/$d' -ef '$DOTFILES/$src' ] && [ \"\$(backups '$B3C')\" = 0 ] && ! out_has 'Kept your'"
  plain "$B3C" --copy
  check "  and so is this repo's link, under --copy" "real_file '$B3C/$d' && cmp -s '$DOTFILES/$src' '$B3C/$d' && [ \"\$(backups '$B3C')\" = 0 ] && ! out_has 'Kept your'"
done

echo "== ordinary destinations: re-runs and switching modes =="
B4="$(new_home)"; cp -R "$DOTFILES" "$B4/dot"; IDENT_SETUP="$B4/dot/setup.sh" plain "$B4" --copy
check "a fresh copy install backs up nothing" "[ \"\$(backups '$B4')\" = 0 ]"
IDENT_SETUP="$B4/dot/setup.sh" plain "$B4" --copy
check "an unchanged --copy re-run backs up nothing" "[ \"\$(backups '$B4')\" = 0 ]"
cat "$B4/$SL" > "$B4/oldcopy"; printf '# newer\n' >> "$B4/dot/$SL_SRC"
IDENT_SETUP="$B4/dot/setup.sh" plain "$B4" --copy
check "a --copy re-run after a source change updates" "[ $RC -eq 0 ] && same_bytes '$B4/dot/$SL_SRC' '$B4/$SL'"
check "  and the old copy is moved aside"     "same_bytes '$B4/oldcopy' '$B4/$SL.pre-dotfiles'"
N="$(backups "$B4")"; IDENT_SETUP="$B4/dot/setup.sh" plain "$B4"
check "copy -> link makes no backup"          "[ \"\$(backups '$B4')\" = '$N' ] && [ -L '$B4/$SL' ] && [ -L '$B4/.tmux.conf' ]"
IDENT_SETUP="$B4/dot/setup.sh" plain "$B4" --copy
check "link -> copy makes no backup"          "[ \"\$(backups '$B4')\" = '$N' ] && [ ! -L '$B4/$SL' ] && [ ! -L '$B4/.tmux.conf' ]"
check "  and the source is intact"            "[ ! -L '$B4/dot/$SL_SRC' ] && [ -f '$B4/dot/$SL_SRC' ]"
B4T="$(new_home)"; cp -R "$DOTFILES" "$B4T/dot"; IDENT_SETUP="$B4T/dot/setup.sh" plain "$B4T" --copy
cat "$B4T/.tmux.conf" > "$B4T/oldcopy"; printf '# newer\n' >> "$B4T/dot/tmux/tmux.conf"
IDENT_SETUP="$B4T/dot/setup.sh" plain "$B4T" --copy
check "an older --copy of ~/.tmux.conf can't be told from a person's own: it stays" "[ $RC -eq 0 ] && same_bytes '$B4T/oldcopy' '$B4T/.tmux.conf' && [ \"\$(backups '$B4T')\" = 0 ]"
check "  and the report names the sample"     "out_has 'Kept your ~/.tmux.conf. The sample is at $B4T/dot/tmux/tmux.conf.'"
B4A="$(new_home)"; ln -s "$DOTFILES/tmux/tmux.conf" "$B4A/hop"; ln -s "$B4A/hop" "$B4A/.tmux.conf"; plain "$B4A"
check "a link reaching the source through another is ours" "[ ! -e '$B4A/.tmux.conf.pre-dotfiles' ] && [ ! -L '$B4A/.tmux.conf.pre-dotfiles' ]"

B5="$(new_home)"; mkdir -p "$B5/.codex"; printf 'my instructions\n' > "$B5/.codex/AGENTS.md"; plain "$B5"
check ".codex/AGENTS.md is left alone"        "[ \"\$(cat '$B5/.codex/AGENTS.md')\" = 'my instructions' ] && absent '$B5/.codex/AGENTS.md.pre-dotfiles'"
B5S="$(new_home)"; mkdir -p "$B5S/.claude"; printf '{"mine":1}\n' > "$B5S/.claude/settings.json"; plain "$B5S"
check "settings.json keeps its drift stop, with no backup" "[ $RC -eq 1 ] && absent '$B5S/.claude/settings.json.pre-dotfiles'"
B5I="$(new_home)"; mkdir -p "$B5I/.config/git"; printf 'mine\n' > "$B5I/.config/git/config"; run_identity "$B5I" >/dev/null; RC=$?
check "identity destinations keep their preflight" "[ $RC -ne 0 ] && [ \"\$(cat '$B5I/.config/git/config')\" = mine ] && absent '$B5I/.config/git/config.pre-dotfiles'"
B5M="$(new_home)"; mkdir -p "$B5M/.claude/rules"; printf 'my rule\n' > "$B5M/.claude/rules/mine.md"; plain "$B5M"
check "a user rule is left alone"             "[ \"\$(cat '$B5M/.claude/rules/mine.md')\" = 'my rule' ] && absent '$B5M/.claude/rules/mine.md.pre-dotfiles'"
BIC="$(new_home)"; cp -R "$DOTFILES" "$BIC/dot"; rm -f "$BIC/dot/tmux/tmux.conf"; printf 'mine\n' > "$BIC/.tmux.conf"; IDENT_SETUP="$BIC/dot/setup.sh" plain "$BIC"
check "an incomplete checkout leaves the file where it is" "[ $RC -eq 1 ] && [ \"\$(cat '$BIC/.tmux.conf')\" = mine ] && absent '$BIC/.tmux.conf.pre-dotfiles'"

echo "== ordinary destinations: a destination that IS the source is refused =="
# Each uses a copy of the checkout, so a failure can't damage this worktree's files.
B6="$(new_home)"; cp -R "$DOTFILES" "$B6/dot"; ln -s "$B6/dot/claude" "$B6/.claude"; B60="$(cksum < "$B6/dot/claude/CLAUDE.md")"; B6S="$(tree_snap "$B6")"
IDENT_SETUP="$B6/dot/setup.sh" plain "$B6"
check "a linked folder into the checkout is refused" "[ $RC -ne 0 ] && out_has 'reaches the destination'"
check "  the source is intact, a real file"   "[ ! -L '$B6/dot/claude/CLAUDE.md' ] && [ \"\$(cksum < '$B6/dot/claude/CLAUDE.md')\" = '$B60' ]"
check "  and nothing was written"             "[ \"\$(tree_snap '$B6')\" = \"\$B6S\" ]"
B7="$(new_home)"; cp -R "$DOTFILES" "$B7/dot"; mv "$B7/dot/tmux/tmux.conf" "$B7/.tmux.conf"; ln -s "$B7/.tmux.conf" "$B7/dot/tmux/tmux.conf"; B70="$(cksum < "$B7/.tmux.conf")"; B7S="$(tree_snap "$B7")"
IDENT_SETUP="$B7/dot/setup.sh" plain "$B7"
check "a source linked to its destination is refused" "[ $RC -ne 0 ] && [ ! -L '$B7/.tmux.conf' ] && [ \"\$(cksum < '$B7/.tmux.conf')\" = '$B70' ] && [ \"\$(tree_snap '$B7')\" = \"\$B7S\" ]"

echo "== --replace-links-from: a foreign destination is refused before any write =="
refused_flag() {  # $1 = label, $2 = the path that must be named; uses $LH, $LOLD
  local h0; h0="$(tree_snap "$LH")"
  plain "$LH" --no-starters --replace-links-from "$LOLD"
  check "$1 is refused"                       "[ $RC -ne 0 ] && out_has '$2' && out_has 'nothing was written'"
  check "  and the home is unchanged"         "[ \"\$(tree_snap '$LH')\" = \"\$(printf '%s' '$h0')\" ]"
  check "  with no backup"                    "[ \"\$(backups '$LH')\" = 0 ]"
}
old_machine; rm -f "$LH/.tmux.conf"; printf 'my tmux\n' > "$LH/.tmux.conf"; refused_flag "a real file at the last destination" ".tmux.conf"
old_machine; printf 'twin\n' > "$LH/twin"; rm -f "$LH/.claude/CLAUDE.md"; ln -s "$LH/twin" "$LH/.claude/CLAUDE.md"; refused_flag "a link elsewhere at CLAUDE.md" ".claude/CLAUDE.md"
old_machine; cp "$DOTFILES/claude/CLAUDE.md" "$LH/twin"; rm -f "$LH/.claude/CLAUDE.md"; ln -s "$LH/twin" "$LH/.claude/CLAUDE.md"; refused_flag "a link to a byte-identical file" ".claude/CLAUDE.md"
old_machine; rm -f "$LH/.tmux.conf"; printf 'a stale copy\n' > "$LH/.tmux.conf"; refused_flag "a stale copy" ".tmux.conf"
old_machine; rm -f "$LH/.tmux.conf"; cp "$DOTFILES/tmux/tmux.conf" "$LH/.tmux.conf"; plain "$LH" --no-starters --replace-links-from "$LOLD"
check "a byte-identical copy is replaced"     "[ $RC -eq 0 ] && [ \"\$(backups '$LH')\" = 0 ] && resolves '$LH/.tmux.conf'"
old_machine; plain "$LH" --no-starters --replace-links-from "$LOLD"
check "dangling old links are replaced, with no backup" "[ $RC -eq 0 ] && [ \"\$(backups '$LH')\" = 0 ] && resolves '$LH/.tmux.conf' && resolves '$LH/.claude/CLAUDE.md'"
plain "$LH" --no-starters --replace-links-from "$LOLD"
check "  and a re-run with the flag still works" "[ $RC -eq 0 ] && [ \"\$(backups '$LH')\" = 0 ]"
old_machine; plain "$LH" --no-starters --force-settings
check "without the flag a dangling old link is kept as a backup" "[ $RC -eq 0 ] && [ \"\$(readlink '$LH/$SL.pre-dotfiles')\" = '$LOLD/$SL_SRC' ] && resolves '$LH/$SL'"
check "  except at a kept file, where it stays and is reported" "[ \"\$(readlink '$LH/.tmux.conf')\" = '$LOLD/tmux/tmux.conf' ] && absent '$LH/.tmux.conf.pre-dotfiles' && out_has 'Kept your ~/.tmux.conf.'"

echo "== --replace-links-from: a .. after a named part is not under the old path =="
# ../../shortcut/../olddot reads as ~/olddot, but shortcut is a link elsewhere, so it really
# leads somewhere else. The planted file exists there, to show what replacing it would lose.
planted_home() {  # sets PH, POLD; $1 = the real file's place under far/olddot
  PH="$(new_home)"; PH="$(cd "$PH" && pwd -P)"; POLD="$PH/olddot"
  mkdir -p "$PH/far/deep" "$PH/far/olddot/$(dirname "$1")"; printf 'not the old checkout\n' > "$PH/far/olddot/$1"
  ln -s "$PH/far/deep" "$PH/shortcut"
}
planted_home git/config; mkdir -p "$PH/.config/git"; (cd "$PH/.config/git" && ln -s ../../shortcut/../olddot/git/config config)
check "the planted link really leads elsewhere" "[ \"\$(cat '$PH/.config/git/config')\" = 'not the old checkout' ]"
P0="$(tree_snap "$PH")"; OUT="$(run_identity "$PH" --replace-links-from "$POLD")"; RC=$?
check "identity: the planted link isn't replaced" "[ $RC -ne 0 ] && out_has '.config/git/config exists' && [ \"\$(readlink '$PH/.config/git/config')\" = ../../shortcut/../olddot/git/config ]"
check "  and nothing was written"             "[ \"\$(tree_snap '$PH')\" = \"\$P0\" ]"
planted_home claude/CLAUDE.md; mkdir -p "$PH/.claude"; (cd "$PH/.claude" && ln -s ../shortcut/../olddot/claude/CLAUDE.md CLAUDE.md)
P0="$(tree_snap "$PH")"; plain "$PH" --no-starters --replace-links-from "$POLD"
check "plain: the planted link isn't replaced" "[ $RC -ne 0 ] && out_has '.claude/CLAUDE.md' && [ \"\$(readlink '$PH/.claude/CLAUDE.md')\" = ../shortcut/../olddot/claude/CLAUDE.md ]"
check "  and nothing was written"             "[ \"\$(tree_snap '$PH')\" = \"\$P0\" ]"
planted_home claude/settings.json; mkdir -p "$PH/.claude"; (cd "$PH/.claude" && ln -s ../shortcut/../olddot/claude/settings.json settings.json)
plain "$PH" --no-starters --replace-links-from "$POLD"
check "plain: nor is a planted settings link" "[ $RC -eq 1 ] && [ -L '$PH/.claude/settings.json' ]"
old_machine; rm -f "$LH/.config/git/config"; (cd "$LH/.config/git" && ln -s ../../src/olddot/git/config config)
OUT="$(IDENT_DIR="$LPRIV" run_identity "$LH" --replace-links-from "$LOLD")"; RC=$?
check "identity: a leading-.. old link is replaced" "[ $RC -eq 0 ] && [ '$LH/.config/git/config' -ef '$LPRIV/git/config' ]"
old_machine; rm -f "$LH/.claude/CLAUDE.md"; (cd "$LH/.claude" && ln -s ../src/olddot/claude/CLAUDE.md CLAUDE.md)
plain "$LH" --no-starters --replace-links-from "$LOLD"
check "plain: a leading-.. old link is replaced" "[ $RC -eq 0 ] && [ \"\$(backups '$LH')\" = 0 ] && [ '$LH/.claude/CLAUDE.md' -ef '$DOTFILES/claude/CLAUDE.md' ]"

echo "== --user-instructions: ~/.claude/CLAUDE.md from a file of your own =="
UI_DIR="$(new_home)"; printf '# my instructions\n' > "$UI_DIR/mine.md"; UI="$UI_DIR/mine.md"
U1="$(new_home)"; plain "$U1" --user-instructions "$UI"
check "it links ~/.claude/CLAUDE.md to the file" "[ $RC -eq 0 ] && [ \"\$(readlink '$U1/.claude/CLAUDE.md')\" = '$UI' ]"
check "  and the report names it"             "out_has '~/.claude/CLAUDE.md -> $UI'"
U1S="$(tree_snap "$U1")"; plain "$U1" --user-instructions "$UI"
check "  and a second run changes nothing"    "[ $RC -eq 0 ] && [ \"\$(tree_snap '$U1')\" = \"\$U1S\" ] && ! out_has 'Kept your'"
plain "$U1" --user-instructions "$UI" --copy
check "--copy installs a copy of it"          "[ $RC -eq 0 ] && real_file '$U1/.claude/CLAUDE.md' && cmp -s '$UI' '$U1/.claude/CLAUDE.md'"
plain "$U1" --user-instructions "$UI"
check "  and that copy counts as its own"     "[ $RC -eq 0 ] && [ -L '$U1/.claude/CLAUDE.md' ] && [ \"\$(backups '$U1')\" = 0 ]"
check "the file itself is untouched"          "[ \"\$(cat '$UI')\" = '# my instructions' ] && [ ! -L '$UI' ]"
U2="$(new_home)"; plain "$U2"
check "the sample's link is there first"      "[ \"\$(readlink '$U2/.claude/CLAUDE.md')\" = '$CM_SRC' ]"
plain "$U2" --user-instructions "$UI"
check "  and the option replaces it"          "[ $RC -eq 0 ] && [ \"\$(readlink '$U2/.claude/CLAUDE.md')\" = '$UI' ] && [ \"\$(backups '$U2')\" = 0 ] && ! out_has 'Kept your'"
plain "$U2"
check "without the option, the file's link is kept as yours" "[ $RC -eq 0 ] && [ \"\$(readlink '$U2/.claude/CLAUDE.md')\" = '$UI' ] && out_has 'Kept your ~/.claude/CLAUDE.md. The sample is at'"
U3="$(new_home)"; mkdir -p "$U3/.claude"; printf 'my own\n' > "$U3/.claude/CLAUDE.md"; plain "$U3" --user-instructions "$UI"
check "a file of your own there is kept"      "[ $RC -eq 0 ] && [ \"\$(cat '$U3/.claude/CLAUDE.md')\" = 'my own' ] && [ \"\$(backups '$U3')\" = 0 ]"
check "  and the report names the file not installed" "out_has 'Kept your ~/.claude/CLAUDE.md. The --user-instructions file, $UI, was not installed there.'"
U4="$(new_home)"; mkdir -p "$U4/.claude"; cp "$CM_SRC" "$U4/.claude/CLAUDE.md"; plain "$U4" --user-instructions "$UI"
check "a copy of the sample is replaced"      "[ $RC -eq 0 ] && [ \"\$(readlink '$U4/.claude/CLAUDE.md')\" = '$UI' ] && [ \"\$(backups '$U4')\" = 0 ]"
U5="$(new_home)"; U50="$(tree_snap "$U5")"; plain "$U5" --user-instructions "$U5/typo.md"
check "a named file that is missing is refused" "[ $RC -eq 2 ] && out_has '$U5/typo.md'"
check "  and nothing was written"             "[ \"\$(tree_snap '$U5')\" = \"\$U50\" ]"
U6="$(new_home)"; (cd "$UI_DIR" && plain "$U6" --user-instructions mine.md)
# Compared as files, not strings: on macOS the temp folder is behind a link (/var is
# /private/var), so the absolute path setup.sh writes can be either spelling.
check "a relative path installs an absolute link" "case \"\$(readlink '$U6/.claude/CLAUDE.md')\" in /*) ;; *) false ;; esac && [ \"\$(readlink '$U6/.claude/CLAUDE.md')\" -ef '$UI' ] && resolves '$U6/.claude/CLAUDE.md'"
check "--user-instructions with no value exits 2" "exits_with 2 bash '$DOTFILES/setup.sh' --user-instructions"
check "--user-instructions with --git-identity exits 2" "exits_with 2 bash '$DOTFILES/setup.sh' --git-identity --user-instructions '$UI'"
old_machine; plain "$LH" --no-starters --replace-links-from "$LOLD" --user-instructions "$UI"
check "with --replace-links-from, an old link is replaced by the file" "[ $RC -eq 0 ] && [ \"\$(readlink '$LH/.claude/CLAUDE.md')\" = '$UI' ] && [ \"\$(backups '$LH')\" = 0 ]"
plain "$LH" --no-starters --replace-links-from "$LOLD" --user-instructions "$UI"
check "  and the file's link counts as its own" "[ $RC -eq 0 ] && [ \"\$(readlink '$LH/.claude/CLAUDE.md')\" = '$UI' ]"
old_machine; rm -f "$LH/.claude/CLAUDE.md"; printf 'mine\n' > "$LH/.claude/CLAUDE.md"; L0="$(tree_snap "$LH")"
plain "$LH" --no-starters --replace-links-from "$LOLD" --user-instructions "$UI"
check "  but a file of your own there is refused" "[ $RC -ne 0 ] && out_has '.claude/CLAUDE.md exists' && [ \"\$(tree_snap '$LH')\" = \"\$L0\" ]"

# Last, after every identity case: none of them may have touched the real HOME.
check "live HOME untouched after the identity cases" "[ \"\$(cat $LIVE_SNAP)\" = \"\$(live_snapshot)\" ]"

echo "== setup.sh names no repository that does not exist =="
# A repository reference specifically: an instruction to clone something that was never
# there fails only for the person following it. The tmux plugin manager is the one
# repository setup.sh tells anyone to fetch.
OTHER_REPOS="$(grep -E 'github\.com[:/]' "$DOTFILES/setup.sh" | grep -v 'github\.com/tmux-plugins/tpm' || true)"
check "no other repository reference" "[ -z \"\$OTHER_REPOS\" ]"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
