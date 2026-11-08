#!/bin/bash
set -e
DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# --- Recovery ---
# This script installs what this repository owns, and only that. Skills are NOT among
# them: install them with whatever installs them. See the note above the report at the end.

# --- Install mode: symlink (default) or copy ---
# A symlink makes an edit in this checkout live at once, which is what you want on a
# machine where you also EDIT these files. A copy is what you want where the checkout
# will not stay: a work machine, a container, a machine you hand back. The trade is
# exactly that — under --copy, editing this repo changes nothing until you re-run.
#
# Both modes rm the destination first. Switching modes therefore works in either
# direction: --copy over an existing symlink replaces it with a real file, and the
# default over a copy replaces it with a link. A file that isn't this repo's is moved
# aside before that rm, or left in place: see "Ordinary destinations" below.
MODE=link
COPY_ASKED=0
GIT_IDENTITY=0
IDENTITY_DIR=""
SETTINGS_OVERLAY=""
USER_INSTRUCTIONS=""
CODEX_SOURCES=()
FORCE_SETTINGS=0
NO_STARTERS=0
REPLACE_FROM=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --copy) MODE=copy; COPY_ASKED=1 ;;
        --link) MODE=link ;;
        --git-identity) GIT_IDENTITY=1 ;;
        --identity-dir)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "setup.sh: --identity-dir needs a folder" >&2; exit 2
            fi
            IDENTITY_DIR="$2"; shift ;;
        --settings-overlay)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "setup.sh: --settings-overlay needs a file" >&2; exit 2
            fi
            SETTINGS_OVERLAY="$2"; shift ;;
        --user-instructions)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "setup.sh: --user-instructions needs a file" >&2; exit 2
            fi
            USER_INSTRUCTIONS="$2"; shift ;;
        --codex-instructions)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "setup.sh: --codex-instructions needs a file" >&2; exit 2
            fi
            CODEX_SOURCES=(${CODEX_SOURCES[@]+"${CODEX_SOURCES[@]}"} "$2"); shift ;;
        --force-settings) FORCE_SETTINGS=1 ;;
        --no-starters) NO_STARTERS=1 ;;
        --replace-links-from)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "setup.sh: --replace-links-from needs the old checkout's path" >&2; exit 2
            fi
            REPLACE_FROM="$2"; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: setup.sh [--link|--copy] [--settings-overlay <file>] [--user-instructions <file>]
                [--codex-instructions <file>]... [--force-settings] [--no-starters]
                [--replace-links-from <old-checkout>]
       setup.sh --git-identity [--identity-dir <dir>] [--replace-links-from <old-checkout>]

  --link   symlink into this checkout (default) — edits here are live immediately
  --copy   install real copies — for a machine that will not keep this checkout
  --git-identity
           install ONLY the git identity component (the data folder's files and bin/),
           as links, and nothing else. Opt-in: no other run installs it. See
           docs/git-identity.md.
  --identity-dir <dir>
           the data folder --git-identity installs from, by default
           ~/.config/dotfiles/identity. It holds:
             owners            who to route; format in bin/git-identity-check's header
             git/config        the routing
             git/identity-*    one file per identity the owners file names
             git/allowed_signers  the signer list
             ssh/github.conf   the SSH aliases
  --settings-overlay <file>
           private settings layered on claude/settings.json to generate
           ~/.claude/settings.json, by default ~/.config/dotfiles/settings-overlay.json.
           A named file must exist; the default may be missing, which means no overlay.
  --user-instructions <file>
           install ~/.claude/CLAUDE.md from this file instead of the sample in
           claude/CLAUDE.md, as a link, or a copy with --copy. It is treated as the sample
           is: a link to it or a byte-identical copy counts as this run's own, and so does
           the sample's link, so a machine moves from the sample to your file. The file
           must exist.
  --codex-instructions <file>
           where Codex's folder exists (CODEX_HOME, or ~/.codex), generate its AGENTS.md
           from this file. Repeat it to join several files, in the order given, with a
           blank line between two. AGENTS.md is a real file in both modes, rewritten only
           when its bytes would change. Its first line marks it as generated, and only a
           file with that line counts as this run's own: anything else there, a link
           included, stops the run before any write. Without the option AGENTS.md is
           never touched, so a file generated earlier stays as it is. Each file must exist
           and be readable.
  --force-settings
           replace ~/.claude/settings.json even if it was changed directly. The run
           otherwise shows the change and stops, until it is moved to the overlay.
  --no-starters
           create no starter files. Without it, a plain run creates commented-out templates
           where they are absent, and never changes one that exists. A wrapper that keeps your
           private layer in a repo of its own passes this: see the README.
  --replace-links-from <old-checkout>
           count a link into this absolute path as this repo's, even if it dangles, after
           a checkout was moved or renamed. Any other link is still refused, and a plain run
           refuses before any write if a destination holds anything it doesn't recognize.

Without --replace-links-from, a plain run leaves your own ~/.claude/CLAUDE.md and ~/.tmux.conf
in place, installs nothing there, and names the sample, or the --user-instructions file, in
the report. An older --copy of either
counts as your own, since it no longer matches: delete it and run again to take the new one.

At any other destination, a file or link that isn't this repo's moves to
<destination>.pre-dotfiles, or .pre-dotfiles.N when that name is taken, and the report names it.
So a --copy re-run after the checkout changed leaves the old copy there.

Environment:
  CLAUDE_SKILLS_DIR  where skills are looked for when reporting (default: ~/.claude/skills)
EOF
            exit 0 ;;
        *) echo "setup.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# Named without the run it configures, it would be ignored, and the install would then
# carry on as though the folder had been used.
if [ -n "$IDENTITY_DIR" ] && [ "$GIT_IDENTITY" = 0 ]; then
    echo "setup.sh: --identity-dir only applies with --git-identity" >&2
    exit 2
fi

if [ "$GIT_IDENTITY" = 1 ]; then
    if [ -n "$SETTINGS_OVERLAY" ] || [ "$FORCE_SETTINGS" = 1 ] || [ -n "$USER_INSTRUCTIONS" ] \
            || [ "${#CODEX_SOURCES[@]}" -gt 0 ]; then
        echo "setup.sh: --settings-overlay, --user-instructions, --codex-instructions and --force-settings don't apply with --git-identity" >&2
        exit 2
    fi
fi

# A typo would otherwise install the sample in its place. Absolute, since the link is read
# from anywhere.
CLAUDE_MD_SAMPLE="$DOTFILES/claude/CLAUDE.md"
CLAUDE_MD_SOURCE="$CLAUDE_MD_SAMPLE"
if [ -n "$USER_INSTRUCTIONS" ]; then
    if [ ! -f "$USER_INSTRUCTIONS" ]; then
        echo "setup.sh: --user-instructions: no such file: $USER_INSTRUCTIONS" >&2; exit 2
    fi
    CLAUDE_MD_SOURCE="$(CDPATH='' cd -- "$(dirname "$USER_INSTRUCTIONS")" && pwd)/$(basename "$USER_INSTRUCTIONS")"
fi

# Codex's instructions: each file checked now, so a typo stops the run before any write. A
# file that is AGENTS.md, or leads to it, would be read into itself and grow on every run.
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
AGENTS="$CODEX_DIR/AGENTS.md"
AGENTS_MARK='<!-- Generated by setup.sh from '
AGENTS_MARK_END='. Edit the files named here, then run setup.sh again. -->'
codex_files=()
codex_names=""
# Both are physical paths, so a home reached through a link (macOS /var is /private/var) still
# names its files from ~.
home_real="$(CDPATH='' cd -- "$HOME" 2>/dev/null && pwd -P)" || home_real="$HOME"
for f in ${CODEX_SOURCES[@]+"${CODEX_SOURCES[@]}"}; do
    # Checked as given: $(...) below strips a trailing newline, so `one.md` and a newline would be
    # checked as one file and read as another. The marker line can't hold one either.
    case "$f" in *"
"*) echo "setup.sh: --codex-instructions: a file name can't hold a newline" >&2; exit 2 ;; esac
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        echo "setup.sh: --codex-instructions: no readable file at $f" >&2; exit 2
    fi
    f="$(CDPATH='' cd -- "$(dirname "$f")" && pwd -P)/$(basename "$f")"
    if [ "$f" -ef "$AGENTS" ]; then
        echo "setup.sh: --codex-instructions: $f is the file $AGENTS, which this script writes." >&2
        echo "  If $AGENTS is a link, move it aside first." >&2; exit 2
    fi
    codex_files=(${codex_files[@]+"${codex_files[@]}"} "$f")
    # Named from the home folder where it can be, so the marker holds no machine's path.
    case "$f" in "${home_real%/}"/*) f="~/${f#"${home_real%/}"/}" ;; esac
    codex_names="${codex_names:+$codex_names, }$f"
done

# An absolute path with the folders that exist fully resolved, and the rest kept as written.
# The rest matters: a renamed checkout can't be resolved, and neither can a link into it. On
# macOS /var is a link to /private/var, so one path has two spellings. The last name is
# followed only when it is a folder.
resolve_path() {          # $1 = an absolute path, which need not exist
    local dir="$1" rest=""
    while [ ! -d "$dir" ]; do
        rest="/$(basename "$dir")$rest"
        dir="$(dirname "$dir")"
    done
    dir="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
    printf '%s%s\n' "${dir%/}" "$rest"
}

# The old checkout is checked before anything uses it, because everything under it will
# count as this repo's. A folder that holds this checkout or the home folder would make
# links to unrelated files count too.
if [ -n "$REPLACE_FROM" ]; then
    case "$REPLACE_FROM" in
        /*) ;;
        *) echo "setup.sh: --replace-links-from needs an absolute path: $REPLACE_FROM" >&2; exit 2 ;;
    esac
    while [ "$REPLACE_FROM" != "/" ] && [ "${REPLACE_FROM%/}" != "$REPLACE_FROM" ]; do
        REPLACE_FROM="${REPLACE_FROM%/}"
    done
    case "/$REPLACE_FROM/" in
        */../*|*/./*) echo "setup.sh: --replace-links-from can't contain . or ..: $REPLACE_FROM" >&2; exit 2 ;;
    esac
    REPLACE_REAL="$(resolve_path "$REPLACE_FROM")"
    for inside in "$(cd "$DOTFILES" && pwd -P)" "$(resolve_path "$HOME")"; do
        case "$inside/" in
            "${REPLACE_REAL%/}"/*)
                echo "setup.sh: --replace-links-from can't be $REPLACE_FROM: it holds $inside" >&2
                exit 2 ;;
        esac
    done
fi

# True for a link into the old checkout, whether or not its target still exists. A `..` in
# an absolute target isn't resolved: past a linked folder it could lead anywhere. The same
# goes for a relative target with a `..` after a named part, which might be a linked folder.
# Leading `..` parts only climb from the link's own, already resolved, folder.
is_old_link() {           # $1 = destination
    [ -n "$REPLACE_FROM" ] && [ -L "$1" ] || return 1
    local target part out IFS_SAVED named=0
    target="$(readlink "$1")"
    case "$target" in
        /*) case "/$target/" in */../*|*/./*) return 1 ;; esac ;;
        *)  out="$(resolve_path "$(dirname "$1")")" || return 1
            IFS_SAVED="$IFS"; IFS=/; set -f
            for part in $target; do
                case "$part" in
                    ''|.) ;;
                    ..) [ "$named" = 1 ] && named=2 && break
                        out="$(dirname "$out")" ;;
                    *) named=1; out="${out%/}/$part" ;;
                esac
            done
            IFS="$IFS_SAVED"; set +f
            [ "$named" != 2 ] || return 1
            target="$out" ;;
    esac
    target="$(resolve_path "$target")" || return 1
    case "$target" in "${REPLACE_REAL%/}"/?*) return 0 ;; esac
    return 1
}

# -p keeps the mode bits, so statusline-command.sh stays executable under --copy.
#
# The source check is not paranoia, it is the difference between the two modes. `cp`
# fails on a missing source and `set -e` stops the script; `ln -sf` happily points at
# nothing, exits 0, and leaves a DANGLING link that the report then lists as though it
# worked. An incomplete checkout is a real way to arrive here. Failing the same way in
# both modes is the point.
need_source() {           # $1 = source in this repo
    if [ ! -e "$1" ]; then
        echo "setup.sh: missing source file: $1" >&2
        echo "  This checkout is incomplete. Nothing further was installed." >&2
        exit 1
    fi
}
install_file() {          # $1 = source in this repo, $2 = destination
    need_source "$1"
    rm -f "$2"
    if [ "$MODE" = copy ]; then cp -p "$1" "$2"; else ln -sf "$1" "$2"; fi
}

# A destination is this repo's when it is a link to its source or a byte-identical copy
# of it. Anything else there is someone's own file, and install_file's rm would destroy
# it, so callers replace or remove only what this answers yes for. With
# --replace-links-from, so is a link into the old checkout.
is_ours() {               # $1 = source in this repo, $2 = destination
    [ "$(readlink "$2" 2>/dev/null)" = "$1" ] || cmp -s "$1" "$2" || is_old_link "$2"
}

# A path with its folder fully resolved and its last name not followed.
physical_path() {     # $1 = an existing absolute path
    local dir base
    dir="$(dirname "$1")"; base="$(basename "$1")"
    case "$base" in
        .|..|/) (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) ;;
        *) dir="$(CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P)" || return 1
           printf '%s/%s\n' "${dir%/}" "$base" ;;
    esac
}
# Prints the first destination the chain reaches, if any. Called only for a path that
# exists, so the chain has an end: a circular link fails the -e test.
reached_destination() {   # $1 = an existing absolute path, $2 = destinations, one per line
    local hop="$1" target
    while :; do
        hop="$(physical_path "$hop")" || return 0
        case "
$2
" in *"
$hop
"*) printf '%s\n' "$hop"; return 0 ;; esac
        [ -L "$hop" ] || return 0
        target="$(readlink "$hop")"
        case "$target" in
            /*) hop="$target" ;;
            *) hop="$(dirname "$hop")/$target" ;;
        esac
    done
}

# --- Git identity component: --git-identity, and nothing else ---
# Opt-in, because it decides which GitHub account every commit and push on the machine
# uses: a work machine running plain setup.sh (or --copy, which is about mechanics, not
# privacy) must get none of it. Links only, because a copy of the routing or the signer
# list would go stale on the next pull with nothing to say so. And it touches nothing
# the plain run installs, so it can go on a machine that wants no other dotfiles.
#
# Every check runs before the first write. A refusal half-way through would leave a
# machine with some of the routing and not the rest, which is worse than none of it.
if [ "$GIT_IDENTITY" = 1 ]; then
    problems=""
    problem() { problems="${problems}  $1
"; }

    # The data folder: who to route, and the files that do it. Absolute, since the links
    # are read from anywhere.
    IDENTITY_DIR="${IDENTITY_DIR:-$HOME/.config/dotfiles/identity}"
    if [ -d "$IDENTITY_DIR" ]; then
        IDENTITY_DIR="$(CDPATH='' cd -- "$IDENTITY_DIR" && pwd)"
        identity_real="$(cd "$IDENTITY_DIR" && pwd -P)"
    else
        problem "no data folder at $IDENTITY_DIR: pass --identity-dir, or create it"
    fi

    # The owners file, by the same rules as bin/git-identity-check, whose header defines
    # them. Read here as well because the install must work with no python3, and a bad
    # line must stop it before the first write. Word lists hold only names these patterns
    # have accepted, so the plain `case` searches and `for` loops below are safe.
    OWNERS_FILE="$IDENTITY_DIR/owners"
    name_re='^[A-Za-z0-9][A-Za-z0-9-]*$'
    alias_re='^github-[A-Za-z0-9][A-Za-z0-9-]*$'
    ident_re='^identity-[A-Za-z0-9._-]+$'
    owner_names=""; owner_aliases=""; ID_ALIASES=""; identity_files=""
    if [ -d "$IDENTITY_DIR" ] && [ ! -f "$OWNERS_FILE" ]; then
        problem "no owners file at $OWNERS_FILE"
    elif [ -f "$OWNERS_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            read -r kw a b c extra <<<"$line"
            case "$kw" in ''|'#'*) continue ;; esac
            if [ "$kw" = owner ] && [ -n "$c" ] && [ -z "$extra" ]; then
                if ! [[ "$a" =~ $name_re ]]; then
                    problem "owners line \`$line\`: the owner is not a GitHub name"
                elif ! [[ "$b" =~ $alias_re ]]; then
                    problem "owners line \`$line\`: the SSH alias must be github-<name>"
                elif ! [[ "$c" =~ $ident_re ]]; then
                    problem "owners line \`$line\`: the identity file must be named identity-<name>"
                else
                    case " $owner_names " in
                        *" $a "*) problem "owners line \`$line\`: this owner already has a line" ;;
                        *) owner_names="$owner_names $a"; owner_aliases="$owner_aliases $b"
                           case " $identity_files " in *" $c "*) ;; *) identity_files="$identity_files $c" ;; esac ;;
                    esac
                fi
            elif [ "$kw" = alias ] && [ -n "$b" ] && [ -z "$c" ]; then
                if [ "$a" != github.com ] && ! [[ "$a" =~ $alias_re ]]; then
                    problem "owners line \`$line\`: the SSH alias must be github.com or github-<name>"
                elif ! [[ "$b" =~ $name_re ]]; then
                    problem "owners line \`$line\`: the account is not a GitHub name"
                elif [ "$a" != github.com ] && [ "$a" != "github-$b" ]; then
                    problem "owners line \`$line\`: the alias github-<name> must map to the account <name>"
                else
                    case " $ID_ALIASES " in
                        *" $a "*) problem "owners line \`$line\`: this alias already has a line" ;;
                        *) ID_ALIASES="$ID_ALIASES $a" ;;
                    esac
                fi
            else
                problem "owners line \`$line\`: expected \`owner <owner> <SSH alias> <identity file>\` or \`alias <SSH alias> <account>\`"
            fi
        done < "$OWNERS_FILE"
        if [ -z "$owner_names" ] && [ -z "$problems" ]; then
            problem "$OWNERS_FILE has no owners"
        fi
        for b in $owner_aliases; do
            case " $ID_ALIASES " in *" $b "*) ;; *) problem "$OWNERS_FILE: an owner uses $b, which has no alias line" ;; esac
        done
        case " $ID_ALIASES " in
            *" github.com "*) ;;
            *) [ -n "$owner_names" ] && problem "$OWNERS_FILE has no \`alias github.com <account>\` line" ;;
        esac
    fi

    # One <source>:<path under HOME> per line. A source is absolute and may hold spaces or
    # colons, so a line splits at its LAST colon.
    COMPONENT="$IDENTITY_DIR/git/config:.config/git/config
$IDENTITY_DIR/owners:.config/git/owners"
    for c in $identity_files; do
        COMPONENT="$COMPONENT
$IDENTITY_DIR/git/$c:.config/git/$c"
    done
    COMPONENT="$COMPONENT
$IDENTITY_DIR/git/allowed_signers:.config/git/allowed_signers
$IDENTITY_DIR/ssh/github.conf:.ssh/config.d/github.conf
$DOTFILES/bin/gh-as:.local/bin/gh-as
$DOTFILES/bin/git-identity-audit:.local/bin/git-identity-audit
$DOTFILES/bin/git-identity-check:.local/bin/git-identity-check"

    [ "$COPY_ASKED" = 0 ] || problem "--copy: the identity component installs as links only, so a pull updates it"
    # Set at all, even empty: git treats any GIT_CONFIG_GLOBAL as an override.
    [ -z "${GIT_CONFIG_GLOBAL+set}" ] || problem "GIT_CONFIG_GLOBAL is set: git would not read ~/.config/git/config at all"
    if [ -n "${XDG_CONFIG_HOME:-}" ] && [ "$XDG_CONFIG_HOME" != "$HOME/.config" ]; then
        problem "XDG_CONFIG_HOME is $XDG_CONFIG_HOME: git would look for the component there, not in ~/.config"
    fi
    checkout="$(cd "$DOTFILES" && pwd -P)"
    # The source tree a destination must not resolve into: this checkout, and the data
    # folder when there is one.
    data_real="${identity_real:-$checkout}"
    while IFS= read -r pair; do
        src="${pair%:*}"; rel="${pair##*:}"; dest="$HOME/$rel"
        [ -e "$src" ] || problem "missing source $src: the checkout or data folder is incomplete"
        # The nearest existing ancestor of the destination. A dangling symlink on the way
        # is a problem in itself: mkdir -p would fail on it AFTER earlier files went in.
        dir="$(dirname "$dest")"
        while [ ! -e "$dir" ]; do
            [ -L "$dir" ] && problem "$dir is a dangling symlink"
            dir="$(dirname "$dir")"
        done
        # Writable AND searchable: without -x nothing can be created inside it.
        if [ -d "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ]; then
            # A parent that resolves into the checkout or data folder makes the source
            # its own destination: install_file's rm would delete it.
            if ! real="$(cd "$dir" 2>/dev/null && pwd -P)"; then
                problem "can't resolve $dir"
            else
                case "$real/" in
                    "$checkout"/*) problem "~/$rel resolves into this checkout ($checkout)" ;;
                    "$data_real"/*) problem "~/$rel resolves into the data folder ($data_real)" ;;
                esac
            fi
        else
            problem "can't create $(dirname "$dest"): $dir is not a writable directory"
        fi
        if { [ -e "$dest" ] || [ -L "$dest" ]; } && ! is_ours "$src" "$dest"; then
            problem "~/$rel exists and is not this repo's: move it aside first"
        fi
    done <<EOF
$COMPONENT
EOF

    # A source that is, or links to, a destination: `cmp` above sees the file compared
    # with itself and calls it ours, and install_file would delete the real file. Every
    # hop of the link chain counts, not just the end: if the destination is itself a link,
    # the chain passes through it and ends somewhere else. Any destination counts, since
    # each one is replaced in turn. Comparing the fully resolved ends instead would refuse
    # every re-run with a linked source, whose destination links through it to the same
    # file. Plain readlink and `pwd -P`, because an older macOS has neither `readlink -f`
    # nor realpath. Both preflights use physical_path and reached_destination, defined above.

    # Only existing destinations: nothing existing can link through one that isn't there.
    existing_dests=""
    while IFS= read -r pair; do
        dest="$HOME/${pair##*:}"
        if [ -e "$dest" ] && physical="$(physical_path "$dest")"; then
            existing_dests="$existing_dests
$physical"
        fi
    done <<EOF
$COMPONENT
EOF
    while IFS= read -r pair; do
        src="${pair%:*}"
        if [ -e "$src" ]; then
            reached="$(reached_destination "$src" "$existing_dests")"
            [ -z "$reached" ] || problem "source $src reaches the destination $reached: installing would destroy it"
        fi
    done <<EOF
$COMPONENT
EOF

    if [ -n "$problems" ]; then
        echo "setup.sh --git-identity: refusing; nothing was written." >&2
        printf '%s' "$problems" >&2
        exit 1
    fi

    MODE=link
    [ -d "$HOME/.ssh" ] || { mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; }
    while IFS= read -r pair; do
        dest="$HOME/${pair##*:}"
        mkdir -p "$(dirname "$dest")"
        install_file "${pair%:*}" "$dest"
    done <<EOF
$COMPONENT
EOF
    echo "Git identity component linked:"
    while IFS= read -r pair; do
        echo "  ~/${pair##*:} -> ${pair%:*}"
    done <<EOF
$COMPONENT
EOF

    # Outside requirements: reported, never installed, in the plain run's style. Both
    # files are the user's, and these changes REMOVE things from them, which is not
    # something to do unasked. git-identity-check fails until they are done.
    echo
    sshconf="$HOME/.ssh/config"
    # ~/.ssh/config read the way ssh reads it: `Keyword value`, `Keyword=value`, quoted
    # values, comments skipped, Host patterns matched as globs with `!` negation, and
    # anything before the first Host/Match applying to every host. Prints:
    #   include            the Include of this component, before the first Host/Match
    #   host N: Host …     a Host block naming GitHub
    #   keys N: aliases    an IdentityFile reaching one of the component's aliases
    ssh_scan() {
        [ -f "$sshconf" ] || return 0
        # No pathname expansion: `for p in $rest` would turn a `Host *` into file names.
        # This runs in a $(…) subshell, so it doesn't leak.
        set -f
        local n=0 line kw rest w seen=0 reaches="" a p pos neg hit
        local aliases="$ID_ALIASES"
        local everywhere="$aliases"
        while IFS= read -r line || [ -n "$line" ]; do
            n=$((n + 1))
            line="${line#"${line%%[![:space:]]*}"}"
            case "$line" in ''|'#'*) continue ;; esac
            line="${line%%[[:space:]]#*}"
            line="${line//\"/ }"; line="${line/=/ }"
            read -r kw rest <<<"$line"
            case "$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')" in
                host)
                    seen=1; reaches=""
                    for a in $aliases; do
                        pos=0; neg=0
                        for p in $rest; do
                            case "$p" in
                                '!'*) [[ "$a" == ${p#!} ]] && neg=1 ;;
                                *)    [[ "$a" == $p ]] && pos=1 ;;
                            esac
                        done
                        [ "$pos" = 1 ] && [ "$neg" = 0 ] && reaches="$reaches $a"
                    done
                    # Only a pattern that NAMES GitHub; `!github*` excludes it.
                    for p in $rest; do
                        case "$p" in '!'*) ;; *[Gg][Ii][Tt][Hh][Uu][Bb]*) echo "host $n: Host $rest"; break ;; esac
                    done ;;
                match)
                    seen=1; reaches="" ;;
                include)
                    if [ "$seen" = 0 ]; then
                        for w in $rest; do
                            case "$w" in
                                config.d/github.conf|"~/.ssh/config.d/github.conf"|"$HOME/.ssh/config.d/github.conf") echo include ;;
                            esac
                        done
                    fi ;;
                identityfile)
                    if [ "$seen" = 0 ]; then hit=" $everywhere"; else hit="$reaches"; fi
                    [ -n "${hit// /}" ] && echo "keys $n:$hit" ;;
            esac
        done < "$sshconf"
    }
    scan="$(ssh_scan || true)"   # no ~/.ssh/config yet: nothing to scan, not an error
    if ! printf '%s\n' "$scan" | grep -qx include; then
        echo "Missing: in ~/.ssh/config, before its first Host or Match line, add:"
        echo "  Include config.d/github.conf"
    fi
    if printf '%s\n' "$scan" | grep -q '^host '; then
        echo "Remove: ~/.ssh/config still has a GitHub Host block; github.conf replaces it:"
        printf '%s\n' "$scan" | grep '^host ' | sed 's/^host /  line /'
    fi
    if printf '%s\n' "$scan" | grep -q '^keys '; then
        echo "Remove: ~/.ssh/config adds an IdentityFile to GitHub aliases; each must offer only its own key:"
        printf '%s\n' "$scan" | grep '^keys ' | sed 's/^keys \([0-9]*\):/  line \1 reaches/'
    fi
    if [ -f "$HOME/.gitconfig" ]; then
        leftovers="$(git config --file "$HOME/.gitconfig" --name-only --list 2>/dev/null \
            | grep -iE '^(user\.(name|email|signingkey)|author\.|committer\.|includeif\.|url\..*\.(push)?insteadof$)' || true)"
        if [ -n "$leftovers" ]; then
            echo "Remove: ~/.gitconfig still sets identity or routing; the component owns these now:"
            printf '%s\n' "$leftovers" | sed 's/^/  /'
        fi
    fi
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Missing: ~/.local/bin on PATH, for gh-as and git-identity-check" ;; esac
    command -v python3 >/dev/null 2>&1 || echo "Missing: python3 — git-identity-check needs it."
    echo "Then check the machine:  ~/.local/bin/git-identity-check --live"
    exit 0
fi

# --- Claude Code settings: decided before anything is written ---
# ~/.claude/settings.json is a real file generated from the base and the overlay, in both
# install modes. It can't be a link, because Claude Code writes changes back into it, and
# those would land in this checkout or in nowhere. --copy needs nothing different: the file
# never depends on the checkout after this run. The last result is recorded beside it, under
# a name nothing reads as settings, so a change made directly can be told from a new base
# or overlay.
#
# Drift is an edit from the record to the live file, a deleted key included, that the new
# result doesn't already hold: merge_settings.py compares them key by key. That is what lets
# "move the change to the overlay" end the stop, even if the base changed meanwhile. With no
# record, a file that isn't a copy of the base is someone's own, so it counts as drift too.
# All of this runs first, so a stop leaves the machine exactly as it was.
LIVE_SETTINGS="$HOME/.claude/settings.json"
SETTINGS_RECORD="$LIVE_SETTINGS.generated"
BASE_SETTINGS="$DOTFILES/claude/settings.json"
MERGE_SETTINGS="$DOTFILES/claude/merge_settings.py"
if [ -n "$SETTINGS_OVERLAY" ]; then
    # A typo here would otherwise apply as "no overlay" and silently drop private settings.
    if [ ! -f "$SETTINGS_OVERLAY" ]; then
        echo "setup.sh: --settings-overlay: no such file: $SETTINGS_OVERLAY" >&2; exit 2
    fi
else
    SETTINGS_OVERLAY="$HOME/.config/dotfiles/settings-overlay.json"
    DEFAULT_OVERLAY=1
fi
# The overlay is an input. Pointing it at a file this run writes would destroy it, and pin
# every base value in it from then on.
for settings_output in "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.generated"; do
    if [ "$SETTINGS_OVERLAY" -ef "$settings_output" ]; then
        echo "setup.sh: the settings overlay can't be $settings_output, which this script writes." >&2; exit 2
    fi
done
settings_state=generate
MERGED_SETTINGS=""
same_settings() { python3 "$MERGE_SETTINGS" compare "$1" "$2" >/dev/null 2>&1; }
edits_preserved() { python3 "$MERGE_SETTINGS" drift "$SETTINGS_RECORD" "$LIVE_SETTINGS" "$MERGED_SETTINGS" >/dev/null 2>&1; }
settings_stop() {         # $1 = what is wrong
    echo "setup.sh: stopping before any change: $1" >&2
}
if ! command -v python3 >/dev/null 2>&1; then
    settings_state=no-python
else
    for f in "$BASE_SETTINGS" "$MERGE_SETTINGS"; do
        if [ ! -e "$f" ]; then
            echo "setup.sh: missing source file: $f" >&2
            echo "  This checkout is incomplete. Nothing further was installed." >&2
            exit 1
        fi
    done
    MERGED_SETTINGS="$(mktemp)"
    NO_RECORD="$(mktemp)"
    trap 'rm -f "$MERGED_SETTINGS" "$NO_RECORD"' EXIT
    printf '{}\n' > "$NO_RECORD"
    if ! python3 "$MERGE_SETTINGS" merge "$BASE_SETTINGS" "$SETTINGS_OVERLAY" > "$MERGED_SETTINGS"; then
        settings_stop "the settings can't be generated from $BASE_SETTINGS and $SETTINGS_OVERLAY"
        exit 1
    fi
    drift=""
    if [ -L "$LIVE_SETTINGS" ]; then
        link_target="$(readlink "$LIVE_SETTINGS")"
        case "$link_target" in /*) ;; *) link_target="$(dirname "$LIVE_SETTINGS")/$link_target" ;; esac
        if [ "$(resolve_path "$link_target")" = "$(resolve_path "$BASE_SETTINGS")" ] || is_old_link "$LIVE_SETTINGS"; then
            :   # The link every machine has before its first generated file.
        else
            drift="~/.claude/settings.json is a link to $(readlink "$LIVE_SETTINGS"), which is not this repo's."
            [ -n "$REPLACE_FROM" ] || drift="$drift
  If it points into a checkout that moved, pass --replace-links-from with that checkout's old path."
        fi
    elif [ -e "$LIVE_SETTINGS" ] && [ ! -f "$LIVE_SETTINGS" ]; then
        settings_stop "~/.claude/settings.json is not a file. Move it aside first."
        exit 1
    elif [ -f "$LIVE_SETTINGS" ] && ! same_settings "$LIVE_SETTINGS" "$MERGED_SETTINGS"; then
        if [ -e "$SETTINGS_RECORD" ]; then
            drift_record="$SETTINGS_RECORD"
            edits_preserved \
                || drift="~/.claude/settings.json was changed directly since setup.sh generated it:"
        else
            # No record, as on a first install over a file of your own. Every value in it is
            # then an edit, measured from nothing: the run goes on only when the result holds
            # each one, so moving them all to the overlay is enough. The base's own keys, which
            # the result adds, lose nothing.
            drift_record="$NO_RECORD"
            same_settings "$BASE_SETTINGS" "$LIVE_SETTINGS" \
                || python3 "$MERGE_SETTINGS" drift "$NO_RECORD" "$LIVE_SETTINGS" "$MERGED_SETTINGS" >/dev/null 2>&1 \
                || drift="~/.claude/settings.json was not generated by setup.sh, and holds values the result would lose:"
        fi
    fi
    if [ -n "$drift" ]; then
        echo "$drift" >&2
        if [ ! -L "$LIVE_SETTINGS" ]; then
            # Exit 1 is a difference, and 2 a file that can't be read, reported by the script.
            python3 "$MERGE_SETTINGS" drift "$drift_record" "$LIVE_SETTINGS" "$MERGED_SETTINGS" | sed 's/^/  /' >&2 || true
        fi
        if [ "$FORCE_SETTINGS" = 1 ]; then
            echo "--force-settings: replacing it, and discarding what is shown above." >&2
        else
            settings_stop "the live settings hold something setup.sh would overwrite."
            echo "  Move the change to $SETTINGS_OVERLAY and run this again," >&2
            echo "  or pass --force-settings to discard it." >&2
            exit 1
        fi
    fi
fi

# --- Ordinary destinations: decided before anything is written ---
# The files below hold nothing setup.sh generates and have no check of their own, unlike
# settings.json (the drift stop) and the identity files (their preflight). install_file's rm would destroy whatever a person had there, so:
#
#   a link to its source or a byte-identical real file   is replaced
#   a link into the old checkout, with the flag          is replaced
#   anything else, without the flag                      is moved aside and reported, except
#                                                        at the two files below
#   anything else, with the flag                         refuses the run, before any write
#
# ~/.claude/CLAUDE.md and ~/.tmux.conf are files a person writes for themselves, and this
# repo's versions are samples of them, so without the flag anything else there stays where it
# is, nothing is installed, and the report names the sample. Moving one aside would swap a
# person's working setup for someone else's preferences. A stale copy of ours counts as theirs,
# because its bytes are all there is to tell the two apart.
#
# The flag refuses because a migration must touch only what it recognizes. A link is judged
# as a link: its target's bytes say nothing about whose link it is, and `cmp` would follow it.
#
# With --user-instructions, ~/.claude/CLAUDE.md comes from that file, and what counts as ours
# there is what would count for it or for the sample. The sample's link is the one a machine
# has before it names a file of its own, so it is replaced rather than kept.
each_ordinary() {         # $1 = the function to call with a source and a destination
    "$1" "$DOTFILES/claude/statusline-command.sh" ~/.claude/statusline-command.sh
    "$1" "$DOTFILES/claude/hooks/guard-codex-exec.py" ~/.claude/hooks/guard-codex-exec.py
    "$1" "$CLAUDE_MD_SOURCE" ~/.claude/CLAUDE.md
    "$1" "$DOTFILES/tmux/tmux.conf" ~/.tmux.conf
}
is_ours_as() {            # $1 = a source, $2 = destination
    if [ -L "$2" ]; then
        [ "$(readlink "$2")" = "$1" ] || [ "$2" -ef "$1" ] || is_old_link "$2"
    else
        [ -f "$2" ] && cmp -s "$1" "$2"
    fi
}
ordinary_is_ours() {      # $1 = source, $2 = destination
    is_ours_as "$1" "$2" && return 0
    [ "$1" = "$CLAUDE_MD_SOURCE" ] && [ "$1" != "$CLAUDE_MD_SAMPLE" ] && is_ours_as "$CLAUDE_MD_SAMPLE" "$2"
}
ordinary_problems=""
ordinary_existing=""
note_existing() {         # $1 = source, $2 = destination
    local physical
    if [ -e "$2" ] && physical="$(physical_path "$2")"; then
        ordinary_existing="$ordinary_existing
$physical"
    fi
}
check_foreign() {         # $1 = source, $2 = destination
    { [ -e "$2" ] || [ -L "$2" ]; } || return 0
    ordinary_is_ours "$1" "$2" && return 0
    ordinary_problems="$ordinary_problems  $2 exists and is not this repo's: move it aside first
"
}
# A destination that is its own source, through a link in either direction or a linked folder
# above it, looks byte-identical, and replacing it would destroy the source.
check_reach() {           # $1 = source, $2 = destination
    local reached
    [ -e "$1" ] || return 0
    reached="$(reached_destination "$1" "$ordinary_existing")"
    [ -z "$reached" ] || ordinary_problems="$ordinary_problems  source $1 reaches the destination $reached: installing would destroy it
"
}
each_ordinary note_existing
each_ordinary check_reach
[ -z "$REPLACE_FROM" ] || each_ordinary check_foreign
# AGENTS.md is generated, so only a file generated by this script is its own: a real file whose
# first line is the whole marker this script writes, its fixed start and end around at least one
# name. A first line with the start alone could be anyone's own header. A link never is, with or without --replace-links-from: no run of this
# script makes one, so a link there is someone else's, and writing over it would lose it.
agents_is_ours() {
    local first=""
    [ -f "$AGENTS" ] && [ ! -L "$AGENTS" ] || return 1
    IFS= read -r first < "$AGENTS" || [ -n "$first" ] || return 1
    case "$first" in "$AGENTS_MARK"?*"$AGENTS_MARK_END") return 0 ;; esac
    return 1
}
if [ "${#codex_files[@]}" -gt 0 ] && [ -d "$CODEX_DIR" ] && { [ -e "$AGENTS" ] || [ -L "$AGENTS" ]; } \
        && ! agents_is_ours; then
    ordinary_problems="$ordinary_problems  $AGENTS exists and was not generated by setup.sh: move it aside first
"
fi
if [ -n "$ordinary_problems" ]; then
    echo "setup.sh: refusing; nothing was written." >&2
    printf '%s' "$ordinary_problems" >&2
    exit 1
fi
moved_aside=""
move_aside_foreign() {    # $1 = source, $2 = destination
    { [ -e "$2" ] || [ -L "$2" ]; } || return 0
    ! ordinary_is_ours "$1" "$2" || return 0
    local backup="$2.pre-dotfiles" n=0
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        n=$((n + 1))
        backup="$2.pre-dotfiles.$n"
    done
    mv "$2" "$backup"
    moved_aside="$moved_aside
  $2 -> $backup"
}
place_file() {            # $1 = source in this repo, $2 = destination
    need_source "$1"
    move_aside_foreign "$1" "$2"
    install_file "$1" "$2"
}
kept_files=""
# With --replace-links-from nothing foreign reaches this: check_foreign has refused the run.
place_unless_own() {      # $1 = source, $2 = destination, $3 = its name in the report
    need_source "$1"
    if { [ -e "$2" ] || [ -L "$2" ]; } && ! ordinary_is_ours "$1" "$2"; then
        if [ "$1" = "$CLAUDE_MD_SOURCE" ] && [ "$1" != "$CLAUDE_MD_SAMPLE" ]; then
            kept_files="$kept_files
Kept your $3. The --user-instructions file, $1, was not installed there."
        else
            kept_files="$kept_files
Kept your $3. The sample is at $1."
        fi
        return 0
    fi
    install_file "$1" "$2"
}

# Writes the result as a real file, never through a link. Private settings can hold secrets,
# so only the owner can read it. A file that only reordered its keys is left as it is.
install_settings() {
    local tmp="$LIVE_SETTINGS.new.$$"
    if [ -L "$LIVE_SETTINGS" ] || [ ! -f "$LIVE_SETTINGS" ] || ! same_settings "$LIVE_SETTINGS" "$MERGED_SETTINGS"; then
        cp "$MERGED_SETTINGS" "$tmp"; chmod 600 "$tmp"
        [ ! -L "$LIVE_SETTINGS" ] || rm -f "$LIVE_SETTINGS"
        mv -f "$tmp" "$LIVE_SETTINGS"
    fi
    if ! cmp -s "$MERGED_SETTINGS" "$SETTINGS_RECORD"; then
        cp "$MERGED_SETTINGS" "$tmp"; chmod 600 "$tmp"
        rm -f "$SETTINGS_RECORD"
        mv -f "$tmp" "$SETTINGS_RECORD"
    fi
}

# --- Claude Code settings ---
mkdir -p ~/.claude
[ "$settings_state" != generate ] || install_settings
place_file "$DOTFILES/claude/statusline-command.sh" ~/.claude/statusline-command.sh

# --- Claude Code hooks ---
# settings.json wires a PreToolUse hook at ~/.claude/hooks/guard-codex-exec.py, so the two
# install together. Settings naming a hook that isn't there leave the guard silently absent,
# with the hook command pointing at a missing file on every Bash call.
mkdir -p ~/.claude/hooks
place_file "$DOTFILES/claude/hooks/guard-codex-exec.py" ~/.claude/hooks/guard-codex-exec.py

# No git hooks are installed. The lines Claude Code adds to commits are a setting,
# `attribution`, which the overlay can set. Installing a commit-msg hook means pointing
# core.hooksPath at this checkout, which silently disables every repository's own .git/hooks.

# --- Instructions: user scope ---
place_unless_own "$CLAUDE_MD_SOURCE" ~/.claude/CLAUDE.md "~/.claude/CLAUDE.md"

# --- tmux config ---
place_unless_own "$DOTFILES/tmux/tmux.conf" ~/.tmux.conf "~/.tmux.conf"

# --- Codex ---
# Only on a machine that already has Codex: a machine without it gets no ~/.codex.
#
# config.toml cannot be a link: Codex writes its per-directory trust entries into it as you
# work. codex/merge_config.py sets the shared keys in place and touches no other line. A
# shared file with nothing but comments sets no key, so the file isn't touched at all.
codex_config=""
if [ -d "$CODEX_DIR" ]; then
    if [ ! -r "$DOTFILES/codex/config.toml" ]; then
        echo "setup.sh: can't read $DOTFILES/codex/config.toml" >&2
        exit 1
    elif ! grep -qv -e '^[[:space:]]*$' -e '^[[:space:]]*#' "$DOTFILES/codex/config.toml"; then
        codex_config=none
    elif command -v python3 >/dev/null 2>&1; then
        python3 "$DOTFILES/codex/merge_config.py" "$DOTFILES/codex/config.toml" \
            "$CODEX_DIR/config.toml" >/dev/null
        codex_config=merged
    else
        codex_config=skipped
    fi
fi

# AGENTS.md is built in a temporary file beside it and moved over it, so Codex never reads half
# a file. The build runs in a subshell, and each step that can fail exits it, because errexit is
# off inside a list followed by ||: a file that can't be read stops the run and leaves the old
# AGENTS.md as it was. When the bytes already match, the file is left as it is, mtime included.
# Under --copy nothing differs: the file never depended on the checkout.
agents_state=""
if [ "${#codex_files[@]}" -gt 0 ]; then
    if [ ! -d "$CODEX_DIR" ]; then
        agents_state=no-codex
    else
        agents_tmp="$(mktemp "$CODEX_DIR/.AGENTS.md.XXXXXX")" \
            || { echo "setup.sh: can't write in $CODEX_DIR" >&2; exit 1; }
        (
            printf '%s%s%s\n' "$AGENTS_MARK" "$codex_names" "$AGENTS_MARK_END" || exit 1
            prev=""
            for f in "${codex_files[@]}"; do
                if [ -n "$prev" ]; then
                    # The blank line goes after a final newline, which the file may lack.
                    last="$(tail -c 1 "$prev")" || exit 1
                    [ -z "$last" ] || printf '\n' || exit 1
                    printf '\n' || exit 1
                fi
                cat "$f" || exit 1
                prev="$f"
            done
        ) > "$agents_tmp" && chmod 0644 "$agents_tmp" \
            || { rm -f "$agents_tmp"; echo "setup.sh: can't build $AGENTS from its files; it was left as it was" >&2; exit 1; }
        if [ -f "$AGENTS" ] && cmp -s "$agents_tmp" "$AGENTS"; then
            rm -f "$agents_tmp"; agents_state=unchanged
        else
            mv -f "$agents_tmp" "$AGENTS" \
                || { rm -f "$agents_tmp"; echo "setup.sh: can't write $AGENTS" >&2; exit 1; }
            agents_state=generated
        fi
    fi
fi

# --- Starter files: created when absent, then the installer's own ---
# Real files, not links, and every suggestion commented out, so an unedited one does nothing.
# The identity ones stay in their own folder: where git and ssh read, --git-identity's
# preflight would refuse them as someone else's files. Nothing in this script names these
# destinations for install_file, so its rm can't reach them. Anything already there is kept,
# even a dangling link. Failing to create one is reported, not fatal: nothing depends on it.
starters_created=""
starters_failed=""
starter() {               # $1 = source under starters/, $2 = path under HOME
    local dest="$HOME/$2"
    if [ -e "$dest" ] || [ -L "$dest" ]; then return 0; fi
    if mkdir -p "$(dirname "$dest")" 2>/dev/null && cp "$DOTFILES/starters/$1" "$dest" 2>/dev/null; then
        starters_created="$starters_created
  ~/$2"
    else
        starters_failed="$starters_failed
  ~/$2"
    fi
}
if [ "$NO_STARTERS" = 0 ]; then
    starter identity/owners .config/dotfiles/identity/owners
    starter identity/git/config .config/dotfiles/identity/git/config
    starter identity/git/identity-alice .config/dotfiles/identity/git/identity-alice
    starter identity/git/allowed_signers .config/dotfiles/identity/git/allowed_signers
    starter identity/ssh/github.conf .config/dotfiles/identity/ssh/github.conf
    starter accounts .config/git/accounts
    starter repo-roots .config/git/repo-roots
    starter tmux-local.conf .config/tmux/local.conf
    # An overlay named on the command line replaces this one, so it needs no starter.
    if [ "${DEFAULT_OVERLAY:-0}" = 1 ]; then
        starter settings-overlay.json .config/dotfiles/settings-overlay.json
        starter settings-overlay.README .config/dotfiles/settings-overlay.README
    fi
fi

# --- Skills: reported, never installed ---
# This script installs nothing it does not own, and it does not own skills. Skills come
# from somewhere else, with an installer of their own. Every other line above links a
# file that lives in THIS repository; calling another project's installer would reach
# into a checkout this script neither controls nor inspects.
#
# Calling that installer from here would add automation, not capability, and a failure
# this script could not see. It would run whatever checkout sits at a fixed path, and
# nothing here can tell whether that checkout is the current one. An older one would
# replace newer skills, restore retired ones, and still report success.
#
# So reporting is the whole job. A machine that already has skills is not improved by
# installing them again.
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"
skill_count=0
for d in "$SKILLS_DIR"/*/; do
    if [ -f "$d/SKILL.md" ]; then skill_count=$((skill_count + 1)); fi
done

# --- Report ---
# Says which mode ran, and an arrow means a link. settings.json is generated in both modes,
# so it gets no arrow. Under --copy the arrows would be a lie, and the last line is the
# part that matters: a copy does not track this checkout, so a later edit here needs a
# re-run to reach the machine.
if [ "$MODE" = copy ]; then
    echo "Dotfiles installed as COPIES:"
    sep="="
else
    echo "Dotfiles installed:"
    sep="->"
fi
if [ "$settings_state" = generate ]; then
    echo "  ~/.claude/settings.json: generated from $DOTFILES/claude/settings.json and $SETTINGS_OVERLAY"
else
    echo "  (~/.claude/settings.json not generated and left as it was: python3 is missing)"
fi
echo "  ~/.claude/statusline-command.sh $sep $DOTFILES/claude/statusline-command.sh"
echo "  ~/.claude/hooks/guard-codex-exec.py $sep $DOTFILES/claude/hooks/guard-codex-exec.py"
report_unless_kept() {    # $1 = the name in the report, $2 = source
    case "$kept_files" in
        *"Kept your $1."*) ;;
        *) echo "  $1 $sep $2" ;;
    esac
}
report_unless_kept "~/.claude/CLAUDE.md" "$CLAUDE_MD_SOURCE"
report_unless_kept "~/.tmux.conf" "$DOTFILES/tmux/tmux.conf"
case "$codex_config" in
    merged)  echo "  $CODEX_DIR/config.toml: shared keys from $DOTFILES/codex/config.toml set" ;;
    none)    echo "  ($CODEX_DIR/config.toml left as it is: $DOTFILES/codex/config.toml sets no shared Codex keys)" ;;
    skipped) echo "  (Codex config not merged: python3 is missing)" ;;
esac
case "$agents_state" in
    generated) echo "  $AGENTS: generated from $codex_names" ;;
    unchanged) echo "  ($AGENTS unchanged: already generated from $codex_names)" ;;
    no-codex)  echo "  (no Codex folder at $CODEX_DIR, so no AGENTS.md was made)" ;;
esac
if [ -n "$kept_files" ]; then
    printf '%s\n' "$kept_files"
fi
if [ -n "$moved_aside" ]; then
    echo
    echo "Moved aside, because they were not this repo's. Nothing was deleted:$moved_aside"
fi
if [ -n "$starters_created" ]; then
    echo
    echo "Starter files created, all suggestions commented out. They are yours to edit, and"
    echo "setup.sh never changes them again:$starters_created"
fi
if [ -n "$starters_failed" ]; then
    echo
    echo "Starter files that could not be created:$starters_failed"
fi
if [ "$MODE" = copy ]; then
    echo
    echo "  These are copies, not links. Editing this checkout will NOT change them;"
    echo "  re-run setup.sh to update the machine."
fi
echo
if [ "$skill_count" -gt 0 ]; then
    echo "Skills: $skill_count installed at $SKILLS_DIR — not managed by this script."
else
    echo "Skills: none installed at $SKILLS_DIR. This script does not install them;"
    echo "  install them with whatever installs your skills."
fi

# --- Outside requirements: reported, never installed ---
# Same rule as skills: these are not this repository's to install, but a file it installs
# fails quietly without them. Without jq the status line shows `/` for every directory; the
# codex guard hook cannot run without python3; tmux.conf's last line runs the tmux plugin
# manager.
missing=0
command -v jq >/dev/null 2>&1 || { [ "$missing" -eq 0 ] && echo; echo "Missing: jq — the status line needs it."; missing=1; }
command -v python3 >/dev/null 2>&1 || { [ "$missing" -eq 0 ] && echo; echo "Missing: python3 — the codex guard hook needs it."; missing=1; }
if [ ! -d ~/.tmux/plugins/tpm ]; then
    [ "$missing" -eq 0 ] && echo
    echo "Missing: the tmux plugin manager, which tmux.conf loads. To install:"
    echo "  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm"
    echo "  then in tmux press prefix + I to fetch tmux-resurrect"
fi
