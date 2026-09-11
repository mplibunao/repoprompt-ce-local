#!/usr/bin/env python3
"""Read the working-journal schema version from a RepoPrompt source tree."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def read_schema_version(repo_root: Path) -> int:
    source_path = repo_root / "Sources/RepoPromptDomainRuntime/DomainPersistence.swift"
    source = source_path.read_text(encoding="utf-8")
    declarations = re.findall(
        r"(?ms)^struct DomainWorkingJournal: Codable \{\n(?P<body>.*?)(?=^\})",
        source,
    )
    matches = [
        match
        for declaration in declarations
        for match in re.findall(
            r"(?m)^[ \t]+static let schemaVersion[ \t]*=[ \t]*([0-9]+)[ \t]*$",
            declaration,
        )
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected exactly one integer DomainWorkingJournal.schemaVersion in {source_path}; "
            f"found {len(matches)}."
        )
    return int(matches[0])


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {Path(sys.argv[0]).name} REPO_ROOT")
    print(read_schema_version(Path(sys.argv[1])))


if __name__ == "__main__":
    main()
