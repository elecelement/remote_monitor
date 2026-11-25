"""Run with python3 -B -m unittest discover -s Tests/Remote -v from GPUWorkbench."""
import base64
import concurrent.futures
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "Sources/WorkbenchCore/Resources/remote.py"
spec_module = importlib.util.spec_from_file_location("fixed_remote", SOURCE)
remote = importlib.util.module_from_spec(spec_module)
spec_module.loader.exec_module(remote)
TMUX = os.environ.get("GWB_TEST_TMUX") or shutil.which("tmux")
REAL_CONDA = os.environ.get("GWB_TEST_CONDA")


def request(**changes):
    fields = dict(mode="ensure", name="train-01", socketID=uuid.uuid4().hex, sessionID=uuid.uuid4().hex,
                  environment="plain", directory="/tmp", conda="")
    return dict(fields, **changes)


class FixedOperations(unittest.TestCase):
    def watch_command(self, overrides):
        # Load the exact CLI module in a child process. Only the device reading and
        # test clock are replaced; pipes and the JSON wire encoding are real.
        script = ("import runpy,sys; scope=runpy.run_path(sys.argv.pop(1)); "
                  "ctx=scope['main'].__globals__; exec(sys.argv.pop(1), ctx); sys.exit(scope['main']())")
        request_data = base64.urlsafe_b64encode(b'{"mode":"watchGPU"}').decode()
        return [sys.executable, "-IBS", "-c", script, str(SOURCE), overrides, request_data]

    def test_watch_gpu_streams_and_publishes_one_final_error(self):
        overrides = """samples = iter([{'gpus': []}, {'gpus': []}])
def query_gpu():
    try: return next(samples)
    except StopIteration: raise Problem('fixture driver unavailable')
def tick(delay):
    assert delay == 5
time.sleep = tick
"""
        result = subprocess.run(self.watch_command(overrides), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual([json.loads(line) for line in result.stdout.splitlines()],
                         [{"ok": True, "gpus": []}, {"ok": True, "gpus": []},
                          {"ok": False, "error": "fixture driver unavailable"}])

    def test_watch_gpu_exits_on_closed_pipe(self):
        overrides = "query_gpu = lambda: {'gpus': []}\noriginal_sleep=time.sleep\ntime.sleep=lambda _: original_sleep(0.05)"
        with subprocess.Popen(self.watch_command(overrides), stdout=subprocess.PIPE, stderr=subprocess.PIPE) as child:
            try:
                self.assertTrue(json.loads(child.stdout.readline())["ok"])
                child.stdout.close()
                self.assertEqual(child.wait(timeout=3), 0)
                self.assertEqual(child.stderr.read(), b"")
            finally:
                if child.poll() is None:
                    child.terminate()

    def test_gpu_protocol_and_missing_metrics(self):
        metrics = remote.parse_metrics('0, NVIDIA A100, 71, 4290, 40960, 36158\n1, "GPU, two", N/A, [N/A], 12000, N/A')
        self.assertEqual(metrics[0], dict(index=0, name="NVIDIA A100", utilization=71, memoryUsed=4290,
                                          memoryTotal=40960, memoryFree=36158))
        self.assertEqual(metrics[1]["name"], "GPU, two")
        self.assertIsNone(metrics[1]["utilization"])
        self.assertIsNone(metrics[1]["memoryUsed"])
        self.assertIsNone(metrics[1]["memoryFree"])
        with self.assertRaises(remote.Problem):
            remote.parse_metrics("unable to communicate with driver")
        with patch.object(remote, "executable", return_value="/usr/bin/nvidia-smi"), patch.object(remote, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, "1, A100, 0, 2, 8, 5\n", "")
            self.assertEqual(remote.query_gpu()["gpus"][0]["index"], 1)
            self.assertEqual(run.call_args[0][0], ["/usr/bin/nvidia-smi",
                             "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,memory.free",
                             "--format=csv,noheader,nounits"])

    def test_cli_fails_closed_for_unknown_requests(self):
        for blob in ({"mode": "remove"}, {"mode": "attach", "socketID": "../../outside"}):
            value = base64.urlsafe_b64encode(json.dumps(blob).encode()).decode().rstrip("=")
            result = subprocess.run([sys.executable, "-IBS", "-c", SOURCE.read_text(), value],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(json.loads(result.stdout)["ok"])

    def test_interactive_attach_error_uses_chosen_language(self):
        for language, phrase in (("en", "original session"), ("zh-Hans", "未找到原会话")):
            output = io.StringIO()
            with patch.object(sys.stdout, "isatty", return_value=True), patch.object(sys, "stderr", output):
                remote.report_error({"mode": "attachConfirmed", "language": language}, remote.missing_session())
            self.assertIn(phrase, output.getvalue())
            self.assertNotIn("sessionToken", output.getvalue())

    def test_pane_activation_error_uses_chosen_language(self):
        env = dict(GWB_EXPECTED_DIR="/", GWB_ENV_NAME="fixture", GWB_STATE="ready",
                   GWB_EXPECTED_PREFIX="/expected", CONDA_PREFIX="/other")
        for language, phrase in (("en", "Conda prefix"), ("zh-Hans", "环境路径")):
            run = subprocess.run([sys.executable, "-IBS", "-c", remote.PANE, json.dumps(env), language],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn(phrase, run.stderr)

    def test_resume_never_creates_and_confirmation_expires_with_the_instance(self):
        config = request()
        token = "123:$1:1770012345"
        with patch.object(remote, "executable", return_value="/usr/bin/tmux"), \
                patch.object(remote, "start_session") as create, patch.object(remote, "session_info") as inspect:
            inspect.return_value = None
            for mode in ("reconnect", "confirm", "attach", "attachConfirmed"):
                with self.assertRaises(remote.SessionProblem) as lost:
                    remote.session(dict(config, mode=mode, sessionToken=token))
                self.assertEqual(lost.exception.code, "missing")
            inspect.return_value = remote.SessionInfo(token, "", "")
            for mode in ("ensure", "reconnect", "attach"):
                with self.assertRaises(remote.SessionProblem) as collision:
                    remote.session(dict(config, mode=mode, sessionToken=token, allowExisting="yes"))
                self.assertEqual((collision.exception.code, collision.exception.token), ("collision", token))
            self.assertEqual(remote.session(dict(config, mode="confirm", sessionToken=token))["origin"], "resumed")
            inspect.return_value = remote.SessionInfo("456:$1:1770012345", "", "")
            with self.assertRaises(remote.SessionProblem) as replaced:
                remote.session(dict(config, mode="attachConfirmed", sessionToken=token))
            self.assertEqual(replaced.exception.code, "missing")
            create.assert_not_called()

    def test_accept_only_literal_standard_conda_exports(self):
        good = "unset _CE_M\nPS1='(plain) '\nexport PATH='/space env/bin:/bin'\n"
        self.assertEqual(remote.activation_values(good), {"PATH": "/space env/bin:/bin"})
        for extra in ["source /extra", "export PROMPT_COMMAND='echo hi'", "echo extra"]:
            with self.assertRaises(ValueError):
                remote.activation_values(good + extra)

    def test_path_and_names(self):
        self.assertEqual(remote.checked_spec(request(name="训练_2"))["name"], "训练_2")
        for changes in [dict(socketID="bad"), dict(name="a:b"), dict(environment="../x"),
                        dict(directory="relative"), dict(conda="bad\nvalue")]:
            with self.assertRaises(remote.Problem):
                remote.checked_spec(request(**changes))

    def test_child_environment_ignores_login_hooks_and_path(self):
        with patch.dict(os.environ, {"PATH": "/custom/bin", "BASH_ENV": "/login-hook",
                                     "PROMPT_COMMAND": "custom", "INPUTRC": "/custom/inputrc"}):
            env = remote.clean_env()
        self.assertNotIn("BASH_ENV", env)
        self.assertNotIn("PROMPT_COMMAND", env)
        self.assertNotIn("/custom", env["PATH"])
        self.assertEqual(env["INPUTRC"], "/dev/null")
        self.assertEqual(env["HISTFILE"], "/dev/null")


@unittest.skipUnless(TMUX, "Install tmux or set GWB_TEST_TMUX to exercise real sessions")
class RealTmux(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir="/tmp", prefix="gw")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.addCleanup(patch.stopall)
        original_environment = remote.clean_env
        patch.object(remote, "clean_env",
                     lambda: dict(original_environment(), TMUX_TMPDIR=str(self.folder))).start()
        patch.object(remote, "TMUX_PATHS", (TMUX,)).start()
        self.work = self.folder / "工作 'space; # text"
        self.work.mkdir()
        self.original = self.work / "existing"
        self.original.write_bytes(b"shared project data")
        self.original.chmod(0o640)
        self.original_stat = self.original.stat()
        self.install = self.folder / "install"
        self.prefix = self.install / "envs/plain"
        for env in (self.install, self.prefix):
            (env / "conda-meta").mkdir(parents=True)
            (env / "conda-meta/history").touch()
            (env / "bin").mkdir()
        script = self.install / "bin/conda"
        script.write_text("""#!/bin/bash
[[ $1 == shell.bash && $2 == activate ]] || exit 3
printf "export CONDA_PREFIX='%s'\\nexport PATH='%s/bin:/usr/bin:/bin'\\n" "$3" "$3"
""")
        script.chmod(0o700)
        self.config = request(directory=str(self.work), conda=str(self.install))
        self.sockets = []
        self.addCleanup(self.close_test_servers)

    def close_test_servers(self):
        # Every matching socket belongs to this disposable, freshly created local fixture.
        for sock in self.folder.glob("tmux-*/default"):
            subprocess.run([TMUX, "-N", "-S", str(sock), "kill-server"], capture_output=True)
        for sock in self.sockets:
            subprocess.run([TMUX, "-N", "-S", str(sock), "kill-server"], capture_output=True)

    def command(self, sock, *args):
        return subprocess.run([TMUX, "-u", "-N", "-S", str(sock), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def owned_socket(self):
        return self.folder / ("tmux-%d" % os.getuid()) / "default"

    def assert_existing_file_untouched(self):
        self.assertEqual(self.original.read_bytes(), b"shared project data")
        after = self.original.stat()
        self.assertEqual((after.st_ino, after.st_mode, after.st_mtime_ns),
                         (self.original_stat.st_ino, self.original_stat.st_mode, self.original_stat.st_mtime_ns))

    def test_concurrent_creation_disconnect_and_unrelated_session(self):
        other = str(self.folder / "other.sock")
        self.sockets.append(other)
        subprocess.run([TMUX, "-f", "/dev/null", "-S", other, "new-session", "-d", "-s", self.config["name"],
                        "/bin/sleep", "120"], check=True)
        pid = self.command(other, "display-message", "-p", "#{pane_pid}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(remote.session, [self.config] * 3))
        self.assertEqual([r["state"] for r in results], ["ready"] * 3)
        self.assertEqual(sorted(r["origin"] for r in results), ["created", "resumed", "resumed"])
        self.assertEqual(len(set(r["sessionToken"] for r in results)), 1)
        sock = self.owned_socket()
        child = self.command(sock, "display-message", "-p", "#{pane_pid}")
        self.assertEqual(os.path.realpath(self.command(sock, "display-message", "-p", "#{pane_current_path}")),
                         os.path.realpath(self.work))
        panes = [line.split() for line in self.command(
            sock, "list-panes", "-F", "#{pane_id} #{pane_left} #{pane_top} #{pane_width}").splitlines()]
        top = [pane for pane in panes if pane[2] == "0"]
        bottom = [pane for pane in panes if pane[2] != "0"]
        self.assertEqual((len(top), len(bottom)), (2, 1))
        self.assertGreater(int(bottom[0][3]), max(int(pane[3]) for pane in top))
        for pane in panes:
            self.command(sock, "send-keys", "-t", pane[0], "-l", r'''printf 'GWB_ENV=%s\n' "${CONDA_PREFIX##*/}"''')
            self.command(sock, "send-keys", "-t", pane[0], "Enter")
            deadline = time.monotonic() + 3
            while True:
                screen = self.command(sock, "capture-pane", "-p", "-t", pane[0])
                if "GWB_ENV=plain" in screen:
                    break
                self.assertLess(time.monotonic(), deadline, "Expected an activated shell in " + pane[0] + ": " + repr(screen))
                time.sleep(0.02)
            actual_dir = self.command(sock, "display-message", "-p", "-t", pane[0], "#{pane_current_path}")
            self.assertEqual(os.path.realpath(actual_dir), os.path.realpath(self.work))
        self.assertFalse(list(self.folder.glob("gwb-*")))
        # Use the exact production attach path inside a pseudo-terminal, then detach.
        pid_attach, pty_fd = pty.fork()
        if pid_attach == 0:
            try:
                remote.session(dict(self.config, mode="attach", sessionToken=results[0]["sessionToken"]))
            except BaseException:
                os._exit(1)
            os._exit(2)
        try:
            limit = time.monotonic() + 6
            while time.monotonic() < limit:
                clients = self.command(sock, "list-clients", "-F", "#{client_pid}")
                if str(pid_attach) in clients.splitlines():
                    break
                if select.select([pty_fd], [], [], 0.05)[0]:
                    os.read(pty_fd, 8192)
            self.assertIn(str(pid_attach), clients.splitlines())
            os.write(pty_fd, b"\x02")
            time.sleep(0.06)
            os.write(pty_fd, b"d")
            while time.monotonic() < limit and self.command(sock, "list-clients"):
                time.sleep(0.02)
            self.assertFalse(self.command(sock, "list-clients"))
        finally:
            os.close(pty_fd)
            os.waitpid(pid_attach, 0)
        self.assertEqual(remote.session(self.config)["state"], "ready")
        self.assertEqual(self.command(sock, "display-message", "-p", "#{pane_pid}"), child)
        self.assertEqual(self.command(other, "display-message", "-p", "#{pane_pid}"), pid)
        os.kill(int(pid), 0)  # Existence probe, sends no signal.
        self.assert_existing_file_untouched()

    def test_hook_switches_to_manual_without_running_it(self):
        hook = self.prefix / "etc/conda/activate.d/example.sh"
        hook.parent.mkdir(parents=True)
        marker = self.folder / "hook-ran"
        hook.write_text("touch " + shlex.quote(str(marker)))
        result = remote.session(self.config)
        self.assertEqual(result["state"], "manual")
        self.assertIn("conda activate plain", result["detail"])
        self.assertFalse(marker.exists())
        self.assert_existing_file_untouched()

    def test_explicit_creation_reports_collision_including_concurrent_creators(self):
        config = dict(self.config, mode="create")
        barrier = threading.Barrier(3, timeout=5)
        start = remote.start_session

        def start_together(tmux, spec, mode):
            # All three creators have observed the name vacant.
            barrier.wait()
            return start(tmux, spec, mode)

        def try_create(_):
            try:
                result = remote.session(config)
                return result["origin"], result["sessionToken"]
            except remote.SessionProblem as err:
                return err.code, err.token

        with patch.object(remote, "start_session", start_together), concurrent.futures.ThreadPoolExecutor(3) as pool:
            attempts = list(pool.map(try_create, range(3)))
        self.assertEqual(sorted(kind for kind, _ in attempts), ["collision", "collision", "created"])
        self.assertEqual(len(set(token for _, token in attempts)), 1)
        session_token = attempts[0][1]
        # Reuse by the same shortcut also requires a fresh decision for an explicitly requested creation.
        self.assertEqual(try_create(None), ("collision", session_token))
        self.assertEqual(remote.session(dict(config, mode="ensure"))["origin"], "resumed")
        self.assertEqual(remote.session(dict(config, mode="confirm", sessionToken=session_token))["origin"], "resumed")
        self.assertEqual(len(self.command(self.owned_socket(), "list-panes", "-F", "#{pane_id}").splitlines()), 3)

    def test_conflict_and_lost_session(self):
        first = remote.session(self.config)
        sock = self.owned_socket()
        self.command(sock, "set-option", "@gwb_identity", "unexpected")
        with self.assertRaises(remote.Problem):
            remote.session(self.config)
        # Refusal must preserve the existing session and its options.
        self.assertEqual(self.command(sock, "show-options", "-v", "@gwb_identity"), "unexpected")
        with self.assertRaises(remote.Problem):
            remote.session(dict(self.config, sessionID=uuid.uuid4().hex))
        self.command(sock, "kill-server")
        for _ in range(100):
            if not sock.exists():
                break
            time.sleep(0.02)
        reconnect = dict(self.config, mode="reconnect", sessionToken=first["sessionToken"])
        for mode in ("attach", "reconnect", "confirm"):
            with self.assertRaises(remote.SessionProblem) as missing:
                remote.session(dict(reconnect, mode=mode))
            self.assertEqual(missing.exception.code, "missing")
        self.assertIsNone(remote.session_info(TMUX, self.config))
        replacement = remote.session(self.config)
        self.assertEqual(replacement["origin"], "created")
        self.assertNotEqual(replacement["sessionToken"], first["sessionToken"])
        with self.assertRaises(remote.SessionProblem) as replaced:
            remote.session(reconnect)
        self.assertEqual(replaced.exception.code, "missing")
        self.assertTrue(sock.exists())

    def test_explicit_reconnect_preserves_an_existing_same_name_session(self):
        sock = self.owned_socket()
        env = remote.clean_env()
        subprocess.run([TMUX, "-f", "/dev/null", "new-session", "-d", "-s", self.config["name"],
                        "/bin/sleep", "120"], env=env, check=True)
        before = self.command(sock, "list-panes", "-F", "#{pane_id} #{pane_pid}")
        # Old saved settings cannot authorize access. Only an explicit decision about this instance can.
        with self.assertRaises(remote.SessionProblem) as collision:
            remote.session(dict(self.config, allowExisting="yes"))
        self.assertEqual(collision.exception.code, "collision")
        token = collision.exception.token
        result = remote.session(dict(self.config, mode="confirm", sessionToken=token))
        self.assertIn("已有会话", result["detail"])
        self.assertEqual(result["origin"], "resumed")
        with self.assertRaises(remote.SessionProblem) as again:
            remote.session(dict(self.config, mode="reconnect", sessionToken=token))
        self.assertEqual(again.exception.code, "collision")
        with patch.object(remote.os, "execve", side_effect=SystemExit) as attach:
            with self.assertRaises(SystemExit):
                remote.session(dict(self.config, mode="attachConfirmed", sessionToken=token))
            self.assertIn(token, attach.call_args.args[1][-3])
        self.assertEqual(self.command(sock, "list-panes", "-F", "#{pane_id} #{pane_pid}"), before)
        self.command(sock, "rename-session", "-t", self.config["name"], "previous")
        self.command(sock, "new-session", "-d", "-s", self.config["name"], "/bin/sleep", "120")
        for mode in ("attachConfirmed", "confirm", "reconnect"):
            with self.assertRaises(remote.SessionProblem) as replaced:
                remote.session(dict(self.config, mode=mode, sessionToken=token))
            self.assertEqual(replaced.exception.code, "missing")
        self.assertEqual(self.command(sock, "list-panes", "-t", "previous", "-F", "#{pane_id} #{pane_pid}"), before)
        self.assertEqual(set(self.work.iterdir()), {self.original})
        self.assert_existing_file_untouched()

    def test_missing_workdir(self):
        with self.assertRaises(remote.Problem):
            remote.session(dict(self.config, directory=str(self.folder / "missing")))
        self.assertFalse((self.folder / "missing").exists())
        self.assert_existing_file_untouched()

    @unittest.skipUnless(REAL_CONDA, "Set GWB_TEST_CONDA to run a real Conda activation")
    def test_real_conda_exec(self):
        # The actual Conda executable activates a disposable prefix with a genuine
        # conda-meta layout; this needs no package download or change to real envs.
        (self.install / "bin/conda").unlink()
        (self.install / "bin/conda").symlink_to(REAL_CONDA)
        result = remote.session(self.config)
        self.assertEqual(result["state"], "ready", result)
        self.assert_existing_file_untouched()


if __name__ == "__main__":
    unittest.main()
