#!/usr/bin/env python3
"""Identify RepoPrompt CE processes by native executable identity.

`list` and `terminate` act on one configured debug executable. `guard` is read-only and
reports whether a RepoPrompt process holds state that the production installer or the
rollback scripts are about to replace.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import signal
import stat
import sys
from pathlib import Path
from typing import Callable, NamedTuple, Protocol

PROC_ALL_PIDS = 1
PROC_PIDPATHINFO_MAXSIZE = 4096
MCP_EXECUTABLE_NAME = "repoprompt-mcp"
# A process launched through one of the CLI links can report the link's name instead of
# the binary's, so these names are inspected too; identity still comes from the resolved
# executable path.
CLI_ALIAS_NAMES = frozenset({"repoprompt_ce_cli", "repoprompt_ce_cli_debug", "rpce-cli", "rpce-cli-debug"})
GUARD_EXIT_CLEAR = 0
EXIT_INSPECTION_FAILED = 1
GUARD_EXIT_BLOCKED = 3


class ProcessIdentityError(RuntimeError):
    pass


class TargetExecutableMissing(ProcessIdentityError):
    pass


class ProcessGone(ProcessIdentityError):
    pass


class ProcessInspector(Protocol):
    def list_pids(self) -> list[int]: ...

    def process_name(self, pid: int) -> str | None: ...

    def process_path(self, pid: int) -> Path: ...


class LibProcInspector:
    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise ProcessIdentityError("debug app process checks require macOS")
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        self.libproc.proc_listpids.restype = ctypes.c_int
        self.libproc.proc_name.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_name.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int

    def list_pids(self) -> list[int]:
        capacity = 4096
        while capacity <= 1_048_576:
            buffer = (ctypes.c_int * capacity)()
            byte_count = self.libproc.proc_listpids(PROC_ALL_PIDS, 0, buffer, ctypes.sizeof(buffer))
            if byte_count <= 0:
                error = ctypes.get_errno()
                detail = os.strerror(error) if error else "process enumeration failed"
                raise ProcessIdentityError(f"could not enumerate processes: {detail}")
            count = byte_count // ctypes.sizeof(ctypes.c_int)
            if count < capacity:
                return [pid for pid in buffer[:count] if pid > 0]
            capacity *= 2
        raise ProcessIdentityError("process enumeration exceeded the supported capacity")

    def process_name(self, pid: int) -> str | None:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_name(pid, buffer, len(buffer))
        if length <= 0:
            return None
        return os.fsdecode(buffer.value)

    def process_path(self, pid: int) -> Path:
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        length = self.libproc.proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            error = ctypes.get_errno()
            if error in {errno.ENOENT, errno.ESRCH}:
                raise ProcessGone(f"process {pid} exited before its executable could be resolved")
            detail = os.strerror(error) if error else "process is unavailable"
            raise ProcessIdentityError(f"could not resolve executable for pid {pid}: {detail}")
        try:
            return Path(os.fsdecode(buffer.value)).resolve(strict=True)
        except OSError as exc:
            raise ProcessIdentityError(f"could not resolve executable path for pid {pid}: {exc}") from exc


def expected_executable_path(path: Path) -> Path:
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = resolved.stat()
    except FileNotFoundError as exc:
        raise TargetExecutableMissing(f"target debug app executable is not installed: {path}") from exc
    except OSError as exc:
        raise ProcessIdentityError(f"target debug app executable is unavailable: {path}: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise ProcessIdentityError(f"target debug app executable is not executable: {resolved}")
    return resolved


def matching_processes(expected_executable: Path, inspector: ProcessInspector | None = None) -> list[int]:
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    matches: list[int] = []
    for pid in active_inspector.list_pids():
        if active_inspector.process_name(pid) != expected.name:
            continue
        try:
            actual = active_inspector.process_path(pid)
        except ProcessGone:
            continue
        if actual == expected:
            matches.append(pid)
    return matches


def terminate_matching_processes(
    expected_executable: Path,
    inspector: ProcessInspector | None = None,
    signaler: Callable[[int, int], None] = os.kill,
) -> list[int]:
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return []
    active_inspector = inspector or LibProcInspector()
    signaled: list[int] = []
    for pid in matching_processes(expected, active_inspector):
        try:
            actual = active_inspector.process_path(pid)
        except ProcessGone:
            continue
        if actual != expected:
            raise ProcessIdentityError(
                f"refusing to signal pid {pid}: executable changed during identity revalidation "
                f"(expected {expected}, got {actual})"
            )
        try:
            signaler(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        except OSError as exc:
            raise ProcessIdentityError(f"could not signal debug app pid {pid}: {exc}") from exc
        signaled.append(pid)
    return signaled


class BlockingProcess(NamedTuple):
    pid: int
    executable: Path


class GuardPolicy(NamedTuple):
    # Cheap prefilter on the native process name; only these candidates have their
    # executable path inspected, so an unrelated process that cannot be inspected never
    # decides the result.
    names: frozenset[str]
    blocks: Callable[[Path], bool]


def comparable_path(path: Path) -> Path:
    # Symlinks in existing components resolve, and a missing tail stays literal, so an
    # absent or malformed install still yields a path a running process can be compared to.
    return path.expanduser().resolve(strict=False)


def production_guard_policy(production_executable: Path) -> GuardPolicy:
    return exact_executables_guard_policy([production_executable])


def release_state_guard_policy(
    production_executable: Path,
    app_name: str,
    display_name: str,
    support_dir: Path,
) -> GuardPolicy:
    configured = comparable_path(production_executable)
    production_suffix = f"/{display_name}.app/Contents/MacOS"
    support = comparable_path(support_dir)
    identity_names = frozenset({app_name, MCP_EXECUTABLE_NAME})

    def in_debug_apps(executable_dir: Path) -> bool:
        try:
            top_level_entry = executable_dir.relative_to(support).parts[0]
        except (ValueError, IndexError):
            return False
        return top_level_entry == "DebugApps" or top_level_entry.startswith("DebugApps-")

    def in_matched_bundle(executable_dir: Path) -> bool:
        return (
            executable_dir == configured.parent
            or str(executable_dir).endswith(production_suffix)
            or in_debug_apps(executable_dir)
        )

    def blocks(actual: Path) -> bool:
        return actual == configured or (actual.name in identity_names and in_matched_bundle(actual.parent))

    return GuardPolicy(identity_names | CLI_ALIAS_NAMES, blocks)


def exact_executables_guard_policy(executables: list[Path]) -> GuardPolicy:
    resolved = {comparable_path(path) for path in executables}
    names = frozenset({path.name for path in executables} | {path.name for path in resolved})
    return GuardPolicy(names, lambda actual: actual in resolved)


def parse_exact_executables(raw: str) -> list[Path]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProcessIdentityError(f"guard executable list is not valid JSON: {exc}") from exc
    if not isinstance(value, list) or not value:
        raise ProcessIdentityError("guard executable list must be a nonempty JSON array of absolute paths")
    paths: list[Path] = []
    for entry in value:
        if not isinstance(entry, str) or not entry.startswith("/"):
            raise ProcessIdentityError(f"guard executable list holds a non-absolute path: {entry!r}")
        paths.append(Path(entry))
    return paths


def blocking_processes(policy: GuardPolicy, inspector: ProcessInspector | None = None) -> list[BlockingProcess]:
    active_inspector = inspector or LibProcInspector()
    blocking: list[BlockingProcess] = []
    for pid in active_inspector.list_pids():
        # A process whose name cannot be read, such as another user's, is skipped by
        # design: it cannot be one of this user's RepoPrompt processes.
        name = active_inspector.process_name(pid)
        if pid == os.getpid() or name not in policy.names:
            continue
        try:
            actual = active_inspector.process_path(pid)
        except ProcessGone:
            # libproc reports a running process whose executable was deleted, such as an
            # app in a removed DebugApps-* directory, the same way as an exited one. Only a
            # process that no longer answers to its name has exited.
            if active_inspector.process_name(pid) != name:
                continue
            raise ProcessIdentityError(
                f"{name} process {pid} is running but its executable cannot be resolved; it may have been deleted"
            ) from None
        if policy.blocks(actual):
            blocking.append(BlockingProcess(pid, actual))
    return blocking


def guard_policy_from_args(args: argparse.Namespace) -> GuardPolicy:
    if args.policy == "production":
        return production_guard_policy(args.production_executable)
    if args.policy == "release-state":
        return release_state_guard_policy(args.production_executable, args.app_name, args.display_name, args.support_dir)
    return exact_executables_guard_policy(parse_exact_executables(args.executables_json))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    operations = parser.add_subparsers(dest="operation", required=True)
    for operation in ("list", "terminate"):
        operations.add_parser(operation).add_argument("--executable", required=True, type=Path)

    guard = operations.add_parser("guard", help="read-only check; exits 0 when clear and 3 when blocked")
    policies = guard.add_subparsers(dest="policy", required=True)
    production = policies.add_parser("production", help="the configured production executable only")
    release_state = policies.add_parser("release-state", help="every RepoPrompt process that holds release state")
    for policy in (production, release_state):
        policy.add_argument("--production-executable", required=True, type=Path)
    release_state.add_argument("--app-name", required=True)
    release_state.add_argument("--display-name", required=True)
    release_state.add_argument("--support-dir", required=True, type=Path)
    exact = policies.add_parser("exact", help="exactly the listed executables")
    exact.add_argument("--executables-json", required=True, help="nonempty JSON array of absolute paths")
    return parser.parse_args(argv)


def run_guard(args: argparse.Namespace, inspector: ProcessInspector | None) -> int:
    blocking = blocking_processes(guard_policy_from_args(args), inspector)
    # Only the PID and executable path: full arguments are not needed to identify the
    # process and can carry private data.
    for process in blocking:
        print(f"  {process.pid}  {process.executable}")
    return GUARD_EXIT_BLOCKED if blocking else GUARD_EXIT_CLEAR


def run_pid_operation(args: argparse.Namespace, inspector: ProcessInspector | None) -> int:
    if args.operation == "list":
        pids = matching_processes(args.executable, inspector)
    else:
        pids = terminate_matching_processes(args.executable, inspector)
    for pid in pids:
        print(pid)
    return 0


def main(argv: list[str], inspector: ProcessInspector | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.operation == "guard":
            return run_guard(args, inspector)
        return run_pid_operation(args, inspector)
    except ProcessIdentityError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return EXIT_INSPECTION_FAILED


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
