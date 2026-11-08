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
#     workspace/CLAUDE.md    optional: linked as ~/src/CLAUDE.md, read in every repo under ~/src
#
# It runs on the Bash 3.2 that macOS ships.
set -e
PRIVATE="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: setup.sh [--replace-links-from <old-checkout>] [--force-settings]

  --replace-links-from <old-checkout>
           after a checkout was moved or renamed, count a link into this absolute path as
           ours. Goes to both base runs and the workspace link.
  --force-settings
           goes to the plain base run: replace ~/.claude/settings.json even if it was
           changed directly. Without it, move the change to settings-overlay.json.

Environment:
  DOTFILES_BASE   the base checkout (default: dotfiles beside this checkout)
  WORKSPACE_DIR   the folder holding the checkouts, where workspace/CLAUDE.md is linked
                  (default: the folder holding this checkout)
EOF
}

die() { echo "setup.sh: $1" >&2; exit "${2:-1}"; }

REPLACE_FROM=""
FORCE_SETTINGS=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --replace-links-from)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "--replace-links-from needs the old checkout's path" 2
            REPLACE_FROM="$2"; shift ;;
        --force-settings) FORCE_SETTINGS=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" 2 ;;
    esac
    shift
done

# An absolute path with the folders that exist resolved, and the rest kept as written, so a
# renamed checkout, or a link into one, still compares. macOS has no `readlink -f`.
resolve_path() {
    local dir="$1" rest=""
    while [ ! -d "$dir" ]; do
        rest="/$(basename "$dir")$rest"
        dir="$(dirname "$dir")"
    done
    dir="$(CDPATH='' cd -P -- "$dir" && pwd -P)" || return 1
    printf '%s%s\n' "${dir%/}" "$rest"
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
SOURCE="$PRIVATE/workspace/CLAUDE.md"
DEST="$WORKSPACE/CLAUDE.md"
if [ -f "$SOURCE" ]; then
    [ -d "$WORKSPACE" ] || die "no workspace folder at $WORKSPACE: set WORKSPACE_DIR."
    case "$(resolve_path "$HOME")/" in
        "$(resolve_path "$WORKSPACE")"/*)
            die "refusing to link $DEST: a CLAUDE.md there is read from every folder beneath it, your home folder included. Keep the checkouts in a folder of their own, or set WORKSPACE_DIR." ;;
    esac
    # Ours is a link to the source, or, with --replace-links-from, a link into the old
    # checkout. Anything else there is yours, even with the same text, and is left alone.
    ours=0
    if [ -L "$DEST" ]; then
        target="$(readlink "$DEST")"
        case "$target" in /*) ;; *) target="$WORKSPACE/$target" ;; esac
        real="$(resolve_path "$target")"
        [ "$real" != "$(resolve_path "$SOURCE")" ] || ours=1
        if [ -n "$REPLACE_FROM" ]; then
            case "$real" in "$(resolve_path "$REPLACE_FROM")"/?*) ours=1 ;; esac
        fi
    fi
    if { [ -e "$DEST" ] || [ -L "$DEST" ]; } && [ "$ours" = 0 ]; then
        die "$DEST exists and is not this repo's link: move it aside first. Nothing was written."
    fi
fi

# Empty arrays are spelled ${a[@]+"${a[@]}"}: Bash 3.2 calls a bare "${a[@]}" unbound under set -u.
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
bash "$BASE/setup.sh" "${PLAIN_ARGS[@]}" ${REPLACE_ARGS[@]+"${REPLACE_ARGS[@]}"} \
    || die "the plain base run stopped, see above. Any git routing is installed. Fix it and run this again."

# --- 3. The workspace file ---
if [ -f "$SOURCE" ]; then
    rm -f "$DEST"        # only a link the checks above found to be ours
    ln -s "$SOURCE" "$DEST"
    echo
    echo "Workspace instructions linked:"
    echo "  $DEST -> $SOURCE"
fi
