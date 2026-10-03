#!/usr/bin/env python3
"""Hermetic tests for the one-way debug profile seed.

Every case builds a small release archive, a fake production profile, and a fake debug
bundle inside a temporary home, points HOME at it, and injects the process table. The real
home, the real archives, both real profiles, and the live process list are never touched.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import json
import os
import plistlib
import signal
import sys
import tarfile
import time
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import quote

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import seed_debug_profile as seed  # noqa: E402
from script_test_support import directory_snapshot, enter_context, temporary_directory  # noqa: E402

TAG = "local/v1.4.0-b99"
# The archived profile path recorded in the manifest. It never exists on disk, so a rewrite
# that keyed off the current HOME instead of the manifest would be caught.
SOURCE_ROOT = "/Users/archived-user/Library/Application Support/RepoPrompt CE"
SOURCE_URL = "file:///Users/archived-user/Library/Application%20Support/RepoPrompt%20CE"
ALPHA = "A1A1A1A1-0000-4000-8000-000000000001"
BETA = "B2B2B2B2-0000-4000-8000-000000000002"
CUSTOM = "C3C3C3C3-0000-4000-8000-000000000003"
ORPHAN = "D4D4D4D4-0000-4000-8000-000000000004"
SMOKE = "E5E5E5E5-0000-4000-8000-000000000005"
ALPHA_FOLDER = f"Workspaces/Workspace-alpha-{ALPHA}"
BETA_FOLDER = f"Workspaces/Workspace-beta-{BETA}"
RUNTIME = f"DomainRuntime/v1/{seed.RUNTIME_ROOT_NAME}"
# Foundation-style output: spacing and escaped slashes that a re-encode would not reproduce.
ALPHA_DOCUMENT = (
    b'{\n  "id" : "' + ALPHA.encode() + b'",\n  "name" : "alpha",\n'
    b'  "roots" : [\n    "\\/Users\\/archived-user\\/src\\/alpha"\n  ]\n}\n'
)
EXPECTED_FILES = {
    "Workspaces/workspacesIndex.json",
    f"{ALPHA_FOLDER}/workspace.json",
    f"{ALPHA_FOLDER}/Chats/ChatSession-1.json",
    f"{ALPHA_FOLDER}/AgentSessions/AgentSession-1.json",
    f"{ALPHA_FOLDER}/AgentSessions/AgentSessionIndex.json",
    f"{BETA_FOLDER}/workspace.json",
    f"{BETA_FOLDER}/Chats/ChatSession-2.json",
    f"{RUNTIME}/workspace-catalog.json",
    f"{RUNTIME}/working-journals/{ALPHA}.json",
    f"{RUNTIME}/working-journals/{BETA}.json",
    f"{RUNTIME}/revisions/{ALPHA}.json",
    "Presets/workflowPresets.json",
    "Presets/modelPresets.json",
    "Settings/globalSettings.json",
}


def json_bytes(value: object) -> bytes:
    return json.dumps(value).encode("utf-8")


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def default_state() -> dict[str, object]:
    """Archive-relative path to file bytes, None for a directory, or a (kind, target) special."""
    return {
        "Workspaces/workspacesIndex.json": json_bytes(
            [
                {"id": ALPHA, "name": "alpha", "customStoragePath": None, "isSystemWorkspace": False},
                {"id": BETA, "name": "beta", "customStoragePath": None, "isSystemWorkspace": False},
                {"id": CUSTOM, "name": "custom", "customStoragePath": "file:///Volumes/Elsewhere/custom/"},
                {"id": SMOKE, "name": "repoprompt-ce", "customStoragePath": None},
            ]
        ),
        f"{ALPHA_FOLDER}/workspace.json": ALPHA_DOCUMENT,
        f"{ALPHA_FOLDER}/Chats/ChatSession-1.json": json_bytes(
            {
                "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/Chats/ChatSession-1.json",
                "messages": [{"text": f"see {SOURCE_ROOT}/Settings in text"}],
            }
        ),
        f"{ALPHA_FOLDER}/AgentSessions/AgentSession-1.json": json_bytes(
            {
                "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/AgentSessions/AgentSession-1.json",
                "codexRolloutPath": f"{SOURCE_ROOT}/Codex/Release/home/sessions/rollout-1.jsonl",
                "worktreeBindings": [{"logicalRootPath": "/Users/archived-user/src/alpha"}],
                "items": [{"text": f"The file is under {SOURCE_ROOT}/Workspaces."}],
                f"{SOURCE_ROOT}/keyed": 1,
            }
        ),
        f"{ALPHA_FOLDER}/AgentSessions/AgentSessionIndex.json": json_bytes({"records": []}),
        f"{ALPHA_FOLDER}/AgentSessions/AgentSessionIndex.json.sb-1a2b3c4d-AbCdEf": b"partial",
        f"{ALPHA_FOLDER}/AgentSessions/._AgentSessionIndex.json": b"appledouble",
        f"{ALPHA_FOLDER}/_git_data/repos/cache.json": json_bytes({}),
        f"Workspaces/._Workspace-alpha-{ALPHA}": b"appledouble",
        f"{BETA_FOLDER}/workspace.json": json_bytes({"id": BETA, "name": "beta"}),
        f"{BETA_FOLDER}/Chats/ChatSession-2.json": json_bytes(
            {"fileURL": f"{SOURCE_URL}/{BETA_FOLDER}/Chats/ChatSession-2.json"}
        ),
        f"Workspaces/Workspace-orphan-{ORPHAN}/workspace.json": json_bytes({"id": ORPHAN}),
        f"Workspaces/Workspace-repoprompt-ce-{SMOKE}/workspace.json": json_bytes({"id": SMOKE}),
        f"{RUNTIME}/workspace-catalog.json": json_bytes(
            {
                "version": 1,
                "revision": 7,
                "entries": [
                    {"workspaceID": ALPHA, "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/workspace.json"},
                    {"workspaceID": BETA, "fileURL": f"{SOURCE_URL}/{BETA_FOLDER}/workspace.json"},
                    {"workspaceID": CUSTOM, "fileURL": "file:///Volumes/Elsewhere/custom/workspace.json"},
                    {
                        "workspaceID": SMOKE,
                        "fileURL": f"{SOURCE_URL}/Workspaces/Workspace-repoprompt-ce-{SMOKE}/workspace.json",
                    },
                ],
                "updatedAt": 812345678.5,
            }
        ),
        f"{RUNTIME}/working-journals/{ALPHA}.json": json_bytes(
            {"version": 1, "workspaceID": ALPHA, "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/workspace.json"}
        ),
        f"{RUNTIME}/working-journals/{BETA}.json": json_bytes(
            {"version": 1, "workspaceID": BETA, "fileURL": f"{SOURCE_URL}/{BETA_FOLDER}/workspace.json"}
        ),
        f"{RUNTIME}/working-journals/{CUSTOM}.json": json_bytes(
            {"version": 1, "workspaceID": CUSTOM, "fileURL": "file:///Volumes/Elsewhere/custom/workspace.json"}
        ),
        f"{RUNTIME}/revisions/{ALPHA}.json": json_bytes({"version": 1, "workspaceID": ALPHA, "savedRevision": 3}),
        f"{RUNTIME}/locks/workspace-{ALPHA}.lock": b"",
        f"{RUNTIME}/rollback/operation.json": json_bytes({}),
        f"{RUNTIME}/settings/runtime-policy.json": json_bytes({}),
        f"{RUNTIME}/settings/agent-sessions.json": json_bytes({"sessions": []}),
        f"{RUNTIME}/settings/direct-settings.json": json_bytes({}),
        "Presets/workflowPresets.json": json_bytes([{"name": "Plan"}]),
        "Presets/modelPresets.json": json_bytes([]),
        "Settings/globalSettings.json": json_bytes({"exportDirectory": f"{SOURCE_ROOT}/Exports", "theme": "dark"}),
        "Settings/globalSettings.json.lock": b"",
        "Codex/Release/home/auth.json": json_bytes({"token": "fixture-token"}),
        "Codex/Release/sqlite/state.sqlite": b"SQLite format 3",
        "MCP/mcp-routing.json": json_bytes({}),
        "MCPEvents-CE-7/terminal.json": json_bytes({}),
        "MCPKillSignals-CE-7": None,
        "Diagnostics/identity-transition-v1.json": json_bytes({}),
        "socket-proxy-debug.log": b"log",
        "windowSessions.json": json_bytes({}),
        "local-signing-identity-v1.json": json_bytes({"leaf": "fixture"}),
        "CodeMapArtifactRuntime-release/artifact": b"artifact",
        "repoprompt_ce_cli": ("symlink", "/Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp"),
    }


def write_state_archive(path: Path, state: dict[str, object], raw_members: tuple[str, ...] = ()) -> None:
    """Writes `./`-prefixed members, parents first, the way local_release_archive.sh does."""
    with tarfile.open(path, "w:gz") as archive:
        directories: set[str] = set()

        def add_directory(name: str) -> None:
            if name in directories:
                return
            if "/" in name:
                add_directory(name.rsplit("/", 1)[0])
            info = tarfile.TarInfo("./" + name)
            info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, 1_700_000_000
            archive.addfile(info)
            directories.add(name)

        for name, value in state.items():
            if "/" in name:
                add_directory(name.rsplit("/", 1)[0])
            if value is None:
                add_directory(name)
                continue
            info = tarfile.TarInfo("./" + name)
            info.mode, info.mtime = 0o644, 1_700_000_000
            if isinstance(value, tuple):
                kind, target = value
                info.type = {
                    "symlink": tarfile.SYMTYPE,
                    "hardlink": tarfile.LNKTYPE,
                    "fifo": tarfile.FIFOTYPE,
                    "chr": tarfile.CHRTYPE,
                }[kind]
                info.linkname = "./" + target if kind == "hardlink" else target
                archive.addfile(info)
            else:
                assert isinstance(value, bytes)
                info.size = len(value)
                archive.addfile(info, io.BytesIO(value))
        for name in raw_members:
            info = tarfile.TarInfo(name)
            info.size, info.mode = 5, 0o644
            archive.addfile(info, io.BytesIO(b"raw\n\n"))


def write_debug_bundle(bundle: Path, journal_version: object = 1) -> None:
    macos = bundle / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    info: dict[str, object] = {"CFBundleExecutable": "RepoPromptDebug", "RepoPromptSigningMode": "debug-adhoc"}
    if journal_version is not None:
        info[seed.JOURNAL_SCHEMA_KEY] = journal_version
    with (bundle / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump(info, handle)
    for name in ("RepoPromptDebug", "repoprompt-mcp"):
        (macos / name).write_text("binary", encoding="utf-8")
        (macos / name).chmod(0o755)


class FakeInspector:
    """A process table of pid -> (native name, executable path)."""

    def __init__(self, processes: dict[int, tuple[str, Path]] | None = None) -> None:
        self.processes = processes or {}

    def list_pids(self) -> list[int]:
        return list(self.processes)

    def process_name(self, pid: int) -> str | None:
        return self.processes[pid][0]

    def process_path(self, pid: int) -> Path:
        return self.processes[pid][1].resolve()


class SeedDebugProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = enter_context(self, temporary_directory(prefix="repoprompt-ce-seed-test."))
        self.home = self.tmp / "home"
        self.support = self.home / "Library" / "Application Support"
        self.production = self.support / "RepoPrompt CE"
        self.debug = self.support / "RepoPrompt CE Debug"
        self.archive_root = self.home / "Archives" / "repoprompt-ce"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("REPOPROMPT_DEBUG_APP_")}
        environment["HOME"] = str(self.home)
        enter_context(self, mock.patch.dict(os.environ, environment, clear=True))
        self.bundle = self.production / "DebugApps" / "RepoPrompt.app"
        write_debug_bundle(self.bundle)
        (self.production / "Workspaces").mkdir(parents=True)
        (self.production / "Workspaces" / "live-production.json").write_text('{"live": true}\n', encoding="utf-8")
        self.debug_url = "file://" + quote(str(self.debug), safe=seed.URL_PATH_SAFE)

    # -- fixtures ---------------------------------------------------------------------------

    def write_archive(
        self,
        tag: str = TAG,
        *,
        directory: Path | None = None,
        state: dict[str, object] | None = None,
        raw_members: tuple[str, ...] = (),
        epoch: float = 1_790_000_000.0,
        manifest: dict[str, object] | None = None,
    ) -> Path:
        archive = directory or self.archive_root / tag
        archive.mkdir(parents=True)
        write_state_archive(archive / seed.STATE_ARCHIVE_NAME, default_state() if state is None else state, raw_members)
        (archive / "app.zip").write_bytes(b"app bundle")
        (archive / "defaults.plist").write_bytes(b"preferences")
        (archive / "local-signing-identity-v1.json").write_bytes(b'{"record": "fixture"}')
        files: dict[str, object] = {}
        for name in ("app.zip", seed.STATE_ARCHIVE_NAME, "defaults.plist", "local-signing-identity-v1.json"):
            digest = hashlib.sha256((archive / name).read_bytes()).hexdigest()
            (archive / f"{name}.sha256").write_text(f"{digest}  {name}\n", encoding="utf-8")
            files[name] = {"sha256": digest, "bytes": (archive / name).stat().st_size}
        payload: dict[str, object] = {
            "schemaVersion": 1,
            "tag": tag,
            "working_journal_schema_version": 1,
            "working_journal_schema_version_status": "from_bundle",
            "observed_working_journal_versions": [1],
            "unreadable_working_journals": [],
            "archivedAtEpoch": epoch,
            "archivedAtISO": "2026-09-27T10:00:00+08:00",
            "applicationSupport": {"sourcePath": SOURCE_ROOT, "excludedNames": ["DebugApps", "Rollbacks", "Conductor"]},
            "files": files,
        }
        payload.update(manifest or {})
        (archive / seed.MANIFEST_NAME).write_text(json.dumps(payload), encoding="utf-8")
        return archive

    def run_seed(self, *args: str, inspector: FakeInspector | None = None) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = seed.main(list(args), inspector=inspector or FakeInspector())
        return code, stdout.getvalue(), stderr.getvalue()

    def seeded_files(self) -> set[str]:
        return {str(path.relative_to(self.debug)) for path in self.debug.rglob("*") if path.is_file() or path.is_symlink()}

    def seeded_json(self, relative: str) -> object:
        return json.loads((self.debug / relative).read_text(encoding="utf-8"))

    def assert_refused(self, code: int, stderr: str, expected: str) -> None:
        self.assertEqual(code, 1, stderr)
        self.assertIn(expected, stderr)

    def assert_left_no_trace(self) -> None:
        staging = [path.name for path in self.support.iterdir() if path.name.startswith(".RepoPrompt CE Debug.seed-staging-")]
        self.assertEqual(staging, [])

    def production_snapshot(self) -> dict[str, bytes | str | None]:
        return directory_snapshot(self.production)

    def debug_backups(self) -> list[Path]:
        return [path for path in self.support.iterdir() if path.name.startswith("RepoPrompt CE Debug.before-seed-")]

    # -- tests ------------------------------------------------------------------------------

    def test_seeds_allowlisted_state_and_rewrites_production_paths(self) -> None:
        self.write_archive()
        production_before = self.production_snapshot()

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.seeded_files(), EXPECTED_FILES)
        chat = self.seeded_json(f"{ALPHA_FOLDER}/Chats/ChatSession-1.json")
        self.assertEqual(chat["fileURL"], f"{self.debug_url}/{ALPHA_FOLDER}/Chats/ChatSession-1.json")
        self.assertEqual(chat["messages"][0]["text"], f"see {SOURCE_ROOT}/Settings in text")
        session = self.seeded_json(f"{ALPHA_FOLDER}/AgentSessions/AgentSession-1.json")
        self.assertEqual(session["codexRolloutPath"], f"{self.debug}/Codex/Release/home/sessions/rollout-1.jsonl")
        self.assertIn(f"{self.debug}/keyed", session)
        self.assertEqual(session["worktreeBindings"][0]["logicalRootPath"], "/Users/archived-user/src/alpha")
        self.assertEqual(session["items"][0]["text"], f"The file is under {SOURCE_ROOT}/Workspaces.")
        self.assertEqual(self.seeded_json("Settings/globalSettings.json")["exportDirectory"], f"{self.debug}/Exports")
        # A document without production paths keeps its exact bytes, so the journal's
        # recorded digest of it still matches.
        self.assertEqual((self.debug / ALPHA_FOLDER / "workspace.json").read_bytes(), ALPHA_DOCUMENT)
        self.assertEqual([entry["id"] for entry in self.seeded_json("Workspaces/workspacesIndex.json")], [ALPHA, BETA])
        catalog = self.seeded_json(f"{RUNTIME}/workspace-catalog.json")
        self.assertEqual(catalog["revision"], 7)
        self.assertEqual(
            [(entry["workspaceID"], entry["fileURL"]) for entry in catalog["entries"]],
            [
                (ALPHA, f"{self.debug_url}/{ALPHA_FOLDER}/workspace.json"),
                (BETA, f"{self.debug_url}/{BETA_FOLDER}/workspace.json"),
            ],
        )
        journal = self.seeded_json(f"{RUNTIME}/working-journals/{ALPHA}.json")
        self.assertEqual(journal["fileURL"], f"{self.debug_url}/{ALPHA_FOLDER}/workspace.json")
        self.assertIn(f"Archive: {TAG}", stdout)
        self.assertIn("Archived: 2026-09-27T10:00:00+08:00", stdout)
        self.assertIn("Rewrote 10 path(s) in 7 file(s)", stdout)
        self.assertIn("Copied 2 workspace(s):\n    alpha\n    beta", stdout)
        self.assertEqual(self.production_snapshot(), production_before)
        self.assert_left_no_trace()

    def test_excluded_categories_are_absent_and_reported(self) -> None:
        self.write_archive()

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        for absent in (
            "Codex",
            "MCP",
            "MCPEvents-CE-7",
            "MCPKillSignals-CE-7",
            "Diagnostics",
            "socket-proxy-debug.log",
            "windowSessions.json",
            "local-signing-identity-v1.json",
            "CodeMapArtifactRuntime-release",
            "repoprompt_ce_cli",
            "Settings/globalSettings.json.lock",
            f"{RUNTIME}/locks",
            f"{RUNTIME}/rollback",
            f"{RUNTIME}/settings/runtime-policy.json",
            f"{RUNTIME}/settings/agent-sessions.json",
            f"{RUNTIME}/settings/direct-settings.json",
            f"{ALPHA_FOLDER}/_git_data",
            f"{ALPHA_FOLDER}/AgentSessions/AgentSessionIndex.json.sb-1a2b3c4d-AbCdEf",
            f"{ALPHA_FOLDER}/AgentSessions/._AgentSessionIndex.json",
            f"Workspaces/._Workspace-alpha-{ALPHA}",
        ):
            with self.subTest(absent=absent):
                self.assertFalse(os.path.lexists(self.debug / absent))
        for category in (
            seed.CODEX,
            seed.MCP_ROUTING,
            seed.POLICY,
            seed.RUN_OWNERSHIP,
            seed.EVENTS,
            seed.LOCKS,
            seed.DIAGNOSTICS,
            seed.TEMPORARY,
            seed.APPLE_DOUBLE,
            seed.OTHER,
        ):
            with self.subTest(category=category):
                self.assertIn(f"    {category} (", stdout)

    def test_custom_storage_reserved_and_unindexed_workspaces_are_skipped_and_reported(self) -> None:
        self.write_archive()

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        self.assertIn("custom: custom storage outside the archived profile", stdout)
        self.assertIn("repoprompt-ce: reserved for the smoke workspace", stdout)
        self.assertIn("Left behind: 1 workspace folder(s)", stdout)
        seeded = "\n".join(self.seeded_files())
        for skipped in (CUSTOM, SMOKE, ORPHAN):
            with self.subTest(skipped=skipped):
                self.assertNotIn(skipped, seeded)

    def test_workspace_selection_copies_only_the_named_workspace(self) -> None:
        self.write_archive()

        code, stdout, stderr = self.run_seed("--workspace", "beta")

        self.assertEqual(code, 0, stderr)
        self.assertEqual(
            {path for path in self.seeded_files() if ALPHA in path or BETA in path},
            {f"{BETA_FOLDER}/workspace.json", f"{BETA_FOLDER}/Chats/ChatSession-2.json", f"{RUNTIME}/working-journals/{BETA}.json"},
        )
        self.assertEqual([entry["id"] for entry in self.seeded_json("Workspaces/workspacesIndex.json")], [BETA])
        self.assertEqual(
            [entry["workspaceID"] for entry in self.seeded_json(f"{RUNTIME}/workspace-catalog.json")["entries"]], [BETA]
        )
        self.assertIn("Not selected: 3 workspace(s)", stdout)

    def test_index_only_workspace_without_a_name_uses_its_folder_name(self) -> None:
        state = default_state()
        state["Workspaces/workspacesIndex.json"] = json_bytes([{"id": ALPHA, "customStoragePath": None}])
        state[f"{RUNTIME}/workspace-catalog.json"] = json_bytes({"version": 1, "entries": []})
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed("--workspace", "alpha")

        self.assertEqual(code, 0, stderr)
        self.assertIn("Copied 1 workspace(s):\n    alpha", stdout)
        self.assertTrue((self.debug / ALPHA_FOLDER / "workspace.json").is_file())

    def test_explicit_reserved_workspace_refuses_before_anything_is_staged(self) -> None:
        self.write_archive()
        self.debug.mkdir(parents=True)
        (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")
        before = directory_snapshot(self.support)
        for arguments in (
            ("--workspace", "repoprompt-ce"),
            ("--workspace", "RepoPrompt-CE", "--replace"),
            ("--workspace", "beta", "--workspace", "REPOPROMPT-CE", "--dry-run"),
        ):
            with self.subTest(arguments=arguments):
                code, stdout, stderr = self.run_seed(*arguments)

                self.assert_refused(code, stderr, "is reserved for the smoke workspace")
                self.assertIn("Nothing was changed", stderr)
                # The refusal comes before the archive is resolved, so no step ran.
                self.assertNotIn("==>", stdout)
                self.assert_left_no_trace()
                self.assertEqual(directory_snapshot(self.support), before)

    def test_unknown_workspace_name_refuses(self) -> None:
        self.write_archive()

        code, _stdout, stderr = self.run_seed("--workspace", "gamma")

        self.assert_refused(code, stderr, "No workspace named 'gamma'")
        self.assertFalse(self.debug.exists())

    def test_unrewritable_production_path_aborts_without_changing_the_destination(self) -> None:
        production_before = self.production_snapshot()
        escapes = {
            # Reads as the debug profile but resolves into production.
            "dot-dot": (
                f"{RUNTIME}/workspace-catalog.json",
                {
                    "version": 1,
                    "entries": [
                        {
                            "workspaceID": ALPHA,
                            "fileURL": "file:///Users/archived-user/Library/Application%20Support/RepoPrompt%20CE%20Debug/"
                            f"../RepoPrompt%20CE/{ALPHA_FOLDER}/workspace.json",
                        }
                    ],
                },
            ),
            # APFS matches names case-insensitively, so this still reaches production.
            "case": (
                f"{ALPHA_FOLDER}/Chats/ChatSession-1.json",
                {"fileURL": "/users/archived-user/library/application support/repoprompt ce/Workspaces/x.json"},
            ),
        }
        for label, (relative, document) in escapes.items():
            with self.subTest(label=label):
                state = default_state()
                state[relative] = json_bytes(document)
                archive = self.write_archive(f"local/escape-{label}", state=state)

                code, _stdout, stderr = self.run_seed("--archive", str(archive))

                self.assert_refused(code, stderr, "still names the production profile after rewriting")
                self.assertFalse(os.path.lexists(self.debug))
                self.assert_left_no_trace()
                self.assertEqual(self.production_snapshot(), production_before)

    def test_journal_schema_gate(self) -> None:
        refusals = {
            "newer archive": ({"working_journal_schema_version": 2}, 1, "newer than the 1 the debug build supports"),
            "newer observed journals": ({"observed_working_journal_versions": [1, 2]}, 1, "contains working journals at version 2"),
            "unknown archive version": (
                {"working_journal_schema_version": None, "working_journal_schema_version_status": "unknown"},
                1,
                "records no working-journal schema version",
            ),
            "debug bundle without the key": ({}, None, "declares no integer RepoPromptWorkingJournalSchemaVersion"),
        }
        for label, (manifest, supported, expected) in refusals.items():
            with self.subTest(label=label):
                write_debug_bundle(self.bundle, journal_version=supported)
                archive = self.write_archive(f"local/gate-{label.replace(' ', '-')}", manifest=manifest)

                code, _stdout, stderr = self.run_seed("--archive", str(archive))

                self.assert_refused(code, stderr, expected)
                self.assertFalse(os.path.lexists(self.debug))

        with self.subTest(label="debug bundle missing"):
            os.environ["REPOPROMPT_DEBUG_APP_BUNDLE"] = str(self.tmp / "missing" / "RepoPrompt.app")
            archive = self.write_archive("local/gate-missing-bundle")
            code, _stdout, stderr = self.run_seed("--archive", str(archive))
            del os.environ["REPOPROMPT_DEBUG_APP_BUNDLE"]
            self.assert_refused(code, stderr, "No debug app bundle at")

        with self.subTest(label="older archive"):
            write_debug_bundle(self.bundle, journal_version=2)
            archive = self.write_archive("local/gate-older")

            code, stdout, stderr = self.run_seed("--archive", str(archive))

            self.assertEqual(code, 0, stderr)
            self.assertIn("Working-journal schema: archive 1, debug build supports 2", stdout)

    def test_non_empty_destination_is_refused_and_an_empty_one_is_used(self) -> None:
        self.write_archive()
        self.debug.mkdir(parents=True)
        (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")
        before = directory_snapshot(self.debug)

        code, _stdout, stderr = self.run_seed()

        self.assert_refused(code, stderr, "already holds data. Rerun with --replace")
        self.assertEqual(directory_snapshot(self.debug), before)

        (self.debug / "marker.txt").unlink()
        code, _stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.seeded_files(), EXPECTED_FILES)

    def test_replace_moves_the_existing_profile_aside(self) -> None:
        self.write_archive()
        self.debug.mkdir(parents=True)
        (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")

        code, stdout, stderr = self.run_seed("--replace")

        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.seeded_files(), EXPECTED_FILES)
        backups = self.debug_backups()
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "marker.txt").read_text(encoding="utf-8"), "existing debug state\n")
        self.assertIn(f"Previous debug profile moved to: {backups[0]}", stdout)

    def test_missing_manifest_or_checksum_mismatch_refuses(self) -> None:
        def remove_manifest(archive: Path) -> None:
            (archive / seed.MANIFEST_NAME).unlink()

        def corrupt_sidecar(archive: Path) -> None:
            (archive / "defaults.plist.sha256").write_text(f"{'0' * 64}  defaults.plist\n", encoding="utf-8")

        def remove_sidecar(archive: Path) -> None:
            (archive / "app.zip.sha256").unlink()

        def tamper_state(archive: Path) -> None:
            data = bytearray((archive / seed.STATE_ARCHIVE_NAME).read_bytes())
            data[-10] ^= 0xFF
            (archive / seed.STATE_ARCHIVE_NAME).write_bytes(bytes(data))

        def alter_manifest_checksum(archive: Path) -> None:
            manifest = json.loads((archive / seed.MANIFEST_NAME).read_text(encoding="utf-8"))
            manifest["files"]["local-signing-identity-v1.json"]["sha256"] = "f" * 64
            (archive / seed.MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")

        cases = {
            "missing manifest": (remove_manifest, "manifest.json is written last and is missing"),
            "sidecar mismatch": (corrupt_sidecar, "Checksum mismatch for defaults.plist"),
            "missing sidecar": (remove_sidecar, "Missing checksum sidecar for app.zip"),
            "tampered state archive": (tamper_state, f"Checksum mismatch for {seed.STATE_ARCHIVE_NAME}"),
            "manifest checksum mismatch": (alter_manifest_checksum, "Checksum mismatch for local-signing-identity-v1.json"),
        }
        for label, (damage, expected) in cases.items():
            with self.subTest(label=label):
                archive = self.write_archive(f"local/damaged-{label.replace(' ', '-')}")
                damage(archive)

                code, _stdout, stderr = self.run_seed("--archive", str(archive))

                self.assert_refused(code, stderr, expected)
                self.assertFalse(os.path.lexists(self.debug))
                self.assert_left_no_trace()

    def test_running_debug_app_or_helper_refuses_but_production_does_not(self) -> None:
        self.write_archive()
        blockers = {
            "debug app": FakeInspector({101: ("RepoPromptDebug", self.bundle / "Contents" / "MacOS" / "RepoPromptDebug")}),
            "debug CLI through its link": FakeInspector(
                {102: ("rpce-cli-debug", self.bundle / "Contents" / "MacOS" / "repoprompt-mcp")}
            ),
            "worktree debug app": FakeInspector(
                {103: ("RepoPromptDebug", self.production / "DebugApps-wt1" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPromptDebug")}
            ),
        }
        for label, inspector in blockers.items():
            with self.subTest(label=label):
                code, _stdout, stderr = self.run_seed(inspector=inspector)

                self.assert_refused(code, stderr, "Quit the debug app and any attached debug CLI first")
                self.assertFalse(os.path.lexists(self.debug))

        production_app = self.tmp / "Applications" / "RepoPrompt CE.app" / "Contents" / "MacOS"
        code, _stdout, stderr = self.run_seed(
            inspector=FakeInspector(
                {
                    201: ("RepoPrompt", production_app / "RepoPrompt"),
                    202: ("rpce-cli", production_app / "repoprompt-mcp"),
                }
            )
        )

        self.assertEqual(code, 0, stderr)

    def test_unsafe_archive_members_refuse(self) -> None:
        production_before = self.production_snapshot()
        cases: dict[str, tuple[dict[str, object], tuple[str, ...], str]] = {
            "absolute name": ({}, ("/tmp/seed-escape.json",), "absolute member name"),
            "parent traversal": ({}, ("./Workspaces/../../seed-escape.json",), "unsafe member name"),
            "fifo": ({f"{ALPHA_FOLDER}/Chats/pipe": ("fifo", "")}, (), "device, FIFO, or other special file"),
            "device": ({f"{ALPHA_FOLDER}/Chats/device": ("chr", "")}, (), "device, FIFO, or other special file"),
        }
        for label, (extra, raw_members, expected) in cases.items():
            with self.subTest(label=label):
                state = default_state()
                state.update(extra)
                archive = self.write_archive(f"local/unsafe-{label.replace(' ', '-')}", state=state, raw_members=raw_members)

                code, _stdout, stderr = self.run_seed("--archive", str(archive), "--dry-run")
                self.assert_refused(code, stderr, expected)

                code, _stdout, stderr = self.run_seed("--archive", str(archive))

                self.assert_refused(code, stderr, expected)
                self.assertFalse(os.path.lexists(self.debug))
                self.assert_left_no_trace()
                self.assertFalse(os.path.lexists(self.support / "seed-escape.json"))
                self.assertEqual(self.production_snapshot(), production_before)

    def test_unreadable_json_is_copied_only_when_it_cannot_name_production(self) -> None:
        state = default_state()
        state[f"{ALPHA_FOLDER}/Chats/truncated.json"] = b'{"fileURL": "file:///tmp/x'
        archive = self.write_archive("local/unreadable-clean", state=state)

        code, stdout, stderr = self.run_seed("--archive", str(archive))

        self.assertEqual(code, 0, stderr)
        self.assertEqual((self.debug / ALPHA_FOLDER / "Chats" / "truncated.json").read_bytes(), b'{"fileURL": "file:///tmp/x')
        self.assertIn("Copied 1 unreadable JSON file(s) unchanged", stdout)

        state[f"{ALPHA_FOLDER}/Chats/truncated.json"] = f'{{"fileURL": "{SOURCE_URL}/Workspaces'.encode()
        archive = self.write_archive("local/unreadable-production", state=state)

        code, _stdout, stderr = self.run_seed("--archive", str(archive), "--replace")

        self.assert_refused(code, stderr, "is not readable JSON and mentions the production profile")
        self.assert_left_no_trace()

    def test_link_members_inside_copied_state_refuse_before_staging(self) -> None:
        production_before = self.production_snapshot()
        payload = f"{ALPHA_FOLDER}/Chats/payload"
        cases: dict[str, dict[str, object]] = {
            "contained symbolic link": {f"{ALPHA_FOLDER}/Chats/alias.json": ("symlink", "ChatSession-1.json")},
            "symbolic link out of the profile": {
                f"{ALPHA_FOLDER}/Chats/escape.json": ("symlink", "../../../../seed-escape.json")
            },
            "absolute symbolic link": {f"{ALPHA_FOLDER}/Chats/escape.json": ("symlink", "/etc/hosts")},
            "hard link to a copied member": {
                f"{ALPHA_FOLDER}/Chats/copy.json": ("hardlink", f"{ALPHA_FOLDER}/Chats/ChatSession-1.json")
            },
            "hard link to an uncopied member": {
                f"{ALPHA_FOLDER}/Chats/copy.json": ("hardlink", "Codex/Release/home/auth.json")
            },
            # A JSON name over an extensionless payload would skip rewriting and the scan.
            "hard-linked JSON over a payload naming production": {
                payload: json_bytes({"fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/workspace.json"}),
                f"{ALPHA_FOLDER}/Chats/linked.json": ("hardlink", payload),
            },
        }
        for label, extra in cases.items():
            with self.subTest(label=label):
                state = default_state()
                state.update(extra)
                archive = self.write_archive(f"local/links-{label.replace(' ', '-')}", state=state)
                for mode in (("--dry-run",), ()):
                    code, stdout, stderr = self.run_seed("--archive", str(archive), *mode)

                    self.assert_refused(code, stderr, "The seed copies no links; nothing was changed.")
                    self.assertNotIn("==> Copying", stdout)
                    self.assertFalse(os.path.lexists(self.debug))
                    self.assert_left_no_trace()
                self.assertFalse(os.path.lexists(self.support / "seed-escape.json"))
                self.assertEqual(self.production_snapshot(), production_before)

    def test_link_chain_and_case_variant_member_cannot_reach_production(self) -> None:
        (self.production / "Settings").mkdir()
        (self.production / "Settings" / "globalSettings.json").write_text('{"sentinel": true}\n', encoding="utf-8")
        production_before = self.production_snapshot()
        state = default_state()
        chats = f"{ALPHA_FOLDER}/Chats"
        # Lexically `y` stays inside the profile; physically `x` is `Chats` itself, so the
        # target climbs one level further, into the production profile beside staging.
        state[f"{chats}/x"] = ("symlink", ".")
        state[f"{chats}/y"] = ("symlink", "x/../../../../RepoPrompt CE")
        # APFS resolves `Y` to the `y` link, which an exact-case path check would not see.
        state[f"{chats}/Y/Settings/globalSettings.json"] = json_bytes({"overwritten": True})
        archive = self.write_archive("local/link-chain", state=state)

        for mode in (("--dry-run",), ()):
            code, stdout, stderr = self.run_seed("--archive", str(archive), *mode)

            self.assert_refused(code, stderr, "The seed copies no links; nothing was changed.")
            self.assertNotIn("==> Copying", stdout)
            self.assertFalse(os.path.lexists(self.debug))
            self.assert_left_no_trace()
            self.assertEqual(self.production_snapshot(), production_before)

    def test_copy_pass_refuses_a_link_member_on_its_own(self) -> None:
        state = default_state()
        state[f"{ALPHA_FOLDER}/Chats/alias.json"] = ("symlink", "ChatSession-1.json")
        archive = seed.load_archive(self.write_archive(state=state), expected_tag=None)
        plan = seed.CopyPlan(frozenset({ALPHA}), frozenset({ALPHA_FOLDER.split("/")[1]}))
        paths = seed.ProfilePathMap([SOURCE_ROOT], str(self.debug))

        with self.assertRaisesRegex(seed.SeedError, "the seed copies no links"):
            seed.copy_state(archive, plan, paths, staging=None)

    def test_staging_writer_never_writes_outside_staging(self) -> None:
        staging = self.tmp / "staging"
        outside = self.tmp / "outside"
        for directory in (staging, outside):
            directory.mkdir()
        (outside / "sentinel.json").write_text("sentinel\n", encoding="utf-8")
        (staging / "Workspaces").symlink_to(outside, target_is_directory=True)
        (staging / "Settings").mkdir()
        (staging / "Settings" / "globalSettings.json").symlink_to(outside / "sentinel.json")
        (staging / "Chats").mkdir()
        (staging / "Chats" / "y").symlink_to(outside, target_is_directory=True)
        outside_before = directory_snapshot(outside)
        writer = seed.StagingWriter(staging)
        attempts = {
            "file under a linked directory": lambda: writer.file(("Workspaces", "x.json"), b"{}", 0),
            "directory under a linked directory": lambda: writer.directory(("Workspaces", "new")),
            "file that is a link": lambda: writer.file(("Settings", "globalSettings.json"), b"{}", 0),
            "case variant of a linked directory": lambda: writer.file(("Chats", "Y", "f.json"), b"{}", 0),
        }
        case_insensitive = (staging / "CHATS").exists()
        for label, attempt in attempts.items():
            with self.subTest(label=label):
                if label.startswith("case variant") and not case_insensitive:
                    attempt()
                else:
                    with self.assertRaisesRegex(seed.SeedError, "Refusing to write"):
                        attempt()
                self.assertEqual(directory_snapshot(outside), outside_before)

    def test_interrupted_replace_restores_the_previous_profile(self) -> None:
        self.write_archive()
        original_rename = os.rename

        def rename(source, target, *, fail_restore: bool) -> None:
            name = Path(source).name
            if name.startswith(".RepoPrompt CE Debug.seed-staging-"):
                raise KeyboardInterrupt
            if fail_restore and name.startswith("RepoPrompt CE Debug.before-seed-"):
                raise OSError("simulated restore failure")
            original_rename(source, target)

        for fail_restore in (False, True):
            with self.subTest(fail_restore=fail_restore):
                self.debug.mkdir(parents=True, exist_ok=True)
                (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")

                with mock.patch.object(seed.os, "rename", lambda s, t: rename(s, t, fail_restore=fail_restore)):
                    code, _stdout, stderr = self.run_seed("--replace")

                self.assertEqual(code, 130)
                self.assert_left_no_trace()
                backups = self.debug_backups()
                if fail_restore:
                    self.assertFalse(os.path.lexists(self.debug))
                    self.assertEqual(len(backups), 1)
                    self.assertEqual((backups[0] / "marker.txt").read_text(encoding="utf-8"), "existing debug state\n")
                    self.assertIn(f"could not be moved back and is at {backups[0]}", stderr)
                    original_rename(backups[0], self.debug)
                else:
                    self.assertEqual(backups, [])
                    self.assertEqual((self.debug / "marker.txt").read_text(encoding="utf-8"), "existing debug state\n")
                    self.assertIn("Interrupted. Nothing was published; the debug profile is unchanged.", stderr)

    def test_interrupt_right_after_staging_is_created_removes_it(self) -> None:
        self.write_archive()
        create_staging = seed.make_staging

        def create_then_interrupt(*args):
            create_staging(*args)
            raise KeyboardInterrupt

        with mock.patch.object(seed, "make_staging", create_then_interrupt):
            code, _stdout, stderr = self.run_seed()

        self.assertEqual(code, 130)
        self.assertIn("Interrupted. Nothing was published; the debug profile is unchanged.", stderr)
        self.assert_left_no_trace()
        self.assertFalse(os.path.lexists(self.debug))

    def test_interrupt_after_publishing_reports_the_published_profile(self) -> None:
        self.write_archive()
        self.debug.mkdir(parents=True)
        (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")

        with mock.patch.object(seed, "print_report", side_effect=KeyboardInterrupt):
            code, _stdout, stderr = self.run_seed("--replace")

        self.assertEqual(code, 130)
        self.assertEqual(self.seeded_files(), EXPECTED_FILES)
        backups = self.debug_backups()
        self.assertEqual(len(backups), 1)
        self.assertIn(f"The seeded profile was published to {self.debug}.", stderr)
        self.assertIn(f"The previous debug profile is at {backups[0]}.", stderr)

    def test_rewritten_document_moves_its_journal_saved_digest(self) -> None:
        alpha_document = json_bytes({"id": ALPHA, "name": "alpha", "exportPath": f"{SOURCE_ROOT}/Exports/alpha"})
        beta_document = json_bytes({"id": BETA, "name": "beta", "exportPath": f"{SOURCE_ROOT}/Exports/beta"})
        working_document = base64.b64encode(json_bytes({"id": ALPHA, "name": "unsaved alpha"})).decode()
        pending_save = {"operationID": "F0F0F0F0-0000-4000-8000-000000000000", "documentDigest": sha256_hex(alpha_document)}
        alpha_journal = {
            "version": 1,
            "workspaceID": ALPHA,
            "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/workspace.json",
            "savedDigest": sha256_hex(alpha_document),
            "workingDocument": working_document,
            "pendingSave": pending_save,
            "contextDigests": {"C0C0C0C0-0000-4000-8000-000000000000": "c" * 64},
        }
        beta_journal = {
            "version": 1,
            "workspaceID": BETA,
            "fileURL": f"{SOURCE_URL}/{BETA_FOLDER}/workspace.json",
            "savedDigest": "0" * 64,
        }
        # Journals first, so the update cannot depend on documents preceding them.
        state: dict[str, object] = {
            f"{RUNTIME}/working-journals/{ALPHA}.json": json_bytes(alpha_journal),
            f"{RUNTIME}/working-journals/{BETA}.json": json_bytes(beta_journal),
        }
        state.update({key: value for key, value in default_state().items() if key not in state})
        state[f"{ALPHA_FOLDER}/workspace.json"] = alpha_document
        state[f"{BETA_FOLDER}/workspace.json"] = beta_document
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        written_alpha = (self.debug / ALPHA_FOLDER / "workspace.json").read_bytes()
        self.assertEqual(json.loads(written_alpha)["exportPath"], f"{self.debug}/Exports/alpha")
        journal = self.seeded_json(f"{RUNTIME}/working-journals/{ALPHA}.json")
        self.assertEqual(journal["savedDigest"], sha256_hex(written_alpha))
        self.assertEqual(journal["fileURL"], f"{self.debug_url}/{ALPHA_FOLDER}/workspace.json")
        self.assertEqual(journal["workingDocument"], working_document)
        self.assertEqual(journal["pendingSave"], pending_save)
        self.assertEqual(journal["contextDigests"], alpha_journal["contextDigests"])
        mismatched = self.seeded_json(f"{RUNTIME}/working-journals/{BETA}.json")
        self.assertEqual(mismatched["savedDigest"], "0" * 64)
        self.assertIn("Updated the saved-document digest in 1 working journal(s)", stdout)

    def test_rewritten_document_moves_its_revision_record_digest(self) -> None:
        alpha_document = json_bytes({"id": ALPHA, "name": "alpha", "exportPath": f"{SOURCE_ROOT}/Exports/alpha"})
        beta_document = json_bytes({"id": BETA, "name": "beta", "exportPath": f"{SOURCE_ROOT}/Exports/beta"})
        alpha_record = {
            "version": 1,
            "workspaceID": ALPHA,
            "savedRevision": 9,
            "documentDigest": sha256_hex(alpha_document),
            "operationID": "F1F1F1F1-0000-4000-8000-000000000000",
            "updatedAt": 812345678.25,
        }
        beta_record = {**alpha_record, "workspaceID": BETA, "documentDigest": "0" * 64}
        # Records first, so the update cannot depend on documents preceding them.
        state: dict[str, object] = {
            f"{RUNTIME}/revisions/{ALPHA}.json": json_bytes(alpha_record),
            f"{RUNTIME}/revisions/{BETA}.json": json_bytes(beta_record),
        }
        state.update({key: value for key, value in default_state().items() if key not in state})
        state[f"{ALPHA_FOLDER}/workspace.json"] = alpha_document
        state[f"{BETA_FOLDER}/workspace.json"] = beta_document
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        written_alpha = (self.debug / ALPHA_FOLDER / "workspace.json").read_bytes()
        self.assertNotEqual(written_alpha, alpha_document)
        self.assertEqual(
            self.seeded_json(f"{RUNTIME}/revisions/{ALPHA}.json"),
            {**alpha_record, "documentDigest": sha256_hex(written_alpha)},
        )
        self.assertEqual(self.seeded_json(f"{RUNTIME}/revisions/{BETA}.json"), beta_record)
        self.assertIn("Updated the saved-document digest in 1 revision record(s)", stdout)

    def test_destination_under_a_symlinked_ancestor_inside_production_refuses_before_staging(self) -> None:
        production = self.tmp / "real-home" / "Library" / "Application Support" / "RepoPrompt CE"
        (production / "Settings").mkdir(parents=True)
        (production / "Settings" / "globalSettings.json").write_text('{"sentinel": true}\n', encoding="utf-8")
        linked_home = self.tmp / "linked-home"
        (linked_home / "Library").mkdir(parents=True)
        (linked_home / "Library" / "Application Support").symlink_to(production, target_is_directory=True)
        os.environ["HOME"] = str(linked_home)
        os.environ["REPOPROMPT_DEBUG_APP_BUNDLE"] = str(self.bundle)
        archive = self.write_archive(
            directory=self.tmp / "archives" / "linked",
            manifest={"applicationSupport": {"sourcePath": str(production), "excludedNames": []}},
        )
        before = directory_snapshot(production)

        code, stdout, stderr = self.run_seed("--archive", str(archive), "--replace")

        self.assert_refused(code, stderr, "resolves into the production profile")
        self.assertNotIn("==> Verifying", stdout)
        self.assertEqual(directory_snapshot(production), before)

    def test_uppercase_json_extension_is_rewritten(self) -> None:
        state = default_state()
        state[f"{ALPHA_FOLDER}/Chats/ChatSession-3.JSON"] = json_bytes({"fileURL": f"{SOURCE_ROOT}/Exports/three"})
        self.write_archive(state=state)

        code, _stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.seeded_json(f"{ALPHA_FOLDER}/Chats/ChatSession-3.JSON")["fileURL"], f"{self.debug}/Exports/three")

    def test_members_that_collide_on_a_case_insensitive_file_system_refuse_before_staging(self) -> None:
        chats = f"{ALPHA_FOLDER}/Chats"
        cases = {
            ".json and .JSON": {f"{chats}/ChatSession-1.JSON": json_bytes({})},
            "letter case": {f"{chats}/notes.json": json_bytes({}), f"{chats}/NOTES.json": json_bytes({})},
            "Unicode normalization": {f"{chats}/café.json": json_bytes({}), f"{chats}/café.json": json_bytes({})},
        }
        for label, extra in cases.items():
            with self.subTest(label=label):
                state = default_state()
                state.update(extra)
                archive = self.write_archive(f"local/collide-{len(label)}", state=state)

                code, stdout, stderr = self.run_seed("--archive", str(archive))

                self.assert_refused(code, stderr, "name the same file on a case-insensitive file system")
                self.assertNotIn("==> Copying", stdout)
                self.assertFalse(os.path.lexists(self.debug))
                self.assert_left_no_trace()

    def journal_with_working_document(self, working: bytes, **fields: object) -> dict[str, object]:
        return {
            "version": 1,
            "workspaceID": ALPHA,
            "fileURL": f"{SOURCE_URL}/{ALPHA_FOLDER}/workspace.json",
            "savedDigest": sha256_hex(ALPHA_DOCUMENT),
            "workingDocument": base64.b64encode(working).decode(),
            **fields,
        }

    def seeded_working_document(self) -> bytes:
        journal = self.seeded_json(f"{RUNTIME}/working-journals/{ALPHA}.json")
        return base64.b64decode(journal["workingDocument"])

    def test_working_document_paths_are_rewritten_inside_the_decoded_document(self) -> None:
        working = json_bytes(
            {
                "id": ALPHA,
                "exportPath": f"{SOURCE_ROOT}/Exports/unsaved",
                "composeTabs": [{"id": "C0C0C0C0-0000-4000-8000-000000000000", "note": f"see {SOURCE_ROOT}/x"}],
                "repoPaths": ["/Users/archived-user/src/alpha"],
            }
        )
        pending_save = {"operationID": "F0F0F0F0-0000-4000-8000-000000000000", "documentDigest": sha256_hex(working)}
        state = default_state()
        state[f"{RUNTIME}/working-journals/{ALPHA}.json"] = json_bytes(
            self.journal_with_working_document(working, pendingSave=pending_save)
        )
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        seeded = json.loads(self.seeded_working_document())
        self.assertEqual(seeded["exportPath"], f"{self.debug}/Exports/unsaved")
        self.assertEqual(seeded["composeTabs"][0]["note"], f"see {SOURCE_ROOT}/x")
        self.assertEqual(seeded["repoPaths"], ["/Users/archived-user/src/alpha"])
        journal = self.seeded_json(f"{RUNTIME}/working-journals/{ALPHA}.json")
        self.assertEqual(journal["pendingSave"], pending_save)
        self.assertEqual(journal["savedDigest"], sha256_hex(ALPHA_DOCUMENT))
        self.assertIn("Rewrote paths inside 1 unsaved working document(s)", stdout)

    def test_saved_digest_that_named_the_working_document_follows_its_rewrite(self) -> None:
        working = json_bytes({"id": ALPHA, "exportPath": f"{SOURCE_ROOT}/Exports/unsaved"})
        state = default_state()
        state[f"{RUNTIME}/working-journals/{ALPHA}.json"] = json_bytes(
            self.journal_with_working_document(working, savedDigest=sha256_hex(working))
        )
        self.write_archive(state=state)

        code, _stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        journal = self.seeded_json(f"{RUNTIME}/working-journals/{ALPHA}.json")
        self.assertEqual(journal["savedDigest"], sha256_hex(self.seeded_working_document()))

    def test_working_document_without_production_paths_keeps_its_bytes(self) -> None:
        # Foundation-style spacing that a re-encode would not reproduce.
        working = b'{\n  "id" : "' + ALPHA.encode() + b'",\n  "repoPaths" : [\n    "\\/Users\\/archived-user\\/src"\n  ]\n}\n'
        state = default_state()
        state[f"{RUNTIME}/working-journals/{ALPHA}.json"] = json_bytes(self.journal_with_working_document(working))
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed()

        self.assertEqual(code, 0, stderr)
        self.assertEqual(self.seeded_working_document(), working)
        self.assertNotIn("unsaved working document", stdout)

    def test_working_document_that_still_names_production_refuses(self) -> None:
        working = json_bytes({"id": ALPHA, "exportPath": "/users/archived-user/library/application support/repoprompt ce/x"})
        state = default_state()
        state[f"{RUNTIME}/working-journals/{ALPHA}.json"] = json_bytes(self.journal_with_working_document(working))
        self.write_archive(state=state)

        code, _stdout, stderr = self.run_seed()

        self.assert_refused(code, stderr, f"{ALPHA}.json (decoded workingDocument) still names the production profile")
        self.assertIn("/exportPath: ", stderr)
        self.assertFalse(os.path.lexists(self.debug))
        self.assert_left_no_trace()

    def test_sigterm_during_replace_restores_the_previous_profile(self) -> None:
        self.write_archive()
        self.debug.mkdir(parents=True)
        (self.debug / "marker.txt").write_text("existing debug state\n", encoding="utf-8")
        original_rename = os.rename
        handler_before = signal.getsignal(signal.SIGTERM)

        def rename(source, target) -> None:
            if Path(source).name.startswith(".RepoPrompt CE Debug.seed-staging-"):
                os.kill(os.getpid(), signal.SIGTERM)
                # The handler raises at the next bytecode boundary; the sleep only bounds a
                # missing handler, which the default action would turn into process exit.
                time.sleep(5)
            original_rename(source, target)

        with mock.patch.object(seed.os, "rename", rename):
            code, _stdout, stderr = self.run_seed("--replace")

        self.assertEqual(code, 128 + signal.SIGTERM)
        self.assertIn("Stopped by SIGTERM. Nothing was published; the debug profile is unchanged.", stderr)
        self.assertEqual((self.debug / "marker.txt").read_text(encoding="utf-8"), "existing debug state\n")
        self.assertEqual(self.debug_backups(), [])
        self.assert_left_no_trace()
        self.assertEqual(signal.getsignal(signal.SIGTERM), handler_before)

    def test_refusal_names_locations_but_never_values(self) -> None:
        secrets = ("SECRET-TOKEN-1", "SECRET-TRANSCRIPT-2", "SECRET-KEY-3")
        state = default_state()
        state[f"{ALPHA_FOLDER}/Chats/ChatSession-1.json"] = json_bytes(
            {
                "fileURL": f"file://localhost{SOURCE_ROOT.replace(' ', '%20')}/x.json?token=SECRET-TOKEN-1",
                "messages": [{"text": "/users/archived-user/library/application support/repoprompt ce/notes\nSECRET-TRANSCRIPT-2"}],
                "/users/archived-user/library/application support/repoprompt ce/SECRET-KEY-3": 1,
            }
        )
        self.write_archive(state=state)

        code, stdout, stderr = self.run_seed()

        self.assert_refused(code, stderr, f"{ALPHA_FOLDER}/Chats/ChatSession-1.json still names the production profile")
        for location in ("/fileURL: ", "/messages/0/text: ", "/<key 2> (object key): "):
            self.assertIn(location, stderr)
        for secret in secrets:
            with self.subTest(secret=secret):
                self.assertNotIn(secret, stdout)
                self.assertNotIn(secret, stderr)

    def test_dry_run_reports_without_writing(self) -> None:
        self.write_archive()
        before = directory_snapshot(self.support)

        code, stdout, stderr = self.run_seed("--dry-run")

        self.assertEqual(code, 0, stderr)
        self.assertEqual(directory_snapshot(self.support), before)
        self.assertIn("dry run; nothing was written", stdout)
        self.assertIn("Would copy 2 workspace(s)", stdout)
        self.assertIn("Would rewrite 10 path(s) in 7 file(s)", stdout)

    def test_default_archive_is_the_newest_complete_one_by_manifest_timestamp(self) -> None:
        self.write_archive("local/v1.4.0-b98", epoch=1_790_500_000.0)
        self.write_archive("local/v1.4.0-b99", epoch=1_790_000_000.0)
        incomplete = self.write_archive("local/v1.4.0-b100", epoch=1_791_000_000.0)
        (incomplete / seed.MANIFEST_NAME).unlink()

        code, stdout, stderr = self.run_seed("--dry-run")

        self.assertEqual(code, 0, stderr)
        self.assertIn("Archive: local/v1.4.0-b98", stdout)

    def test_symlinked_destination_is_refused(self) -> None:
        self.write_archive()
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        self.debug.symlink_to(elsewhere, target_is_directory=True)
        production_before = self.production_snapshot()

        code, _stdout, stderr = self.run_seed("--replace")

        self.assert_refused(code, stderr, "is a symlink; the seed never writes through one")
        self.assertTrue(self.debug.is_symlink())
        self.assertEqual(self.production_snapshot(), production_before)


if __name__ == "__main__":
    unittest.main()
