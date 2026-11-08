# dotfiles

A setup for [Claude Code](https://docs.claude.com/en/docs/claude-code) and Codex: instruction
files, settings, a status line, one safety hook, a tmux configuration, and the script that
installs them. It also carries an optional component that sends every git commit and push out
as the right GitHub account.

MIT licensed. See `LICENSE`.

**Releases are snapshots.** Each release replaces the files here with a new copy, so the history
holds only releases. A pull request can't be merged as it stands. An issue or a patch is welcome:
the change is made by hand and arrives in a later release, not under its own commit.

---

## How it fits together

This repo is a public base. It holds the files that are the same for everyone, and nothing about
you. Your private details, such as your GitHub accounts, your Claude Code settings and notes about
your own projects, live in a layer on top that this repo never contains.

The dependency runs one way. Your layer calls this repo's `setup.sh` and passes it your files.
This repo never refers to your layer, so you can pull a new release without merging anything.

You can hold that layer in either of two ways:

- **Files on one machine.** A plain run creates starter files under `~/.config/`, and you edit them
  there. See *Starter files*.
- **A private repo of your own,** for several machines. It holds the same data, plus a short
  `setup.sh` that runs this one with options. See *Keeping your private layer in a repo of your own*.

Start with the first if you have one machine. Move to the second when another machine needs the
same accounts and settings.

---

## Install it

```bash
git clone https://github.com/rosslevinsky/dotfiles.git
bash dotfiles/setup.sh
```

`setup.sh` is safe to run again at any time, and it reports what it did. It installs:

- `~/.claude/settings.json`, generated from `claude/settings.json` and your overlay
- the status line, `~/.claude/statusline-command.sh`
- the codex guard hook, `~/.claude/hooks/guard-codex-exec.py`, which refuses a `codex exec`
  that would hang waiting on stdin
- the user instruction file, `~/.claude/CLAUDE.md`, from `claude/CLAUDE.md`, or from the file you
  name with `--user-instructions <file>`. The repo's file is a short sample of what such a file
  holds, to replace with your own. One you already have stays in its place
- `~/.tmux.conf`, a sample too. One you already have stays in its place
- on a machine that has Codex (`~/.codex` exists), any keys `codex/config.toml` sets, set in place
  in `~/.codex/config.toml`. It isn't a link, because Codex writes its trusted-folder list into it.
  As shipped, `codex/config.toml` sets no key, so the file isn't touched. The merge only sets keys,
  so a key removed from `codex/config.toml` keeps its last value there
- with `--codex-instructions <file>`, on a machine that has Codex, `~/.codex/AGENTS.md`, generated
  from the files you name. See *Codex's instructions*
- the starter files described below

**Make the samples yours before you edit them.** With links, `~/.claude/CLAUDE.md` and
`~/.tmux.conf` point into this checkout, so an edit there changes this repo's file. Turn each into
a file of your own first:

```bash
cp ~/.claude/CLAUDE.md ~/.claude/CLAUDE.md.mine && rm ~/.claude/CLAUDE.md && mv ~/.claude/CLAUDE.md.mine ~/.claude/CLAUDE.md
cp ~/.tmux.conf ~/.tmux.conf.mine && rm ~/.tmux.conf && mv ~/.tmux.conf.mine ~/.tmux.conf
```

From then on `setup.sh` keeps them, and the report says so. To keep your own `CLAUDE.md` in git,
put it in a repo of yours and pass it on every run:

```bash
bash dotfiles/setup.sh --user-instructions ~/src/my-config/claude/CLAUDE.md
```

`~/.claude/CLAUDE.md` is then a link to that file, or a copy with `--copy`, and counts as this
run's own, the way the sample does. A private repo's wrapper can pass it for you: see *Keeping your
private layer in a repo of your own*.

It does not install skills: install them with whatever installs your skills, and see *Things that
will catch you out* for why. It does not install a workspace file (a `CLAUDE.md` in the folder
above your repos) either, because such a file names your own projects. A private repo of your own
can install one. See *What loads, and when*. Without `--codex-instructions` it never touches
Codex's instructions, `~/.codex/AGENTS.md`.

**It also needs three things it does not install:** `jq` (without it the status line shows `/`
for every directory and drops the model and branch), `python3` (the settings merge and the codex
guard hook), and the tmux plugin manager at `~/.tmux/plugins/tpm`, which `tmux.conf` loads.
`setup.sh` names whichever is missing, and prints the clone command for the plugin manager.

### Codex's instructions

Claude reads `~/.claude/CLAUDE.md` and every file in `~/.claude/rules/`. Codex reads one user file,
`AGENTS.md` in its folder (`CODEX_HOME`, or `~/.codex`). To give Codex the same text, name each file
it should hold, in order:

```bash
bash dotfiles/setup.sh --codex-instructions ~/src/my-config/claude/CLAUDE.md \
    --codex-instructions ~/src/my-config/claude/rules/style.md
```

**It is a generated file, not a link.** A link can show Codex only one file, and you may have
several. So `setup.sh` writes `AGENTS.md` as a real file: a first line saying it was generated and
from which files, then each file in the order given, with a blank line between two. The file names
start with `~/` where they are under your home folder, so the file names no machine's home. It is the same file with
`--copy`, since it never depended on this checkout.

Because it is a copy of your files, an edit to one of them reaches Codex on the next run, not
before. A run that would write the same bytes leaves the file alone, its modification time
included. The file is built beside the old one and then moved into place, so Codex never reads half
of it, and a file that can't be read stops the run with the old `AGENTS.md` kept.

- **Only a file with that whole first line, as `setup.sh` writes it, is this run's own.** Anything
  else at `AGENTS.md`, a file of your own or any link, stops the run before it writes anything, and
  the message names the path.
  `--replace-links-from` doesn't change that: no run of `setup.sh` makes a link there.
- **Each file you name must exist and be readable,** or the run stops before any write.
- **With no Codex folder,** nothing is made, and the report says so in one line.
- **A later run without the option** leaves the generated file as it is. Delete it yourself if you
  no longer want it.

### Links or copies

```bash
bash dotfiles/setup.sh           # the same as --link: links into this checkout
bash dotfiles/setup.sh --copy    # real files, for a machine that won't keep the checkout
```

With links, an edit in this checkout is live at once, which suits a machine where you edit these
files. On a machine you will hand back, or where you will delete the clone, links would dangle,
so use `--copy`. The trade is that a copy doesn't track the repo: the machine keeps the old
version until you run `setup.sh --copy` again. You can switch modes in either direction. The two
files in *If something is already there* are the exception: an older copy of either no longer
matches this repo, so it counts as yours until you delete it.

### If something is already there

- **Your own `~/.claude/CLAUDE.md` or `~/.tmux.conf`,** or a link there that isn't this repo's,
  stays in place on a plain or `--copy` run. Nothing is installed there, and the report says, for
  example, `Kept your ~/.tmux.conf. The sample is at <path>.` A link from this repo or a
  byte-identical copy counts as this repo's, and is replaced as usual. With your own `~/.tmux.conf`,
  `~/.config/tmux/local.conf` does nothing unless your file reads it. With
  `--user-instructions <file>`, a link to that file or to the sample, or a byte-identical copy of
  either, counts as this run's own and is replaced. Anything else at `~/.claude/CLAUDE.md` stays,
  and the report names the file that wasn't installed. A named file must exist.
- **Any other file or link that isn't this repo's** is moved to `<destination>.pre-dotfiles`,
  or `.pre-dotfiles.N` when that name is taken, and the report names it. Nothing is deleted.
- **`~/.claude/settings.json`** stops the run instead; see *Settings*.
- **Codex's `AGENTS.md`,** with `--codex-instructions`, stops the run unless `setup.sh` generated
  it; see *Codex's instructions*.
- **Identity files** make `--git-identity` refuse before it writes anything.
- **A checkout you moved or renamed** leaves links pointing at the old path. They look like
  someone else's files, so tell `setup.sh` about the old path:

  ```bash
  bash dotfiles/setup.sh --replace-links-from /old/path/to/dotfiles
  bash dotfiles/setup.sh --git-identity --replace-links-from /old/path/to/dotfiles
  ```

  The path must be absolute. A link into it counts as this repo's, even if it dangles, and so does
  a link to the `--user-instructions` file. With this flag nothing is moved aside or kept: anything
  else at a destination, those two files included, refuses the whole run before any write, because
  a migration should touch only what it recognizes.

---

## The layers

Each layer adds to the one before it, and you can stop at any of them. Everything above the base
is your private layer, and each part of it can live in one of two places: in files on this machine,
or in a private repo of your own (see *How it fits together*).

| Layer | What it holds | On one machine | In a private repo of your own |
|---|---|---|---|
| base | this repo's files | `setup.sh` | the wrapper runs `setup.sh --no-starters` |
| settings overlay | your own Claude Code settings | edit `~/.config/dotfiles/settings-overlay.json` | `settings-overlay.json`, passed with `--settings-overlay <file>` |
| user instructions | your own `~/.claude/CLAUDE.md` | make the sample yours, as in *Install it* | `claude/CLAUDE.md`, passed with `--user-instructions <file>`, and the rules in `<your repo>/claude/rules/`, which the wrapper links. Both go to Codex with `--codex-instructions <file>` |
| identity data | who to route, and the files that do it | edit `~/.config/dotfiles/identity/`, then run `setup.sh --git-identity` | `owners`, `git/` and `ssh/`, passed with `--identity-dir <dir>` |
| workspace file | instructions for every repo in one folder | write it yourself | a `CLAUDE.md` in your repo's `workspace/` folder, which the wrapper links |
| machine-local files | tmux settings, and the accounts and folders this machine has | edit the starter files | the same: they differ per machine, so they stay out of the repo |

### Settings

`~/.claude/settings.json` is a real file that `setup.sh` generates, in both install modes. It
can't be a link, because Claude Code writes changes back into it. The base,
`claude/settings.json`, holds only what the installed files need: the hook and the status line.
Your model, theme, plugins, permissions and commit attribution go in the overlay. In particular,
the base grants no permission to run commands without asking.

The merge is simple. Objects merge key by key, and any other value in the overlay replaces the
base's, arrays included. A missing overlay and an empty one give the same result. A file named
with `--settings-overlay` must exist, so a typo can't silently drop your settings.

**The drift stop.** Each run records what it generated in `~/.claude/settings.json.generated`. If
the live file holds a change that the record doesn't and the new result wouldn't keep, `setup.sh`
shows the difference and stops before changing anything. A reordering alone doesn't count, since
Claude Code reorders keys. To go on, either:

- move the change to the overlay and run `setup.sh` again, or
- pass `--force-settings` to discard it.

On a first install there is no record yet, so a `settings.json` you already have counts as all
change. Copy every value from it into the overlay, and the run goes on: the result keeps each of
your values and adds the base's keys. Any value left out, or one the overlay changes, stops it and
is shown.

A change to the base or the overlay, with no edit to the live file, applies without either. With
`python3` missing, the file is left as it was and the report says so.

### Starter files

A plain run creates each of these only if nothing is at that path, and never changes one again.
They are real files, yours to edit, and the report names each one it creates. Every suggestion in
them is commented out and uses the fictional account `alice`, so an unedited file does nothing:
it can't imply that an account exists, and `git-identity-check` treats it as missing. Each file's
comments say how to fill it in and how to check the result. `--no-starters` creates none.

| Starter in this repo | Created at | What it is for |
|---|---|---|
| `starters/settings-overlay.json` | `~/.config/dotfiles/settings-overlay.json` | the overlay, an empty object at first. Not created when you pass `--settings-overlay` |
| `starters/settings-overlay.README` | `~/.config/dotfiles/settings-overlay.README` | guidance for the overlay, since JSON has no comments |
| `starters/tmux-local.conf` | `~/.config/tmux/local.conf` | this machine's tmux settings, read last so they win |
| `starters/accounts` | `~/.config/git/accounts` | the GitHub accounts this machine is meant to have |
| `starters/repo-roots` | `~/.config/git/repo-roots` | the folders `git-identity-check` scans |
| `starters/identity/owners` | `~/.config/dotfiles/identity/owners` | who to route |
| `starters/identity/git/config` | `~/.config/dotfiles/identity/git/config` | the routing |
| `starters/identity/git/identity-alice` | `~/.config/dotfiles/identity/git/identity-alice` | one identity, to rename |
| `starters/identity/git/allowed_signers` | `~/.config/dotfiles/identity/git/allowed_signers` | the signer list |
| `starters/identity/ssh/github.conf` | `~/.config/dotfiles/identity/ssh/github.conf` | the SSH aliases |

The identity starters have their own folder because git and ssh don't read it. In the places they
do read, a starter would make `--git-identity` refuse it as someone else's file.

---

## Keeping your private layer in a repo of your own

Use this when more than one machine should get the same accounts and settings. You make a private
repo, put your data in it, and clone it beside this one on each machine. Its `setup.sh` runs this
repo's `setup.sh` with options that point at your data.

### The layout

```
~/src/dotfiles/                          a clone of this repo, the base
~/src/my-config/                         your private repo, holding:
~/src/my-config/setup.sh                 the wrapper, copied from examples/private-layer/setup.sh
~/src/my-config/owners                   the identity data folder, in the shape --identity-dir
~/src/my-config/git/config               describes: who to route, the routing, one file per
~/src/my-config/git/identity-*           identity, the signer list and the SSH aliases
~/src/my-config/git/allowed_signers
~/src/my-config/ssh/github.conf
~/src/my-config/settings-overlay.json    your Claude Code settings
~/src/my-config/claude/CLAUDE.md         optional: your user instructions, as ~/.claude/CLAUDE.md
~/src/my-config/claude/rules/*.md        optional: more user instructions, each linked into
                                         ~/.claude/rules/
~/src/my-config/workspace/CLAUDE.md      optional: linked as ~/src/CLAUDE.md
```

The names are examples. The wrapper looks for the base in a folder called `dotfiles` beside your
repo, or wherever `DOTFILES_BASE` says. The folder that holds both checkouts is the workspace
folder, and a `CLAUDE.md` there is read in every repo under it. It can't be your home folder or a
folder that holds it, because a `CLAUDE.md` there would load for everything you open. Where Codex
is, the base generates `~/.codex/AGENTS.md` from `claude/CLAUDE.md` and then the rules.

### Starting the repo

Start from this repo's starters:

```bash
mkdir -p ~/src/my-config/workspace
cd ~/src/my-config && git init
cp -R ../dotfiles/starters/identity/. .
cp ../dotfiles/starters/settings-overlay.json ../dotfiles/starters/settings-overlay.README .
cp ../dotfiles/examples/private-layer/setup.sh .
cp ../dotfiles/examples/private-layer/workspace-CLAUDE.md workspace/CLAUDE.md
```

Then rename `~/src/my-config/git/identity-alice` after your own account and fill in each file.
Their comments say how: `settings-overlay.README` explains the overlay, with an example of each
common key. `workspace/CLAUDE.md` is a sample workspace file, read in every repo beside yours.
Replace its example sections with your own, or delete the `workspace` folder if you don't want one. Commit, and push to a private repository.

The identity data is optional. If you want only your settings and workspace notes in the repo,
delete `owners`, `git` and `ssh` from it. With no `owners` file, or one holding only comments, the
wrapper skips the identity install and says so.

**Never put private keys or tokens in any repo.** SSH keys stay in `~/.ssh` on the machine that
made them, and `gh` keeps its own tokens.

### Moving from files on one machine

If this machine already has its private layer under `~/.config/dotfiles/`, start the repo from
those files instead of the starters, so nothing you filled in is lost:

```bash
mkdir -p ~/src/my-config/workspace
cd ~/src/my-config && git init
cp -R ~/.config/dotfiles/identity/. .   # skip this line if you don't use git identity
cp ~/.config/dotfiles/settings-overlay.json .
cp ../dotfiles/examples/private-layer/setup.sh .
bash setup.sh
```

Skip the identity folder if you never filled it in, that is if `~/.config/dotfiles/identity/owners`
has only comments, or if you don't want the routing. If you copied it anyway, delete `owners`, `git`
and `ssh` from the repo before running the wrapper.

Copy them unchanged, and run the wrapper before you edit them. The identity install then counts
each old link as its own, because the file it points to has the same bytes, and points it at your
repo instead. If you edited a file first, that run refuses it as someone else's. Pass the old
folder to replace those links anyway. As in *Moving or renaming a checkout*, a `~/.claude/CLAUDE.md`
or `~/.tmux.conf` of your own must be moved aside for a run with this flag:

```bash
bash ~/src/my-config/setup.sh --replace-links-from ~/.config/dotfiles/identity
```

Once the run succeeds, check that no link still points into the old folder. This lists any that
do, and prints nothing when there are none:

```bash
ls -l ~/.claude ~/.claude/rules ~/.config/git ~/.ssh/config.d ~/.local/bin 2>/dev/null | grep '/\.config/dotfiles/'
```

A link left over is usually an identity you took out of `owners` earlier: the install never
removes the link for an identity it no longer names. If you still need that identity, add it back
to `owners` in your repo, copy its file into the repo's `git/`, and run the wrapper again.
Otherwise delete the link. When the check prints nothing, delete the old folder, so the repo is the
only copy. The per-machine files in `~/.config/git/` and `~/.config/tmux/` stay where they are.

```bash
rm -r ~/.config/dotfiles
```

### What stays on each machine

Three files differ from machine to machine, so they stay out of the repo. Copy each one that isn't
there yet, and edit them on the machine:

```bash
mkdir -p ~/.config/git ~/.config/tmux
[ -e ~/.config/git/accounts ] || cp ~/src/dotfiles/starters/accounts ~/.config/git/accounts
[ -e ~/.config/git/repo-roots ] || cp ~/src/dotfiles/starters/repo-roots ~/.config/git/repo-roots
[ -e ~/.config/tmux/local.conf ] || cp ~/src/dotfiles/starters/tmux-local.conf ~/.config/tmux/local.conf
```

`accounts` lists the GitHub accounts this machine has, `repo-roots` the folders
`git-identity-check` scans (without it, `~/src`, three folders down), and `local.conf` this
machine's tmux settings.

### The wrapper

`examples/private-layer/setup.sh` is a complete wrapper with made-up names. Copy it and change
what you need. Each run:

1. Checks first, and writes nothing until the checks pass: the base checkout and `python3` are
   there, the workspace folder is not your home folder and doesn't hold it, and any `CLAUDE.md`
   there is the wrapper's own link. A file of yours, or a link to anything else, stops the run.
   The same goes for `~/.claude/rules/<name>.md` for each rule in `<your repo>/claude/rules/`.
   `claude/CLAUDE.md`, each rule and `workspace/CLAUDE.md` must be real files in real folders of
   your repo, not links. The checks also decide what steps 4 and 5 will do, so nothing the base
   run creates can change it.
2. Runs `setup.sh --git-identity --identity-dir <your repo>`, if your repo has an `owners` file.
   This goes first, so git routing works even if a later step stops.
3. Runs `setup.sh --no-starters --settings-overlay <your repo>/settings-overlay.json`, adding
   `--user-instructions <your repo>/claude/CLAUDE.md` when that file exists. Keeping the file in
   your repo means a pull updates it on every machine. It also adds `--codex-instructions` for
   `claude/CLAUDE.md`, then for each rule, sorted by name in byte order, so the base generates Codex's
   `AGENTS.md` from them where Codex's folder exists. The base's own checks for `AGENTS.md` run
   here, before it writes anything: see *Codex's instructions*.
4. Links your repo's `workspace` file as `CLAUDE.md` in the workspace folder, if there is one.
   Without it, the wrapper's own link there is removed and anything else is left alone.
5. Links each rule as `~/.claude/rules/<name>.md`. The wrapper's own link for a rule you deleted is
   removed, and any other file there is left alone.

**Codex gets the same instructions as Claude,** in one generated file, since Codex reads only one.
Claude follows a pull at once, through the links. Codex gets an edit on the next run. The exception
is a `~/.claude/CLAUDE.md` of your own, which the base keeps (see *If something is already there*):
Claude then reads that file, and Codex still gets your repo's. Move yours aside and run the wrapper
again to give both the repo's file. Only your repo's files go into `AGENTS.md`: a rule you keep
only on one machine, such as `~/.claude/rules/local.md`, reaches Claude but not Codex. With no
`claude/CLAUDE.md` and no rules, nothing goes to Codex, and an `AGENTS.md` there is left as it is, a
generated one included.

**The wrapper's own link is one it made.** Its target is exactly the path to your repo's file, as
the wrapper writes it. A link the wrapper didn't make, a relative one included, is left alone or
refused, even if it leads to the same file.

Steps 2 and 3 are the whole idea. Without the checks they come down to:

```bash
bash ~/src/dotfiles/setup.sh --git-identity --identity-dir ~/src/my-config
bash ~/src/dotfiles/setup.sh --no-starters --settings-overlay ~/src/my-config/settings-overlay.json
```

**A wrapper must pass `--no-starters`.** A plain run creates starters for a layer kept on one
machine, under `~/.config/dotfiles/`. Your repo holds that layer instead, so the starters would be
a second copy that looks real and does nothing: an edit there would change nothing. The flag turns
off every starter, which is why the per-machine files above are copied by hand.

On a new machine:

Steps 1, 4 and 7, and the identity part of step 6, apply only when your repo holds identity data.
With settings and workspace notes alone, skip them.

1. Make each account's SSH key on this machine, and add it on GitHub as both an authentication key
   and a signing key. Steps 2 and 3 of *Set up a machine* in `docs/git-identity.md` say how.
   Routing and signing both need these keys.
2. Make sure this machine can read your private repo: sign in with `gh auth login` and clone over
   HTTPS, or clone over SSH with a key that already has access.
3. Clone both:

   ```bash
   mkdir -p ~/src && cd ~/src
   git clone https://github.com/rosslevinsky/dotfiles.git
   git clone <your private repo> my-config
   ```

4. Add this machine's public keys to the signer list, so the commits it signs verify everywhere.
   In `~/src/my-config/git/allowed_signers`, add one line per address this machine signs as: the
   address, then the contents of that account's `~/.ssh/id_ed25519_<account>.pub`. Commit, push,
   and pull on your other machines. The signer list is a link there, so a pull is enough.
5. Copy the per-machine files, as in *What stays on each machine*, and fill them in.
6. Run the wrapper: `bash ~/src/my-config/setup.sh`. Do what its report lists as missing, such as
   the `Include` line in `~/.ssh/config`. Steps 6, 7 and 9 of the guide's *Set up a machine*
   cover the rest.
7. Check the machine, then make a commit in a routed repo and verify its signature:

   ```bash
   ~/.local/bin/git-identity-check --live
   git verify-commit HEAD
   ```

### Updating

```bash
git -C ~/src/dotfiles pull
git -C ~/src/my-config pull
bash ~/src/my-config/setup.sh
```

It is safe to run again: a second run changes nothing. With links, a pull already changes most
files. The run adds new ones and generates `~/.claude/settings.json` and Codex's `AGENTS.md` again.

### Moving or renaming a checkout

The links still point at the old path, so tell the wrapper about it:

```bash
bash ~/src/my-config/setup.sh --replace-links-from /old/path/to/dotfiles
```

It passes the flag to both runs of this repo's `setup.sh`. A workspace or rule link counts as the
wrapper's own when it points at your repo's file under that path, or, if you moved both checkouts
together, under the folder that held them: pass that folder. The path must be absolute, with no
`.` or `..` in it, and counts both as you write it and with its linked folders resolved. A refusal
names the link's target, so you can see which path to pass. With this flag, a `~/.claude/CLAUDE.md` or `~/.tmux.conf` of your own stops the run
(see *If something is already there*), so move yours aside for that one run and put it back after.

Codex's `AGENTS.md` needs nothing: it is a file, not a link, and the next run writes it again with
the new paths in its first line.

---

## Git identity

An optional component chooses the GitHub account for every commit and push by the repository's
owner, and refuses to commit when it can't tell. It is opt-in: only `setup.sh --git-identity`
installs it. `docs/git-identity.md` covers setup, the audit, `gh-as` and every failure it reports.

---

## What loads, and when

Claude reads instructions from several files at once. Starting at your working directory it walks
up the tree, collects every `CLAUDE.md` on the way, and joins them together root-first. Nothing
overrides anything among the files that load, so the only figure that matters is the total for one
session.

Claude reads a project's `AGENTS.md` too, but by default only when no `CLAUDE.md`, `.claude/CLAUDE.md`
or `CLAUDE.local.md` sits in the working directory or above it. Any of those makes Claude skip
`AGENTS.md`, a workspace file included. `~/.claude/CLAUDE.md` doesn't count, and it keeps loading
alongside `AGENTS.md`. The **Project instructions** option in `/config` changes this default.

| Tier | Claude reads it at | Loads | Comes from |
|---|---|---|---|
| user | `~/.claude/CLAUDE.md` | every session, every repo, this machine | `claude/CLAUDE.md`, or your `--user-instructions` file |
| user rules | `~/.claude/rules/<name>.md` | every session, like the user file | you, or a private repo of your own |
| workspace | `<folder holding your repos>/CLAUDE.md` | every repo under that folder | you, or the wrapper in a private repo of your own |
| repo | `<repo>/CLAUDE.md`, or `<repo>/AGENTS.md` when no `CLAUDE.md` counts | only in that repo | the repo |
| rule | `<repo>/.claude/rules/<name>.md` | only when you open a file its `paths:` matches | the repo |
| skills | `~/.claude/skills/<name>/SKILL.md` | every session: `name` and `description` only | whatever installs your skills |

`setup.sh` installs the first. It never touches the others.

Codex reads none of the Claude files above: no `CLAUDE.md` and no `.claude/` folder. It reads a
repo's own `AGENTS.md`, and one user file, `~/.codex/AGENTS.md`, or `AGENTS.md` in `CODEX_HOME`.
That file loads in every Codex session on the machine, like the user tier. `setup.sh` generates it
only when you pass `--codex-instructions`, joining the files you name, since Codex has no rules
folder to read them from. The wrapper in a private repo of your own passes your user instructions
and rules (see *Codex's instructions* and *The wrapper*). An edit to one of those files reaches
Codex on the next run.

Put a workspace file one level above your repos, so it is read inside every one of them and nowhere
else. In `$HOME` it would load for everything on the machine.

**Skills cost more than you would guess.** Every installed skill's name and description loads in
every session, because that is how Claude decides a skill is relevant. Only the description loads;
the body waits until the skill is used.

### Measuring it

```bash
bash tests/check_line_budget.sh
```

It reports the folder above this checkout and every repo in it, including a workspace file another
repo installed there. It reports lines and words separately because they disagree: a skill
description is a few lines carrying a paragraph each. Counting lines alone would also reward
reflowing a file instead of shortening it.

---

## Where to put a new fact

Ask these in order. Stop at the first one that answers.

**1. Can something check it?** → a hook, a test, or a setting. Not a sentence.

Prose is checked by nobody and goes stale quietly. Where a claim matters, write the thing that
breaks when it stops being true.

**2. Is it only true while a particular file is open?** → a `paths:`-scoped rule in that repo's
`.claude/rules/`.

A rule about editing one file should not load in sessions that never open it. A rule announces
itself by loading, so nothing needs to point at it.

**3. Is it a procedure you run, not a fact you need?** → a skill.

A ten-step runbook is a skill in the wrong container. Raising a line budget does not fix that.

**4. Is it already written somewhere that covers this case?** → write nothing, and delete the copy
you were about to add to. A rule kept in four places drifts in three.

**5. Only now — where is it true?** → that picks the tier.

| True… | Put it in |
|---|---|
| on one machine only | a rule in `~/.claude/rules/`, installed only where a marker exists |
| everywhere you personally work | `~/.claude/CLAUDE.md` |
| for every repo in the workspace | the workspace file |
| for one repo | that repo's own `CLAUDE.md` |

The first question comes first because every hard case turns on what *kind* of thing you have, and
the tier only matters once you know that.

---

## Things that will catch you out

**Imports do not save anything.** An imported file loads at launch exactly like the file that
imports it. Splitting a large `CLAUDE.md` into imports reorganizes it without reducing what a
session pays. Only `paths:` rules and skills genuinely defer.

**A `CLAUDE.md` has no conditional syntax.** It loads whole or not at all. That is why
machine-specific content belongs in its own file, installed only on the machines it is true of.

**A file reached by two paths loads once.** Installed from this repo, the user file is a symlink
into it, so a session inside `claude/` meets it twice. Claude deduplicates by real path.

**Claude's own memory does not travel.** Its notes under `~/.claude/projects/<project>/memory/` are
machine-local and in no repository. Anything there that is a durable rule belongs in a `CLAUDE.md`,
a skill, or a hook.

**This script doesn't install skills, on purpose.** Install them with whatever installs your skills.
Running another project's installer from here would run whatever checkout sits at a fixed path,
and nothing here can tell whether it is current. An older one would replace newer skills with older
ones, bring back retired ones, and still print success. The report at the end of a run only counts
the skills it finds.

---

## The checks

They are all cheap, and none touches your home: those that install use a throwaway one. They also run in CI
on every pull request and every push to `main`, on Linux and macOS. The identity suites also run on
git 2.43, in an `ubuntu:24.04` container. CI also runs `gitleaks` over the repository, pinned to one
version and checked against its published checksum.

```bash
bash tests/test_setup.sh
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/test_line_budget.sh
bash tests/test_readme_commands.sh
bash tests/test_statusline.sh
bash tests/test_git_identity.sh            # and: bash tests/test_git_identity.sh installed
bash tests/test_git_identity_check.sh
bash tests/test_gh_as.sh
bash tests/test_git_identity_audit.sh
bash tests/test_private_layer.sh
```

The identity suites need git 2.36 or newer (for `hasconfig`), OpenSSH's `ssh-keygen` and `ssh`, and
`python3`. `tests/test_readme_commands.sh` needs an authenticated `gh`, to ask GitHub whether each
other repository the README names exists. `tests/check_line_budget.sh` needs Bash 4 or newer, so on macOS run it with a
newer bash than the stock `/bin/bash` 3.2. There, `tests/test_line_budget.sh` says it skipped,
except in CI, where it fails instead. The rest need only POSIX tools.

They run on fictional accounts: `alice`, the organization `acme`, `bob` and `carol`, under
`tests/fixtures/`.

| Suite | What it catches |
|---|---|
| `tests/test_setup.sh` | a link that dangles, a machine-specific file created or left where it should not be, a run that is not repeatable, a hook that has stopped denying what it exists to deny, settings that grant a blanket permission, `--user-instructions`, the settings merge and drift stop, `--codex-instructions` and the `AGENTS.md` it generates, starter files, moving a checkout, someone's file being lost or replaced, and skills being installed |
| `tests/test_guard_codex_exec.py` | the codex guard, running the real script in a subprocess. Every assertion is on the decision the hook returns, never its wording: searching a message for "deny" also matches a message explaining why something was allowed |
| `tests/test_merge_settings.py` | the merge rules, the parsed comparison, and what counts as drift |
| `tests/test_statusline.sh` | the status line at several terminal widths: the line count, no line overflowing, and the hostname first |
| `tests/check_line_budget.sh` | not a test but the tool: a file over 200 lines fails, and a session over 400 lines warns. The 200 comes from Claude Code's documentation, which says to target under 200 lines per `CLAUDE.md` file; failing at it is this repo's choice. The 400 is a judgment call, and as a hard failure it would invite cutting prose, when the real fix is moving file-conditional content into a `paths:` rule |
| `tests/test_line_budget.sh` | that the tool above measures something real: its figures against the installed user file, a person's own in its place, and a workspace file another repo installed, and that the limit fails |
| `tests/test_readme_commands.sh` | this file's and `docs/git-identity.md`'s instructions naming something that doesn't exist, a repository that doesn't exist, the wrong clone URL, a suite, flag or starter they leave out, and a pointer into that guide that lands on no heading |
| `tests/test_git_identity.sh` | the routing as git itself resolves it: each owner's rewritten fetch and push URLs, the author, committer and signing key, real signed commits, and the repos that must refuse to commit. It runs once on hand-placed files and once after a real `setup.sh --git-identity` |
| `tests/test_git_identity_check.sh` | breaks one thing at a time in a clean fixture home and expects `git-identity-check` to name that cause, with live SSH answers played back by a stub |
| `tests/test_git_identity_audit.sh` | `git-identity-audit` against a fake home for the machine that runs the audit and two fake remote machines reached through a stub ssh: the leak rules, every setup failure, refusing bad config, and that the standalone machine is sent nothing about other accounts and has nothing written |
| `tests/test_gh_as.sh` | `gh-as` against a stub gh: the token lookup, the refusals, argument passthrough, and that the token never reaches the screen, even under `bash -x` |
| `tests/test_private_layer.sh` | the sample wrapper in `examples/private-layer/`, run on a fake private repo beside a copy of this checkout: identity links into that repo, the overlay reaching the settings, the user instructions from that repo, no starters, the workspace link, the rule links, the files it gives Codex and in what order, what it must leave alone, a second run that changes nothing, a workspace file or folder it must refuse, a renamed checkout, a repo with no identity data, and moving from files on one machine |

---

## Recovery

```bash
ls -l ~/.claude
bash dotfiles/setup.sh
```

The first shows whether any symlink dangles. The second re-links everything this repo owns and is
safe to repeat.

**Editing a skill.** If your skills are installed as copies, `~/.claude/skills/` is not a working
tree, and an edit made there is lost on the next install. Edit the skill where it comes from. This
repo doesn't track skill files.
