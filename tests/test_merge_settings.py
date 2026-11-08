#!/usr/bin/env python3
"""The rules for layering private settings on a shareable base, and for comparing them.

Run from the repository root:  python3 -m unittest tests.test_merge_settings
"""

import copy
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "claude", "merge_settings.py")
_spec = importlib.util.spec_from_file_location("merge_settings", SCRIPT)
merge_settings = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(merge_settings)


class Merge(unittest.TestCase):
    def test_objects_merge_recursively(self):
        got = merge_settings.merge({"a": {"b": 1, "c": {"d": 2}}, "e": 3},
                                   {"a": {"c": {"f": 4}}})
        self.assertEqual(got, {"a": {"b": 1, "c": {"d": 2, "f": 4}}, "e": 3})

    def test_arrays_are_replaced_not_combined(self):
        got = merge_settings.merge({"p": {"allow": ["x", "y"]}}, {"p": {"allow": ["z"]}})
        self.assertEqual(got, {"p": {"allow": ["z"]}})

    def test_an_empty_array_replaces_too(self):
        self.assertEqual(merge_settings.merge({"a": [1]}, {"a": []}), {"a": []})

    def test_a_scalar_replaces_an_object_and_an_object_replaces_a_scalar(self):
        self.assertEqual(merge_settings.merge({"a": {"b": 1}}, {"a": 2}), {"a": 2})
        self.assertEqual(merge_settings.merge({"a": 2}, {"a": {"b": 1}}), {"a": {"b": 1}})

    def test_null_and_false_are_values_that_replace(self):
        self.assertEqual(merge_settings.merge({"a": 1, "b": 1}, {"a": None, "b": False}),
                         {"a": None, "b": False})

    def test_inputs_are_not_changed(self):
        base, overlay = {"a": {"b": [1]}}, {"a": {"c": [2]}}
        base0, overlay0 = copy.deepcopy(base), copy.deepcopy(overlay)
        got = merge_settings.merge(base, overlay)
        got["a"]["b"].append(9)
        got["a"]["c"].append(9)
        self.assertEqual((base, overlay), (base0, overlay0))


class Same(unittest.TestCase):
    def test_reordered_keys_are_not_a_change(self):
        self.assertTrue(merge_settings.same({"a": 1, "b": {"c": 2, "d": 3}},
                                            {"b": {"d": 3, "c": 2}, "a": 1}))

    def test_a_reordered_array_is_a_change(self):
        self.assertFalse(merge_settings.same({"a": [1, 2]}, {"a": [2, 1]}))

    def test_true_is_not_one(self):
        # Python's == says True == 1 and 1 == 1.0, but JSON's values differ.
        self.assertFalse(merge_settings.same({"a": True}, {"a": 1}))
        self.assertFalse(merge_settings.same({"a": [0]}, {"a": [False]}))

    def test_differences_name_the_path_and_both_values(self):
        lines = merge_settings.differences({"a": {"b": 1}, "gone": 2, "same": 3},
                                           {"a": {"b": 5}, "new": [6], "same": 3})
        text = "\n".join(lines)
        self.assertIn("a.b", text)
        self.assertIn("gone", text)
        self.assertIn("new", text)
        self.assertNotIn("same", text)

    def test_no_differences_when_only_the_order_changed(self):
        self.assertEqual(merge_settings.differences({"a": 1, "b": 2}, {"b": 2, "a": 1}), [])


class UnpreservedEdits(unittest.TestCase):
    """Drift: an edit from the record to the live file that the new result doesn't hold."""

    def lost(self, record, live, result):
        return merge_settings.unpreserved_edits(record, live, result)

    def test_a_moved_edit_with_an_independent_base_change_is_not_drift(self):
        self.assertEqual(self.lost({"a": 1}, {"a": 1, "edit": "v"}, {"a": 1, "edit": "v", "fromBase": 2}), [])

    def test_a_live_edit_not_in_the_result_is_drift(self):
        text = "\n".join(self.lost({"a": 1}, {"a": 1, "edit": "v"}, {"a": 1, "fromBase": 2}))
        self.assertIn("edit", text)
        self.assertIn('"v"', text)
        self.assertNotIn("fromBase", text)

    def test_a_changed_value_must_match_the_result(self):
        self.assertEqual(self.lost({"a": 1}, {"a": 2}, {"a": 2}), [])
        self.assertTrue(self.lost({"a": 1}, {"a": 2}, {"a": 3}))
        self.assertTrue(self.lost({"a": 1}, {"a": 2}, {"a": 1}))

    def test_a_key_deleted_live_must_be_gone_from_the_result(self):
        self.assertIn("gone", "\n".join(self.lost({"gone": 1}, {}, {"gone": 1})))
        self.assertTrue(self.lost({"gone": 1}, {}, {"gone": 2}))
        self.assertEqual(self.lost({"gone": 1}, {}, {"other": 2}), [])

    def test_a_null_in_the_result_is_not_a_deletion(self):
        self.assertTrue(self.lost({"k": 1}, {}, {"k": None}))
        self.assertTrue(self.lost({}, {"k": None}, {}))

    def test_no_live_edit_is_never_drift(self):
        self.assertEqual(self.lost({"a": {"b": 1}}, {"a": {"b": 1}}, {"z": 9}), [])

    def test_only_reordered_keys_are_not_an_edit(self):
        self.assertEqual(self.lost({"a": 1, "b": 2}, {"b": 2, "a": 1}, {}), [])

    def test_objects_compare_recursively(self):
        record = {"o": {"keep": 1, "drop": 2, "deep": {"x": 1}}}
        live = {"o": {"keep": 1, "added": 3, "deep": {"x": 5}}}
        self.assertEqual(self.lost(record, live, {"o": {"keep": 9, "added": 3, "deep": {"x": 5, "y": 1}}}), [])
        lines = "\n".join(self.lost(record, live, {"o": {"keep": 1, "drop": 2, "deep": {"x": 1}}}))
        self.assertIn("o.drop", lines)
        self.assertIn("o.added", lines)
        self.assertIn("o.deep.x", lines)
        self.assertNotIn("o.keep", lines)

    def test_a_new_live_object_compares_recursively_too(self):
        self.assertEqual(self.lost({}, {"o": {"a": 1}}, {"o": {"a": 1, "b": 2}}), [])
        self.assertIn("o.a", "\n".join(self.lost({}, {"o": {"a": 1}}, {"o": {"a": 2}})))
        self.assertTrue(self.lost({}, {"o": {}}, {}))

    def test_a_result_that_replaced_the_object_holds_no_nested_edit(self):
        self.assertTrue(self.lost({"o": {"a": 1}}, {"o": {"a": 2}}, {"o": 3}))
        self.assertEqual(self.lost({"o": {"a": 1}}, {"o": {}}, {"o": 3}), [])

    def test_a_type_change_compares_whole(self):
        self.assertEqual(self.lost({"o": {"a": 1}}, {"o": 1}, {"o": 1}), [])
        self.assertTrue(self.lost({"o": {"a": 1}}, {"o": 1}, {"o": {"a": 1}}))
        self.assertTrue(self.lost({"o": 1}, {"o": {"a": 1}}, {"o": 1}))

    def test_values_compare_as_json_not_as_python(self):
        self.assertTrue(self.lost({"a": 0}, {"a": True}, {"a": 1}))
        self.assertTrue(self.lost({"a": []}, {"a": [1, 2]}, {"a": [2, 1]}))


class CommandLine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def run_cli(self, *args):
        return subprocess.run([sys.executable, SCRIPT] + list(args),
                              capture_output=True, text=True)

    def test_merge_prints_the_result(self):
        base = self.write("base", '{"a": 1, "b": {"c": 2}}')
        overlay = self.write("overlay", '{"b": {"d": 3}}')
        p = self.run_cli("merge", base, overlay)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout), {"a": 1, "b": {"c": 2, "d": 3}})

    def test_missing_and_empty_overlay_give_identical_bytes(self):
        base = self.write("base", '{"a": {"b": [1]}}')
        missing = self.run_cli("merge", base, os.path.join(self.tmp.name, "absent"))
        empty_object = self.run_cli("merge", base, self.write("o1", "{}\n"))
        empty_file = self.run_cli("merge", base, self.write("o2", ""))
        self.assertEqual(missing.returncode, 0, missing.stderr)
        self.assertEqual(missing.stdout, empty_object.stdout)
        self.assertEqual(missing.stdout, empty_file.stdout)
        self.assertEqual(json.loads(missing.stdout), {"a": {"b": [1]}})

    def test_an_overlay_under_a_file_counts_as_missing(self):
        base = self.write("base", '{"a": 1}')
        p = self.run_cli("merge", base, os.path.join(base, "overlay"))
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout), {"a": 1})

    def test_output_is_stable(self):
        base = self.write("base", '{"z": 1, "a": 2}')
        overlay = self.write("overlay", '{"m": 3}')
        first, second = self.run_cli("merge", base, overlay), self.run_cli("merge", base, overlay)
        self.assertEqual(first.stdout, second.stdout)
        self.assertTrue(first.stdout.endswith("\n"))

    def test_nan_in_an_overlay_is_refused(self):
        base = self.write("base.json", "{}")
        overlay = self.write("overlay.json", '{"custom": NaN}')
        out = self.run_cli("merge", base, overlay)
        self.assertNotEqual(out.returncode, 0)
        self.assertNotIn("NaN", out.stdout)

    def test_a_broken_overlay_fails_and_names_the_file(self):
        base = self.write("base", "{}")
        for name, text in (("bad", "{not json"), ("list", "[1]"), ("scalar", "3")):
            overlay = self.write(name, text)
            p = self.run_cli("merge", base, overlay)
            self.assertNotEqual(p.returncode, 0, name)
            self.assertEqual(p.stdout, "", name)
            self.assertIn(overlay, p.stderr)

    def test_a_missing_or_broken_base_fails(self):
        overlay = self.write("overlay", "{}")
        self.assertNotEqual(self.run_cli("merge", os.path.join(self.tmp.name, "absent"), overlay).returncode, 0)
        self.assertNotEqual(self.run_cli("merge", self.write("b", "[]"), overlay).returncode, 0)
        self.assertNotEqual(self.run_cli("merge", self.write("e", ""), overlay).returncode, 0)

    def test_compare_ignores_order(self):
        a = self.write("a", '{"x": 1, "y": 2}')
        b = self.write("b", '{"y": 2, "x": 1}')
        p = self.run_cli("compare", a, b)
        self.assertEqual((p.returncode, p.stdout), (0, ""))

    def test_compare_shows_a_change_and_exits_one(self):
        a = self.write("a", '{"x": 1}')
        b = self.write("b", '{"x": 2}')
        p = self.run_cli("compare", a, b)
        self.assertEqual(p.returncode, 1)
        self.assertIn("x", p.stdout)

    def test_compare_of_an_unreadable_file_exits_two(self):
        a = self.write("a", "{}")
        p = self.run_cli("compare", a, self.write("b", "{broken"))
        self.assertEqual(p.returncode, 2)
        self.assertIn("isn't valid JSON", p.stderr)
        self.assertEqual(self.run_cli("compare", a, os.path.join(self.tmp.name, "absent")).returncode, 2)

    def test_drift_reports_only_what_the_result_would_lose(self):
        record = self.write("record", '{"a": 1}')
        live = self.write("live", '{"a": 1, "edit": "v"}')
        p = self.run_cli("drift", record, live, self.write("kept", '{"a": 1, "edit": "v", "b": 2}'))
        self.assertEqual((p.returncode, p.stdout), (0, ""))
        p = self.run_cli("drift", record, live, self.write("lost", '{"a": 1, "b": 2}'))
        self.assertEqual(p.returncode, 1)
        self.assertIn("edit", p.stdout)
        self.assertNotIn("b:", p.stdout)

    def test_drift_of_an_unreadable_file_exits_two(self):
        good = self.write("good", "{}")
        p = self.run_cli("drift", good, self.write("broken", "{broken"), good)
        self.assertEqual(p.returncode, 2)
        self.assertIn("isn't valid JSON", p.stderr)

    def test_drift_needs_all_three_files(self):
        good = self.write("good", "{}")
        self.assertEqual(self.run_cli("drift", good, good).returncode, 2)

    def test_an_unknown_command_exits_two(self):
        self.assertEqual(self.run_cli("nonsense").returncode, 2)


class OverlayExample(unittest.TestCase):
    """The example in starters/settings-overlay.README is what people copy, so it must work."""

    ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

    def example(self):
        lines, inside = [], False
        with open(os.path.join(self.ROOT, "starters", "settings-overlay.README")) as f:
            for line in f:
                if line.startswith("# --- example begins"):
                    inside = True
                elif line.startswith("# --- example ends"):
                    break
                elif inside:
                    self.assertTrue(line.startswith("#"), line)
                    lines.append(line[1:])
        self.assertTrue(lines, "no example between the markers")

        def no_constants(name):
            raise ValueError("not strict JSON: %s" % name)

        return json.loads("".join(lines), parse_constant=no_constants)

    def test_every_value_has_the_type_claude_code_expects(self):
        overlay = self.example()
        rule = re.compile(r"^[A-Z][A-Za-z]*(\([^()]+\))?$")
        for key, value in overlay.items():
            if key in ("model", "theme"):
                self.assertIsInstance(value, str, key)
                self.assertTrue(value, key)
            elif key == "permissions":
                self.assertIsInstance(value, dict)
                for kind, rules in value.items():
                    self.assertIn(kind, ("allow", "deny", "ask"))
                    self.assertIsInstance(rules, list)
                    for r in rules:
                        self.assertIsInstance(r, str)
                        self.assertRegex(r, rule)
            elif key == "env":
                self.assertIsInstance(value, dict)
                for name, v in value.items():
                    self.assertIsInstance(name, str)
                    self.assertIsInstance(v, str, name)
            else:
                self.fail("the example has a key the test doesn't know: %s" % key)
        if "theme" in overlay:
            self.assertIn(overlay["theme"], ("auto", "dark", "light", "dark-daltonized",
                                             "light-daltonized", "dark-ansi", "light-ansi"))

    def test_the_example_is_strict_json_and_merges_onto_the_base(self):
        overlay = self.example()
        with open(os.path.join(self.ROOT, "claude", "settings.json")) as f:
            base = json.load(f)
        got = merge_settings.merge(base, overlay)
        for key, value in overlay.items():
            self.assertEqual(got[key], value)
        for key in base:
            self.assertIn(key, got)

    def test_every_key_in_the_example_is_explained(self):
        with open(os.path.join(self.ROOT, "starters", "settings-overlay.README")) as f:
            text = f.read()
        for key in self.example():
            self.assertRegex(text, r"(?m)^#   %s +\S" % key)


if __name__ == "__main__":
    unittest.main()
