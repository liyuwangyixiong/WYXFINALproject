"""Find repository path components that are unsafe for portable release."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ALLOWED = re.compile(r"[a-z0-9_-]+(?:\.[a-z0-9_-]+)*\Z")
CONVENTIONAL = {"README.md", "LICENSE", "SKILL.md", ".gitignore", ".gitattributes"}
SKIP_DIRS = {".git", "vivado_build", "__pycache__"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    bad = []
    checked = 0
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if any(part in SKIP_DIRS for part in relative.parts):
            continue
        checked += 1
        if path.name not in CONVENTIONAL and not ALLOWED.fullmatch(path.name):
            bad.append(str(relative))
    for name in bad:
        print("INVALID", name)
    print(f"PATH_CHECK checked={checked} invalid={len(bad)}")
    if bad:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
