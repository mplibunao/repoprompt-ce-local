#!/usr/bin/env python3
"""Seed the debug profile one way from a verified production release archive.

The source is `application-support.tar.gz` in an archive written by
`Scripts/local_release_archive.sh`. The seed keeps the selected workspaces with their chat
and agent history, the workspace index, presets, and global settings; rewrites file paths
that point into the archived production profile so they point into the debug profile; and
publishes the result as `~/Library/Application Support/RepoPrompt CE Debug` with one
rename. The live production profile is never read, written, or locked.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import errno
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import sys
import tarfile
import tempfile
import time
import unicodedata
import zlib
from collections import Counter
from collections.abc import Callable, Iterator, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import debug_app_process  # noqa: E402

# MCPFilesystemIdentity.applicationSupportDirectoryName for the release and debug flavors.
PRODUCTION_PROFILE_NAME = "RepoPrompt CE"
DEBUG_PROFILE_NAME = "RepoPrompt CE Debug"
ARCHIVE_ROOT_RELATIVE = Path("Archives") / "repoprompt-ce"
STATE_ARCHIVE_NAME = "application-support.tar.gz"
MANIFEST_NAME = "manifest.json"
MANIFEST_SCHEMA_VERSION = 1
DEBUG_BUNDLE_NAME = "RepoPrompt.app"
JOURNAL_SCHEMA_KEY = "RepoPromptWorkingJournalSchemaVersion"
# The tag contract of resolve_release_tag in Scripts/local_release_env.sh.
TAG_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]*")
TAG_SEGMENT_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# Tags nest under the archive root (`local/v1.4.0-b45`); the bound keeps the newest-archive
# search out of unrelated trees such as a restore's rescue copy.
MAX_TAG_DEPTH = 4
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
# The conductor smoke flow creates and switches to this workspace by name. A seeded workspace
# with the same name would replace that small, predictable fixture with production history.
SMOKE_WORKSPACE_NAME = "repoprompt-ce"

UUID_PATTERN = r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
# DomainWorkspaceStoragePath.directoryName(name:id:).
WORKSPACE_FOLDER_PATTERN = re.compile(rf"Workspace-(?P<name>.*)-(?P<id>{UUID_PATTERN})")
WORKSPACE_INDEX_NAME = "workspacesIndex.json"
WORKSPACE_DOCUMENT_NAME = "workspace.json"
WORKSPACE_HISTORY_FOLDERS = frozenset({"Chats", "AgentSessions"})
CATALOG_NAME = "workspace-catalog.json"
# The app composes its domain runtime with profile identifier "default", and
# DomainRuntimeConfiguration.runtimeRootDirectory names the runtime root after the identifier
# and the first twelve hex digits of its SHA-256 digest. Debug uses the same identifier.
RUNTIME_ROOT_NAME = "default-" + hashlib.sha256(b"default").hexdigest()[:12]
PER_WORKSPACE_RUNTIME_FOLDERS = frozenset({"working-journals", "revisions", "deletion-tombstones"})
POLICY_FILES = frozenset({"runtime-policy.json", "protected-mutations.json", "protected-mutation-journal.json"})
# Run ownership and worktree routing for live agent runs, keyed to the runtime that owned
# them. Debug must not adopt production's runs; transcripts and their worktree bindings
# travel in the per-workspace AgentSessions files instead.
RUN_OWNERSHIP_FILES = frozenset({"agent-sessions.json", "agent-worktree-bindings.json"})
# Foundation's atomic writes stage `<name>.sb-<8 hex>-<6 chars>` beside the target.
ATOMIC_SAVE_TEMPORARY = re.compile(r"\.sb-[0-9A-Fa-f]{8}-[A-Za-z0-9]{6}$")
# Characters Foundation leaves unescaped in a file URL's path, so a rewritten prefix keeps
# the encoding of the rest of the URL.
URL_PATH_SAFE = "/!$&'()*+,;=:@"
COPY_CHUNK_BYTES = 1 << 20
MAX_REPORTED_NAMES = 12
# Object keys can themselves carry paths or secrets, so a refusal names a key only when it
# looks like an identifier.
REPORTABLE_KEY = re.compile(r"[A-Za-z0-9_.-]{1,64}")
# O_NOFOLLOW makes opening a file whose final component is a link fail instead of writing
# through it.
WRITE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)

CODEX = "managed Codex homes and SQLite"
MCP_ROUTING = "MCP routing records"
POLICY = "policy caches"
RUN_OWNERSHIP = "agent run ownership records"
EVENTS = "event and kill-signal directories"
LOCKS = "locks and PID files"
DIAGNOSTICS = "diagnostics"
TEMPORARY = "temporary state"
APPLE_DOUBLE = "macOS AppleDouble metadata"
OTHER = "other entries outside the allowlist"
EXCLUDED_CATEGORY_ORDER = (CODEX, MCP_ROUTING, POLICY, RUN_OWNERSHIP, EVENTS, LOCKS, DIAGNOSTICS, TEMPORARY, APPLE_DOUBLE, OTHER)


class SeedError(Exception):
    """A refusal; the debug profile is unchanged and any staging directory is removed."""


@dataclass(frozen=True)
class Locations:
    home: Path

    @property
    def application_support(self) -> Path:
        return self.home / "Library" / "Application Support"

    @property
    def production_root(self) -> Path:
        return self.application_support / PRODUCTION_PROFILE_NAME

    @property
    def debug_root(self) -> Path:
        return self.application_support / DEBUG_PROFILE_NAME

    @property
    def archive_root(self) -> Path:
        return self.home / ARCHIVE_ROOT_RELATIVE


@dataclass(frozen=True)
class Archive:
    directory: Path
    tag: str
    manifest: Mapping[str, object]
    archived_at_epoch: float
    source_root: str

    @property
    def state_path(self) -> Path:
        return self.directory / STATE_ARCHIVE_NAME


@dataclass
class Workspace:
    id: str
    name: str
    folders: frozenset[str]
    skip_reason: str | None = None


@dataclass
class Survey:
    folders_by_id: dict[str, set[str]] = field(default_factory=dict)
    folder_names: dict[str, str] = field(default_factory=dict)
    documented_folders: set[str] = field(default_factory=set)
    index: object = None
    catalog: object = None
    excluded: Counter[tuple[str, str]] = field(default_factory=Counter)
    links: list[tuple[tuple[str, ...], str]] = field(default_factory=list)
    destinations: dict[str, tuple[str, ...]] = field(default_factory=dict)
    collisions: list[tuple[tuple[str, ...], tuple[str, ...]]] = field(default_factory=list)


@dataclass
class WorkspacePlan:
    copied: list[Workspace]
    skipped: list[Workspace]
    unselected: int
    unindexed_folders: int

    @property
    def ids(self) -> frozenset[str]:
        return frozenset(workspace.id for workspace in self.copied)

    @property
    def folders(self) -> frozenset[str]:
        return frozenset(folder for workspace in self.copied for folder in workspace.folders)


@dataclass
class CopyStats:
    files: int = 0
    bytes: int = 0
    rewritten_paths: int = 0
    rewritten_files: int = 0
    unparsed_json_files: int = 0
    updated_journal_digests: int = 0
    updated_revision_digests: int = 0
    rewritten_working_documents: int = 0


def step(message: str) -> None:
    print(f"\n==> {message}", flush=True)


# -- archive selection and verification -------------------------------------------------


def load_archive(directory: Path, expected_tag: str | None) -> Archive:
    manifest_path = directory / MANIFEST_NAME
    if not manifest_path.is_file():
        raise SeedError(f"No completed archive at {directory}: manifest.json is written last and is missing.")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SeedError(f"Unreadable manifest {manifest_path}: {error}") from error
    if not isinstance(manifest, dict):
        raise SeedError(f"Manifest {manifest_path} is not a JSON object.")
    if manifest.get("schemaVersion") != MANIFEST_SCHEMA_VERSION:
        raise SeedError(f"Manifest {manifest_path} has unsupported schemaVersion {manifest.get('schemaVersion')!r}.")
    tag = manifest.get("tag")
    if not isinstance(tag, str) or not tag:
        raise SeedError(f"Manifest {manifest_path} records no tag.")
    if expected_tag is not None and tag != expected_tag:
        raise SeedError(f"Manifest {manifest_path} records tag {tag!r}, not {expected_tag!r}.")
    epoch = manifest.get("archivedAtEpoch")
    if not isinstance(epoch, (int, float)) or isinstance(epoch, bool):
        raise SeedError(f"Manifest {manifest_path} records no archive timestamp.")
    support = manifest.get("applicationSupport")
    source_root = support.get("sourcePath") if isinstance(support, dict) else None
    if not isinstance(source_root, str) or not source_root.startswith("/") or source_root.rstrip("/") == "":
        raise SeedError(f"Manifest {manifest_path} does not record the archived profile's absolute path.")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise SeedError(f"Manifest {manifest_path} lists no archive files.")
    for name in files:
        if not isinstance(name, str) or not name or "/" in name or name in {".", ".."}:
            raise SeedError(f"Manifest {manifest_path} lists an unusable file name {name!r}.")
    if STATE_ARCHIVE_NAME not in files:
        raise SeedError(f"Manifest {manifest_path} does not list {STATE_ARCHIVE_NAME}.")
    return Archive(directory, tag, manifest, float(epoch), source_root.rstrip("/"))


def complete_archives(archive_root: Path) -> list[Archive]:
    archives: list[Archive] = []
    pending = [(archive_root, 0)]
    while pending:
        directory, depth = pending.pop()
        if (directory / MANIFEST_NAME).is_file():
            try:
                archives.append(load_archive(directory, directory.relative_to(archive_root).as_posix()))
            except SeedError:
                pass
            continue
        if depth >= MAX_TAG_DEPTH:
            continue
        try:
            children = sorted(directory.iterdir())
        except OSError:
            continue
        for child in children:
            # A restore leaves `<tag>.rescue-<timestamp>.<suffix>` beside the archive holding a
            # full copy of the replaced state; it is never an archive.
            if (
                TAG_SEGMENT_PATTERN.fullmatch(child.name)
                and ".rescue-" not in child.name
                and child.is_dir()
                and not child.is_symlink()
            ):
                pending.append((child, depth + 1))
    return archives


def resolve_archive(selector: str | None, archive_root: Path) -> Archive:
    if selector is None:
        archives = complete_archives(archive_root)
        if not archives:
            raise SeedError(
                f"No completed release archive under {archive_root}. "
                "Create one with Scripts/local_release_archive.sh <tag>, or pass --archive."
            )
        return max(archives, key=lambda archive: archive.archived_at_epoch)
    if selector.startswith("/"):
        directory = Path(selector)
        if not directory.is_dir():
            raise SeedError(f"No archive directory at {directory}.")
        return load_archive(directory, expected_tag=None)
    if not TAG_PATTERN.fullmatch(selector) or ".." in selector or selector.endswith("/"):
        raise SeedError(f"Refusing unsafe tag: {selector}")
    return load_archive(archive_root / selector, expected_tag=selector)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(COPY_CHUNK_BYTES):
            digest.update(chunk)
    return digest.hexdigest()


def verify_checksums(archive: Archive) -> int:
    """Checks every listed file against its sidecar and the manifest.

    Every file is hashed, including the preferences export and the signing identity record,
    so the whole rollback unit is known intact; their bytes are only hashed, never parsed.
    """
    files = archive.manifest["files"]
    assert isinstance(files, dict)
    for name, record in sorted(files.items()):
        path = archive.directory / name
        sidecar = archive.directory / f"{name}.sha256"
        if not path.is_file():
            raise SeedError(f"Manifest names a missing archive file: {name}")
        if not sidecar.is_file():
            raise SeedError(f"Missing checksum sidecar for {name}")
        expected = record.get("sha256") if isinstance(record, dict) else None
        if not isinstance(expected, str) or not SHA256_PATTERN.fullmatch(expected):
            raise SeedError(f"Manifest records no usable checksum for {name}")
        recorded_size = record.get("bytes")
        if type(recorded_size) is int and recorded_size != path.stat().st_size:
            raise SeedError(f"Size mismatch for {name}; refusing to seed from {archive.directory}.")
        sidecar_fields = sidecar.read_text(encoding="utf-8").split()
        if len(sidecar_fields) != 2 or sidecar_fields[1].lstrip("*") != name:
            raise SeedError(f"Malformed checksum sidecar for {name}")
        actual = sha256_of(path)
        if not (sidecar_fields[0].lower() == expected == actual):
            raise SeedError(f"Checksum mismatch for {name}; refusing to seed from {archive.directory}.")
    return len(files)


# -- format gate --------------------------------------------------------------------------


def debug_bundle_path(locations: Locations, environ: Mapping[str, str]) -> Path:
    # The bundle Scripts/package_app.sh writes and conductor launches, honoring the same
    # conductor overrides that the process guard reads.
    bundle = environ.get("REPOPROMPT_DEBUG_APP_BUNDLE")
    if bundle:
        return Path(bundle)
    root = environ.get("REPOPROMPT_DEBUG_APP_ROOT")
    if root:
        return Path(root) / DEBUG_BUNDLE_NAME
    return locations.production_root / "DebugApps" / DEBUG_BUNDLE_NAME


def supported_journal_schema_version(bundle: Path) -> int:
    if not bundle.is_dir():
        raise SeedError(
            f"No debug app bundle at {bundle}, so the working-journal format it reads is unknown. "
            "Build it with `make dev-build` first."
        )
    try:
        info = debug_app_process.bundle_info(bundle)
    except debug_app_process.ProcessIdentityError as error:
        raise SeedError(str(error)) from error
    if info.get("RepoPromptSigningMode") not in debug_app_process.DEBUG_SIGNING_MODES:
        raise SeedError(f"{bundle} is not a debug app bundle.")
    version = info.get(JOURNAL_SCHEMA_KEY)
    if type(version) is not int:
        raise SeedError(f"{bundle} declares no integer {JOURNAL_SCHEMA_KEY}; rebuild it with `make dev-build`.")
    return version


def check_journal_schema(archive: Archive, supported: int) -> int:
    """Applies the promotion procedure's forward-compatibility comparison to the debug build.

    An older archive is allowed: the debug build reads it the way production will after its
    next upgrade. A version the archive could not establish proves nothing and refuses.
    """
    version = archive.manifest.get("working_journal_schema_version")
    status = archive.manifest.get("working_journal_schema_version_status")
    if type(version) is not int or status == "unknown":
        raise SeedError(
            f"Archive {archive.tag} records no working-journal schema version (status {status!r}), "
            "so the seed cannot show that the debug build reads its journals."
        )
    if version > supported:
        raise SeedError(
            f"Archive {archive.tag} uses working-journal schema {version}, newer than the {supported} "
            "the debug build supports. Rebuild the debug app from a newer checkout."
        )
    observed = archive.manifest.get("observed_working_journal_versions")
    if not isinstance(observed, list) or any(type(value) is not int for value in observed):
        raise SeedError(f"Archive {archive.tag} does not record the working-journal versions it contains.")
    if observed and max(observed) > supported:
        raise SeedError(
            f"Archive {archive.tag} contains working journals at version {max(observed)}, newer than the "
            f"{supported} the debug build supports."
        )
    return version


# -- preconditions ------------------------------------------------------------------------


def debug_process_policy(production_root: Path, environ: Mapping[str, str]) -> debug_app_process.GuardPolicy:
    """Matches every process that can write the debug profile and nothing in production.

    Those are the debug app and its MCP helper in any debug bundle under the production
    profile's `DebugApps` or `DebugApps-*` directories, and conductor's configured bundle.
    The release app and its CLI are inspected only to be ruled out, so a running production
    app never blocks the seed.
    """
    support = debug_app_process.comparable_path(production_root)
    configured = {
        debug_app_process.comparable_path(path) for path in debug_app_process.configured_debug_app_executables(environ)
    }
    executable_names = frozenset({*debug_app_process.DEBUG_APP_EXECUTABLE_NAMES, debug_app_process.MCP_EXECUTABLE_NAME})

    def blocks(actual: Path) -> bool:
        if actual in configured:
            return True
        try:
            top_level_entry = actual.relative_to(support).parts[0]
        except (ValueError, IndexError):
            return False
        in_debug_apps = top_level_entry == "DebugApps" or top_level_entry.startswith("DebugApps-")
        return in_debug_apps and actual.name in executable_names

    return debug_app_process.GuardPolicy(executable_names | debug_app_process.CLI_ALIAS_NAMES, blocks)


def require_debug_app_stopped(
    locations: Locations,
    environ: Mapping[str, str],
    inspector: debug_app_process.ProcessInspector | None,
) -> None:
    try:
        blocking = debug_app_process.blocking_processes(
            debug_process_policy(locations.production_root, environ), inspector
        )
    except debug_app_process.ProcessIdentityError as error:
        raise SeedError(f"Could not confirm that the debug app is stopped: {error}") from error
    if blocking:
        listing = "\n".join(f"  {process.pid}  {process.executable}" for process in blocking)
        raise SeedError(f"Quit the debug app and any attached debug CLI first; these processes use the debug profile:\n{listing}")


def destination_state(debug_root: Path) -> str:
    try:
        metadata = os.lstat(debug_root)
    except FileNotFoundError:
        return "absent"
    if stat.S_ISLNK(metadata.st_mode):
        raise SeedError(f"{debug_root} is a symlink; the seed never writes through one. Remove it first.")
    if not stat.S_ISDIR(metadata.st_mode):
        raise SeedError(f"{debug_root} exists and is not a directory.")
    with os.scandir(debug_root) as entries:
        return "occupied" if any(True for _ in entries) else "empty"


def require_outside_production(sources: list[str], locations: Locations) -> None:
    """Refuses when the destination or its staging parent physically lies in production.

    realpath follows a symlink at any existing ancestor, such as a disposable home whose
    `Library/Application Support` links into the production profile. The production root is
    a sibling inside the staging parent by design, so only the debug root must not contain it.
    """
    debug_root = canonical_path(os.path.realpath(locations.debug_root))
    staging_parent = canonical_path(os.path.realpath(locations.application_support))
    for source in sources:
        production = canonical_path(os.path.realpath(source))
        if within(debug_root, production) or within(staging_parent, production) or within(production, debug_root):
            raise SeedError(
                f"The debug profile {locations.debug_root} or its staging directory resolves into the production "
                f"profile {source}, or contains it. Nothing was changed."
            )


# -- path rewriting -----------------------------------------------------------------------


def canonical_path(path: str) -> str:
    # APFS compares names case-insensitively and normalization-insensitively by default, so a
    # variant spelling of the production root still reaches production.
    normalized = os.path.normpath(re.sub(r"^/+", "/", path))
    return unicodedata.normalize("NFC", normalized).casefold()


def within(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def local_path(value: str) -> str | None:
    """The filesystem path a JSON string names, or None when it is not an absolute path."""
    if value.startswith("/"):
        return value
    if value[:5].lower() != "file:":
        return None
    try:
        parts = urlsplit(value)
    except ValueError:
        return None
    if parts.scheme.lower() != "file" or parts.netloc.lower() not in {"", "localhost"}:
        return None
    path = unquote(parts.path)
    return path if path.startswith("/") else None


class ProfilePathMap:
    """Moves string values naming the production profile onto the debug profile.

    Only a value that begins with the production root, as a plain path or as a file URL, is
    rewritten; free text that merely mentions the path is data and stays as written.
    """

    def __init__(self, sources: list[str], target: str) -> None:
        self.target = target
        self.sources = sources
        self.encoded_target = "file://" + quote(target, safe=URL_PATH_SAFE)
        self.encoded_sources = ["file://" + quote(source, safe=URL_PATH_SAFE) for source in sources]
        self.production_roots = [canonical_path(source) for source in sources]

    def rewrite(self, value: str) -> str | None:
        for source in self.sources:
            if value == source or value.startswith(source + "/"):
                return self.target + value[len(source):]
        if value.startswith("file:"):
            for source in self.encoded_sources:
                if value.startswith(source) and (len(value) == len(source) or value[len(source)] in "/?#"):
                    return self.encoded_target + value[len(source):]
        return None

    def reaches_production(self, value: str) -> bool:
        path = local_path(value)
        if path is None:
            return False
        candidate = canonical_path(path)
        return any(within(candidate, root) for root in self.production_roots)


def rewrite_json_strings(document: object, rewrite: Callable[[str], str | None]) -> tuple[object, int]:
    """Rewrites object keys and string values in place, iteratively so depth is unbounded."""
    if isinstance(document, str):
        replacement = rewrite(document)
        return (document, 0) if replacement is None else (replacement, 1)
    count = 0
    pending = [document] if isinstance(document, (list, dict)) else []
    while pending:
        node = pending.pop()
        if isinstance(node, list):
            for position, value in enumerate(node):
                if isinstance(value, str):
                    replacement = rewrite(value)
                    if replacement is not None:
                        node[position] = replacement
                        count += 1
                elif isinstance(value, (list, dict)):
                    pending.append(value)
            continue
        assert isinstance(node, dict)
        items: list[tuple[str, object]] = []
        changed = False
        for key, value in node.items():
            new_key = rewrite(key)
            if new_key is not None:
                key, changed, count = new_key, True, count + 1
            if isinstance(value, str):
                replacement = rewrite(value)
                if replacement is not None:
                    value, changed, count = replacement, True, count + 1
            elif isinstance(value, (list, dict)):
                pending.append(value)
            items.append((key, value))
        if changed:
            node.clear()
            node.update(items)
    return document, count


def pointer_segment(key: str, position: int) -> str:
    return key if REPORTABLE_KEY.fullmatch(key) else f"<key {position}>"


def production_locations(document: object, reaches_production: Callable[[str], bool]) -> list[str]:
    """JSON locations of strings that resolve into production; the strings themselves can hold
    transcript text or URL credentials, so only their locations are ever reported."""
    found: list[str] = []
    pending: list[tuple[object, str]] = [(document, "")]
    while pending:
        node, pointer = pending.pop()
        if isinstance(node, str):
            if reaches_production(node):
                found.append(pointer or "/")
        elif isinstance(node, list):
            pending.extend((value, f"{pointer}/{index}") for index, value in enumerate(node))
        elif isinstance(node, dict):
            for position, (key, value) in enumerate(node.items()):
                location = f"{pointer}/{pointer_segment(key, position)}"
                if reaches_production(key):
                    found.append(f"{location} (object key)")
                pending.append((value, location))
    return sorted(found)


def encode_json(document: object) -> bytes:
    try:
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    except UnicodeEncodeError:
        # A lone surrogate escape survives decoding but has no UTF-8 form; ASCII escapes keep it.
        return json.dumps(document, separators=(",", ":")).encode("ascii")


# -- archive layout -----------------------------------------------------------------------


def member_parts(name: str) -> tuple[str, ...] | None:
    """Relative path components of a member, or None for the archive's root entry."""
    path = name
    while path.startswith("./"):
        path = path[2:]
    path = path.rstrip("/")
    if path in {"", "."}:
        return None
    if name.startswith("/"):
        raise SeedError(f"The state archive holds an absolute member name {name!r}; refusing to extract it.")
    parts = tuple(path.split("/"))
    if any(part in {"", ".", ".."} for part in parts):
        raise SeedError(f"The state archive holds an unsafe member name {name!r}; refusing to extract it.")
    return parts


def is_json_name(name: str) -> bool:
    return name.lower().endswith(".json")


def excluded_category(parts: tuple[str, ...]) -> tuple[str, str] | None:
    """The report category and display name of state the seed never copies.

    None marks an allowlist candidate; whether it is copied then depends on the selected
    workspaces.
    """
    name, top = parts[-1], parts[0]
    if name.startswith("._"):
        return APPLE_DOUBLE, "._*"
    if name.endswith((".lock", ".pid")):
        return LOCKS, "*" + Path(name).suffix
    if ATOMIC_SAVE_TEMPORARY.search(name):
        return TEMPORARY, "*.sb-* atomic-save files"
    if top == "Workspaces":
        return excluded_workspace_entry(parts)
    if top == "DomainRuntime":
        return excluded_runtime_entry(parts)
    if top == "Presets":
        return None if len(parts) == 1 or (len(parts) == 2 and is_json_name(name)) else (OTHER, "Presets/" + "/".join(parts[1:]))
    if top == "Settings":
        return None if parts in {("Settings",), ("Settings", "globalSettings.json")} else (OTHER, "Settings/" + parts[1])
    if top == "Codex":
        return CODEX, top
    if top == "MCP":
        return MCP_ROUTING, top
    if top == "Events" or top.startswith(("MCPEvents-", "MCPKillSignals-")):
        return EVENTS, top
    if top == "Diagnostics" or name.endswith(".log"):
        return DIAGNOSTICS, top
    if top in {"Temporary", "WorktreeMergePreviews", "workspace-cleanup-backups"}:
        return TEMPORARY, top
    return OTHER, top


def excluded_workspace_entry(parts: tuple[str, ...]) -> tuple[str, str] | None:
    if len(parts) == 1 or parts == ("Workspaces", WORKSPACE_INDEX_NAME):
        return None
    if not WORKSPACE_FOLDER_PATTERN.fullmatch(parts[1]):
        return OTHER, "Workspaces/" + parts[1]
    if len(parts) == 2 or parts[2] in WORKSPACE_HISTORY_FOLDERS or parts[2:] == (WORKSPACE_DOCUMENT_NAME,):
        return None
    return OTHER, "Workspaces/*/" + parts[2]


def excluded_runtime_entry(parts: tuple[str, ...]) -> tuple[str, str] | None:
    if len(parts) == 1:
        return None
    if parts[1] != "v1":
        return OTHER, "DomainRuntime/" + parts[1]
    if len(parts) == 2:
        return None
    if parts[2] != RUNTIME_ROOT_NAME:
        return (RUN_OWNERSHIP, "DomainRuntime/v1/" + parts[2]) if parts[2] in RUN_OWNERSHIP_FILES else (OTHER, "DomainRuntime/v1/" + parts[2])
    if len(parts) == 3 or parts[3:] == (CATALOG_NAME,):
        return None
    folder = parts[3]
    if folder in PER_WORKSPACE_RUNTIME_FOLDERS and len(parts) <= 5:
        return None
    if folder == "locks":
        return LOCKS, "DomainRuntime/v1/*/locks"
    if folder == "rollback":
        return TEMPORARY, "DomainRuntime/v1/*/rollback"
    if folder == "settings":
        if len(parts) == 4:
            return None
        if parts[4] in POLICY_FILES:
            return POLICY, "DomainRuntime/v1/*/settings/" + parts[4]
        if parts[4] in RUN_OWNERSHIP_FILES:
            return RUN_OWNERSHIP, "DomainRuntime/v1/*/settings/" + parts[4]
        return OTHER, "DomainRuntime/v1/*/settings/" + parts[4]
    return OTHER, "DomainRuntime/v1/*/" + folder


def open_state_archive(archive: Archive) -> Iterator[tuple[tarfile.TarFile, tarfile.TarInfo, tuple[str, ...]]]:
    try:
        with tarfile.open(archive.state_path, mode="r|gz") as state:
            for member in state:
                parts = member_parts(member.name)
                if parts is not None:
                    yield state, member, parts
    except (tarfile.TarError, OSError, EOFError, zlib.error) as error:
        raise SeedError(f"Could not read {archive.state_path}: {error}") from error


def read_member(state: tarfile.TarFile, member: tarfile.TarInfo) -> bytes:
    handle = state.extractfile(member)
    if handle is None:
        raise SeedError(f"Could not read archive member {member.name!r}.")
    with handle:
        return handle.read()


def load_json_member(state: tarfile.TarFile, member: tarfile.TarInfo, label: str) -> object:
    if not member.isreg():
        raise SeedError(f"The archived {label} is not a regular file.")
    try:
        return json.loads(read_member(state, member))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise SeedError(f"The archived {label} is not readable JSON: {error}") from error


def destination_key(parts: tuple[str, ...]) -> str:
    # APFS compares names case-insensitively and normalization-insensitively by default, so
    # two members whose keys match land on one file and the later overwrites the earlier.
    folded = unicodedata.normalize("NFD", "/".join(parts)).casefold()
    return unicodedata.normalize("NFD", folded)


def survey_archive(archive: Archive) -> Survey:
    survey = Survey()
    for state, member, parts in open_state_archive(archive):
        category = excluded_category(parts)
        if category is not None:
            survey.excluded[category] += 1
            continue
        if member.issym() or member.islnk():
            survey.links.append((parts, "symbolic" if member.issym() else "hard"))
        if not member.isdir():
            key = destination_key(parts)
            if key in survey.destinations:
                survey.collisions.append((survey.destinations[key], parts))
            else:
                survey.destinations[key] = parts
        if parts == ("Workspaces", WORKSPACE_INDEX_NAME):
            survey.index = load_json_member(state, member, "workspace index")
        elif parts == ("DomainRuntime", "v1", RUNTIME_ROOT_NAME, CATALOG_NAME):
            survey.catalog = load_json_member(state, member, "workspace catalog")
        if parts[0] == "Workspaces" and len(parts) >= 2:
            match = WORKSPACE_FOLDER_PATTERN.fullmatch(parts[1])
            if match:
                survey.folders_by_id.setdefault(match["id"].upper(), set()).add(parts[1])
                survey.folder_names[parts[1]] = match["name"]
                if parts[2:] == (WORKSPACE_DOCUMENT_NAME,) and member.isreg():
                    survey.documented_folders.add(parts[1])
    return survey


# -- workspace selection ------------------------------------------------------------------


def index_entries(index: object) -> list[dict[str, object]]:
    if index is None:
        return []
    if not isinstance(index, list) or not all(isinstance(entry, dict) and isinstance(entry.get("id"), str) for entry in index):
        raise SeedError("The archived workspace index has an unrecognized format; refusing to seed from it.")
    return index


def catalog_entries(catalog: object) -> list[dict[str, object]]:
    if catalog is None:
        return []
    entries = catalog.get("entries") if isinstance(catalog, dict) else None
    if not isinstance(entries, list) or not all(
        isinstance(entry, dict) and isinstance(entry.get("workspaceID"), str) for entry in entries
    ):
        raise SeedError("The archived workspace catalog has an unrecognized format; refusing to seed from it.")
    return entries


def require_unreserved_names(requested: list[str]) -> None:
    # An explicit request for the reserved name could only end in a reported skip and a
    # published profile without the workspace that was asked for.
    reserved = [name for name in requested if name.casefold() == SMOKE_WORKSPACE_NAME]
    if reserved:
        raise SeedError(
            f"The workspace name {reserved[0]!r} is reserved for the smoke workspace that `make dev-smoke` "
            "creates and uses, so the seed never copies it. Nothing was changed; remove that --workspace "
            "argument and rerun."
        )


def plan_workspaces(survey: Survey, source_root: str, requested: list[str]) -> WorkspacePlan:
    """Decides which archived workspaces are copied.

    A workspace is one the index or the runtime catalog lists. Folders neither lists are
    leftovers the app no longer shows, so they stay behind.
    """
    archived_workspaces = canonical_path(source_root + "/Workspaces")

    def outside_profile(value: object) -> bool:
        if not isinstance(value, str):
            return False
        path = local_path(value)
        return path is None or not within(canonical_path(path), archived_workspaces)

    names: dict[str, str] = {}
    custom: set[str] = set()
    listed_ids: set[str] = set()
    for entry in index_entries(survey.index):
        workspace_id = str(entry["id"]).upper()
        listed_ids.add(workspace_id)
        if isinstance(entry.get("name"), str):
            names.setdefault(workspace_id, str(entry["name"]))
        if outside_profile(entry.get("customStoragePath")):
            custom.add(workspace_id)
    for entry in catalog_entries(survey.catalog):
        workspace_id = str(entry["workspaceID"]).upper()
        listed_ids.add(workspace_id)
        if outside_profile(entry.get("fileURL")):
            custom.add(workspace_id)

    workspaces: list[Workspace] = []
    for workspace_id in sorted(listed_ids):
        folders = frozenset(survey.folders_by_id.get(workspace_id, ()))
        name = names.get(workspace_id) or next((survey.folder_names[folder] for folder in sorted(folders)), "(unnamed)")
        workspace = Workspace(workspace_id, name, folders)
        if workspace_id in custom:
            workspace.skip_reason = "custom storage outside the archived profile"
        elif name.casefold() == SMOKE_WORKSPACE_NAME:
            workspace.skip_reason = "reserved for the smoke workspace"
        elif not folders & survey.documented_folders:
            workspace.skip_reason = "missing from the archive"
        workspaces.append(workspace)

    candidates = workspaces
    if requested:
        unknown = [name for name in requested if not any(workspace.name == name for workspace in workspaces)]
        if unknown:
            available = ", ".join(sorted({workspace.name for workspace in workspaces})) or "none"
            raise SeedError(f"No workspace named {', '.join(map(repr, unknown))} in the archive. Workspaces: {available}")
        candidates = [workspace for workspace in workspaces if workspace.name in requested]
    known_ids = {workspace.id for workspace in workspaces}
    unindexed = {folder for workspace_id, folders in survey.folders_by_id.items() if workspace_id not in known_ids for folder in folders}
    return WorkspacePlan(
        copied=[workspace for workspace in candidates if workspace.skip_reason is None],
        skipped=[workspace for workspace in candidates if workspace.skip_reason is not None],
        unselected=len(workspaces) - len(candidates),
        unindexed_folders=len(unindexed),
    )


# -- copy ---------------------------------------------------------------------------------


@dataclass(frozen=True)
class CopyPlan:
    ids: frozenset[str]
    folders: frozenset[str]

    def includes(self, parts: tuple[str, ...]) -> bool:
        """Whether an allowlist candidate belongs to the selected workspaces' state."""
        if parts[0] == "Workspaces":
            return len(parts) == 1 or parts[1] == WORKSPACE_INDEX_NAME or parts[1] in self.folders
        if parts[0] == "DomainRuntime" and len(parts) == 5:
            stem, suffix = os.path.splitext(parts[4])
            return suffix.lower() == ".json" and stem.upper() in self.ids
        return True

    def filter_index(self, document: object) -> tuple[object, bool]:
        entries = index_entries(document)
        kept = [entry for entry in entries if str(entry["id"]).upper() in self.ids]
        return kept, len(kept) != len(entries)

    def filter_catalog(self, document: object) -> tuple[object, bool]:
        entries = catalog_entries(document)
        kept = [entry for entry in entries if str(entry["workspaceID"]).upper() in self.ids]
        if len(kept) == len(entries):
            return document, False
        assert isinstance(document, dict)
        return {**document, "entries": kept}, True


# Links are never materialized. A target checked lexically can still resolve elsewhere
# physically, through another link or through a case-variant name that APFS resolves to a
# link, and the release archives hold no links inside the state the seed copies.
def refuse_copied_links(links: list[tuple[tuple[str, ...], str]], plan: CopyPlan) -> None:
    copied = [(parts, kind) for parts, kind in links if plan.includes(parts)]
    if copied:
        parts, kind = copied[0]
        raise SeedError(
            f"The archive holds {len(copied)} link member(s) inside the state the seed copies, starting with the "
            f"{kind} link {'/'.join(parts)}. The seed copies no links; nothing was changed."
        )


def refuse_colliding_members(collisions: list[tuple[tuple[str, ...], tuple[str, ...]]], plan: CopyPlan) -> None:
    copied = [(first, second) for first, second in collisions if plan.includes(first) and plan.includes(second)]
    if copied:
        first, second = copied[0]
        raise SeedError(
            f"Archive members {'/'.join(first)} and {'/'.join(second)} name the same file on a case-insensitive "
            f"file system, so one would overwrite the other ({len(copied)} such pair(s)). Nothing was changed."
        )


def refuse_link_member(member: tarfile.TarInfo, relative: str) -> None:
    if member.issym() or member.islnk():
        raise SeedError(f"{relative} is a link inside the state the seed copies; the seed copies no links.")


class StagingWriter:
    """Writes copied members under the staging root and nowhere else; writes nothing in a dry run.

    Before every directory or file write, the parent must resolve inside the staging root, and
    files open with O_NOFOLLOW, so a link that reached staging by any route cannot carry a
    write elsewhere.
    """

    def __init__(self, root: Path | None) -> None:
        self.root = root
        self.real_root = os.path.realpath(root) if root is not None else ""
        self.created: set[tuple[str, ...]] = set()

    def require_inside(self, path: Path, relative: str) -> None:
        real = os.path.realpath(path)
        if os.path.commonpath([real, self.real_root]) != self.real_root:
            raise SeedError(f"Refusing to write {relative}: its directory resolves outside the staging directory.")

    def directory(self, parts: tuple[str, ...]) -> Path | None:
        if self.root is None:
            return None
        relative = "/".join(parts) or "."
        current = self.root
        for length, component in enumerate(parts, start=1):
            parent, current = current, current / component
            if parts[:length] in self.created:
                continue
            self.require_inside(parent, relative)
            try:
                os.mkdir(current, 0o755)
            except FileExistsError:
                pass
            self.created.add(parts[:length])
        self.require_inside(current, relative)
        return current

    def open_file(self, parts: tuple[str, ...]):
        parent = self.directory(parts[:-1])
        if parent is None:
            return None
        try:
            descriptor = os.open(parent / parts[-1], WRITE_FLAGS, 0o644)
        except OSError as error:
            if error.errno == errno.ELOOP:
                raise SeedError(f"Refusing to write {'/'.join(parts)} through a link in the staging directory.") from error
            raise
        return os.fdopen(descriptor, "wb")

    def file(self, parts: tuple[str, ...], data: bytes, mtime: float) -> int:
        target = self.open_file(parts)
        if target is not None:
            with target:
                target.write(data)
                target.flush()
                os.utime(target.fileno(), (mtime, mtime))
        return len(data)

    def stream(self, parts: tuple[str, ...], source, mtime: float) -> int:
        target = self.open_file(parts)
        if target is None:
            return sum(len(chunk) for chunk in iter(lambda: source.read(COPY_CHUNK_BYTES), b""))
        with target:
            shutil.copyfileobj(source, target, COPY_CHUNK_BYTES)
            target.flush()
            os.utime(target.fileno(), (mtime, mtime))
            return target.tell()


def member_key(relative: str) -> str:
    return unicodedata.normalize("NFC", relative).casefold()


def archived_member_key(value: str, sources: list[str]) -> str | None:
    """The archive member a path or file URL under an archived root names, as a member key."""
    path = local_path(value)
    if path is None:
        return None
    candidate = canonical_path(path)
    for source in sources:
        root = canonical_path(source)
        if candidate.startswith(root + "/"):
            return candidate[len(root) + 1:]
    return None


def saved_digest_update(
    documents: Mapping[str, tuple[str, str]], sources: list[str], stats: CopyStats
) -> Callable[[object], tuple[object, bool]]:
    """Moves a working journal's savedDigest to its rewritten workspace document.

    The runtime trusts a saved document only while its bytes hash to the journal's
    savedDigest, so a document the seed rewrote would otherwise read as externally edited.
    Only a digest that recorded the archived document changes; unsaved state such as the
    working document and a pending save stays exactly as archived.
    """

    def update(journal: object) -> tuple[object, bool]:
        if not isinstance(journal, dict):
            return journal, False
        file_url, saved_digest = journal.get("fileURL"), journal.get("savedDigest")
        if not isinstance(file_url, str) or not isinstance(saved_digest, str):
            return journal, False
        key = archived_member_key(file_url, sources)
        digests = documents.get(key) if key is not None else None
        if digests is None or saved_digest != digests[0]:
            return journal, False
        journal["savedDigest"] = digests[1]
        stats.updated_journal_digests += 1
        return journal, True

    return update


def rewrite_working_document(
    journal: object, relative: str, paths: ProfilePathMap, stats: CopyStats
) -> tuple[object, bool]:
    """Rewrites production paths inside a journal's unsaved working document.

    The journal carries the document's JSON bytes as base64, Swift's default encoding for
    Data, so the structural rewrite and the scan reach it only once decoded. Only savedDigest
    can name these bytes, and only when the saved document is byte-identical; the pending save
    and the per-context digests stay as archived.
    """
    encoded = journal.get("workingDocument") if isinstance(journal, dict) else None
    if not isinstance(encoded, str):
        return journal, False
    try:
        original = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        # The runtime cannot decode it either, so it reads the saved document instead.
        return journal, False
    scratch = CopyStats()
    rewritten = rewrite_json_member(original, f"{relative} (decoded workingDocument)", paths, None, scratch)
    if rewritten == original:
        return journal, False
    assert isinstance(journal, dict)
    journal["workingDocument"] = base64.b64encode(rewritten).decode("ascii")
    if journal.get("savedDigest") == hashlib.sha256(original).hexdigest():
        journal["savedDigest"] = hashlib.sha256(rewritten).hexdigest()
    stats.rewritten_paths += scratch.rewritten_paths
    stats.rewritten_working_documents += 1
    return journal, True


def journal_update(
    documents: Mapping[str, tuple[str, str]], paths: ProfilePathMap, stats: CopyStats, relative: str
) -> Callable[[object], tuple[object, bool]]:
    move_saved_digest = saved_digest_update(documents, paths.sources, stats)

    def update(journal: object) -> tuple[object, bool]:
        journal, digest_moved = move_saved_digest(journal)
        journal, working_rewritten = rewrite_working_document(journal, relative, paths, stats)
        return journal, digest_moved or working_rewritten

    return update


def revision_digest_update(
    documents: Mapping[str, list[tuple[str, str]]], workspace_id: str, stats: CopyStats
) -> Callable[[object], tuple[object, bool]]:
    """Moves a revision record's documentDigest to its rewritten workspace document.

    Without a working journal, the runtime keeps a workspace's saved revision only while
    this digest matches the document on disk. The record names no file, so it matches the
    workspace's rewritten documents by their archived SHA-256.
    """

    def update(record: object) -> tuple[object, bool]:
        digest = record.get("documentDigest") if isinstance(record, dict) else None
        if not isinstance(digest, str):
            return record, False
        for archived, written in documents.get(workspace_id, ()):
            if digest == archived:
                record["documentDigest"] = written
                stats.updated_revision_digests += 1
                return record, True
        return record, False

    return update


def rewrite_json_member(
    data: bytes,
    relative: str,
    paths: ProfilePathMap,
    transform: Callable[[object], tuple[object, bool]] | None,
    stats: CopyStats,
) -> bytes:
    try:
        document = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        # Unparseable JSON cannot be rewritten structurally; it is copied as written only when
        # it cannot name the production profile at all.
        lowered = data.lower()
        if any(source.casefold().encode("utf-8", "ignore") in lowered for source in paths.sources) or any(
            source.lower().encode("ascii", "ignore") in lowered for source in paths.encoded_sources
        ):
            raise SeedError(f"{relative} is not readable JSON and mentions the production profile; refusing to copy it.")
        stats.unparsed_json_files += 1
        return data
    document, transformed = transform(document) if transform is not None else (document, False)
    document, count = rewrite_json_strings(document, paths.rewrite)
    remaining = production_locations(document, paths.reaches_production)
    if remaining:
        listing = "\n".join(f"  {location}: resolves into the production profile" for location in remaining[:5])
        raise SeedError(
            f"{relative} still names the production profile after rewriting, at these JSON locations "
            f"(values withheld):\n{listing}"
        )
    # Unchanged files keep their exact bytes: a working journal records the SHA-256 of its
    # saved document, so a re-encoded but otherwise identical document would read as an
    # external edit.
    if count == 0 and not transformed:
        return data
    if count:
        stats.rewritten_paths += count
        stats.rewritten_files += 1
    return encode_json(document)


def runtime_record_folder(parts: tuple[str, ...]) -> str | None:
    """`working-journals` or `revisions` for a per-workspace record that names a saved digest."""
    if len(parts) == 5 and parts[:3] == ("DomainRuntime", "v1", RUNTIME_ROOT_NAME):
        if parts[3] in {"working-journals", "revisions"}:
            return parts[3]
    return None


def copy_state(archive: Archive, plan: CopyPlan, paths: ProfilePathMap, staging: Path | None) -> CopyStats:
    """Copies the allowlisted members, rewriting JSON on the way; no write when staging is None."""
    writer = StagingWriter(staging)
    stats = CopyStats()
    # Each workspace document the seed rewrote, as (archived SHA-256, written SHA-256), by
    # archive key and by workspace ID. Journals and revision records wait until every document
    # is known, because the archive order of Workspaces and DomainRuntime is not fixed.
    documents: dict[str, tuple[str, str]] = {}
    documents_by_workspace: dict[str, list[tuple[str, str]]] = {}
    records: list[tuple[tuple[str, ...], bytes, float]] = []
    for state, member, parts in open_state_archive(archive):
        if excluded_category(parts) is not None or not plan.includes(parts):
            continue
        relative = "/".join(parts)
        refuse_link_member(member, relative)
        if member.isdir():
            writer.directory(parts)
            continue
        if not member.isreg():
            raise SeedError(f"{relative} is a device, FIFO, or other special file; refusing to extract it.")
        if is_json_name(parts[-1]):
            raw = read_member(state, member)
            if runtime_record_folder(parts) is not None:
                records.append((parts, raw, member.mtime))
                continue
            transform = None
            if parts == ("Workspaces", WORKSPACE_INDEX_NAME):
                transform = plan.filter_index
            elif parts == ("DomainRuntime", "v1", RUNTIME_ROOT_NAME, CATALOG_NAME):
                transform = plan.filter_catalog
            data = rewrite_json_member(raw, relative, paths, transform, stats)
            if parts[0] == "Workspaces" and parts[2:] == (WORKSPACE_DOCUMENT_NAME,) and data != raw:
                digests = (hashlib.sha256(raw).hexdigest(), hashlib.sha256(data).hexdigest())
                documents[member_key(relative)] = digests
                folder = WORKSPACE_FOLDER_PATTERN.fullmatch(parts[1])
                if folder is not None:
                    documents_by_workspace.setdefault(folder["id"].upper(), []).append(digests)
            size = writer.file(parts, data, member.mtime)
        else:
            handle = state.extractfile(member)
            if handle is None:
                raise SeedError(f"Could not read archive member {relative}.")
            with handle:
                size = writer.stream(parts, handle, member.mtime)
        stats.files += 1
        stats.bytes += size
    for parts, raw, mtime in records:
        if runtime_record_folder(parts) == "working-journals":
            update = journal_update(documents, paths, stats, "/".join(parts))
        else:
            # revisionURL(workspaceID) names the file, so its stem is the workspace it describes.
            update = revision_digest_update(documents_by_workspace, os.path.splitext(parts[4])[0].upper(), stats)
        data = rewrite_json_member(raw, "/".join(parts), paths, update, stats)
        stats.files += 1
        stats.bytes += writer.file(parts, data, mtime)
    return stats


# -- publish ------------------------------------------------------------------------------


def make_staging(locations: Locations, publishing: PublishState) -> Path:
    # A sibling of the destination keeps the final rename on one filesystem, so publishing is
    # a single atomic rename. The directory is registered before returning, so cleanup finds
    # it even when an interrupt lands before the caller's assignment completes.
    locations.application_support.mkdir(parents=True, exist_ok=True)
    publishing.staging = Path(
        tempfile.mkdtemp(prefix=f".{DEBUG_PROFILE_NAME}.seed-staging-", dir=locations.application_support)
    )
    return publishing.staging


def remove_staging(staging: Path, locations: Locations) -> None:
    if staging.parent != locations.application_support or not staging.name.startswith(f".{DEBUG_PROFILE_NAME}.seed-staging-"):
        raise SeedError(f"Refusing to remove {staging}; it is not this seed's staging directory.")
    try:
        shutil.rmtree(staging)
    except OSError as error:
        print(f"WARNING: could not remove the staging directory {staging}: {error}", file=sys.stderr)


def backup_path(debug_root: Path) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    candidate = debug_root.with_name(f"{debug_root.name}.before-seed-{stamp}")
    suffix = 2
    while os.path.lexists(candidate):
        candidate = debug_root.with_name(f"{debug_root.name}.before-seed-{stamp}-{suffix}")
        suffix += 1
    return candidate


@dataclass
class PublishState:
    """What publishing changed, so the final message is true whatever stops the seed."""

    started: bool = False
    published: bool = False
    backup: Path | None = None
    staging: Path | None = None


def restore_backup(state: PublishState, debug_root: Path) -> None:
    # Only an emptied destination takes the previous profile back; one that holds the
    # published profile already, or anything else, is left alone.
    if state.backup is not None and os.path.lexists(state.backup) and not os.path.lexists(debug_root):
        try:
            os.rename(state.backup, debug_root)
        except OSError:
            pass


def publish(staging: Path, locations: Locations, replace: bool, state: PublishState) -> None:
    """Renames staging into place; an existing profile is moved aside, never deleted."""
    debug_root = locations.debug_root
    state.started = True
    occupied = destination_state(debug_root) == "occupied"
    if occupied and not replace:
        raise SeedError(f"{debug_root} gained data during the seed; nothing was published.")
    try:
        if occupied:
            state.backup = backup_path(debug_root)
            os.rename(debug_root, state.backup)
        os.rename(staging, debug_root)
    except BaseException:
        restore_backup(state, debug_root)
        raise


def describe_outcome(state: PublishState, locations: Locations) -> str:
    backup_present = state.backup is not None and os.path.lexists(state.backup)
    if state.published:
        moved = f" The previous debug profile is at {state.backup}." if backup_present else ""
        return f"The seeded profile was published to {locations.debug_root}.{moved}"
    if backup_present and not os.path.lexists(locations.debug_root):
        return (
            f"The previous debug profile could not be moved back and is at {state.backup}; "
            f"rename it to {locations.debug_root} to restore it."
        )
    return "Nothing was published; the debug profile is unchanged."


# -- report -------------------------------------------------------------------------------


def describe_age(epoch: float) -> str:
    days = max(0.0, time.time() - epoch) / 86400
    return "less than a day old" if days < 1 else f"{int(days)} day{'s' if int(days) != 1 else ''} old"


def print_report(
    archive: Archive,
    journal_version: int,
    supported: int,
    workspaces: WorkspacePlan,
    stats: CopyStats,
    excluded: Counter[tuple[str, str]],
    locations: Locations,
    *,
    dry_run: bool,
    replace_pending: bool,
    backup: Path | None,
) -> None:
    archived_at = archive.manifest.get("archivedAtISO")
    print("\nSeed report" + (" (dry run; nothing was written)" if dry_run else ""))
    print(f"  Archive: {archive.tag} at {archive.directory}")
    print(f"  Archived: {archived_at if isinstance(archived_at, str) else archive.archived_at_epoch} ({describe_age(archive.archived_at_epoch)})")
    print(f"  Working-journal schema: archive {journal_version}, debug build supports {supported}")
    print(f"  Destination: {locations.debug_root}")
    if dry_run and replace_pending:
        print("  The existing debug profile would be moved to a timestamped sibling.")
    if backup is not None:
        print(f"  Previous debug profile moved to: {backup}")
    verb = "Would copy" if dry_run else "Copied"
    print(f"  {verb} {len(workspaces.copied)} workspace(s):")
    for workspace in sorted(workspaces.copied, key=lambda item: item.name.casefold()):
        print(f"    {workspace.name}")
    if workspaces.skipped:
        print(f"  Skipped {len(workspaces.skipped)} workspace(s):")
        for workspace in sorted(workspaces.skipped, key=lambda item: item.name.casefold()):
            print(f"    {workspace.name}: {workspace.skip_reason}")
    if workspaces.unselected:
        print(f"  Not selected: {workspaces.unselected} workspace(s)")
    if workspaces.unindexed_folders:
        print(f"  Left behind: {workspaces.unindexed_folders} workspace folder(s) that neither the index nor the catalog lists")
    print(f"  {verb} {stats.files} file(s), {stats.bytes} bytes")
    rewrite_verb = "Would rewrite" if dry_run else "Rewrote"
    print(f"  {rewrite_verb} {stats.rewritten_paths} path(s) in {stats.rewritten_files} file(s)")
    if stats.updated_journal_digests:
        digest_verb = "Would update" if dry_run else "Updated"
        print(f"  {digest_verb} the saved-document digest in {stats.updated_journal_digests} working journal(s)")
    if stats.updated_revision_digests:
        digest_verb = "Would update" if dry_run else "Updated"
        print(f"  {digest_verb} the saved-document digest in {stats.updated_revision_digests} revision record(s)")
    if stats.rewritten_working_documents:
        print(f"  {rewrite_verb} paths inside {stats.rewritten_working_documents} unsaved working document(s)")
    if stats.unparsed_json_files:
        print(f"  Copied {stats.unparsed_json_files} unreadable JSON file(s) unchanged; none names the production profile")
    print("  Excluded:")
    by_category: dict[str, Counter[str]] = {}
    for (category, display), count in excluded.items():
        by_category.setdefault(category, Counter())[display] += count
    for category in EXCLUDED_CATEGORY_ORDER:
        names = by_category.get(category)
        if not names:
            continue
        shown = sorted(names)[:MAX_REPORTED_NAMES]
        more = len(names) - len(shown)
        listing = ", ".join(shown) + (f", and {more} more" if more else "")
        total = sum(names.values())
        print(f"    {category} ({total} {'entry' if total == 1 else 'entries'}): {listing}")


# -- entry point --------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Seed the debug profile one way from a verified production release archive. "
            f"The destination is ~/Library/Application Support/{DEBUG_PROFILE_NAME}; the production "
            "profile is never read or written."
        )
    )
    parser.add_argument(
        "--archive",
        metavar="TAG_OR_PATH",
        help=(
            f"Archive tag under ~/{ARCHIVE_ROOT_RELATIVE}, such as local/v1.4.0-b45, or an absolute "
            "archive directory. Default: the newest complete archive by manifest timestamp."
        ),
    )
    parser.add_argument(
        "--workspace",
        metavar="NAME",
        action="append",
        default=[],
        help="Copy only the archived workspace with this name; repeat for more. Default: every workspace.",
    )
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Move an existing debug profile to a timestamped sibling before publishing. It is never deleted.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Run every check and report what would be copied and rewritten.")
    return parser.parse_args(argv)


def seed(
    args: argparse.Namespace,
    inspector: debug_app_process.ProcessInspector | None,
    locations: Locations,
    publishing: PublishState,
) -> int:
    require_unreserved_names(args.workspace)
    environ = os.environ

    step("Resolving the release archive")
    archive = resolve_archive(args.archive, locations.archive_root)
    print(f"Archive {archive.tag} at {archive.directory}")

    step("Checking the working-journal format")
    supported = supported_journal_schema_version(debug_bundle_path(locations, environ))
    journal_version = check_journal_schema(archive, supported)
    print(f"Archive schema {journal_version}; debug build supports {supported}")

    step("Checking the debug app and the destination")
    require_debug_app_stopped(locations, environ, inspector)
    sources = list(dict.fromkeys([archive.source_root, str(locations.production_root)]))
    require_outside_production(sources, locations)
    occupied = destination_state(locations.debug_root) == "occupied"
    if occupied and not args.replace:
        raise SeedError(
            f"{locations.debug_root} already holds data. Rerun with --replace to move it to a timestamped "
            "sibling first; nothing is deleted."
        )
    print(
        "No debug app is running; the destination is "
        + ("occupied and will be moved aside" if occupied else "absent or empty")
    )

    step("Verifying archive checksums")
    print(f"Verified {verify_checksums(archive)} archive files")

    step("Surveying the archived state")
    survey = survey_archive(archive)
    workspaces = plan_workspaces(survey, archive.source_root, args.workspace)
    plan = CopyPlan(workspaces.ids, workspaces.folders)
    refuse_copied_links(survey.links, plan)
    refuse_colliding_members(survey.collisions, plan)
    paths = ProfilePathMap(sources, str(locations.debug_root))

    try:
        staging = None if args.dry_run else make_staging(locations, publishing)
        step("Copying and rewriting" + (" (dry run)" if args.dry_run else f" into {staging}"))
        stats = copy_state(archive, plan, paths, staging)
        if staging is not None:
            step(f"Publishing {locations.debug_root}")
            require_debug_app_stopped(locations, environ, inspector)
            publish(staging, locations, args.replace, publishing)
    finally:
        # The rename that publishes is the only thing that removes staging before this
        # point, so a missing staging directory means the profile was published.
        if publishing.staging is not None:
            if os.path.lexists(publishing.staging):
                remove_staging(publishing.staging, locations)
            else:
                publishing.published = True

    print_report(
        archive,
        journal_version,
        supported,
        workspaces,
        stats,
        survey.excluded,
        locations,
        dry_run=args.dry_run,
        replace_pending=occupied,
        backup=publishing.backup if publishing.published else None,
    )
    return 0


class Terminated(BaseException):
    """SIGTERM or SIGHUP, raised so the restore and cleanup paths run as for an interrupt."""

    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def raise_terminated(signum: int, _frame: object) -> None:
    raise Terminated(signum)


def main(argv: list[str] | None = None, *, inspector: debug_app_process.ProcessInspector | None = None) -> int:
    previous_handlers = {signum: signal.signal(signum, raise_terminated) for signum in (signal.SIGTERM, signal.SIGHUP)}
    try:
        args = parse_args(sys.argv[1:] if argv is None else argv)
        locations = Locations(Path.home())
        publishing = PublishState()
        try:
            return seed(args, inspector, locations, publishing)
        except (SeedError, OSError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            if publishing.started:
                print(describe_outcome(publishing, locations), file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print(f"Interrupted. {describe_outcome(publishing, locations)}", file=sys.stderr)
            return 130
        except Terminated as stop:
            print(f"Stopped by {signal.Signals(stop.signum).name}. {describe_outcome(publishing, locations)}", file=sys.stderr)
            return 128 + stop.signum
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, signal.SIG_DFL if handler is None else handler)


if __name__ == "__main__":
    raise SystemExit(main())
