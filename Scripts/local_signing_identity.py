#!/usr/bin/env python3
"""Inventory and resolve the Apple Development identity that signs local production builds.

The production inventory reads command output from ``security`` and ``openssl``.
Tests may pass an offline JSON fixture so no Keychain command is executed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2
SELF_SIGNED_SCHEMA_VERSION = 1
INVENTORY_SCHEMA_VERSION = 2
CERTIFICATE_NAME_PREFIX = "Apple Development: "
TEAM_PATTERN = re.compile(r"^[0-9A-Z]{10}$")
SHA1_PATTERN = re.compile(r"^[0-9A-F]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9A-F]{64}$")
KEYCHAIN_SERVICE_PATTERN = re.compile(
    r"^com\.pvncher\.repoprompt\.ce\.local-"
    r"(apple-development\.[0-9A-Z]{10}|self-signed\.[0-9a-f]{64})"
    r"\.keychain\.v[1-9][0-9]*$"
)
IDENTITY_LINE_PATTERN = re.compile(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$')
PEM_PATTERN = re.compile(
    rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    re.DOTALL,
)
XCODE_CERTIFICATE_HINT = (
    "Create or renew one in Xcode: Settings > Accounts > select the team > Manage Certificates > "
    "+ > Apple Development."
)


class IdentityError(RuntimeError):
    pass


@dataclass(frozen=True)
class CertificateRecord:
    commonName: str
    teamIdentifier: str
    sha1: str
    notAfter: str
    hasPrivateKey: bool
    isExpired: bool


@dataclass(frozen=True)
class RegistryRecord:
    schemaVersion: int
    teamIdentifier: str
    keychainService: str


@dataclass(frozen=True)
class SelfSignedRegistryRecord:
    """The schema 1 record a self-signed local install wrote."""

    schemaVersion: int
    certificateName: str
    certificateSHA256: str
    serviceGeneration: int

    @property
    def keychainService(self) -> str:
        return (
            "com.pvncher.repoprompt.ce.local-self-signed."
            f"{self.certificateSHA256.lower()}.keychain.v{self.serviceGeneration}"
        )


def normalize_sha1(value: str) -> str:
    normalized = "".join(character for character in value.upper() if character in "0123456789ABCDEF")
    if not SHA1_PATTERN.fullmatch(normalized):
        raise IdentityError("Expected a 40-character hexadecimal certificate SHA-1 fingerprint.")
    return normalized


def normalize_team(value: str) -> str:
    normalized = value.strip().upper()
    if not TEAM_PATTERN.fullmatch(normalized):
        raise IdentityError(f"Expected a 10-character Apple Team ID, got '{value}'.")
    return normalized


def validate_keychain_service(value: str) -> str:
    if not KEYCHAIN_SERVICE_PATTERN.fullmatch(value):
        raise IdentityError(f"Not a local production Keychain service name: '{value}'.")
    return value


def run_command(arguments: list[str], *, input_data: bytes | None = None) -> bytes:
    result = subprocess.run(arguments, input=input_data, capture_output=True, check=False)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise IdentityError(f"Command failed ({' '.join(arguments)}): {stderr or 'no diagnostic output'}")
    return result.stdout


def parse_identity_hashes(output: str) -> set[str]:
    hashes: set[str] = set()
    for line in output.splitlines():
        match = IDENTITY_LINE_PATTERN.match(line)
        if match and match.group(2).startswith(CERTIFICATE_NAME_PREFIX):
            hashes.add(match.group(1).upper())
    return hashes


def openssl_field(pem: bytes, arguments: list[str]) -> str:
    output = run_command(["openssl", "x509", "-noout", *arguments], input_data=pem)
    return output.decode("utf-8", errors="replace").strip()


def parse_subject(subject: str) -> dict[str, str]:
    """Parse an RFC 2253 subject, keeping the first value of each attribute."""
    value = subject.split("=", 1)[1] if subject.startswith("subject=") else subject
    fields: dict[str, str] = {}
    for part in re.split(r"(?<!\\),", value.strip()):
        key, separator, item = part.partition("=")
        if separator:
            fields.setdefault(key.strip(), re.sub(r"\\(.)", r"\1", item.strip()))
    return fields


def parse_sha1(output: str) -> str:
    return normalize_sha1(output.rsplit("=", 1)[-1])


def parse_not_after(output: str) -> datetime:
    value = output.split("=", 1)[-1].strip()
    try:
        return datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise IdentityError(f"Could not parse certificate expiry '{value}'.") from error


def iso(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def inventory_from_commands(keychain: str, evaluated_at: datetime) -> dict[str, Any]:
    # `find-identity -v` lists only identities whose certificate chain macOS trusts and whose
    # private key is present, so membership there is what makes a certificate usable.
    identity_output = run_command(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain]
    ).decode("utf-8", errors="replace")
    identity_hashes = parse_identity_hashes(identity_output)

    certificate_result = subprocess.run(
        ["security", "find-certificate", "-a", "-c", CERTIFICATE_NAME_PREFIX.rstrip(": "), "-p", keychain],
        capture_output=True,
        check=False,
    )
    if certificate_result.returncode not in (0, 44):
        stderr = certificate_result.stderr.decode("utf-8", errors="replace").strip()
        raise IdentityError(
            "Command failed (security find-certificate): " + (stderr or "no diagnostic output")
        )
    records: list[CertificateRecord] = []
    matched_identity_hashes: set[str] = set()
    for pem_match in PEM_PATTERN.finditer(certificate_result.stdout):
        pem = pem_match.group(0) + b"\n"
        subject = parse_subject(openssl_field(pem, ["-subject", "-nameopt", "RFC2253"]))
        common_name = subject.get("CN", "")
        if not common_name.startswith(CERTIFICATE_NAME_PREFIX):
            continue
        sha1 = parse_sha1(openssl_field(pem, ["-fingerprint", "-sha1"]))
        not_after = parse_not_after(openssl_field(pem, ["-enddate"]))
        has_private_key = sha1 in identity_hashes
        if has_private_key:
            matched_identity_hashes.add(sha1)
        records.append(
            CertificateRecord(
                commonName=common_name,
                teamIdentifier=subject.get("OU", ""),
                sha1=sha1,
                notAfter=iso(not_after),
                hasPrivateKey=has_private_key,
                isExpired=not_after <= evaluated_at,
            )
        )

    missing_certificates = sorted(identity_hashes - matched_identity_hashes)
    if missing_certificates:
        raise IdentityError(
            "Could not export certificates for Apple Development identities: " + ", ".join(missing_certificates)
        )
    return make_inventory(records, evaluated_at)


def inventory_from_fixture(path: Path, evaluated_at: datetime) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    records = [CertificateRecord(**record) for record in payload.get("certificates", [])]
    return make_inventory(records, evaluated_at)


def make_inventory(records: list[CertificateRecord], evaluated_at: datetime) -> dict[str, Any]:
    normalized_records: list[CertificateRecord] = []
    for record in records:
        if not record.commonName.startswith(CERTIFICATE_NAME_PREFIX):
            continue
        try:
            not_after = datetime.fromisoformat(record.notAfter.replace("Z", "+00:00"))
        except ValueError as error:
            raise IdentityError(f"Could not parse certificate expiry '{record.notAfter}'.") from error
        normalized_records.append(
            CertificateRecord(
                commonName=record.commonName,
                teamIdentifier=record.teamIdentifier.strip().upper(),
                sha1=normalize_sha1(record.sha1),
                notAfter=iso(not_after),
                hasPrivateKey=bool(record.hasPrivateKey),
                isExpired=bool(record.isExpired or not_after <= evaluated_at),
            )
        )
    candidates = [
        record
        for record in normalized_records
        if record.hasPrivateKey and not record.isExpired and TEAM_PATTERN.fullmatch(record.teamIdentifier)
    ]
    candidates.sort(key=lambda item: (item.teamIdentifier, item.notAfter, item.sha1), reverse=True)
    normalized_records.sort(key=lambda item: (item.teamIdentifier, item.sha1))
    return {
        "schemaVersion": INVENTORY_SCHEMA_VERSION,
        "evaluatedAt": iso(evaluated_at),
        "candidates": [asdict(record) for record in candidates],
        "matchingCertificates": [asdict(record) for record in normalized_records],
    }


def load_registry_payload(path: Path) -> dict[str, Any] | None:
    try:
        details = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(details.st_mode):
        raise IdentityError(f"Local signing identity registry is not a regular file: {path}")
    if details.st_uid != os.getuid():
        raise IdentityError(f"Local signing identity registry is not owned by the current user: {path}")
    if stat.S_IMODE(details.st_mode) & 0o077:
        raise IdentityError(f"Local signing identity registry must have owner-only permissions (0600): {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise IdentityError(f"Local signing identity registry is invalid: {path}") from error
    if not isinstance(payload, dict):
        raise IdentityError(f"Local signing identity registry is invalid: {path}")
    return payload


def read_registry(path: Path) -> RegistryRecord | SelfSignedRegistryRecord | None:
    payload = load_registry_payload(path)
    if payload is None:
        return None
    try:
        if payload.get("schemaVersion") == SELF_SIGNED_SCHEMA_VERSION:
            legacy = SelfSignedRegistryRecord(**payload)
            if (
                not legacy.certificateName
                or not SHA256_PATTERN.fullmatch(legacy.certificateSHA256.upper())
                or legacy.serviceGeneration < 1
            ):
                raise IdentityError(f"Local signing identity registry has invalid fields: {path}")
            return legacy
        if payload.get("schemaVersion") != SCHEMA_VERSION:
            raise IdentityError(f"Unsupported local signing identity registry version: {payload.get('schemaVersion')}")
        record = RegistryRecord(**payload)
    except TypeError as error:
        raise IdentityError(f"Local signing identity registry is invalid: {path}") from error
    if normalize_team(record.teamIdentifier) != record.teamIdentifier:
        raise IdentityError(f"Local signing identity registry has invalid fields: {path}")
    validate_keychain_service(record.keychainService)
    return record


def write_registry(path: Path, record: RegistryRecord) -> None:
    if record.schemaVersion != SCHEMA_VERSION or normalize_team(record.teamIdentifier) != record.teamIdentifier:
        raise IdentityError("Refusing to write an invalid local signing identity registry record.")
    validate_keychain_service(record.keychainService)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(asdict(record), handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
        directory_descriptor = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary_path.exists():
            temporary_path.unlink()


def load_inventory(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != INVENTORY_SCHEMA_VERSION:
        raise IdentityError("Unsupported local signing identity inventory version.")
    return payload


def candidates_by_team(inventory: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """Valid identities grouped by team, newest expiry first within each team."""
    candidates = inventory.get("candidates")
    if not isinstance(candidates, list):
        raise IdentityError("Local signing identity inventory is missing candidates.")
    grouped: dict[str, list[dict[str, Any]]] = {}
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise IdentityError("Local signing identity inventory contains an invalid candidate.")
        normalized = dict(candidate)
        normalized["sha1"] = normalize_sha1(str(candidate.get("sha1", "")))
        normalized["teamIdentifier"] = normalize_team(str(candidate.get("teamIdentifier", "")))
        grouped.setdefault(normalized["teamIdentifier"], []).append(normalized)
    for team_candidates in grouped.values():
        team_candidates.sort(key=lambda item: (str(item.get("notAfter", "")), item["sha1"]), reverse=True)
    return grouped


def unavailable_reason(inventory: dict[str, Any], team: str) -> str:
    matching = [item for item in inventory.get("matchingCertificates", []) if item.get("teamIdentifier") == team]
    if any(item.get("isExpired") for item in matching):
        return "is expired"
    if any(not item.get("hasPrivateKey") for item in matching):
        return "does not have an available private key or a trusted certificate chain"
    return "is missing"


def new_keychain_service(team: str) -> str:
    generation = (1 << 61) | secrets.randbits(61)
    return f"com.pvncher.repoprompt.ce.local-apple-development.{team}.keychain.v{generation}"


def choose_team(by_team: dict[str, list[dict[str, Any]]], selected: str | None) -> str:
    if selected:
        if selected not in by_team:
            raise IdentityError(
                f"No valid Apple Development identity for selected team {selected}. {XCODE_CERTIFICATE_HINT}"
            )
        return selected
    if not by_team:
        raise IdentityError(f"No valid Apple Development code-signing identity was found. {XCODE_CERTIFICATE_HINT}")
    if len(by_team) == 1:
        return next(iter(by_team))
    teams = "\n".join(f"  - {team}: {candidates[0]['commonName']}" for team, candidates in sorted(by_team.items()))
    raise IdentityError(
        "Apple Development identities from several teams exist; refusing first-match selection.\n"
        f"{teams}\n"
        "Re-run with LOCAL_SIGNING_TEAM_ID=<team> to register one explicitly."
    )


def resolve_plan(
    inventory: dict[str, Any],
    registry: RegistryRecord | SelfSignedRegistryRecord | None,
    selected_team: str | None,
    rotate: bool,
) -> dict[str, Any]:
    by_team = candidates_by_team(inventory)
    selected = normalize_team(selected_team) if selected_team else None

    if isinstance(registry, RegistryRecord) and not rotate:
        registered = registry.teamIdentifier
        if selected and selected != registered:
            raise IdentityError(
                "A different local signing team is already registered. "
                "Set ROTATE_LOCAL_SIGNING_IDENTITY=1 to rotate explicitly."
            )
        if registered not in by_team:
            raise IdentityError(
                f"The Apple Development identity for registered team {registered} "
                f"{unavailable_reason(inventory, registered)}; refusing to adopt another team. "
                f"{XCODE_CERTIFICATE_HINT} Rotate explicitly with ROTATE_LOCAL_SIGNING_IDENTITY=1 to change teams."
            )
        return {
            "action": "use",
            "candidate": by_team[registered][0],
            "teamIdentifier": registered,
            "keychainService": registry.keychainService,
            "registryNeedsWrite": False,
        }

    if registry is None and rotate:
        raise IdentityError("No local signing identity is registered; rotation is not applicable on first use.")
    team = choose_team(by_team, selected)
    plan: dict[str, Any] = {
        "candidate": by_team[team][0],
        "teamIdentifier": team,
        "registryNeedsWrite": True,
    }
    if isinstance(registry, SelfSignedRegistryRecord) and not rotate:
        # Builds signed by the team keep reading the secrets that self-signed builds stored.
        # macOS asks once per stored item before the first team-signed build may read it.
        plan.update(action="adopt-from-self-signed", keychainService=registry.keychainService)
        return plan
    plan.update(action="rotate" if rotate else "adopt", keychainService=new_keychain_service(team))
    if registry is not None:
        plan["previousKeychainService"] = registry.keychainService
    return plan


def evaluation_time(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise IdentityError(f"Invalid evaluation timestamp: {value}") from error
    return parsed.astimezone(timezone.utc)


def emit(payload: Any) -> None:
    json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory")
    inventory_parser.add_argument("--keychain", required=True)
    inventory_parser.add_argument("--fixture")
    inventory_parser.add_argument("--at")

    plan_parser = subparsers.add_parser("plan")
    plan_parser.add_argument("--inventory", required=True)
    plan_parser.add_argument("--registry", required=True)
    plan_parser.add_argument("--team")
    plan_parser.add_argument("--rotate", action="store_true")

    write_parser = subparsers.add_parser("write-registry")
    write_parser.add_argument("--path", required=True)
    write_parser.add_argument("--team", required=True)
    write_parser.add_argument("--keychain-service", required=True)

    read_parser = subparsers.add_parser("read-registry")
    read_parser.add_argument("--path", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "inventory":
            at = evaluation_time(arguments.at)
            if arguments.fixture:
                payload = inventory_from_fixture(Path(arguments.fixture), at)
            else:
                payload = inventory_from_commands(arguments.keychain, at)
            emit(payload)
        elif arguments.command == "plan":
            payload = resolve_plan(
                load_inventory(Path(arguments.inventory)),
                read_registry(Path(arguments.registry)),
                arguments.team,
                arguments.rotate,
            )
            emit(payload)
        elif arguments.command == "write-registry":
            record = RegistryRecord(
                schemaVersion=SCHEMA_VERSION,
                teamIdentifier=normalize_team(arguments.team),
                keychainService=arguments.keychain_service,
            )
            write_registry(Path(arguments.path), record)
            emit(asdict(record))
        elif arguments.command == "read-registry":
            record = read_registry(Path(arguments.path))
            if record is None:
                raise IdentityError(f"Local signing identity registry does not exist: {arguments.path}")
            if not isinstance(record, RegistryRecord):
                raise IdentityError(f"Local signing identity registry still has schema {record.schemaVersion}: {arguments.path}")
            emit(asdict(record))
    except (IdentityError, OSError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
