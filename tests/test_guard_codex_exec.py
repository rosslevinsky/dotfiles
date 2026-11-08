#!/usr/bin/env python3
"""What the codex guard must deny, and what it must not.

The hook is a program that reads a JSON payload and writes a JSON decision, so
that is what these tests exercise: the installed script, in a subprocess, over
stdin. Importing it would test a copy of the logic and miss anything that only
goes wrong at the process boundary.

Every assertion is on `permissionDecision`. Grepping the message prose passes on
any text containing the word "deny" -- including a message explaining why
something was allowed.

Two failure directions, and they are not symmetric:

  FAILING OPEN is the expensive one. An unguarded `codex exec` blocks at
  "Reading additional input from stdin..." until EOF that never comes, with almost
  no output. Every case here that expects `deny` is a
  command that would hang.

  FAILING CLOSED costs a round trip, but a guard that denies ordinary work is a
  guard that gets switched off. The `allow` cases are the ones that keep it
  installed -- particularly writing *about* the guard, which it must not block.
"""
import json
import os
import subprocess
import unittest

HOOK = os.environ.get(
    "GUARD_HOOK",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "claude", "hooks", "guard-codex-exec.py"),
)


def decide(command, **tool_input):
    """Run the hook over a Bash payload and return its permission decision.

    No output at all means the hook exited without an opinion, which the harness
    reads as "allow" -- so that is what this reports, rather than a special case
    every test would have to repeat.
    """
    payload = {"tool_name": "Bash", "tool_input": dict({"command": command}, **tool_input)}
    proc = subprocess.run(
        ["python3", HOOK],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        timeout=15,
    )
    if proc.returncode != 0:
        raise AssertionError(f"hook exited {proc.returncode}: {proc.stderr}")
    out = proc.stdout.strip()
    if not out:
        return "allow"
    return json.loads(out)["hookSpecificOutput"]["permissionDecision"]


class Denies(unittest.TestCase):
    """Commands that would hang. Each must be refused."""

    def assertDenied(self, command, **kw):
        self.assertEqual("deny", decide(command, **kw), f"should have been denied: {command}")

    # -- the baseline the hook was written for -------------------------------

    def test_bare_unguarded_exec(self):
        self.assertDenied('codex exec -s read-only "hi"')

    def test_missing_only_the_timeout(self):
        self.assertDenied('codex exec "hi" < /dev/null')

    def test_missing_only_the_stdin_redirect(self):
        self.assertDenied('timeout 60 codex exec "hi"')

    # -- separators inside the quoted prompt ---------------------------------
    #
    # The prompt is one shell word. `&&` inside it is text, not syntax. Splitting
    # on it first would leave fragments with unbalanced quotes that the hook can't
    # parse, and a command it can't parse must not run unguarded.

    def test_and_and_inside_the_prompt(self):
        self.assertDenied('codex exec "compare A && B"')

    def test_or_or_inside_the_prompt(self):
        self.assertDenied('codex exec "either A || B"')

    def test_semicolon_inside_the_prompt(self):
        self.assertDenied('codex exec "do a; then b"')

    def test_pipe_inside_the_prompt(self):
        self.assertDenied('codex exec "use a | pipe"')

    def test_single_quoted_prompt_with_separators(self):
        self.assertDenied("codex exec 'compare A && B'")

    def test_newline_inside_the_prompt(self):
        self.assertDenied('codex exec "line one\nline two"')

    # -- wrappers the prefix stripper has to know ---------------------------

    def test_nohup_prefix(self):
        self.assertDenied('nohup codex exec "x"')

    def test_env_prefix(self):
        self.assertDenied('env -i PATH=/bin codex exec "x"')

    def test_timeout_with_its_own_flag(self):
        # If `-k 10` consumed the duration slot, `1800` would be left looking like
        # the executable and the segment would stop being a codex invocation.
        self.assertDenied('timeout -k 10 1800 codex exec "x"')

    def test_timeout_with_joined_flag(self):
        self.assertDenied('timeout --kill-after=10 1800 codex exec "x"')

    # -- a redirect written inside the prompt text --------------------------

    def test_redirect_only_inside_the_prompt(self):
        # The words `< /dev/null` appear, but as part of the prompt the model
        # reads -- not as a redirection the shell performs.
        self.assertDenied('timeout 60 codex exec "always pass < /dev/null when running"')

    # -- nesting ------------------------------------------------------------

    def test_subshell(self):
        self.assertDenied('(codex exec "x")')

    def test_command_substitution(self):
        self.assertDenied('OUT=$(codex exec "x")')

    def test_backtick_substitution(self):
        self.assertDenied('OUT=`codex exec "x"`')

    # -- separators as real syntax: the segment must still be inspected ------

    def test_separator_before_the_invocation(self):
        self.assertDenied('echo starting && codex exec "x"')

    def test_separator_after_the_invocation(self):
        self.assertDenied('codex exec "x" ; echo done')

    def test_piped_into_a_pager(self):
        self.assertDenied('codex exec "x" | tee out.txt')

    def test_newline_separated_commands(self):
        self.assertDenied('cd /tmp\ncodex exec "x"')

    def test_redirect_present_but_in_a_different_segment(self):
        # `cat < /dev/null` satisfies nothing about the codex call beside it.
        self.assertDenied('codex exec "x" ; cat < /dev/null')

    def test_second_of_two_invocations_is_unguarded(self):
        self.assertDenied(
            'timeout 60 codex exec "a" < /dev/null && codex exec "b"'
        )

    # -- the documented alias ------------------------------------------------

    def test_exec_alias_e(self):
        self.assertDenied('codex e "x"')

    # -- a heredoc body is data, EXCEPT when it is a script -----------------

    def test_heredoc_piped_to_a_shell(self):
        # `cat <<EOF` writes the body out; `bash <<EOF` runs it. Treating every
        # heredoc as inert would trade a false positive for a hole.
        self.assertDenied("bash <<'SH'\ncodex exec \"x\"\nSH")

    def test_heredoc_used_as_the_codex_prompt(self):
        # Here stdin is the heredoc, which is the opposite of closing it.
        self.assertDenied("timeout 60 codex exec <<'EOF'\nreview this\nEOF")

    def test_substitution_inside_an_unquoted_heredoc(self):
        # An unquoted delimiter leaves `$(...)` to be expanded, so it runs.
        self.assertDenied("cat > f.md <<EOF\nresult: $(codex exec \"x\")\nEOF")

    # -- unparseable input fails closed, not open ---------------------------

    def test_unterminated_quote_around_an_exec(self):
        # Nothing here can be parsed with confidence. Skipping what
        # can't be parsed would be allowing it, and this one would hang.
        self.assertDenied('codex exec "unterminated')


class Allows(unittest.TestCase):
    """Ordinary work. A guard that refuses these gets uninstalled."""

    def assertAllowed(self, command, **kw):
        self.assertEqual("allow", decide(command, **kw), f"should have been allowed: {command}")

    # -- correctly guarded invocations ---------------------------------------

    def test_guarded(self):
        self.assertAllowed('timeout 60 codex exec -s read-only "hi" < /dev/null')

    def test_guarded_no_space_before_redirect(self):
        self.assertAllowed('timeout 60 codex exec "hi" </dev/null')

    def test_guarded_with_explicit_fd(self):
        self.assertAllowed('timeout 60 codex exec "hi" 0</dev/null')

    def test_guarded_detached_with_nohup(self):
        self.assertAllowed(
            'nohup timeout 1800 codex exec "x" < /dev/null > out.txt 2>&1 &'
        )

    def test_guarded_alias(self):
        self.assertAllowed('timeout 60 codex e "x" < /dev/null')

    def test_guarded_with_timeout_flags(self):
        self.assertAllowed('timeout -k 10 1800 codex exec "x" < /dev/null')

    def test_guarded_prompt_containing_separators(self):
        self.assertAllowed('timeout 60 codex exec "compare A && B" < /dev/null')

    # -- subcommands that neither read stdin nor call the model --------------
    #
    # The subcommand counts, not just the executable: refusing one of these
    # with a message about stdin redirection would tell the reader nothing true.

    def test_login(self):
        self.assertAllowed("codex login")

    def test_logout(self):
        self.assertAllowed("codex logout")

    def test_mcp_list(self):
        self.assertAllowed("codex mcp list")

    def test_doctor(self):
        self.assertAllowed("codex doctor")

    def test_apply(self):
        self.assertAllowed("codex apply")

    def test_help(self):
        self.assertAllowed("codex --help")

    def test_exec_help(self):
        self.assertAllowed("codex exec --help")

    def test_version(self):
        self.assertAllowed("codex --version")

    def test_bare_interactive(self):
        # `codex` with no subcommand is the interactive TUI. It is a poor thing
        # to launch from a tool call, but it is not the stdin hang this guard
        # exists to prevent, and a message about a redirect wouldn't help.
        self.assertAllowed("codex")

    # -- the false positive: writing about the guard -------------------------

    def test_heredoc_documenting_the_guard(self):
        # A quoted heredoc body is data. No shell executes it. Splitting on
        # newlines first would make a body line beginning `codex exec` its own
        # segment and refuse it, so the guard would block the act of recording
        # what the guard does.
        self.assertAllowed(
            "cat >> evidence.md <<'EOF'\n"
            "The hook refuses this form:\n"
            'codex exec "x"\n'
            "EOF"
        )

    def test_heredoc_unquoted_delimiter(self):
        self.assertAllowed(
            "cat >> notes.md <<EOF\n"
            'Ran: codex exec "review" < /dev/null\n'
            "EOF"
        )

    def test_heredoc_dash_form(self):
        self.assertAllowed(
            "cat >> notes.md <<-'EOF'\n"
            '\tcodex exec "x"\n'
            "\tEOF"
        )

    # -- codex named, not run ------------------------------------------------

    def test_echoing_the_rule(self):
        self.assertAllowed('echo "the guard denies codex exec without a redirect"')

    def test_grepping_for_it(self):
        self.assertAllowed('grep -rn "codex exec" plans/')

    def test_reading_the_hook(self):
        self.assertAllowed("cat ~/.claude/hooks/guard-codex-exec.py")

    def test_git_commit_message_naming_it(self):
        self.assertAllowed('git commit -m "fix: codex exec guard fails open"')

    # -- a script that starts codex itself, and closes stdin in Python ------

    def test_script_that_runs_codex(self):
        # A script like this spawns codex itself with stdin=DEVNULL. The guard
        # cannot see through a Python process and must not guess.
        self.assertAllowed("python3 tools/run_codex.py --idle 900")


class Robustness(unittest.TestCase):
    """The hook runs on every Bash call. It must never be the thing that breaks one."""

    def test_malformed_payload_is_not_an_error(self):
        proc = subprocess.run(["python3", HOOK], input="not json",
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(0, proc.returncode)
        self.assertEqual("", proc.stdout.strip())

    def test_empty_payload(self):
        self.assertEqual("allow", decide(""))

    def test_no_command_key(self):
        proc = subprocess.run(["python3", HOOK], input='{"tool_name":"Bash","tool_input":{}}',
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(0, proc.returncode)

    def test_denial_names_the_offending_segment(self):
        # Not prose-matching: the structured requirement is that a denial says
        # WHICH command it refused, because a message that does not is unusable
        # when several commands are chained.
        payload = {"tool_name": "Bash",
                   "tool_input": {"command": 'echo hi && codex exec "the bad one"'}}
        proc = subprocess.run(["python3", HOOK], input=json.dumps(payload),
                              capture_output=True, text=True, timeout=15)
        reason = json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("the bad one", reason)
        self.assertNotIn("echo hi &&", reason)


if __name__ == "__main__":
    unittest.main(verbosity=2)
