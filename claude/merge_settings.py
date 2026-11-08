#!/usr/bin/env python3
"""Layer private settings on a shareable base, and compare settings files.

Usage: merge_settings.py merge <base.json> <overlay.json>   prints the result
       merge_settings.py compare <a.json> <b.json>          exit 0 same, 1 different, 2 unreadable
       merge_settings.py drift <record> <live> <result>     exit 0 no drift, 1 drift, 2 unreadable

Objects merge recursively, and an overlay value replaces anything else, arrays included.
A missing overlay, an empty file and `{}` all mean no overlay, so a machine can go without
one. Files are compared as parsed JSON, because Claude Code reorders keys when it writes.

Drift is an edit from the record to the live file that the new result doesn't already hold,
so replacing the live file would lose it. An edit the result does hold is not drift, whatever
else changed in the base or the overlay.
"""

import json
import sys


class Unreadable(Exception):
    pass


def merge(base, overlay):
    """A new object: base with overlay on top. Neither input is changed or shared."""
    out = json.loads(json.dumps(base))
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = merge(out[key], value)
        else:
            out[key] = json.loads(json.dumps(value))
    return out


def _canonical(value):
    # Text, not ==, because Python says True == 1 and 1 == 1.0.
    return json.dumps(value, sort_keys=True)


def same(a, b):
    return _canonical(a) == _canonical(b)


def differences(old, new, path=""):
    """One line per changed value: `- path: old` and `+ path: new`."""
    lines = []
    for key in sorted(set(old) | set(new)):
        where = f"{path}.{key}" if path else key
        if key in old and key in new and isinstance(old[key], dict) and isinstance(new[key], dict):
            lines += differences(old[key], new[key], where)
        elif key not in new:
            lines.append(f"- {where}: {_canonical(old[key])}")
        elif key not in old:
            lines.append(f"+ {where}: {_canonical(new[key])}")
        elif not same(old[key], new[key]):
            lines.append(f"- {where}: {_canonical(old[key])}")
            lines.append(f"+ {where}: {_canonical(new[key])}")
    return lines


def unpreserved_edits(record, live, result, path=""):
    """One line per edit from record to live that result lacks: `- path: old`, `+ path: new`.

    A key deleted live must be absent from result, and a changed or added one must have the
    live value there. Objects compare key by key, so one key's edit says nothing of another's.
    A result with no object at a key holds nothing beneath it.
    """
    lines = []
    for key in sorted(set(record) | set(live)):
        where = f"{path}.{key}" if path else key
        in_record, in_live, in_result = key in record, key in live, key in result
        if in_record and in_live and same(record[key], live[key]):
            continue
        if not in_live:
            if in_result:
                lines.append(f"- {where}: {_canonical(record[key])}")
        elif isinstance(live[key], dict) and (
            (in_record and isinstance(record[key], dict))
            or (not in_record and in_result and isinstance(result[key], dict))
        ):
            below = result[key] if in_result and isinstance(result[key], dict) else {}
            lines += unpreserved_edits(record.get(key, {}), live[key], below, where)
        elif not in_result or not same(live[key], result[key]):
            if in_record:
                lines.append(f"- {where}: {_canonical(record[key])}")
            lines.append(f"+ {where}: {_canonical(live[key])}")
    return lines


def _load(path, optional=False):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (FileNotFoundError, NotADirectoryError):
        if optional:
            return {}
        raise Unreadable(f"{path} does not exist")
    except (OSError, UnicodeDecodeError) as e:
        raise Unreadable(f"{path} can't be read: {e}")
    if optional and not text.strip():
        return {}
    try:
        value = json.loads(text, parse_constant=_refuse_constant)
    except ValueError as e:
        raise Unreadable(f"{path} isn't valid JSON: {e}")
    if not isinstance(value, dict):
        raise Unreadable(f"{path} must hold a JSON object")
    return value


def _refuse_constant(name):
    # Python accepts these by default, but they aren't JSON, so the output would be invalid.
    raise ValueError(f"{name} is not valid JSON")


def main(argv):
    wanted = {"merge": 3, "compare": 3, "drift": 4}
    if not argv or len(argv) != wanted.get(argv[0]):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        if argv[0] == "merge":
            result = merge(_load(argv[1]), _load(argv[2], optional=True))
            print(json.dumps(result, indent=2, ensure_ascii=False, allow_nan=False))
            return 0
        loaded = [_load(path) for path in argv[1:]]
    except Unreadable as e:
        print(f"merge_settings: {e}", file=sys.stderr)
        return 2
    lines = differences(*loaded) if argv[0] == "compare" else unpreserved_edits(*loaded)
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
