#!/usr/bin/env python3
"""Check project tool selection without installing developer tools."""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from script_test_support import write_bash_stub


class SwiftStyleToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        scripts = self.repo / "Scripts"
        scripts.mkdir(parents=True)
        for name in ("install_format_tools.sh", "swift_style.sh"):
            shutil.copy2(Path(__file__).parent / name, scripts / name)
        shutil.copy2(Path(__file__).parent.parent / "mise.toml", self.repo / "mise.toml")
        for directory in (
            "Sources/RepoPrompt", "Sources/RepoPromptExecutable", "Sources/RepoPromptMCP",
            "Sources/RepoPromptShared", "Tests/RepoPromptTests",
            "Packages/RepoPromptAgentProviders/Sources", "Packages/RepoPromptAgentProviders/Tests",
        ):
            (self.repo / directory).mkdir(parents=True)
        for name in ("Package.swift", "Packages/RepoPromptAgentProviders/Package.swift"):
            (self.repo / name).write_text("// fixture\n")

        self.bin = self.root / "bin"
        self.managed = self.root / "managed"
        self.ready = self.root / "installed"
        self.ready.touch()
        self.log = self.root / "calls"
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FIXTURE_REPO": str(self.repo),
            "FIXTURE_MANAGED": str(self.managed),
            "FIXTURE_READY": str(self.ready),
            "FIXTURE_LOG": str(self.log),
        }
        for tool in ("swiftformat", "swiftlint"):
            write_bash_stub(self.managed, tool, 'echo "$(basename "$0") $*" >> "$FIXTURE_LOG"')
            write_bash_stub(self.bin, tool, "exit 91")
        write_bash_stub(self.bin, "mise", '''
            [[ "$1" == -C && "$2" == "$FIXTURE_REPO" ]] || exit 92
            shift 2
            case "$1" in
                which)
                    [[ -f "$FIXTURE_READY" ]] || exit 1
                    case "$2" in
                        swiftformat) backend='github:nicklockwood/SwiftFormat' ;;
                        swiftlint) backend='aqua:realm/SwiftLint' ;;
                    esac
                    if [[ "${3:-}" == --tool && "${4:-}" == "$backend" ]]; then
                        echo "$FIXTURE_MANAGED/$2"
                    else
                        command -v "$2"
                    fi
                    ;;
                install)
                    [[ "$*" == 'install github:nicklockwood/SwiftFormat aqua:realm/SwiftLint' ]] || exit 93
                    echo install >> "$FIXTURE_LOG"
                    touch "$FIXTURE_READY"
                    ;;
                *) exit 94 ;;
            esac
        ''')

    def run_script(self, script: str, action: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.repo / "Scripts" / script), action], cwd=self.root,
            env=self.env, text=True, capture_output=True, timeout=10,
        )

    def test_lint_uses_project_tools_when_global_tools_conflict(self) -> None:
        result = self.run_script("swift_style.sh", "lint")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(calls[0].startswith("swiftformat "), calls)
        self.assertTrue(calls[1].startswith("swiftlint "), calls)

    def test_missing_project_tools_do_not_fall_back_or_install_during_checks(self) -> None:
        self.ready.unlink()
        for action in ("status", "check", "resolve-swiftformat", "resolve-swiftlint"):
            with self.subTest(action=action):
                result = self.run_script("install_format_tools.sh", action)
                self.assertEqual(result.returncode == 0, action == "status", result.stderr)
                self.assertIn("make dev-install-format-tools", result.stdout + result.stderr)
                self.assertFalse(self.ready.exists())
                self.assertFalse(self.log.exists())

    def test_install_provisions_both_project_tools(self) -> None:
        self.ready.unlink()
        result = self.run_script("install_format_tools.sh", "install")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.ready.exists())
        self.assertEqual(self.log.read_text().splitlines()[0], "install")


if __name__ == "__main__":
    unittest.main()
