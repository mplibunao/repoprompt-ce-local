#!/usr/bin/env python3
"""Focused regression tests for contribution preflight remote policy."""

from __future__ import annotations

import os
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
PREFLIGHT_SOURCE = REPO_ROOT / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"


def write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ContributionPreflightRemoteGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()

        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        self.git("config", "user.name", "Preflight Test")
        self.git("config", "user.email", "preflight@example.invalid")

        self.preflight = self.repo / ".agents/skills/rpce-contribution-check/scripts/preflight.sh"
        self.preflight.parent.mkdir(parents=True)
        shutil.copy2(PREFLIGHT_SOURCE, self.preflight)

        (self.repo / "Makefile").write_text("guardrails:\n\t@:\n", encoding="utf-8")
        (self.repo / "README.md").write_text("fixture\n", encoding="utf-8")

        self.bin_dir = self.repo / ".test-bin"
        self.bin_dir.mkdir()
        write_executable(self.bin_dir / "gitleaks", "#!/bin/sh\nexit 0\n")

        self.git("add", ".")
        self.git("commit", "-q", "-m", "fixture baseline")

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repo,
            text=True,
            capture_output=True,
            check=True,
        )

    def prepare_push_branch(self) -> None:
        self.git("remote", "add", "origin", "https://example.invalid/origin.git")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("switch", "-q", "-c", "port/123-fixture")

    def install_config_sensitive_gitleaks(self) -> None:
        write_executable(
            self.bin_dir / "gitleaks",
            "#!/bin/sh\n"
            'config=""\n'
            'target=""\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    --config) config="$2"; shift 2 ;;\n'
            '    *) target="$1"; shift ;;\n'
            "  esac\n"
            "done\n"
            'if [ -n "$config" ] && grep -q "^allow_all = true$" "$config"; then exit 0; fi\n'
            'if grep -R -q "staged-secret-value" "$target"; then exit 1; fi\n'
            "exit 0\n",
        )

    def commit_strict_gitleaks_config(self) -> Path:
        config = self.repo / ".gitleaks.toml"
        config.write_text("allow_all = false\n", encoding="utf-8")
        self.git("add", ".gitleaks.toml")
        self.git("commit", "-q", "-m", "add strict gitleaks config")
        return config

    def run_preflight(self, mode: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env['PATH']}"
        return subprocess.run(
            [str(self.preflight), mode],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    @staticmethod
    def output(result: subprocess.CompletedProcess[str]) -> str:
        return result.stdout + result.stderr

    def test_commit_allows_repository_without_remotes(self) -> None:
        result = self.run_preflight("commit")

        self.assertEqual(result.returncode, 0, self.output(result))

    def test_commit_allows_origin_only_repository(self) -> None:
        self.git("remote", "add", "origin", "https://example.invalid/origin.git")

        result = self.run_preflight("commit")

        self.assertEqual(result.returncode, 0, self.output(result))

    def test_commit_ignores_unstaged_gitleaks_allowlist_broadening(self) -> None:
        self.install_config_sensitive_gitleaks()
        config = self.commit_strict_gitleaks_config()
        secret = self.repo / "secret.txt"
        secret.write_text("staged-secret-value\n", encoding="utf-8")
        self.git("add", "secret.txt")
        config.write_text("allow_all = true\n", encoding="utf-8")

        result = self.run_preflight("commit")

        self.assertNotEqual(result.returncode, 0, self.output(result))

    def test_commit_honours_staged_gitleaks_config_change(self) -> None:
        self.install_config_sensitive_gitleaks()
        config = self.commit_strict_gitleaks_config()
        secret = self.repo / "secret.txt"
        secret.write_text("staged-secret-value\n", encoding="utf-8")
        config.write_text("allow_all = true\n", encoding="utf-8")
        self.git("add", "secret.txt", ".gitleaks.toml")

        result = self.run_preflight("commit")

        self.assertEqual(result.returncode, 0, self.output(result))

    def test_commit_rejects_and_names_non_origin_remote(self) -> None:
        self.git("remote", "add", "origin", "https://example.invalid/origin.git")
        self.git("remote", "add", "upstream", "https://example.invalid/upstream.git")

        result = self.run_preflight("commit")

        self.assertNotEqual(result.returncode, 0, self.output(result))
        self.assertIn("upstream", self.output(result))
        self.assertIn("only 'origin' is allowed", self.output(result))

    def test_commit_fails_closed_when_git_remote_listing_fails(self) -> None:
        self.git("remote", "add", "origin", "https://example.invalid/origin.git")
        self.git("remote", "add", "upstream", "https://example.invalid/upstream.git")

        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        write_executable(
            self.bin_dir / "git",
            "#!/bin/sh\n"
            'if [ "$#" -eq 1 ] && [ "$1" = remote ]; then exit 128; fi\n'
            f'exec {shlex.quote(str(real_git))} "$@"\n',
        )

        result = self.run_preflight("commit")

        self.assertNotEqual(result.returncode, 0, self.output(result))
        self.assertIn("failed to list Git remotes", self.output(result))
        self.assertNotIn("unexpected Git remote(s)", self.output(result))

    def test_push_reports_origin_main_fallback_provenance(self) -> None:
        self.prepare_push_branch()

        result = self.run_preflight("push")

        self.assertEqual(result.returncode, 0, self.output(result))
        self.assertIn("Comparison base provenance: origin_main_fallback", self.output(result))

    def test_push_rejects_and_names_non_origin_remote(self) -> None:
        self.prepare_push_branch()
        self.git("remote", "add", "upstream", "https://example.invalid/upstream.git")

        result = self.run_preflight("push")

        self.assertNotEqual(result.returncode, 0, self.output(result))
        self.assertIn("unexpected Git remote(s): upstream", self.output(result))


if __name__ == "__main__":
    unittest.main()
