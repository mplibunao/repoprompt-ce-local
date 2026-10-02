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
import plistlib
import signal
import stat
import sys
import xml.parsers.expat
from collections.abc import Mapping
from pathlib import Path
from typing import Callable, NamedTuple, Protocol

PROC_ALL_PIDS = 1
PROC_PIDPATHINFO_MAXSIZE = 4096
MCP_EXECUTABLE_NAME = "repoprompt-mcp"
DEBUG_APP_EXECUTABLE_NAME = "RepoPromptDebug"
# Debug bundles packaged before the rename declare the release executable name, and one can
# still be installed or running at the configured debug path, so it stays recognized there.
LEGACY_DEBUG_APP_EXECUTABLE_NAME = "RepoPrompt"
DEBUG_APP_EXECUTABLE_NAMES = (DEBUG_APP_EXECUTABLE_NAME, LEGACY_DEBUG_APP_EXECUTABLE_NAME)
# The `RepoPromptSigningMode` values Scripts/package_app.sh writes for debug packages; every
# other value belongs to a release build.
DEBUG_SIGNING_MODES = frozenset({"debug-apple-development", "debug-adhoc"})
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


def resolved_target(expected_executable: Path) -> tuple[Path | None, str]:
    # An absent target still has its named processes inspected: a process still running
    # from a deleted or replaced executable must not be reported as stopped.
    try:
        expected = expected_executable_path(expected_executable)
    except TargetExecutableMissing:
        return None, expected_executable.name
    return expected, expected.name


def live_candidate_path(inspector: ProcessInspector, pid: int, name: str) -> Path | None:
    """Returns a named candidate's executable, or None once the process has exited.

    libproc reports a running process whose executable was deleted the same way as an
    exited one, so only a process that no longer answers to its name counts as gone.
    """
    try:
        return inspector.process_path(pid)
    except ProcessGone:
        if inspector.process_name(pid) != name:
            return None
        raise ProcessIdentityError(
            f"{name} process {pid} is running but its executable cannot be resolved; it may have been deleted"
        ) from None


def matching_processes(expected_executable: Path, inspector: ProcessInspector | None = None) -> list[int]:
    expected, name = resolved_target(expected_executable)
    active_inspector = inspector or LibProcInspector()
    matches: list[int] = []
    for pid in active_inspector.list_pids():
        if active_inspector.process_name(pid) != name:
            continue
        actual = live_candidate_path(active_inspector, pid, name)
        if actual is not None and actual == expected:
            matches.append(pid)
    return matches


def terminate_matching_processes(
    expected_executable: Path,
    inspector: ProcessInspector | None = None,
    signaler: Callable[[int, int], None] = os.kill,
) -> list[int]:
    expected, name = resolved_target(expected_executable)
    active_inspector = inspector or LibProcInspector()
    signaled: list[int] = []
    for pid in matching_processes(expected_executable, active_inspector):
        actual = live_candidate_path(active_inspector, pid, name)
        if actual is None:
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


def bundle_info(bundle: Path) -> dict[str, object]:
    info_path = bundle / "Contents" / "Info.plist"
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except FileNotFoundError as exc:
        raise ProcessIdentityError(f"app bundle has no Info.plist: {bundle}") from exc
    except (OSError, ValueError, xml.parsers.expat.ExpatError) as exc:
        raise ProcessIdentityError(f"could not read {info_path}: {exc}") from exc
    if not isinstance(info, dict):
        raise ProcessIdentityError(f"{info_path} is not a dictionary")
    return info


def packaged_app_executable(
    bundle: Path,
    expected_name: str | None = None,
    info: Mapping[str, object] | None = None,
) -> Path:
    """Returns the canonical GUI executable that a bundle's Info.plist declares.

    Metadata only selects which exact path to inspect. It never authorizes signaling a
    process on its own. An expected name is an assertion, not a fallback.
    """
    declared = (info if info is not None else bundle_info(bundle)).get("CFBundleExecutable")
    if not isinstance(declared, str) or not declared or declared in {".", ".."} or "/" in declared or "\0" in declared:
        raise ProcessIdentityError(f"invalid CFBundleExecutable in {bundle}: {declared!r}")
    if expected_name is not None and declared != expected_name:
        raise ProcessIdentityError(f"{bundle} declares executable {declared!r}, expected {expected_name!r}")
    try:
        canonical_bundle = bundle.resolve(strict=True)
        executable = canonical_bundle / "Contents" / "MacOS" / declared
        metadata = executable.lstat()
        resolved = executable.resolve(strict=True)
    except OSError as exc:
        raise ProcessIdentityError(f"declared executable {declared!r} is unavailable in {bundle}: {exc}") from exc
    if stat.S_ISLNK(metadata.st_mode):
        raise ProcessIdentityError(f"declared executable is a symlink: {executable}")
    if not resolved.is_relative_to(canonical_bundle):
        raise ProcessIdentityError(f"declared executable escapes its bundle: {resolved}")
    if not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111:
        raise ProcessIdentityError(f"declared executable is not an executable regular file: {resolved}")
    return resolved


def debug_bundle_executable(bundle: Path, expected_name: str | None = None) -> Path:
    """Returns the declared GUI executable of a bundle that must be a debug package."""
    info = bundle_info(bundle)
    marker = info.get("RepoPromptSigningMode")
    if not isinstance(marker, str) or marker not in DEBUG_SIGNING_MODES:
        raise ProcessIdentityError(f"{bundle} is not a debug app bundle: its RepoPromptSigningMode is {marker!r}")
    executable = packaged_app_executable(bundle, expected_name, info)
    if executable.name not in DEBUG_APP_EXECUTABLE_NAMES:
        raise ProcessIdentityError(f"{bundle} declares {executable.name!r}, which is not a debug app executable")
    return executable


def debug_lifecycle_executables(bundle: Path) -> tuple[Path, ...]:
    """The exact paths that debug stop, status, and launch confirmation inspect.

    Both the current and the legacy leaf are inspected, because a pre-rename instance can
    still be running at the same location. A bundle that exists must be debug-marked, so a
    configured path that is actually a release bundle is never a stop target.
    """
    leaves = tuple(bundle / "Contents" / "MacOS" / name for name in DEBUG_APP_EXECUTABLE_NAMES)
    if not os.path.lexists(bundle):
        return leaves
    debug_bundle_executable(bundle)
    try:
        canonical_bundle = bundle.resolve(strict=True)
    except OSError as exc:
        raise ProcessIdentityError(f"debug app bundle is unavailable: {bundle}: {exc}") from exc
    for leaf in leaves:
        require_contained_leaf(leaf, canonical_bundle)
    return leaves


def require_contained_leaf(leaf: Path, canonical_bundle: Path) -> None:
    # Process matching follows symlinks, so every candidate leaf is checked, not only the
    # declared one: an undeclared leaf that links elsewhere would make its target, such as
    # the production app, a stop target. An absent leaf has nothing to match.
    try:
        metadata = leaf.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise ProcessIdentityError(f"debug app executable is unavailable: {leaf}: {exc}") from exc
    remedy = "remove or correct the unsafe leaf first, then retry './conductor run'"
    if stat.S_ISLNK(metadata.st_mode):
        raise ProcessIdentityError(f"debug app executable {leaf} is a symlink to {os.readlink(leaf)}; {remedy}")
    try:
        resolved = leaf.resolve(strict=True)
    except OSError as exc:
        raise ProcessIdentityError(f"debug app executable is unavailable: {leaf}: {exc}") from exc
    if not resolved.is_relative_to(canonical_bundle):
        raise ProcessIdentityError(f"debug app executable {leaf} resolves outside its bundle to {resolved}; {remedy}")


def configured_debug_app_executables(environ: Mapping[str, str]) -> list[Path]:
    # The GUI and MCP helper executables of the developer conductor's debug bundle override,
    # resolved the way Scripts/conductor.py resolves it. The default DebugApps location is
    # already covered by the support-dir rule.
    bundle = environ.get("REPOPROMPT_DEBUG_APP_BUNDLE")
    root = environ.get("REPOPROMPT_DEBUG_APP_ROOT")
    if bundle:
        configured = Path(bundle)
    elif root:
        configured = Path(root) / "RepoPrompt.app"
    else:
        return []
    return [configured / "Contents" / "MacOS" / name for name in (*DEBUG_APP_EXECUTABLE_NAMES, MCP_EXECUTABLE_NAME)]


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
    environ: Mapping[str, str] = os.environ,
) -> GuardPolicy:
    configured = comparable_path(production_executable)
    production_suffix = f"/{display_name}.app/Contents/MacOS"
    support = comparable_path(support_dir)
    identity_names = frozenset({app_name, MCP_EXECUTABLE_NAME})
    configured_debug = {comparable_path(path) for path in configured_debug_app_executables(environ)}

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
        if actual == configured or actual in configured_debug:
            return True
        # The renamed debug executable identifies RepoPrompt only inside a debug bundle;
        # an unrelated executable that happens to share the name is not a blocker.
        if actual.name == DEBUG_APP_EXECUTABLE_NAME:
            return in_debug_apps(actual.parent)
        return actual.name in identity_names and in_matched_bundle(actual.parent)

    return GuardPolicy(identity_names | {DEBUG_APP_EXECUTABLE_NAME} | CLI_ALIAS_NAMES, blocks)


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
