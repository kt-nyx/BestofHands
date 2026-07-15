# SPDX-License-Identifier: Unlicense

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^)]+)\)")
SKIP_DIRECTORIES = {".git", ".venv", "dist", "tools/ExportTool"}


def is_skipped(path: Path) -> bool:
    relative = path.relative_to(ROOT).as_posix()
    return any(relative == directory or relative.startswith(directory + "/") for directory in SKIP_DIRECTORIES)


def main() -> None:
    failures: list[str] = []
    checked = 0

    for document in sorted(ROOT.rglob("*.md")):
        if is_skipped(document):
            continue
        content = document.read_text(encoding="utf-8")
        for match in LINK.finditer(content):
            target = match.group(1).strip()
            if (
                not target
                or target.startswith(("#", "http://", "https://", "mailto:"))
                or target.startswith("<")
            ):
                continue
            path_text = target.split("#", 1)[0].replace("%20", " ")
            if not path_text:
                continue
            resolved = (document.parent / path_text).resolve()
            checked += 1
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                failures.append(f"{document.relative_to(ROOT)}: link leaves repository: {target}")
                continue
            if not resolved.exists():
                failures.append(f"{document.relative_to(ROOT)}: missing link target: {target}")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        raise SystemExit(1)

    print(f"Local Markdown links passed: {checked}")


if __name__ == "__main__":
    main()
