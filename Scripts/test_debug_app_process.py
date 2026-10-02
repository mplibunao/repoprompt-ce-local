#!/usr/bin/env python3
"""Hermetic tests for RepoPrompt CE debug app process identity checks."""

from __future__ import annotations

import contextlib
import io
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402
import debug_app_process  # noqa: E402


def write_app_bundle(
    bundle: Path,
    declared: object = "RepoPromptDebug",
    *,
    marker: object = "debug-adhoc",
    leaves: tuple[str, ...] | None = None,
) -> Path:
    """Writes an app bundle whose Info.plist declares `declared` and holds executable `leaves`."""
    macos = bundle / "Contents" / "MacOS"
    macos.mkdir(parents=True, exist_ok=True)
    info: dict[str, object] = {"CFBundleExecutable": declared, "RepoPromptSigningMode": marker}
    with (bundle / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump({key: value for key, value in info.items() if value is not None}, handle)
    for leaf in leaves if leaves is not None else (str(declared),):
        (macos / leaf).write_text("binary", encoding="utf-8")
        (macos / leaf).chmod(0o755)
    return bundle


class FakeInspector:
    def __init__(
        self,
        names: dict[int, str],
        paths: dict[int, Path | list[Path | Exception] | Exception],
        *,
        exited: set[int] | None = None,
    ) -> None:
        self.names = dict(names)
        self.paths = paths
        # PIDs whose process has exited by the time its path is read, so its name lookup
        # fails afterwards the way libproc's does.
        self.exited = exited or set()

    def list_pids(self) -> list[int]:
        return list(self.names)

    def process_name(self, pid: int) -> str | None:
        return self.names.get(pid)

    def process_path(self, pid: int) -> Path:
        value = self.paths[pid]
        if pid in self.exited:
            self.names.pop(pid, None)
        if isinstance(value, Exception):
            raise value
        if isinstance(value, list):
            current = value.pop(0) if len(value) > 1 else value[0]
            if isinstance(current, Exception):
                raise current
            return current.resolve(strict=True)
        return value.resolve(strict=True)


class DebugAppProcessTests(unittest.TestCase):
    def make_executable(self, root: Path, relative_path: str) -> Path:
        executable = root / relative_path
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("binary", encoding="utf-8")
        executable.chmod(0o755)
        return executable.resolve(strict=True)

    def test_only_exact_debug_executable_is_included(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            production = self.make_executable(root, "Applications/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            ce_release = self.make_executable(root, "Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector(
                {101: "RepoPromptDebug", 102: "RepoPrompt", 103: "RepoPrompt", 104: "Other"},
                {101: debug, 102: production, 103: ce_release, 104: debug},
            )

            matches = debug_app_process.matching_processes(debug, inspector)

        self.assertEqual(matches, [101])

    def test_termination_revalidates_identity_and_rejects_pid_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            debug = self.make_executable(root, "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            production = self.make_executable(root, "Production/RepoPrompt.app/Contents/MacOS/RepoPrompt")
            inspector = FakeInspector({201: "RepoPromptDebug"}, {201: [debug, production]})
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "executable changed"):
                debug_app_process.terminate_matching_processes(
                    debug,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_matching_identity_is_revalidated_then_signaled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            inspector = FakeInspector({301: "RepoPromptDebug"}, {301: [debug, debug]})
            signals: list[tuple[int, int]] = []

            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(signaled, [301])
        self.assertEqual(signals, [(301, signal.SIGTERM)])

    def test_missing_target_is_normal_not_installed_state(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "DebugApps" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPromptDebug"
            unrelated = self.make_executable(Path(tmp), "Elsewhere/RepoPromptDebug")
            inspector = FakeInspector(
                {101: "RepoPromptDebug", 102: "RepoPromptDebug"},
                {101: unrelated, 102: debug_app_process.ProcessGone("exited")},
                exited={102},
            )
            signals: list[tuple[int, int]] = []

            matches = debug_app_process.matching_processes(missing, inspector)
            signaled = debug_app_process.terminate_matching_processes(
                missing,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(matches, [])
        self.assertEqual(signaled, [])
        self.assertEqual(signals, [])

    def test_termination_with_a_missing_target_fails_closed_for_a_live_unresolved_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "DebugApps" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPromptDebug"
            inspector = FakeInspector({601: "RepoPromptDebug"}, {601: debug_app_process.ProcessGone("ENOENT")})
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "may have been deleted"):
                debug_app_process.terminate_matching_processes(
                    missing,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_termination_refuses_a_candidate_whose_executable_disappears_before_signaling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            # Matched by path, then unresolvable at revalidation while it still answers to its name.
            inspector = FakeInspector({701: "RepoPromptDebug"}, {701: [debug, debug_app_process.ProcessGone("ENOENT")]})
            signals: list[tuple[int, int]] = []

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "may have been deleted"):
                debug_app_process.terminate_matching_processes(
                    debug,
                    inspector,
                    signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
                )

        self.assertEqual(signals, [])

    def test_termination_skips_a_candidate_that_exits_before_signaling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            inspector = FakeInspector(
                {801: "RepoPromptDebug"},
                {801: [debug, debug_app_process.ProcessGone("exited")]},
                exited={801},
            )
            signals: list[tuple[int, int]] = []

            signaled = debug_app_process.terminate_matching_processes(
                debug,
                inspector,
                signaler=lambda pid, sent_signal: signals.append((pid, sent_signal)),
            )

        self.assertEqual(signaled, [])
        self.assertEqual(signals, [])

    def test_running_candidate_with_deleted_executable_is_unknown_not_stopped(self) -> None:
        # libproc reports ENOENT for a running process whose executable was deleted, for
        # example a debug app whose bundle was replaced underneath it.
        with tempfile.TemporaryDirectory() as tmp:
            installed = self.make_executable(Path(tmp), "Present/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            missing = Path(tmp) / "Replaced" / "RepoPrompt.app" / "Contents" / "MacOS" / "RepoPromptDebug"
            for target in (installed, missing):
                with self.subTest(target=target):
                    inspector = FakeInspector({501: "RepoPromptDebug"}, {501: debug_app_process.ProcessGone("ENOENT")})
                    with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "may have been deleted"):
                        debug_app_process.matching_processes(target, inspector)

    def test_unresolvable_named_candidate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            debug = self.make_executable(Path(tmp), "Debug/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
            inspector = FakeInspector(
                {401: "RepoPromptDebug"},
                {401: debug_app_process.ProcessIdentityError("identity unavailable")},
            )

            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "identity unavailable"):
                debug_app_process.matching_processes(debug, inspector)


class PackagedAppMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.bundle = self.root / "DebugApps" / "RepoPrompt.app"

    def test_declared_executable_is_returned_canonically(self) -> None:
        write_app_bundle(self.bundle, "RepoPromptDebug")
        alias = self.root / "alias.app"
        alias.symlink_to(self.bundle)

        executable = debug_app_process.packaged_app_executable(alias, "RepoPromptDebug")

        self.assertEqual(executable, self.bundle / "Contents" / "MacOS" / "RepoPromptDebug")

    def test_expected_name_is_an_assertion_not_a_fallback(self) -> None:
        write_app_bundle(self.bundle, "RepoPrompt", leaves=("RepoPrompt", "RepoPromptDebug"))

        with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "expected 'RepoPromptDebug'"):
            debug_app_process.packaged_app_executable(self.bundle, "RepoPromptDebug")

    def test_malformed_executable_metadata_is_rejected(self) -> None:
        for declared in (None, "", ".", "..", "../RepoPrompt", "MacOS/RepoPromptDebug", 7, ["RepoPromptDebug"]):
            with self.subTest(declared=declared):
                shutil.rmtree(self.bundle, ignore_errors=True)
                write_app_bundle(self.bundle, declared, leaves=("RepoPromptDebug",))
                with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "invalid CFBundleExecutable"):
                    debug_app_process.packaged_app_executable(self.bundle)

    def test_unreadable_info_plist_is_rejected(self) -> None:
        contents = self.bundle / "Contents"
        contents.mkdir(parents=True)
        with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "no Info.plist"):
            debug_app_process.packaged_app_executable(self.bundle)
        for payload in (b"not a plist", b"<?xml version='1.0'?><plist><dict><key>", plistlib.dumps(["RepoPromptDebug"])):
            with self.subTest(payload=payload):
                (contents / "Info.plist").write_bytes(payload)
                with self.assertRaises(debug_app_process.ProcessIdentityError):
                    debug_app_process.packaged_app_executable(self.bundle)

    def test_symlinked_escaping_and_non_executable_leaves_are_rejected(self) -> None:
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "RepoPromptDebug").write_text("binary", encoding="utf-8")
        (outside / "RepoPromptDebug").chmod(0o755)
        macos = self.bundle / "Contents" / "MacOS"
        cases = {
            "symlink": lambda: (macos / "RepoPromptDebug").symlink_to(outside / "RepoPromptDebug"),
            "escapes its bundle": lambda: (shutil.rmtree(macos), macos.symlink_to(outside)),
            "not an executable regular file": lambda: (macos / "RepoPromptDebug").chmod(0o644),
            "unavailable": lambda: (macos / "RepoPromptDebug").unlink(),
        }
        for message, damage in cases.items():
            with self.subTest(message=message):
                shutil.rmtree(self.bundle, ignore_errors=True)
                write_app_bundle(self.bundle, "RepoPromptDebug", leaves=() if message == "symlink" else None)
                damage()
                with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, message):
                    debug_app_process.packaged_app_executable(self.bundle)

    def test_debug_bundle_requires_a_debug_marker_and_a_debug_leaf(self) -> None:
        for marker in ("debug-adhoc", "debug-apple-development"):
            for declared in debug_app_process.DEBUG_APP_EXECUTABLE_NAMES:
                with self.subTest(marker=marker, declared=declared):
                    shutil.rmtree(self.bundle, ignore_errors=True)
                    write_app_bundle(self.bundle, declared, marker=marker)
                    executable = debug_app_process.debug_bundle_executable(self.bundle)
                    self.assertEqual(executable.name, declared)
        for marker in ("local-self-signed", "developer-id", "release-candidate-adhoc", None, 1):
            with self.subTest(marker=marker):
                shutil.rmtree(self.bundle, ignore_errors=True)
                write_app_bundle(self.bundle, "RepoPrompt", marker=marker)
                with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "not a debug app bundle"):
                    debug_app_process.debug_bundle_executable(self.bundle)
        shutil.rmtree(self.bundle)
        write_app_bundle(self.bundle, "Other")
        with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "not a debug app executable"):
            debug_app_process.debug_bundle_executable(self.bundle)

    def test_lifecycle_targets_cover_both_leaves_and_refuse_a_release_bundle(self) -> None:
        expected = (
            self.bundle / "Contents" / "MacOS" / "RepoPromptDebug",
            self.bundle / "Contents" / "MacOS" / "RepoPrompt",
        )
        # A genuinely absent bundle is a normal stopped state, not an error.
        self.assertEqual(debug_app_process.debug_lifecycle_executables(self.bundle), expected)
        write_app_bundle(self.bundle, "RepoPrompt")
        self.assertEqual(debug_app_process.debug_lifecycle_executables(self.bundle), expected)
        shutil.rmtree(self.bundle)
        write_app_bundle(self.bundle, "RepoPrompt", marker="local-self-signed")
        with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "not a debug app bundle"):
            debug_app_process.debug_lifecycle_executables(self.bundle)

    def test_lifecycle_targets_refuse_an_undeclared_leaf_that_leaves_the_bundle(self) -> None:
        production = self.root / "Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt"
        production.parent.mkdir(parents=True)
        production.write_text("binary", encoding="utf-8")
        production.chmod(0o755)
        write_app_bundle(self.bundle, "RepoPromptDebug")
        (self.bundle / "Contents" / "MacOS" / "RepoPrompt").symlink_to(production)

        with self.assertRaisesRegex(
            debug_app_process.ProcessIdentityError,
            "is a symlink to .*remove or correct the unsafe leaf first, then retry './conductor run'",
        ):
            debug_app_process.debug_lifecycle_executables(self.bundle)

        # A leaf below a directory that links out of the bundle is refused even when the leaf
        # itself is a regular file.
        (self.bundle / "Contents" / "Linked").symlink_to(production.parent)
        with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "resolves outside its bundle"):
            debug_app_process.require_contained_leaf(
                self.bundle / "Contents" / "Linked" / "RepoPrompt", self.bundle.resolve(strict=True)
            )


class LifecycleSurfaceTests(unittest.TestCase):
    @staticmethod
    def copy_finder_launcher(root: Path) -> Path:
        launcher = root / "Launch RepoPrompt CE.command"
        launcher.write_text((SCRIPT_DIR.parent / launcher.name).read_text(encoding="utf-8"), encoding="utf-8")
        return launcher

    def test_lifecycle_surfaces_have_no_process_name_kill_fallback(self) -> None:
        run_script = (SCRIPT_DIR / "run.sh").read_text(encoding="utf-8")
        conductor_script = (SCRIPT_DIR / "conductor.py").read_text(encoding="utf-8")
        finder_launcher = (SCRIPT_DIR.parent / "Launch RepoPrompt CE.command").read_text(encoding="utf-8")

        for source in [run_script, conductor_script, finder_launcher]:
            self.assertNotIn("pgrep -x RepoPrompt", source)
            self.assertNotIn("pkill -x RepoPrompt", source)
        self.assertIn('exec python3 -u "$ROOT_DIR/Scripts/conductor.py" __operation_runner "$PAYLOAD"', run_script)
        self.assertIn('"kind": "debug_app_build_then_launch"', run_script)
        self.assertIn("safe coordinated launcher requires Python 3", finder_launcher)
        self.assertIn("No uncoordinated fallback is provided", finder_launcher)
        self.assertNotIn("LAUNCH_MODE", finder_launcher)
        self.assertNotIn("direct mode", finder_launcher.lower())
        agents = (SCRIPT_DIR.parent / "AGENTS.md").read_text(encoding="utf-8")
        readme = (SCRIPT_DIR.parent / "README.md").read_text(encoding="utf-8")
        self.assertIn("does not provide an uncoordinated no-Python fallback", agents)
        self.assertIn("does not provide an", readme)
        self.assertIn("uncoordinated no-Python fallback", readme)

    def test_conductor_inspects_and_signals_both_exact_debug_executables(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bundle = write_app_bundle(Path(tmp) / "DebugApps" / "RepoPrompt.app")
            current = bundle / "Contents" / "MacOS" / "RepoPromptDebug"
            legacy = bundle / "Contents" / "MacOS" / "RepoPrompt"
            running = {current: [12, 11], legacy: [11]}
            inspected: list[Path] = []
            signaled: list[Path] = []

            def matching(path: Path) -> list[int]:
                inspected.append(path)
                return running[path]

            def terminate(path: Path) -> list[int]:
                signaled.append(path)
                return running[path]

            with mock.patch.object(conductor, "debug_app_bundle_path", return_value=bundle), mock.patch.object(
                conductor, "matching_processes", side_effect=matching
            ), mock.patch.object(conductor, "terminate_matching_processes", side_effect=terminate):
                self.assertEqual(conductor.find_debug_app_pids(), ["11", "12"])
                self.assertEqual(conductor.terminate_debug_app_processes(), ["11", "12"])

        self.assertEqual(inspected, [current, legacy])
        self.assertEqual(signaled, [current, legacy])

    def test_conductor_selftest_includes_process_helper_suite(self) -> None:
        makefile = (SCRIPT_DIR.parent / "Makefile").read_text(encoding="utf-8")
        target = makefile.split("conductor-selftest:", 1)[1].split("\n\n", 1)[0]
        self.assertIn("python3 Scripts/test_debug_app_process.py", target)



class ProcessGuardTests(unittest.TestCase):
    APP = "RepoPrompt"
    DISPLAY = "RepoPrompt CE"

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.support = self.root / "Library/Application Support/RepoPrompt CE"
        self.production = self.executable("Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")

    def executable(self, relative_path: str) -> Path:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("binary", encoding="utf-8")
        path.chmod(0o755)
        return path

    def alias(self, relative_path: str, target: Path) -> Path:
        path = self.root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.symlink_to(target)
        return path

    def release_state(self) -> debug_app_process.GuardPolicy:
        return debug_app_process.release_state_guard_policy(self.production, self.APP, self.DISPLAY, self.support)

    def blocking_pids(self, policy: debug_app_process.GuardPolicy, names: dict[int, str], paths: dict) -> list[int]:
        return [process.pid for process in debug_app_process.blocking_processes(policy, FakeInspector(names, paths))]

    def test_production_policy_blocks_only_the_configured_executable(self) -> None:
        elsewhere = self.executable("Elsewhere/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
        lookalike = self.executable("Applications/RepoPrompt CE.app.old/Contents/MacOS/RepoPrompt")
        helper = self.executable("Applications/RepoPrompt CE.app/Contents/Resources/codex/RepoPrompt")
        mcp = self.executable("Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp")
        policy = debug_app_process.production_guard_policy(self.production)
        # The name prefilter comes from the executable path itself, so it cannot disagree with it.
        self.assertEqual(policy.names, frozenset({"RepoPrompt"}))

        blocking = self.blocking_pids(
            policy,
            {1: "RepoPrompt", 2: "RepoPrompt", 3: "RepoPrompt", 4: "RepoPrompt", 5: "repoprompt-mcp"},
            {1: self.production, 2: elsewhere, 3: lookalike, 4: helper, 5: mcp},
        )

        self.assertEqual(blocking, [1])

    def test_guard_fails_closed_for_a_running_process_whose_executable_was_deleted(self) -> None:
        # libproc answers ENOENT for the path of a running process whose executable was
        # unlinked, which the inspector reports as ProcessGone, while its name still reads.
        for policy in (
            debug_app_process.production_guard_policy(self.production),
            self.release_state(),
        ):
            inspector = FakeInspector({1: "RepoPrompt"}, {1: debug_app_process.ProcessGone("ENOENT")})
            with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "may have been deleted"):
                debug_app_process.blocking_processes(policy, inspector)

    def test_release_state_policy_blocks_production_debug_and_mcp_identities(self) -> None:
        other_install = self.executable("Users/me/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt")
        debug = self.executable("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt")
        worktree_debug = self.executable(
            "Library/Application Support/RepoPrompt CE/DebugApps-wt1/RepoPrompt.app/Contents/MacOS/RepoPrompt"
        )
        production_mcp = self.executable("Applications/RepoPrompt CE.app/Contents/MacOS/repoprompt-mcp")
        debug_mcp = self.executable("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp")
        cli_link = self.alias("RepoPrompt/repoprompt_ce_cli", production_mcp)
        rpce_link = self.alias("bin/rpce-cli", cli_link)

        blocking = self.blocking_pids(
            self.release_state(),
            {
                1: "RepoPrompt",
                2: "RepoPrompt",
                3: "RepoPrompt",
                4: "RepoPrompt",
                5: "repoprompt-mcp",
                6: "repoprompt-mcp",
                7: "rpce-cli",
            },
            {1: self.production, 2: other_install, 3: debug, 4: worktree_debug, 5: production_mcp, 6: debug_mcp, 7: rpce_link},
        )

        self.assertEqual(blocking, [1, 2, 3, 4, 5, 6, 7])

    def test_release_state_policy_blocks_renamed_debug_apps(self) -> None:
        debug = self.executable("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
        worktree_debug = self.executable(
            "Library/Application Support/RepoPrompt CE/DebugApps-wt1/RepoPrompt.app/Contents/MacOS/RepoPromptDebug"
        )
        staged_debug = self.executable(
            "Library/Application Support/RepoPrompt CE/DebugApps/.staging/1-2-ab/RepoPrompt.app/Contents/MacOS/RepoPromptDebug"
        )

        blocking = self.blocking_pids(
            self.release_state(),
            {1: "RepoPromptDebug", 2: "RepoPromptDebug", 3: "RepoPromptDebug"},
            {1: debug, 2: worktree_debug, 3: staged_debug},
        )

        self.assertEqual(blocking, [1, 2, 3])

    def test_release_state_policy_ignores_renamed_name_outside_debug_bundles(self) -> None:
        elsewhere = self.executable("Users/me/tools/RepoPromptDebug")
        lookalike = self.executable("Library/Application Support/RepoPrompt CE/DebugAppsX/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
        other_support = self.executable("Library/Application Support/Other/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")

        blocking = self.blocking_pids(
            self.release_state(),
            {1: "RepoPromptDebug", 2: "RepoPromptDebug", 3: "RepoPromptDebug"},
            {1: elsewhere, 2: lookalike, 3: other_support},
        )

        self.assertEqual(blocking, [])

    def test_release_state_policy_adds_exact_debug_paths_from_conductor_overrides(self) -> None:
        custom_bundle = self.root / "Custom/RepoPrompt.app"
        custom_root = self.root / "CustomRoot"
        cases = {
            "bundle": ({"REPOPROMPT_DEBUG_APP_BUNDLE": str(custom_bundle)}, custom_bundle),
            "root": ({"REPOPROMPT_DEBUG_APP_ROOT": str(custom_root)}, custom_root / "RepoPrompt.app"),
            "bundle wins over root": (
                {"REPOPROMPT_DEBUG_APP_BUNDLE": str(custom_bundle), "REPOPROMPT_DEBUG_APP_ROOT": str(custom_root)},
                custom_bundle,
            ),
        }
        unrelated = self.executable("Custom/Other.app/Contents/MacOS/RepoPromptDebug")
        unrelated_helper = self.executable("Custom/Other.app/Contents/MacOS/repoprompt-mcp")
        for label, (environ, bundle) in cases.items():
            with self.subTest(label=label):
                current = self.executable(str((bundle / "Contents/MacOS/RepoPromptDebug").relative_to(self.root)))
                legacy = self.executable(str((bundle / "Contents/MacOS/RepoPrompt").relative_to(self.root)))
                helper = self.executable(str((bundle / "Contents/MacOS/repoprompt-mcp").relative_to(self.root)))
                cli_alias = self.alias(f"aliases/{label}/repoprompt_ce_cli_debug", helper)
                policy = debug_app_process.release_state_guard_policy(
                    self.production, self.APP, self.DISPLAY, self.support, environ
                )

                blocking = self.blocking_pids(
                    policy,
                    {
                        1: "RepoPromptDebug",
                        2: "RepoPrompt",
                        3: "RepoPromptDebug",
                        4: "RepoPrompt",
                        5: "repoprompt-mcp",
                        6: "repoprompt_ce_cli_debug",
                        7: "repoprompt-mcp",
                    },
                    {1: current, 2: legacy, 3: unrelated, 4: self.production, 5: helper, 6: cli_alias, 7: unrelated_helper},
                )

                # The override adds exact debug matches, including its MCP helper reached directly or
                # through a CLI link; production still blocks beside them.
                self.assertEqual(blocking, [1, 2, 4, 5, 6])
        without_override = self.blocking_pids(
            debug_app_process.release_state_guard_policy(self.production, self.APP, self.DISPLAY, self.support, {}),
            {1: "RepoPromptDebug", 2: "repoprompt-mcp"},
            {1: custom_bundle / "Contents/MacOS/RepoPromptDebug", 2: custom_bundle / "Contents/MacOS/repoprompt-mcp"},
        )
        self.assertEqual(without_override, [])

    def test_production_policy_ignores_current_and_legacy_debug_apps(self) -> None:
        legacy = self.executable("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt")
        current = self.executable("Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")

        blocking = self.blocking_pids(
            debug_app_process.production_guard_policy(self.production),
            {1: "RepoPrompt", 2: "RepoPromptDebug", 3: "RepoPrompt"},
            {1: legacy, 2: current, 3: self.production},
        )

        self.assertEqual(blocking, [3])

    def test_release_state_policy_ignores_lookalikes_and_unrelated_bundles(self) -> None:
        lookalike_debug = self.executable(
            "Library/Application Support/RepoPrompt CE/DebugAppsX/RepoPrompt.app/Contents/MacOS/RepoPrompt"
        )
        other_support = self.executable("Library/Application Support/Other/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt")
        suffix_lookalike = self.executable("Applications/NotRepoPrompt CE.app/Contents/MacOS/RepoPrompt")
        other_product_mcp = self.executable("Applications/RepoPrompt.app/Contents/MacOS/repoprompt-mcp")
        helper = self.executable("Applications/RepoPrompt CE.app/Contents/MacOS/codex")

        blocking = self.blocking_pids(
            self.release_state(),
            {1: "RepoPrompt", 2: "RepoPrompt", 3: "RepoPrompt", 4: "repoprompt-mcp", 5: "RepoPrompt"},
            {1: lookalike_debug, 2: other_support, 3: suffix_lookalike, 4: other_product_mcp, 5: helper},
        )

        self.assertEqual(blocking, [])

    def test_guard_ignores_exited_and_uninspectable_foreign_processes(self) -> None:
        inspector = FakeInspector(
            {1: "RepoPrompt", 2: "launchd", 3: "RepoPrompt"},
            {
                1: debug_app_process.ProcessGone("exited"),
                2: debug_app_process.ProcessIdentityError("Operation not permitted"),
                3: self.production,
            },
            exited={1},
        )

        blocking = debug_app_process.blocking_processes(self.release_state(), inspector)

        self.assertEqual([process.pid for process in blocking], [3])

    def test_guard_fails_closed_when_a_named_candidate_cannot_be_inspected(self) -> None:
        for name in ("RepoPrompt", "repoprompt-mcp", "repoprompt_ce_cli_debug"):
            with self.subTest(name=name):
                inspector = FakeInspector({1: name}, {1: debug_app_process.ProcessIdentityError("identity unavailable")})
                with self.assertRaisesRegex(debug_app_process.ProcessIdentityError, "identity unavailable"):
                    debug_app_process.blocking_processes(self.release_state(), inspector)

    def test_exact_executable_list_replaces_the_shape_rules(self) -> None:
        owned = self.executable("fixture/owned-tool")
        alias = self.alias("fixture/repoprompt-mcp", owned)
        policy = debug_app_process.exact_executables_guard_policy([alias])

        blocking = self.blocking_pids(
            policy,
            {1: "RepoPrompt", 2: "owned-tool", 3: "repoprompt-mcp"},
            {1: self.production, 2: owned, 3: owned},
        )

        self.assertEqual(blocking, [2, 3])

    def test_exact_executable_list_is_validated(self) -> None:
        for raw in ("not json", "[]", "{}", '["relative/path"]', "[1]"):
            with self.subTest(raw=raw), self.assertRaises(debug_app_process.ProcessIdentityError):
                debug_app_process.parse_exact_executables(raw)

    def run_guard_cli(self, argv: list[str], inspector: FakeInspector) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = debug_app_process.main(argv, inspector=inspector)
        return status, stdout.getvalue(), stderr.getvalue()

    def test_guard_cli_distinguishes_clear_blocked_and_inspection_failure(self) -> None:
        argv = ["guard", "production", "--production-executable", str(self.production)]

        clear = self.run_guard_cli(argv, FakeInspector({}, {}))
        blocked = self.run_guard_cli(argv, FakeInspector({77: "RepoPrompt"}, {77: self.production}))
        failed = self.run_guard_cli(
            argv, FakeInspector({78: "RepoPrompt"}, {78: debug_app_process.ProcessIdentityError("denied")})
        )

        self.assertEqual(clear, (debug_app_process.GUARD_EXIT_CLEAR, "", ""))
        self.assertEqual(blocked[0], debug_app_process.GUARD_EXIT_BLOCKED)
        self.assertEqual(blocked[1], f"  77  {self.production}\n")
        self.assertEqual(failed[0], debug_app_process.EXIT_INSPECTION_FAILED)
        self.assertIn("denied", failed[2])

    def test_release_state_cli_reads_the_conductor_debug_override_from_the_environment(self) -> None:
        override = self.executable("Custom/RepoPrompt.app/Contents/MacOS/RepoPromptDebug")
        argv = [
            "guard",
            "release-state",
            "--production-executable",
            str(self.production),
            "--app-name",
            self.APP,
            "--display-name",
            self.DISPLAY,
            "--support-dir",
            str(self.support),
        ]
        inspector = FakeInspector({79: "RepoPromptDebug"}, {79: override})

        with mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(self.root / "Custom/RepoPrompt.app")}):
            status, stdout, _ = self.run_guard_cli(argv, inspector)

        self.assertEqual(status, debug_app_process.GUARD_EXIT_BLOCKED)
        self.assertEqual(stdout, f"  79  {override}\n")

    def test_guard_never_signals_a_blocking_process(self) -> None:
        argv = ["guard", "production", "--production-executable", str(self.production)]
        refuse = mock.Mock(side_effect=AssertionError("guard must not signal"))

        with mock.patch.object(debug_app_process.os, "kill", refuse), mock.patch.object(
            debug_app_process.os, "killpg", refuse
        ), mock.patch.object(debug_app_process.signal, "pthread_kill", refuse):
            status, stdout, _ = self.run_guard_cli(argv, FakeInspector({77: "RepoPrompt"}, {77: self.production}))

        self.assertEqual(status, debug_app_process.GUARD_EXIT_BLOCKED)
        self.assertIn("77", stdout)
        refuse.assert_not_called()

    def test_cli_keeps_pid_operations_and_requires_each_policy_argument(self) -> None:
        for operation in ("list", "terminate"):
            args = debug_app_process.parse_args([operation, "--executable", str(self.production)])
            self.assertEqual((args.operation, args.executable), (operation, self.production))
        exact = debug_app_process.parse_args(["guard", "exact", "--executables-json", '["/a/RepoPrompt"]'])
        self.assertEqual((exact.policy, exact.executables_json), ("exact", '["/a/RepoPrompt"]'))
        incomplete = [
            ["list"],
            ["guard"],
            ["guard", "production"],
            ["guard", "production", "--production-executable", str(self.production), "--app-name", self.APP],
            ["guard", "release-state", "--production-executable", str(self.production), "--app-name", self.APP],
            ["guard", "exact"],
        ]
        for argv in incomplete:
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
                debug_app_process.parse_args(argv)
            self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
