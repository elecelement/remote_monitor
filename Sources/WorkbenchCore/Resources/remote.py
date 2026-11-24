"""Fixed remote operations; invoked by the bundled client with isolated system Python."""
import base64
import csv
import json
import math
import os
import pwd
import re
import shlex
import subprocess
import sys
import time


TMUX_PATHS = ("/usr/bin/tmux", "/bin/tmux", "/usr/local/bin/tmux")
GPU_PATHS = ("/usr/bin/nvidia-smi", "/usr/local/nvidia/bin/nvidia-smi")
BASH = "/bin/bash"
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


class Problem(Exception):
    pass


def executable(paths, label):
    for path in paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise Problem("没有找到可执行的 " + label)


def clean_env():
    account = pwd.getpwuid(os.getuid())
    return {"HOME": account.pw_dir, "USER": account.pw_name, "LOGNAME": account.pw_name,
            "SHELL": BASH, "PATH": SYSTEM_PATH, "TERM": "xterm-256color",
            "LANG": "C.UTF-8", "HISTFILE": "/dev/null", "INPUTRC": "/dev/null"}


def run(argv, env, timeout=8):
    return subprocess.run(argv, env=env, cwd="/", stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
                          encoding="utf-8", errors="replace")


def parse_metrics(output):
    def number(raw):
        try:
            value = float(raw)
            return value if math.isfinite(value) and value >= 0 else None
        except ValueError:
            return None

    records = []
    for row in csv.reader(output.splitlines(), skipinitialspace=True):
        if not row:
            continue
        if len(row) != 5 or not row[0].strip().isdigit():
            raise Problem("驱动返回了无法识别的 GPU 数据。")
        records.append(dict(index=int(row[0]), name=row[1].strip(), utilization=number(row[2]),
                            memoryUsed=number(row[3]), memoryTotal=number(row[4])))
    return records


def query_gpu():
    proc = run([executable(GPU_PATHS, "nvidia-smi"),
                "--query-gpu=index,name,utilization.gpu,memory.used,memory.total",
                "--format=csv,noheader,nounits"], clean_env())
    if proc.returncode:
        raise Problem("无法读取 NVIDIA 驱动数据。")
    return {"gpus": parse_metrics(proc.stdout)}


def checked_spec(request):
    for key in ("socketID", "sessionID"):
        if not isinstance(request.get(key), str) or not re.fullmatch("[0-9a-f]{32}", request[key]):
            raise Problem("会话标识无效。")
    for key, pattern in (("name", r"[\w][\w-]{0,63}"),
                         ("environment", r"[\w][\w.\-]{0,127}")):
        if not isinstance(request.get(key), str) or not re.fullmatch(pattern, request[key]):
            raise Problem("会话名或环境名的字符无效。")
    for key in ("directory", "conda"):
        value = request.get(key, "")
        if key == "conda" and value == "":
            continue
        if (not isinstance(value, str) or not value.startswith("/") or len(value) > 4096
                or any(ord(c) < 32 or ord(c) == 127 for c in value)):
            raise Problem("请使用远程绝对路径。")
    return {key: request.get(key, "") for key in
            ("socketID", "sessionID", "name", "environment", "directory", "conda", "requireReady")}


def conda_paths(spec):
    supplied = spec["conda"]
    home = pwd.getpwuid(os.getuid()).pw_dir
    roots = [supplied] if supplied else [
        os.path.join(home, name) for name in ("miniconda3", "anaconda3", "miniforge3", "mambaforge")
    ] + ["/opt/conda", "/opt/miniconda3", "/opt/anaconda3"]
    fallback = (None, None)
    for root in roots:
        if os.path.basename(root) == "conda" and os.path.basename(os.path.dirname(root)) in ("bin", "condabin"):
            root = os.path.dirname(os.path.dirname(root))
        root = os.path.realpath(root)
        exe = os.path.join(root, "bin", "conda")
        if (os.path.isfile(os.path.join(root, "conda-meta", "history")) and os.path.isfile(exe)
                and os.access(exe, os.X_OK)):
            if fallback[0] is None:
                fallback = root, exe
            prefix = root if spec["environment"] == "base" else os.path.join(root, "envs", spec["environment"])
            if os.path.isfile(os.path.join(prefix, "conda-meta", "history")):
                return root, exe
    return fallback


def activation_values(script):
    # Conda's shell activator can emit commands and environment-supplied variables.
    # Consume only its standard literal exports as data; never evaluate generated code.
    allowed = {"PATH", "CONDA_SHLVL", "CONDA_PREFIX", "CONDA_DEFAULT_ENV", "CONDA_PROMPT_MODIFIER",
               "CONDA_EXE", "CONDA_PYTHON_EXE", "_CONDA_ROOT", "_CONDA_EXE", "_CE_M", "_CE_CONDA"}
    env = {}
    for line in script.splitlines():
        if not line.strip():
            continue
        words = shlex.split(line, comments=False)
        if len(words) == 1 and words[0].startswith("PS1="):
            continue
        if len(words) == 2 and words[0] == "unset" and words[1] in allowed:
            env.pop(words[1], None)
            continue
        if len(words) != 2 or words[0] != "export":
            raise ValueError("extra activation statement")
        key, separator, value = words[1].partition("=")
        if not separator or key not in allowed:
            raise ValueError("extra activation variable")
        env[key] = value
    return env


def registered_prefix(home, name):
    # Conda installations can share named environments stored outside their own envs directories.
    registry = os.path.join(home, ".conda", "environments.txt")
    try:
        with open(registry, encoding="utf-8") as stream:
            lines = stream.read(1_048_577)
        if len(lines) > 1_048_576:
            return None
    except (OSError, UnicodeError):
        return None
    matches = set()
    for path in lines.splitlines():
        if path.startswith("/") and os.path.basename(path) == name:
            prefix = os.path.realpath(path)
            if os.path.isfile(os.path.join(prefix, "conda-meta", "history")):
                matches.add(prefix)
    return next(iter(matches)) if len(matches) == 1 else None


def environment_for_shell(spec):
    env = clean_env()
    env["GWB_EXPECTED_DIR"] = os.path.realpath(spec["directory"])
    env["GWB_STATE"] = "manual"
    env["GWB_ENV_NAME"] = spec["environment"]
    root, exe = conda_paths(spec)
    advice = "可手动初始化 Conda 后运行 conda activate " + shlex.quote(spec["environment"])
    if not exe:
        return env, "未能确认 Conda 安装位置；" + advice
    init = os.path.join(root, "etc", "profile.d", "conda.sh")
    if os.path.isfile(init):
        env["GWB_CONDA_INIT"] = init
        env["CONDA_EXE"] = exe
        advice = "请在此终端手动运行 conda activate " + shlex.quote(spec["environment"])
    prefix = root if spec["environment"] == "base" else os.path.join(root, "envs", spec["environment"])
    prefix = os.path.realpath(prefix)
    if not os.path.isfile(os.path.join(prefix, "conda-meta", "history")):
        prefix = registered_prefix(env["HOME"], spec["environment"])
        if not prefix:
            return env, "未能确认目标环境；" + advice
    try:
        for hooks in ("etc/conda/activate.d", "etc/conda/env_vars.d"):
            path = os.path.join(prefix, hooks)
            if os.path.lexists(path) and os.listdir(path):
                return env, "环境包含额外激活脚本或变量；" + advice
        if os.path.lexists(os.path.join(prefix, "conda-meta", "state")):
            return env, "环境包含自定义状态；" + advice
        probe_env = clean_env()
        probe_env.update(HOME="/dev/null", TMPDIR="/dev/null", XDG_CACHE_HOME="/dev/null",
                         XDG_CONFIG_HOME="/dev/null", PYTHONDONTWRITEBYTECODE="1", PYTHONNOUSERSITE="1",
                         CONDA_NO_PLUGINS="true", CONDA_OFFLINE="true", CONDARC="/dev/null")
        result = run([exe, "shell.bash", "activate", prefix], probe_env)
        values = activation_values(result.stdout)
        if (result.returncode or values.get("CONDA_PREFIX") != prefix
                or os.path.join(prefix, "bin") not in values.get("PATH", "").split(os.pathsep)):
            raise ValueError("prefix mismatch")
    except (ValueError, OSError, subprocess.TimeoutExpired):
        return env, "激活结果无法安全确认；" + advice
    env.update(values)
    env["GWB_EXPECTED_PREFIX"] = prefix
    env["GWB_STATE"] = "ready"
    return env, "已进入工作目录并激活 " + spec["environment"]


# tmux runs this fixed program directly in each new pane, with all per-pane data in argv.
PANE = '''import json, os, sys
env = json.loads(sys.argv[1])
os.chdir(env.pop("GWB_EXPECTED_DIR"))
name = env.pop("GWB_ENV_NAME")
state = env.pop("GWB_STATE")
init = env.pop("GWB_CONDA_INIT", "")
prefix = env.pop("GWB_EXPECTED_PREFIX", "")
if state == "ready" and env.get("CONDA_PREFIX") != prefix:
    sys.exit("Conda prefix mismatch")
env["PS1"] = ("(" + name + ") " if state == "ready" else "") + r"\\u@\\h:\\w\\$ "
if init:
    env["GWB_CONDA_INIT"] = init
    env["BASH_FUNC_conda%%"] = '() { unset -f conda; source "$GWB_CONDA_INIT" && conda "$@"; }'
os.execve("/bin/bash", ["/bin/bash", "--noprofile", "--norc", "-i"], env)
'''


def session_info(tmux, spec):
    # List exact names and IDs without starting a tmux server.
    proc = run([tmux, "-N", "-u", "list-sessions", "-F",
                "#{session_name}|#{session_id}|#{@gwb_identity}|#{@gwb_state}"], clean_env())
    for line in proc.stdout.splitlines():
        fields = line.split("|", 3)
        if len(fields) == 4 and fields[0] == spec["name"] and re.fullmatch(r"\$[0-9]+", fields[1]):
            return fields[1:]
    return None


def start_session(tmux, spec):
    if not os.path.isdir(spec["directory"]) or not os.access(spec["directory"], os.X_OK):
        raise Problem("工作目录不存在或没有进入权限。")
    env, detail = environment_for_shell(spec)
    if spec.get("requireReady") == "yes" and env["GWB_STATE"] != "ready":
        raise Problem(detail)
    pane = [sys.executable, "-I", "-B", "-S", "-c", PANE, json.dumps(env, ensure_ascii=True)]
    target = "=" + spec["name"] + ":"
    # The first split inserts a full-width pane above the original, then selects it.
    # Splitting that active top pane horizontally leaves the original pane across the bottom.
    proc = run([tmux, "-u", "-f", "/dev/null", "new-session", "-d", "-E", "-s", spec["name"], *pane,
                ";", "split-window", "-v", "-b", "-t", target, *pane,
                ";", "split-window", "-h", "-t", target, *pane,
                ";", "set-option", "-t", target, "@gwb_identity", spec["sessionID"],
                ";", "set-option", "-t", target, "@gwb_state", env["GWB_STATE"]], clean_env())
    if proc.returncode:
        info = session_info(tmux, spec)
        if not info or info[1:] != [spec["sessionID"], env["GWB_STATE"]]:
            raise Problem("无法完成三窗格启动。现有会话将保留，请在终端检查。 " + proc.stderr.strip()[:180])
    limit = time.monotonic() + 4
    while time.monotonic() < limit:
        panes = run([tmux, "-N", "-u", "list-panes", "-t", target, "-F",
                     "#{pane_current_command}\t#{pane_current_path}"], clean_env())
        expected = "bash\t" + env["GWB_EXPECTED_DIR"]
        if not panes.returncode and panes.stdout.splitlines() == [expected] * 3:
            return env["GWB_STATE"], detail
        time.sleep(0.05)
    raise Problem("未能确认三个终端都进入了指定目录。会话已保留，请检查 tmux。")


def session(request):
    spec = checked_spec(request)
    tmux = executable(TMUX_PATHS, "tmux")
    info = session_info(tmux, spec)
    attach = request["mode"] == "attach"
    if info is None:
        if attach:
            raise Problem("该会话已结束，请从快捷方式重新启动。")
        state, detail = start_session(tmux, spec)
        return {"state": state, "detail": detail}

    target, identity, state = info
    if identity != spec["sessionID"] or state not in ("ready", "manual"):
        if request.get("allowExisting") != "yes":
            raise Problem("发现同名会话。如已确认是你的会话，可在快捷方式中允许接回。")
        state = "ready"
    if attach:
        os.execve(tmux, [tmux, "-N", "-u", "attach-session", "-E", "-t", target], clean_env())
    return {"state": state, "detail": "已找到已有会话，接回时保留当前布局、环境和任务。"}


def main():
    try:
        os.umask(0o077)
        os.chdir("/")
        token = sys.argv[1]
        if len(token) > 65536:
            raise Problem("请求过长。")
        request = json.loads(base64.urlsafe_b64decode(token + "=" * (-len(token) % 4)))
        if request["mode"] == "watchGPU":
            while publish(dict(ok=True, **query_gpu())):
                time.sleep(5)
            return 0
        if request["mode"] == "gpu":
            data = query_gpu()
        elif request["mode"] in ("ensure", "attach"):
            data = session(request)
        else:
            raise Problem("不支持此操作。")
        publish(dict(ok=True, **data))
        return 0
    except (Problem, OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError) as err:
        publish({"ok": False, "error": str(err)})
        return 1


def publish(record):
    try:
        print(json.dumps(record, ensure_ascii=True), flush=True)
    except BrokenPipeError:
        # The SSH channel closed. Discard buffered output, including Python's final flush.
        with open(os.devnull, "wb") as sink:
            os.dup2(sink.fileno(), sys.stdout.fileno())
        return False
    return True


if __name__ == "__main__":
    sys.exit(main())
