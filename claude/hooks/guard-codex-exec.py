#!/usr/bin/env python3
"""PreToolUse guard: refuse `codex exec` without stdin redirection and a timeout.

Why this exists
---------------
`codex exec` ALWAYS reads stdin, even when the prompt is passed as an argument
("If stdin is piped and a prompt is also provided, stdin is appended as a
<stdin> block" -- codex exec --help). It blocks at
"Reading additional input from stdin..." until EOF, BEFORE any model call.

A backgrounded command often has an open pipe on stdin that never closes, so
codex waits forever and prints almost nothing. A foreground Bash call gets
`< /dev/null` from the harness and a backgrounded one does not, so the same
command finishes in one and blocks in the other, and a blocked run looks like
one that is still working.

This hook denies rather than rewrites: silently editing a command is worse than
refusing it with an explanation.

How it reads a command
----------------------
A shell command is scanned once, left to right, tracking quotes and heredocs,
and cut into segments at control operators that are actually operators. That
order matters. Splitting on `&&` `||` `;` `|` with a regex first would treat the
four characters inside `codex exec "compare A && B"` as syntax, producing fragments
with unbalanced quotes that can't be parsed, and a command that can't be parsed
must not run unguarded. The same scan is what lets a heredoc body through: no shell executes
it, so a line in it beginning `codex exec` is prose, not a command.

Each segment is kept twice. `raw` is the text, for splitting into words. `code`
has every quoted run blanked out, so `< /dev/null` written *inside the prompt*
no longer looks like a redirection the shell performs.

Only `codex exec` (and its documented alias `codex e`) is guarded. `codex login`
does not read stdin and does not call the model, so a message about redirection
would tell the reader nothing true.
"""
import json
import re
import shlex
import sys

# Accept `< /dev/null`, `</dev/null`, `0< /dev/null`, `0</dev/null`.
STDIN_REDIR = re.compile(r"\d?<\s*/dev/null")
# Leading NAME=value environment assignments.
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Last-resort check when the command cannot be parsed at all.
LOOKS_LIKE_EXEC = re.compile(r"(?:^|[;&|(`\s])codex\s+(?:exec|e)\b")

# Flags that exit before reading stdin or calling the model.
INERT_FLAGS = {"--help", "-h", "--version", "-V"}
# `codex exec` and the alias `codex --help` documents for it.
EXEC_SUBCOMMANDS = {"exec", "e"}
# Options consuming a following value, unless written --flag=value.
CODEX_VALUE_FLAGS = {"-c", "--config", "-C", "--cd", "-m", "--model",
                     "-s", "--sandbox", "-p", "--profile",
                     "-a", "--ask-for-approval", "--enable", "--output-schema"}
TIMEOUT_VALUE_FLAGS = {"-k", "--kill-after", "-s", "--signal"}
# Wrappers that change how a command runs, not what it is.
PASSTHROUGH = {"nohup", "stdbuf", "nice", "ionice"}
# Programs whose heredoc body is a script, not data.
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}

BLANK = "\x00"      # stands in for a character that was inside quotes


def scan(command):
    """Cut a shell command into segments at operators that are really operators.

    Returns `(segments, parsed)`. Each segment is a `(raw, code)` pair; `code`
    is `raw` with quoted runs blanked, so text inside the prompt cannot pass for
    shell syntax. `parsed` is False when the scan ran off the end inside an open
    quote or an unclosed heredoc -- the caller must not read that as safe.
    """
    segments = []
    raw_buf, code_buf = [], []
    heredocs = []                 # delimiters awaiting their bodies
    scripts = []                  # bodies a shell will run
    substitutions = []            # bodies of unquoted heredocs, which the shell expands
    i, n = 0, len(command)
    parsed = True

    def flush():
        raw, code = "".join(raw_buf).strip(), "".join(code_buf).strip()
        if raw:
            segments.append((raw, code))
        del raw_buf[:], code_buf[:]

    def keep(text, blanked=False):
        raw_buf.append(text)
        code_buf.append(BLANK * len(text) if blanked else text)

    def feeds_a_shell():
        """Is the command this heredoc attaches to going to run the body?"""
        try:
            words = shlex.split("".join(raw_buf).replace("<<", " "))
        except ValueError:
            return True              # cannot tell, so assume the worst
        rest, _ = strip_prefix(words)
        return bool(rest) and rest[0].rsplit("/", 1)[-1] in SHELLS

    def read_heredoc_bodies(pos):
        """Consume the bodies queued by `<<` on the line just ended."""
        while heredocs:
            delim, strip_tabs, expands, runs = heredocs.pop(0)
            body = []
            while pos < n:
                end = command.find("\n", pos)
                if end == -1:
                    end = n
                line = command[pos:end]
                pos = end + 1 if end < n else n
                if (line.lstrip("\t") if strip_tabs else line).rstrip("\r") == delim:
                    break
                body.append(line)
            else:
                # Ran out of input before the delimiter: the body is unbounded.
                return pos, False
            if runs:
                scripts.append("\n".join(body))
            elif expands:
                substitutions.append("\n".join(body))
        return pos, True

    while i < n:
        ch = command[i]

        if ch == "\\" and i + 1 < n:
            keep(command[i:i + 2], blanked=True)
            i += 2
            continue

        if ch in "'\"":
            close = command.find(ch, i + 1)
            if close == -1:
                keep(command[i:], blanked=True)
                parsed = False
                break
            keep(command[i:close + 1], blanked=True)
            i = close + 1
            continue

        if ch == "<" and command[i:i + 2] == "<<" and command[i:i + 3] != "<<<":
            j = i + 2
            strip_tabs = j < n and command[j] == "-"
            j += 1 if strip_tabs else 0
            while j < n and command[j] in " \t":
                j += 1
            if j < n and command[j] in "'\"":
                close = command.find(command[j], j + 1)
                if close == -1:
                    parsed = False
                    break
                # A quoted delimiter means the shell expands nothing in the body.
                heredocs.append((command[j + 1:close], strip_tabs, False, feeds_a_shell()))
                j = close + 1
            else:
                start = j
                while j < n and command[j] not in " \t\n;&|<>()":
                    j += 1
                if j == start:
                    keep(command[i:i + 2])       # a bare `<<` is not ours to read
                    i += 2
                    continue
                heredocs.append((command[start:j], strip_tabs, True, feeds_a_shell()))
            keep(command[i:j], blanked=True)
            i = j
            continue

        if ch == "\n":
            flush()
            i += 1
            if heredocs:
                i, ok = read_heredoc_bodies(i)
                parsed = parsed and ok
            continue

        if command[i:i + 2] in ("&&", "||", ";;"):
            flush()
            i += 2
            continue

        if ch in ";&|()`":
            flush()
            i += 1
            continue

        keep(ch)
        i += 1

    flush()
    if heredocs:                  # `<<EOF` with no body at all
        parsed = False

    # A heredoc fed to a shell is a script: read it as one.
    for body in scripts:
        inner, ok = scan(body)
        segments.extend(inner)
        parsed = parsed and ok

    # An unquoted heredoc body is still expanded, so a `$(...)` in it runs.
    for body in substitutions:
        inner, ok = scan(body.replace("$(", "`").replace(")", "`"))
        segments.extend(inner)
        parsed = parsed and ok

    return segments, parsed


def skip_flags(words, i, value_flags):
    """Advance past option words, consuming the value of a value-taking flag."""
    while i < len(words) and words[i].startswith("-") and words[i] != "-":
        word = words[i]
        i += 1
        if word == "--":
            break
        if "=" not in word and word in value_flags and i < len(words):
            i += 1
    return i


def strip_prefix(words):
    """Drop wrappers that change how a command runs, not what it runs.

    Reports whether a `timeout` was among them. `nohup` is here because it is
    the usual way to detach a long run, and not recognizing it would leave every
    detached invocation -- the ones most likely to hang -- unchecked.
    """
    had_timeout = False
    i = 0
    while i < len(words):
        word = words[i]
        if ENV_ASSIGN.match(word):
            i += 1
            continue
        name = word.rsplit("/", 1)[-1]
        if name in PASSTHROUGH:
            i += 1
            continue
        if name == "env":
            i += 1
            while i < len(words):
                if ENV_ASSIGN.match(words[i]):
                    i += 1
                elif words[i] in ("-u", "--unset") and i + 1 < len(words):
                    i += 2
                elif words[i].startswith("-"):
                    i += 1
                else:
                    break
            continue
        if name == "timeout":
            had_timeout = True
            i = skip_flags(words, i + 1, TIMEOUT_VALUE_FLAGS)
            if i < len(words):
                i += 1          # the DURATION
            continue
        break
    return words[i:], had_timeout


def exec_subcommand(words):
    """The codex subcommand being run, or None for the bare interactive TUI."""
    i = skip_flags(words, 1, CODEX_VALUE_FLAGS)
    return words[i] if i < len(words) else None


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # never break the tool call on a malformed payload

    command = (payload.get("tool_input") or {}).get("command") or ""
    if "codex" not in command:
        sys.exit(0)

    segments, parsed = scan(command)

    problems = []
    for raw, code in segments:
        if raw.startswith("#"):
            continue
        try:
            words = shlex.split(raw)
        except ValueError:
            parsed = False
            continue
        rest, had_timeout = strip_prefix(words)
        if not rest:
            continue
        if rest[0] != "codex" and not rest[0].endswith("/codex"):
            continue
        if exec_subcommand(rest) not in EXEC_SUBCOMMANDS:
            continue            # login, mcp, doctor, the bare TUI: not this hook's business
        if any(flag in rest for flag in INERT_FLAGS):
            continue            # --help / --version exit before reading stdin

        missing = []
        if not STDIN_REDIR.search(code):
            missing.append("`< /dev/null`")
        if not had_timeout:
            missing.append("a `timeout <seconds>` wrapper")
        if missing:
            problems.append((raw[:120], missing))

    if not problems and parsed:
        sys.exit(0)

    if not parsed and not problems:
        # Nothing could be read with confidence. Refuse only if what could not
        # be read looks like the thing that hangs.
        if not LOOKS_LIKE_EXEC.search(command):
            sys.exit(0)
        problems.append((command[:120], ["a form this guard can parse"]))

    lines = [
        "Blocked: `codex exec` invocation missing a required safety guard.",
        "",
        "`codex exec` always reads stdin, even with the prompt as an argument. With an",
        "open stdin (the default when backgrounding) it blocks forever at",
        '"Reading additional input from stdin..." before any model call.',
        "",
    ]
    for segment, missing in problems:
        lines.append(f"  segment: {segment}")
        lines.append(f"  missing: {', '.join(missing)}")
    lines += [
        "",
        "Correct form:",
        "  timeout 1800 codex exec --sandbox read-only \"<prompt>\" < /dev/null > out.txt 2>&1",
        "",
        "Run it detached, not in the foreground: a foreground call stops after 10 minutes,",
        "and a review can take longer. Once detached, `ps -o etime,time,pcpu -p <pid>` tells",
        "you whether it is working -- accumulating CPU means thinking, 0% means blocked.",
        "",
        "A script that starts codex for you is not checked here, because this guard can't",
        "see inside it. Make sure it closes stdin and sets a time limit of its own.",
    ]

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": "\n".join(lines),
        }
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
