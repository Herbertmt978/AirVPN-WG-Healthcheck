import importlib.machinery
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "bin" / "wg-healthcheck-setup"


def _load_setup():
    loader = importlib.machinery.SourceFileLoader(
        "wg_healthcheck_setup_store_tests", str(SETUP)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[loader.name] = module
    loader.exec_module(module)
    return module


setup = _load_setup()


class SnapshotFileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.source = self.root / "source.conf"
        self.backup = self.root / "source.conf.backup"
        self.staging = self.backup.with_name(f".{self.backup.name}.snapshot-staging")
        self.source.write_bytes(b"private snapshot payload\n")
        self.source.chmod(0o600)
        self.trusted_uid = os.geteuid()

    def _recording_open(self):
        real_open = os.open
        descriptors: list[int] = []

        def recording_open(path, flags, mode=0o777, *, dir_fd=None):
            descriptor = real_open(path, flags, mode, dir_fd=dir_fd)
            descriptors.append(descriptor)
            return descriptor

        def close_descriptors():
            for descriptor in descriptors:
                try:
                    os.close(descriptor)
                except OSError:
                    pass

        self.addCleanup(close_descriptors)
        return descriptors, recording_open

    def _recording_fsync(self):
        real_fsync = os.fsync
        directory_observations: list[bool] = []

        def recording_fsync(descriptor):
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_observations.append(self.backup.exists())
            return real_fsync(descriptor)

        return directory_observations, recording_fsync

    def _temporary_entries(self, target):
        return tuple(self.root.glob(f".{target.name}.setup-*"))

    def _assert_descriptors_closed(self, descriptors):
        for descriptor in descriptors:
            with self.subTest(descriptor=descriptor), self.assertRaises(OSError):
                os.fstat(descriptor)

    def _directory_cleanup_observer(self, target):
        real_fsync = os.fsync
        observations: list[tuple[str, ...]] = []

        def recording_fsync(descriptor):
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                observations.append(
                    tuple(sorted(path.name for path in self._temporary_entries(target)))
                )
            return real_fsync(descriptor)

        return observations, recording_fsync

    def test_snapshot_staging_path_is_fixed_and_same_directory(self):
        helper = getattr(setup.store, "snapshot_staging_path", None)

        self.assertIsNotNone(helper)
        self.assertEqual(helper(self.backup), self.staging)

    def test_private_staging_path_is_fixed_and_same_directory(self):
        helper = getattr(setup.store, "private_staging_path", None)

        self.assertIsNotNone(helper)
        target = self.root / "credential"
        self.assertEqual(
            helper(target),
            self.root / ".credential.setup-staging",
        )

    def test_atomic_write_refuses_abandoned_staging_without_overwrite(self):
        target = self.root / "credential"
        target.write_bytes(b"installed-credential\n")
        target.chmod(0o600)
        staging = setup.store.private_staging_path(target)
        staging.write_bytes(b"crashed-secret-staging\n")
        staging.chmod(0o600)

        with self.assertRaises(setup.SetupError):
            setup.store.atomic_write(target, b"replacement\n", self.trusted_uid)

        self.assertEqual(target.read_bytes(), b"installed-credential\n")
        self.assertEqual(staging.read_bytes(), b"crashed-secret-staging\n")

    def test_copy_descriptor_atomic_refuses_abandoned_credential_staging(self):
        target = self.root / "credential"
        target.write_bytes(b"installed-credential\n")
        target.chmod(0o600)
        staging = setup.store.private_staging_path(target)
        staging.write_bytes(b"crashed-secret-staging\n")
        staging.chmod(0o600)
        source_fd = os.open(self.source, os.O_RDONLY | os.O_CLOEXEC)
        try:
            with self.assertRaises(setup.SetupError):
                setup.store.copy_descriptor_atomic(
                    source_fd,
                    target,
                    self.trusted_uid,
                    expected_size=self.source.stat().st_size,
                )
        finally:
            os.close(source_fd)

        self.assertEqual(target.read_bytes(), b"installed-credential\n")
        self.assertEqual(staging.read_bytes(), b"crashed-secret-staging\n")

    def test_directory_inspection_failure_closes_descriptor_and_maps_error(self):
        descriptors, recording_open = self._recording_open()

        with (
            mock.patch.object(setup.store.os, "open", side_effect=recording_open),
            mock.patch.object(
                setup.store.os,
                "fstat",
                side_effect=OSError("simulated directory inspection failure"),
            ),
            self.assertRaises(setup.SetupError),
        ):
            setup.store._open_directory(self.root, self.trusted_uid)

        self.assertEqual(len(descriptors), 1)
        self._assert_descriptors_closed(descriptors)

    def test_atomic_write_failure_durably_removes_temporary_and_closes_fds(self):
        target = self.root / "target.conf"
        target.write_bytes(b"original\n")
        target.chmod(0o600)
        descriptors, recording_open = self._recording_open()
        observations, recording_fsync = self._directory_cleanup_observer(target)

        with (
            mock.patch.object(setup.store.os, "open", side_effect=recording_open),
            mock.patch.object(
                setup.store,
                "_write_all",
                side_effect=OSError("simulated write failure"),
            ),
            mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.atomic_write(target, b"replacement\n", self.trusted_uid)

        self.assertEqual(target.read_bytes(), b"original\n")
        self.assertEqual(self._temporary_entries(target), ())
        self.assertIn((), observations)
        self._assert_descriptors_closed(descriptors)

    def test_atomic_write_base_exception_durably_removes_temporary(self):
        target = self.root / "target.conf"
        observations, recording_fsync = self._directory_cleanup_observer(target)

        with (
            mock.patch.object(setup.store, "_write_all", side_effect=KeyboardInterrupt),
            mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync),
            self.assertRaises(KeyboardInterrupt),
        ):
            setup.store.atomic_write(target, b"replacement\n", self.trusted_uid)

        self.assertEqual(self._temporary_entries(target), ())
        self.assertIn((), observations)

    def test_atomic_write_reports_temporary_cleanup_failure(self):
        target = self.root / "target.conf"
        real_unlink = os.unlink

        try:
            with (
                mock.patch.object(
                    setup.store,
                    "_write_all",
                    side_effect=OSError("simulated write failure"),
                ),
                mock.patch.object(
                    setup.store.os,
                    "unlink",
                    side_effect=OSError("simulated cleanup failure"),
                ),
                self.assertRaisesRegex(setup.SetupError, "temporary.*removed"),
            ):
                setup.store.atomic_write(target, b"replacement\n", self.trusted_uid)
        finally:
            for temporary in self._temporary_entries(target):
                real_unlink(temporary)

    def test_descriptor_copy_failure_durably_removes_temporary_and_closes_fds(self):
        target = self.root / "credential"
        target.write_bytes(b"original\n")
        target.chmod(0o600)
        source_fd = os.open(self.source, os.O_RDONLY | os.O_CLOEXEC)
        descriptors, recording_open = self._recording_open()
        observations, recording_fsync = self._directory_cleanup_observer(target)
        try:
            with (
                mock.patch.object(setup.store.os, "open", side_effect=recording_open),
                mock.patch.object(
                    setup.store,
                    "_copy_exact",
                    side_effect=OSError("simulated copy failure"),
                ),
                mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync),
                self.assertRaises(setup.SetupError),
            ):
                setup.store.copy_descriptor_atomic(
                    source_fd,
                    target,
                    self.trusted_uid,
                    expected_size=self.source.stat().st_size,
                )

            self.assertEqual(target.read_bytes(), b"original\n")
            self.assertEqual(self._temporary_entries(target), ())
            self.assertIn((), observations)
            self._assert_descriptors_closed(descriptors)
            os.fstat(source_fd)
        finally:
            os.close(source_fd)

    def test_snapshot_closes_source_when_backup_directory_open_fails(self):
        descriptors, recording_open = self._recording_open()

        with (
            mock.patch.object(setup.store.os, "open", side_effect=recording_open),
            mock.patch.object(
                setup.store,
                "_open_directory",
                side_effect=setup.SetupError("simulated directory failure"),
            ),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertEqual(len(descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])
        self.assertFalse(self.backup.exists())

    def test_snapshot_failure_removes_partial_backup_and_syncs_parent(self):
        directory_observations, recording_fsync = self._recording_fsync()
        publication_observations: list[tuple[bool, bool]] = []

        def fail_after_partial_copy(_source_fd, destination_fd, _length):
            os.write(destination_fd, b"partial")
            publication_observations.append(
                (self.backup.exists(), self.staging.exists())
            )
            raise OSError("simulated copy failure")

        with (
            mock.patch.object(
                setup.store,
                "_copy_exact",
                side_effect=fail_after_partial_copy,
            ),
            mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertFalse(self.backup.exists())
        self.assertFalse(self.staging.exists())
        self.assertEqual(publication_observations, [(False, True)])
        self.assertIn(False, directory_observations)

    def test_snapshot_base_exception_removes_partial_backup_and_syncs_parent(self):
        directory_observations, recording_fsync = self._recording_fsync()

        with (
            mock.patch.object(
                setup.store, "_copy_exact", side_effect=KeyboardInterrupt
            ),
            mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync),
            self.assertRaises(KeyboardInterrupt),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertFalse(self.backup.exists())
        self.assertFalse(self.staging.exists())
        self.assertIn(False, directory_observations)

    def test_snapshot_failure_closes_every_opened_descriptor(self):
        descriptors, recording_open = self._recording_open()

        with (
            mock.patch.object(setup.store.os, "open", side_effect=recording_open),
            mock.patch.object(
                setup.store,
                "_copy_exact",
                side_effect=OSError("simulated copy failure"),
            ),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertEqual(len(descriptors), 3)
        for descriptor in descriptors:
            with self.subTest(descriptor=descriptor), self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_snapshot_directory_sync_failure_still_removes_partial_backup(self):
        real_fsync = os.fsync
        directory_observations: list[bool] = []

        def fail_first_directory_sync(descriptor):
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                directory_observations.append(self.backup.exists())
                if len(directory_observations) == 1:
                    raise OSError("simulated directory sync failure")
            return real_fsync(descriptor)

        with (
            mock.patch.object(
                setup.store.os, "fsync", side_effect=fail_first_directory_sync
            ),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertTrue(self.backup.is_file())
        self.assertEqual(self.backup.read_bytes(), self.source.read_bytes())
        self.assertFalse(self.staging.exists())
        self.assertEqual(directory_observations, [True, True])

    def test_snapshot_publication_never_overwrites_a_racing_backup(self):
        real_open = os.open

        def install_racing_backup(
            _source_name,
            destination_name,
            *,
            src_dir_fd,
            dst_dir_fd,
            follow_symlinks,
        ):
            self.assertEqual(src_dir_fd, dst_dir_fd)
            self.assertFalse(follow_symlinks)
            descriptor = real_open(
                destination_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                0o600,
                dir_fd=dst_dir_fd,
            )
            try:
                os.write(descriptor, b"racing-backup\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            raise FileExistsError("simulated publication race")

        with (
            mock.patch.object(
                setup.store.os, "link", side_effect=install_racing_backup
            ),
            self.assertRaises(setup.SetupError),
        ):
            setup.store.snapshot_file(
                self.source, self.backup, self.trusted_uid, maximum=4096
            )

        self.assertEqual(self.backup.read_bytes(), b"racing-backup\n")
        self.assertFalse(self.staging.exists())

    def test_restore_snapshot_finishes_interrupted_hardlink_publication(self):
        original = b"rollback-source-unit-test\n"
        self.staging.write_bytes(original)
        self.staging.chmod(0o600)
        os.link(self.staging, self.backup)
        self.source.write_bytes(b"mutated-target-unit-test\n")
        self.source.chmod(0o600)

        setup.store.restore_snapshot(self.backup, self.source, self.trusted_uid)

        self.assertFalse(self.staging.exists())
        self.assertEqual(self.backup.read_bytes(), original)
        self.assertEqual(self.backup.stat().st_nlink, 1)
        self.assertEqual(self.source.read_bytes(), original)

    def test_durable_unlink_removes_orphaned_snapshot_staging(self):
        self.staging.write_bytes(b"partial-snapshot")
        self.staging.chmod(0o600)
        directory_observations, recording_fsync = self._recording_fsync()

        with mock.patch.object(setup.store.os, "fsync", side_effect=recording_fsync):
            setup.store.durable_unlink(self.backup, self.trusted_uid, required=False)

        self.assertFalse(self.staging.exists())
        self.assertIn(False, directory_observations)

    def test_restore_snapshot_is_repeatable_until_owner_cleans_backup(self):
        original = b"rollback-source-unit-test\n"
        replacement = b"mutated-target-unit-test\n"
        self.source.write_bytes(original)
        self.source.chmod(0o600)
        setup.store.snapshot_file(
            self.source,
            self.backup,
            self.trusted_uid,
            maximum=1024,
        )
        self.source.write_bytes(replacement)
        self.source.chmod(0o600)

        setup.store.restore_snapshot(self.backup, self.source, self.trusted_uid)

        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), original)
        self.source.write_bytes(replacement)
        self.source.chmod(0o600)

        setup.store.restore_snapshot(self.backup, self.source, self.trusted_uid)

        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(self.backup.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
