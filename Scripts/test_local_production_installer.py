#!/usr/bin/env python3
"""Focused offline regression tests for the local production installer."""

from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import textwrap
import unittest
from unittest import mock
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from script_test_support import (  # noqa: E402
    FakeProcessGuard,
    directory_snapshot,
    enter_context,
    temporary_directory,
    write_bash_stub,
    write_executable,
)

ROOT_DIR = SCRIPT_DIR.parent
TEAM_A = "AAAAA11111"
TEAM_B = "BBBBB22222"
SHA1_A = "1" * 40
SHA1_B = "2" * 40
SHA1_C = "3" * 40
SHA1_A_RENEWED = "4" * 40
SELF_SIGNED_SHA256 = "A" * 64
SERVICE_A = f"com.pvncher.repoprompt.ce.local-apple-development.{TEAM_A}.keychain.v{(1 << 61) + 5}"
SERVICE_A_ROTATED = f"com.pvncher.repoprompt.ce.local-apple-development.{TEAM_A}.keychain.v{(1 << 61) + 6}"
SERVICE_B = f"com.pvncher.repoprompt.ce.local-apple-development.{TEAM_B}.keychain.v{(1 << 61) + 7}"
HEAD_COMMIT = "c" * 40
OTHER_COMMIT = "d" * 40
SELF_SIGNED_SERVICE = f"com.pvncher.repoprompt.ce.local-self-signed.{SELF_SIGNED_SHA256.lower()}.keychain.v7"
FRESH_SERVICE = re.compile(
    r"^com\.pvncher\.repoprompt\.ce\.local-apple-development\.(?P<team>[0-9A-Z]{10})\.keychain\.v(?P<generation>[0-9]+)$"
)


def certificate(
    sha1: str,
    team: str,
    *,
    private_key: bool = True,
    expired: bool = False,
    not_after: str = "2099-01-01T00:00:00Z",
) -> dict[str, Any]:
    return {
        "commonName": f"Apple Development: Fixture Developer ({team[:5]}ZZZZZ)",
        "teamIdentifier": team,
        "sha1": sha1,
        "notAfter": "2020-01-01T00:00:00Z" if expired else not_after,
        "hasPrivateKey": private_key,
        "isExpired": expired,
    }


def team_registry(team: str, service: str) -> dict[str, Any]:
    return {"schemaVersion": 2, "teamIdentifier": team, "keychainService": service}


def self_signed_registry(fingerprint: str, generation: int) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "certificateName": "RepoPrompt CE Local Self-Signed Code Signing",
        "certificateSHA256": fingerprint,
        "serviceGeneration": generation,
    }


class LocalProductionIdentityToolTests(unittest.TestCase):
    def test_command_inventory_reads_apple_development_identities_independent_of_output_order(self) -> None:
        spec = importlib.util.spec_from_file_location("local_signing_identity", SCRIPT_DIR / "local_signing_identity.py")
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        pem_b = b"-----BEGIN CERTIFICATE-----\nCERT-B\n-----END CERTIFICATE-----\n"
        pem_a = b"-----BEGIN CERTIFICATE-----\nCERT-A\n-----END CERTIFICATE-----\n"
        pem_without_key = b"-----BEGIN CERTIFICATE-----\nCERT-C\n-----END CERTIFICATE-----\n"
        identity_output = (
            f'  1) {SHA1_B} "Apple Development: Dev B (B0B0B0B0B0)"\n'
            f'  2) {SHA1_A} "Apple Development: Dev, A (A0A0A0A0A0)"\n'
            f'  3) {SHA1_C} "Developer ID Application: Someone Else ({TEAM_A})"\n'
        ).encode()
        subjects = {
            "A": rf"subject=UID=A0A0A0A0A0,CN=Apple Development: Dev\, A (A0A0A0A0A0),OU={TEAM_A},O=Dev A,C=US",
            "B": f"subject=CN=Apple Development: Dev B (B0B0B0B0B0),OU={TEAM_B},O=Dev B,C=US",
            "C": f"subject=CN=Apple Development: Dev C (C0C0C0C0C0),OU={TEAM_A},O=Dev C,C=US",
        }

        def fake_run_command(arguments: list[str], *, input_data: bytes | None = None) -> bytes:
            if arguments[:2] == ["security", "find-identity"]:
                return identity_output
            self.assertEqual(arguments[:3], ["openssl", "x509", "-noout"])
            marker = "A" if b"CERT-A" in (input_data or b"") else "B" if b"CERT-B" in (input_data or b"") else "C"
            if "-subject" in arguments:
                return f"{subjects[marker]}\n".encode()
            if "-enddate" in arguments:
                return b"notAfter=Jan  1 00:00:00 2099 GMT\n"
            fingerprint = {"A": SHA1_A, "B": SHA1_B, "C": SHA1_C}[marker]
            return f"SHA1 Fingerprint={fingerprint}\n".encode()

        certificate_result = subprocess.CompletedProcess(
            ["security"],
            0,
            stdout=pem_b + pem_without_key + pem_a,
            stderr=b"",
        )
        with mock.patch.object(module, "run_command", side_effect=fake_run_command), mock.patch.object(
            module.subprocess,
            "run",
            return_value=certificate_result,
        ):
            inventory = module.inventory_from_commands(
                "/fixture/login.keychain-db",
                module.evaluation_time("2030-01-01T00:00:00Z"),
            )

        self.assertEqual(
            sorted((item["teamIdentifier"], item["sha1"]) for item in inventory["candidates"]),
            [(TEAM_A, SHA1_A), (TEAM_B, SHA1_B)],
        )
        by_sha1 = {item["sha1"]: item for item in inventory["matchingCertificates"]}
        self.assertEqual(by_sha1[SHA1_A]["commonName"], "Apple Development: Dev, A (A0A0A0A0A0)")
        self.assertFalse(by_sha1[SHA1_C]["hasPrivateKey"])


class LocalProductionInstallerTests(unittest.TestCase):
    def test_local_entitlements_and_packaging_require_team_and_service_metadata(self) -> None:
        template = ROOT_DIR / "AppBundle" / "RepoPrompt.local-production.entitlements.template"
        with template.open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertEqual(
            entitlements,
            {
                "com.apple.security.cs.allow-jit": True,
                "com.apple.security.cs.disable-library-validation": True,
                "com.apple.security.files.bookmarks.app-scope": True,
                "com.apple.security.temporary-exception.mach-lookup.global-name": [
                    "__BUNDLE_ID__-spks",
                    "__BUNDLE_ID__-spki",
                ],
            },
        )
        package_script = (SCRIPT_DIR / "package_app.sh").read_text(encoding="utf-8")
        self.assertIn("LOCAL_SIGNING_TEAM_ID", package_script)
        self.assertIn("LOCAL_KEYCHAIN_SERVICE", package_script)
        info_template = (ROOT_DIR / "AppBundle" / "Info.plist.template").read_text(encoding="utf-8")
        self.assertIn("RepoPromptLocalSigningTeamIdentifier", info_template)
        self.assertIn("RepoPromptLocalKeychainService", info_template)
        self.assertIn("Extracted designated requirement", package_script)

    def test_first_use_adopts_sole_team_and_writes_registry(self) -> None:
        result, context = self.run_installer([certificate(SHA1_A, TEAM_A)], expected_team=TEAM_A)
        self.assertEqual(result.returncode, 0, result.stderr)
        registry = self.registry(context)
        self.assertEqual(registry["schemaVersion"], 2)
        self.assertEqual(registry["teamIdentifier"], TEAM_A)
        match = FRESH_SERVICE.fullmatch(registry["keychainService"])
        self.assertIsNotNone(match, registry)
        self.assertEqual(match.group("team"), TEAM_A)
        self.assertGreaterEqual(int(match.group("generation")), 1 << 61)
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertIn(f"Selected local signing team: {TEAM_A}", result.stdout)
        self.assertIn(f'certificate leaf[subject.OU] = "{TEAM_A}"', result.stdout)
        self.assertEqual(
            context["package_capture"].read_text(encoding="utf-8").strip(),
            f"{SHA1_A}|{TEAM_A}|{registry['keychainService']}",
        )
        self.assertNotIn("find-identity", context["security_log"].read_text(encoding="utf-8"))

    def test_installer_uses_packager_output_without_reinvoking_swift(self) -> None:
        result, context = self.run_installer([certificate(SHA1_A, TEAM_A)], expected_team=TEAM_A)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(context["swift_log"].exists())
        self.assertEqual(
            (context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(encoding="utf-8"),
            "new\n",
        )

    def test_installer_reads_packaged_app_from_split_release_source_root(self) -> None:
        with self.subTest(mode="combined"):
            result, context = self.run_installer(
                [certificate(SHA1_A, TEAM_A)],
                expected_team=TEAM_A,
                split_release_source_root=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(encoding="utf-8"),
                "new\n",
            )
            self.assertFalse((context["tooling_root"] / ".build" / "release" / "RepoPrompt.app").exists())

        # The split root has its own version.env, and the git stub answers only for it, so
        # checking HEAD or versions against the control-plane checkout fails.
        with self.subTest(mode="prepare, then install-prepared"):
            context = self.prepare(split_release_source_root=True)
            self.assertTrue(context["prepared_app"].is_dir())
            self.assertFalse((context["tooling_root"] / ".build" / "local-production").exists())
            result = self.invoke(context, "install-prepared")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((context["installed_app"] / "payload.txt").read_text(encoding="utf-8"), "new\n")

    def test_prepare_runs_beside_running_production_and_changes_nothing_installed(self) -> None:
        context = self.prepare(processes=[{"pid": 4242, "name": "RepoPrompt", "path": "{production_executable}"}])
        self.assertEqual(context["process_guard"].calls, 0)
        self.assertEqual(directory_snapshot(context["install_dir"]), context["install_dir_before"])
        self.assert_registry_unchanged(context)
        self.assertEqual(self.prepared_provenance(context)["commit"], HEAD_COMMIT)
        self.assertEqual(list(context["prepared_app"].parent.glob("*.preparing.*")), [])
        self.assertEqual(len(context["package_capture"].read_text(encoding="utf-8").splitlines()), 1)

    def test_prepare_refuses_a_build_that_does_not_match_head_and_keeps_the_previous_bundle(self) -> None:
        context = self.prepare()
        previous = directory_snapshot(context["prepared_app"])
        result = self.invoke(context, "prepare", {"FAKE_PROVENANCE_COMMIT": OTHER_COMMIT})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"provenance commit is not HEAD {HEAD_COMMIT}", result.stderr)
        self.assertEqual(directory_snapshot(context["prepared_app"]), previous)
        self.assertEqual(list(context["prepared_app"].parent.glob("*.preparing.*")), [])

    def test_prepare_refuses_signing_plans_that_would_write_the_registry(self) -> None:
        scenarios = [
            ("first use", {}),
            ("self-signed registry", {"registry": self_signed_registry(SELF_SIGNED_SHA256, 7)}),
            ("rotation", {"registry": team_registry(TEAM_A, SERVICE_A), "rotate": True}),
        ]
        for name, kwargs in scenarios:
            with self.subTest(name):
                result, context = self.run_installer(
                    [certificate(SHA1_A, TEAM_A)], expected_team=TEAM_A, mode="prepare", **kwargs
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Split preparation requires an existing Apple Development signing registry", result.stderr)
                self.assertFalse(context["package_capture"].exists())
                self.assert_registry_unchanged(context)
                self.assertFalse(context["prepared_app"].exists())

    def test_install_prepared_installs_the_prepared_bundle_without_packaging(self) -> None:
        context = self.prepare()
        (context["build_dir"] / "RepoPrompt.app" / "payload.txt").write_text("rebuilt after preparation\n", encoding="utf-8")
        for tool in (
            context["scripts"] / "package_app.sh",
            context["scripts"] / "resolve_full_xcode_developer_dir.sh",
            context["bin_dir"] / "security",
        ):
            write_executable(tool, "#!/bin/sh\nexit 98\n")
        result = self.invoke(context, "install-prepared", {"LOCAL_SIGNING_TEAM_ID": f" {TEAM_A.lower()} "})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((context["installed_app"] / "payload.txt").read_text(encoding="utf-8"), "new\n")
        self.assert_registry_unchanged(context)

    def test_install_prepared_refuses_a_bundle_that_does_not_match(self) -> None:
        # The last item of each row is the message of the one check that must refuse, so a row
        # cannot pass on another check's refusal.
        cases = [
            (
                "prepared bundle missing",
                lambda context: shutil.rmtree(context["prepared_app"]),
                "No prepared local production app at",
            ),
            (
                "HEAD moved after preparation",
                lambda context: context["env"].update(FAKE_HEAD_COMMIT=OTHER_COMMIT),
                f"its provenance commit is not HEAD {OTHER_COMMIT}",
            ),
            (
                "dirty provenance",
                lambda context: self.edit_prepared_provenance(context, dirty=True),
                "its provenance does not record a clean worktree",
            ),
            (
                "git status unavailable",
                lambda context: self.edit_prepared_provenance(context, git_status="unavailable"),
                "its provenance git_status is not ok",
            ),
            (
                "provenance version is not 1",
                lambda context: self.edit_prepared_provenance(context, version=2),
                "its provenance is missing or is not version 1",
            ),
            (
                "marketing version changed after preparation",
                lambda context: self.set_version_env(context, "MARKETING_VERSION", "1.0.1"),
                "its version is not 1.0.1 from version.env",
            ),
            (
                "build number changed after preparation",
                lambda context: self.set_version_env(context, "BUILD_NUMBER", "2"),
                "its build is not 2 from version.env",
            ),
            (
                "registry service changed after preparation",
                lambda context: self.write_registry(context, team_registry(TEAM_A, SERVICE_A_ROTATED)),
                f"its Keychain service is not {SERVICE_A_ROTATED}",
            ),
            (
                "registry team changed after preparation",
                lambda context: self.write_registry(context, team_registry(TEAM_B, SERVICE_B)),
                f"its designated requirement is not anchored to team {TEAM_B}",
            ),
            (
                # The designated requirement still names the registered team, so only the plist check refuses.
                "Info.plist team differs from the registry",
                lambda context: self.edit_prepared_info_plist(context, RepoPromptLocalSigningTeamIdentifier=TEAM_B),
                f"its signing team is not {TEAM_A}",
            ),
            (
                "signing mode marker is not local Apple Development",
                lambda context: self.edit_prepared_info_plist(context, RepoPromptSigningMode="local-self-signed"),
                "it is not marked as a local Apple Development build",
            ),
            (
                "staged copy fails verification",
                lambda context: context["env"].update(FAIL_STAGED_CODESIGN="1"),
                f"the signature does not verify against the team {TEAM_A} requirement",
            ),
        ]
        for name, change, refusal in cases:
            with self.subTest(name):
                context = self.prepare()
                change(context)
                context["registry_before"] = context["registry"].read_bytes()
                result = self.invoke(context, "install-prepared")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(refusal, result.stderr)
                self.assertIn("nothing was installed", result.stderr)
                self.assert_no_install_mutation(context, packaged=True)
                self.assert_registry_unchanged(context)

    def test_multiple_first_use_teams_fail_with_teams_and_explicit_selection_succeeds(self) -> None:
        certificates = [certificate(SHA1_B, TEAM_B), certificate(SHA1_A, TEAM_A)]
        failed, _ = self.run_installer(certificates, expected_team=TEAM_A)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn(TEAM_A, failed.stderr)
        self.assertIn(TEAM_B, failed.stderr)
        self.assertIn("LOCAL_SIGNING_TEAM_ID=<team>", failed.stderr)

        selected, context = self.run_installer(certificates, selected_team=TEAM_B, expected_team=TEAM_B)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(self.registry(context)["teamIdentifier"], TEAM_B)

    def test_no_valid_identity_on_first_use_points_to_xcode_without_writing_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A, private_key=False), certificate(SHA1_B, TEAM_B, expired=True)],
            expected_team=TEAM_A,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Manage Certificates", result.stderr)
        self.assertFalse(context["registry"].exists())
        self.assert_no_install_mutation(context, packaged=False)

    def test_registered_team_without_valid_identity_fails_without_adopting_another_team(self) -> None:
        scenarios = [
            ([], "is missing"),
            ([certificate(SHA1_B, TEAM_B)], "is missing"),
            ([certificate(SHA1_A, TEAM_A, expired=True)], "is expired"),
            ([certificate(SHA1_A, TEAM_A, private_key=False)], "does not have an available private key"),
        ]
        for certificates, expected_message in scenarios:
            with self.subTest(expected_message=expected_message, certificates=len(certificates)):
                result, context = self.run_installer(
                    certificates,
                    registry=team_registry(TEAM_A, SERVICE_A),
                    expected_team=TEAM_A,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_message, result.stderr)
                self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))
                self.assert_no_install_mutation(context, packaged=False)

    def test_renewed_certificate_keeps_registered_team_service_and_requirement(self) -> None:
        result, context = self.run_installer(
            [
                certificate(SHA1_A, TEAM_A, expired=True),
                certificate(SHA1_C, TEAM_A, not_after="2031-01-01T00:00:00Z"),
                certificate(SHA1_A_RENEWED, TEAM_A, not_after="2032-01-01T00:00:00Z"),
            ],
            registry=team_registry(TEAM_A, SERVICE_A),
            expected_team=TEAM_A,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))
        self.assertEqual(
            context["package_capture"].read_text(encoding="utf-8").strip(),
            f"{SHA1_A_RENEWED}|{TEAM_A}|{SERVICE_A}",
        )

    def test_self_signed_registry_moves_to_team_signing_and_keeps_its_keychain_service(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            registry=self_signed_registry(SELF_SIGNED_SHA256, 7),
            expected_team=TEAM_A,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SELF_SIGNED_SERVICE))
        self.assertIn("Always Allow", result.stdout)
        self.assertEqual(
            context["package_capture"].read_text(encoding="utf-8").strip(),
            f"{SHA1_A}|{TEAM_A}|{SELF_SIGNED_SERVICE}",
        )

    def test_explicit_rotation_registers_a_fresh_service_and_leaves_the_prior_one(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            registry=team_registry(TEAM_A, SERVICE_A),
            selected_team=TEAM_B,
            rotate=True,
            expected_team=TEAM_B,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        registry = self.registry(context)
        self.assertEqual(registry["teamIdentifier"], TEAM_B)
        match = FRESH_SERVICE.fullmatch(registry["keychainService"])
        self.assertIsNotNone(match, registry)
        self.assertEqual(match.group("team"), TEAM_B)
        self.assertIn("prior local Keychain service inaccessible", result.stderr)

    def test_selecting_another_team_without_rotation_fails(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            registry=team_registry(TEAM_A, SERVICE_A),
            selected_team=TEAM_B,
            expected_team=TEAM_B,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ROTATE_LOCAL_SIGNING_IDENTITY=1", result.stderr)
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))

    def test_two_consecutive_installs_keep_team_service_and_designated_requirement(self) -> None:
        first, context = self.run_installer([certificate(SHA1_A, TEAM_A)], expected_team=TEAM_A)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_requirement = self.requirement_line(first.stdout)
        first_registry = self.registry(context)
        second = self.invoke(context)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.registry(context), first_registry)
        self.assertEqual(self.requirement_line(second.stdout), first_requirement)

    def test_existing_install_lock_fails_closed_without_removing_other_owner_lock(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            expected_team=TEAM_A,
            preexisting_lock=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Another local production install is active", result.stderr)
        self.assertTrue(Path(f"{context['registry']}.lock").is_dir())

    ROTATION = {
        "registry": team_registry(TEAM_A, SERVICE_A),
        "selected_team": TEAM_B,
        "rotate": True,
        "expected_team": TEAM_B,
    }

    def test_failed_registry_backup_preserves_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            fail_registry_backup_copy=True,
            **self.ROTATION,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_registry_write_restores_prior_app_and_exact_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            fail_registry_write=True,
            **self.ROTATION,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_app_backup_preserves_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            fail_app_backup_move=True,
            fail_registry_restore_copy=True,
            **self.ROTATION,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])

    def test_failed_registry_restore_preserves_snapshot_for_manual_recovery(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            fail_registry_write=True,
            fail_registry_restore_copy=True,
            **self.ROTATION,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(context["registry"].read_text(encoding="utf-8"), "damaged registry\n")
        match = re.search(r"Preserving failed transaction snapshot for manual recovery: ([^\n]+)", result.stderr)
        self.assertIsNotNone(match, result.stderr)
        preserved = Path(match.group(1))
        self.addCleanup(shutil.rmtree, preserved, True)
        snapshot = preserved / "local-signing-identity-registry.backup"
        self.assertTrue(snapshot.is_file())
        self.assertEqual(json.loads(snapshot.read_text(encoding="utf-8")), team_registry(TEAM_A, SERVICE_A))

    def test_failed_postwrite_registry_verification_restores_prior_app_and_registry(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
            fail_registry_verification=True,
            **self.ROTATION,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))

    def test_failed_replacement_restores_prior_app_and_does_not_write_registry(self) -> None:
        with self.subTest(mode="combined"):
            result, context = self.run_installer(
                [certificate(SHA1_A, TEAM_A)],
                expected_team=TEAM_A,
                fail_final_install_move=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
            self.assertFalse(context["registry"].exists())

        with self.subTest(mode="install-prepared"):
            context = self.prepare(fail_final_install_move=True)
            result = self.invoke(context, "install-prepared")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "old\n")
            self.assert_registry_unchanged(context)

    def test_running_production_app_stops_install_before_any_mutation(self) -> None:
        with self.subTest(mode="combined"):
            result, context = self.run_installer(
                [certificate(SHA1_A, TEAM_A)],
                expected_team=TEAM_A,
                processes=[{"pid": 4242, "name": "RepoPrompt", "path": "{production_executable}"}],
                record_pgrep_calls=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Quit RepoPrompt CE before building a replacement", result.stderr)
            self.assertIn("4242", result.stderr)
            self.assertIn(str(context["production_executable"].resolve()), result.stderr)
            self.assert_no_install_mutation(context, packaged=False)
            self.assertFalse(context["registry"].parent.exists())
            self.assertEqual(list(context["tmp_root"].iterdir()), [])
            self.assertFalse(context["pgrep_log"].exists())

        with self.subTest(mode="install-prepared"):
            context = self.prepare(processes=[{"pid": 4242, "name": "RepoPrompt", "path": "{production_executable}"}])
            result = self.invoke(context, "install-prepared")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Quit RepoPrompt CE before staging the prepared build", result.stderr)
            self.assertIn("4242", result.stderr)
            self.assert_no_install_mutation(context, packaged=True)
            self.assert_registry_unchanged(context)

    def test_rollback_guard_override_does_not_redirect_the_production_guard(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            expected_team=TEAM_A,
            processes=[{"pid": 4343, "name": "RepoPrompt", "path": "{production_executable}"}],
            extra_env={"LOCAL_RELEASE_GUARD_EXECUTABLES_JSON": '["/nonexistent/repoprompt-ce-guard-sentinel"]'},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit RepoPrompt CE before building a replacement", result.stderr)
        self.assertIn("4343", result.stderr)
        self.assert_no_install_mutation(context, packaged=False)

    def test_other_installs_and_bundled_helpers_do_not_block_replacement(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            expected_team=TEAM_A,
            processes=[
                {"pid": 501, "name": "RepoPrompt", "path": "{temp}/Elsewhere/RepoPrompt CE.app/Contents/MacOS/RepoPrompt"},
                {"pid": 502, "name": "RepoPrompt", "path": "{temp}/Applications/RepoPrompt CE.app.old/Contents/MacOS/RepoPrompt"},
                {"pid": 503, "name": "codex", "path": "{installed_app}/Contents/Resources/codex/codex"},
                {"pid": 504, "name": "repoprompt-mcp", "path": "{installed_app}/Contents/MacOS/repoprompt-mcp"},
            ],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "new\n")
        self.assertEqual(context["process_guard"].calls, 3)

    DEBUG_APP_PROCESSES = [
        {
            "pid": 511,
            "name": "RepoPrompt",
            "path": "{temp}/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt",
        },
        {
            "pid": 512,
            "name": "RepoPromptDebug",
            "path": "{temp}/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPromptDebug",
        },
        {
            "pid": 513,
            "name": "repoprompt-mcp",
            "path": "{temp}/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/repoprompt-mcp",
        },
    ]

    def test_current_and_legacy_debug_apps_do_not_block_replacement(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            expected_team=TEAM_A,
            processes=self.DEBUG_APP_PROCESSES,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "new\n")
        self.assertEqual(context["process_guard"].calls, 3)

    def test_production_beside_running_debug_apps_still_blocks_every_checkpoint(self) -> None:
        for checkpoint, message in enumerate(
            ("before building a replacement", "before staging", "before replacing"),
            start=1,
        ):
            with self.subTest(checkpoint=checkpoint):
                result, context = self.run_installer(
                    [certificate(SHA1_A, TEAM_A)],
                    registry=team_registry(TEAM_A, SERVICE_A),
                    expected_team=TEAM_A,
                    processes=[
                        *self.DEBUG_APP_PROCESSES,
                        {"pid": 514, "name": "RepoPrompt", "path": "{production_executable}", "from_call": checkpoint},
                    ],
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"Quit RepoPrompt CE {message}", result.stderr)
                self.assertIn("514", result.stderr)
                self.assertNotIn("DebugApps", result.stderr)
                self.assert_no_install_mutation(context, packaged=checkpoint > 1)

    def test_native_inspection_failure_stops_before_packaging(self) -> None:
        for scenario, kwargs in [
            ("enumeration", {"fail_process_enumeration": True}),
            ("named candidate", {"processes": [{"pid": 601, "name": "RepoPrompt", "path": "{production_executable}", "error": "identity"}]}),
            ("deleted executable", {"processes": [{"pid": 602, "name": "RepoPrompt", "path": "{production_executable}", "error": "unlinked"}]}),
        ]:
            with self.subTest(scenario=scenario):
                result, context = self.run_installer([certificate(SHA1_A, TEAM_A)], expected_team=TEAM_A, **kwargs)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("process identity inspection failed", result.stderr)
                self.assert_no_install_mutation(context, packaged=False)

    def test_production_opened_during_build_stops_before_staging(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            registry=team_registry(TEAM_A, SERVICE_A),
            expected_team=TEAM_A,
            processes=[{"pid": 701, "name": "RepoPrompt", "path": "{production_executable}", "from_call": 2}],
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit RepoPrompt CE before staging", result.stderr)
        self.assert_no_install_mutation(context, packaged=True)
        self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))

    def test_production_opened_during_staging_stops_before_replacement(self) -> None:
        with self.subTest(mode="combined"):
            result, context = self.run_installer(
                [certificate(SHA1_A, TEAM_A), certificate(SHA1_B, TEAM_B)],
                processes=[{"pid": 801, "name": "RepoPrompt", "path": "{production_executable}", "from_call": 3}],
                **self.ROTATION,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Quit RepoPrompt CE before replacing", result.stderr)
            self.assert_no_install_mutation(context, packaged=True)
            self.assertEqual(self.registry(context), team_registry(TEAM_A, SERVICE_A))

        # Preparation doesn't call the guard, so the prepared install's second call is the
        # check before replacing.
        with self.subTest(mode="install-prepared"):
            context = self.prepare(
                processes=[{"pid": 801, "name": "RepoPrompt", "path": "{production_executable}", "from_call": 2}]
            )
            result = self.invoke(context, "install-prepared")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Quit RepoPrompt CE before replacing", result.stderr)
            self.assert_no_install_mutation(context, packaged=True)
            self.assert_registry_unchanged(context)

    def test_absent_installation_installs_through_all_checkpoints(self) -> None:
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            expected_team=TEAM_A,
            installed=False,
            processes=[
                {
                    "pid": 901,
                    "name": "RepoPrompt",
                    "path": "{temp}/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app/Contents/MacOS/RepoPrompt",
                }
            ],
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((context["install_dir"] / "RepoPrompt CE.app" / "payload.txt").read_text(), "new\n")
        self.assertEqual(context["process_guard"].calls, 3)

    def test_installer_and_shared_guard_do_not_match_command_lines(self) -> None:
        for name in ("install_local_production.sh", "local_release_env.sh"):
            source = (SCRIPT_DIR / name).read_text(encoding="utf-8")
            self.assertNotIn("pgrep", source, name)
            self.assertNotIn("ps -o command", source, name)

    def assert_no_install_mutation(self, context: dict[str, Any], *, packaged: bool) -> None:
        self.assertEqual(directory_snapshot(context["installed_app"]), context["installed_app_before"])
        self.assertEqual(context["package_capture"].exists(), packaged)
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.installing.*")), [])
        self.assertEqual(list(context["install_dir"].glob(".RepoPrompt CE.app.backup.*")), [])
        self.assertFalse(Path(f"{context['registry']}.lock").exists())

    def assert_registry_unchanged(self, context: dict[str, Any]) -> None:
        if context["registry_before"] is None:
            self.assertFalse(context["registry"].exists())
            return
        self.assertEqual(context["registry"].read_bytes(), context["registry_before"])
        self.assertEqual(context["registry"].stat().st_mode & 0o777, 0o600)

    def prepare(self, **kwargs: Any) -> dict[str, Any]:
        """Runs a successful preparation against a registered team A identity."""
        result, context = self.run_installer(
            [certificate(SHA1_A, TEAM_A)],
            registry=team_registry(TEAM_A, SERVICE_A),
            expected_team=TEAM_A,
            mode="prepare",
            **kwargs,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return context

    def run_installer(
        self,
        certificates: list[dict[str, Any]],
        *,
        expected_team: str,
        registry: dict[str, Any] | None = None,
        selected_team: str | None = None,
        rotate: bool = False,
        fail_final_install_move: bool = False,
        fail_app_backup_move: bool = False,
        fail_registry_backup_copy: bool = False,
        fail_registry_write: bool = False,
        fail_registry_restore_copy: bool = False,
        preexisting_lock: bool = False,
        fail_registry_verification: bool = False,
        split_release_source_root: bool = False,
        processes: list[dict[str, Any]] | None = None,
        fail_process_enumeration: bool = False,
        installed: bool = True,
        record_pgrep_calls: bool = False,
        extra_env: dict[str, str] | None = None,
        mode: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, Any]]:
        temp_dir = enter_context(self, temporary_directory())
        installer_tmp = temp_dir / "tmp"
        installer_tmp.mkdir()
        root = temp_dir / "repo"
        process_guard = FakeProcessGuard(
            root,
            extra_scripts=(
                "install_local_production.sh",
                "local_signing_identity.py",
                "resolve_full_xcode_developer_dir.sh",
            ),
        )
        scripts = process_guard.scripts_dir
        if fail_registry_verification or fail_registry_write:
            real_tool = scripts / "local_signing_identity_real.py"
            shutil.move(scripts / "local_signing_identity.py", real_tool)
            (scripts / "local_signing_identity.py").write_text(
                textwrap.dedent(
                    """\
                    import os
                    import subprocess
                    import sys
                    from pathlib import Path

                    marker = os.environ["FAIL_REGISTRY_READ_MARKER"]
                    real_tool = os.path.join(os.path.dirname(__file__), "local_signing_identity_real.py")
                    command = sys.argv[1] if len(sys.argv) > 1 else ""
                    if command == "write-registry" and os.environ.get("FAIL_REGISTRY_WRITE") == "1":
                        path = Path(sys.argv[sys.argv.index("--path") + 1])
                        path.write_text("damaged registry\\n", encoding="utf-8")
                        path.chmod(0o644)
                        print("ERROR: simulated registry write failure", file=sys.stderr)
                        raise SystemExit(2)
                    if command == "read-registry" and os.path.exists(marker):
                        print("ERROR: simulated post-write registry verification failure", file=sys.stderr)
                        raise SystemExit(2)
                    result = subprocess.run([sys.executable, real_tool, *sys.argv[1:]])
                    if command == "write-registry" and result.returncode == 0:
                        open(marker, "w", encoding="utf-8").close()
                    raise SystemExit(result.returncode)
                    """
                ),
                encoding="utf-8",
            )
        (root / "version.env").write_text(
            (
                'APP_NAME=RepoPrompt\nDISPLAY_NAME="RepoPrompt CE"\n'
                'BUNDLE_ID=com.pvncher.repoprompt.ce\nMARKETING_VERSION=1.0.0\n'
                'BUILD_NUMBER=1\nSIGNING_TEAM_ID=ABC123\n'
            ),
            encoding="utf-8",
        )

        release_source_root = temp_dir / "release-source" if split_release_source_root else root
        if split_release_source_root:
            release_source_root.mkdir()
            (release_source_root / "version.env").write_text(
                (
                    'APP_NAME=RepoPrompt\nDISPLAY_NAME="RepoPrompt CE"\n'
                    'BUNDLE_ID=com.pvncher.repoprompt.ce\nMARKETING_VERSION=2.0.0\n'
                    'BUILD_NUMBER=7\nSIGNING_TEAM_ID=ABC123\n'
                ),
                encoding="utf-8",
            )
        build_dir = release_source_root / ".build" / "release"
        install_dir = temp_dir / "Applications"
        installed_app = install_dir / "RepoPrompt CE.app"
        production_executable = installed_app / "Contents" / "MacOS" / "RepoPrompt"
        install_dir.mkdir(parents=True)
        if installed:
            (installed_app / "payload.txt").parent.mkdir(parents=True)
            (installed_app / "payload.txt").write_text("old\n", encoding="utf-8")
            write_executable(production_executable, "#!/bin/sh\nexit 0\n")
        placeholders = {
            "temp": str(temp_dir),
            "installed_app": str(installed_app),
            "production_executable": str(production_executable),
        }
        process_guard.set_processes(
            [{**entry, "path": entry["path"].format(**placeholders)} for entry in processes or []],
            fail_enumeration=fail_process_enumeration,
        )
        keychain = temp_dir / "Library" / "Keychains" / "login keychain-db"
        keychain.parent.mkdir(parents=True)
        keychain.touch()
        fixture = temp_dir / "inventory.json"
        fixture.write_text(json.dumps({"certificates": certificates}), encoding="utf-8")
        registry_path = temp_dir / "Application Support" / "RepoPrompt CE" / "local-signing-identity-v1.json"
        if registry:
            registry_path.parent.mkdir(parents=True)
            registry_path.write_text(json.dumps(registry), encoding="utf-8")
            registry_path.chmod(0o600)
        if preexisting_lock:
            lock_path = Path(f"{registry_path}.lock")
            lock_path.mkdir(parents=True)
            (lock_path / "pid").write_text("99999\n", encoding="utf-8")

        package_capture = temp_dir / "package-capture.txt"
        # Like the real packager, it reads version.env from REPOPROMPT_RELEASE_SOURCE_ROOT when
        # set and records HEAD in the provenance. FAKE_PROVENANCE_COMMIT simulates a commit
        # landing during the build.
        write_executable(
            scripts / "package_app.sh",
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                source_root="${REPOPROMPT_RELEASE_SOURCE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
                source "$source_root/version.env"
                app="$FAKE_BUILD_DIR/RepoPrompt.app"
                mkdir -p "$app/Contents/Resources"
                printf 'new\\n' > "$app/payload.txt"
                printf '%s|%s|%s\\n' "$SIGN_IDENTITY" "$LOCAL_SIGNING_TEAM_ID" "$LOCAL_KEYCHAIN_SERVICE" >> "$PACKAGE_CAPTURE"
                cat > "$app/Contents/Info.plist" <<EOF
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>CFBundleShortVersionString</key><string>$MARKETING_VERSION</string>
                  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
                  <key>RepoPromptSigningMode</key><string>local-apple-development</string>
                  <key>RepoPromptLocalSigningTeamIdentifier</key><string>$LOCAL_SIGNING_TEAM_ID</string>
                  <key>RepoPromptLocalKeychainService</key><string>$LOCAL_KEYCHAIN_SERVICE</string>
                </dict></plist>
                EOF
                cat > "$app/Contents/Resources/RepoPromptProvenance.json" <<EOF
                {"version": 1, "commit": "${FAKE_PROVENANCE_COMMIT:-$FAKE_HEAD_COMMIT}", "dirty": false, "git_status": "ok"}
                EOF
                """
            ),
        )

        bin_dir = temp_dir / "bin"
        bin_dir.mkdir()
        security_log = temp_dir / "security.log"
        write_bash_stub(
            bin_dir,
            "security",
            """\
            printf '%s\\n' "$*" >> "$SECURITY_LOG"
            case "$1" in
                default-keychain) printf '    "%s"\\n' "$FAKE_KEYCHAIN" ;;
                *) exit 0 ;;
            esac
            """,
        )
        swift_log = temp_dir / "swift.log"
        write_bash_stub(bin_dir, "swift", 'printf "%s\\n" "$*" >> "$SWIFT_LOG"\nexit 97\n')
        write_bash_stub(
            bin_dir,
            "xcrun",
            """\
            if [[ "$*" == "--sdk macosx --show-sdk-version" && "${DEVELOPER_DIR:-}" == "$FAKE_DEVELOPER_DIR" ]]; then
                printf '27.0\\n'
                exit 0
            fi
            exit 1
            """,
        )
        write_bash_stub(
            bin_dir,
            "codesign",
            """\
            if [[ "${FAIL_STAGED_CODESIGN:-0}" == "1" && "$1" == "--verify" && "${!#}" == *".installing."* ]]; then
                printf '%s: a sealed resource is missing or invalid\\n' "${!#}" >&2
                exit 1
            fi
            if [[ "$1" == "-d" && "$2" == "-r-" ]]; then
                printf 'designated => anchor apple generic and identifier "com.pvncher.repoprompt.ce" and certificate leaf[subject.OU] = "%s" and certificate leaf[field.1.2.840.113635.100.6.1.12] exists\\n' "$FAKE_DESIGNATED_TEAM" >&2
            fi
            exit 0
            """,
        )
        pgrep_log = temp_dir / "pgrep.log"
        if record_pgrep_calls:
            write_bash_stub(bin_dir, "pgrep", 'printf "%s\\n" "$*" >> "$PGREP_LOG"\nexit 1\n')
        write_bash_stub(bin_dir, "ditto", 'cp -R "$1" "$2"\n')
        # The stub answers only `rev-parse HEAD` run in the release source root. That keeps the
        # fixture hermetic and makes a HEAD read from any other checkout fail.
        write_bash_stub(
            bin_dir,
            "git",
            """\
            if [[ "$#" == 4 && "$1" == "-C" && "$3" == "rev-parse" && "$4" == "HEAD" ]] &&
                [[ "$(cd "$2" && pwd -P)" == "$(cd "$FAKE_GIT_ROOT" && pwd -P)" ]]; then
                printf '%s\\n' "$FAKE_HEAD_COMMIT"
                exit 0
            fi
            printf 'fake git: unsupported invocation: %s\\n' "$*" >&2
            exit 1
            """,
        )
        write_bash_stub(
            bin_dir,
            "cp",
            """\
            if [[ "${FAIL_REGISTRY_BACKUP_COPY:-0}" == "1" && "$#" == "3" && "$1" == "-p" && "$2" == "$FAKE_REGISTRY_PATH" ]]; then
                exit 29
            fi
            if [[ "${FAIL_REGISTRY_RESTORE_COPY:-0}" == "1" && "$#" == "3" && "$1" == "-p" && "$2" == *"local-signing-identity-registry.backup" ]]; then
                exit 30
            fi
            exec /bin/cp "$@"
            """,
        )
        write_bash_stub(
            bin_dir,
            "mv",
            """\
            if [[ "${FAIL_APP_BACKUP_MOVE:-0}" == "1" && "$1" == "$FAKE_INSTALLED_APP" && "$2" == *".backup."*"/RepoPrompt CE.app" ]]; then
                exit 24
            fi
            if [[ "${FAIL_FINAL_INSTALL_MOVE:-0}" == "1" && "$1" == *".installing."*"/RepoPrompt CE.app" && "$2" == *"/RepoPrompt CE.app" ]]; then
                exit 23
            fi
            exec /bin/mv "$@"
            """,
        )

        env = os.environ.copy()
        fake_developer_dir = self.create_fake_xcode(temp_dir / "Xcode.app", sdk_version="27.0")
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "CONFIRM_LOCAL_PRODUCTION_INSTALL": "1",
                "LOCAL_PRODUCTION_INSTALL_DIR": str(install_dir),
                "LOCAL_SIGNING_IDENTITY_REGISTRY_PATH": str(registry_path),
                "LOCAL_SIGNING_IDENTITY_INVENTORY_FIXTURE": str(fixture),
                "LOCAL_SIGNING_IDENTITY_EVALUATED_AT": "2030-01-01T00:00:00Z",
                "FAKE_BUILD_DIR": str(build_dir),
                "FAKE_DEVELOPER_DIR": str(fake_developer_dir),
                "FAKE_KEYCHAIN": str(keychain),
                "FAKE_DESIGNATED_TEAM": expected_team,
                "SECURITY_LOG": str(security_log),
                "SWIFT_LOG": str(swift_log),
                "PACKAGE_CAPTURE": str(package_capture),
                "FAIL_FINAL_INSTALL_MOVE": "1" if fail_final_install_move else "0",
                "FAIL_APP_BACKUP_MOVE": "1" if fail_app_backup_move else "0",
                "FAIL_REGISTRY_BACKUP_COPY": "1" if fail_registry_backup_copy else "0",
                "FAIL_REGISTRY_WRITE": "1" if fail_registry_write else "0",
                "FAIL_REGISTRY_RESTORE_COPY": "1" if fail_registry_restore_copy else "0",
                "FAIL_REGISTRY_READ_MARKER": str(temp_dir / "fail-registry-read"),
                "TMPDIR": str(installer_tmp),
                "FAKE_REGISTRY_PATH": str(registry_path),
                "FAKE_INSTALLED_APP": str(installed_app),
                "DEVELOPER_DIR": str(fake_developer_dir),
                "PGREP_LOG": str(pgrep_log),
                "FAKE_HEAD_COMMIT": HEAD_COMMIT,
                "FAKE_GIT_ROOT": str(release_source_root),
            }
        )
        if selected_team:
            env["LOCAL_SIGNING_TEAM_ID"] = selected_team
        if rotate:
            env["ROTATE_LOCAL_SIGNING_IDENTITY"] = "1"
        if split_release_source_root:
            env["REPOPROMPT_RELEASE_SOURCE_ROOT"] = str(release_source_root)
        env.update(process_guard.env)
        env.update(extra_env or {})

        context = {
            "command": ["bash", str(scripts / "install_local_production.sh")],
            "env": env,
            "install_dir": install_dir,
            "registry": registry_path,
            "package_capture": package_capture,
            "security_log": security_log,
            "swift_log": swift_log,
            "tmp_root": installer_tmp,
            "tooling_root": root,
            "scripts": scripts,
            "bin_dir": bin_dir,
            "release_source_root": release_source_root,
            "build_dir": build_dir,
            "prepared_app": release_source_root / ".build" / "local-production" / "RepoPrompt.app",
            "install_dir_before": directory_snapshot(install_dir),
            "installed_app": installed_app,
            "installed_app_before": directory_snapshot(installed_app),
            "registry_before": registry_path.read_bytes() if registry else None,
            "production_executable": production_executable,
            "process_guard": process_guard,
            "pgrep_log": pgrep_log,
        }
        return self.invoke(context, mode), context

    @staticmethod
    def invoke(
        context: dict[str, Any],
        mode: str | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [*context["command"], *([mode] if mode else [])],
            env={**context["env"], **(extra_env or {})},
            text=True,
            capture_output=True,
            timeout=15,
        )

    @staticmethod
    def prepared_provenance(context: dict[str, Any]) -> dict[str, Any]:
        path = context["prepared_app"] / "Contents" / "Resources" / "RepoPromptProvenance.json"
        return json.loads(path.read_text(encoding="utf-8"))

    @classmethod
    def edit_prepared_provenance(cls, context: dict[str, Any], **fields: Any) -> None:
        path = context["prepared_app"] / "Contents" / "Resources" / "RepoPromptProvenance.json"
        path.write_text(json.dumps({**cls.prepared_provenance(context), **fields}), encoding="utf-8")

    @staticmethod
    def edit_prepared_info_plist(context: dict[str, Any], **fields: Any) -> None:
        path = context["prepared_app"] / "Contents" / "Info.plist"
        path.write_bytes(plistlib.dumps({**plistlib.loads(path.read_bytes()), **fields}))

    @staticmethod
    def set_version_env(context: dict[str, Any], key: str, value: str) -> None:
        path = context["release_source_root"] / "version.env"
        path.write_text(
            re.sub(rf"^{key}=.*$", f"{key}={value}", path.read_text(encoding="utf-8"), flags=re.M),
            encoding="utf-8",
        )

    @staticmethod
    def write_registry(context: dict[str, Any], record: dict[str, Any]) -> None:
        context["registry"].write_text(json.dumps(record), encoding="utf-8")
        context["registry"].chmod(0o600)

    @staticmethod
    def registry(context: dict[str, Any]) -> dict[str, Any]:
        return json.loads(context["registry"].read_text(encoding="utf-8"))

    @staticmethod
    def requirement_line(output: str) -> str:
        return next(line for line in output.splitlines() if line.startswith("Packaged designated requirement:"))

    @staticmethod
    def create_fake_xcode(app_path: Path, *, sdk_version: str) -> Path:
        developer_dir = app_path / "Contents" / "Developer"
        (developer_dir / "usr" / "bin").mkdir(parents=True)
        (developer_dir / "Platforms" / "MacOSX.platform").mkdir(parents=True)
        xcodebuild = developer_dir / "usr" / "bin" / "xcodebuild"
        write_executable(xcodebuild, "#!/usr/bin/env bash\nexit 0\n")
        (developer_dir / ".fixture-sdk-version").write_text(f"{sdk_version}\n", encoding="utf-8")
        return developer_dir

    @classmethod
    def create_xcode_resolver_stubs(
        cls,
        root: Path,
        *,
        selected_path: Path | None = None,
        marker: Path | None = None,
    ) -> Path:
        bin_dir = root / "bin"
        bin_dir.mkdir(exist_ok=True)
        selected = str(selected_path or root / "CommandLineTools")
        marker_command = f"printf 'invoked\\n' > {str(marker)!r}\n" if marker else ""
        write_bash_stub(
            bin_dir,
            "xcode-select",
            f"""\
            {marker_command}printf '%s\\n' {selected!r}
            """,
        )
        write_bash_stub(
            bin_dir,
            "xcrun",
            """\
            [[ "$*" == "--sdk macosx --show-sdk-version" ]] || exit 64
            [[ -f "${DEVELOPER_DIR:-}/.fixture-sdk-version" ]] || exit 65
            cat "$DEVELOPER_DIR/.fixture-sdk-version"
            """,
        )
        return bin_dir


if __name__ == "__main__":
    unittest.main()
