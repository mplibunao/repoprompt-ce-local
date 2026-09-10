#!/usr/bin/env python3
"""Tools for script tests."""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
import stat
import tempfile
import textwrap


@contextmanager
def temporary_directory(*, prefix: str | None = None) -> Iterator[Path]:
    with tempfile.TemporaryDirectory(prefix=prefix) as directory:
        yield Path(directory)


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
