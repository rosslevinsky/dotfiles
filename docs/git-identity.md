# Git identity

How to set up and run this repo's optional identity component. `README.md` covers the rest of the
setup, including the starter files this guide asks you to fill in.

This component chooses the GitHub account for every commit and push by the repository's owner, so
a repo owned by one account never gets a commit or a key from another. A repo with no GitHub
remote, or one from an owner you haven't listed, **refuses to commit**: there is no fallback
identity to leak. Every commit is SSH-signed.

It is opt-in. A plain `setup.sh`, or `--copy`, installs none of it, because it decides which
account every commit on the machine uses. `--git-identity` installs only this component, as links
and nothing else, so it can go on a machine that wants no other dotfiles. `--copy` is refused with
it, because a copy of the routing or the signer list would go stale with nothing to say so. Every
check runs before the first write.

## What it installs

Links, from the data folder (`~/.config/dotfiles/identity` unless you pass `--identity-dir <dir>`)
and from this checkout:

| From | To | What it does |
|---|---|---|
| `identity/owners` | `~/.config/git/owners` | who to route |
| `identity/git/config` | `~/.config/git/config` | rewrites each owner's URLs to its SSH alias, and picks its identity |
| `identity/git/identity-<name>` | `~/.config/git/identity-<name>` | one per identity the owners file names |
| `identity/git/allowed_signers` | `~/.config/git/allowed_signers` | the signer list |
| `identity/ssh/github.conf` | `~/.ssh/config.d/github.conf` | one key per SSH alias |
| `bin/gh-as`, `bin/git-identity-check`, `bin/git-identity-audit` | `~/.local/bin/` | the tools |

Git reads `~/.config/git/config` before `~/.gitconfig`, which stays yours for machine-local
settings. The data folder can live anywhere, including in a private repo of your own.

## Set up a machine

1. Run `bash dotfiles/setup.sh`, which creates the starter files.
2. For each account the machine needs, make a key **on this machine**, and never copy one:
   `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_<account>`.
3. On github.com, signed in as that account, add the public key twice under Settings → SSH and GPG
   keys: once as an **authentication** key and once as a **signing** key.
4. Fill in the identity starters in `~/.config/dotfiles/`, following the comments in each:
   `identity/owners`, `identity/git/config`, `identity/git/identity-alice` (renamed for your
   account), `identity/git/allowed_signers` and `identity/ssh/github.conf`.
5. List the accounts in `~/.config/git/accounts`, and the folders to scan in
   `~/.config/git/repo-roots`. Without that file the check scans `~/src`, three folders down.
6. In `~/.ssh/config`, before its first `Host` or `Match` line, add
   `Include config.d/github.conf`. Remove any `Host github.com` block, and any `IdentityFile` that
   applies to every host.
7. In `~/.gitconfig`, remove any `[user]` name, email or signingkey, and any `includeIf` or
   `insteadOf` rule.
8. Run `bash dotfiles/setup.sh --git-identity`.
9. If this machine has never connected to GitHub over SSH, run `ssh -T git@github.com` once. Compare
   the fingerprint it shows with
   [GitHub's published ones](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
   before accepting it. The check can't answer that prompt, so without this it reports
   `live-inconclusive`.
10. Run `~/.local/bin/git-identity-check --live`.

`setup.sh` doesn't do steps 6 and 7 for you, because they delete things from files that are yours.
It reports them, and the check fails until they're done.

**It worked when** `setup.sh` lists no `Missing:` or `Remove:` lines and the check ends with
`all checks passed`.

**Keys and signing.** Use one key per account per machine. Signing uses the private key's path,
which works with or without an agent. A key with a passphrase needs an agent, or every
non-interactive commit will block. To verify commits from another machine, add its public keys to
`identity/git/allowed_signers` in your data folder.

## Start a new repo, or give a repo an identity

- **New repo:** add its GitHub remote **before** the first commit. The remote is what picks the
  identity: `git remote add origin git@github.com:<owner>/<repo>.git`
- **A repo with no remote, or remotes of several owners** (a fork with an `upstream` remote
  counts): include one whole identity file. Never set `user.name` or `user.email` by hand:
  `git config --local include.path ~/.config/git/identity-<name>`

**It worked when** `git var GIT_AUTHOR_IDENT` prints the identity you meant.

## Audit every machine

`git-identity-audit` runs on one machine, the machine that runs the audit. From there it checks
every machine you list, and scans every repo's history for your own addresses in the wrong place.

```bash
git-identity-audit            # add --offline to skip the GitHub login probes
```

Run it after changing a machine or a key, and otherwise every so often. Nothing runs it for you.

- **Setup:** a machine with this component runs its own `git-identity-check`. A *standalone* machine
  is one that holds only some of your accounts and must not learn the others. It is checked by code
  the audit sends over ssh and runs in memory, so nothing is written there, and it's told only about
  its own accounts.
- **History:** a commit counts as a leak only when its address is **yours** (from the `mine` lines
  below, plus each account's noreply address) and isn't the identity that repo's owner should use.
  Other people's addresses are never reported. Keep hostname patterns to your own username: a bare
  `*@*.local` would also match colleagues.
  - `[leak-old]` lines are before `since`: history that predates the setup. They're reported, not
    failed, since fixing them means rewriting history.
  - `FAIL [leak-new]` means the setup has broken since.

It reads `~/.config/git/audit` on the machine that runs the audit, which is machine-local and never
committed:

```
machine laptop local component
machine server server.example.com component
machine work-box work-box.example.com standalone ~/code:3 ~:1
standalone-accounts work-box alice
mine alice@example.com
mine alice+*@example.com
mine alice@*.local
since YYYY-MM-DD
```

**It worked when** the last line is `all machines passed`.

## Run gh as a specific account

`gh-as <account> <gh arguments>`, for example `gh-as alice pr create --fill`.

Git needs nothing like this, since it routes by owner. `gh` always acts as its *active* account
(`gh auth status`). `gh-as` uses another account's stored token for one command without switching.
It refuses `gh auth`, and any `GH_HOST` or `GH_REPO` naming a host other than github.com.

## The check failed

`git-identity-check` names each problem with a tag. Fix it, then run the check again.

| Tag | What it means | Fix |
|---|---|---|
| `layout` | `GIT_CONFIG_GLOBAL` or a non-default `XDG_CONFIG_HOME` is set, or the component isn't installed | unset it; `bash dotfiles/setup.sh --git-identity` |
| `env-identity` | `GIT_AUTHOR_*`, `GIT_COMMITTER_*` or `EMAIL` is set | unset it in your shell startup files |
| `gitconfig-identity`, `gitconfig-rules` | `~/.gitconfig` still sets an identity, `includeIf`, `insteadOf` or `pushInsteadOf` | delete those lines |
| `unconditional-identity` | some global or system config applies one identity to every repo | delete it; the identity files are the only source |
| `local-file` | `~/.config/git/local` sets more than `gpg.*` | move the rest elsewhere |
| `owners` | `~/.config/git/owners` is missing, has no owners, has a line that breaks the format in `git-identity-check`'s header, or names an identity file that is missing | fix the file in the data folder, then re-run `setup.sh --git-identity` |
| `ssh-include` | `~/.ssh/config` lacks `Include config.d/github.conf` before its first `Host` | add it at the top |
| `ssh-identityfile`, `ssh-identitiesonly` | a GitHub alias would offer a key other than its own | remove the other `IdentityFile` (often under `Host *`) and any `IdentitiesOnly no` |
| `accounts`, `key-missing` | `~/.config/git/accounts` is missing or wrong, or a listed account has no key | fix the file, or make and register the key (*Set up a machine*, steps 2–3) |
| `https-route`, `rewrite`, `repo-route` | an owner's URL doesn't resolve to its SSH alias | reinstall the component; remove repo-local `insteadOf` and `pushInsteadOf` rules |
| `repo-local-identity`, `repo-identity-source` | a repo sets its own name or email, or gets an identity from a folder rule | replace with an identity include (*Start a new repo*) |
| `repo-ambiguous` | a repo's remotes or push URLs name several owners | add an identity include |
| `repo-identity-mismatch` | a repo's author, committer and key don't match one identity file | look for a repo-local override |
| `repo-signing` | a repo switched signing off or points at another signer file | find where with `git config --show-origin <key>` in that repo, and remove it there |
| `repo-unreadable`, `repo-roots` | a repo git can't read, or a bad `repo-roots` line | repair it, or fix the line |
| `live-login`, `live-refused-expected` | an alias logged in as the wrong account; a declared account was refused; or an undeclared one logged in | a refused declared account usually means its key isn't registered (*Set up a machine*, step 3); otherwise check the key in `identity/ssh/github.conf` and `~/.config/git/accounts` |
| `live-inconclusive` | GitHub couldn't be reached, or the host key failed | network, or `~/.ssh/known_hosts` |
| `check` (audit only) | a component machine's own check failed; its `FAIL` lines follow | fix them on that machine |
| `standalone-foreign` (audit only) | a standalone machine's config names an account or owner it shouldn't | remove that rule from its `~/.gitconfig` |
| `leak-new` (audit only) | a commit made since `since` carries your address in the wrong repo | find out which machine made it, and fix that machine's setup |
| `unreachable` (audit only) | ssh to that machine failed | network, or the machine is down |

`[no-identity]`, `[root-missing]` and `[unreadable]` lines are information, not failures.
