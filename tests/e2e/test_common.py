"""Focused lifecycle regression tests for the shared E2E server manager."""

import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import common


class ServerManagerLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.root = Path(self.tempdir.name)
        self.server_bin = self.root / "server" / "target" / "debug" / "server"
        self.server_bin.parent.mkdir(parents=True)
        self.server_bin.touch()
        (self.root / "tests" / "e2e").mkdir(parents=True)
        self.project_root_patch = mock.patch.object(common, "PROJECT_ROOT", self.root)
        self.project_root_patch.start()
        self.addCleanup(self.project_root_patch.stop)
        self.port_patch = mock.patch.dict(common.os.environ, {}, clear=False)
        self.port_patch.start()
        common.os.environ.pop("PORT", None)
        self.addCleanup(self.port_patch.stop)

    def test_existing_binary_is_rebuilt_and_url_port_is_passed_to_child(self):
        manager = common.ServerManager("http://127.0.0.1:8123/api/v1")
        manager.is_running = mock.Mock(side_effect=[False, True])
        process = mock.Mock()
        with mock.patch.object(common.subprocess, "run", return_value=mock.Mock(returncode=0)) as build, \
             mock.patch.object(common.subprocess, "Popen", return_value=process) as popen:
            self.assertTrue(manager.ensure_running())
            build.assert_called_once()
            self.assertEqual(build.call_args.args[0], ["cargo", "build", "--bin", "server"])
            self.assertEqual(popen.call_args.kwargs["env"]["PORT"], "8123")
            self.assertIsNot(popen.call_args.kwargs["stdout"], subprocess.PIPE)
            manager.server_log.close()
            manager.server_log = None

    def test_spawn_error_closes_log_and_returns_failure(self):
        manager = common.ServerManager("http://127.0.0.1:8123/api/v1")
        manager.is_running = mock.Mock(return_value=False)
        with mock.patch.object(common.subprocess, "run", return_value=mock.Mock(returncode=0)), \
             mock.patch.object(common.subprocess, "Popen", side_effect=OSError("spawn failed")):
            self.assertFalse(manager.ensure_running())
        self.assertIsNone(manager.server_log)

    def test_stop_clears_ownership_when_child_already_exited(self):
        manager = common.ServerManager()
        manager.process = mock.Mock()
        manager.process.poll.return_value = 1
        manager.spawned_by_us = True
        manager.server_log = tempfile.TemporaryFile(mode="w+")

        manager.stop()

        self.assertFalse(manager.spawned_by_us)
        self.assertTrue(manager.server_log.closed)


if __name__ == "__main__":
    unittest.main()
