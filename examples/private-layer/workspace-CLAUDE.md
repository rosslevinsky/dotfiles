<!--
A sample workspace file. Claude Code reads a CLAUDE.md in every folder from where it starts up to
the root, so a file in the folder that holds your repos is read by every session started anywhere
inside that folder: in each repo, and in the folder itself. Put here only what is true of all the
repos together. Facts about one repo belong in that
repo's own CLAUDE.md. Replace each example section with your own, or delete it.
-->

## How the repos here relate (example)

`app` is the web service and `app-infra` deploys it. A change to the service's settings usually
needs a matching change in `app-infra`, so check both before calling it done.

## Rules for every repo (example)

Run a repo's tests before committing in it. Never commit to `main` directly: make a branch and
open a pull request.

## Where things are (example)

Shared scripts live in `tools/`. Notes that span repos live in `notes/`, one file per topic.
