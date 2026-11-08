#!/usr/bin/env bash
#
# Every command the README and the git identity guide tell you to run must name something
# that exists.
#
# Documentation rots silently: nothing fails when an instruction stops being true, so
# it stays wrong until someone follows it, and an instruction to clone a repository that
# doesn't exist can't work on a fresh machine.
#
# The checks:
#   1. No dead repository URLs, and the clone command names this repo.
#   2. Every dotfiles-relative path a command names is present.
#   3. Every suite that exists is in "The checks", and every flag setup.sh takes is
#      described.

set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README="$DOTFILES/README.md"
GUIDE="$DOTFILES/docs/git-identity.md"
[ -f "$GUIDE" ] || { echo "FAIL docs/git-identity.md is missing"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

echo "== the clone command names the public repo =="
PUBLIC_URL="https://github.com/rosslevinsky/dotfiles.git"
if grep -qF "git clone $PUBLIC_URL" "$README"; then ok "clones $PUBLIC_URL"; else bad "clones $PUBLIC_URL"; fi
if grep -qE 'git clone git@' "$README"; then bad "no clone needs an SSH key"; else ok "no clone needs an SSH key"; fi

echo "== repository URLs resolve =="
# This repo's own URL is checked above, as exact text, and not asked of GitHub. Where it
# exists the answer proves nothing, because CI is already running in it, and in a checkout
# made before the first release the answer would be a failure that means nothing.
while read -r url; do
  [ -z "$url" ] && continue
  [ "$url" = "$PUBLIC_URL" ] && continue
  slug="${url#https://github.com/}"; slug="${slug%.git}"
  if gh repo view "$slug" >/dev/null 2>&1; then ok "$slug exists"; else bad "$slug does NOT exist"; fi
done < <(grep -hoE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(\.git)?' "$README" "$GUIDE" | sort -u)

echo "== dotfiles-relative paths named in commands exist =="
# The lookbehind excludes `~/.claude/...` and `.claude/...`: those are runtime paths under
# $HOME or inside another repo, not files in this one. Without it every mention of the
# install destination reads as a missing local path.
#
# The optional `dotfiles/` prefix is why this reads two forms. `dotfiles/claude/rules/x.md`
# has its path behind the lookbehind (preceded by `/`), so without the prefix it would
# silently stop being checked. A doc-checker that quietly narrows when the docs improve is
# the failure it exists to catch, so both spellings count and the prefix is stripped before
# the existence test.
#
# Written with grep -E, not -P: macOS grep has no -P, and there the loop would receive no
# paths and check nothing while CI stayed green. The lookbehind becomes a captured preceding
# character, which the first sed expression strips. An empty result fails outright.
# The folders are this repo's top-level ones. A data-folder file is written
# `identity/git/config`, whose path is behind the lookbehind.
extract_paths() {  # $1 = a markdown file
  grep -oE '(^|[^~.[:alnum:]_/])(dotfiles/)?(bin|claude|codex|docs|examples|starters|tests|tmux)/[A-Za-z0-9_.*/-]+' "$1" \
    | sed -E 's#^[^[:alnum:]]##; s#^dotfiles/##; s#[.]$##' | sort -u
}
readme_paths="$(extract_paths "$README")"
[ -n "$readme_paths" ] || bad "no dotfiles paths found in the README: the pattern matched nothing"
guide_paths="$(extract_paths "$GUIDE")"
[ -n "$guide_paths" ] || bad "no dotfiles paths found in the guide: the pattern matched nothing"
paths="$(printf '%s\n%s\n' "$readme_paths" "$guide_paths" | sort -u)"
# A path may be a glob (bin/git-identity-* names two files); it must match at least one.
exists() { local m; for m in "$DOTFILES"/$1; do [ -e "$m" ] && return 0; done; return 1; }
for p in $paths; do
  if exists "$p"; then ok "$p"; else bad "$p is named but absent"; fi
done

# The extraction must actually catch a runbook command naming something that isn't
# there, or a renamed script would leave the README pointing at nothing while this stays
# green. Checked against a two-line fixture, so the real README needn't be broken.
fixture="$(mktemp)"
printf 'Run `bin/git-identity-check`, then `bin/no-such-tool --live`.\nEdit `starters/no-such-file`.\nRead `docs/git-identity.md`, then `docs/no-such-guide.md`.\n' > "$fixture"
missing="$(for p in $(extract_paths "$fixture"); do exists "$p" || echo "$p"; done)"
rm -f "$fixture"
case "$missing" in
  *bin/no-such-tool*docs/no-such-guide.md*starters/no-such-file*) ok "a runbook command naming a missing path is caught" ;;
  *) bad "a runbook command naming a missing path is caught (got: ${missing:-nothing})" ;;
esac
case "$missing" in
  *docs/git-identity.md*) bad "a guide that exists is reported missing" ;;
  *) ok "a guide that exists is not reported missing" ;;
esac

echo "== the guide is reachable, and what points into it lands on a heading =="
grep -qF 'docs/git-identity.md' "$README" && ok "the README points at the guide" || bad "the README points at the guide"
for pointer in 'bin/git-identity-check:The check failed' 'bin/git-identity-audit:Audit every machine'; do
  tool="${pointer%%:*}"; section="${pointer#*:}"
  grep -qF "docs/git-identity.md" "$DOTFILES/$tool" && grep -qF "\"$section\"" "$DOTFILES/$tool" \
    && ok "$tool names the guide and \"$section\"" || bad "$tool names the guide and \"$section\""
  grep -qx "## $section" "$GUIDE" && ok "the guide has the heading \"$section\"" || bad "the guide has the heading \"$section\""
done
grep -qF 'docs/git-identity.md' "$DOTFILES/setup.sh" && ok "setup.sh points at the guide" || bad "setup.sh points at the guide"

echo "== every suite that exists is in The checks =="
checks="$(awk '/^## The checks/ {f=1; next} /^## / {f=0} f' "$README")"
[ -n "$checks" ] || bad "the README has a section called The checks"
for f in "$DOTFILES"/tests/test_*.sh "$DOTFILES"/tests/test_*.py "$DOTFILES"/tests/check_*.sh; do
  rel="tests/${f##*/}"
  # A suite that isn't one of the checks says so in its first lines.
  head -n 5 "$f" | grep -q '^# Not one of The checks\.' && continue
  case "$checks" in *"$rel"*) ok "$rel is described" ;; *) bad "$rel is in the tree but not in The checks" ;; esac
done

echo "== every flag setup.sh takes is described =="
for flag in $(grep -oE '^ +--[a-z-]+\)' "$DOTFILES/setup.sh" | tr -d ' )'); do
  if grep -qe "$flag" "$README" "$GUIDE"; then ok "$flag"; else bad "$flag is in setup.sh but not the README or the guide"; fi
done
grep -q 'pre-dotfiles' "$README" && ok "the move-aside name is described" || bad "the move-aside name is described"
for f in "$DOTFILES"/starters/*; do
  rel="starters/${f##*/}"
  grep -qF "$rel" "$README" && ok "$rel is described" || bad "$rel is in the tree but not the README"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
