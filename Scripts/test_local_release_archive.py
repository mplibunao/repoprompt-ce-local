#!/usr/bin/env python3
"""Offline round-trip tests for the local release rollback unit.

Every case runs `local_release_archive.sh` and `local_release_restore.sh` against a
synthetic app bundle, state tree, preferences domain, and identity record inside a
temporary directory, so the real install at /Applications and the real Application
Support tree are never read or written.
"""

from __future__ import annotations

import filecmp
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
ARCHIVE_SCRIPT = SCRIPT_DIR / "local_release_archive.sh"
RESTORE_SCRIPT = SCRIPT_DIR / "local_release_restore.sh"
ENV_SCRIPT = SCRIPT_DIR / "local_release_env.sh"
PACKAGE_SCRIPT = SCRIPT_DIR / "package_app.sh"
JOURNAL_SCHEMA_TOOL = SCRIPT_DIR / "read_working_journal_schema_version.py"
INFO_PLIST_TEMPLATE = ROOT_DIR / "AppBundle" / "Info.plist.template"
DISPLAY_NAME = "RepoPrompt CE"
TAG = "local/v1.4.0-b99"
JOURNAL_SOURCE_PATH = Path("Sources/RepoPromptDomainRuntime/DomainPersistence.swift")


def tree_snapshot(root: Path) -> dict[str, str | None]:
    """Relative path -> file contents (None for directories), for exact-tree comparison."""
    snapshot: dict[str, str | None] = {}
    for path in sorted(root.rglob("*")):
        key = str(path.relative_to(root))
        snapshot[key] = None if path.is_dir() and not path.is_symlink() else path.read_text(encoding="utf-8")
    return snapshot


class LocalReleaseRollbackUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="repoprompt-ce-rollback-test."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.install_dir = self.tmp / "Applications"
        self.app = self.install_dir / f"{DISPLAY_NAME}.app"
        self.state = self.tmp / "Application Support" / DISPLAY_NAME
        self.archive_root = self.tmp / "Archives"
        self.defaults_domain = self.tmp / "prefs" / "com.example.repoprompt.ce.test"
        self.identity_path = self.state / "local-signing-identity-v1.json"
        self.defaults_domain.parent.mkdir(parents=True, exist_ok=True)
        self.process_token = f"repoprompt-ce-guard-{self.tmp.name}"
        self.source_repository = self.tmp / "source-repository"
        subprocess.run(["git", "init", "-q", str(self.source_repository)], check=True, capture_output=True)
        self.archived_commit = self.commit_journal_source(
            "struct DomainWorkingJournal: Codable {\n"
            "    static let schemaVersion = 1\n"
            "}\n"
        )

    # -- fixtures ---------------------------------------------------------------

    def commit_journal_source(self, source: str) -> str:
        path = self.source_repository / JOURNAL_SOURCE_PATH
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        subprocess.run(
            ["git", "-C", str(self.source_repository), "add", str(JOURNAL_SOURCE_PATH)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(self.source_repository),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "journal schema fixture",
            ],
            check=True,
            capture_output=True,
        )
        return subprocess.run(
            ["git", "-C", str(self.source_repository), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def write_app(
        self,
        *,
        build: str,
        commit: str | None,
        dirty: bool | None = False,
        git_status: str | None = "ok",
        journal_schema_version: int | None = 1,
    ) -> None:
        resources = self.app / "Contents" / "Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (self.app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
        (self.app / "Contents" / "MacOS" / "RepoPrompt").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        info = {
            "CFBundleIdentifier": "com.pvncher.repoprompt.ce",
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": build,
            "RepoPromptSigningMode": "local-self-signed",
        }
        if journal_schema_version is not None:
            info["RepoPromptWorkingJournalSchemaVersion"] = journal_schema_version
        with (self.app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        provenance = resources / "RepoPromptProvenance.json"
        if commit is None:
            provenance.unlink(missing_ok=True)
        else:
            payload = {
                "version": 1,
                "commit": commit,
                "dirty": dirty,
                "git_status": git_status,
                "buildTimeISO": "2026-09-10T00:00:00+02:00",
            }
            provenance.write_text(json.dumps(payload), encoding="utf-8")

    def write_state(self, marker: str) -> None:
        for name in ("Settings", "Workspaces", "DebugApps", "Rollbacks"):
            (self.state / name).mkdir(parents=True, exist_ok=True)
        (self.state / "Settings" / "globalSettings.json").write_text(f'{{"marker":"{marker}"}}\n', encoding="utf-8")
        (self.state / "Workspaces" / "one.json").write_text(f"workspace-{marker}\n", encoding="utf-8")
        # Exact-name exclusions apply only at the top level, so nested content with the
        # same name remains part of the rollback unit.
        (self.state / "Workspaces" / "inner" / "DebugApps").mkdir(parents=True, exist_ok=True)
        (self.state / "Workspaces" / "inner" / "DebugApps" / "nested.json").write_text(
            f"nested-{marker}\n", encoding="utf-8"
        )
        (self.state / "DebugApps" / "marker.txt").write_text(f"debug-{marker}\n", encoding="utf-8")
        (self.state / "Rollbacks" / "marker.txt").write_text(f"rollback-{marker}\n", encoding="utf-8")
        self.identity_path.write_text(
            json.dumps(
                {
                    "certificateName": "RepoPrompt CE Local Self-Signed Code Signing",
                    "certificateSHA256": "A" * 64,
                    "schemaVersion": 1,
                    "serviceGeneration": 42,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def write_defaults(self, pairs: dict[str, str]) -> None:
        self.run_defaults(["delete", str(self.defaults_domain)], check=False)
        for key, value in pairs.items():
            self.run_defaults(["write", str(self.defaults_domain), key, "-string", value])

    def write_baseline_fixture(
        self,
        *,
        defaults: dict[str, str] | None = None,
        dirty: bool | None = False,
        git_status: str | None = "ok",
        journal_schema_version: int | None = 1,
    ) -> None:
        self.write_app(
            build="38",
            commit=self.archived_commit,
            dirty=dirty,
            git_status=git_status,
            journal_schema_version=journal_schema_version,
        )
        self.write_state("original")
        effective_defaults = {"UpdateChannel": "stable"} if defaults is None else defaults
        self.write_defaults(effective_defaults)

    def read_defaults(self) -> dict[str, object]:
        export = self.tmp / "defaults-readback.plist"
        self.run_defaults(["export", str(self.defaults_domain), str(export)])
        with export.open("rb") as handle:
            return plistlib.load(handle)

    def run_defaults(self, arguments: list[str], *, check: bool = True) -> None:
        subprocess.run(["defaults", *arguments], check=check, capture_output=True)

    # -- script drivers ---------------------------------------------------------

    def environment(self, **overrides: str) -> dict[str, str]:
        env = dict(os.environ)
        env.update(
            {
                "LOCAL_PRODUCTION_INSTALL_DIR": str(self.install_dir),
                "LOCAL_PRODUCTION_APP": str(self.app),
                "LOCAL_APP_SUPPORT_DIR": str(self.state),
                "LOCAL_DEFAULTS_DOMAIN": str(self.defaults_domain),
                "LOCAL_RELEASE_ARCHIVE_ROOT": str(self.archive_root),
                "LOCAL_SIGNING_IDENTITY_REGISTRY_PATH": str(self.identity_path),
                "LOCAL_RELEASE_SOURCE_REPOSITORY": str(self.source_repository),
                # A per-test token so the guard runs for real without matching the
                # operator's live RepoPrompt processes.
                "LOCAL_RELEASE_RUNNING_PROCESS_PATTERNS": self.process_token,
            }
        )
        env.update(overrides)
        return env

    def run_script(self, script: Path, tag: str = TAG, **overrides: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(script), tag],
            cwd=ROOT_DIR,
            env=self.environment(**overrides),
            capture_output=True,
            text=True,
        )

    def archive(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        result = self.run_script(ARCHIVE_SCRIPT, **overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def restore(self, **overrides: str) -> subprocess.CompletedProcess[str]:
        result = self.run_script(RESTORE_SCRIPT, **overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def manifest(self) -> dict:
        return json.loads((self.archive_root / TAG / "manifest.json").read_text(encoding="utf-8"))

    # -- tests ------------------------------------------------------------------

    def test_package_contract_embeds_working_journal_schema_version(self) -> None:
        template = INFO_PLIST_TEMPLATE.read_text(encoding="utf-8")
        package_script = PACKAGE_SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            "<key>RepoPromptWorkingJournalSchemaVersion</key>"
            "<string>__WORKING_JOURNAL_SCHEMA_VERSION__</string>",
            template,
        )
        self.assertIn("WORKING_JOURNAL_SCHEMA_VERSION=", package_script)
        self.assertIn(
            "'<string>__WORKING_JOURNAL_SCHEMA_VERSION__</string>':"
            "'<integer>$WORKING_JOURNAL_SCHEMA_VERSION</integer>'",
            package_script,
        )
        self.assertIn('read_working_journal_schema_version.py" "$ROOT_DIR"', package_script)
        self.assertIn(
            '[[ "$PACKAGED_WORKING_JOURNAL_SCHEMA_VERSION_TYPE" == "integer" ]]',
            package_script,
        )
        self.assertIn(
            "expected exactly one integer DomainWorkingJournal.schemaVersion",
            JOURNAL_SCHEMA_TOOL.read_text(encoding="utf-8"),
        )

    def test_round_trip_reproduces_app_state_defaults_and_identity(self) -> None:
        self.write_baseline_fixture(defaults={"UpdateChannel": "stable", "RemovedLater": "yes"})
        app_before = tree_snapshot(self.app)
        state_before = tree_snapshot(self.state)

        self.archive()

        # Diverge every restored surface, including keys the newer build would have added.
        self.write_app(build="39", commit="f" * 40)
        (self.state / "Settings" / "globalSettings.json").write_text('{"marker":"mutated"}\n', encoding="utf-8")
        (self.state / "Workspaces" / "one.json").unlink()
        (self.state / "Workspaces" / "added-later.json").write_text("stray\n", encoding="utf-8")
        self.identity_path.write_text("{}\n", encoding="utf-8")
        self.write_defaults({"UpdateChannel": "tip", "AddedLater": "yes"})
        # Uncaptured directories carry post-archive content that must survive the restore.
        (self.state / "DebugApps" / "marker.txt").write_text("debug-after\n", encoding="utf-8")
        (self.state / "Rollbacks" / "marker.txt").write_text("rollback-after\n", encoding="utf-8")

        self.restore()

        self.assertEqual(tree_snapshot(self.app), app_before)
        restored_state = tree_snapshot(self.state)
        for name, expected in state_before.items():
            if name.startswith(("DebugApps", "Rollbacks")):
                continue
            self.assertEqual(restored_state.get(name), expected, name)
        self.assertNotIn("Workspaces/added-later.json", restored_state)
        self.assertEqual(restored_state["DebugApps/marker.txt"], "debug-after\n")
        self.assertEqual(restored_state["Rollbacks/marker.txt"], "rollback-after\n")
        self.assertEqual(self.read_defaults(), {"UpdateChannel": "stable", "RemovedLater": "yes"})

    def test_manifest_records_tag_build_commit_and_timestamps(self) -> None:
        self.write_baseline_fixture()

        self.archive()
        manifest = self.manifest()

        self.assertEqual(manifest["tag"], TAG)
        self.assertEqual(manifest["app"]["build"], "38")
        self.assertEqual(manifest["app"]["commit"], self.archived_commit)
        self.assertEqual(manifest["app"]["signingMode"], "local-self-signed")
        self.assertEqual(
            manifest["applicationSupport"]["excludedNames"],
            ["DebugApps", "Rollbacks", "Conductor", "DebugApps-*"],
        )
        self.assertTrue(manifest["localSigningIdentity"]["archived"])
        self.assertIsInstance(manifest["archivedAtEpoch"], float)
        self.assertTrue(manifest["archivedAtISO"])
        for name in ("app.zip", "application-support.tar.gz", "defaults.plist"):
            self.assertEqual(len(manifest["files"][name]["sha256"]), 64, name)

    def test_bundle_schema_takes_priority_over_observed_journal_versions(self) -> None:
        self.write_baseline_fixture(journal_schema_version=1)
        journals = self.state / "DomainRuntime" / "v1" / "release-profile" / "working-journals"
        journals.mkdir(parents=True)
        (journals / "00000000-0000-0000-0000-000000000001.json").write_text(
            json.dumps({"version": 2}), encoding="utf-8"
        )

        self.archive()
        manifest = self.manifest()

        self.assertEqual(manifest["working_journal_schema_version"], 1)
        self.assertEqual(manifest["working_journal_schema_version_status"], "from_bundle")
        self.assertEqual(manifest["provenance_commit_working_journal_schema_version"], 1)
        self.assertEqual(manifest["observed_working_journal_versions"], [2])

    def test_clean_provenance_commit_supplies_legacy_bundle_schema(self) -> None:
        self.write_baseline_fixture(journal_schema_version=None)
        journals = self.state / "DomainRuntime" / "v1" / "release-profile" / "working-journals"
        journals.mkdir(parents=True)
        for index, version in enumerate((1, 2), start=1):
            name = f"00000000-0000-0000-0000-{index:012d}.json"
            (journals / name).write_text(json.dumps({"version": version}), encoding="utf-8")

        self.archive()
        manifest = self.manifest()

        self.assertEqual(manifest["working_journal_schema_version"], 1)
        self.assertEqual(manifest["working_journal_schema_version_status"], "from_commit")
        self.assertEqual(manifest["provenance_commit_working_journal_schema_version"], 1)
        self.assertEqual(manifest["observed_working_journal_versions"], [1, 2])

    def test_excluded_domain_runtime_still_reports_live_observed_journal_versions(self) -> None:
        self.write_baseline_fixture()
        journals = self.state / "DomainRuntime" / "v1" / "release-profile" / "working-journals"
        journals.mkdir(parents=True)
        (journals / "00000000-0000-0000-0000-000000000001.json").write_text(
            json.dumps({"version": 2}), encoding="utf-8"
        )

        self.archive(LOCAL_RELEASE_ARCHIVE_EXCLUDES="DebugApps:Rollbacks:Conductor:DomainRuntime")
        manifest = self.manifest()
        listing = subprocess.run(
            ["tar", "-tzf", str(self.archive_root / TAG / "application-support.tar.gz")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()

        top_level = {entry.removeprefix("./").split("/", 1)[0] for entry in listing}
        self.assertEqual(manifest["observed_working_journal_versions"], [2])
        self.assertNotIn("DomainRuntime", top_level)

    def test_manifest_records_unreadable_journal_without_aborting_archive(self) -> None:
        self.write_baseline_fixture()
        journals = self.state / "DomainRuntime" / "v1" / "release-profile" / "working-journals"
        journals.mkdir(parents=True)
        valid_name = "00000000-0000-0000-0000-000000000001.json"
        unreadable_name = "00000000-0000-0000-0000-000000000002.json"
        (journals / valid_name).write_text(json.dumps({"version": 2}), encoding="utf-8")
        (journals / unreadable_name).write_text('{"version":', encoding="utf-8")

        self.archive()
        manifest_path = self.archive_root / TAG / "manifest.json"
        manifest = self.manifest()

        self.assertTrue(manifest_path.is_file())
        self.assertEqual(manifest["observed_working_journal_versions"], [2])
        self.assertEqual(
            manifest["unreadable_working_journals"],
            [f"DomainRuntime/v1/release-profile/working-journals/{unreadable_name}"],
        )

    def test_manifest_records_no_observed_versions_when_no_working_journal_exists(self) -> None:
        self.write_baseline_fixture()

        self.archive()
        manifest = self.manifest()

        self.assertEqual(manifest["working_journal_schema_version"], 1)
        self.assertEqual(manifest["observed_working_journal_versions"], [])
        self.assertEqual(manifest["unreadable_working_journals"], [])

    def test_missing_bundle_schema_provenance_and_journals_records_unknown(self) -> None:
        self.write_app(build="37", commit=None, journal_schema_version=None)
        self.write_state("original")
        self.write_defaults({"UpdateChannel": "stable"})

        self.archive()
        manifest = self.manifest()

        self.assertIsNone(manifest["working_journal_schema_version"])
        self.assertEqual(manifest["working_journal_schema_version_status"], "unknown")
        self.assertIsNone(manifest["provenance_commit_working_journal_schema_version"])

    def test_dirty_provenance_and_journals_do_not_guess_archived_schema(self) -> None:
        self.write_baseline_fixture(dirty=True, journal_schema_version=None)
        journals = self.state / "DomainRuntime" / "v1" / "release-profile" / "working-journals"
        journals.mkdir(parents=True)
        (journals / "00000000-0000-0000-0000-000000000001.json").write_text(
            json.dumps({"version": 2}), encoding="utf-8"
        )

        self.archive()
        manifest = self.manifest()

        self.assertIsNone(manifest["working_journal_schema_version"])
        self.assertEqual(manifest["working_journal_schema_version_status"], "unknown")
        self.assertIsNone(manifest["provenance_commit_working_journal_schema_version"])
        self.assertEqual(manifest["observed_working_journal_versions"], [2])

    def test_archive_excludes_debug_apps_and_rollbacks_from_the_state_tarball(self) -> None:
        self.write_baseline_fixture()

        self.archive()

        listing = subprocess.run(
            ["tar", "-tzf", str(self.archive_root / TAG / "application-support.tar.gz")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        self.assertTrue(any(entry.endswith("Settings/globalSettings.json") for entry in listing))
        # Exclusion matching applies only to top-level entries.
        top_level = {entry.split("/")[1] for entry in listing if entry.startswith("./") and len(entry.split("/")) > 1}
        self.assertNotIn("DebugApps", top_level)
        self.assertNotIn("Rollbacks", top_level)
        self.assertIn("Settings", top_level)
        self.assertIn("Workspaces", top_level)

    def test_prefix_exclusion_survives_restore_with_post_archive_content(self) -> None:
        self.write_baseline_fixture()
        preserved = self.state / "DebugApps-foo-preserved"
        preserved.mkdir()
        marker = preserved / "marker.txt"
        marker.write_text("before-archive\n", encoding="utf-8")

        self.archive()
        listing = subprocess.run(
            ["tar", "-tzf", str(self.archive_root / TAG / "application-support.tar.gz")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertNotIn("./DebugApps-foo-preserved/", listing)

        marker.write_text("after-archive\n", encoding="utf-8")
        self.restore()

        self.assertEqual(marker.read_text(encoding="utf-8"), "after-archive\n")

    def test_restore_succeeds_when_current_state_directory_is_absent(self) -> None:
        self.write_baseline_fixture(defaults={"UpdateChannel": "stable", "RemovedLater": "yes"})
        app_before = tree_snapshot(self.app)
        identity_before = self.identity_path.read_text(encoding="utf-8")
        self.archive()

        shutil.rmtree(self.state)
        self.write_app(build="39", commit="f" * 40)
        self.write_defaults({"UpdateChannel": "tip", "AddedLater": "yes"})

        result = self.restore()

        self.assertNotIn("Enumerating excluded Application Support entries", result.stdout)
        self.assertEqual(tree_snapshot(self.app), app_before)
        self.assertEqual(
            (self.state / "Settings" / "globalSettings.json").read_text(encoding="utf-8"),
            '{"marker":"original"}\n',
        )
        self.assertEqual((self.state / "Workspaces" / "one.json").read_text(encoding="utf-8"), "workspace-original\n")
        self.assertEqual(self.identity_path.read_text(encoding="utf-8"), identity_before)
        self.assertEqual(self.read_defaults(), {"UpdateChannel": "stable", "RemovedLater": "yes"})

    def test_restore_fails_when_excluded_entry_enumeration_fails(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        stub_dir = self.tmp / "failing-find"
        stub_dir.mkdir()
        find_stub = stub_dir / "find"
        find_stub.write_text("#!/bin/sh\nexit 73\n", encoding="utf-8")
        find_stub.chmod(0o755)

        result = self.run_script(RESTORE_SCRIPT, PATH=f"{stub_dir}:{os.environ['PATH']}")
        output = result.stdout + result.stderr

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not enumerate excluded entries", output)
        self.assertNotIn(f"\nRestored {TAG}", output)
        rescues = sorted(self.archive_root.glob("**/*.rescue-*"))
        self.assertEqual(len(rescues), 1, output)
        self.assertTrue((rescues[0] / "application-support" / "DebugApps").is_dir())

    def test_archive_refuses_identity_records_carrying_key_material(self) -> None:
        self.write_baseline_fixture()
        self.identity_path.write_text(json.dumps({"certificateName": "x", "privateKeyPEM": "-----BEGIN"}), encoding="utf-8")

        result = self.run_script(ARCHIVE_SCRIPT)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("key material", result.stdout + result.stderr)
        self.assertFalse((self.archive_root / TAG / "manifest.json").exists())

    def test_restore_refuses_a_corrupted_archive(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        app_zip = self.archive_root / TAG / "app.zip"
        app_zip.write_bytes(app_zip.read_bytes() + b"corrupt")
        state_before = tree_snapshot(self.state)

        result = self.run_script(RESTORE_SCRIPT)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stdout + result.stderr)
        self.assertEqual(tree_snapshot(self.state), state_before)

    def test_restore_refuses_an_incomplete_archive(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        (self.archive_root / TAG / "manifest.json").unlink()

        result = self.run_script(RESTORE_SCRIPT)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest.json", result.stdout + result.stderr)

    def test_archive_refuses_to_overwrite_a_completed_archive_without_opt_in(self) -> None:
        self.write_baseline_fixture()
        self.archive()

        result = self.run_script(ARCHIVE_SCRIPT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LOCAL_RELEASE_ARCHIVE_OVERWRITE", result.stdout + result.stderr)

        self.archive(LOCAL_RELEASE_ARCHIVE_OVERWRITE="1")

    def test_both_scripts_refuse_path_escaping_tags(self) -> None:
        self.write_baseline_fixture()
        for script in (ARCHIVE_SCRIPT, RESTORE_SCRIPT):
            for tag in ("../escape", "local/../../escape", "/absolute"):
                result = self.run_script(script, tag=tag)
                self.assertNotEqual(result.returncode, 0, f"{script.name} {tag}")
                self.assertIn("unsafe tag", result.stdout + result.stderr, f"{script.name} {tag}")

    def test_round_trip_preserves_byte_identical_state_files(self) -> None:
        self.write_baseline_fixture()
        reference = self.tmp / "reference-state"
        shutil.copytree(self.state, reference, symlinks=True)

        self.archive()
        shutil.rmtree(self.state / "Settings")
        self.restore()

        comparison = filecmp.dircmp(str(reference), str(self.state), ignore=["DebugApps", "Rollbacks"])
        self.assertEqual(comparison.left_only, [])
        self.assertEqual(comparison.diff_files, [])

    def test_nested_directory_named_like_an_exclusion_survives_archive_and_restore(self) -> None:
        self.write_baseline_fixture()
        nested = self.state / "Workspaces" / "inner" / "DebugApps" / "nested.json"

        self.archive()
        listing = subprocess.run(
            ["tar", "-tzf", str(self.archive_root / TAG / "application-support.tar.gz")],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("Workspaces/inner/DebugApps/nested.json", listing)
        self.assertNotIn("./DebugApps/", listing)
        self.assertNotIn("./Rollbacks/", listing)

        nested.write_text("mutated\n", encoding="utf-8")
        self.restore()

        self.assertEqual(nested.read_text(encoding="utf-8"), "nested-original\n")

    def test_unreadable_manifest_refuses_before_changing_anything(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        app_before = tree_snapshot(self.app)
        state_before = tree_snapshot(self.state)
        defaults_before = self.read_defaults()

        for corruption in ("{ not json", "{}", '{"schemaVersion": 1, "tag": "other"}'):
            (self.archive_root / TAG / "manifest.json").write_text(corruption, encoding="utf-8")
            result = self.run_script(RESTORE_SCRIPT)
            self.assertNotEqual(result.returncode, 0, corruption)
            self.assertEqual(tree_snapshot(self.app), app_before, corruption)
            self.assertEqual(tree_snapshot(self.state), state_before, corruption)
            self.assertEqual(self.read_defaults(), defaults_before, corruption)
            self.assertEqual(list(self.archive_root.glob("**/*.rescue-*")), [], corruption)

    def test_manifest_without_files_or_excluded_names_refuses_and_verifies_nothing(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        manifest_path = self.archive_root / TAG / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        del manifest["files"]
        del manifest["applicationSupport"]["excludedNames"]
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        app_zip = self.archive_root / TAG / "app.zip"
        app_zip.write_bytes(app_zip.read_bytes() + b"corrupt")
        excluded_before = (self.state / "DebugApps" / "marker.txt").read_text(encoding="utf-8")

        result = self.run_script(RESTORE_SCRIPT)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lists no archive files", result.stdout + result.stderr)
        self.assertTrue((self.state / "DebugApps").is_dir())
        self.assertEqual((self.state / "DebugApps" / "marker.txt").read_text(encoding="utf-8"), excluded_before)

    def test_restore_keeps_a_rescue_directory_and_survives_an_interrupted_run(self) -> None:
        self.write_baseline_fixture()
        self.archive()
        original_app = tree_snapshot(self.app)

        interrupted = self.run_script(RESTORE_SCRIPT, LOCAL_RELEASE_ABORT_AT_STEP="Restoring application support")
        self.assertNotEqual(interrupted.returncode, 0)
        rescues = sorted(self.archive_root.glob("**/*.rescue-*"))
        self.assertEqual(len(rescues), 1, interrupted.stdout + interrupted.stderr)
        self.assertIn(str(rescues[0]), interrupted.stdout + interrupted.stderr)
        # The interrupted run stopped after the app swap, so the rescue holds the app it
        # replaced and the pre-clear preferences export.
        self.assertTrue((rescues[0] / f"{DISPLAY_NAME}.app").is_dir())
        self.assertTrue((rescues[0] / "defaults-before-restore.plist").is_file())
        self.assertEqual(tree_snapshot(rescues[0] / f"{DISPLAY_NAME}.app"), original_app)

        succeeded = self.restore()
        rescues = sorted(self.archive_root.glob("**/*.rescue-*"))
        self.assertGreaterEqual(len(rescues), 1)
        self.assertIn("rescue-", succeeded.stdout)
        self.assertTrue(any((rescue / "application-support").is_dir() for rescue in rescues))

    def test_both_scripts_refuse_while_a_repoprompt_process_is_running(self) -> None:
        self.write_baseline_fixture()
        self.archive()

        # A symlink, not a copy: copying a signed system binary invalidates its signature
        # and macOS kills the process immediately.
        fake = self.tmp / "repoprompt-mcp"
        os.symlink("/bin/sleep", fake)
        process = subprocess.Popen([str(fake), "45"])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)

        for script in (ARCHIVE_SCRIPT, RESTORE_SCRIPT):
            result = self.run_script(
                script,
                LOCAL_RELEASE_RUNNING_PROCESS_PATTERNS=f"{self.tmp}/repoprompt-mcp",
                LOCAL_RELEASE_ARCHIVE_OVERWRITE="1",
            )
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0, script.name)
            self.assertIn("Quit RepoPrompt before", output, script.name)
            self.assertIn(str(process.pid), output, script.name)
        self.assertEqual(list(self.archive_root.glob("**/*.rescue-*")), [])

    def test_default_process_guard_patterns_cover_production_debug_mcp_and_cli(self) -> None:
        defaults = ENV_SCRIPT.read_text(encoding="utf-8")
        for fragment in (
            "/$DISPLAY_NAME.app/Contents/MacOS/$APP_NAME",
            "DebugApps/$APP_NAME.app/Contents/MacOS/$APP_NAME",
            "repoprompt-mcp",
            "repoprompt_ce_cli",
        ):
            self.assertIn(fragment, defaults, fragment)


if __name__ == "__main__":
    unittest.main()
