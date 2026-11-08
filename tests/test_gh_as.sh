#!/usr/bin/env bash
#
# gh-as runs one gh command as a chosen account on github.com, without switching gh's
# active account and without ever showing the token.
#
# A stub gh stands in for the real one: `gh auth token` answers from a scripted token
# and exit status, and any other call records its arguments and the GH_TOKEN it was
# given, then exits with a scripted status. So every assertion is about what gh-as
# passed and printed, and nothing reaches GitHub.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH_AS="$DOTFILES/bin/gh-as"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; printf '         want: %s\n          got: %s\n' "$2" "$3"; fi; }

T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

TOKEN="fixture-token-value"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/bin/sh
if [ "\$1" = auth ] && [ "\$2" = token ]; then
  printf '%s\n' "\$*" > "$T/token-args"
  [ -n "\${STUB_TOKEN_STDERR:-}" ] && printf '%s\n' "\$STUB_TOKEN_STDERR" >&2
  printf '%s' "\${STUB_TOKEN-$TOKEN}"
  exit "\${STUB_TOKEN_RC:-0}"
fi
: > "$T/ran"
for a in "\$@"; do printf '%s\n' "\$a"; done > "$T/args"
printf '%s' "\${GH_TOKEN:-}" > "$T/token-seen"
echo "stub gh output"
exit "\${STUB_RC:-0}"
EOF
chmod +x "$T/bin/gh" || { echo "stub setup failed" >&2; exit 2; }
# Every case must reach the stub, never the real gh with real stored tokens.
[ "$(PATH="$T/bin:$PATH" command -v gh)" = "$T/bin/gh" ] || { echo "stub gh is not first on PATH" >&2; exit 2; }

# A clean gh environment, cleared once here and not inside run(): a case that sets
# GH_HOST or GH_REPO on purpose must reach gh-as with it.
unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_REPO GH_ENTERPRISE_TOKEN

# Runs gh-as with the stub first on PATH; leaves stdout and stderr in $OUT and the exit
# status in $RC.
run() {
  rm -f "$T/ran" "$T/args" "$T/token-args" "$T/token-seen"
  OUT="$(PATH="$T/bin:$PATH" "$@" 2>&1)"
  RC=$?
}
ran()      { if [ -e "$T/ran" ]; then ok "$1"; else bad "$1"; fi; }
# A refusal must come before the token lookup, so neither marker may exist.
not_ran()  { if [ -e "$T/ran" ] || [ -e "$T/token-args" ]; then bad "$1"; else ok "$1"; fi; }
not_ran_cmd() { if [ -e "$T/ran" ]; then bad "$1"; else ok "$1"; fi; }  # the lookup itself may have run
no_token() { case "$OUT" in *"$TOKEN"*) bad "$1"; printf '         token leaked: %s\n' "$OUT" ;; *) ok "$1" ;; esac; }

[ -x "$GH_AS" ] || bad "bin/gh-as exists and is executable"

echo "== the normal path =="
run "$GH_AS" bob api user --jq .login
same "exits with gh's status" 0 "$RC"
same "token looked up for that account on github.com" \
  "auth token --hostname github.com --user bob" "$(cat "$T/token-args" 2>/dev/null)"
same "gh receives the token in GH_TOKEN" "$TOKEN" "$(cat "$T/token-seen" 2>/dev/null)"
same "arguments pass through unchanged" "api
user
--jq
.login" "$(cat "$T/args" 2>/dev/null)"
same "gh's output comes through" "stub gh output" "$OUT"
no_token "token never printed"

echo "== awkward arguments survive intact =="
run "$GH_AS" alice pr create --title "it's a \"quoted\" title" --body 'two  spaces'
same "spaces and quotes preserved" "pr
create
--title
it's a \"quoted\" title
--body
two  spaces" "$(cat "$T/args" 2>/dev/null)"

echo "== gh's exit status is returned =="
STUB_RC=4 run "$GH_AS" alice repo view
same "non-zero status passed back" 4 "$RC"

echo "== refusals: gh never runs =="
STUB_TOKEN_RC=1 STUB_TOKEN_STDERR="no oauth token found for github.com account nobody" run "$GH_AS" nobody api user
same "failed lookup exits 1" 1 "$RC"
not_ran_cmd "failed lookup: gh not run"
STUB_TOKEN="" run "$GH_AS" alice api user
same "empty token exits 1" 1 "$RC"
not_ran_cmd "empty token: gh not run"
GH_HOST=ghe.example.com run "$GH_AS" alice api user
same "GH_HOST for another host exits 2" 2 "$RC"
not_ran "GH_HOST for another host: no lookup, gh not run"
GH_HOST=github.com run "$GH_AS" alice api user
same "GH_HOST=github.com is fine" 0 "$RC"
GH_REPO=ghe.example.com/team/repo run "$GH_AS" alice repo view
same "GH_REPO on another host exits 2" 2 "$RC"
not_ran "GH_REPO on another host: no lookup, gh not run"
GH_REPO=alice/widgets run "$GH_AS" alice repo view
same "GH_REPO as OWNER/REPO is fine" 0 "$RC"
GH_REPO=github.com/alice/widgets run "$GH_AS" alice repo view
same "GH_REPO qualified with github.com is fine" 0 "$RC"
run "$GH_AS"
same "no account: usage, exit 2" 2 "$RC"
not_ran "no account: no lookup, gh not run"
run "$GH_AS" alice
same "account but no command: usage, exit 2" 2 "$RC"

echo "== arguments are never second-guessed =="
run "$GH_AS" alice pr create --body "see --hostname=other.example for details"
same "a body mentioning --hostname passes through" 0 "$RC"
ran "the command ran"

echo "== gh auth is refused: auth token would print the injected token =="
run "$GH_AS" alice auth token --hostname github.com
same "auth exits 2" 2 "$RC"
not_ran "auth: no lookup, gh not run"
no_token "auth: token not printed"

echo "== account names =="
run "$GH_AS" "" api user
same "empty account exits 2" 2 "$RC"
not_ran "empty account: no lookup, gh not run"
run "$GH_AS" "-x" api user
same "an option-like account exits 2" 2 "$RC"

echo "== tracing never shows the token =="
rm -f "$T/ran"
OUT="$(PATH="$T/bin:$PATH" bash -x "$GH_AS" alice api user 2>&1)"; RC=$?
same "runs under bash -x" 0 "$RC"
no_token "bash -x does not print the token"
# SHELLOPTS is readonly inside bash, so it is set through env: a child bash imports it
# from its environment and starts with xtrace on. The "+ " lines prove tracing really
# was on, so the no-token assertion is not passing vacuously.
OUT="$(env SHELLOPTS=xtrace PATH="$T/bin:$PATH" bash "$GH_AS" alice api user 2>&1)"
case "$OUT" in *"+ set +x"*) ok "inherited xtrace was really on" ;; *) bad "inherited xtrace was really on" ;; esac
no_token "inherited xtrace does not print the token"

echo "== the token never shows, even when a lookup fails loudly =="
STUB_TOKEN_RC=1 STUB_TOKEN="$TOKEN" run "$GH_AS" alice api user
no_token "token from a failed lookup not printed"

# A suite that silently checks nothing must not pass.
[ "$PASS" -ge 20 ] || bad "only $PASS checks ran: the suite exercised less than it should"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
