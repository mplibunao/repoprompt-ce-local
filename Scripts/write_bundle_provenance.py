#!/usr/bin/env python3
"""Write Git provenance metadata into a RepoPrompt application bundle."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time


def git_output(root: Path, arguments: list[str]) -> tuple[bool, str]:
    try:
        completed = subprocess.run(
            ["git", "-C", str(root), *arguments],
            text=True,
            capture_output=True,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, ""
    if completed.returncode != 0:
        return False, ""
    return True, completed.stdout


def git_value(root: Path, arguments: list[str]) -> str | None:
    succeeded, output = git_output(root, arguments)
    if not succeeded:
        return None
    value = output.strip()
    return value or None


def write_bundle_provenance(root: Path, bundle: Path) -> Path:
    root = root.resolve()
    status_available, status_output = git_output(
        root, ["status", "--porcelain=v1", "--untracked-files=all"]
    )
    status_entries = status_output.splitlines() if status_available else []
    dirty = (
        any(not entry.startswith("?? ") for entry in status_entries)
        if status_available
        else None
    )
    untracked_files = (
        any(entry.startswith("?? ") for entry in status_entries)
        if status_available
        else None
    )
    now = time.time()
    payload = {
        "version": 1,
        "repoRoot": str(root),
        "worktreePath": str(root),
        "worktreeName": root.name,
        "branch": git_value(root, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "commit": git_value(root, ["rev-parse", "HEAD"]),
        "dirty": dirty,
        "git_status": "ok" if status_available else "unavailable",
        "untracked_files": untracked_files,
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
