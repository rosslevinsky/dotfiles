#!/bin/bash
# A sample setup.sh for a private repo of your own, which puts your private layer on top of
# this public one. Copy it to the top of that repo and edit it there. It never needs to
# change this repo, and this repo never refers to yours.
#
# It expects the two checkouts side by side, for example:
#
#   ~/src/dotfiles/      a clone of this repo, the base
#   ~/src/my-config/     your private repo, holding this script and:
#     owners, git/, ssh/     optional: the identity data folder, as --identity-dir describes it
#     settings-overlay.json  your Claude Code settings
#     claude/CLAUDE.md       optional: your user instructions, installed as ~/.claude/CLAUDE.md
#     claude/rules/*.md      optional: more user instructions, each linked into ~/.claude/rules/
#     workspace/CLAUDE.md    optional: linked as ~/src/CLAUDE.md, read in every repo under ~/src
#
# Where Codex is, the base generates its AGENTS.md from claude/CLAUDE.md and the rules.
#
# It runs on the Bash 3.2 that macOS ships.
set -e
# Physical, so every run spells the links it makes the same way, however it was started.
PRIVATE="$(CDPATH='' cd -P -- "$(dirname "$0")" && pwd -P)"

usage() {
    cat <<'EOF'
Usage: setup.sh [--replace-links-from <old-checkout>] [--force-settings]

  --replace-links-from <old-checkout>
           after a checkout was moved or renamed, count a link into this absolute path as
           ours. Goes to both base runs. For the workspace and rule links, it is this
           repo's old path, or the folder that held it.
  --force-settings
           goes to the plain base run: replace ~/.claude/settings.json even if it was
           changed directly. Without it, move the change to settings-overlay.json.

Environment:
  DOTFILES_BASE   the base checkout (default: dotfiles beside this checkout)
  WORKSPACE_DIR   the folder holding the checkouts, where workspace/CLAUDE.md is linked
                  (default: the folder holding this checkout)
  CODEX_HOME      Codex's folder, where the base generates AGENTS.md if the folder exists
                  (default: ~/.codex)
EOF
}

die() { echo "setup.sh: $1" >&2; exit "${2:-1}"; }

REPLACE_FROM=""
FORCE_SETTINGS=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --replace-links-from)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "--replace-links-from needs the old checkout's path" 2
            REPLACE_FROM="${2%/}"; shift ;;
        --force-settings) FORCE_SETTINGS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" 2 ;;
    esac
    shift
done

# Links are matched by exact text below, so the old path must be written plainly.
case "$REPLACE_FROM/" in
    /|[!/]*|*/./*|*/../*) [ -z "$REPLACE_FROM" ] || die "--replace-links-from needs an absolute path with no . or .. in it" 2 ;;
esac

# An absolute path with the folders that exist resolved, so the workspace folder can be compared
# with the home folder. macOS has no `readlink -f`.
resolve_path() {
    local dir="$1" rest=""
    while [ ! -d "$dir" ]; do
        rest="/$(basename "$dir")$rest"
        dir="$(dirname "$dir")"
    done
    dir="$(CDPATH='' cd -P -- "$dir" && pwd -P)" || return 1
    printf '%s%s\n' "${dir%/}" "$rest"
}
present() { [ -e "$1" ] || [ -L "$1" ]; }

# The old path as given, and as it resolves, since the links this wrapper made are physical.
REPLACE_REAL=""
[ -z "$REPLACE_FROM" ] || REPLACE_REAL="$(resolve_path "$REPLACE_FROM")"

# Sets TARGET to a link's target exactly. $(...) alone would also strip newlines that belong to
# it; readlink, GNU or BSD, adds one.
# A link's target, exactly. readlink can't be trusted with an odd name (macOS's rewrites some),
# and $(...) drops trailing newlines, so python3 prints it with an x after.
target_of() {
    TARGET="$(python3 -c 'import os, sys; sys.stdout.write(os.readlink(sys.argv[1]) + "x")' "$1" 2>/dev/null || :)"
    TARGET="${TARGET%x}"
}

# Ours is a link whose target is exactly the path this wrapper writes, or, with
# --replace-links-from, that path in the old checkout or in a folder that held it. Nothing is
# resolved, so a link the wrapper didn't make, a relative one included, is never ours: it is
# left alone or refused, even with the same text. Leaves TARGET for the message in decide.
link_is_ours() {          # $1 = a destination, $2 = its source within this repo
    local old
    TARGET=""
    [ -L "$1" ] || return 1
    target_of "$1"
    [ "$TARGET" != "$PRIVATE/$2" ] || return 0
    [ -n "$REPLACE_FROM" ] || return 1
    for old in "$REPLACE_FROM" "$REPLACE_REAL"; do
        [ "$TARGET" != "$old/$2" ] && [ "$TARGET" != "$old/$(basename "$PRIVATE")/$2" ] || return 0
    done
    return 1
}

# A source must be a real file in real folders here: a link could lead to a file the base
# installs, or to the destination itself.
real_source() {           # $1 = a source within this repo. True if it is there.
    local p="$1"
    while :; do
        [ ! -L "$PRIVATE/$p" ] \
            || die "$PRIVATE/$1 must be a real file in this repo, not a link or in a linked folder. Nothing was written."
        case "$p" in */*) p="${p%/*}" ;; *) break ;; esac
    done
    [ -f "$PRIVATE/$1" ]
}

# Decides a link step before any write, so the base run can't change it: link, after refusing
# anything there that isn't ours; remove our own link, which would dangle; or leave. Sets STEP.
decide() {                # $1 = a destination, $2 = its source within this repo
    STEP=""
    if [ -f "$PRIVATE/$2" ]; then
        if present "$1" && ! link_is_ours "$1" "$2"; then
            die "$1 exists and is not this repo's link${TARGET:+ (it links to $TARGET)}: move it aside first. Nothing was written."
        fi
        STEP=link
    elif link_is_ours "$1" "$2"; then
        STEP=remove
    elif present "$1"; then
        STEP=leave
    fi
}

# Carries out what decide chose. rm removes only a link it found to be ours.
do_step() {               # $1 = the step, $2 = a destination, $3 = its source, $4 = a label
    case "$1" in
        link)
            target_of "$2"; [ "$TARGET" = "$3" ] || { rm -f "$2"; ln -s "$3" "$2"; }
            printf '\n%s linked:\n  %s -> %s\n' "$4" "$2" "$3" ;;
        remove)
            rm -f "$2"
            printf '\n%s: removed the link %s, because there is no %s.\n' "$4" "$2" "$3" ;;
        leave)
            printf '\n%s: left %s alone. There is no %s to link it to.\n' "$4" "$2" "$3" ;;
    esac
}

# --- Checks. Nothing is written until they pass. ---
BASE="${DOTFILES_BASE:-$(dirname "$PRIVATE")/dotfiles}"
[ -f "$BASE/setup.sh" ] || die "no base checkout at $BASE: clone it there, or set DOTFILES_BASE."
# Without python3 the base skips the settings merge and still succeeds, losing the overlay.
command -v python3 >/dev/null 2>&1 || die "python3 is needed to merge settings-overlay.json."
[ -f "$PRIVATE/settings-overlay.json" ] || die "missing $PRIVATE/settings-overlay.json"

# The workspace file is read from every folder below the one it sits in. In the home folder,
# or a folder holding it, that is everything you open, so it is refused.
WORKSPACE="${WORKSPACE_DIR:-$(dirname "$PRIVATE")}"
DEST="$WORKSPACE/CLAUDE.md"
if real_source workspace/CLAUDE.md; then
    [ -d "$WORKSPACE" ] || die "no workspace folder at $WORKSPACE: set WORKSPACE_DIR."
    case "$(resolve_path "$HOME")/" in
        "$(resolve_path "$WORKSPACE")"/*)
            die "refusing to link $DEST: a CLAUDE.md there is read from every folder beneath it, your home folder included. Keep the checkouts in a folder of their own, or set WORKSPACE_DIR." ;;
    esac
fi
decide "$DEST" workspace/CLAUDE.md; WORKSPACE_STEP="$STEP"

# Each rule is linked into ~/.claude/rules, after the same checks, and the wrapper's own link for
# a rule that is gone is removed. Codex reads one user file, so the base joins claude/CLAUDE.md and
# then the rules into AGENTS.md, sorted in the C locale so every machine gets the same order. The
# base checks AGENTS.md itself, before its own first write.
# Empty arrays are spelled ${a[@]+"${a[@]}"}: Bash 3.2 calls a bare "${a[@]}" unbound under set -u.
RULES_DIR="$HOME/.claude/rules"
CODEX_ARGS=(); RULE_DESTS=(); RULE_STEPS=()
! real_source claude/CLAUDE.md || CODEX_ARGS=(--codex-instructions "$PRIVATE/claude/CLAUDE.md")
add_rule() {              # $1 = a destination, $2 = its step
    RULE_DESTS=(${RULE_DESTS[@]+"${RULE_DESTS[@]}"} "$1")
    RULE_STEPS=(${RULE_STEPS[@]+"${RULE_STEPS[@]}"} "$2")
}
find_rules() {
    local LC_ALL=C f name
    for f in "$PRIVATE"/claude/rules/*.md; do
        name="${f##*/}"
        real_source "claude/rules/$name" || continue
        decide "$RULES_DIR/$name" "claude/rules/$name"; add_rule "$RULES_DIR/$name" "$STEP"
        CODEX_ARGS=(${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} --codex-instructions "$f")
    done
    for f in "$RULES_DIR"/*.md; do
        name="${f##*/}"
        [ -e "$PRIVATE/claude/rules/$name" ] || ! link_is_ours "$f" "claude/rules/$name" || add_rule "$f" remove
    done
}
find_rules

REPLACE_ARGS=()
[ -z "$REPLACE_FROM" ] || REPLACE_ARGS=(--replace-links-from "$REPLACE_FROM")

# --- 1. Git identity, first, so git routing works even if a later step stops ---
# Only when this repo holds identity data. With no owners file, or one holding only comments
# (an unfilled starter), there is nothing to route, and the base would refuse.
if [ -f "$PRIVATE/owners" ] && grep -q '^[[:space:]]*[^#[:space:]]' "$PRIVATE/owners"; then
    bash "$BASE/setup.sh" --git-identity --identity-dir "$PRIVATE" ${REPLACE_ARGS[@]+"${REPLACE_ARGS[@]}"} \
        || die "the identity run stopped, see above. Nothing else ran."
else
    echo "No owners in $PRIVATE/owners (no file, or only comments): skipping the git identity install."
fi

# --- 2. The plain base run, with your overlay and no starter files ---
# The starters are for keeping the private layer in ~/.config/dotfiles. This repo holds it
# instead, so starters there would be a second, unused copy that looks like the real one.
PLAIN_ARGS=(--no-starters --settings-overlay "$PRIVATE/settings-overlay.json")
# Your own instructions, kept here so a pull updates them on every machine. Without the file
# the base installs its sample, or keeps a ~/.claude/CLAUDE.md of yours.
[ ! -f "$PRIVATE/claude/CLAUDE.md" ] || PLAIN_ARGS=("${PLAIN_ARGS[@]}" --user-instructions "$PRIVATE/claude/CLAUDE.md")
[ "$FORCE_SETTINGS" = 0 ] || PLAIN_ARGS=("${PLAIN_ARGS[@]}" --force-settings)
echo
bash "$BASE/setup.sh" "${PLAIN_ARGS[@]}" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ${REPLACE_ARGS[@]+"${REPLACE_ARGS[@]}"} \
    || die "the plain base run stopped, see above. Any git routing is installed. Fix it and run this again."

# --- 3. The workspace file and the rules, as the checks decided ---
do_step "$WORKSPACE_STEP" "$DEST" "$PRIVATE/workspace/CLAUDE.md" "Workspace instructions"
i=0
while [ "$i" -lt "${#RULE_DESTS[@]}" ]; do
    [ "$i" -gt 0 ] || mkdir -p "$RULES_DIR"
    do_step "${RULE_STEPS[$i]}" "${RULE_DESTS[$i]}" "$PRIVATE/claude/rules/${RULE_DESTS[$i]##*/}" "User rule"
    i=$((i + 1))
done
