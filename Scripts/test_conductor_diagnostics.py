#!/usr/bin/env python3
"""Unit tests for the focused-build and high-output diagnostic helpers."""

from __future__ import annotations

import contextlib
import io
import json
import os
import plistlib
import sys
import unittest
from pathlib import Path
from typing import Tuple
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import conductor  # noqa: E402
import conductor_diagnostics  # noqa: E402
import debug_app_process  # noqa: E402
from script_test_support import (  # noqa: E402
    directory_snapshot,
    enter_context,
    temporary_directory,
    write_executable,
)


def write_app_bundle(
    bundle: Path,
    declared: str = "RepoPromptDebug",
    *,
    marker: str = "debug-adhoc",
    leaves: tuple[str, ...] | None = None,
) -> Path:
    """Writes an app bundle whose Info.plist declares `declared` and holds executable `leaves`."""
    (bundle / "Contents").mkdir(parents=True, exist_ok=True)
    with (bundle / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleExecutable": declared, "RepoPromptSigningMode": marker}, handle)
    for leaf in leaves if leaves is not None else (declared,):
        write_executable(bundle / "Contents" / "MacOS" / leaf, "#!/bin/sh\nexit 0\n")
    return bundle


def no_lock(*_args: object, **_kwargs: object) -> contextlib.AbstractContextManager[None]:
    return contextlib.nullcontext()


class ProcessTable:
    """A fixed process table for the real process-identity helpers."""

    def __init__(self, processes: dict[int, tuple[str, Path]]) -> None:
        self.processes = processes

    def list_pids(self) -> list[int]:
        return list(self.processes)

    def process_name(self, pid: int) -> str | None:
        return self.processes[pid][0] if pid in self.processes else None

    def process_path(self, pid: int) -> Path:
        return self.processes[pid][1].resolve(strict=True)


class XCTestSandboxTests(unittest.TestCase):
    def test_default_uses_fresh_job_directory_and_is_reported_as_artifact(self) -> None:
        with temporary_directory() as tmp:
            default_root = tmp / "ticket.test-sandbox"
            env: dict[str, str] = {}

            sandbox_root = conductor.configure_xctest_sandbox("test", {}, env, default_root)

            self.assertEqual(sandbox_root, str(default_root))
            self.assertEqual(env["REPOPROMPT_TEST_SANDBOX_ROOT"], str(default_root))
            self.assertTrue(default_root.is_dir())
            self.assertEqual(
                (default_root / conductor.TEST_SANDBOX_MARKER_FILENAME).read_text(encoding="utf-8"),
                conductor.TEST_SANDBOX_MARKER_CONTENT,
            )
            summary = conductor.OutputSummarizer.summarize_lines(
                "test",
                {},
                "completed",
                0,
                False,
                [f"Test sandbox: {sandbox_root}\n"],
            )
            self.assertEqual(summary["sections"][0]["title"], "Artifacts")
            self.assertEqual(summary["sections"][0]["lines"], [f"Test sandbox: {sandbox_root}"])

            job = conductor.Job(
                ticket="ticket",
                request_key=None,
                fingerprint="fingerprint",
                operation="test",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={},
                created_at=0,
                log_path=tmp / "ticket.log",
                test_sandbox_root=sandbox_root,
            )
            payload = job.to_payload(include_tail=False, include_summary=False)
            self.assertEqual(payload["testSandboxRoot"], sandbox_root)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                conductor.print_job_result_header(payload, {"headline": "completed successfully"})
            self.assertIn(f"Sandbox:  {sandbox_root}", output.getvalue())

    def test_focused_build_injects_sandbox_only_when_it_runs_tests(self) -> None:
        cases = (
            (["focused-build", "--test"], True),
            (["focused-build", "--filter", "ExampleTests"], True),
            (["focused-build"], False),
        )
        for argv, expects_sandbox in cases:
            with self.subTest(argv=argv), temporary_directory() as tmp:
                captured_args: dict[str, object] = {}

                def capture_request(
                    _paths: object,
                    operation: str,
                    args: dict[str, object],
                    _flags: object,
                ) -> int:
                    self.assertEqual(operation, "diagnostics")
                    captured_args.update(args)
                    return 0

                with mock.patch.object(
                    conductor,
                    "enqueue_and_maybe_wait",
                    side_effect=capture_request,
                ):
                    self.assertEqual(
                        conductor.handle_real_operation(mock.Mock(), "diagnostics", argv),
                        0,
                    )

                default_root = tmp / "ticket.test-sandbox"
                env: dict[str, str] = {}
                sandbox_root = conductor.configure_xctest_sandbox(
                    "diagnostics",
                    captured_args,
                    env,
                    default_root,
                )

                if expects_sandbox:
                    self.assertEqual(sandbox_root, str(default_root))
                    self.assertEqual(env[conductor.TEST_SANDBOX_ENV_KEY], str(default_root))
                    self.assertTrue(default_root.is_dir())
                else:
                    self.assertIsNone(sandbox_root)
                    self.assertNotIn(conductor.TEST_SANDBOX_ENV_KEY, env)
                    self.assertFalse(default_root.exists())

    def test_explicit_sandbox_override_wins(self) -> None:
        with temporary_directory() as tmp:
            default_root = tmp / "ticket.test-sandbox"
            explicit_root = str(tmp / "caller-sandbox")
            env = {"REPOPROMPT_TEST_SANDBOX_ROOT": f"  {explicit_root}\n"}

            sandbox_root = conductor.configure_xctest_sandbox("provider-test", {}, env, default_root)

            self.assertEqual(sandbox_root, explicit_root)
            self.assertEqual(env["REPOPROMPT_TEST_SANDBOX_ROOT"], explicit_root)
            self.assertFalse(default_root.exists())

    def test_blank_explicit_sandbox_is_rejected(self) -> None:
        for value in ("", "  \n"):
            with self.subTest(value=value), temporary_directory() as tmp:
                with self.assertRaisesRegex(conductor.ConductorError, "must not be blank"):
                    conductor.configure_xctest_sandbox(
                        "test",
                        {},
                        {"REPOPROMPT_TEST_SANDBOX_ROOT": value},
                        tmp / "ticket.test-sandbox",
                    )

    def test_retention_removes_only_conductor_owned_sandbox(self) -> None:
        with temporary_directory() as tmp:
            jobs_dir = tmp / "jobs"
            owned = jobs_dir / "ticket.test-sandbox"
            caller_owned = jobs_dir / "caller.test-sandbox"
            owned.mkdir(parents=True)
            caller_owned.mkdir()
            for sandbox in (owned, caller_owned):
                (sandbox / conductor.TEST_SANDBOX_MARKER_FILENAME).write_text(
                    conductor.TEST_SANDBOX_MARKER_CONTENT,
                    encoding="utf-8",
                )
            (owned / "profile.json").write_text("{}", encoding="utf-8")
            os.utime(owned, (0, 0))
            os.utime(caller_owned, (0, 0))
            caller_job = conductor.Job(
                ticket="caller",
                request_key=None,
                fingerprint="fingerprint",
                operation="test",
                args={},
                lanes=["build"],
                timeout=None,
                verbose=False,
                env={conductor.TEST_SANDBOX_ENV_KEY: f"  {caller_owned}\n"},
                created_at=0,
                log_path=jobs_dir / "caller.log",
            )
            state = object.__new__(conductor.DaemonState)
            state.paths = mock.Mock(jobs_dir=jobs_dir)
            state.condition = mock.MagicMock()
            state._retention_generation = 1
            state.jobs = {caller_job.ticket: caller_job}
            retained = state._test_sandbox_name_for_job(caller_job)
            self.assertEqual(retained, caller_owned.name)

            state._retention_external(
                1,
                (),
                (caller_owned,),
                frozenset(),
                frozenset(),
                frozenset(),
            )

            self.assertFalse(owned.exists())
            self.assertTrue(caller_owned.exists())


class FocusedBuildDiagnosticTests(unittest.TestCase):
    def _make_fake_swift(self, output: str, exit_code: int = 0) -> Path:
        tmp = enter_context(self, temporary_directory())
        swift = tmp / "swift"
        write_executable(
            swift,
            "#!/usr/bin/env bash\n"
            f"cat <<'EOF'\n{output}EOF\n"
            f"exit {exit_code}\n",
        )
        return tmp

    def _run_with_path(self, path: Path, args: dict) -> Tuple[int, str]:
        old_path = os.environ.get("PATH")
        try:
            # Keep only the fake swift directory plus the system tools the
            # fixture needs. macOS keeps bash in /bin, while /usr/bin/env
            # resolves the fixture's shebang through PATH.
            os.environ["PATH"] = f"{path}{os.pathsep}/usr/bin{os.pathsep}/bin"
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                code = conductor_diagnostics.run_focused_build(self.repo_root, args)
            return code, buf.getvalue()
        finally:
            if old_path is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = old_path

    def setUp(self) -> None:
        self.repo_root = enter_context(self, temporary_directory())

    def test_focused_build_parses_swift_build_output(self) -> None:
        output = (
            "Building for debugging...\n"
            "[0/5] Write swift-version--42C19770CB19FCAE.txt\n"
            "[3/7] Compiling swift_probe swift_probe.swift\n"
            "[4/7] Emitting module swift_probe\n"
            "[5/8] Wrapping AST for swift_probe for debugging\n"
            "[6/8] Write Objects.LinkFileList\n"
            "[7/8] Linking swift_probe\n"
            "Build complete! (1.23s)\n"
        )
        fake_path = self._make_fake_swift(output, exit_code=0)
        code, captured = self._run_with_path(fake_path, {"product": "RepoPrompt"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["diagnostic"], "focused-build")
        self.assertEqual(report["swift"]["exitCode"], 0)
        self.assertEqual(report["timing"]["build"]["seconds"], 1.23)
        self.assertEqual(report["jobs"]["compile"], 1)
        self.assertEqual(report["jobs"]["emitModule"], 1)
        self.assertEqual(report["jobs"]["wrapAst"], 1)
        self.assertEqual(report["jobs"]["link"], 1)
        self.assertEqual(report["jobs"]["write"], 2)
        self.assertEqual(report["jobs"]["frontend"], 3)
        self.assertEqual(report["output"]["lines"], 8)

    def test_focused_build_counts_warnings_and_errors_by_module(self) -> None:
        output = (
            "Building for debugging...\n"
            "[2/101] Emitting module RepoPromptShared\n"
            "[3/103] Compiling RepoPromptShared POSIXDescriptorSupport.swift\n"
            "Sources/RepoPromptShared/Warning.swift:10:5: warning: unused variable\n"
            "Sources/RepoPromptShared/Warning.swift:11:5: warning: unused variable\n"
            "Sources/RepoPromptShared/Error.swift:20:5: error: cannot find 'x' in scope\n"
            "Build complete! (2.50s)\n"
        )
        fake_path = self._make_fake_swift(output, exit_code=1)
        code, captured = self._run_with_path(fake_path, {"product": "RepoPrompt"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["swift"]["exitCode"], 1)
        self.assertEqual(report["warnings"]["rawCount"], 2)
        self.assertEqual(report["warnings"]["uniqueCount"], 1)
        self.assertEqual(report["warnings"]["byModule"]["RepoPromptShared"], 2)
        self.assertEqual(report["errors"]["rawCount"], 1)
        self.assertEqual(report["errors"]["byModule"]["RepoPromptShared"], 1)
        self.assertEqual(report["errors"]["bySource"]["Sources/RepoPromptShared/Error.swift"], 1)

    def test_focused_build_resolves_relative_warning_and_error_paths(self) -> None:
        # No compile-task context is emitted before the diagnostics, so the
        # parser must derive the module from the repo-relative source path.
        output = (
            "Building for debugging...\n"
            "Sources/RepoPromptShared/Warning.swift:10:5: warning: unused variable\n"
            "Sources/RepoPromptShared/Error.swift:20:5: error: cannot find 'x' in scope\n"
            "Build complete! (1.00s)\n"
        )
        fake_path = self._make_fake_swift(output, exit_code=0)
        code, captured = self._run_with_path(fake_path, {"product": "RepoPrompt"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["warnings"]["byModule"]["RepoPromptShared"], 1)
        self.assertEqual(report["warnings"]["bySource"]["Sources/RepoPromptShared/Warning.swift"], 1)
        self.assertEqual(report["errors"]["byModule"]["RepoPromptShared"], 1)
        self.assertEqual(report["errors"]["bySource"]["Sources/RepoPromptShared/Error.swift"], 1)

    def test_focused_build_resolves_absolute_warning_paths(self) -> None:
        abs_warning = str(self.repo_root / "Sources/RepoPromptShared/Warning.swift")
        abs_error = str(self.repo_root / "Sources/RepoPromptShared/Error.swift")
        output = (
            "Building for debugging...\n"
            f"{abs_warning}:10:5: warning: unused variable\n"
            f"{abs_error}:20:5: error: cannot find 'x' in scope\n"
            "Build complete! (1.00s)\n"
        )
        fake_path = self._make_fake_swift(output, exit_code=0)
        code, captured = self._run_with_path(fake_path, {"product": "RepoPrompt"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["warnings"]["byModule"]["RepoPromptShared"], 1)
        self.assertEqual(report["errors"]["byModule"]["RepoPromptShared"], 1)

    def test_focused_build_parses_swift_test_output(self) -> None:
        output = (
            "Building for debugging...\n"
            "[7/8] Linking swift_probe\n"
            "Build complete! (2.00s)\n"
            "Test Suite 'All tests' started at 2025-10-09 13:12:08.094\n"
            "Test Suite 'All tests' passed at 2025-10-09 13:12:08.095\n"
            "     Executed 3 tests, with 0 failures (0 unexpected) in 0.456 (0.457) seconds\n"
        )
        fake_path = self._make_fake_swift(output, exit_code=0)
        code, captured = self._run_with_path(fake_path, {"testFilter": "Example"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["swift"]["exitCode"], 0)
        self.assertEqual(report["timing"]["xctest"]["tests"], 3)
        self.assertEqual(report["timing"]["xctest"]["seconds"], 0.456)
        self.assertEqual(report["timing"]["xctest"]["wallSeconds"], 0.457)

    def test_focused_build_missing_swift_returns_one(self) -> None:
        with temporary_directory() as tmp, mock.patch.object(
            conductor_diagnostics.subprocess,
            "Popen",
            side_effect=FileNotFoundError,
        ):
            code, _ = self._run_with_path(tmp, {"product": "RepoPrompt"})
        self.assertEqual(code, 1)

    def test_focused_build_reports_scratch_state(self) -> None:
        output = "Build complete! (0.50s)\n"
        fake_path = self._make_fake_swift(output, exit_code=0)
        build_dir = self.repo_root / ".build"
        build_dir.mkdir()
        (build_dir / "some").write_text("x", encoding="utf-8")
        code, captured = self._run_with_path(fake_path, {"product": "RepoPrompt"})
        self.assertEqual(code, 0)
        report = json.loads(captured)
        self.assertEqual(report["scratch"]["observedBefore"], "warm")
        self.assertIsNotNone(report["scratch"]["sizeBytes"])
        self.assertGreaterEqual(report["scratch"]["sizeBytes"], 1)


class DebugAppLifecycleTests(unittest.TestCase):
    """Debug app lifecycle against fixture bundles; machine-wide locks are replaced so no
    real conductor lock, debug app, or production app is touched."""

    def setUp(self) -> None:
        self.tmp = enter_context(self, temporary_directory())
        self.bundle = self.tmp / "DebugApps" / "RepoPrompt.app"
        self.current = self.bundle / "Contents" / "MacOS" / "RepoPromptDebug"
        self.legacy = self.bundle / "Contents" / "MacOS" / "RepoPrompt"
        enter_context(self, mock.patch.dict(os.environ, {"REPOPROMPT_DEBUG_APP_BUNDLE": str(self.bundle)}))
        enter_context(self, mock.patch.object(conductor, "APP_STOP_POLL_SECONDS", 0.01))
        enter_context(self, mock.patch.object(conductor, "APP_STOP_QUIET_SECONDS", 0.05))
        enter_context(self, mock.patch.object(conductor, "machine_exclusive_lock", no_lock))
        enter_context(self, mock.patch.object(conductor, "machine_heavy_slot", no_lock))
        self.commands: list[list[str]] = []
        self.output = io.StringIO()
        enter_context(self, contextlib.redirect_stdout(self.output))

    def record_command(self, _label: str, argv: list[object], _cwd: Path, **_kwargs: object) -> Tuple[int, str, str]:
        self.commands.append([str(arg) for arg in argv])
        return 0, "", ""

    def test_stop_and_status_target_only_the_exact_current_and_legacy_debug_paths(self) -> None:
        write_app_bundle(self.bundle, leaves=("RepoPromptDebug", "RepoPrompt"))
        running = {self.current: {12}, self.legacy: {11}}
        inspected: set[Path] = set()
        signaled: list[Path] = []

        def matching(path: Path) -> list[int]:
            inspected.add(path)
            return sorted(running[path])

        def terminate(path: Path) -> list[int]:
            signaled.append(path)
            pids, running[path] = sorted(running[path]), set()
            return pids

        with mock.patch.object(conductor, "matching_processes", side_effect=matching), mock.patch.object(
            conductor, "terminate_matching_processes", side_effect=terminate
        ), mock.patch.object(conductor, "run_operation_command", side_effect=self.record_command):
            status_code = conductor.operation_app_status(self.tmp)
            stop_code = conductor._operation_app_stop_unlocked(self.tmp, {})

        output = self.output.getvalue()
        self.assertEqual((status_code, stop_code), (0, 0))
        self.assertIn("Running matching debug app PIDs: 11, 12", output)
        self.assertIn(f"App executable: {self.current.resolve()}", output)
        self.assertIn("RepoPrompt stop confirmed.", output)
        self.assertEqual(signaled, [self.current, self.legacy])
        self.assertEqual(inspected, {self.current, self.legacy})

    def test_release_marked_debug_override_is_never_stopped_or_launched(self) -> None:
        write_app_bundle(self.bundle, "RepoPrompt", marker="local-self-signed")
        before = directory_snapshot(self.bundle)
        matching = mock.Mock(side_effect=AssertionError("a release bundle must not be inspected"))
        terminate = mock.Mock(side_effect=AssertionError("a release bundle must not be signaled"))

        with mock.patch.object(conductor, "matching_processes", matching), mock.patch.object(
            conductor, "terminate_matching_processes", terminate
        ), mock.patch.object(conductor, "run_operation_command", side_effect=self.record_command):
            stop_code = conductor._operation_app_stop_unlocked(self.tmp, {})
            launch_code = conductor.operation_app_launch_existing(self.tmp, {})

        self.assertEqual((stop_code, launch_code), (1, 1))
        matching.assert_not_called()
        terminate.assert_not_called()
        self.assertEqual(self.commands, [])
        self.assertEqual(directory_snapshot(self.bundle), before)
        self.assertIn("not a debug app bundle", self.output.getvalue())

    def test_undeclared_leaf_linking_to_production_fails_closed_without_signaling(self) -> None:
        production = self.tmp / "Applications" / "RepoPrompt CE.app" / "Contents" / "MacOS" / "RepoPrompt"
        write_executable(production, "#!/bin/sh\nexit 0\n")
        write_app_bundle(self.bundle)
        self.legacy.symlink_to(production)
        table = ProcessTable({41: ("RepoPrompt", production)})
        signals: list[tuple[int, int]] = []

        def matching(path: Path) -> list[int]:
            return debug_app_process.matching_processes(path, table)

        def terminate(path: Path) -> list[int]:
            return debug_app_process.terminate_matching_processes(
                path, table, signaler=lambda pid, sent: signals.append((pid, sent))
            )

        with mock.patch.object(conductor, "matching_processes", side_effect=matching), mock.patch.object(
            conductor, "terminate_matching_processes", side_effect=terminate
        ), mock.patch.object(conductor, "run_operation_command", side_effect=self.record_command):
            stop_code = conductor._operation_app_stop_unlocked(self.tmp, {})
            status_code = conductor.operation_app_status(self.tmp)

        output = self.output.getvalue()
        self.assertEqual(signals, [])
        self.assertEqual((stop_code, status_code), (1, 1))
        self.assertIn("could not safely identify the debug app process", output)
        self.assertIn(f"{self.legacy} is a symlink to {production}", output)
        self.assertIn("remove or correct the unsafe leaf first, then retry './conductor run'", output)
        self.assertIn("Running matching debug app PIDs: unknown", output)

    def test_launch_existing_follows_the_declared_executable_of_an_intact_legacy_bundle(self) -> None:
        write_app_bundle(self.bundle, "RepoPrompt")

        with mock.patch.object(conductor, "_operation_app_stop_unlocked", return_value=0), mock.patch.object(
            conductor, "report_launch_bundle_details", return_value=0
        ), mock.patch.object(conductor, "wait_for_debug_app_process", return_value=["11"]), mock.patch.object(
            conductor, "run_operation_command", side_effect=self.record_command
        ):
            code = conductor.operation_app_launch_existing(self.tmp, {})

        self.assertEqual(code, 0)
        self.assertEqual(self.commands, [["open", "-n", str(self.bundle)]])

    def test_launch_existing_does_not_substitute_another_leaf_for_a_missing_declared_one(self) -> None:
        write_app_bundle(self.bundle, "RepoPromptDebug", leaves=("RepoPrompt",))
        stop = mock.Mock(return_value=0)

        with mock.patch.object(conductor, "_operation_app_stop_unlocked", stop), mock.patch.object(
            conductor, "run_operation_command", side_effect=self.record_command
        ):
            code = conductor.operation_app_launch_existing(self.tmp, {})

        self.assertEqual(code, 1)
        stop.assert_not_called()
        self.assertEqual(self.commands, [])
        self.assertIn("existing debug app bundle is not launchable", self.output.getvalue())

    def test_staged_activation_requires_the_renamed_executable_and_a_debug_marker(self) -> None:
        write_app_bundle(self.bundle, "RepoPrompt")
        live_before = directory_snapshot(self.bundle)
        staging = self.bundle.parent / ".staging"
        for label, declared, marker in (
            ("legacy-name", "RepoPrompt", "debug-adhoc"),
            ("release-marker", "RepoPromptDebug", "local-self-signed"),
        ):
            with self.subTest(label=label):
                staged = write_app_bundle(staging / label / "RepoPrompt.app", declared, marker=marker)
                with self.assertRaisesRegex(conductor.ConductorError, "not launchable"):
                    conductor.activate_staged_debug_bundle(staged, self.bundle)
                self.assertEqual(directory_snapshot(self.bundle), live_before)

        staged = write_app_bundle(staging / "current" / "RepoPrompt.app")
        conductor.activate_staged_debug_bundle(staged, self.bundle)

        self.assertEqual(debug_app_process.debug_bundle_executable(self.bundle).name, "RepoPromptDebug")
        self.assertFalse(staged.parent.exists())

    def test_packaging_admits_only_staged_output_that_declares_the_renamed_executable(self) -> None:
        staging = self.bundle.parent / ".staging"
        for declared, expected_code in (("RepoPrompt", 1), ("RepoPromptDebug", 0)):
            with self.subTest(declared=declared):

                def package(_label: str, _argv: list[str], _cwd: Path, env: dict[str, str], **_kwargs: object) -> Tuple[int, str, str]:
                    write_app_bundle(Path(env["REPOPROMPT_DEBUG_APP_BUNDLE"]), declared)
                    return 0, "", ""

                with mock.patch.object(conductor, "run_operation_command", side_effect=package):
                    code, staged = conductor.package_debug_app_under_heavy(self.tmp, "debug app build/package")

                self.assertEqual(code, expected_code)
                if expected_code:
                    self.assertIsNone(staged)
                    self.assertEqual(list(staging.iterdir()), [])
                else:
                    assert staged is not None
                    self.assertEqual(debug_app_process.debug_bundle_executable(staged).name, "RepoPromptDebug")
                    conductor.cleanup_staged_debug_bundle(staged)

    def test_package_failure_leaves_the_live_debug_app_untouched(self) -> None:
        write_app_bundle(self.bundle, "RepoPrompt")
        before = directory_snapshot(self.bundle)
        stop = mock.Mock(return_value=0)
        activate = mock.Mock()

        with mock.patch.object(conductor, "run_operation_command", return_value=(2, "", "")) as command, mock.patch.object(
            conductor, "_operation_app_stop_unlocked", stop
        ), mock.patch.object(conductor, "activate_staged_debug_bundle", activate):
            code = conductor.operation_debug_app_build_then_launch(self.tmp, {})

        self.assertEqual(code, 2)
        self.assertEqual(command.call_count, 1)
        stop.assert_not_called()
        activate.assert_not_called()
        self.assertEqual(directory_snapshot(self.bundle), before)
        self.assertIn("no live bundle or stop/launch lifecycle action was performed", self.output.getvalue())


class HighOutputDiagnosticTests(unittest.TestCase):
    def test_high_output_generates_expected_counts(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = conductor_diagnostics.run_high_output(Path("/tmp"), {"lines": 10, "warnings": 2, "exitCode": 42})
        self.assertEqual(code, 42)
        text = buf.getvalue()
        lines = text.strip().splitlines()
        # start marker + 10 lines + 2 warnings + done marker
        self.assertEqual(len(lines), 14)
        self.assertEqual(sum(1 for line in lines if "synthetic warning 0" in line), 1)
        self.assertEqual(sum(1 for line in lines if "synthetic warning 1" in line), 1)

    def test_high_output_honors_zero_lines_and_warnings(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = conductor_diagnostics.run_high_output(Path("/tmp"), {"lines": 0, "warnings": 0, "exitCode": 7})
        self.assertEqual(code, 7)
        lines = buf.getvalue().strip().splitlines()
        self.assertEqual(lines, ["==> high-output diagnostic start", "==> high-output diagnostic done"])


if __name__ == "__main__":
    unittest.main()
