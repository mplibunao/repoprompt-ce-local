#!/usr/bin/env python3
"""Tools for script tests."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import AbstractContextManager, contextmanager
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile
import textwrap
from typing import TypeVar
import unittest


ContextValue = TypeVar("ContextValue")
SCRIPT_DIR = Path(__file__).resolve().parent

# Replaces `debug_app_process.py` in a copied script tree. It runs the real detector with
# a process table read from FAKE_PROCESS_TABLE, so a harness can decide what is "running"
# without the shipped detector having any way to pretend production is stopped. Each
# `guard` invocation increments `<table>.calls`; a process entry with `from_call: N` is
# visible from the Nth guard call on, which lets a test open the app at a later checkpoint.
# `error` simulates inspection results: "gone" (the process exited), "unlinked" (it runs
# but its executable was deleted), or "identity" (its path cannot be read).
FAKE_PROCESS_INSPECTOR_WRAPPER = """\
import importlib.util
import json
import os
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "debug_app_process_real", Path(__file__).with_name("debug_app_process_real.py")
)
real = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = real
spec.loader.exec_module(real)

table_path = Path(os.environ["FAKE_PROCESS_TABLE"])
calls_path = table_path.with_name(table_path.name + ".calls")
call = int(calls_path.read_text()) if calls_path.exists() else 0
if sys.argv[1:2] == ["guard"]:
    call += 1
    calls_path.write_text(str(call))
table = json.loads(table_path.read_text())
visible = {entry["pid"]: entry for entry in table.get("processes", []) if entry.get("from_call", 1) <= call}


class FixtureInspector:
    def list_pids(self):
        if table.get("failEnumeration"):
            raise real.ProcessIdentityError("simulated process enumeration failure")
        return list(visible)

    def process_name(self, pid):
        entry = visible[pid]
        return None if entry.get("exited") else entry["name"]

    def process_path(self, pid):
        entry = visible[pid]
        if entry.get("error") == "gone":
            entry["exited"] = True
            raise real.ProcessGone(f"simulated exit of {pid}")
        if entry.get("error") == "unlinked":
            # What libproc reports for a running process whose executable was deleted.
            raise real.ProcessGone(f"simulated deleted executable of {pid}")
        if entry.get("error") == "identity":
            raise real.ProcessIdentityError(f"simulated identity failure for {pid}")
        return Path(entry["path"]).resolve()


raise SystemExit(real.main(sys.argv[1:], inspector=FixtureInspector()))
"""


@contextmanager
def temporary_directory(*, prefix: str | None = None) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        yield Path(directory)


def enter_context(
    test_case: unittest.TestCase,
    context_manager: AbstractContextManager[ContextValue],
) -> ContextValue:
    value = context_manager.__enter__()
    test_case.addCleanup(context_manager.__exit__, None, None, None)
    return value


def write_executable(
    path: Path,
    content: str,
    *,
    executable_bits: int = stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | executable_bits)


def write_bash_stub(directory: Path, name: str, body: str) -> None:
    write_executable(
        directory / name,
        "#!/usr/bin/env bash\nset -euo pipefail\n" + textwrap.dedent(body),
    )


def directory_snapshot(root: Path) -> dict[str, bytes | str | None]:
    """Relative path -> file bytes, None for a directory, or `symlink:<target>` for a link.

    Links are recorded, never followed, so a snapshot stays inside the tree and a link
    replaced by a copy of its target still counts as a change.
    """
    snapshot: dict[str, bytes | str | None] = {}
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        for name in (*directory_names, *file_names):
            path = Path(directory, name)
            key = str(path.relative_to(root))
            if path.is_symlink():
                snapshot[key] = f"symlink:{os.readlink(path)}"
            elif path.is_dir():
                snapshot[key] = None
            else:
                snapshot[key] = path.read_bytes()
    return dict(sorted(snapshot.items()))


class FakeProcessGuard:
    """A copied script tree whose process guard reads a test-owned process table.

    The tree holds `local_release_env.sh`, its metadata loader, `version.env`, any extra
    scripts, and the fake inspector wrapper, so the shell scripts under test run their
    real guard logic against processes the test declares.
    """

    def __init__(self, repo_root: Path, *, extra_scripts: tuple[str, ...] = ()) -> None:
        self.scripts_dir = repo_root / "Scripts"
        self.scripts_dir.mkdir(parents=True, exist_ok=True)
        for name in ("local_release_env.sh", "load_release_metadata.sh", *extra_scripts):
            shutil.copy2(SCRIPT_DIR / name, self.scripts_dir / name)
        shutil.copy2(SCRIPT_DIR.parent / "version.env", repo_root / "version.env")
        shutil.copy2(SCRIPT_DIR / "debug_app_process.py", self.scripts_dir / "debug_app_process_real.py")
        (self.scripts_dir / "debug_app_process.py").write_text(FAKE_PROCESS_INSPECTOR_WRAPPER, encoding="utf-8")
        self.process_table = repo_root / "fake-processes.json"
        self.set_processes([])

    def set_processes(self, processes: list[dict[str, object]], *, fail_enumeration: bool = False) -> None:
        """Replaces the declared processes and resets the guard-call counter."""
        self.process_table.write_text(
            json.dumps({"processes": processes, "failEnumeration": fail_enumeration}), encoding="utf-8"
        )
        self._calls_path.unlink(missing_ok=True)

    @property
    def calls(self) -> int:
        return int(self._calls_path.read_text(encoding="utf-8")) if self._calls_path.exists() else 0

    @property
    def env(self) -> dict[str, str]:
        # The exact-path override would replace the policy under test, so it is cleared.
        return {"FAKE_PROCESS_TABLE": str(self.process_table), "LOCAL_RELEASE_GUARD_EXECUTABLES_JSON": ""}

    @property
    def _calls_path(self) -> Path:
        return self.process_table.with_name(self.process_table.name + ".calls")
