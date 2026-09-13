#!/usr/bin/env python3
"""Unit tests for the focused-build and high-output diagnostic helpers."""

from __future__ import annotations

import contextlib
import io
import json
import os
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
from script_test_support import enter_context, temporary_directory, write_executable  # noqa: E402


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
