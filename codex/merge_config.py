#!/usr/bin/env python3
"""Merge the top-level keys of a small TOML file into Codex's config.toml.

Usage: merge_config.py <shared.toml> <target config.toml>

Codex keeps per-directory trust entries in the same file as the model settings and
rewrites it as you work, so the file cannot be a symlink into this repository. This
replaces each shared key's line in the target's top-level section, or adds it at the
top, and leaves every other line byte-for-byte as it was. It writes nothing when the
target already matches, so running it again changes nothing.

It understands only `key = value` lines, one per line, which is all the shared file
holds. A shared key whose existing value spans several lines is refused, not mangled.
"""

import os
import re
import sys

KEY_LINE = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")


def shared_lines(path):
    """Return {key: line} for every `key = value` line, in file order."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = KEY_LINE.match(line)
            if not m:
                sys.exit(f"merge_config: not a `key = value` line in {path}: {line!r}")
            out[m.group(1)] = line.strip()
    return out


def merge(shared, text):
    lines = text.splitlines()
    # The top-level section ends at the first table header.
    top_end = next((i for i, l in enumerate(lines) if l.lstrip().startswith("[")), len(lines))
    missing = []
    for key, new in shared.items():
        for i in range(top_end):
            m = KEY_LINE.match(lines[i])
            if m and m.group(1) == key:
                value = lines[i].split("=", 1)[1].strip()
                if value[:1] in "[{" or value.startswith(('"""', "'''")):
                    sys.exit(f"merge_config: {key} has a multi-line value in the target; "
                             "edit it by hand")
                lines[i] = new
                break
        else:
            missing.append(new)
    lines = missing + lines
    return "\n".join(lines) + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[2])
    src, dst = sys.argv[1], sys.argv[2]
    shared = shared_lines(src)
    try:
        with open(dst, encoding="utf-8") as f:
            before = f.read()
    except FileNotFoundError:
        before = ""
    after = merge(shared, before)
    if after == before:
        print("unchanged")
        return
    # Codex creates this file 0600. Keep an existing file's mode; give a new one that.
    mode = os.stat(dst).st_mode & 0o777 if before else 0o600
    tmp = dst + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(after)
    os.chmod(tmp, mode)
    os.replace(tmp, dst)
    print("updated")


if __name__ == "__main__":
    main()
