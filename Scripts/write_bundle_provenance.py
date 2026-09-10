#!/usr/bin/env python3
"""Write Git provenance metadata into a RepoPrompt application bundle."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time


def git_value(root: Path, arguments: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), *arguments],
            text=True,
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    value = completed.stdout.strip()
    return value or None


def write_bundle_provenance(root: Path, bundle: Path) -> Path:
    root = root.resolve()
    tracked_status = git_value(root, ["status", "--porcelain", "--untracked-files=no"])
    untracked_files = git_value(root, ["ls-files", "--others", "--exclude-standard"])
    now = time.time()
    payload = {
        "version": 1,
        "repoRoot": str(root),
        "worktreePath": str(root),
        "worktreeName": root.name,
        "branch": git_value(root, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "commit": git_value(root, ["rev-parse", "HEAD"]),
        "dirty": bool(tracked_status),
        "untracked_files": bool(untracked_files),
        "buildTimeEpoch": now,
        "buildTimeISO": datetime.fromtimestamp(now, timezone.utc)
        .astimezone()
        .isoformat(timespec="seconds"),
    }
    path = bundle / "Contents" / "Resources" / "RepoPromptProvenance.json"
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    arguments = parser.parse_args()
    path = write_bundle_provenance(arguments.repo_root, arguments.bundle)
    print(f"Bundle provenance: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
