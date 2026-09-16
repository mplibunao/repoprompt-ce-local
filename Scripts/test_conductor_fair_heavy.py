#!/usr/bin/env python3
"""Focused regression tests for fair global-heavy admission."""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import os
import socket
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

SCRIPT_DIR = Path(__file__).resolve().parent


def load_conductor() -> Any:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--conductor-source", type=Path)
    options, remaining = parser.parse_known_args()
    sys.argv = [sys.argv[0], *remaining]
    if options.conductor_source is None:
        if str(SCRIPT_DIR) not in sys.path:
            sys.path.insert(0, str(SCRIPT_DIR))
        import conductor as loaded

        return loaded
    source = options.conductor_source.resolve()
    sys.path.insert(0, str(source.parent))
    spec = importlib.util.spec_from_file_location("conductor_under_test", source)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load conductor source at {source}")
    loaded = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = loaded
    spec.loader.exec_module(loaded)
    return loaded


conductor = load_conductor()


class FairHeavyAdmissionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        patcher = mock.patch.object(conductor, "machine_lock_dir", return_value=self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.coordinators: list[Any] = []
        self.remote_sockets: list[socket.socket] = []

    def metadata(self, label: str = "local") -> dict[str, Any]:
        return {
            "lockKind": "global-heavy",
            "ticket": label,
            "operation": "test",
            "operationLabel": label,
            "repoRoot": "/fixture",
            "repoHash": "fixture",
            "worktree": "fixture",
            "acquiredAt": 1.0,
        }

    def make_coordinator(
        self,
        label: str = "local",
        *,
        env: dict[str, str] | None = None,
        clock: Any = None,
        on_warning: Any = None,
    ) -> Any:
        kwargs: dict[str, Any] = {"on_warning": on_warning}
        if clock is not None:
            kwargs["clock"] = clock
        with mock.patch.object(conductor, "process_start_token", return_value="owner-start"):
            coordinator = conductor.FairHeavyAdmission(self.metadata(label), env or {}, **kwargs)
        self.coordinators.append(coordinator)
        self.addCleanup(coordinator.close)
        return coordinator

    def add_remote(
        self,
        coordinator: Any,
        *,
        waiter_id: str,
        sequence: int,
        pid: int,
        token: str,
        state: str = "waiting",
    ) -> dict[str, Any]:
        path = coordinator.waiters_dir / f"{waiter_id}.sock"
        remote = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        remote.bind(str(path))
        self.remote_sockets.append(remote)
        self.addCleanup(remote.close)
        self.addCleanup(path.unlink, missing_ok=True)
        record = {
            "waiterID": waiter_id,
            "sequence": sequence,
            "state": state,
            "ownerPID": pid,
            "ownerStartToken": token,
            "notifySocketPath": str(path),
            "acquiredSlotPath": None,
        }
        with coordinator._queue_lock():
            payload = coordinator._load_queue()
            payload["waiters"].append(record)
            payload["nextSequence"] = max(int(payload["nextSequence"]), sequence + 1)
            payload["generation"] += 1
            coordinator._write_queue(payload)
        return record

    def load_queue(self, coordinator: Any) -> dict[str, Any]:
        with coordinator._queue_lock():
            return coordinator._load_queue()

    def remove_owned_record(self, coordinator: Any) -> None:
        with coordinator._queue_lock():
            payload = coordinator._load_queue()
            payload["waiters"] = [
                item
                for item in payload["waiters"]
                if not (
                    item.get("waiterID") == coordinator.waiter_id
                    and item.get("ownerPID") == coordinator.owner_pid
                    and item.get("ownerStartToken") == coordinator.owner_start
                )
            ]
            payload["generation"] += 1
            coordinator._write_queue(payload)

    def assert_slot_available(self, coordinator: Any) -> None:
        slot = conductor.global_heavy_slot_paths(coordinator.env)[0].open("a+", encoding="utf-8")
        try:
            fcntl.flock(slot.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(slot.fileno(), fcntl.LOCK_UN)
        finally:
            slot.close()

    def test_incomplete_snapshot_preserves_live_exact_remote_waiter(self) -> None:
        coordinator = self.make_coordinator()
        self.add_remote(
            coordinator,
            waiter_id="remote-live",
            sequence=0,
            pid=222,
            token="remote-start",
        )

        with mock.patch.object(conductor, "process_table_snapshot", return_value={}), mock.patch.object(
            conductor.os, "kill", return_value=None
        ), mock.patch.object(conductor, "process_start_token", return_value="remote-start"):
            _payload, waiter, position, ordered = coordinator._queue_snapshot()

        self.assertEqual([item["waiterID"] for item in ordered], ["remote-live", coordinator.waiter_id])
        self.assertEqual(
            (waiter["waiterID"], waiter["ownerPID"], waiter["ownerStartToken"]),
            (coordinator.waiter_id, coordinator.owner_pid, coordinator.owner_start),
        )
        self.assertEqual(position, 2)

    def test_inconclusive_targeted_identity_preserves_remote_waiter(self) -> None:
        cases = (
            ("missing-token", None, None),
            ("permission", PermissionError(), "unused"),
            ("other-os-error", OSError(5, "fixture"), "unused"),
        )
        for index, (label, kill_error, token) in enumerate(cases):
            with self.subTest(label=label):
                coordinator = self.make_coordinator(label)
                waiter_id = f"remote-{label}"
                self.add_remote(
                    coordinator,
                    waiter_id=waiter_id,
                    sequence=100 + index,
                    pid=300 + index,
                    token="expected",
                )
                kill = mock.Mock(side_effect=kill_error) if kill_error else mock.Mock(return_value=None)
                with mock.patch.object(conductor, "process_table_snapshot", return_value={}), mock.patch.object(
                    conductor.os, "kill", kill
                ), mock.patch.object(conductor, "process_start_token", return_value=token) as token_probe:
                    ordered = coordinator._queue_snapshot()[3]
                self.assertIn(waiter_id, {item["waiterID"] for item in ordered})
                if kill_error:
                    token_probe.assert_not_called()

    def test_confirmed_dead_and_reused_remote_waiters_are_pruned(self) -> None:
        coordinator = self.make_coordinator()
        self.add_remote(coordinator, waiter_id="dead", sequence=20, pid=401, token="dead-start")
        self.add_remote(coordinator, waiter_id="reused", sequence=21, pid=402, token="old-start")
        self.add_remote(coordinator, waiter_id="live", sequence=22, pid=403, token="live-start")

        def kill(pid: int, _signal: int) -> None:
            if pid == 401:
                raise ProcessLookupError()

        tokens = {402: "new-start", 403: "live-start"}
        with mock.patch.object(conductor, "process_table_snapshot", return_value={}), mock.patch.object(
            conductor.os, "kill", side_effect=kill
        ), mock.patch.object(conductor, "process_start_token", side_effect=lambda pid: tokens[pid]):
            ordered = coordinator._queue_snapshot()[3]

        waiter_ids = {item["waiterID"] for item in ordered}
        self.assertNotIn("dead", waiter_ids)
        self.assertNotIn("reused", waiter_ids)
        self.assertIn("live", waiter_ids)

    def test_missing_own_waiter_rejoins_surviving_queue_tail(self) -> None:
        coordinator = self.make_coordinator()
        survivor = self.add_remote(
            coordinator,
            waiter_id="survivor",
            sequence=20,
            pid=501,
            token="survivor-start",
        )
        self.add_remote(coordinator, waiter_id="dead", sequence=21, pid=502, token="dead-start")
        self.remove_owned_record(coordinator)
        before = self.load_queue(coordinator)
        writes = 0
        real_write = coordinator._write_queue

        def count_write(payload: dict[str, Any]) -> None:
            nonlocal writes
            writes += 1
            real_write(payload)

        with mock.patch.object(conductor, "now", return_value=1234.5), mock.patch.object(
            conductor, "process_table_snapshot", return_value={501: (1, "survivor-start")}
        ), mock.patch.object(coordinator, "_probe_remote_identity", return_value="stale"), mock.patch.object(
            coordinator, "_write_queue", side_effect=count_write
        ), mock.patch.object(coordinator, "_notify") as notify:
            payload, recovered, position, ordered = coordinator._queue_snapshot()

        self.assertEqual(writes, 1)
        notify.assert_not_called()
        self.assertEqual(payload["generation"], before["generation"] + 2)
        self.assertEqual(payload["nextSequence"], before["nextSequence"] + 1)
        self.assertEqual(recovered["waiterID"], coordinator.waiter_id)
        self.assertEqual(recovered["sequence"], before["nextSequence"])
        self.assertEqual(recovered["state"], "waiting")
        self.assertIsNone(recovered["acquiredSlotPath"])
        self.assertEqual(recovered["enqueuedAt"], 1234.5)
        self.assertEqual(recovered["notifySocketPath"], str(coordinator.notify_path))
        self.assertEqual(recovered["ownerPID"], coordinator.owner_pid)
        self.assertEqual(recovered["ownerStartToken"], coordinator.owner_start)
        self.assertEqual([item["waiterID"] for item in ordered], [survivor["waiterID"], coordinator.waiter_id])
        self.assertEqual(position, 2)

        second = coordinator._queue_snapshot()
        self.assertEqual(second[0]["nextSequence"], payload["nextSequence"])
        self.assertEqual(
            sum(1 for item in second[3] if coordinator._owns_waiter(item)),
            1,
        )

    def test_rejoined_waiter_acquires_without_admission_failure(self) -> None:
        coordinator = self.make_coordinator()
        self.remove_owned_record(coordinator)

        lease = coordinator.wait()

        self.assertIsNotNone(lease)
        assert lease is not None
        self.assertEqual(lease.waiter_id, coordinator.waiter_id)
        lease.release()
        self.assertFalse(coordinator.notify_path.exists())
        self.assertEqual(self.load_queue(coordinator)["waiters"], [])

    def test_cancel_after_rejoin_removes_only_exact_owned_waiter(self) -> None:
        coordinator = self.make_coordinator()
        survivor = self.add_remote(
            coordinator,
            waiter_id="survivor",
            sequence=20,
            pid=601,
            token="survivor-start",
        )
        self.remove_owned_record(coordinator)
        with mock.patch.object(
            conductor, "process_table_snapshot", return_value={601: (1, "survivor-start")}
        ):
            coordinator._queue_snapshot()

        lease = coordinator.wait(cancel_check=lambda: True)

        self.assertIsNone(lease)
        self.assertFalse(coordinator.notify_path.exists())
        self.assertEqual(
            [item["waiterID"] for item in self.load_queue(coordinator)["waiters"]],
            [survivor["waiterID"]],
        )

    def test_targeted_probe_is_memoized_only_for_one_pruning_pass(self) -> None:
        coordinator = self.make_coordinator()
        for index in range(2):
            self.add_remote(
                coordinator,
                waiter_id=f"shared-{index}",
                sequence=20 + index,
                pid=701,
                token="shared-start",
            )
        with mock.patch.object(conductor, "process_table_snapshot", return_value={}), mock.patch.object(
            coordinator, "_probe_remote_identity", return_value="live"
        ) as probe:
            coordinator._queue_snapshot()
            self.assertEqual(probe.call_count, 1)
            coordinator._queue_snapshot()
            self.assertEqual(probe.call_count, 2)

    def test_snapshot_fast_paths_and_cached_negative_refresh(self) -> None:
        coordinator = self.make_coordinator(clock=lambda: 10.0)
        self.add_remote(coordinator, waiter_id="remote", sequence=20, pid=801, token="exact")
        with mock.patch.object(
            conductor, "process_table_snapshot", return_value={801: (1, "exact")}
        ), mock.patch.object(coordinator, "_probe_remote_identity") as probe:
            coordinator._queue_snapshot()
            probe.assert_not_called()

        coordinator._remote_process_snapshot = {}
        coordinator._remote_process_snapshot_at = 10.0
        with mock.patch.object(
            conductor, "process_table_snapshot", return_value={801: (1, "exact")}
        ) as snapshot, mock.patch.object(coordinator, "_probe_remote_identity") as probe:
            coordinator._queue_snapshot()
            self.assertEqual(snapshot.call_count, 1)
            probe.assert_not_called()

        coordinator._remote_process_snapshot = {}
        coordinator._remote_process_snapshot_at = 10.0
        with mock.patch.object(conductor, "process_table_snapshot", return_value=None), mock.patch.object(
            coordinator, "_probe_remote_identity"
        ) as probe:
            ordered = coordinator._queue_snapshot()[3]
            probe.assert_not_called()
            self.assertIn("remote", {item["waiterID"] for item in ordered})

        coordinator._remote_process_snapshot = None
        coordinator._remote_process_snapshot_at = None
        with mock.patch.object(conductor, "process_table_snapshot", return_value=None), mock.patch.object(
            coordinator, "_probe_remote_identity"
        ) as probe:
            ordered = coordinator._queue_snapshot()[3]
            probe.assert_not_called()
            self.assertIn("remote", {item["waiterID"] for item in ordered})

    def test_missing_and_corrupt_queue_recover_under_kernel_capacity(self) -> None:
        for queue_state in ("missing", "corrupt"):
            with self.subTest(queue_state=queue_state):
                warnings: list[tuple[str, str]] = []
                coordinator = self.make_coordinator(
                    queue_state,
                    on_warning=lambda kind, message: warnings.append((kind, message)),
                )
                slot_path = conductor.global_heavy_slot_paths(coordinator.env)[0]
                holder = slot_path.open("a+", encoding="utf-8")
                fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
                try:
                    if queue_state == "missing":
                        coordinator.queue_path.unlink()
                    else:
                        coordinator.queue_path.write_text("{invalid", encoding="utf-8")
                        os.chmod(coordinator.queue_path, 0o600)

                    cancel = threading.Event()
                    recovered: list[dict[str, Any]] = []

                    def observe_recovery(position: int, earlier: list[dict[str, Any]]) -> None:
                        if cancel.is_set():
                            return
                        payload = self.load_queue(coordinator)
                        recovered.extend(item for item in payload["waiters"] if coordinator._owns_waiter(item))
                        self.assertEqual(position, 1)
                        self.assertEqual(earlier, [])
                        cancel.set()
                        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                        try:
                            sender.sendto(b"rescan", str(coordinator.notify_path))
                        finally:
                            sender.close()

                    lease = coordinator.wait(cancel_check=cancel.is_set, update=observe_recovery)

                    self.assertIsNone(lease)
                    self.assertEqual(len(recovered), 1)
                    self.assertEqual(recovered[0]["state"], "waiting")
                    self.assertIsNone(recovered[0]["acquiredSlotPath"])
                    self.assertFalse(coordinator.notify_path.exists())
                    self.assertEqual(self.load_queue(coordinator)["waiters"], [])
                    if queue_state == "corrupt":
                        self.assertEqual([kind for kind, _message in warnings], ["fairQueueQuarantined"])
                    else:
                        self.assertEqual(warnings, [])
                finally:
                    fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
                    holder.close()

    def test_admission_recheck_requires_exact_identity_and_releases_rejected_slot(self) -> None:
        for mode in ("removed", "same-id-different-owner"):
            with self.subTest(mode=mode):
                coordinator = self.make_coordinator(mode)
                real_snapshot = coordinator._queue_snapshot
                snapshots = 0
                cancel_checks = 0

                def snapshot_then_mutate() -> Any:
                    nonlocal snapshots
                    snapshots += 1
                    result = real_snapshot()
                    if snapshots == 1:
                        with coordinator._queue_lock():
                            payload = coordinator._load_queue()
                            owned = next(item for item in payload["waiters"] if coordinator._owns_waiter(item))
                            if mode == "removed":
                                payload["waiters"].remove(owned)
                            else:
                                owned["ownerStartToken"] = "different-owner"
                            payload["generation"] += 1
                            coordinator._write_queue(payload)
                        sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                        try:
                            sender.sendto(b"rescan", str(coordinator.notify_path))
                        finally:
                            sender.close()
                    return result

                def cancel() -> bool:
                    nonlocal cancel_checks
                    cancel_checks += 1
                    return cancel_checks > 1

                with mock.patch.object(coordinator, "_queue_snapshot", side_effect=snapshot_then_mutate):
                    self.assertIsNone(coordinator.wait(cancel_check=cancel))
                self.assert_slot_available(coordinator)

    def test_acquisition_errors_release_attempted_slot(self) -> None:
        cases = ("queue-write", "display-metadata")
        for label in cases:
            with self.subTest(label=label):
                coordinator = self.make_coordinator(label)
                if label == "queue-write":
                    patcher = mock.patch.object(coordinator, "_write_queue", side_effect=RuntimeError(label))
                else:
                    patcher = mock.patch.object(
                        conductor, "write_display_lock_metadata", side_effect=RuntimeError(label)
                    )
                with patcher, self.assertRaisesRegex(RuntimeError, label):
                    coordinator.wait()
                self.assert_slot_available(coordinator)

    def test_recovery_failure_abandons_and_preserves_unrelated_state(self) -> None:
        for label in ("unsafe-read", "atomic-write"):
            with self.subTest(label=label):
                coordinator = self.make_coordinator(label)
                survivor = self.add_remote(
                    coordinator,
                    waiter_id=f"survivor-{label}",
                    sequence=20,
                    pid=901,
                    token="survivor-start",
                )
                self.remove_owned_record(coordinator)
                if label == "unsafe-read":
                    os.chmod(coordinator.queue_path, 0o644)
                    with self.assertRaisesRegex(conductor.ConductorError, "unsafe global-heavy queue"):
                        coordinator.wait()
                    os.chmod(coordinator.queue_path, 0o600)
                else:
                    with mock.patch.object(
                        conductor, "process_table_snapshot", return_value={901: (1, "survivor-start")}
                    ), mock.patch.object(
                        coordinator, "_write_queue", side_effect=OSError("atomic-write")
                    ), self.assertRaisesRegex(OSError, "atomic-write"):
                        coordinator.wait()
                self.assertFalse(coordinator.notify_path.exists())
                self.assertIn(survivor["waiterID"], {item["waiterID"] for item in self.load_queue(coordinator)["waiters"]})

    def test_configured_capacity_still_requires_available_kernel_slot(self) -> None:
        for capacity in (1, 2):
            with self.subTest(capacity=capacity):
                coordinator = self.make_coordinator(
                    f"capacity-{capacity}", env={"REPOPROMPT_DEV_HEAVY_SLOTS": str(capacity)}
                )
                paths = conductor.global_heavy_slot_paths(coordinator.env)
                holders = [path.open("a+", encoding="utf-8") for path in paths]
                try:
                    for holder in holders:
                        fcntl.flock(holder.fileno(), fcntl.LOCK_EX)
                    updates = 0

                    def update(_position: int, _earlier: list[dict[str, Any]]) -> None:
                        nonlocal updates
                        updates += 1
                        if updates == 1:
                            sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
                            try:
                                sender.sendto(b"rescan", str(coordinator.notify_path))
                            finally:
                                sender.close()

                    lease = coordinator.wait(cancel_check=lambda: updates > 0, update=update)
                    self.assertIsNone(lease)
                finally:
                    for holder in holders:
                        fcntl.flock(holder.fileno(), fcntl.LOCK_UN)
                        holder.close()


if __name__ == "__main__":
    unittest.main()
