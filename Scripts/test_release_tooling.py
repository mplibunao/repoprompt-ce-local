#!/usr/bin/env python3
"""Regression coverage for release packaging and rollout tooling."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import worktree_startup_live_benchmark  # noqa: E402
from script_test_support import (  # noqa: E402
    enter_context,
    temporary_directory,
    write_bash_stub,
    write_executable,
)
ROLLOUT_TOOL = SCRIPT_DIR / "stable_rollout.py"
POLICY = SCRIPT_DIR / "apple_identity_policy.json"
PROFILE_TOOL = SCRIPT_DIR / "embedded_provisioning_profile.py"
PROVENANCE_TOOL = SCRIPT_DIR / "write_bundle_provenance.py"
JOURNAL_SCHEMA_TOOL = SCRIPT_DIR / "read_working_journal_schema_version.py"
INFO_PLIST_TEMPLATE = ROOT_DIR / "AppBundle" / "Info.plist.template"
STAGED_RELEASE_VALIDATOR = SCRIPT_DIR / "validate_staged_release.sh"
PACKAGE_SCRIPT = SCRIPT_DIR / "package_app.sh"
ARCHITECTURE_VALIDATOR = SCRIPT_DIR / "validate_app_architectures.sh"
RESOURCE_BUNDLE_VALIDATOR = SCRIPT_DIR / "validate_required_swiftpm_resource_bundles.sh"
APP_ICON_DEBUG = ROOT_DIR / "AppBundle" / "AppIconDebug.icns"
TEMPLATE_TOKEN = re.compile(r"__[A-Z][A-Z0-9_]*__")


class StagedReleasePlistTests(unittest.TestCase):
    def test_raw_info_plist_template_is_parseable(self) -> None:
        template = plistlib.loads(INFO_PLIST_TEMPLATE.read_bytes())
        self.assertEqual(
            template["RepoPromptWorkingJournalSchemaVersion"],
            "__WORKING_JOURNAL_SCHEMA_VERSION__",
        )

    def test_expected_plist_renders_working_journal_schema_as_integer(self) -> None:
        result = subprocess.run(
            [sys.executable, str(JOURNAL_SCHEMA_TOOL), str(ROOT_DIR)],
            text=True,
            capture_output=True,
            check=True,
            timeout=10,
        )
        schema_version = result.stdout.strip()
        text = INFO_PLIST_TEMPLATE.read_text(encoding="utf-8")
        for key, value in {
            "__BUNDLE_NAME__": "RepoPrompt CE",
            "__EXECUTABLE_NAME__": "RepoPrompt",
            "__ICON_NAME__": "AppIcon",
            "__DISPLAY_NAME__": "RepoPrompt CE",
            "__BUNDLE_ID__": "com.repoprompt.ce",
            "__MARKETING_VERSION__": "1.0.0",
            "__BUILD_NUMBER__": "1",
            "__DEBUG_SECURE_STORAGE_BACKEND__": "alternate-in-memory",
            "__SIGNING_MODE__": "release-candidate-adhoc",
            "__LOCAL_SIGNING_CERTIFICATE_SHA256__": "",
            "__LOCAL_SECURE_STORAGE_GENERATION__": "",
            "__IDENTITY_MIGRATION_PHASE__": "disabled",
            "<string>__WORKING_JOURNAL_SCHEMA_VERSION__</string>": (
                f"<integer>{schema_version}</integer>"
            ),
        }.items():
            text = text.replace(key, value)

        expected_plist = plistlib.loads(text.encode("utf-8"))
        rendered_version = expected_plist["RepoPromptWorkingJournalSchemaVersion"]
        self.assertEqual(rendered_version, int(schema_version))
        self.assertIs(type(rendered_version), int)

        validator = STAGED_RELEASE_VALIDATOR.read_text(encoding="utf-8")
        self.assertIn(
            '"<string>__WORKING_JOURNAL_SCHEMA_VERSION__</string>": (',
            validator,
        )


PACKAGING_GUI_PAYLOAD = b"fixture RepoPrompt GUI product; RepoPromptKeyboardShortcutsResourceLookupV1\n"
PACKAGING_MCP_PAYLOAD = b"fixture repoprompt-mcp helper product\n"
PACKAGING_ICON_SENTINEL = b"fixture ordinary app icon sentinel\n"
PACKAGING_RELEASE_COMMIT = "0123456789abcdef0123456789abcdef01234567"

_CODEX_ARTIFACT_TOOL_STUB = '''#!/usr/bin/env python3
"""Fixture Codex artifact tool limited to the operations package_app.sh uses."""

import sys
from pathlib import Path

FIXTURE_ROOT = Path("{{FIXTURE_ROOT}}").resolve()
EXPECTED_MANIFEST = FIXTURE_ROOT / "source" / "Vendor" / "Codex" / "manifest.json"
EXPECTED_CACHE_ROOT = FIXTURE_ROOT / "codex-cache"
EXPECTED_ARCH = "{{CODEX_ARCH}}"
EXPECTED_BUNDLES = tuple(
    Path(raw).resolve()
    for raw in ({{CODEX_BUNDLES}})
)


def reject(message):
    raise SystemExit(f"fixture codex tool: {message}")


def resolved(value):
    return Path(value).resolve(strict=False)


arguments = sys.argv[1:]
if len(arguments) < 3 or arguments[0] != "--manifest":
    reject("expected --manifest <path> <operation> ...")
if resolved(arguments[1]) != EXPECTED_MANIFEST:
    reject(f"unexpected manifest path: {arguments[1]}")
if not Path(arguments[1]).is_file():
    reject(f"missing manifest: {arguments[1]}")
positional = arguments[2:]
operation = positional[0] if positional else ""
flags = {}
for index in range(1, len(positional), 2):
    if not positional[index].startswith("--") or index + 1 >= len(positional):
        reject(f"malformed operation arguments: {positional[index:]}")
    flags[positional[index]] = positional[index + 1]
expected_flags = {
    "manifest-version": set(),
    "acquire": {"--arch", "--cache-root"},
    "stage-bundle": {"--arch", "--cache-root", "--bundle"},
    "verify-bundle": {"--arch", "--bundle"},
}.get(operation)
if expected_flags is None:
    reject(f"unsupported operation: {operation!r}")
if set(flags) != expected_flags:
    reject(f"unsupported flags for {operation}: got {sorted(flags)}, expected {sorted(expected_flags)}")
if flags.get("--arch") not in (None, EXPECTED_ARCH):
    reject(f"unexpected architecture for {operation}: {flags.get('--arch')!r}")
if "--cache-root" in flags and resolved(flags["--cache-root"]) != EXPECTED_CACHE_ROOT:
    reject(f"unexpected cache root: {flags['--cache-root']}")
if "--bundle" in flags and resolved(flags["--bundle"]) not in EXPECTED_BUNDLES:
    reject(f"unexpected bundle destination: {flags['--bundle']}")

if operation == "manifest-version":
    print("0.42.0-fixture")
elif operation == "acquire":
    EXPECTED_CACHE_ROOT.mkdir(parents=True, exist_ok=True)
elif operation == "stage-bundle":
    bundle = resolved(flags["--bundle"])
    bundle.mkdir(parents=True, exist_ok=True)
    (bundle / "codex-fixture-runtime.txt").write_text("fixture codex runtime payload\\n", encoding="utf-8")
elif operation == "verify-bundle":
    if not (resolved(flags["--bundle"]) / "codex-fixture-runtime.txt").is_file():
        reject(f"bundle was not staged by this fixture: {flags['--bundle']}")
'''

_PROVENANCE_WRITER_STUB = '''#!/usr/bin/env python3
"""Fixture provenance writer pinned to the fixture's repo root and app bundle."""

import argparse
import json
from pathlib import Path

EXPECTED_REPO_ROOT = Path("{{REPO_ROOT}}").resolve()
EXPECTED_BUNDLE = Path("{{APP_BUNDLE}}").resolve()

parser = argparse.ArgumentParser()
parser.add_argument("--repo-root", required=True)
parser.add_argument("--bundle", required=True)
arguments = parser.parse_args()
if Path(arguments.repo_root).resolve(strict=False) != EXPECTED_REPO_ROOT:
    raise SystemExit(f"fixture provenance writer: unexpected repo root: {arguments.repo_root}")
if Path(arguments.bundle).resolve(strict=False) != EXPECTED_BUNDLE:
    raise SystemExit(f"fixture provenance writer: unexpected bundle: {arguments.bundle}")
resources = EXPECTED_BUNDLE / "Contents" / "Resources"
resources.mkdir(parents=True, exist_ok=True)
(resources / "RepoPromptProvenance.json").write_text(
    json.dumps(
        {
            "schema_version": 1,
            "git_status": "ok",
            "dirty": False,
            "commit": "0000000000000000000000000000000000000000",
            "untracked_files": [],
        },
        indent=2,
    )
    + "\\n",
    encoding="utf-8",
)
'''

_JSON_VALIDATOR_STUB = '''#!/usr/bin/env python3
"""Fixture JSON validator pinned to the fixture's provenance document."""

import json
import sys
from pathlib import Path

EXPECTED_DOCUMENT = Path("{{PROVENANCE_DOCUMENT}}").resolve()

if len(sys.argv) != 2:
    raise SystemExit("fixture json validator: expected one file argument")
document = Path(sys.argv[1])
if document.resolve(strict=False) != EXPECTED_DOCUMENT:
    raise SystemExit(f"fixture json validator: unexpected document: {document}")
json.loads(document.read_text(encoding="utf-8"))
'''

_ARTIFACT_MANIFEST_TOOL_STUB = '''#!/usr/bin/env python3
"""Fixture artifact-manifest tool pinned to the fixture's write/verify paths."""

import argparse
import json
from pathlib import Path

EXPECTED_ARCHITECTURES = "arm64,x86_64"
EXPECTED_WRITE_APP = Path("{{WRITE_APP}}").resolve()
EXPECTED_WRITE_OUTPUT = Path("{{WRITE_OUTPUT}}").resolve()
EXPECTED_VERIFY_APP = Path("{{VERIFY_APP}}").resolve()
EXPECTED_VERIFY_MANIFEST = Path("{{VERIFY_MANIFEST}}").resolve()

parser = argparse.ArgumentParser()
parser.add_argument("operation", choices=["write", "verify"])
parser.add_argument("--app", required=True)
parser.add_argument("--output")
parser.add_argument("--manifest")
parser.add_argument("--expected-architectures", required=True)
arguments = parser.parse_args()
if arguments.expected_architectures != EXPECTED_ARCHITECTURES:
    raise SystemExit(f"fixture artifact manifest: unexpected architectures: {arguments.expected_architectures}")


def document():
    return {
        "schema_version": 1,
        "app_bundle": Path(arguments.app).name,
        "expected_architectures": arguments.expected_architectures,
    }


if arguments.operation == "write":
    if Path(arguments.app).resolve(strict=False) != EXPECTED_WRITE_APP:
        raise SystemExit(f"fixture artifact manifest: unexpected write app bundle: {arguments.app}")
    if not arguments.output or Path(arguments.output).resolve(strict=False) != EXPECTED_WRITE_OUTPUT:
        raise SystemExit(f"fixture artifact manifest: unexpected write output: {arguments.output}")
    EXPECTED_WRITE_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    EXPECTED_WRITE_OUTPUT.write_text(json.dumps(document(), indent=2) + "\\n", encoding="utf-8")
else:
    if Path(arguments.app).resolve(strict=False) != EXPECTED_VERIFY_APP:
        raise SystemExit(f"fixture artifact manifest: unexpected verify app bundle: {arguments.app}")
    if not arguments.manifest or Path(arguments.manifest).resolve(strict=False) != EXPECTED_VERIFY_MANIFEST:
        raise SystemExit(f"fixture artifact manifest: unexpected verify manifest: {arguments.manifest}")
    if json.loads(EXPECTED_VERIFY_MANIFEST.read_text(encoding="utf-8")) != document():
        raise SystemExit("fixture artifact manifest does not match the packaged app")
'''


def _write_payload(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _render_stub(body: str, **values: str) -> str:
    for name, value in values.items():
        body = body.replace("{{" + name + "}}", value)
    return body


class _PackagingRunFixture:
    """A disposable tree that executes the real package_app.sh as a subprocess.

    The copied metadata loader, working-journal schema reader, SwiftPM resource-bundle
    scripts, and architecture validator run for real against fixture inputs, as does the
    plist renderer inside package_app.sh itself. The remaining substitutes constrain
    operations and arguments to varying degrees: the Codex, provenance, artifact-manifest,
    and JSON tools pin their configured fixture paths, while several no-op scripts check
    only argument shape. Only the codesign and install_name_tool substitutes record their
    argument lists; the `security` and `xcrun` sentinels record an invocation and fail.
    Compilation, Codex acquisition, signing, architecture reporting, and the substituted
    external verifications are simulated, so the real validators that consume them do not
    prove real architectures, valid signatures, or runtime authenticity. The build inputs
    provide only the `RepoPrompt` and `repoprompt-mcp` products, so a packaged
    `RepoPromptDebug` leaf shows that packaging performed the debug rename itself.
    """

    def __init__(
        self,
        root: Path,
        *,
        conf: str,
        architectures: str,
        bundle_id: str,
        with_staged_validator: bool = False,
    ) -> None:
        self.root = root
        self.conf = conf
        self.bundle_id = bundle_id
        self.source = root / "source"
        self.control = root / "control"
        self.bin = root / "bin"
        self.home = root / "home"
        self.tmp = root / "tmp"
        self.oplog = root / "oplog"
        self.build_template = root / "build-template"
        self.build_input = root / "build-input"
        self.staged = root / "staged"
        for directory in (self.source, self.control, self.bin, self.home, self.tmp, self.oplog):
            directory.mkdir(parents=True)
        self._write_source_tree()
        self._write_build_template()
        self._write_control_plane(with_staged_validator)
        self._write_command_substitutes(architectures)

    @property
    def app_bundle(self) -> Path:
        if self.conf == "release":
            return self.source / ".build" / "release" / "RepoPrompt.app"
        return self.root / "debug-app" / "RepoPrompt.app"

    @property
    def compat_bundle(self) -> Path:
        return self.source / ".build" / self.conf / "RepoPrompt.app"

    def environment(self, overrides: dict[str, str] | None = None) -> dict[str, str]:
        environment = {
            "PATH": f"{Path(sys.executable).parent}{os.pathsep}{self.bin}{os.pathsep}/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "CFFIXED_USER_HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "REPOPROMPT_RELEASE_SOURCE_ROOT": str(self.source),
            "REPOPROMPT_CONTROL_PLANE_SCRIPTS_DIR": str(self.control),
            "REPOPROMPT_DEBUG_APP_BUNDLE": str(self.root / "debug-app" / "RepoPrompt.app"),
            "REPOPROMPT_CODEX_CACHE_ROOT": str(self.root / "codex-cache"),
        }
        if self.conf == "release":
            environment["RELEASE_ALLOW_ADHOC_SIGNING"] = "1"
        else:
            environment["ALLOW_ADHOC_SIGNING"] = "1"
            environment["PREFER_STABLE_DEBUG_SIGNING"] = "0"
        environment.update(overrides or {})
        return environment

    def run(self, overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [str(PACKAGE_SCRIPT), self.conf],
                text=True,
                capture_output=True,
                env=self.environment(overrides),
                timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError(
                f"packaging fixture timed out (conf={self.conf}, overrides={overrides}): "
                f"stdout={error.stdout!r} stderr={error.stderr!r}"
            ) from error

    def run_staged_validator(self) -> subprocess.CompletedProcess[str]:
        environment = self.environment()
        environment["REPOPROMPT_APPROVED_SOURCE_ROOT"] = str(self.source)
        environment["REPOPROMPT_RELEASE_SOURCE_ROOT"] = str(self.staged)
        environment["RELEASE_COMMIT"] = PACKAGING_RELEASE_COMMIT
        try:
            return subprocess.run(
                [str(self.control / "validate_staged_release.sh")],
                text=True,
                capture_output=True,
                env=environment,
                timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            raise AssertionError(
                f"staged validation fixture timed out: stdout={error.stdout!r} stderr={error.stderr!r}"
            ) from error

    def read_packaged_plist(self) -> dict[str, object]:
        return plistlib.loads((self.app_bundle / "Contents" / "Info.plist").read_bytes())

    def recorded_operations(self, tool: str) -> list[list[str]]:
        log = self.oplog / f"{tool}.log"
        if not log.exists():
            return []
        return [shlex.split(line) for line in log.read_text(encoding="utf-8").splitlines() if line.strip()]

    def sentinel_invoked(self, tool: str) -> bool:
        return (self.oplog / f"{tool}.log").exists()

    def write_staged_payload(self) -> None:
        staged_release = self.staged / ".build" / "release"
        staged_release.mkdir(parents=True)
        shutil.copytree(self.app_bundle, staged_release / "RepoPrompt.app", symlinks=True)
        shutil.copy2(
            self.source / ".build" / "release" / "RepoPrompt-artifact-manifest.json",
            staged_release / "RepoPrompt-artifact-manifest.json",
        )
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "version.env"):
            shutil.copy2(self.source / name, self.staged / name)
        shutil.copytree(self.source / "ThirdPartyLicenses", self.staged / "ThirdPartyLicenses")
        (self.staged / "RELEASE_COMMIT").write_text(f"{PACKAGING_RELEASE_COMMIT}\n", encoding="utf-8")

    def _write_source_tree(self) -> None:
        shutil.copy2(ROOT_DIR / "version.env", self.source / "version.env")
        app_bundle = self.source / "AppBundle"
        app_bundle.mkdir()
        shutil.copy2(INFO_PLIST_TEMPLATE, app_bundle / "Info.plist.template")
        shutil.copy2(APP_ICON_DEBUG, app_bundle / "AppIconDebug.icns")
        (self.source / "LICENSE").write_text("fixture license\n", encoding="utf-8")
        (self.source / "THIRD_PARTY_NOTICES.md").write_text("fixture third-party notices\n", encoding="utf-8")
        third_party_licenses = self.source / "ThirdPartyLicenses"
        third_party_licenses.mkdir()
        (third_party_licenses / "fixture-library.txt").write_text(
            "fixture third-party license text\n", encoding="utf-8"
        )
        codex_vendor = self.source / "Vendor" / "Codex"
        codex_vendor.mkdir(parents=True)
        (codex_vendor / "manifest.json").write_text('{"version": "0.42.0-fixture"}\n', encoding="utf-8")
        domain_sources = self.source / "Sources" / "RepoPromptDomainRuntime"
        domain_sources.mkdir(parents=True)
        # The real schema reader accepts exactly one declaration of this shape.
        (domain_sources / "DomainPersistence.swift").write_text(
            "struct DomainWorkingJournal: Codable {\n    static let schemaVersion = 7\n}\n",
            encoding="utf-8",
        )
        app_resources = self.source / "AppResources"
        app_resources.mkdir()
        (app_resources / "AppIcon.icns").write_bytes(PACKAGING_ICON_SENTINEL)

    def _write_build_template(self) -> None:
        _write_payload(self.build_template / "RepoPrompt", PACKAGING_GUI_PAYLOAD)
        _write_payload(self.build_template / "repoprompt-mcp", PACKAGING_MCP_PAYLOAD)
        sparkle_binaries = self.build_template / "Sparkle.framework" / "Versions" / "B"
        for relative in (
            "Sparkle",
            "Autoupdate",
            "Updater.app/Contents/MacOS/Updater",
            "XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        ):
            _write_payload(sparkle_binaries / relative, f"fixture Sparkle binary {relative}\n".encode("utf-8"))
        shortcuts = self.build_template / "KeyboardShortcuts_KeyboardShortcuts.bundle"
        (shortcuts / "en.lproj").mkdir(parents=True)
        (shortcuts / "Info.plist").write_bytes(plistlib.dumps({}))
        (shortcuts / "en.lproj" / "Localizable.strings").write_text("", encoding="utf-8")

    def _write_control_plane(self, with_staged_validator: bool) -> None:
        real_scripts = [
            "load_release_metadata.sh",
            "normalize_swiftpm_resource_bundles.sh",
            "read_working_journal_schema_version.py",
            "run_without_github_tokens.sh",
            "validate_app_architectures.sh",
            "validate_required_swiftpm_resource_bundles.sh",
        ]
        if with_staged_validator:
            real_scripts.append("validate_staged_release.sh")
        for name in real_scripts:
            shutil.copy2(SCRIPT_DIR / name, self.control / name)

        write_bash_stub(
            self.control,
            "doctor.sh",
            '[[ "${1:-}" == "--quiet" ]] || { echo "fixture doctor: unsupported arguments: $*" >&2; exit 1; }\n',
        )
        write_bash_stub(
            self.control,
            "patch_keyboard_shortcuts_resource_lookup.sh",
            "[[ $# -eq 1 ]] || { echo \"fixture patcher: expected source root\" >&2; exit 1; }\n",
        )
        write_bash_stub(
            self.control,
            "verify_sparkle_vendor.sh",
            "[[ $# -eq 1 && -d \"$1\" ]] || { echo \"fixture sparkle verifier: missing framework: ${1:-}\" >&2; exit 1; }\n",
        )
        write_bash_stub(
            self.control,
            "build_swiftpm_release_products.sh",
            _render_stub(
                "[[ $# -eq 1 ]] || { echo \"fixture release builder: expected one destination argument\" >&2; exit 1; }\n"
                '[[ "$1" == "{{EXPECTED_DESTINATION}}" ]] || '
                '{ echo "fixture release builder: refusing unexpected destination: $1" >&2; exit 1; }\n'
                'rm -rf "$1"\n'
                'mkdir -p "$(dirname "$1")"\n'
                'cp -R "{{BUILD_TEMPLATE}}" "$1"\n',
                EXPECTED_DESTINATION=str(
                    self.source / ".build" / "public-release-products" / "release"
                ),
                BUILD_TEMPLATE=str(self.build_template),
            ),
        )
        write_bash_stub(
            self.control,
            "validate_embedded_mcp_helper_layout.sh",
            "[[ $# -eq 2 ]] || { echo \"fixture layout validator: expected bundle and label\" >&2; exit 1; }\n",
        )
        write_bash_stub(
            self.control,
            "smoke_embedded_mcp_helper.sh",
            "[[ $# -eq 2 ]] || { echo \"fixture helper smoke: expected bundle and label\" >&2; exit 1; }\n",
        )
        if with_staged_validator:
            write_bash_stub(
                self.control,
                "validate_packaged_legal.sh",
                "[[ $# -eq 1 ]] || { echo \"fixture legal validator: expected bundle\" >&2; exit 1; }\n",
            )
        staged_release_bundle = self.staged / ".build" / "release" / "RepoPrompt.app"
        codex_bundle_paths = [self.app_bundle / "Contents" / "Resources" / "BundledRuntimes" / "Codex"]
        if with_staged_validator:
            codex_bundle_paths.append(
                staged_release_bundle / "Contents" / "Resources" / "BundledRuntimes" / "Codex"
            )
        write_executable(
            self.control / "codex_runtime_artifact.py",
            _render_stub(
                _CODEX_ARTIFACT_TOOL_STUB,
                FIXTURE_ROOT=str(self.root),
                CODEX_ARCH="host" if self.conf == "debug" else "all",
                CODEX_BUNDLES="".join(f"\n        {str(path)!r}," for path in codex_bundle_paths),
            ),
        )
        write_executable(
            self.control / "write_bundle_provenance.py",
            _render_stub(
                _PROVENANCE_WRITER_STUB,
                REPO_ROOT=str(self.source),
                APP_BUNDLE=str(self.app_bundle),
            ),
        )
        write_executable(
            self.control / "validate_json.py",
            _render_stub(
                _JSON_VALIDATOR_STUB,
                PROVENANCE_DOCUMENT=str(
                    self.app_bundle / "Contents" / "Resources" / "RepoPromptProvenance.json"
                ),
            ),
        )
        write_executable(
            self.control / "write_app_artifact_manifest.py",
            _render_stub(
                _ARTIFACT_MANIFEST_TOOL_STUB,
                WRITE_APP=str(self.app_bundle),
                WRITE_OUTPUT=str(
                    self.source / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
                ),
                VERIFY_APP=str(staged_release_bundle),
                VERIFY_MANIFEST=str(
                    self.staged / ".build" / "release" / "RepoPrompt-artifact-manifest.json"
                ),
            ),
        )

    def _write_command_substitutes(self, architectures: str) -> None:
        write_bash_stub(
            self.bin,
            "swift",
            _render_stub(
                '[[ "${1:-}" == "build" ]] || { echo "fixture swift: unsupported invocation: $*" >&2; exit 1; }\n'
                "shift\n"
                'conf=""\n'
                'product=""\n'
                "show_bin_path=0\n"
                "while [[ $# -gt 0 ]]; do\n"
                '    case "$1" in\n'
                '        -c) conf="$2"; shift 2 ;;\n'
                '        --product) product="$2"; shift 2 ;;\n'
                "        --show-bin-path) show_bin_path=1; shift ;;\n"
                '        *) echo "fixture swift: unsupported argument: $1" >&2; exit 1 ;;\n'
                "    esac\n"
                "done\n"
                '[[ -n "$conf" ]] || { echo "fixture swift: missing -c configuration" >&2; exit 1; }\n'
                "if (( show_bin_path )); then\n"
                '    [[ -z "$product" ]] || { echo "fixture swift: unexpected --product alongside --show-bin-path" >&2; exit 1; }\n'
                '    echo "{{BUILD_INPUT}}"\n'
                "    exit 0\n"
                "fi\n"
                'case "$product" in\n'
                "    RepoPrompt | repoprompt-mcp) ;;\n"
                '    *) echo "fixture swift: unsupported product: ${product:-<missing>}" >&2; exit 1 ;;\n'
                "esac\n"
                'rm -rf "{{BUILD_INPUT}}"\n'
                'cp -R "{{BUILD_TEMPLATE}}" "{{BUILD_INPUT}}"\n',
                BUILD_INPUT=str(self.build_input),
                BUILD_TEMPLATE=str(self.build_template),
            ),
        )
        write_bash_stub(
            self.bin,
            "lipo",
            _render_stub(
                '[[ "${1:-}" == "-archs" && $# -eq 2 ]] || { echo "fixture lipo: unsupported invocation: $*" >&2; exit 1; }\n'
                '[[ -f "$2" ]] || { echo "fixture lipo: missing input: $2" >&2; exit 1; }\n'
                'echo "{{ARCHITECTURES}}"\n',
                ARCHITECTURES=architectures,
            ),
        )
        packaged_executable = "RepoPromptDebug" if self.conf == "debug" else "RepoPrompt"
        write_bash_stub(
            self.bin,
            "install_name_tool",
            _render_stub(
                "printf '%q ' \"$@\" >> \"{{LOG}}\"\n"
                "printf '\\n' >> \"{{LOG}}\"\n"
                "if [[ \"$#\" -eq 3 && \"${1:-}\" == \"-add_rpath\" "
                "&& \"${2:-}\" == \"@executable_path/../Frameworks\" "
                "&& \"$3\" == \"{{EXPECTED_TARGET}}\" ]]; then\n"
                '    [[ -f "$3" ]] || { echo "fixture install_name_tool: missing target: $3" >&2; exit 1; }\n'
                "    exit 0\n"
                "fi\n"
                'echo "fixture install_name_tool: unsupported invocation: $*" >&2\n'
                "exit 1\n",
                LOG=str(self.oplog / "install_name_tool.log"),
                EXPECTED_TARGET=str(
                    self.app_bundle / "Contents" / "MacOS" / packaged_executable
                ),
            ),
        )
        write_bash_stub(
            self.bin,
            "codesign",
            _render_stub(
                "printf '%q ' \"$@\" >> \"{{LOG}}\"\n"
                "printf '\\n' >> \"{{LOG}}\"\n"
                "target=\"${@: -1}\"\n"
                "python3 - \"$target\" <<'PY' || "
                "{ echo \"fixture codesign: target outside fixture: $target\" >&2; exit 1; }\n"
                "import sys\n"
                "from pathlib import Path\n"
                "\n"
                "root = Path(\"{{FIXTURE_ROOT}}\").resolve()\n"
                "resolved = Path(sys.argv[1]).resolve(strict=False)\n"
                "raise SystemExit(0 if resolved == root or root in resolved.parents else 1)\n"
                "PY\n"
                "if [[ \"${1:-}\" == \"-dv\" && \"$#\" -eq 3 && \"${2:-}\" == \"--verbose=4\" && -d \"$target\" ]]; then\n"
                '    echo "Identifier={{BUNDLE_ID}}"\n'
                '    echo "TeamIdentifier=not set"\n'
                "    exit 0\n"
                "fi\n"
                "if [[ \"${1:-}\" == \"--verify\" && \"$#\" -eq 5 && \"${2:-}\" == \"--deep\" && \"${3:-}\" == \"--strict\" "
                "&& \"${4:-}\" == \"--verbose=2\" && -d \"$target\" ]]; then\n"
                "    exit 0\n"
                "fi\n"
                "if [[ \"${1:-}\" == \"--force\" && \"${2:-}\" == \"--sign\" && \"${3:-}\" == \"-\" ]]; then\n"
                "    if [[ \"$#\" -eq 5 && \"${4:-}\" == \"--timestamp=none\" ]] || "
                "[[ \"$#\" -eq 6 && \"${4:-}\" == \"--timestamp=none\" "
                "&& \"${5:-}\" == \"--preserve-metadata=entitlements\" ]]; then\n"
                '        [[ -e "$target" ]] || { echo "fixture codesign: missing target: $target" >&2; exit 1; }\n'
                "        exit 0\n"
                "    fi\n"
                "fi\n"
                'echo "fixture codesign: unsupported invocation: $*" >&2\n'
                "exit 1\n",
                LOG=str(self.oplog / "codesign.log"),
                FIXTURE_ROOT=str(self.root),
                BUNDLE_ID=self.bundle_id,
            ),
        )
        for tool in ("security", "xcrun"):
            write_bash_stub(
                self.bin,
                tool,
                _render_stub(
                    'echo "{{TOOL}}" >> "{{LOG}}"\n'
                    'echo "fixture sentinel: {{TOOL}} must not be invoked by these packaging branches" >&2\n'
                    "exit 1\n",
                    TOOL=tool,
                    LOG=str(self.oplog / f"{tool}.log"),
                ),
            )


class DebugPackagingIdentityTests(unittest.TestCase):
    def test_packaged_artifact_identity_follows_conf_and_bundle_id_precedence(self) -> None:
        default_plists: dict[str, dict[str, object]] = {}
        cases = (
            ("debug defaults", "debug", {}, "com.pvncher.repoprompt.ce.debug"),
            (
                "debug DEBUG_BUNDLE_ID",
                "debug",
                {"DEBUG_BUNDLE_ID": "com.example.repoprompt.debug-override"},
                "com.example.repoprompt.debug-override",
            ),
            (
                "debug BUNDLE_ID wins over DEBUG_BUNDLE_ID",
                "debug",
                {
                    "DEBUG_BUNDLE_ID": "com.example.repoprompt.debug-override",
                    "BUNDLE_ID": "com.example.repoprompt.explicit",
                },
                "com.example.repoprompt.explicit",
            ),
            ("release defaults", "release", {}, "com.pvncher.repoprompt.ce"),
            (
                "release BUNDLE_ID",
                "release",
                {"BUNDLE_ID": "com.example.repoprompt.release-override"},
                "com.example.repoprompt.release-override",
            ),
        )
        for label, conf, overrides, expected_bundle_id in cases:
            with self.subTest(case=label):
                root = enter_context(self, temporary_directory(prefix="repoprompt-packaging-fixture-"))
                fixture = _PackagingRunFixture(
                    root,
                    conf=conf,
                    architectures="arm64 x86_64" if conf == "release" else "arm64",
                    bundle_id=expected_bundle_id,
                )
                result = fixture.run(overrides)
                self.assertEqual(result.returncode, 0, f"[{label}]\n{result.stdout}\n{result.stderr}")

                debug = conf == "debug"
                executable = "RepoPromptDebug" if debug else "RepoPrompt"
                icon = "AppIconDebug" if debug else "AppIcon"
                info = fixture.read_packaged_plist()
                if not overrides:
                    default_plists[conf] = info
                self.assertEqual(info["CFBundleName"], "RepoPromptDebug" if debug else "RepoPrompt CE")
                self.assertEqual(info["CFBundleDisplayName"], "RepoPrompt CE Debug" if debug else "RepoPrompt CE")
                self.assertEqual(info["CFBundleExecutable"], executable)
                self.assertEqual(info["CFBundleIconFile"], icon)
                self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLIconFile"], icon)
                self.assertEqual(info["CFBundleIdentifier"], expected_bundle_id)
                self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["repoprompt-ce"])
                self.assertEqual(info["RepoPromptWorkingJournalSchemaVersion"], 7)
                self.assertIs(type(info["RepoPromptWorkingJournalSchemaVersion"]), int)
                self.assertEqual(info["RepoPromptDebugSecureStorageBackend"], "alternate-in-memory")
                self.assertEqual(info["RepoPromptSigningMode"], "debug-adhoc" if debug else "release-candidate-adhoc")
                self.assertEqual(info["RepoPromptIdentityMigrationPhase"], "disabled")
                self.assertEqual(
                    TEMPLATE_TOKEN.findall(
                        (fixture.app_bundle / "Contents" / "Info.plist").read_text(encoding="utf-8")
                    ),
                    [],
                )

                macos = fixture.app_bundle / "Contents" / "MacOS"
                packaged_gui = macos / executable
                self.assertTrue(packaged_gui.is_file())
                self.assertFalse(packaged_gui.is_symlink())
                self.assertNotEqual(packaged_gui.stat().st_mode & stat.S_IXUSR, 0)
                self.assertEqual(packaged_gui.read_bytes(), PACKAGING_GUI_PAYLOAD)
                self.assertFalse((macos / ("RepoPrompt" if debug else "RepoPromptDebug")).exists())
                self.assertEqual((macos / "repoprompt-mcp").read_bytes(), PACKAGING_MCP_PAYLOAD)

                resources = fixture.app_bundle / "Contents" / "Resources"
                embedded_debug_icon = resources / "AppIconDebug.icns"
                if debug:
                    self.assertEqual(embedded_debug_icon.read_bytes(), APP_ICON_DEBUG.read_bytes())
                else:
                    self.assertFalse(embedded_debug_icon.exists())
                self.assertEqual((resources / "AppIcon.icns").read_bytes(), PACKAGING_ICON_SENTINEL)
                shortcuts = resources / "KeyboardShortcuts_KeyboardShortcuts.bundle"
                self.assertTrue((shortcuts / "Contents" / "Info.plist").is_file())
                self.assertTrue(
                    (shortcuts / "Contents" / "Resources" / "en.lproj" / "Localizable.strings").is_file()
                )

                rpath_operations = fixture.recorded_operations("install_name_tool")
                self.assertEqual(
                    rpath_operations,
                    [["-add_rpath", "@executable_path/../Frameworks", str(packaged_gui)]],
                )
                signing_operations = fixture.recorded_operations("codesign")
                self.assertIn(
                    ["--force", "--sign", "-", "--timestamp=none", str(packaged_gui)],
                    signing_operations,
                )
                self.assertIn(
                    ["--force", "--sign", "-", "--timestamp=none", str(fixture.app_bundle)],
                    signing_operations,
                )

                if debug:
                    self.assertTrue(fixture.compat_bundle.is_symlink())
                    self.assertEqual(os.readlink(fixture.compat_bundle), str(fixture.app_bundle))
                else:
                    self.assertTrue(fixture.app_bundle.is_dir())
                    self.assertFalse(fixture.app_bundle.is_symlink())

                for tool in ("security", "xcrun"):
                    self.assertFalse(fixture.sentinel_invoked(tool), f"[{label}] {tool} sentinel was invoked")
                for tool in ("codesign", "install_name_tool"):
                    for arguments in fixture.recorded_operations(tool):
                        for argument in arguments:
                            if argument.startswith("/"):
                                self.assertTrue(Path(argument).is_relative_to(root), argument)

        self.assertEqual(set(default_plists), {"debug", "release"})

        normalized = {
            conf: self._normalized_unaffected_fields(plist) for conf, plist in default_plists.items()
        }
        self.assertEqual(
            normalized["debug"],
            normalized["release"],
            "packaged debug and release plists differ outside the identity fields and the URL icon",
        )

    @staticmethod
    def _normalized_unaffected_fields(plist: dict[str, object]) -> dict[str, object]:
        normalized = copy.deepcopy(plist)
        for field in (
            "CFBundleName",
            "CFBundleDisplayName",
            "CFBundleExecutable",
            "CFBundleIconFile",
            "CFBundleIdentifier",
            "RepoPromptSigningMode",
        ):
            if field not in normalized:
                raise AssertionError(f"packaged plist is missing required field: {field}")
            del normalized[field]
        url_types = normalized["CFBundleURLTypes"]
        assert isinstance(url_types, list)
        for url_type in url_types:
            assert isinstance(url_type, dict)
            if "CFBundleURLIconFile" not in url_type:
                raise AssertionError("packaged URL type is missing CFBundleURLIconFile")
            del url_type["CFBundleURLIconFile"]
        return normalized

    def test_packaging_rejects_unresolved_plist_tokens_before_signing(self) -> None:
        unresolved = _PackagingRunFixture(
            enter_context(self, temporary_directory(prefix="repoprompt-renderer-fixture-")),
            conf="debug",
            architectures="arm64",
            bundle_id="com.pvncher.repoprompt.ce.debug",
        )
        template = unresolved.source / "AppBundle" / "Info.plist.template"
        template.write_text(
            template.read_text(encoding="utf-8").replace(
                "</dict>\n</plist>",
                "  <key>CFBundleDevelopmentRegion</key>"
                "<string>__UNRENDERED_FIXTURE_TOKEN__</string>\n</dict>\n</plist>",
            ),
            encoding="utf-8",
        )
        rejected = unresolved.run()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn(
            "unresolved Info.plist template tokens: __UNRENDERED_FIXTURE_TOKEN__",
            rejected.stdout + rejected.stderr,
        )
        self.assertEqual(unresolved.recorded_operations("codesign"), [])
        self.assertFalse((unresolved.app_bundle / "Contents" / "Info.plist").exists())

    def test_staged_release_accepts_packaged_plist_and_rejects_presentation_tampering(self) -> None:
        staged = _PackagingRunFixture(
            enter_context(self, temporary_directory(prefix="repoprompt-renderer-fixture-")),
            conf="release",
            architectures="arm64 x86_64",
            bundle_id="com.pvncher.repoprompt.ce",
            with_staged_validator=True,
        )
        packaged = staged.run()
        self.assertEqual(packaged.returncode, 0, f"{packaged.stdout}\n{packaged.stderr}")
        staged.write_staged_payload()
        accepted = staged.run_staged_validator()
        self.assertEqual(accepted.returncode, 0, f"{accepted.stdout}\n{accepted.stderr}")
        self.assertIn("OK: staged release payload matches approved source and confined path policy.", accepted.stdout)

        staged_plist = staged.staged / ".build" / "release" / "RepoPrompt.app" / "Contents" / "Info.plist"
        altered = plistlib.loads(staged_plist.read_bytes())
        altered["CFBundleDisplayName"] = "RepoPrompt CE Tampered"
        staged_plist.write_bytes(plistlib.dumps(altered))
        mismatch = staged.run_staged_validator()
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn(
            "staged Info.plist does not match the approved release candidate",
            mismatch.stdout + mismatch.stderr,
        )


class DebugProfileCutoverToolingTests(unittest.TestCase):
    """The debug runtime profile lives in its own sibling directory; the release rollback unit and
    the developer debug bundle keep their existing locations."""

    def setUp(self) -> None:
        self.home = enter_context(self, temporary_directory(prefix="repoprompt-cutover-home-"))
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("LOCAL_") and not key.startswith("REPOPROMPT_DEBUG_APP_")
        }
        self.env["HOME"] = str(self.home)

    def test_release_rollback_unit_locations_are_unchanged(self) -> None:
        script = (
            'source "$1"; printf "%s\\n" "$LOCAL_PRODUCTION_APP" "$LOCAL_PRODUCTION_EXECUTABLE" '
            '"$LOCAL_APP_SUPPORT_DIR" "$LOCAL_DEFAULTS_DOMAIN"'
        )
        result = subprocess.run(
            ["bash", "-c", script, "bash", str(SCRIPT_DIR / "local_release_env.sh")],
            cwd=ROOT_DIR,
            env=self.env,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "/Applications/RepoPrompt CE.app",
                "/Applications/RepoPrompt CE.app/Contents/MacOS/RepoPrompt",
                f"{self.home}/Library/Application Support/RepoPrompt CE",
                "com.pvncher.repoprompt.ce",
            ],
        )

    def test_developer_debug_bundle_location_is_unchanged(self) -> None:
        result = subprocess.run(
            [sys.executable, "-c", "import conductor; print(conductor.debug_app_bundle_path())"],
            cwd=SCRIPT_DIR,
            env=self.env,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.strip(),
            f"{self.home}/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app",
        )


class PackagedExecutableValidatorTests(unittest.TestCase):
    PATCH_MARKER = b"RepoPromptKeyboardShortcutsResourceLookupV1"

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.app = self.root / "RepoPrompt.app"
        self.lipo = self.root / "lipo"
        self.lipo.write_text("#!/bin/sh\necho arm64\n", encoding="utf-8")
        self.lipo.chmod(0o755)

    def write_bundle(self, leaves: tuple[str, ...] = ("RepoPromptDebug",), declared: str | None = "RepoPromptDebug") -> None:
        shutil.rmtree(self.app, ignore_errors=True)
        macos = self.app / "Contents" / "MacOS"
        macos.mkdir(parents=True)
        for leaf in (*leaves, "repoprompt-mcp"):
            (macos / leaf).write_bytes(b"binary " + self.PATCH_MARKER)
            (macos / leaf).chmod(0o755)
        shortcuts = self.app / "Contents" / "Resources" / "KeyboardShortcuts_KeyboardShortcuts.bundle" / "Contents"
        (shortcuts / "Resources" / "en.lproj").mkdir(parents=True)
        (shortcuts / "Info.plist").write_bytes(plistlib.dumps({}))
        (shortcuts / "Resources" / "en.lproj" / "Localizable.strings").write_text("", encoding="utf-8")
        if declared is not None:
            (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": declared}))

    def run_validator(self, script: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(script), str(self.app), *arguments],
            text=True,
            capture_output=True,
            env={**os.environ, "LIPO": str(self.lipo)},
            timeout=30,
        )

    def test_architecture_validator_follows_the_declared_executable(self) -> None:
        for declared in ("RepoPromptDebug", "RepoPrompt"):
            with self.subTest(declared=declared):
                self.write_bundle(leaves=(declared,), declared=declared)
                result = self.run_validator(ARCHITECTURE_VALIDATOR, "matching", "fixture")
                self.assertEqual(result.returncode, 0, result.stderr)
        self.write_bundle(leaves=("RepoPromptDebug",), declared="RepoPrompt")
        result = self.run_validator(ARCHITECTURE_VALIDATOR, "matching", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected non-symlink executable", result.stderr)

    def test_public_universal_policy_requires_the_release_executable(self) -> None:
        self.lipo.write_text("#!/bin/sh\necho x86_64 arm64\n", encoding="utf-8")
        sparkle_binaries = (
            "Sparkle",
            "Autoupdate",
            "Updater.app/Contents/MacOS/Updater",
            "XPCServices/Installer.xpc/Contents/MacOS/Installer",
            "XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
        )
        for declared, expected_code in (("RepoPromptDebug", 1), ("RepoPrompt", 0)):
            with self.subTest(declared=declared):
                self.write_bundle(leaves=(declared,), declared=declared)
                for relative in sparkle_binaries:
                    binary = self.app / "Contents" / "Frameworks" / "Sparkle.framework" / "Versions" / "B" / relative
                    binary.parent.mkdir(parents=True, exist_ok=True)
                    binary.write_bytes(b"binary")
                    binary.chmod(0o755)

                result = self.run_validator(ARCHITECTURE_VALIDATOR, "arm64,x86_64", "fixture")

                self.assertEqual(result.returncode, expected_code, result.stdout + result.stderr)
                if expected_code:
                    self.assertIn("requires the release executable Contents/MacOS/RepoPrompt", result.stderr)
                    self.assertIn("declares RepoPromptDebug", result.stderr)
                else:
                    self.assertIn("passed universal architecture policy", result.stdout)

    def test_architecture_validator_rejects_malformed_or_missing_executable_metadata(self) -> None:
        for declared in ("", ".", "..", "../RepoPromptDebug", "MacOS/RepoPromptDebug", None):
            with self.subTest(declared=declared):
                self.write_bundle(declared=declared)
                result = self.run_validator(ARCHITECTURE_VALIDATOR, "matching", "fixture")
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, "invalid CFBundleExecutable|could not read CFBundleExecutable")
        self.write_bundle(leaves=())
        (self.app / "Contents" / "MacOS" / "RepoPromptDebug").symlink_to(self.app / "Contents" / "MacOS" / "repoprompt-mcp")
        result = self.run_validator(ARCHITECTURE_VALIDATOR, "matching", "fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("expected non-symlink executable", result.stderr)

    def test_resource_validator_names_the_executable_before_info_plist_exists(self) -> None:
        self.write_bundle(declared=None)
        self.assertEqual(self.run_validator(RESOURCE_BUNDLE_VALIDATOR, "fixture", "RepoPromptDebug").returncode, 0)
        for arguments, message in (
            (("fixture",), "missing required SwiftPM resource bundle file"),
            (("fixture", "RepoPrompt"), "missing required SwiftPM resource bundle file"),
            (("fixture", "../RepoPromptDebug"), "invalid packaged executable name"),
        ):
            with self.subTest(arguments=arguments):
                result = self.run_validator(RESOURCE_BUNDLE_VALIDATOR, *arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)

    def test_resource_validator_requires_agreement_once_info_plist_exists(self) -> None:
        self.write_bundle(leaves=("RepoPromptDebug", "RepoPrompt"))
        self.assertEqual(self.run_validator(RESOURCE_BUNDLE_VALIDATOR, "fixture").returncode, 0)
        self.assertEqual(self.run_validator(RESOURCE_BUNDLE_VALIDATOR, "fixture", "RepoPromptDebug").returncode, 0)
        disagreement = self.run_validator(RESOURCE_BUNDLE_VALIDATOR, "fixture", "RepoPrompt")
        self.assertNotEqual(disagreement.returncode, 0)
        self.assertIn("declares executable 'RepoPromptDebug', expected 'RepoPrompt'", disagreement.stdout + disagreement.stderr)
        (self.app / "Contents" / "MacOS" / "RepoPromptDebug").write_bytes(b"binary without marker")
        unpatched = self.run_validator(RESOURCE_BUNDLE_VALIDATOR, "fixture")
        self.assertNotEqual(unpatched.returncode, 0)
        self.assertIn("patch marker", unpatched.stdout + unpatched.stderr)

    def test_benchmark_build_identity_hashes_the_declared_app_executable(self) -> None:
        plan = {"dataset": {"base_commit_oid": "0" * 40}}
        for declared in ("RepoPromptDebug", "RepoPrompt"):
            with self.subTest(declared=declared):
                self.write_bundle(leaves=(declared,), declared=declared)
                executable = self.app / "Contents" / "MacOS" / declared
                executable.write_bytes(f"{declared} binary".encode())
                link = self.root / "rpce-cli-debug"
                link.unlink(missing_ok=True)
                link.symlink_to(self.app / "Contents" / "MacOS" / "repoprompt-mcp")

                identity = worktree_startup_live_benchmark.exact_live_build_identity(link, plan)

                self.assertEqual(identity["app_executable_sha256"], hashlib.sha256(executable.read_bytes()).hexdigest())
        self.write_bundle(leaves=("RepoPrompt",), declared="RepoPromptDebug")
        with self.assertRaisesRegex(worktree_startup_live_benchmark.BenchmarkError, "exact RepoPrompt app executable"):
            worktree_startup_live_benchmark.exact_live_build_identity(self.app / "Contents" / "MacOS" / "repoprompt-mcp", plan)
        loose_cli = self.root / "repoprompt-mcp"
        loose_cli.write_bytes(b"cli")
        with self.assertRaisesRegex(worktree_startup_live_benchmark.BenchmarkError, "not inside an app bundle"):
            worktree_startup_live_benchmark.exact_live_build_identity(loose_cli, plan)


class BundleProvenanceTests(unittest.TestCase):
    def git(self, root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", "-C", str(root), *arguments],
            text=True,
            capture_output=True,
            check=True,
            timeout=10,
        )

    def test_provenance_separates_tracked_changes_from_untracked_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repository"
            bundle = Path(temp) / "RepoPrompt.app"
            resources = bundle / "Contents" / "Resources"
            root.mkdir()
            resources.mkdir(parents=True)
            self.git(root, "init", "-q")
            self.git(root, "config", "user.name", "RepoPrompt Test")
            self.git(root, "config", "user.email", "test@example.invalid")
            tracked = root / "tracked.txt"
            tracked.write_text("committed\n", encoding="utf-8")
            self.git(root, "add", "tracked.txt")
            self.git(root, "commit", "-q", "-m", "fixture")

            untracked_directory = root / "untracked"
            untracked_directory.mkdir()
            (untracked_directory / "local.txt").write_text("local\n", encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(PROVENANCE_TOOL),
                    "--repo-root",
                    str(root),
                    "--bundle",
                    str(bundle),
                ],
                text=True,
                capture_output=True,
                check=True,
                timeout=10,
            )
            provenance_path = resources / "RepoPromptProvenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            self.assertFalse(provenance["dirty"])
            self.assertEqual(provenance["git_status"], "ok")
            self.assertTrue(provenance["untracked_files"])

            tracked.write_text("modified\n", encoding="utf-8")
            subprocess.run(
                [
                    sys.executable,
                    str(PROVENANCE_TOOL),
                    "--repo-root",
                    str(root),
                    "--bundle",
                    str(bundle),
                ],
                text=True,
                capture_output=True,
                check=True,
                timeout=10,
            )
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            self.assertTrue(provenance["dirty"])
            self.assertEqual(provenance["git_status"], "ok")
            self.assertTrue(provenance["untracked_files"])

            real_git = shutil.which("git")
            self.assertIsNotNone(real_git)
            fake_bin = Path(temp) / "fake-bin"
            fake_bin.mkdir()
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/bin/sh\n"
                'if [ "$3" = "status" ]; then\n'
                "    exit 1\n"
                "fi\n"
                'exec "$REAL_GIT" "$@"\n',
                encoding="utf-8",
            )
            fake_git.chmod(fake_git.stat().st_mode | stat.S_IXUSR)
            environment = dict(os.environ)
            environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
            environment["REAL_GIT"] = str(real_git)
            subprocess.run(
                [
                    sys.executable,
                    str(PROVENANCE_TOOL),
                    "--repo-root",
                    str(root),
                    "--bundle",
                    str(bundle),
                ],
                text=True,
                capture_output=True,
                check=True,
                env=environment,
                timeout=10,
            )
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            self.assertIsNone(provenance["dirty"])
            self.assertEqual(provenance["git_status"], "unavailable")
            self.assertIsNone(provenance["untracked_files"])


class StableTipFloorTests(unittest.TestCase):
    def rollout(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(ROLLOUT_TOOL), *arguments],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            timeout=30,
        )

    @staticmethod
    def declaration(
        path: Path,
        role: str,
        predecessors: list[dict[str, str]] | None = None,
        reset_authority: dict[str, object] | None = None,
    ) -> None:
        declaration = {
            "schemaVersion": 2 if reset_authority is not None else 1,
            "channel": "tip",
            "currentRole": role,
            "eligibilityProfile": "tip-identity-dress-rehearsal-v1",
            "expectedMigrationPhase": (
                "legacy-preparer" if role == "preparer" else "disabled"
            ),
            "expectedSigningIdentity": (
                "legacy" if role == "preparer" else "successor"
            ),
            "predecessors": predecessors or [],
        }
        if reset_authority is not None:
            declaration["resetAuthority"] = reset_authority
        path.write_text(json.dumps(declaration, indent=2) + "\n", encoding="utf-8")

    def generate_release(
        self,
        root: Path,
        label: str,
        role: str,
        build: str,
        predecessor: dict[str, object] | None = None,
        tag: str | None = None,
        marketing_version: str = "1.4.0",
        reset_authority: dict[str, object] | None = None,
    ) -> dict[str, Path | str]:
        release_root = root / label
        release_root.mkdir()
        release_tag = tag or f"tip-{label}"
        predecessor_entries: list[dict[str, str]] = []
        predecessor_paths: list[Path] = []
        if predecessor is not None:
            predecessor_manifest = predecessor["manifest"]
            assert isinstance(predecessor_manifest, Path)
            predecessor_entries.append(
                {
                    "role": str(predecessor["role"]),
                    "tag": str(predecessor["tag"]),
                    "rolloutManifestSha256": hashlib.sha256(
                        predecessor_manifest.read_bytes()
                    ).hexdigest(),
                }
            )
            predecessor_paths.append(predecessor_manifest)

        declaration_path = release_root / "tip-rollout.json"
        self.declaration(
            declaration_path,
            role,
            predecessor_entries,
            reset_authority,
        )
        is_preparer = role == "preparer"
        version_env = release_root / "version.env"
        version_env.write_text(
            "APP_NAME=RepoPrompt\n"
            f"MARKETING_VERSION={marketing_version}\n"
            f"BUILD_NUMBER={build}\n"
            f"BUNDLE_ID={'com.pvncher.repoprompt.ce' if is_preparer else 'com.repoprompt.ce'}\n"
            f"SIGNING_TEAM_ID={'648A27MST5' if is_preparer else '69N6K965SF'}\n",
            encoding="utf-8",
        )
        enclosure_basename = f"RepoPrompt-{label}-{build}"
        enclosure = release_root / (
            enclosure_basename + (".zip" if is_preparer else ".pkg")
        )
        enclosure.write_text(f"fixture enclosure {label}\n", encoding="utf-8")
        artifact_manifest = release_root / "artifact-manifest.json"
        artifact_manifest.write_text('{"schema_version":1}\n', encoding="utf-8")
        appcast = release_root / "appcast.xml"
        manifest = release_root / "identity-rollout.json"
        arguments = [
            "generate",
            "--declaration",
            str(declaration_path),
            "--policy",
            str(POLICY),
            "--version-env",
            str(version_env),
            "--release-tag",
            release_tag,
            "--release-commit",
            hashlib.sha1(label.encode("utf-8")).hexdigest(),
            "--migration-phase",
            "legacy-preparer" if is_preparer else "disabled",
            "--enclosure",
            str(enclosure),
            "--enclosure-basename",
            enclosure_basename,
            "--enclosure-signature",
            f"fixture-signature-{label}",
            "--app-artifact-manifest",
            str(artifact_manifest),
            "--appcast-output",
            str(appcast),
            "--manifest-output",
            str(manifest),
        ]
        for predecessor_path in predecessor_paths:
            arguments.extend(("--predecessor-manifest", str(predecessor_path)))
        result = self.rollout(*arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return {
            "role": role,
            "tag": release_tag,
            "manifest": manifest,
            "appcast": appcast,
            "declaration": declaration_path,
        }

    @staticmethod
    def stable_appcast(path: Path, build: str, marketing_version: str) -> None:
        path.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
            "  <channel>\n"
            "    <item>\n"
            f"      <sparkle:shortVersionString>{marketing_version}</sparkle:shortVersionString>\n"
            f"      <sparkle:version>{build}</sparkle:version>\n"
            "    </item>\n"
            "  </channel>\n"
            "</rss>\n",
            encoding="utf-8",
        )

    def validate_floor(
        self,
        stable_appcast: Path,
        tip_release: dict[str, Path | str],
    ) -> subprocess.CompletedProcess[str]:
        return self.rollout(
            "validate-stable-tip-floor",
            "--policy",
            str(POLICY),
            "--stable-appcast",
            str(stable_appcast),
            "--tip-manifest",
            str(tip_release["manifest"]),
            "--tip-appcast",
            str(tip_release["appcast"]),
        )

    def validate_progression(
        self,
        candidate: dict[str, Path | str],
        live: dict[str, Path | str],
        declaration: Path | None = None,
        stable_appcast: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            "validate-live-tip-progression",
            "--policy",
            str(POLICY),
            "--candidate-manifest",
            str(candidate["manifest"]),
            "--candidate-appcast",
            str(candidate["appcast"]),
            "--live-manifest",
            str(live["manifest"]),
            "--live-appcast",
            str(live["appcast"]),
        ]
        if declaration is not None:
            assert stable_appcast is not None
            arguments.extend(
                (
                    "--declaration",
                    str(declaration),
                    "--stable-appcast",
                    str(stable_appcast),
                )
            )
        return self.rollout(*arguments)

    def test_transition_to_replacement_preparer_requires_exact_reset_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture_root = Path(temporary_directory)
            stable_appcast = fixture_root / "stable-appcast.xml"
            self.stable_appcast(stable_appcast, "36", "1.4.0")

            stale_preparer = self.generate_release(
                fixture_root,
                "preparer-stale",
                "preparer",
                "35.15.18",
                tag="tip-2f94412e6ab5",
            )
            live_transition = self.generate_release(
                fixture_root,
                "transition-live",
                "transition",
                "35.15.39",
                predecessor=stale_preparer,
                tag="tip-57b572038048",
            )
            stale_floor = self.validate_floor(stable_appcast, live_transition)
            self.assertNotEqual(stale_floor.returncode, 0)
            self.assertIn("Stable=36 preparer=35.15.18", stale_floor.stderr)

            live_manifest_digest = hashlib.sha256(
                Path(live_transition["manifest"]).read_bytes()
            ).hexdigest()
            stale_preparer_digest = hashlib.sha256(
                Path(stale_preparer["manifest"]).read_bytes()
            ).hexdigest()
            reset_authority = {
                "type": "transition-to-replacement-preparer-v1",
                "liveTip": {
                    "role": "transition",
                    "tag": "tip-57b572038048",
                    "buildNumber": "35.15.39",
                    "rolloutManifestSha256": live_manifest_digest,
                },
                "stableEpoch": {
                    "marketingVersion": "1.4.0",
                    "buildNumber": "36",
                },
                "retainedPreparer": {
                    "role": "preparer",
                    "tag": "tip-2f94412e6ab5",
                    "buildNumber": "35.15.18",
                    "rolloutManifestSha256": stale_preparer_digest,
                },
            }
            replacement_preparer = self.generate_release(
                fixture_root,
                "preparer-replacement",
                "preparer",
                "36.0.1",
                tag="tip-aaaaaaaaaaaa",
                reset_authority=reset_authority,
            )

            without_reset = self.validate_progression(replacement_preparer, live_transition)
            self.assertNotEqual(without_reset.returncode, 0)
            self.assertIn(
                "candidate Tip rollout role would regress or skip the live rollout state",
                without_reset.stderr,
            )

            with_reset = self.validate_progression(
                replacement_preparer,
                live_transition,
                Path(replacement_preparer["declaration"]),
                stable_appcast,
            )
            self.assertEqual(with_reset.returncode, 0, with_reset.stderr)
            self.assertIn("explicit Tip reset authorized", with_reset.stdout)
            self.assertIn("tip-57b572038048 (35.15.39)", with_reset.stdout)
            self.assertIn("tip-2f94412e6ab5 (35.15.18)", with_reset.stdout)

            low_replacement = self.generate_release(
                fixture_root,
                "preparer-too-low",
                "preparer",
                "35.15.40",
                tag="tip-bbbbbbbbbbbb",
                reset_authority=reset_authority,
            )
            too_low = self.validate_progression(
                low_replacement,
                live_transition,
                Path(low_replacement["declaration"]),
                stable_appcast,
            )
            self.assertNotEqual(too_low.returncode, 0)
            self.assertIn("newer than both live Tip and Stable", too_low.stderr)

            valid_declaration = json.loads(
                Path(replacement_preparer["declaration"]).read_text(encoding="utf-8")
            )
            tampered_cases = [
                ("missing reset", "missing", "explicit checked-in resetAuthority"),
                ("wrong type", "type", "resetAuthority type must be"),
                ("live tag", "live-tag", "live Tip tag mismatch"),
                ("live build", "live-build", "live Tip buildNumber mismatch"),
                ("live digest", "live-digest", "live Tip manifest digest mismatch"),
                ("Stable marketing", "stable-marketing", "Stable epoch marketingVersion mismatch"),
                ("Stable build", "stable-build", "Stable epoch buildNumber mismatch"),
                ("retained tag", "retained-tag", "retained preparer tag mismatch"),
                ("retained build", "retained-build", "retained preparer buildNumber mismatch"),
                ("retained digest", "retained-digest", "retained preparer rolloutManifestSha256 mismatch"),
            ]
            for label, mutation, diagnostic in tampered_cases:
                declaration = copy.deepcopy(valid_declaration)
                if mutation == "missing":
                    declaration["schemaVersion"] = 1
                    del declaration["resetAuthority"]
                elif mutation == "type":
                    declaration["resetAuthority"]["type"] = "not-a-reset"
                elif mutation == "live-tag":
                    declaration["resetAuthority"]["liveTip"]["tag"] = "tip-cccccccccccc"
                elif mutation == "live-build":
                    declaration["resetAuthority"]["liveTip"]["buildNumber"] = "35.15.38"
                elif mutation == "live-digest":
                    declaration["resetAuthority"]["liveTip"]["rolloutManifestSha256"] = "0" * 64
                elif mutation == "stable-marketing":
                    declaration["resetAuthority"]["stableEpoch"]["marketingVersion"] = "1.3.0"
                elif mutation == "stable-build":
                    declaration["resetAuthority"]["stableEpoch"]["buildNumber"] = "35"
                elif mutation == "retained-tag":
                    declaration["resetAuthority"]["retainedPreparer"]["tag"] = "tip-dddddddddddd"
                elif mutation == "retained-build":
                    declaration["resetAuthority"]["retainedPreparer"]["buildNumber"] = "35.15.17"
                elif mutation == "retained-digest":
                    declaration["resetAuthority"]["retainedPreparer"]["rolloutManifestSha256"] = "1" * 64
                else:
                    self.fail(f"unhandled mutation: {mutation}")
                tampered_declaration = fixture_root / f"tampered-{mutation}.json"
                tampered_declaration.write_text(
                    json.dumps(declaration, indent=2) + "\n", encoding="utf-8"
                )
                result = self.validate_progression(
                    replacement_preparer,
                    live_transition,
                    tampered_declaration,
                    stable_appcast,
                )
                with self.subTest(case=label):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(diagnostic, result.stderr)


class EmbeddedProvisioningProfileTests(unittest.TestCase):
    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(PROFILE_TOOL), *arguments],
            cwd=ROOT_DIR,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def test_install_normalizes_owner_only_source_to_deployed_readable_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "release.provisionprofile"
            destination = root / "RepoPrompt.app" / "Contents" / "embedded.provisionprofile"
            payload = b"fixture provisioning profile\n"
            source.write_bytes(payload)
            source.chmod(0o600)

            result = self.run_tool("install", str(source), str(destination))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(destination.read_bytes(), payload)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o644)
            self.assertNotEqual(destination.stat().st_mode & stat.S_IROTH, 0)
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o600)

    def test_install_replaces_destination_symlink_without_mutating_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "release.provisionprofile"
            target = root / "protected-target"
            destination = root / "RepoPrompt.app" / "Contents" / "embedded.provisionprofile"
            source.write_bytes(b"fixture provisioning profile\n")
            source.chmod(0o600)
            target.write_bytes(b"protected target\n")
            target.chmod(0o600)
            destination.parent.mkdir(parents=True)
            destination.symlink_to(target)

            result = self.run_tool("install", str(source), str(destination))

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(destination.is_symlink())
            self.assertEqual(destination.read_bytes(), source.read_bytes())
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o644)
            self.assertEqual(target.read_bytes(), b"protected target\n")
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_validate_rejects_sealed_profile_unreadable_by_non_owner(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            profile = Path(temporary_directory) / "embedded.provisionprofile"
            profile.write_bytes(b"fixture provisioning profile\n")
            profile.chmod(0o600)

            result = self.run_tool("validate", str(profile))

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must use deployed-readable mode 0644, got 0600", result.stderr)

    def test_every_release_signing_path_installs_and_validates_profile_before_distribution(self) -> None:
        cases = (
            ("package_app.sh", 'phase "Signing app bundle"'),
            ("sign_staged_release.sh", "sign_path() {"),
        )
        for filename, signing_marker in cases:
            source = (SCRIPT_DIR / filename).read_text(encoding="utf-8")
            install = source.index('embedded_provisioning_profile.py" install')
            validate = source.index('embedded_provisioning_profile.py" validate')
            strict_verification = source.rindex('codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"')
            with self.subTest(script=filename):
                self.assertLess(install, source.index(signing_marker))
                self.assertGreater(validate, strict_verification)
                self.assertNotIn(
                    'cp "$REPOPROMPT_PROVISIONING_PROFILE"',
                    source,
                )


if __name__ == "__main__":
    unittest.main()
