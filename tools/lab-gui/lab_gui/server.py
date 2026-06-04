from __future__ import annotations

import json
import os
import queue
import re
import shlex
import signal
import subprocess
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Iterator

from flask import Flask, Response, abort, jsonify, request, stream_with_context

# -----------------------------------------------------------------------------
# Repo root: lab_gui/package -> tools/lab-gui/lab_gui -> tools/lab-gui -> repo
# -----------------------------------------------------------------------------
_PKG = Path(__file__).resolve().parent
_LAB_GUI = _PKG.parent
_DEFAULT_REPO = _LAB_GUI.parent.parent


def repo_root() -> Path:
    env = os.environ.get("AUTO_OS_ROOT", "").strip()
    if env:
        return Path(env).expanduser().resolve()
    return _DEFAULT_REPO.resolve()


# -----------------------------------------------------------------------------
# Presets (each argv tuple is allowlisted verbatim)
# -----------------------------------------------------------------------------
_PRESETS_RAW: list[dict[str, Any]] = [
    {
        "id": "guest-onecrate-evidence",
        "label": "访客 onecrate + syscall 证据",
        "argv": ["bash", "scripts/guest-onecrate-syscall-evidence.sh"],
        "doc": (
            "环境变量见脚本头注释：`GUEST_ONECRATE_MODE`（rustc/cargo）、"
            "`GUEST_ONECRATE_ALLOW_FETCH`、`GUEST_ONECRATE_SYSCALL_STATS_SEC`、"
            "`GUEST_ONECRATE_DEVLOG_SEC`、`GUEST_ONECRATE_TAIL_HTTP` 等。"
            "根文件与内核路径可用 `GUEST_ONECRATE_ROOTFS`、`GUEST_ONECRATE_SKIP_KERNEL_SAVE`。"
            "说明：`AX_LOG` 等为**编译期**选项，运行时环境变量无法控制已编好的内核。"
        ),
    },
    {
        "id": "guest-onecrate-diagnose",
        "label": "访客 onecrate 诊断（脚本）",
        "argv": ["bash", "scripts/guest-onecrate-diagnose.sh"],
        "doc": "辅助脚本；通常与 onecrate evidence 流水线配合查阅。",
    },
    {
        "id": "tail-http-results",
        "label": "tail HTTP（默认 results.txt 占位路径）",
        "argv": [
            "python3",
            "scripts/tail-http-serve.py",
            ".guest-runs/guest-onecrate-bench/results.txt",
        ],
        "doc": (
            "`tail-http-serve.py PATH [PORT] [LINES] [REFRESH_SEC]`。"
            "将中间路径改成你的日志文件即可；CLI 详见脚本 docstring。"
        ),
    },
    {
        "id": "verify-starry-smoke-riscv64",
        "label": "verify Starry 访客 smoke（riscv64）",
        "argv": ["bash", "scripts/verify-starry-guest-smoke.sh", "ARCH=riscv64"],
        "doc": "需 QEMU/串口；可选 `KERNEL=`、`DISK=` 等参数加在本行后以空格分隔并符合校验规则。",
    },
    {
        "id": "verify-starry-smoke-x86_64",
        "label": "verify Starry 访客 smoke（x86_64）",
        "argv": ["bash", "scripts/verify-starry-guest-smoke.sh", "ARCH=x86_64"],
        "doc": "同上，架构为 x86_64。",
    },
    {
        "id": "verify-syscall-monitor-smoke",
        "label": "verify syscall 监视器 smoke（宿主伪造串口）",
        "argv": ["bash", "scripts/verify-syscall-monitor-smoke.sh"],
        "doc": (
            "脚本自检解析器：**不启动真实 Starry QEMU**。"
            "输出块为合成的 SYSCALL_STATS 文本——仅用于解析链冒烟，不能与访客 syscall 实况混谈。"
        ),
    },
]

PRESETS = _PRESETS_RAW
ALLOWLIST_ARGV: set[tuple[str, ...]] = {tuple(p["argv"]) for p in PRESETS}


def _join_argv(argv: list[str]) -> str:
    return " ".join(shlex.quote(a) for a in argv)


# -----------------------------------------------------------------------------
# Safety: custom == bash/python3 + script under repo; no obvious shell injection
# -----------------------------------------------------------------------------
_FORBIDDEN_CUSTOM_SUBSTR = (";", "|", "&", "\n", "\r", "`", "$(", "${", "\x00")


def _bad_substrings(cmdline: str) -> str | None:
    for s in _FORBIDDEN_CUSTOM_SUBSTR:
        if s in cmdline:
            return f"命令含禁止片段 {s!r}（请使用脚本参数，勿用管道/重定向/子 shell）"
    return None


_PYTHON_LEADING_FLAGS = frozenset({"-u", "-b", "-B", "-E", "-s", "-S", "-O", "-OO", "-v", "-q"})


def _runner_name(cmd0: str) -> str:
    return Path(cmd0).name


def _is_allowed_runner(cmd0: str) -> bool:
    return cmd0 in ("bash", "python3") or _runner_name(cmd0) in ("bash", "python3")


def _resolve_under_repo(repo: Path, arg: str) -> Path:
    p = Path(arg)
    if p.is_absolute():
        return p.resolve()
    return (repo / p).resolve()


def _validate_custom_argv(argv: list[str], repo: Path) -> str | None:
    repo = repo.resolve()
    if not argv:
        return "命令为空"
    if not _is_allowed_runner(argv[0]):
        return "自定义仅允许 `bash` 或 `python3` 作为第一个词（可用绝对路径，但 basename 须为二者之一）"
    if _runner_name(argv[0]) == "bash" and "-c" in argv[1:]:
        return "不允许 `bash -c`"

    rest = argv[1:]
    name = _runner_name(argv[0])
    if name == "python3":
        i = 0
        while i < len(rest) and rest[i] in _PYTHON_LEADING_FLAGS:
            i += 1
        if i < len(rest) and rest[i] == "--":
            i += 1
        if i >= len(rest):
            return "未找到要执行的 .py 脚本路径"
        script_arg = rest[i]
    else:
        i = 0
        while i < len(rest) and rest[i].startswith("-"):
            if rest[i] == "-c":
                return "不允许 `bash -c`"
            i += 1
        if i >= len(rest):
            return "bash 后须为仓库内的脚本路径"
        script_arg = rest[i]

    full = _resolve_under_repo(repo, script_arg)
    try:
        full.relative_to(repo)
    except ValueError:
        return f"脚本路径须在仓库内：{full}"
    if not full.is_file():
        return f"脚本不存在或不是文件：{full}"
    return None


def parse_command_line(cmdline: str, repo: Path) -> tuple[list[str], str]:
    """Return (argv, kind) where kind is 'allowlist' or 'custom'."""
    raw = cmdline.strip()
    if not raw:
        raise ValueError("命令行为空")
    bad = _bad_substrings(raw)
    if bad:
        raise ValueError(bad)
    try:
        argv = shlex.split(raw, posix=True)
    except ValueError as e:
        raise ValueError(f"无法解析命令行（引号配对？）：{e}") from e

    tup = tuple(argv)
    if tup in ALLOWLIST_ARGV:
        return argv, "allowlist"
    err = _validate_custom_argv(argv, repo)
    if err:
        raise ValueError(err)
    return argv, "custom"


def parse_env_extra(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"环境行须为 KEY=value：{line!r}")
        k, v = line.split("=", 1)
        k = k.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k):
            raise ValueError(f"非法环境变量名：{k!r}")
        out[k] = v
    return out


def parse_cwd(s: str, repo: Path) -> Path:
    s = (s or "").strip() or str(repo.resolve())
    p = Path(s)
    if not p.is_absolute():
        p = (repo / p).resolve()
    else:
        p = p.resolve()
    try:
        p.relative_to(repo.resolve())
    except ValueError:
        raise ValueError("工作目录必须位于仓库树根之下") from None
    if not p.is_dir():
        raise ValueError(f"工作目录不存在或不是目录：{p}")
    return p


# -----------------------------------------------------------------------------
# Child process session + killpg
# -----------------------------------------------------------------------------
def _popen_group(argv: list[str], cwd: Path, env: dict[str, str]) -> subprocess.Popen[str]:
    kwargs: dict[str, Any] = dict(
        args=argv,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    if os.name == "posix":
        kwargs["preexec_fn"] = os.setsid  # type: ignore[assignment]
    return subprocess.Popen(**kwargs)  # noqa: S603 — argv allowlisted/validated


def kill_proc_group(proc: subprocess.Popen[str], *, grace_sec: float = 3.0) -> None:
    if proc.poll() is not None:
        return
    if os.name != "posix":
        proc.terminate()
        try:
            proc.wait(timeout=int(grace_sec))
        except subprocess.TimeoutExpired:
            proc.kill()
        return
    try:
        pgid = os.getpgid(proc.pid)
    except ProcessLookupError:
        return
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + grace_sec
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return
        time.sleep(0.05)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        pass


# -----------------------------------------------------------------------------
# Run registry (single-user lab tool)
# -----------------------------------------------------------------------------
class RunState:
    __slots__ = ("id", "proc", "log_q", "thread", "started", "done", "exit_code")

    def __init__(self) -> None:
        self.id = uuid.uuid4().hex
        self.proc: subprocess.Popen[str] | None = None
        self.log_q: queue.Queue[str | None] = queue.Queue()
        self.thread: threading.Thread | None = None
        self.started = time.time()
        self.done = threading.Event()
        self.exit_code: int | None = None


_REGISTRY: dict[str, RunState] = {}
_REGISTRY_LOCK = threading.Lock()


def _reader_thread(proc: subprocess.Popen[str], st: RunState) -> None:
    assert proc.stdout is not None
    try:
        for line in iter(proc.stdout.readline, ""):
            st.log_q.put(line)
        proc.wait()
        st.exit_code = int(proc.returncode or 0)
    except Exception as ex:  # noqa: BLE001 — surface to UI
        st.log_q.put(f"\n[lab-gui] reader error: {ex!s}\n")
        st.exit_code = 1
    finally:
        st.log_q.put(None)
        st.done.set()


def create_app() -> Flask:
    app = Flask(__name__)

    INDEX_HTML = """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width,initial-scale=1"/>
  <title>Auto-OS lab-gui</title>
  <style>
    :root {
      --bg:#0f1419; --panel:#161b22; --border:#30363d; --text:#e6edf3; --muted:#8b949e;
      --acc:#388bfd; --good:#3fb950; --bad:#f85149; --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    * { box-sizing: border-box; }
    body { margin:0; font-family: system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
      background:var(--bg); color:var(--text); height:100vh; display:flex; flex-direction:column; }
    header { padding:12px 16px; border-bottom:1px solid var(--border); background:var(--panel);
      display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:8px;}
    header h1 { margin:0; font-size:1.05rem; font-weight:600; letter-spacing:.02em;}
    header .hint { font-size:.8rem; color:var(--muted); }
    main { flex:1; display:flex; min-height:0; gap:12px; padding:12px; }
    .left { flex:0 0 380px; min-width:260px; display:flex; flex-direction:column; gap:10px; overflow:auto;}
    .right { flex:1; min-width:280px; display:flex; flex-direction:column; min-height:0; gap:8px;}
    label { font-size:.75rem; color:var(--muted); display:block; margin-bottom:4px;}
    select, textarea, input[type=text] {
      width:100%; border:1px solid var(--border); border-radius:6px;
      background:#0d1117; color:var(--text); padding:8px 10px; font-size:.85rem;
    }
    textarea { resize:vertical; min-height:86px; font-family:var(--mono); }
    textarea#cmd { min-height:100px;}
    textarea#term { flex:1; min-height:200px; background:#010409; color:#c9d1d9;}
    button {
      cursor:pointer; border:none; border-radius:6px; padding:10px 16px;
      font-weight:600; font-size:.85rem;
    }
    button.primary { background:var(--acc); color:#fff;}
    button.danger { background:var(--bad); color:#fff;}
    button.ghost { background:transparent; border:1px solid var(--border); color:var(--text);}
    button:disabled { opacity:.45; cursor:not-allowed;}
    .row { display:flex; gap:8px; flex-wrap:wrap; align-items:center;}
    .doc { font-size:.75rem; color:var(--muted); line-height:1.35; padding:8px 10px;
      border:1px dashed var(--border); border-radius:6px; background:#0d1117;}
    .pill { font-size:.7rem; color:var(--muted); }
    footer { padding:8px 16px; border-top:1px solid var(--border); font-size:.72rem;
      color:var(--muted); text-align:center;}
  </style>
</head>
<body>
  <header>
    <h1>Lab GUI</h1>
    <span class="hint">仅监听 127.0.0.1 · 默认不预填命令（可改后再运行）· SSE 合并流</span>
  </header>
  <main>
    <section class="left">
      <div>
        <label for="preset">预设（选一项填入命令行，或保持首项留空自行编辑）</label>
        <select id="preset"></select>
      </div>
      <p class="pill" id="presetkind"></p>
      <div class="doc" id="presetdoc"></div>
      <div>
        <label for="cmd">命令行（可编辑；须通过 allowlist 或 bash/python3+仓库内脚本）</label>
        <textarea id="cmd" spellcheck="false"></textarea>
      </div>
      <div>
        <label for="cwd">工作目录（默认仓库根，相对路径相对仓库）</label>
        <input id="cwd" type="text" placeholder="仓库根目录" autocomplete="off"/>
      </div>
      <div>
        <label for="env">额外环境变量（每行 KEY=value）</label>
        <textarea id="env" spellcheck="false" placeholder="FOO=bar"></textarea>
      </div>
      <div class="row">
        <button type="button" class="primary" id="run">运行</button>
        <button type="button" class="danger" id="stop" disabled>停止</button>
      </div>
      <p class="pill" id="status">就绪</p>
    </section>
    <section class="right">
      <label for="term">输出</label>
      <textarea id="term" readonly spellcheck="false"></textarea>
      <button type="button" class="ghost" id="clear">清空终端</button>
    </section>
  </main>
  <footer>树根：<code id="reporoot"></code> · AUTO_OS_ROOT 可覆盖默认推导。</footer>
<script>
(async function(){
  document.getElementById('reporoot').textContent = __REPO_ROOT__;
  const presetSel = document.getElementById('preset');
  const presetDocEl = document.getElementById('presetdoc');
  const presetKindEl = document.getElementById('presetkind');
  const cmdEl = document.getElementById('cmd');
  const cwdEl = document.getElementById('cwd');
  const envEl = document.getElementById('env');
  const termEl = document.getElementById('term');
  const runBtn = document.getElementById('run');
  const stopBtn = document.getElementById('stop');
  const statEl = document.getElementById('status');

  let es = null;
  let activeRun = null;

  const presets = __PRESETS_JSON__;

  function fillPreset(meta) {
    cmdEl.value = meta.cmd || '';
    presetDocEl.textContent = meta.doc || '';
    presetKindEl.textContent = meta.cmd
      ? '命令种类：预设（亦为 allowlist 成员）'
      : '命令行留空：请编辑后再点「运行」，或换选其它预设';
  }

  presets.forEach((p,i) => {
    const opt = document.createElement('option');
    opt.value = String(i);
    opt.textContent = p.label;
    presetSel.appendChild(opt);
  });
  presetSel.addEventListener('change', () => {
    fillPreset(presets[Number(presetSel.value)]);
  });
  fillPreset(presets[0]);

  document.getElementById('clear').onclick = () => { termEl.value=''; };

  function stopEs() {
    if (es) { es.close(); es = null; }
  }

  async function stopRun(remote=true) {
    stopEs();
    if (remote && activeRun) {
      try {
        await fetch('/api/stop/' + encodeURIComponent(activeRun), { method:'POST' });
      } catch(e) { console.warn(e); }
    }
    activeRun = null;
    stopBtn.disabled = true;
    runBtn.disabled = false;
    statEl.textContent = '已停止';
  }

  stopBtn.onclick = () => stopRun(true);

  runBtn.onclick = async () => {
    if (activeRun) return;
    termEl.value += '\n———— 新会话 ————\n';
    statEl.textContent = '连接中…';
    runBtn.disabled = true;
    stopBtn.disabled = false;
    let body;
    try {
      body = {
        command: cmdEl.value,
        cwd: cwdEl.value,
        env_extra: envEl.value,
      };
      const rsp = await fetch('/api/run', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const j = await rsp.json().catch(()=>({}));
      if (!rsp.ok) throw new Error(j.error || rsp.statusText);
      activeRun = j.run_id;
      statEl.textContent = '运行中 (' + activeRun.slice(0,8) + '…)';
      stopEs();
      es = new EventSource('/api/stream/' + encodeURIComponent(activeRun));
      es.onmessage = (ev) => {
        try {
          const msg = JSON.parse(ev.data);
          if (msg.t === 'chunk') termEl.value += msg.text || '';
          if (msg.t === 'done') {
            statEl.textContent = '退出码 ' + msg.exit_code;
            stopEs();
            activeRun = null;
            stopBtn.disabled = true;
            runBtn.disabled = false;
          }
          if (msg.t === 'error') termEl.value += "\n[fatal] " + msg.err + "\n";
        } catch(e) {}
        termEl.scrollTop = termEl.scrollHeight;
      };
      es.onerror = () => {
        termEl.value += "\n[SSE 连接中断]\n";
        statEl.textContent = 'SSE 中断';
        stopRun(true);
        runBtn.disabled = false;
      };
    } catch (e) {
      termEl.value += "\n[错误] " + e.message + "\n";
      statEl.textContent = '失败';
      runBtn.disabled = false;
      stopBtn.disabled = true;
      activeRun = null;
    }
  };
})();
</script>
</body>
</html>
"""

    @app.route("/")
    def index() -> Any:
        r = repo_root()
        presets_payload = [
            {
                "label": "— 留空，自行编辑后再运行 —",
                "cmd": "",
                "doc": (
                    "不预填任何命令：先改环境变量/工作目录，再在「命令行」里手写或粘贴；"
                    "或从本下拉选其它项一键填入。未填命令时点「运行」会报错。"
                ),
            }
        ] + [{"label": p["label"], "cmd": _join_argv(list(p["argv"])), "doc": p["doc"]} for p in PRESETS]
        html = INDEX_HTML.replace("__PRESETS_JSON__", json.dumps(presets_payload)).replace(
            "__REPO_ROOT__", json.dumps(r.as_posix())
        )
        return Response(html, mimetype="text/html")

    @app.route("/api/presets")
    def api_presets() -> Any:
        head = [
            {
                "id": "manual-empty",
                "label": "— 留空，自行编辑后再运行 —",
                "argv": [],
                "doc": "不预填命令；自行编辑命令行或选其它预设。",
                "cmd": "",
            }
        ]
        rest = [
            {"id": p["id"], "label": p["label"], "argv": p["argv"], "doc": p["doc"], "cmd": _join_argv(list(p["argv"]))}
            for p in PRESETS
        ]
        return jsonify(presets=head + rest)

    @app.route("/api/run", methods=["POST"])
    def api_run() -> Any:
        repo = repo_root()
        data = request.get_json(silent=True) or {}
        cmdline = (data.get("command") or "").strip()
        cwd_s = data.get("cwd") or ""
        env_text = data.get("env_extra") or ""
        try:
            argv, kind = parse_command_line(cmdline, repo)
            cwd = parse_cwd(cwd_s, repo)
            extra_env = parse_env_extra(env_text)
        except ValueError as e:
            return jsonify(error=str(e)), 400

        merged = os.environ.copy()
        merged.update(extra_env)

        with _REGISTRY_LOCK:
            if len(_REGISTRY) > 16:
                for k in list(_REGISTRY.keys()):
                    old = _REGISTRY.get(k)
                    if old and old.done.is_set():
                        del _REGISTRY[k]
            running = sum(1 for st in _REGISTRY.values() if not st.done.is_set())
            if running >= 1:
                return jsonify(error="已有任务在运行，请先点「停止」或等待结束"), 409

            st = RunState()
            try:
                st.proc = _popen_group(argv, cwd=cwd, env=merged)
            except OSError as e:
                return jsonify(error=f"无法启动进程：{e}"), 400

            _REGISTRY[st.id] = st

        st.thread = threading.Thread(target=_reader_thread, args=(st.proc, st), daemon=True)
        st.thread.start()

        return jsonify(run_id=st.id, kind=kind)

    def _sse_format(obj: dict[str, Any]) -> str:
        return "data: " + json.dumps(obj, ensure_ascii=False) + "\n\n"

    @app.route("/api/stream/<run_id>")
    def api_stream(run_id: str) -> Any:
        with _REGISTRY_LOCK:
            st = _REGISTRY.get(run_id)
        if st is None:
            abort(404)

        def gen() -> Iterator[str]:
            while True:
                item = st.log_q.get()
                if item is None:
                    yield _sse_format({"t": "done", "exit_code": st.exit_code})
                    return
                yield _sse_format({"t": "chunk", "text": item})

        return Response(
            stream_with_context(gen()),
            mimetype="text/event-stream",
            headers={
                "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
                "Connection": "keep-alive",
            },
        )

    @app.route("/api/stop/<run_id>", methods=["POST"])
    def api_stop(run_id: str) -> Any:
        with _REGISTRY_LOCK:
            st = _REGISTRY.get(run_id)
        if not st:
            return jsonify(error="unknown run_id"), 404
        if st.proc:
            kill_proc_group(st.proc)
            try:
                st.thread.join(timeout=2.0) if st.thread else None
            except RuntimeError:
                pass
            st.done.set()
            try:
                st.log_q.put_nowait(None)
            except queue.Full:
                pass
        return jsonify(ok=True)

    return app


def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="Auto-OS lab web GUI")
    ap.add_argument("--host", default="127.0.0.1", help="默认仅本机")
    ap.add_argument("--port", type=int, default=int(os.environ.get("LAB_GUI_PORT", "8765")))
    args = ap.parse_args()

    repo = repo_root()
    os.environ.setdefault("AUTO_OS_ROOT", str(repo))

    app = create_app()
    print(f"[lab-gui] repo_root={repo.as_posix()}", flush=True)
    print(f"[lab-gui] http://{args.host}:{args.port}/", flush=True)
    app.run(host=args.host, port=args.port, threaded=True)
