#!/usr/bin/env bash
#
# git-identity-audit checks every machine from the machine that runs the audit, and scans
# commit history for your own addresses in the wrong place.
#
# A fake home for that machine and two fake remote machines live under one temp dir. A stub `ssh` runs a
# "remote" command locally, with HOME set to that machine's fake home, so the audit's
# real remote path is exercised without a network. The fixtures use made-up accounts
# (alice owning alice/* and acme/*, bob owning bob/*), which also proves the audit takes
# every account name from configuration and hard-codes none.
#
# IDENTITY_DIR names a data folder (default: tests/fixtures/identity). Its owners file
# supplies the names the audit's code must not contain, so no list of them ships here.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="$DOTFILES/bin/git-identity-audit"
IDENTITY_DIR="${IDENTITY_DIR:-$DOTFILES/tests/fixtures/identity}"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d)" && [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$T"' EXIT

unset GIT_CONFIG_GLOBAL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME \
      GIT_COMMITTER_EMAIL EMAIL SSH_AUTH_SOCK GIT_SSH_COMMAND GIT_DIR GIT_WORK_TREE \
      GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_CONFIG GIT_PREFIX LANGUAGE
mkdir -p "$T/empty-template"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_TEMPLATE_DIR="$T/empty-template" LC_ALL=C

REAL_SSH="$(command -v ssh)" || { echo "ssh not found" >&2; exit 2; }
NOREPLY_ALICE="1+alice@users.noreply.github.com"
NOREPLY_BOB="2+bob@users.noreply.github.com"
ACME="work@acme.example"

# The routing a component machine installs, in miniature: rewrites naming each owner's
# alias, and one identity file per owner.
write_routing() {  # $1 = a home
  local g="$1/.config/git"; mkdir -p "$g"
  printf '[user]\n\tname = alice\n\temail = %s\n\tsigningkey = ~/.ssh/id_ed25519_alice\n' "$NOREPLY_ALICE" > "$g/identity-alice"
  printf '[user]\n\tname = Acme Person\n\temail = %s\n\tsigningkey = ~/.ssh/id_ed25519_alice\n' "$ACME" > "$g/identity-acme"
  printf '[user]\n\tname = bob\n\temail = %s\n\tsigningkey = ~/.ssh/id_ed25519_bob\n' "$NOREPLY_BOB" > "$g/identity-bob"
  {
    printf '[user]\n\tuseConfigOnly = true\n'
    printf '[url "git@github-alice:alice/"]\n\tinsteadOf = git@github.com:alice/\n'
    printf '[url "git@github-alice:acme/"]\n\tinsteadOf = git@github.com:acme/\n'
    printf '[url "git@github-bob:bob/"]\n\tinsteadOf = git@github.com:bob/\n'
    printf '[includeIf "hasconfig:remote.*.url:git@github.com:alice/**"]\n\tpath = ~/.config/git/identity-alice\n'
    printf '[includeIf "hasconfig:remote.*.url:git@github.com:acme/**"]\n\tpath = ~/.config/git/identity-acme\n'
    printf '[includeIf "hasconfig:remote.*.url:git@github.com:bob/**"]\n\tpath = ~/.config/git/identity-bob\n'
  } > "$g/config"
}

# A repo with a remote and commits by the given emails at the given dates. No signing:
# the history scan reads addresses and dates, not signatures.
mkrepo() {  # $1 = path, $2 = remote url, then pairs: email date
  local r="$1" url="$2"; shift 2
  mkdir -p "$r" && git -C "$r" init -q || { echo "fixture repo failed" >&2; exit 2; }
  [ -n "$url" ] && git -C "$r" remote add origin "$url"
  while [ "$#" -ge 2 ]; do
    GIT_AUTHOR_NAME=x GIT_AUTHOR_EMAIL="$1" GIT_COMMITTER_NAME=x GIT_COMMITTER_EMAIL="$1" \
      GIT_AUTHOR_DATE="$2T12:00:00Z" GIT_COMMITTER_DATE="$2T12:00:00Z" \
      git -C "$r" -c commit.gpgsign=false -c user.useConfigOnly=false commit -q --allow-empty -m "c $1"
    shift 2
  done
}

# The commit dates and the `since` line are made up. They are built from these so that a
# search of shipped files for a dated event finds only a real one.
Y=2026; PY=2025

# --- the machine that runs the audit ---
HUB="$T/hub"; mkdir -p "$HUB/.local/bin" "$HUB/repos"
write_routing "$HUB"
printf '%s/repos 2\n' "$HUB" > "$HUB/.config/git/repo-roots"
cat > "$HUB/.local/bin/git-identity-check" <<'EOF'
#!/bin/sh
echo "scanned 3 repos"; [ "${STUB_CHECK_RC:-0}" = 0 ] && echo "all checks passed" || echo "FAIL [ssh-include] stub"
exit "${STUB_CHECK_RC:-0}"
EOF
chmod +x "$HUB/.local/bin/git-identity-check"
mkrepo "$HUB/repos/a1" git@github.com:alice/a1.git "$NOREPLY_ALICE" $Y-01-01 me@real.example $Y-05-01
mkrepo "$HUB/repos/c1" git@github.com:acme/c1.git "$ACME" $Y-02-01 colleague@acme.example $Y-02-02 me+x@real.example $Y-03-01
mkrepo "$HUB/repos/b1" git@github.com:bob/b1.git "$NOREPLY_BOB" $Y-02-01 "$NOREPLY_ALICE" $Y-04-01
mkrepo "$HUB/repos/third" https://github.com/someone/else.git "user@box.example" $PY-12-01 stranger@else.example $PY-12-02
# alice's noreply in a acme repo: same account (alice owns acme), so nothing is exposed.
mkrepo "$HUB/repos/c2" git@github.com:acme/c2.git "$NOREPLY_ALICE" $Y-02-01
# A mirror with only a local-path remote: no owner, and a noreply address exposes nothing.
mkrepo "$HUB/repos/mirror" ../a1 "$NOREPLY_ALICE" $Y-02-01 me@real.example $Y-02-02
# The older noreply spelling (no number) is the same account: fine in its own repos and
# in an ownerless mirror, a leak in another account's repo.
git -C "$HUB/repos/a1" -c commit.gpgsign=false -c user.name=x -c user.email=alice@users.noreply.github.com commit -q --allow-empty -m v
mkrepo "$HUB/repos/mirror2" ../a1 alice@users.noreply.github.com $Y-02-01
mkrepo "$HUB/repos/b3" git@github.com:bob/b3.git alice@users.noreply.github.com $Y-02-01
# An identity include on a acme repo: the same account's noreply is still fine.
mkrepo "$HUB/repos/c3" git@github.com:acme/c3.git "$NOREPLY_ALICE" $Y-02-01 "$ACME" $Y-02-02
git -C "$HUB/repos/c3" config --local include.path "~/.config/git/identity-acme"
# Two identity includes: git uses the LAST, so acme's address is expected, not alice's.
mkrepo "$HUB/repos/a3" git@github.com:alice/a3.git "$ACME" $Y-02-01
git -C "$HUB/repos/a3" config --local --add include.path "~/.config/git/identity-alice"
git -C "$HUB/repos/a3" config --local --add include.path "~/.config/git/identity-acme"
# A remote supplied only through an included config file: bob owns it, so alice's
# noreply here ties the two accounts together.
mkrepo "$HUB/repos/b2" "" "$NOREPLY_ALICE" $Y-02-01
printf '[remote "origin"]\n\turl = git@github.com:bob/b2.git\n' > "$HUB/repos/b2/.git/remote.inc"
git -C "$HUB/repos/b2" config --local include.path remote.inc

# --- a component machine, "comp" ---
HOSTS="$T/hosts"; COMP="$HOSTS/comp"; mkdir -p "$COMP/.local/bin" "$COMP/src/alice"
write_routing "$COMP"
cp "$HUB/.local/bin/git-identity-check" "$COMP/.local/bin/"
mkrepo "$COMP/src/alice/x" git@github.com:alice/x.git "$NOREPLY_ALICE" $Y-06-01

# --- a standalone machine, "solo": alice only (owners alice and acme) ---
SOLO="$HOSTS/solo"; mkdir -p "$SOLO/.ssh" "$SOLO/.config/git" "$SOLO/repos"
cp "$HUB/.config/git/identity-alice" "$HUB/.config/git/identity-acme" "$SOLO/.config/git/"
write_solo() {
  {
    printf '[user]\n\tuseConfigOnly = true\n'
    printf '[url "git@github-alice:alice/"]\n\tinsteadOf = git@github.com:alice/\n'
    printf '[url "git@github-alice:acme/"]\n\tinsteadOf = git@github.com:acme/\n'
    printf '[includeIf "hasconfig:remote.*.url:git@github.com:alice/**"]\n\tpath = ~/.config/git/identity-alice\n'
    printf '[includeIf "hasconfig:remote.*.url:git@github.com:acme/**"]\n\tpath = ~/.config/git/identity-acme\n'
  } > "$SOLO/.gitconfig"
  printf 'Host github.com github-alice\n    HostName github.com\n    User git\n    IdentityFile ~/.ssh/id_ed25519_alice\n    IdentitiesOnly yes\n' > "$SOLO/.ssh/config"
}
write_solo
: > "$SOLO/.ssh/id_ed25519_alice"; : > "$SOLO/.ssh/id_ed25519_alice.pub"
mkrepo "$SOLO/repos/c" git@github.com:acme/c.git "$ACME" $Y-03-01
mkrepo "$SOLO/repos/p" git@github.com:alice/p.git "$NOREPLY_ALICE" $Y-03-01 "$ACME" $Y-03-02
# bob's noreply in a acme repo on solo. solo knows nothing of bob; the machine that runs the audit does.
mkrepo "$SOLO/repos/x" git@github.com:acme/x.git "$NOREPLY_BOB" $Y-03-03

# --- the audit's own config, on the machine that runs it ---
cat > "$HUB/.config/git/audit" <<EOF
# machines: machine <name> <local|ssh-host> <component|standalone> [<root>:<depth> ...]
machine hub local component
machine comp comp component
machine solo solo standalone ~/repos:2
standalone-accounts solo alice
mine me@real.example
mine me+*@real.example
mine user@*.example
mine $NOREPLY_BOB
mine alice@users.noreply.github.com
since $Y-09-15
EOF

# --- the stub ssh ---
# `ssh [opts] <host> <command…>` with a fixture host runs the command locally in that
# host's home, logging what it was sent. `-T … git@<alias>` answers from a table.
# Anything else (`-G`) goes to the real ssh.
mkdir -p "$T/bin" "$T/answers" "$T/sent"
cat > "$T/bin/ssh" <<EOF
#!/usr/bin/env bash
args=("\$@"); i=0; tee=0
while [ \$i -lt \${#args[@]} ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -o|-F|-i|-p|-l) i=\$((i+2)); continue ;;
    -T) tee=1; i=\$((i+1)); continue ;;
    -*) i=\$((i+1)); continue ;;
  esac
  break
done
host="\${args[\$i]:-}"
if [ -n "\$host" ] && [ -d "$HOSTS/\$host" ]; then
  cmd="\${args[*]:\$((i+1))}"
  printf '%s\n' "\$cmd" >> "$T/sent/\$host.args"
  stdin_copy="\$(mktemp)"; cat > "\$stdin_copy"; cat "\$stdin_copy" >> "$T/sent/\$host.stdin"
  sys_env=""; [ -f "$HOSTS/\$host/system.gitconfig" ] && sys_env="GIT_CONFIG_SYSTEM=$HOSTS/\$host/system.gitconfig GIT_CONFIG_NOSYSTEM="
  cd "$HOSTS/\$host" && env \$sys_env PATH="$HOSTS/\$host/bin:\$PATH" HOME="$HOSTS/\$host" XDG_CONFIG_HOME="$HOSTS/\$host/.config" bash -c "\$cmd" < "\$stdin_copy"; rc=\$?
  rm -f "\$stdin_copy"; exit \$rc
fi
if [ "\$tee" = 1 ]; then
  printf '%s\n' "\$*" >> "$T/sent/probes.args"
  alias="\${host#git@}"; f="$T/answers/\$alias"
  if [ -f "\$f" ]; then cat "\$f" >&2; exit 1; fi
  echo "ssh: connect to host \$alias port 22: Operation timed out" >&2; exit 255
fi
case " \$* " in *" -G "*) exec "$REAL_SSH" "\$@" ;; esac
# Any other host is unreachable: never let the suite touch the network.
echo "ssh: Could not resolve hostname \$host: nodename nor servname provided" >&2; exit 255
EOF
chmod +x "$T/bin/ssh"
[ "$(PATH="$T/bin:$PATH" command -v ssh)" = "$T/bin/ssh" ] || { echo "stub ssh not first on PATH" >&2; exit 2; }
printf 'Hi alice! You have successfully authenticated, but GitHub does not provide shell access.\n' > "$T/answers/github.com"
cp "$T/answers/github.com" "$T/answers/github-alice"

run_audit() { OUT="$(PATH="$T/bin:$PATH" HOME="$HUB" XDG_CONFIG_HOME="$HUB/.config" "$AUDIT" "$@" 2>&1)"; RC=$?; }
has()   { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1"; printf '         missing: %s\n' "$2"; printf '%s\n' "$OUT" | sed 's/^/         | /' | head -60; fi; }
lacks() { if printf '%s\n' "$OUT" | grep -qF -- "$2"; then bad "$1"; printf '         unexpected: %s\n' "$2"; else ok "$1"; fi; }
exits() { if [ "$RC" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $RC, wanted $2)"; fi; }

[ -x "$AUDIT" ] || bad "bin/git-identity-audit exists and is executable"

echo "== the code names no account: every name comes from configuration =="
# Anywhere in a line, one name per line, read from the owners file. A whole-word search
# would miss a name inside a key file such as id_ed25519_<name>. No names at all would
# make this pass by matching nothing, so that fails too; and copies with a planted name
# prove the search can find one.
OWNER_NAMES="$T/owner-names"
awk '$1 == "owner" { print $2 } $1 == "alias" { print $3 }' "$IDENTITY_DIR/owners" 2>/dev/null | sort -u > "$OWNER_NAMES"
names_in() { grep -iF -f "$OWNER_NAMES" "$1" >/dev/null; }
if [ -s "$OWNER_NAMES" ]; then ok "the owners file supplies names to search for"; else bad "the owners file supplies names to search for"; fi
if [ -f "$AUDIT" ] && [ -s "$OWNER_NAMES" ] && ! names_in "$AUDIT"; then
  ok "no account name in bin/git-identity-audit"
else
  bad "no account name in bin/git-identity-audit"
fi
cp "$AUDIT" "$T/planted-audit"; printf '# %s\n' "$(head -1 "$OWNER_NAMES")" >> "$T/planted-audit"
if names_in "$T/planted-audit"; then ok "  and the search finds a planted name"; else bad "  and the search finds a planted name"; fi
cp "$AUDIT" "$T/planted-key"; printf '# ~/.ssh/id_ed25519_%s\n' "$(head -1 "$OWNER_NAMES")" >> "$T/planted-key"
if names_in "$T/planted-key"; then ok "  and the search finds a name inside a key file name"; else bad "  and the search finds a name inside a key file name"; fi

echo "== a clean set of machines passes, with old leaks reported =="
run_audit
exits "clean audit exits 0" 0
has   "the auditing machine's own check ran"      "hub: setup ok"
has   "the component machine's check ran over ssh" "comp: setup ok"
has   "the standalone machine passed"              "solo: setup ok"
has   "my real address in an alice repo is an old leak"        "[leak-old] hub $HUB/repos/a1: me@real.example"
has   "a me+ address in a acme repo is an old leak"            "[leak-old] hub $HUB/repos/c1: me+x@real.example"
has   "alice's noreply in an bob repo is an old leak"      "[leak-old] hub $HUB/repos/b1: $NOREPLY_ALICE"
has   "a hostname address in a third-party repo is an old leak" "[leak-old] hub $HUB/repos/third: user@box.example"
lacks "the owner's own identity is not a leak"                 "$HUB/repos/a1: $NOREPLY_ALICE"
lacks "the acme identity in a acme repo is not a leak"         "$HUB/repos/c1: $ACME"
lacks "a colleague's address is not mine, so not a leak"       "colleague@acme.example"
lacks "a stranger's address is not mine, so not a leak"        "stranger@else.example"
lacks "an account's noreply in its own other owner's repo is not a leak" "$HUB/repos/c2: $NOREPLY_ALICE"
lacks "a noreply address in an ownerless mirror is not a leak"   "$HUB/repos/mirror: $NOREPLY_ALICE"
has   "a real address in an ownerless mirror still is"           "[leak-old] hub $HUB/repos/mirror: me@real.example"
has   "the acme identity in an alice repo on solo is an old leak" "[leak-old] solo $SOLO/repos/p: $ACME"
has   "live probes ran on solo"                    "solo: github-alice logged in as alice"
lacks "an include keeps the same account's noreply allowed"    "$HUB/repos/c3: $NOREPLY_ALICE"
lacks "the older noreply spelling is fine in its own repo"     "$HUB/repos/a1: alice@users.noreply.github.com"
lacks "  and in an ownerless mirror"                           "$HUB/repos/mirror2: alice@users.noreply.github.com"
has   "  but ties accounts in another account's repo"          "[leak-old] hub $HUB/repos/b3: alice@users.noreply.github.com"
if grep -q -- '-o UpdateHostKeys=no' "$T/sent/probes.args" && grep -q -- '-o ControlMaster=no' "$T/sent/probes.args" \
   && grep -q -- '-o StrictHostKeyChecking=yes' "$T/sent/probes.args"; then
  ok "live probes forbid known_hosts updates and control sockets"
else
  bad "live probes forbid known_hosts updates and control sockets"
fi
lacks "the LAST identity include is the one expected"          "$HUB/repos/a3: $ACME"
has   "a remote from an included file still names the owner"   "[leak-old] hub $HUB/repos/b2: $NOREPLY_ALICE"
has   "the auditing machine classifies solo's history with every account"   "[leak-old] solo $SOLO/repos/x: $NOREPLY_BOB"

echo "== nothing about other accounts reaches the standalone machine =="
if ! grep -q 'bob' "$T/sent/solo.args" "$T/sent/solo.stdin" 2>/dev/null && [ -s "$T/sent/solo.stdin" ]; then
  ok "solo was sent no bob name, in arguments or code"
else
  bad "solo was sent no bob name, in arguments or code"
fi
tree() { (cd "$1" && find . | sort; find . -type f -exec cksum {} + | sort); }
S0="$(tree "$SOLO")"; run_audit; S1="$(tree "$SOLO")"
if [ "$S0" = "$S1" ]; then ok "the audit wrote nothing anywhere in solo's home"; else bad "the audit wrote nothing anywhere in solo's home"; diff <(echo "$S0") <(echo "$S1") | head -5 | sed 's/^/         /'; fi
if ! grep -rq 'mine\|real.example\|box.example' "$T/sent/solo.args" 2>/dev/null; then
  ok "solo was sent none of my address patterns"
else
  bad "solo was sent none of my address patterns"
fi

echo "== a comment-only repo-roots behaves as a missing one =="
# On a component machine, repo-roots decides what the history scan reads. Comments alone
# must fall back to the default root, or the machine's history goes unscanned and passes.
mkrepo "$COMP/src/alice/y" git@github.com:alice/y.git me@real.example $Y-02-01
run_audit
has   "the default root is scanned with no repo-roots"          "[leak-old] comp $COMP/src/alice/y: me@real.example"
printf '# no roots yet\n' > "$COMP/.config/git/repo-roots"
run_audit
has   "  and with a comment-only one"                           "[leak-old] comp $COMP/src/alice/y: me@real.example"
rm -rf "$COMP/src/alice/y" "$COMP/.config/git/repo-roots"

echo "== failures =="
mkrepo "$HUB/repos/a2" git@github.com:alice/a2.git "$ACME" $Y-11-01
run_audit
exits "a leak dated after 'since' fails the audit" 1
has   "  and is named as new" "FAIL [leak-new] hub $HUB/repos/a2: $ACME"
rm -rf "$HUB/repos/a2"

STUB_CHECK_RC=1 run_audit
exits "a failing component check fails the audit" 1
has   "  and is named" "FAIL [check] hub"

printf '[url "git@github-bob:bob/"]\n\tinsteadOf = git@github.com:bob/\n' >> "$SOLO/.gitconfig"
run_audit; exits "a foreign account in solo's config fails" 1; has "  and is named" "FAIL [standalone-foreign] solo"
write_solo

# An ALLOWED owner routed through a FOREIGN account's alias: only the alias names the
# foreign account, so this is caught by the account check alone.
printf '[url "git@github-bob:alice/"]\n\tinsteadOf = ssh://git@github.com/alice/\n' >> "$SOLO/.gitconfig"
run_audit; exits "an allowed owner routed through a foreign alias fails" 1; has "  and is named" "FAIL [standalone-foreign] solo"
write_solo

printf '[user]\n\temail = me@real.example\n' >> "$SOLO/.gitconfig"
run_audit; exits "an unconditional identity on solo fails" 1; has "  and is named" "FAIL [unconditional-identity] solo"
write_solo

printf 'Host *\n    IdentityFile ~/.ssh/id_other\n' >> "$SOLO/.ssh/config"
run_audit; exits "an extra key on solo fails" 1; has "  and is named" "FAIL [ssh-identityfile] solo"
write_solo

git -C "$SOLO/repos/c" config --local user.email me@real.example
run_audit; exits "a repo-local identity on solo fails" 1; has "  and is named" "FAIL [repo-local-identity] solo"
git -C "$SOLO/repos/c" config --local --unset user.email

printf 'Hi bob! You have successfully authenticated.\n' > "$T/answers/github-alice"
run_audit; exits "a wrong live login on solo fails" 1; has "  and is named" "FAIL [live-login] solo"
cp "$T/answers/github.com" "$T/answers/github-alice"

rm -f "$T/answers/github-alice"
run_audit; exits "an inconclusive probe on solo fails" 1; has "  and is named" "FAIL [live-inconclusive] solo"
cp "$T/answers/github.com" "$T/answers/github-alice"

printf '[url "git@github-bob:"]\n\tinsteadOf = git@github.com:\n' >> "$SOLO/.gitconfig"
run_audit; exits "a catch-all rewrite to a foreign alias fails" 1; has "  and is named" "FAIL [standalone-foreign] solo"
write_solo

printf '[url "git@github-bob:bob/"]\n\tinsteadOf = git@github.com:bob/\n' > "$SOLO/system.gitconfig"
run_audit; exits "foreign routing in solo's SYSTEM config fails" 1; has "  and is named" "FAIL [standalone-foreign] solo"
rm -f "$SOLO/system.gitconfig"

mkdir -p "$SOLO/.ssh/config.d"; printf 'Host github-bob\n    HostName github.com\n' > "$SOLO/.ssh/config.d/foreign.conf"
{ printf 'Include config.d/foreign.conf\n'; cat "$SOLO/.ssh/config"; } > "$T/sc" && cp "$T/sc" "$SOLO/.ssh/config"
run_audit; exits "a foreign alias in an SSH-included file fails" 1; has "  and is named" "FAIL [standalone-foreign] solo"
rm -rf "$SOLO/.ssh/config.d"; write_solo

git -C "$SOLO/repos/c" remote add up https://github.com/someone/else.git
run_audit; exits "a repo mixing an allowed owner with an unrouted one fails" 1; has "  and is named" "FAIL [repo-ambiguous] solo"
git -C "$SOLO/repos/c" remote remove up

printf '[user]\n\tname = Not Me\n\temail = %s\n\tsigningkey = ~/.ssh/id_ed25519_alice\n' "$ACME" > "$SOLO/.config/git/identity-fake"
git -C "$SOLO/repos/c" config --local include.path "~/.config/git/identity-fake"
run_audit; exits "an include with an allowed email but another name fails" 1; has "  and is named" "FAIL [repo-include-foreign] solo"
git -C "$SOLO/repos/c" config --local --unset include.path; rm -f "$SOLO/.config/git/identity-fake"

mkdir -p "$SOLO/my ids"; cp "$SOLO/.config/git/identity-acme" "$SOLO/my ids/identity-acme"
git -C "$SOLO/repos/p" config --local include.path "$SOLO/my ids/identity-acme"
run_audit
lacks "an include path with a space still counts"  "FAIL [repo-ambiguous] solo"
lacks "  and its identity is the expected one"     "[leak-old] solo $SOLO/repos/p: $ACME"
git -C "$SOLO/repos/p" config --local --unset include.path; rm -rf "$SOLO/my ids"

sed -i.bak '/useConfigOnly/d' "$SOLO/.gitconfig" && rm -f "$SOLO/.gitconfig.bak"
run_audit; exits "losing useConfigOnly on solo fails" 1; has "  and is named" "FAIL [fallback-identity] solo"
write_solo

git -C "$SOLO/repos/c" remote add other git@github.com:alice/o.git
run_audit; exits "a mixed-owner repo on solo fails" 1; has "  and is named" "FAIL [repo-ambiguous] solo"
git -C "$SOLO/repos/c" remote remove other

git -C "$SOLO/repos/c" config --local include.path "~/.config/git/identity-acme"
git -C "$SOLO/repos/c" config --local committer.email me@real.example
run_audit; exits "an include plus a committer override on solo fails" 1; has "  and is named" "FAIL [repo-identity-mismatch] solo"
git -C "$SOLO/repos/c" config --local --unset committer.email; git -C "$SOLO/repos/c" config --local --unset include.path

mkrepo "$HUB/repos/broken" git@github.com:alice/broken.git "$NOREPLY_ALICE" $Y-01-01
rm -rf "$HUB/repos/broken/.git/objects/"??
run_audit; exits "an unreadable history fails" 1; has "  and is named" "FAIL [history-unreadable] hub $HUB/repos/broken"
rm -rf "$HUB/repos/broken"

# A machine whose remote run prints a complete, clean-looking answer and THEN fails: the
# exit status alone must fail it.
CR="$HOSTS/crashy"; mkdir -p "$CR/bin" "$CR/.local/bin"; cp "$HUB/.local/bin/git-identity-check" "$CR/.local/bin/"
REAL_PY="$(command -v python3)"
printf '#!/bin/sh\n"%s" "$@"\nexit 3\n' "$REAL_PY" > "$CR/bin/python3"; chmod +x "$CR/bin/python3"
printf 'machine crashy crashy component\n' >> "$HUB/.config/git/audit"
run_audit; exits "a remote run that fails after a full answer fails" 1; has "  and is named" "FAIL [unreachable] crashy"
sed -i.bak '/^machine crashy/d' "$HUB/.config/git/audit" && rm -f "$HUB/.config/git/audit.bak"

printf 'machine down down.invalid component\n' >> "$HUB/.config/git/audit"
run_audit; exits "an unreachable machine fails, even with error output" 1; has "  and is named" "FAIL [unreachable] down"
sed -i.bak '/^machine down/d' "$HUB/.config/git/audit" && rm -f "$HUB/.config/git/audit.bak"

echo "== --offline skips every network probe =="
rm -f "$T/answers/github.com" "$T/answers/github-alice"
run_audit --offline
exits "offline audit passes without answers" 0
lacks "  and probed nothing" "logged in as"

echo "== bad configuration is refused (exit 2) =="
cp "$HUB/.config/git/audit" "$T/audit.good"
conf_case() {  # $1 = label, then sed expression applied to the audit file
  cp "$T/audit.good" "$HUB/.config/git/audit"; sed -i.bak "$2" "$HUB/.config/git/audit"; rm -f "$HUB/.config/git/audit.bak"
  run_audit; exits "$1" 2
}
conf_case "no since line"                '/^since/d'
conf_case "a since that isn't a date"    's/^since .*/since 2026-2-01/'
conf_case "no machine lines"             '/^machine/d'
conf_case "a root depth that isn't a number" 's#~/repos:2#~/repos:two#'
conf_case "an unknown machine kind"      's/^machine comp comp component/machine comp comp gadget/'
cp "$T/audit.good" "$HUB/.config/git/audit"

echo "== the machine list is required =="
mv "$HUB/.config/git/audit" "$T/audit.bak"
run_audit; exits "no audit file: exit 2" 2; has "  and says where it belongs" "~/.config/git/audit"
mv "$T/audit.bak" "$HUB/.config/git/audit"

[ "$PASS" -ge 35 ] || bad "only $PASS checks ran: the suite exercised less than it should"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
