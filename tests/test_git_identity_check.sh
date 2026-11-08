#!/usr/bin/env bash
#
# git-identity-check must fail loudly on every way a machine can drift, and never fail
# on a correct setup.
#
# Each case starts from a clean fixture home (the component copied in, fixture keys,
# an SSH config that includes github.conf), breaks exactly ONE thing, and expects the
# check to exit 1 naming that cause by its tag, e.g. "[ssh-include]". The clean
# fixture itself must pass: a check that fails everything would satisfy every case.
#
# SSH is read through an explicit config file (GIT_IDENTITY_CHECK_SSH_CONFIG, which the
# check passes to `ssh -F`), with absolute include paths, because a fake HOME alone does
# not stop ssh from reading the real home's files. Live probes use a stub `ssh` that
# answers -T from a scripted table and hands everything else to the real ssh.
#
# Settings, so the same cases can run against any data folder:
#   IDENTITY_DIR       the data folder (default: tests/fixtures/identity)
#   IDENTITY_EXPECTED  its four cases (default: tests/fixtures/identity-expected.sh)

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$DOTFILES/bin/git-identity-check"
IDENTITY_DIR="${IDENTITY_DIR:-$DOTFILES/tests/fixtures/identity}"
IDENTITY_EXPECTED="${IDENTITY_EXPECTED:-$DOTFILES/tests/fixtures/identity-expected.sh}"
[ -f "$IDENTITY_EXPECTED" ] || { echo "no expected values: $IDENTITY_EXPECTED" >&2; exit 2; }
# shellcheck source=fixtures/identity-expected.sh
. "$IDENTITY_EXPECTED"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

REAL_SSH="$(command -v ssh)" || { echo "ssh not found" >&2; exit 2; }

# Same isolation as test_git_identity.sh: nothing inherited may steer git.
unset GIT_CONFIG_GLOBAL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME \
      GIT_COMMITTER_EMAIL EMAIL SSH_AUTH_SOCK GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE \
      GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG GIT_PREFIX LANGUAGE
mkdir -p "$T/empty-template"
# GIT_CONFIG_SYSTEM as well: an explicit `git config --system` ignores GIT_CONFIG_NOSYSTEM.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_TEMPLATE_DIR="$T/empty-template" LC_ALL=C

# One set of fixture keys, copied into every fixture home: generating keys per case
# would make the suite slow for no extra coverage.
mkdir -p "$T/keys"
for a in $MAIN $SECOND $ABSENT; do
  ssh-keygen -q -t ed25519 -N '' -C "fixture-$a" -f "$T/keys/id_ed25519_$a" || { echo "ssh-keygen failed" >&2; exit 2; }
done

N=0
# Builds a clean fixture home and points HOME, XDG_CONFIG_HOME and the SSH config at it.
# Called directly, not in $(…), so its exports reach the caller and a failure stops the run.
fresh_home() {
  N=$((N+1)); H="$T/home$N"
  mkdir -p "$H/.ssh/config.d" "$H/.config/git" "$H/src" || { echo "fixture home failed" >&2; exit 2; }
  export HOME="$H" XDG_CONFIG_HOME="$H/.config"
  cp "$IDENTITY_DIR"/git/config "$IDENTITY_DIR"/git/identity-* "$IDENTITY_DIR"/git/allowed_signers \
     "$IDENTITY_DIR"/owners "$H/.config/git/" || { echo "fixture data failed" >&2; exit 2; }
  cp "$IDENTITY_DIR/ssh/github.conf" "$H/.ssh/config.d/github.conf" || { echo "fixture data failed" >&2; exit 2; }
  cp "$T"/keys/* "$H/.ssh/"
  printf 'Include %s/.ssh/config.d/github.conf\n\nHost example\n    HostName example.invalid\n' "$H" > "$H/.ssh/config"
  export GIT_IDENTITY_CHECK_SSH_CONFIG="$H/.ssh/config"
  printf "# accounts this machine has\n$MAIN\n$SECOND\n$ABSENT\n" > "$H/.config/git/accounts"
  printf '%s/src 3\n' "$H" > "$H/.config/git/repo-roots"
  # One well-formed repo per routed owner, so the clean scan has real work to do.
  for o in $MAIN $ORG $SECOND $ABSENT; do
    mkdir -p "$H/src/$o/repo" && git -C "$H/src/$o/repo" init -q \
      && git -C "$H/src/$o/repo" remote add origin "git@github.com:$o/repo.git" \
      || { echo "fixture repo failed" >&2; exit 2; }
  done
}

# Runs the check; leaves output in $OUT and the exit status in $RC.
run_check() { OUT="$("$CHECK" "$@" 2>&1)"; RC=$?; }

expect_pass() {  # $1 = label, then check args
  local label="$1"; shift; run_check "$@"
  if [ "$RC" -eq 0 ]; then ok "$label"; else bad "$label (exit $RC)"; printf '%s\n' "$OUT" | grep -E 'FAIL' | sed 's/^/         /'; fi
}
expect_fail() {  # $1 = label, $2 = tag, then check args
  local label="$1" tag="$2"; shift 2; run_check "$@"
  if [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -qF "FAIL [$tag]"; then
    ok "$label → [$tag]"
  else
    bad "$label → [$tag] (exit $RC)"; printf '%s\n' "$OUT" | sed 's/^/         /'
  fi
}
output_has()     { if printf '%s\n' "$OUT" | grep -qF "$2"; then ok "$1"; else bad "$1"; printf '         missing: %s\n' "$2"; fi; }
output_lacks()   { if printf '%s\n' "$OUT" | grep -qF "$2"; then bad "$1"; printf '         unexpected: %s\n' "$2"; else ok "$1"; fi; }

[ -x "$CHECK" ] || bad "bin/git-identity-check exists and is executable"

echo "== a clean fixture passes, offline =="
fresh_home
expect_pass "clean fixture"
output_has "offline says authentication is untested" "authentication: not tested"
output_has "the scan found the four fixture repos" "scanned 4 repos"

echo "== the code names no account =="
# Anywhere in a line, read from the owners file, so no list of real names has to ship
# here. A whole-word search would miss a name inside a key file such as id_ed25519_<name>.
OWNER_NAMES="$T/owner-names"
awk '$1 == "owner" { print $2 } $1 == "alias" { print $3 }' "$IDENTITY_DIR/owners" | sort -u > "$OWNER_NAMES"
names_in() { grep -iF -f "$OWNER_NAMES" "$1" >/dev/null; }
if [ -s "$OWNER_NAMES" ] && ! names_in "$CHECK"; then
  ok "no account name in bin/git-identity-check"
else
  bad "no account name in bin/git-identity-check"
fi
cp "$CHECK" "$T/planted-check"; printf '# ~/.ssh/id_ed25519_%s\n' "$(head -1 "$OWNER_NAMES")" >> "$T/planted-check"
if names_in "$T/planted-check"; then ok "  and the search finds a name inside a key file name"; else bad "  and the search finds a name inside a key file name"; fi

echo "== the owners file =="
# Everything the check knows about owners comes from here, so a file it can't use must
# fail rather than leave it with nothing to check.
OWNERS_FILE() { printf '%s/git/owners' "$XDG_CONFIG_HOME"; }
fresh_home; rm "$(OWNERS_FILE)"
expect_fail "no owners file" owners
output_lacks "  and the failure doesn't claim the owner checks passed" "all checks passed"
output_has "  and says what it skipped" "skipped"
fresh_home; printf '# owner <owner> <alias> <identity file>\n\n  # indented\n' > "$(OWNERS_FILE)"
expect_fail "a comment-only owners file" owners
output_has "  says it has no owners" "no owners"
fresh_home; : > "$(OWNERS_FILE)"
expect_fail "an empty owners file" owners
fresh_home; grep -v '^owner' "$(OWNERS_FILE)" > "$T/o"; cp "$T/o" "$(OWNERS_FILE)"
expect_fail "alias lines with no owner lines" owners
# Each case appends one bad line to a good file.
bad_line() {  # $1 = label, $2 = the line
  fresh_home; printf '%s\n' "$2" >> "$(OWNERS_FILE)"
  expect_fail "$1" owners
  output_has "  and names the line" "$2"
}
bad_line "an unknown keyword"                 "maintainer someone github-someone identity-someone"
bad_line "an owner line short of a field"     "owner someone github-$MAIN"
bad_line "an owner line with an extra field"  "owner someone github-$MAIN identity-$MAIN extra"
bad_line "an owner with an invalid name"      "owner some/one github-$MAIN identity-$MAIN"
bad_line "an owner routed to a bad alias"     "owner someone gitlab-$MAIN identity-$MAIN"
bad_line "an owner routed to plain github.com" "owner someone github.com identity-$MAIN"
bad_line "an identity file outside the folder" "owner someone github-$MAIN ../identity-$MAIN"
bad_line "an identity file with the wrong name" "owner someone github-$MAIN config"
bad_line "an alias line short of a field"     "alias github-someone"
bad_line "an alias with a bad name"           "alias gitlab.com $MAIN"
bad_line "an alias for a bad account"         "alias github-someone some/one"
bad_line "an alias naming another account"    "alias github-someone $MAIN"
bad_line "a second line for one owner"       "owner $MAIN github-$MAIN identity-$MAIN"
bad_line "a second line for one alias"        "alias github-$MAIN $MAIN"
bad_line "an owner using an undeclared alias" "owner someone github-someone identity-$MAIN"
fresh_home; grep -v '^alias github.com' "$(OWNERS_FILE)" > "$T/o"; cp "$T/o" "$(OWNERS_FILE)"
expect_fail "no alias line for plain github.com" owners
fresh_home; rm "$XDG_CONFIG_HOME/git/identity-$SECOND"
expect_fail "an owner whose identity file is missing" owners

echo "== owners and aliases really come from the file =="
fresh_home; printf 'owner someone github-%s identity-%s\n' "$MAIN" "$MAIN" >> "$(OWNERS_FILE)"
expect_fail "a listed owner the routing doesn't rewrite" rewrite
# With the owner gone from the file, its missing rewrites are no longer the check's concern.
fresh_home; grep -v "^owner $SECOND " "$(OWNERS_FILE)" > "$T/o"; cp "$T/o" "$(OWNERS_FILE)"
grep -v "github.com[:/]$SECOND/" "$XDG_CONFIG_HOME/git/config" > "$T/c"; cp "$T/c" "$XDG_CONFIG_HOME/git/config"
rm -rf "$HOME/src/$SECOND"
expect_pass "an owner the file doesn't list isn't checked"
fresh_home; printf 'someone\n' >> "$XDG_CONFIG_HOME/git/accounts"
expect_fail "an account no alias line uses" accounts
# Alias names may hold hyphens, as account names do. The owner comes back out of a routed
# URL, so a pattern that stopped at the hyphen would call this repo unrouted.
fresh_home
printf 'owner dash-co github-dash-co identity-%s\nalias github-dash-co dash-co\n' "$MAIN" >> "$(OWNERS_FILE)"
printf 'dash-co\n' >> "$XDG_CONFIG_HOME/git/accounts"
for f in "" .pub; do : > "$HOME/.ssh/id_ed25519_dash-co$f"; done
printf 'Host github-dash-co\n    HostName github.com\n    User git\n    IdentityFile ~/.ssh/id_ed25519_dash-co\n    IdentitiesOnly yes\n' >> "$HOME/.ssh/config.d/github.conf"
for form in "git@github.com:" "https://github.com/" "ssh://git@github.com/"; do
  printf '[url "git@github-dash-co:dash-co/"]\n\tinsteadOf = %sdash-co/\n' "$form" >> "$XDG_CONFIG_HOME/git/config"
  printf '[includeIf "hasconfig:remote.*.url:%sdash-co/**"]\n\tpath = ~/.config/git/identity-%s\n' "$form" "$MAIN" >> "$XDG_CONFIG_HOME/git/config"
done
mkdir -p "$HOME/src/dash-co/repo" && git -C "$HOME/src/dash-co/repo" init -q
git -C "$HOME/src/dash-co/repo" remote add origin "git@github.com:dash-co/repo.git"
expect_pass "an owner and alias with hyphens"

echo "== comment-only accounts and repo-roots behave as missing ones =="
# The whole output must match, not just the verdict: a comment-only file that passed for
# a different reason, or scanned something else, would still be a different result.
same_output() {  # $1 = label, $2 = the file, then check args: runs with $2 missing, then comment-only
  local label="$1" f="$2"; shift 2
  rm -f "$f";                        run_check "$@"; local o1="$OUT" r1="$RC"
  printf '# nothing here yet\n\n' > "$f"; run_check "$@"
  if [ "$RC" = "$r1" ] && [ "$OUT" = "$o1" ]; then ok "$label"; else
    bad "$label"; printf '         missing (exit %s):\n%s\n         comment-only (exit %s):\n%s\n' "$r1" "$o1" "$RC" "$OUT"
  fi
}
fresh_home; printf '# nothing here yet\n' > "$XDG_CONFIG_HOME/git/accounts"
expect_fail "a comment-only accounts file" accounts
output_lacks "  never reaches a pass" "all checks passed"
fresh_home; same_output "accounts: same output as a missing file" "$XDG_CONFIG_HOME/git/accounts"
fresh_home; printf '# nothing here yet\n' > "$XDG_CONFIG_HOME/git/repo-roots"
expect_pass "a comment-only repo-roots"
output_has "  scans the default root" "scanned 4 repos"
fresh_home; same_output "repo-roots: same output as a missing file" "$XDG_CONFIG_HOME/git/repo-roots" --verbose

echo "== global config and environment =="
fresh_home; printf '[user]\n\temail = leak@example.com\n' > "$HOME/.gitconfig"
expect_fail "user.email in ~/.gitconfig" gitconfig-identity
fresh_home; printf '[user]\n\tuseConfigOnly = true\n' > "$HOME/.gitconfig"
expect_pass "useConfigOnly alone in ~/.gitconfig is fine"
fresh_home; printf '[includeIf "gitdir:~/src/"]\n\tpath = ~/.gitconfig-old\n' > "$HOME/.gitconfig"
expect_fail "leftover includeIf in ~/.gitconfig" gitconfig-rules
fresh_home; printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$HOME/.gitconfig"
expect_fail "leftover insteadOf in ~/.gitconfig" gitconfig-rules
fresh_home; printf '[author]\n\temail = leak@example.com\n' >> "$XDG_CONFIG_HOME/git/config"
expect_fail "unconditional author.email in the global config" unconditional-identity
fresh_home; printf "[include]\n\tpath = ~/.config/git/identity-$MAIN\n" > "$HOME/.gitconfig"
expect_fail "unconditional include of an identity file" unconditional-identity
fresh_home; GIT_AUTHOR_EMAIL=leak@example.com expect_fail "identity environment variable" env-identity
fresh_home; GIT_CONFIG_GLOBAL="$HOME/other" expect_fail "GIT_CONFIG_GLOBAL set" layout
fresh_home; XDG_CONFIG_HOME="$HOME/elsewhere" expect_fail "non-default XDG_CONFIG_HOME" layout
fresh_home; printf "[user]\n\tsigningkey = ~/.ssh/id_ed25519_$SECOND\n" > "$XDG_CONFIG_HOME/git/local"
expect_fail "identity setting in ~/.config/git/local" local-file

echo "== SSH and keys =="
fresh_home; printf 'Host *\n    IdentityFile ~/.ssh/id_other\n' >> "$HOME/.ssh/config.d/github.conf"
expect_fail "second IdentityFile through Host *" ssh-identityfile
fresh_home; printf 'Host example\n    HostName example.invalid\n' > "$HOME/.ssh/config"
expect_fail "missing Include line" ssh-include
fresh_home; printf 'Host example\n    HostName example.invalid\nInclude %s/.ssh/config.d/github.conf\n' "$HOME" > "$HOME/.ssh/config"
expect_fail "Include after the first Host" ssh-include
fresh_home; { printf 'IdentitiesOnly no\n'; cat "$HOME/.ssh/config"; } > "$T/sc" && cp "$T/sc" "$HOME/.ssh/config"
expect_fail "IdentitiesOnly no set before the Include" ssh-identitiesonly
fresh_home; printf 'Include "%s/.ssh/config.d/github.conf"\n' "$HOME" > "$HOME/.ssh/config"
expect_pass "a quoted Include is accepted"
fresh_home; printf 'Include=%s/.ssh/config.d/github.conf\n' "$HOME" > "$HOME/.ssh/config"
expect_pass "an Include= form is accepted"
fresh_home; rm "$HOME/.ssh/id_ed25519_$SECOND"
expect_fail "missing key for a declared account" key-missing
fresh_home; rm "$HOME/.ssh/id_ed25519_$ABSENT"*
printf "$MAIN\n$SECOND\n" > "$XDG_CONFIG_HOME/git/accounts"
expect_pass "missing key for an UNdeclared account is fine"
fresh_home; rm "$XDG_CONFIG_HOME/git/accounts"
expect_fail "no accounts file" accounts

echo "== rewrites =="
fresh_home; grep -v "insteadOf = https://github.com/$SECOND/" "$XDG_CONFIG_HOME/git/config" > "$T/c" && cp "$T/c" "$XDG_CONFIG_HOME/git/config"
expect_fail "routed owner left on https" https-route

echo "== repo scan =="
R() { printf '%s/src/%s/repo' "$HOME" "$MAIN"; }
fresh_home; git -C "$(R)" config --local user.name "Someone"
expect_fail "repo-local name without an identity include" repo-local-identity
fresh_home; git -C "$(R)" remote add other "git@github.com:$SECOND/x.git"
expect_fail "mixed-owner repo without an identity include" repo-ambiguous
fresh_home; git -C "$(R)" remote add other "git@github.com:$SECOND/x.git"
git -C "$(R)" config --local include.path "~/.config/git/identity-$MAIN"
expect_pass "mixed-owner repo WITH an identity include"
fresh_home; git -C "$(R)" config --local --add remote.origin.pushurl "https://github.com/$ABSENT/x.git"
expect_fail "pushurl names a different owner" repo-ambiguous
fresh_home; git -C "$(R)" config --local include.path "~/.config/git/identity-$MAIN"
git -C "$(R)" config --local user.email "leak@example.com"
expect_fail "identity include plus a conflicting user.email" repo-local-identity
# insteadOf applies once, to the URL as written, longest match winning: a repo-local
# rule matching more of the original URL beats the component's owner-wide rule.
fresh_home; git -C "$(R)" config --local url."https://github.com/$MAIN/repo".insteadOf "git@github.com:$MAIN/repo"
expect_fail "repo-local rewrite back to https" repo-route
fresh_home; git -C "$(R)" config --local --add remote.origin.pushurl "https://github.com/someone-else/x.git"
expect_fail "routed owner plus an unrouted GitHub owner" repo-ambiguous
fresh_home; git -C "$(R)" remote add other "git@github.com:$SECOND/x.git"
git -C "$(R)" config --local include.path "/nonexistent/identity-$SECOND"
expect_fail "an include of a nonexistent identity file" repo-ambiguous
fresh_home; mkdir -p "$HOME/src/x/broken" && git -C "$HOME/src/x/broken" init -q && printf '[core\n' >> "$HOME/src/x/broken/.git/config"
expect_fail "a repo git can't read" repo-unreadable
# Root can list a chmod-000 folder (CI's git 2.43 job runs in a container as root), so
# the case can only be staged by an ordinary user.
if [ "$(id -u)" = 0 ]; then
  echo "  skip unlistable-folder case: running as root, which can list any folder"
else
  fresh_home; mkdir -p "$HOME/src/x/locked" && chmod 000 "$HOME/src/x/locked"
  expect_pass "an unlistable folder is reported, not failed"
  output_has "unlistable folder reported" "[unreadable] $HOME/src/x/locked"
  chmod 755 "$HOME/src/x/locked"
fi
# gitdir: matches the resolved path, and on macOS the temp dir sits under /var, a symlink.
fresh_home; printf "[includeIf \"gitdir:%s/src/\"]\n\tpath = ~/.config/git/identity-$MAIN\n" "$(cd "$HOME" && pwd -P)" >> "$XDG_CONFIG_HOME/git/config"
mkdir -p "$HOME/src/x/norem" && git -C "$HOME/src/x/norem" init -q
expect_fail "a folder rule gives a no-remote repo an identity" repo-identity-source
fresh_home; git -C "$(R)" config --local url."https://mirror.example/$MAIN/".pushInsteadOf "git@github.com:$MAIN/"
expect_fail "pushInsteadOf sends a routed push to https" repo-route
fresh_home; git -C "$(R)" config --local url."git@github-$SECOND:$SECOND/".pushInsteadOf "git@github.com:$MAIN/"
expect_fail "pushInsteadOf sends the push to another owner" repo-ambiguous
fresh_home; git -C "$(R)" remote add other "git@github.com:$SECOND/x.git"
git -C "$(R)" config --local include.path ".config/git/identity-$SECOND"
# Run from $HOME, where the relative path WOULD name a real identity file: git resolves
# it from .git/ instead, where it names nothing. Not in a subshell: its tally would be lost.
cd "$HOME" || exit 2
expect_fail "a relative include resolves from .git, not the working directory" repo-ambiguous
cd "$DOTFILES" || exit 2
fresh_home; git -C "$(R)" config --local commit.gpgsign false
expect_fail "repo-local commit.gpgsign=false" repo-signing
fresh_home; git -C "$(R)" config --local gpg.ssh.allowedSignersFile "/tmp/other"
expect_fail "repo-local allowedSignersFile" repo-signing

echo "== no-identity repos are listed, not failed =="
fresh_home
mkdir -p "$HOME/src/x/norem" "$HOME/src/x/local" "$HOME/src/x/third"
git -C "$HOME/src/x/norem" init -q
git -C "$HOME/src/x/local" init -q; git -C "$HOME/src/x/local" remote add origin ../elsewhere
git -C "$HOME/src/x/third" init -q; git -C "$HOME/src/x/third" remote add origin https://github.com/someone-else/x.git
expect_pass "no remote, local-path-only and unrouted owner"
output_has "no-remote repo listed"        "[no-identity] $HOME/src/x/norem"
output_has "local-path repo listed"       "[no-identity] $HOME/src/x/local"
output_has "unrouted-owner repo listed"   "[no-identity] $HOME/src/x/third"
fresh_home; git -C "$(R)" remote add local ../elsewhere
expect_pass "a local-path remote beside a GitHub one is one owner"
# git itself ignores a .git folder with no HEAD (an empty .git/info left behind, say), so
# the check must not call it an unreadable repo.
fresh_home; mkdir -p "$HOME/src/x/stray/.git/info"
expect_pass "a .git folder without HEAD is not a repo"
output_lacks "  and isn't reported as unreadable" "[repo-unreadable] $HOME/src/x/stray"
# The other side of that rule: a HEAD that is a symlink to a branch with no commits yet
# (an older git layout) is a real repo, and must still be scanned.
fresh_home; S="$HOME/src/$MAIN/symhead"; mkdir -p "$S" && git -C "$S" init -q
git -C "$S" remote add origin "git@github.com:$MAIN/symhead.git"
rm "$S/.git/HEAD" && ln -s refs/heads/main "$S/.git/HEAD"
expect_pass "a repo with a dangling symlink HEAD" --verbose
output_has "  is still scanned" "scanned $S"

echo "== repo-roots: depth, layouts, missing roots =="
fresh_home
# ~/src/<owner>/<repo>/<worktree>, the bare-plus-worktrees layout, at depth 3.
B="$HOME/src/$ABSENT/wt"; mkdir -p "$B"
git init -q --bare "$B/.bare" && printf 'gitdir: ./.bare\n' > "$B/.git"
git -C "$B" remote add origin "git@github.com:$ABSENT/wt.git"
git -C "$HOME/src/$ABSENT/repo" -c commit.gpgsign=false commit -q --allow-empty -m init
git -C "$HOME/src/$ABSENT/repo" worktree add -q "$HOME/src/$ABSENT/repo/feature" 2>/dev/null
# A repo at depth 2 under a `~ 1` root must NOT be scanned.
mkdir -p "$HOME/deep/inner" && git -C "$HOME/deep/inner" init -q
mkdir -p "$HOME/shallow" && git -C "$HOME/shallow" init -q
printf '# roots\n%s/src 3\n%s 1\n%s/absent 2\n' "$HOME" "$HOME" "$HOME" > "$XDG_CONFIG_HOME/git/repo-roots"
expect_pass "mixed layouts and roots" --verbose
output_has  "bare-plus-worktrees container found" "$HOME/src/$ABSENT/wt"
output_has  "linked worktree found"               "$HOME/src/$ABSENT/repo/feature"
output_has  "depth-1 repo under ~ found"          "$HOME/shallow"
output_lacks "depth-2 repo under ~ 1 not scanned" "$HOME/deep/inner"
output_has  "missing root reported"               "[root-missing] $HOME/absent"
rm "$XDG_CONFIG_HOME/git/repo-roots"
run_check --verbose
output_has  "default root is ~/src at depth 3"     "$HOME/src/$ABSENT/repo/feature"

echo "== --live classifies each probe =="
# A stub ssh: -T answers come from $STUB/<alias>; anything else goes to the real ssh.
STUB="$T/stub"; mkdir -p "$STUB/bin"
cat > "$STUB/bin/ssh" <<EOF
#!/bin/sh
case " \$* " in
  *" -T "*) for a in "\$@"; do last="\$a"; done
            host="\${last#git@}"
            f="$STUB/answers/\$host"
            if [ -f "\$f" ]; then cat "\$f" >&2; exit "\$(cat "\$f.rc")"; fi
            echo "ssh: connect to host \$host port 22: Operation timed out" >&2; exit 255 ;;
  *) exec "$REAL_SSH" "\$@" ;;
esac
EOF
chmod +x "$STUB/bin/ssh"
answer() {  # $1 = alias, $2 = rc, $3 = text
  mkdir -p "$STUB/answers"; printf '%s\n' "$3" > "$STUB/answers/$1"; printf '%s\n' "$2" > "$STUB/answers/$1.rc"
}
hi()     { answer "$1" 1 "Hi $2! You've successfully authenticated, but GitHub does not provide shell access."; }
denied() { answer "$1" 255 "git@github.com: Permission denied (publickey)."; }

fresh_home
hi github.com $MAIN; hi github-$MAIN $MAIN; hi github-$SECOND $SECOND; hi github-$ABSENT $ABSENT
PATH="$STUB/bin:$PATH" expect_pass "all declared accounts log in as themselves" --live
output_lacks "--live does not say untested" "authentication: not tested"
denied github-$ABSENT
printf "$MAIN\n$SECOND\n" > "$XDG_CONFIG_HOME/git/accounts"; rm "$HOME/.ssh/id_ed25519_$ABSENT"*
PATH="$STUB/bin:$PATH" expect_pass "an undeclared account is refused, as required" --live
hi github-$ABSENT $ABSENT
PATH="$STUB/bin:$PATH" expect_fail "an undeclared account that logs in" live-refused-expected --live
hi github-$ABSENT $ABSENT; hi github-$SECOND $MAIN
PATH="$STUB/bin:$PATH" expect_fail "a declared alias logs in as the wrong account" live-login --live
hi github-$SECOND $SECOND; rm -f "$STUB/answers/github-$MAIN" "$STUB/answers/github-$MAIN.rc"
PATH="$STUB/bin:$PATH" expect_fail "a timeout is inconclusive, never a pass" live-inconclusive --live
denied github-$ABSENT; rm -f "$STUB/answers/github-$ABSENT"; answer github-$ABSENT 255 "Host key verification failed."
hi github-$MAIN $MAIN
PATH="$STUB/bin:$PATH" expect_fail "a host-key failure is not a refusal" live-inconclusive --live

echo "== failure messages point at the runbook =="
fresh_home; printf '[user]\n\temail = leak@example.com\n' > "$HOME/.gitconfig"
run_check
output_has "names the guide and its section" 'docs/git-identity.md: "The check failed"'

# A suite that silently checks nothing must not pass.
[ "$PASS" -ge 45 ] || bad "only $PASS checks ran: the suite exercised less than it should"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
