#!/usr/bin/env bash
#
# The identity component routes by owner, and only git can say whether it does.
#
# Every assertion here asks git itself — the URL it will actually fetch from and push
# to, the author and committer it will actually write, the key it will actually sign
# with — in a throwaway HOME that holds nothing but the component and fixture keys.
# Nothing touches the network: `ls-remote --get-url` and `remote get-url` only rewrite.
#
# The negative cases matter most. A repo with no remote, a local-path remote or an
# unknown owner must REFUSE to commit, because a refusal is what stands between a
# misrouted repo and a commit carrying the wrong name.
#
# Usage: tests/test_git_identity.sh [manual|installed]
#   manual     place the component files into the temp HOME by hand (the default)
#   installed  populate the temp HOME with `setup.sh --git-identity`, so the same
#              assertions prove what the installer actually puts there
#
# Settings, so the same assertions can run against any data folder:
#   IDENTITY_DIR       the data folder (default: tests/fixtures/identity)
#   IDENTITY_EXPECTED  what it should produce (default: tests/fixtures/identity-expected.sh)

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-manual}"
IDENTITY_DIR="${IDENTITY_DIR:-$DOTFILES/tests/fixtures/identity}"
IDENTITY_EXPECTED="${IDENTITY_EXPECTED:-$DOTFILES/tests/fixtures/identity-expected.sh}"
[ -f "$IDENTITY_EXPECTED" ] || { echo "no expected values: $IDENTITY_EXPECTED" >&2; exit 2; }
# shellcheck source=fixtures/identity-expected.sh
. "$IDENTITY_EXPECTED"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
# Compares a command's output to what is expected, and prints both on a mismatch: a
# routing failure that says only "FAIL" sends you hunting for which URL came back.
same() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n          got: %s\n' "$2" "$3"; fi
}

# Stop if the temp dir can't be made. Carrying on with an empty $T would create
# directories and keys under /home.
T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

# --- Isolation ---
# Only the temp HOME's config may be read. GIT_CONFIG_NOSYSTEM drops the system file;
# GIT_CONFIG_GLOBAL is unset because it would REPLACE the global pair; every identity
# variable is unset because git prefers them to any config. SSH_AUTH_SOCK goes too: the
# signing contract is private-key paths, which must work with no agent at all.
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME \
      GIT_COMMITTER_EMAIL EMAIL SSH_AUTH_SOCK GIT_SSH_COMMAND
# Repository-selection and injected-config variables override `git -C`: an inherited
# GIT_DIR would aim every fixture write below at a real repository.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
      GIT_CONFIG GIT_PREFIX
# An empty template directory, so `git init` copies no hooks into the fixtures: an
# inherited GIT_TEMPLATE_DIR with a pre-commit hook would otherwise run during the test
# commits. And the C locale, because the refusal check matches git's English message.
mkdir -p "$T/empty-template"
export GIT_TEMPLATE_DIR="$T/empty-template" LC_ALL=C
unset LANGUAGE
mkdir -p "$HOME/.ssh" "$XDG_CONFIG_HOME/git"
[ "$HOME" != "$(eval echo ~"$(id -un)")" ] || { echo "REFUSING: HOME is the live home" >&2; exit 2; }

# One key per signing account named in the expected values.
for a in $(printf '%s\n' "$EXPECTED_IDENTITIES" | cut -d'|' -f4 | sort -u); do
  ssh-keygen -q -t ed25519 -N '' -C "fixture-$a" -f "$HOME/.ssh/id_ed25519_$a" || { echo "ssh-keygen failed" >&2; exit 2; }
done
fp() { ssh-keygen -lf "$1" | awk '{print $2}'; }

# Verification reads a signer file made here, passed with -c at verify time, never the
# data folder's: that file can hold real keys, and in an installed HOME it is a link into
# the data folder, which a test must not write through.
SIGNERS="$T/fixture_signers"
printf '%s\n' "$EXPECTED_IDENTITIES" | while IFS='|' read -r _ _ email signer _; do
  printf '%s %s\n' "$email" "$(cut -d' ' -f1,2 "$HOME/.ssh/id_ed25519_$signer.pub")"
done > "$SIGNERS"

# --- Install ---
case "$MODE" in
  manual)
    cp "$IDENTITY_DIR"/git/config "$IDENTITY_DIR"/git/identity-* "$XDG_CONFIG_HOME/git/" \
      || bad "the data folder has git/config and identity files"
    ;;
  installed)
    if ! env -i PATH="$PATH" HOME="$HOME" \
           bash "$DOTFILES/setup.sh" --git-identity --identity-dir "$IDENTITY_DIR" >"$T/setup.out" 2>&1; then
      bad "setup.sh --git-identity installs into the temp HOME"; sed 's/^/         /' "$T/setup.out"
    else
      ok "setup.sh --git-identity installs into the temp HOME"
      [ -L "$XDG_CONFIG_HOME/git/config" ] && ok "the installed config is a link" || bad "the installed config is a link"
    fi
    ;;
  *) echo "unknown mode: $MODE" >&2; exit 2 ;;
esac

# --- Expected values, one line per identity: name|email|account whose key signs ---
expected_line() { printf '%s\n' "$EXPECTED_IDENTITIES" | awk -F'|' -v o="$1" '$1 == o'; }
expect()   { expected_line "$1" | cut -d'|' -f2-4; }
alias_of() { expected_line "$1" | cut -d'|' -f5; }
[ -n "$(expect "$MAIN")" ] && [ -n "$(expect "$ORG")" ] && [ -n "$(expect "$SECOND")" ] && [ -n "$(expect "$ABSENT")" ] \
  || { echo "$IDENTITY_EXPECTED: an owner has no expected identity" >&2; exit 2; }

# Sets $r to a fresh repo, or stops the run. It is not called as r="$(…)": a failure
# inside a subshell can't stop the script, and an empty $r makes `git -C ""` act on
# whatever directory the test was started from.
mkdir -p "$T/repos"
newrepo() {
  r="$(mktemp -d "$T/repos/r.XXXXXX")" && [ -d "$r" ] && git -C "$r" init -q && [ -d "$r/.git" ] \
    || { echo "fixture repo creation failed" >&2; exit 2; }
}

# Identity as one unit: author, committer and signing key must all be the one identity.
check_identity() {  # $1 = label, $2 = repo, $3 = owner
  local IFS='|'; set -- "$1" "$2" $(expect "$3")
  local label="$1" r="$2" name="$3" email="$4" signer="$5"
  same "$label: author"    "$name <$email>" "$(git -C "$r" var GIT_AUTHOR_IDENT 2>/dev/null | sed 's/ [0-9]* [-+][0-9]*$//')"
  same "$label: committer" "$name <$email>" "$(git -C "$r" var GIT_COMMITTER_IDENT 2>/dev/null | sed 's/ [0-9]* [-+][0-9]*$//')"
  same "$label: signing key" "~/.ssh/id_ed25519_$signer" "$(git -C "$r" config user.signingkey)"
}

# A real commit, signed with the private-key path, then verified against fixture keys.
check_signed_commit() {  # $1 = label, $2 = repo, $3 = owner
  local IFS='|'; set -- "$1" "$2" $(expect "$3")
  local label="$1" r="$2" name="$3" email="$4" signer="$5"
  # Only a key this suite generated may sign. On real data, a wrong path could be a real key.
  local key; key="$(git -C "$r" config user.signingkey)"
  if [ "$key" != "~/.ssh/id_ed25519_$signer" ]; then
    bad "$label: not signing with $key"; return
  fi
  if git -C "$r" commit -q --allow-empty -m "fixture" </dev/null 2>"$T/commit.err"; then
    ok "$label: commit succeeds"
  else
    bad "$label: commit succeeds"; sed 's/^/         /' "$T/commit.err"; return
  fi
  local log; log="$(git -C "$r" -c gpg.ssh.allowedSignersFile="$SIGNERS" log -1 --format='%an|%ae|%cn|%ce|%G?|%GF')"
  same "$label: signed commit" "$name|$email|$name|$email|G|$(fp "$HOME/.ssh/id_ed25519_$signer")" "$log"
}

# A refusal must be for a MISSING IDENTITY. With no identity there is also no signing
# key, so a commit would fail at signing anyway, and a check that only looked for "the
# commit failed" would pass even with useConfigOnly gone. Signing is switched off for
# the probe, and the failure must be git's own identity refusal.
refuses_commit() {  # $1 = label, $2 = repo
  if git -C "$2" var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
    bad "$1: no author identity resolves"
  else
    ok "$1: no author identity resolves"
  fi
  if git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m "should not land" \
       </dev/null >/dev/null 2>"$T/refuse.err"; then
    bad "$1: commit is refused"
  elif grep -qiE 'Author identity unknown|Please tell me who you are|no email was given' "$T/refuse.err"; then
    ok "$1: commit is refused for a missing identity"
  else
    bad "$1: commit is refused for a missing identity"; sed 's/^/         /' "$T/refuse.err"
  fi
}

echo "== each owner, each URL form: rewritten transport and identity =="
for owner in $MAIN $ORG $SECOND $ABSENT; do
  want="git@$(alias_of "$owner"):$owner/x.git"
  for url in "git@github.com:$owner/x.git" "https://github.com/$owner/x.git" \
             "ssh://git@github.com/$owner/x.git" "git@$(alias_of "$owner"):$owner/x.git"; do
    newrepo; git -C "$r" remote add origin "$url"
    same "$owner [$url]: fetch URL" "$want" "$(git -C "$r" ls-remote --get-url origin)"
    same "$owner [$url]: push URL"  "$want" "$(git -C "$r" remote get-url --all --push origin)"
    check_identity "$owner [$url]" "$r" "$owner"
  done
  check_signed_commit "$owner" "$r" "$owner"
done

echo "== push destinations: pushurl and several push URLs are rewritten too =="
newrepo; git -C "$r" remote add origin "git@github.com:$MAIN/x.git"
git -C "$r" remote set-url --push origin "https://github.com/$SECOND/y.git"
same "pushurl to another owner is rewritten" "git@github-$SECOND:$SECOND/y.git" "$(git -C "$r" remote get-url --all --push origin)"
newrepo; git -C "$r" remote add origin "git@github.com:$MAIN/x.git"
git -C "$r" remote set-url --add --push origin "https://github.com/$MAIN/x.git"
git -C "$r" remote set-url --add --push origin "git@github.com:$ABSENT/z.git"
same "every push URL is rewritten" \
  "git@github-$MAIN:$MAIN/x.git
git@github-$ABSENT:$ABSENT/z.git" "$(git -C "$r" remote get-url --all --push origin)"

echo "== bare repos and linked worktrees resolve like any other =="
b="$T/repos/bare.git"; git init -q --bare "$b"; git -C "$b" remote add origin "git@github.com:$SECOND/x.git"
check_identity "bare repo" "$b" $SECOND
newrepo; git -C "$r" remote add origin "git@github.com:$ABSENT/x.git"
check_signed_commit "worktree's main repo" "$r" $ABSENT
git -C "$r" worktree add -q "$T/repos/wt" 2>/dev/null
check_identity "linked worktree" "$T/repos/wt" $ABSENT

echo "== no identity: these must refuse to commit =="
same "useConfigOnly is on" "true" "$(git -C "$T" config --global user.useConfigOnly)"
newrepo
refuses_commit "no remote" "$r"
mkdir -p "$HOME/src/$MAIN"; r="$HOME/src/$MAIN/stranger"; git init -q "$r"
git -C "$r" remote add origin "git@github.com:someone-else/x.git"
refuses_commit "unknown owner, under the main account's folder" "$r"
newrepo; git -C "$r" remote add origin "https://github.com/someone-else/x.git"
same "unknown owner keeps its https URL" "https://github.com/someone-else/x.git" "$(git -C "$r" ls-remote --get-url origin)"
refuses_commit "unknown owner over https" "$r"
newrepo; git -C "$r" remote add origin "../elsewhere"
refuses_commit "only a local-path remote" "$r"

echo "== a local-path remote beside a GitHub one changes nothing =="
newrepo; git -C "$r" remote add origin "git@github.com:$MAIN/x.git"
git -C "$r" remote add local "../elsewhere"
check_identity "GitHub remote plus local path" "$r" $MAIN

echo "== an explicit identity include supplies a whole identity =="
newrepo; git -C "$r" config --local include.path "~/.config/git/identity-$SECOND"
check_signed_commit "no remote, identity include" "$r" $SECOND
newrepo; git -C "$r" remote add origin "git@github.com:$MAIN/x.git"
git -C "$r" remote add other "git@github.com:$SECOND/y.git"
# Without an include, the later global rule (the second account) wins. The include picks the
# OTHER owner, so this passes only if the repo-local include really overrides.
check_identity "mixed owners, no include: last global rule wins" "$r" $SECOND
git -C "$r" config --local include.path "~/.config/git/identity-$MAIN"
check_identity "mixed owners, identity include overrides" "$r" $MAIN

# A suite that silently checks nothing must not pass.
[ "$PASS" -ge 60 ] || bad "only $PASS checks ran: the suite exercised less than it should"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
