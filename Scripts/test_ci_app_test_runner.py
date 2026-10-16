#!/usr/bin/env python3
"""Pure self-tests for the CI app-test runner."""

from __future__ import annotations

import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import ci_app_test_runner as runner  # noqa: E402


class TestDiscoveryTests(unittest.TestCase):
    def test_parse_suite_methods_deduplicates_and_sorts(self) -> None:
        output = "\n".join(
            [
                "RepoPromptTests.SecondTests/testB",
                "noise",
                "RepoPromptTests.FirstTests/testZ",
                "RepoPromptTests.FirstTests/testA",
                "RepoPromptTests.FirstTests/testA",
            ]
        )

        self.assertEqual(
            runner.parse_suite_methods(output),
            {
                "RepoPromptTests.FirstTests": (
                    "RepoPromptTests.FirstTests/testA",
                    "RepoPromptTests.FirstTests/testZ",
                ),
                "RepoPromptTests.SecondTests": (
                    "RepoPromptTests.SecondTests/testB",
                ),
            },
        )

    def test_invalid_shard_arguments_are_rejected(self) -> None:
        invalid_arguments = ((0, 1), (2, 0), (2, 3))
        for shard_count, shard_index in invalid_arguments:
            with self.subTest(
                shard_count=shard_count,
                shard_index=shard_index,
            ):
                with self.assertRaises(ValueError):
                    runner.validate_shard_args(shard_count, shard_index)

        with self.assertRaisesRegex(ValueError, "greater than zero"):
            runner.assign_suites_to_shards({}, 0)

    def test_lpt_sharding_is_deterministic_balanced_and_exhaustive(self) -> None:
        counts = {
            "RepoPromptTests.A": 8,
            "RepoPromptTests.B": 7,
            "RepoPromptTests.C": 4,
            "RepoPromptTests.D": 3,
            "RepoPromptTests.E": 2,
        }

        shards, loads = runner.assign_suites_to_shards(counts, 2)

        self.assertEqual(loads, (13, 11))
        self.assertLessEqual(max(loads) - min(loads), 2)
        self.assertEqual(set(shards[0] + shards[1]), set(counts))
        self.assertEqual(
            runner.assign_suites_to_shards(dict(reversed(counts.items())), 2),
            (shards, loads),
        )

class TestBundleResolutionTests(unittest.TestCase):
    def test_discover_test_bundles_parses_show_bin_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bin_path = Path(directory)
            first = bin_path / "RepoPromptTests.xctest"
            second = bin_path / "RepoPromptCodeMapCoreTests.xctest"
            first.mkdir()
            second.mkdir()
            completed = subprocess.CompletedProcess(
                args=["swift", "build", "--show-bin-path"],
                returncode=0,
                stdout=f"{bin_path}\n",
                stderr="",
            )
            with mock.patch.object(runner.subprocess, "run", return_value=completed):
                discovered = runner.discover_test_bundles("swift", None)

        self.assertEqual(
            discovered,
            {
                "RepoPromptCodeMapCoreTests": second,
                "RepoPromptTests": first,
            },
        )

    def test_unique_package_bundle_is_preferred(self) -> None:
        package_bundle = Path("/tmp/RepoPromptPackageTests.xctest")
        discovered = {
            "RepoPromptPackageTests": package_bundle,
            "RepoPromptTests": Path("/tmp/RepoPromptTests.xctest"),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )

        self.assertEqual(selection.package_bundle, package_bundle)
        self.assertEqual(selection.target_bundles, {})

    def test_target_bundle_resolution_and_missing_target_diagnostic(self) -> None:
        root_bundle = Path("/tmp/RepoPromptTests.xctest")
        discovered = {
            "RepoPromptTests": root_bundle,
            "RepoPromptCodeMapCoreTests": Path(
                "/tmp/RepoPromptCodeMapCoreTests.xctest"
            ),
        }
        with mock.patch.object(
            runner,
            "discover_test_bundles",
            return_value=discovered,
        ), mock.patch.object(
            runner,
            "xctest_binary_path",
            return_value=("/usr/bin/xctest",),
        ):
            selection = runner.resolve_bundle_selection(
                swift_binary="swift",
                cwd=None,
                suites=("RepoPromptTests.ParserTests",),
            )
            with self.assertRaisesRegex(
                ValueError,
                r"missing XCTest bundles for selected targets: \['MissingTests'\]",
            ):
                runner.resolve_bundle_selection(
                    swift_binary="swift",
                    cwd=None,
                    suites=("MissingTests.ParserTests",),
                )

        self.assertEqual(
            selection.target_bundles,
            {"RepoPromptTests": root_bundle},
        )

    def test_command_construction_uses_xctest_or_swift_fallback(self) -> None:
        xctest_selection = runner.BundleSelection(
            None,
            {"RepoPromptTests": Path("/tmp/RepoPromptTests.xctest")},
            ("/usr/bin/xctest",),
        )
        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="swift",
                bundle_selection=xctest_selection,
            ),
            (
                "/usr/bin/xctest",
                "-XCTest",
                "RepoPromptTests.ParserContractTests",
                "/tmp/RepoPromptTests.xctest",
            ),
        )

        self.assertEqual(
            runner.command_for_suite(
                "RepoPromptTests.ParserContractTests",
                swift_binary="custom-swift",
                bundle_selection=runner.BundleSelection(None, {}, None),
            ),
            (
                "custom-swift",
                "test",
                "--skip-build",
                "--filter",
                "RepoPromptTests.ParserContractTests",
            ),
        )


class TestExecutionTests(unittest.TestCase):
    def empty_bundle_selection(self) -> runner.BundleSelection:
        return runner.BundleSelection(None, {}, None)

    def test_suite_environment_preserves_inherited_values_and_replaces_state(self) -> None:
        inherited = {
            "PATH": "/usr/bin",
            "CUSTOM_TOKEN": "preserved",
            "HOME": "/old/home",
            "CFFIXED_USER_HOME": "/old/fixed-home",
            "TMPDIR": "/old/tmpdir",
            "TMP": "/old/tmp",
            "TEMP": "/old/temp",
            "XDG_CONFIG_HOME": "/old/config",
            "XDG_CACHE_HOME": "/old/cache",
            "XDG_DATA_HOME": "/old/data",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.FirstTests",
                inherited,
            )
            second = runner.isolated_suite_environment(
                root,
                "RepoPromptTests.SecondTests",
                inherited,
            )

            self.assertNotEqual(first["HOME"], second["HOME"])
            self.assertEqual(first["HOME"], first["CFFIXED_USER_HOME"])
            self.assertEqual(first["TMPDIR"], first["TMP"])
            self.assertEqual(first["TMPDIR"], first["TEMP"])
            self.assertEqual(first["PATH"], "/usr/bin")
            self.assertEqual(first["CUSTOM_TOKEN"], "preserved")
            for key in (
                "HOME",
                "TMPDIR",
                "XDG_CONFIG_HOME",
                "XDG_CACHE_HOME",
                "XDG_DATA_HOME",
            ):
                self.assertTrue(Path(first[key]).is_dir(), key)
                self.assertNotEqual(first[key], inherited[key])

    def test_runner_stops_on_first_failure(self) -> None:
        calls: list[tuple[str, ...]] = []

        def executor(command, _cwd, _environment) -> int:
            calls.append(tuple(command))
            return 9

        with tempfile.TemporaryDirectory() as directory:
            result = runner.run_selected_suites(
                ("RepoPromptTests.FirstTests", "RepoPromptTests.SecondTests"),
                swift_binary="swift",
                cwd=None,
                bundle_selection=self.empty_bundle_selection(),
                sandbox_root=Path(directory),
                executor=executor,
                output=io.StringIO(),
            )

        self.assertEqual(result, 9)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][-1], "RepoPromptTests.FirstTests")


class LocalExecutionTests(unittest.TestCase):
    LISTED = [
        "RepoPromptTests.AlphaTests/testOne",
        "RepoPromptTests.AlphaTests/testTwo",
        "RepoPromptTests.BetaTests/testOne",
        "RepoPromptRegexCoreTests.RegexTests/testMatch",
    ]
    SANDBOXED = {
        "PATH": "/usr/bin",
        "REPOPROMPT_TEST_SANDBOX_ROOT": "/sandbox",
        "NSUnbufferedIO": "YES",
    }

    def test_flatten_matches_swiftpm_specifiers_and_skips_empty_suites(self) -> None:
        document = {"name": "All Tests", "tests": [{"name": "RepoPromptCEPackageTests.xctest", "tests": [
            {"name": "RepoPromptTests.AlphaTests", "tests": [{"name": "testTwo"}, {"name": "testOne"}]},
            {"name": "RepoPromptTests.EmptyTests", "tests": []},
        ]}]}
        only_empty = {"name": "All Tests", "tests": [{"name": "Pkg.xctest", "tests": [
            {"name": "M.EmptyA", "tests": []},
            {"name": "M.EmptyB", "tests": []},
        ]}]}

        self.assertEqual(
            runner.flatten_listed_tests(document),
            ["RepoPromptTests.AlphaTests/testOne", "RepoPromptTests.AlphaTests/testTwo"],
        )
        self.assertEqual(runner.flatten_listed_tests(only_empty), [])

    def test_select_uses_regex_search_and_collapses_whole_suites(self) -> None:
        select = runner.select_xctest_specifiers
        self.assertEqual(select(self.LISTED, None), ["All"])
        self.assertEqual(select([], None), [])
        self.assertEqual(select(self.LISTED, "AlphaTests"), ["RepoPromptTests.AlphaTests"])
        self.assertEqual(
            select(self.LISTED, "testOne"),
            ["RepoPromptTests.AlphaTests/testOne", "RepoPromptTests.BetaTests"],
        )
        self.assertEqual(
            select(self.LISTED, "Alpha|Regex"),
            ["RepoPromptRegexCoreTests.RegexTests", "RepoPromptTests.AlphaTests"],
        )
        self.assertEqual(
            select(self.LISTED, r"^RepoPromptTests\.AlphaTests/testTwo$"),
            ["RepoPromptTests.AlphaTests/testTwo"],
        )
        self.assertEqual(select(self.LISTED, "Nope"), [])

    def test_non_portable_filters_fall_back(self) -> None:
        for test_filter in (r"\d", "(?i)alpha", "Alpha{2}", "[[a]]", "[]a]", "[a&&b]", "(unclosed", "end\\"):
            with self.subTest(test_filter=test_filter):
                self.assertIsNone(runner.select_xctest_specifiers(self.LISTED, test_filter))
        for test_filter in ("Alpha.*One", "[AB]eta", "(Alpha|Beta)Tests", "testOne$", r"Tests\."):
            with self.subTest(test_filter=test_filter):
                self.assertIsNotNone(runner.select_xctest_specifiers(self.LISTED, test_filter))

    PACKAGE_BUNDLE = {"RepoPromptCEPackageTests": Path("/b/RepoPromptCEPackageTests.xctest")}
    # Swift Build, the default build system since Swift 6.4, builds one bundle per test target.
    TARGET_BUNDLES = {
        "RepoPromptTests": Path("/b/RepoPromptTests.xctest"),
        "RepoPromptRegexCoreTests": Path("/b/RepoPromptRegexCoreTests.xctest"),
    }

    def list_by_module(self, bundle: Path, _environment) -> list[str]:
        if bundle.stem.endswith("PackageTests"):
            return list(self.LISTED)
        return [specifier for specifier in self.LISTED if specifier.startswith(f"{bundle.stem}.")]

    def direct(self, root: Path, **overrides):
        options = dict(
            swift_binary="swift",
            cwd=root,
            test_filter="AlphaTests",
            environment=self.SANDBOXED,
            lister=self.list_by_module,
            bundle_discovery=lambda _swift, _cwd: self.PACKAGE_BUNDLE,
            xctest_binary=lambda: ("/x/xctest",),
        )
        options.update(overrides)
        return runner.direct_xctest_commands(**options)

    def test_direct_commands_run_bundles_unless_equivalence_is_not_guaranteed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(
                self.direct(root),
                [("/x/xctest", "-XCTest", "RepoPromptTests.AlphaTests", "/b/RepoPromptCEPackageTests.xctest")],
            )
            self.assertEqual(self.direct(root, test_filter="Nope"), [])
            self.assertIsNone(self.direct(root, bundle_discovery=lambda _swift, _cwd: {}))
            self.assertIsNone(self.direct(root, lister=lambda _bundle, _environment: None))
            # An empty listing would otherwise pass every job without running a test.
            self.assertIsNone(self.direct(root, test_filter=None, lister=lambda _bundle, _environment: []))
            self.assertIsNone(self.direct(root, test_filter=r"\d"))
            tests = root / "Tests" / "NewTests"
            tests.mkdir(parents=True)
            (tests / "SwiftTestingTests.swift").write_text("public import Testing\n", encoding="utf-8")
            self.assertIsNone(self.direct(root))

    def test_direct_commands_launch_only_target_bundles_with_selected_tests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            per_target = dict(bundle_discovery=lambda _swift, _cwd: self.TARGET_BUNDLES)
            self.assertEqual(
                self.direct(Path(directory), test_filter="Regex", **per_target),
                [("/x/xctest", "-XCTest", "RepoPromptRegexCoreTests.RegexTests", "/b/RepoPromptRegexCoreTests.xctest")],
            )
            self.assertEqual(
                self.direct(Path(directory), test_filter=None, **per_target),
                [
                    ("/x/xctest", "-XCTest", "All", "/b/RepoPromptRegexCoreTests.xctest"),
                    ("/x/xctest", "-XCTest", "All", "/b/RepoPromptTests.xctest"),
                ],
            )

    def run_local(
        self,
        direct,
        *,
        build_status: int = 0,
        bundle_statuses: dict[str, int] | None = None,
        test_product: str | None = None,
    ):
        calls: list[tuple[tuple[str, ...], dict[str, str]]] = []

        def executor(command, _cwd, environment) -> int:
            calls.append((tuple(command), dict(environment)))
            if tuple(command[1:2]) == ("build",):
                return build_status
            return (bundle_statuses or {}).get(command[-1], 0)

        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin"}, clear=True), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout:
            status = runner.run_local_tests(
                swift_binary="swift",
                cwd=None,
                sandbox_root="/sandbox",
                test_filter="S",
                test_product=test_product,
                executor=executor,
                direct_commands=direct,
            )
        return status, calls, stdout.getvalue()

    def test_run_local_tests_builds_clean_then_runs_bundles_in_sandbox(self) -> None:
        listed_with: dict[str, str] = {}
        bundles = [("/x/xctest", "-XCTest", "S", "/a.xctest"), ("/x/xctest", "-XCTest", "S", "/b.xctest")]

        def direct(**kwargs):
            listed_with.update(kwargs["environment"])
            return bundles

        status, calls, output = self.run_local(direct, bundle_statuses={"/a.xctest": 3})

        self.assertEqual(calls[0], (("swift", "build", "--build-tests"), {"PATH": "/usr/bin"}))
        self.assertEqual(calls[1:], [(command, self.SANDBOXED) for command in bundles])
        # The listing helper loads test code, so it gets the sandbox too.
        self.assertEqual(listed_with, self.SANDBOXED)
        # A failing bundle fails the run even though the later bundle, which still runs, passes.
        self.assertEqual(status, 3)
        self.assertIn("$ /x/xctest -XCTest S /b.xctest", output)

    def test_run_local_tests_stops_after_failed_build(self) -> None:
        direct = mock.Mock()

        status, calls, _ = self.run_local(direct, build_status=1)

        self.assertEqual(status, 1)
        self.assertEqual(len(calls), 1)
        direct.assert_not_called()

    def test_run_local_tests_reports_no_match_without_launching(self) -> None:
        status, calls, output = self.run_local(lambda **_kwargs: [])

        self.assertEqual(status, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("No matching test cases were run", output)

    def test_run_local_tests_falls_back_to_swiftpm(self) -> None:
        _, calls, _ = self.run_local(lambda **_kwargs: None)
        self.assertEqual(calls[1], (("swift", "test", "--skip-build", "--filter", "S"), self.SANDBOXED))

        direct = mock.Mock()
        _, calls, _ = self.run_local(direct, test_product="RepoPromptPackageTests")
        direct.assert_not_called()
        self.assertEqual(
            calls[1][0],
            ("swift", "test", "--skip-build", "--test-product", "RepoPromptPackageTests", "--filter", "S"),
        )

    def test_local_mode_takes_the_sandbox_out_of_its_own_environment(self) -> None:
        seen: dict[str, object] = {}

        def run_local_tests(**kwargs) -> int:
            seen.update(kwargs, environ=dict(runner.os.environ))
            return -15

        sandboxed = {"PATH": "/usr/bin", "REPOPROMPT_TEST_SANDBOX_ROOT": " /sandbox\n"}
        with mock.patch.dict(runner.os.environ, sandboxed, clear=True), \
                mock.patch.object(runner, "run_local_tests", side_effect=run_local_tests):
            status = runner.main(["--local", "--filter", "S"])

        # SwiftPM commands the runner starts inherit its environment, so the sandbox must be gone.
        self.assertEqual(seen["environ"], {"PATH": "/usr/bin"})
        self.assertEqual(seen["sandbox_root"], "/sandbox")
        self.assertEqual(status, 128 + 15)
        with mock.patch.dict(runner.os.environ, {"PATH": "/usr/bin"}, clear=True), \
                mock.patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(runner.main(["--local"]), 2)


if __name__ == "__main__":
    unittest.main()
