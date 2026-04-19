#!/usr/bin/env python3
"""Self-host Dispatcher.

把 selfhost-orchestrator/tasks/*.md 的任务包并发派发给 cursor-agent CLI。
每个任务在独立的 git worktree + 独立 cursor-agent session 中跑。

用法：
    python3 dispatcher.py --dry-run                # 只打印命令
    python3 dispatcher.py --execute                # 真派发全部任务
    python3 dispatcher.py --execute --only T1      # 只派发 T1
    python3 dispatcher.py --execute --model sonnet-4-thinking
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TASKS_DIR = ROOT / "tasks"
LOGS_DIR = ROOT / "logs"
SESSIONS_DIR = ROOT / "sessions"
WORKTREES_DIR = ROOT.parent / ".worktrees"
WORKSPACE = ROOT.parent
TGOSKITS = WORKSPACE / "tgoskits"
PATCHES = WORKSPACE / "patches"
PIN_FILE = WORKSPACE / "PIN.toml"


def read_pin_commit() -> str:
    """从 PIN.toml 读取 tgoskits 上游 base commit。"""
    if not PIN_FILE.exists():
        return ""
    for raw in PIN_FILE.read_text().splitlines():
        s = raw.strip()
        if s.startswith("commit") and "=" in s:
            return s.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


PIN_COMMIT = read_pin_commit()

AGENT_BIN = os.path.expanduser("~/.local/bin/cursor-agent")
DEFAULT_MODEL = os.environ.get("DISPATCHER_MODEL", "auto")  # 默认 auto
ENV_FILE = Path(os.path.expanduser("~/.config/selfhost-orchestrator/env"))


def load_local_env() -> None:
    """从 ~/.config/selfhost-orchestrator/env 加载本地 export 形式 env。

    文件格式举例（chmod 600）：
        export CURSOR_API_KEY="crsr_xxx"
    """
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), val)


load_local_env()

# 每个任务包对应 (id, 标题, 工作分支)
TASKS = [
    ("T-skel", "test-skeletons", "cursor/selfhost-test-skeletons-7c9d"),
    ("T1",     "execve-mt",       "cursor/selfhost-execve-mt-7c9d"),
    ("T2",     "file-locks",      "cursor/selfhost-file-locks-7c9d"),
    ("T3",     "ipv6-socket",     "cursor/selfhost-ipv6-7c9d"),
    ("T4",     "mount-ext4-9p",   "cursor/selfhost-mount-fs-7c9d"),
    ("T5",     "resource-limits", "cursor/selfhost-resource-limits-7c9d"),
    ("M1.5",   "guest-validation","cursor/m15-guest-validation-7c9d"),
    ("F-alpha","fork-exec-deadlock", "cursor/falpha-fork-exec-deadlock-7c9d"),
    ("F-beta", "console-rx",     "cursor/fbeta-console-rx-7c9d"),
]


def current_branch() -> str:
    """读 Auto-OS 仓的当前分支名（subagent worktree 应基于此）。"""
    r = subprocess.run(["git", "rev-parse", "--abbrev-ref", "HEAD"],
                       cwd=str(WORKSPACE), capture_output=True, text=True)
    return r.stdout.strip() or "main"


# 全局 base ref（可被 --base 覆盖）
DISPATCH_BASE: str | None = None


def find_task_file(task_id: str) -> Path:
    matches = list(TASKS_DIR.glob(f"{task_id}-*.md"))
    if not matches:
        raise FileNotFoundError(f"No task md for {task_id} under {TASKS_DIR}")
    return matches[0]


def worktree_path(task_id: str) -> Path:
    return WORKTREES_DIR / task_id


def ensure_worktree(task_id: str, branch: str) -> Path:
    """为 task_id 创建/复用一个独立的 Auto-OS 仓 worktree。

    每个 subagent 在自己的 worktree 里工作。Worktree 包含完整 Auto-OS 仓
    （含 patches/、scripts/、tgoskits/ 子模块），互不干扰。
    """
    WORKTREES_DIR.mkdir(parents=True, exist_ok=True)
    wt = worktree_path(task_id)

    # Auto-OS 仓的 fetch
    subprocess.run(["git", "fetch", "origin"], cwd=str(WORKSPACE), check=False)

    if wt.exists():
        return wt

    base = DISPATCH_BASE or current_branch()
    cmd = ["git", "worktree", "add", "-B", branch, str(wt), base]
    r = subprocess.run(cmd, cwd=str(WORKSPACE), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git worktree add failed: {r.stderr}")

    # 在新 worktree 内初始化 tgoskits 子模块
    subprocess.run(["git", "submodule", "update", "--init", "tgoskits"],
                   cwd=str(wt), check=False)
    # 把 tgoskits reset 到 PIN
    if PIN_COMMIT:
        subprocess.run(["git", "fetch", "upstream", "dev"],
                       cwd=str(wt / "tgoskits"), check=False)
        subprocess.run(["git", "reset", "--hard", PIN_COMMIT],
                       cwd=str(wt / "tgoskits"), check=False)
    return wt


def build_prompt(task_id: str, branch: str, worktree: Path) -> str:
    body = find_task_file(task_id).read_text(encoding="utf-8")
    patch_dir_name = task_id  # 比如 T1-execve-mt
    header = f"""你是 StarryOS self-hosting 计划的子工程师（subagent），由 Director 派发任务。

## 你的工作环境（重要）

- **Auto-OS 仓 worktree**：`{worktree}`（独立 git worktree，只属于你）
- **Auto-OS 仓分支**：`{branch}`（已基于 `main` 创建好，你 push 这个分支）
- **tgoskits 子模块**：`{worktree}/tgoskits`，已 reset 到 PIN commit `{PIN_COMMIT[:8]}`
- **patches 输出目录**：`{worktree}/patches/{patch_dir_name}/`
- **测试输出目录**：`{worktree}/tests/selfhost/`

## 工作模式：patches-in-Auto-OS（务必遵守）

**你绝对不要 push tgoskits 子模块**。Auto-OS 项目的所有 tgoskits 修改都以 patch 形式
存在 `patches/Tn-slug/` 目录里。完整规则见 `{worktree}/patches/README.md`。

## 你必须做的事（流程）

1. `cd {worktree}`，确认 `git status` 干净、`git branch --show-current` == `{branch}`。
2. `cd tgoskits && git checkout -B cursor/selfhost-{patch_dir_name.lower()}-7c9d {PIN_COMMIT}`
   - 在 tgoskits 子模块里开一个临时本地分支，用来承载你的 commit。
   - 这个分支不会被 push，只是用来 `git format-patch` 提取。
3. 严格按下面"任务包"实现。**不要扩大范围**：只动任务包列出的文件，遇到必须改其他文件时先在输出里说明。
4. 在 tgoskits 内 `git add` + Conventional Commits 拆 commit（每个独立改动一个 commit）。
5. `cd {worktree}` (回到 Auto-OS worktree)
6. **运行 `scripts/extract-patches.sh {patch_dir_name}`** 把 commits 提到 `patches/{patch_dir_name}/0001-...patch …`
7. **运行 `scripts/sanity-check.sh`** 确认 patches 自身可 apply（必须看到 `OK: ...`）
8. **运行 `scripts/build.sh ARCH=riscv64`** 与 `scripts/build.sh ARCH=x86_64` 验证两架构都能 build
   - 如果 host 缺 musl 工具链可能跑不动，那就跳过，留待 CI 验证，但要在输出里说明
9. 在 Auto-OS worktree 内：
   - `git add patches/{patch_dir_name}/ tests/selfhost/`
   - `git commit -m "feat(patches/{task_id}): <一句话总结>"`
   - `git push -u origin {branch}`
10. 用 `gh pr create --base main --head {branch} --repo yks23/Auto-OS --title "..." --body "..."` 开 PR
    - PR title: `feat(selfhost): {task_id} <slug>`
    - PR body 必须含 acceptance criteria 自检表 + 测试运行日志摘要

## 你必须返回给 Director 的产出

### 完成信号（最重要）

完成所有工作后，**最后一步必须**：

```bash
mkdir -p selfhost-orchestrator/done
cat > selfhost-orchestrator/done/{task_id}.done <<'EOF'
{ ... 你的 final JSON summary ... }
EOF
```

Director 通过监听这个 sentinel 文件知道你完成了，**不写 sentinel = Director 不知道你完成**，会一直挂等。

如果你卡住或失败了也要写 sentinel，把 status 写成 FAIL/BLOCKED + 原因。**任何情况都必须写**。

### 同时也要在终端输出 JSON

最后一段输出**也必须是 JSON**（包在 ```json``` fenced block 里），与 sentinel 内容一致，格式：

```json
{{
  "task_id": "{task_id}",
  "auto_os_branch": "{branch}",
  "tgoskits_local_branch": "cursor/selfhost-{patch_dir_name.lower()}-7c9d",
  "patches": ["patches/{patch_dir_name}/0001-xxx.patch", "..."],
  "tests": ["tests/selfhost/test_xxx.c", "..."],
  "auto_os_commits": ["sha1", "..."],
  "pr_url": "https://github.com/yks23/Auto-OS/pull/N",
  "sanity_check": "PASS|FAIL",
  "build_riscv64": "PASS|FAIL|SKIPPED",
  "build_x86_64": "PASS|FAIL|SKIPPED",
  "acceptance_criteria": [
    {{"item": "...", "status": "PASS|PARTIAL|FAIL|SKIP", "note": "..."}}
  ],
  "blocked_by": [],
  "decisions_needed": []
}}
```

## 硬约束

- **不得**修改 `tgoskits` 之外的任何文件，**除了** `patches/{patch_dir_name}/` 与 `tests/selfhost/`。
- **不得**修改 `scripts/`、`PIN.toml`、`.github/workflows/`、其它任务的 `patches/Tj/`。
- **不得** push tgoskits 子模块到任何 remote。
- **不得** force-push 任何分支。
- 任何 acceptance criteria 做不到，标 PARTIAL/FAIL/SKIP 并说明原因，**不要假装完成**。

================ 以下是你的任务包 ================

{body}
"""
    return header


def cmd_for(task_id: str, branch: str, model: str | None,
            worktree: Path, session_id: str | None = None,
            extra_prompt: str | None = None) -> list[str]:
    """
    构建 cursor-agent CLI 调用：
    - session_id != None：用 --resume <id>，prompt 当作"接着干"的 followup
    - session_id == None：新建 session
    """
    if extra_prompt is not None:
        prompt = extra_prompt
    else:
        prompt = build_prompt(task_id, branch, worktree)
    cmd = [
        AGENT_BIN,
        "-p",
        "--output-format", "stream-json",
        "--stream-partial-output",
        "--force",
        "--trust",
        "--workspace", str(worktree),
    ]
    if session_id:
        cmd += ["--resume", session_id]
    if model:
        cmd += ["--model", model]
    cmd.append(prompt)
    return cmd


def session_file(task_id: str) -> Path:
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
    return SESSIONS_DIR / f"{task_id}.session"


def load_session_id(task_id: str) -> str | None:
    sf = session_file(task_id)
    if sf.exists():
        return sf.read_text().strip() or None
    return None


def save_session_id(task_id: str, sid: str) -> None:
    session_file(task_id).write_text(sid)


def create_chat() -> str:
    """调用 cursor-agent create-chat 拿 session ID。"""
    r = subprocess.run([AGENT_BIN, "create-chat"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"create-chat failed: {r.stderr}")
    return r.stdout.strip().splitlines()[-1].strip()


def extract_session_id_from_log(log_path: Path) -> str | None:
    """从 stream-json log 中提取 session_id（任意一个 event 上都有）。"""
    if not log_path.exists():
        return None
    try:
        with open(log_path) as f:
            for line in f:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                sid = obj.get("session_id")
                if sid:
                    return sid
    except Exception:
        pass
    return None


def env_check() -> tuple[bool, str]:
    if not Path(AGENT_BIN).exists():
        return False, f"cursor-agent CLI 不存在：{AGENT_BIN}"
    if not (WORKSPACE / "tgoskits" / ".git").exists():
        return False, "tgoskits 子模块未初始化"
    if not os.environ.get("CURSOR_API_KEY"):
        # 不阻塞 dry-run，但执行模式会失败
        return True, "warning: CURSOR_API_KEY 未设置（dry-run 可继续，--execute 会 401）"
    return True, "ok"


def dispatch_one(task_id: str, branch: str, *, dry_run: bool, model: str | None,
                 foreground: bool = False, resume: bool = False,
                 followup_prompt: str | None = None) -> dict:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = LOGS_DIR / f"{task_id}_{ts}.log"

    if dry_run:
        wt = worktree_path(task_id)
    else:
        wt = ensure_worktree(task_id, branch)

    sid = None
    if resume:
        sid = load_session_id(task_id)
        if not sid:
            raise RuntimeError(f"--resume requested but no session for {task_id}; run without --resume first")
    else:
        # 新 session：尝试 create-chat 拿 ID，存盘后用 --resume 启动
        # 这样后续可以接着干
        if not dry_run:
            try:
                sid = create_chat()
                save_session_id(task_id, sid)
            except Exception as e:
                # 不致命：第一次跑也可以不带 --resume，session_id 会出现在 stream-json log 里
                print(f"  [warn] create-chat failed ({e}); will extract sid from log", file=sys.stderr)

    cmd = cmd_for(task_id, branch, model, wt, session_id=sid,
                  extra_prompt=followup_prompt)

    info = {
        "task": task_id,
        "branch": branch,
        "worktree": str(wt),
        "log": str(log_path),
        "session_id": sid,
        "resumed": resume,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "cmd_preview": " ".join(shlex.quote(c) if i < len(cmd) - 1 else "<PROMPT>"
                                for i, c in enumerate(cmd)),
    }

    if dry_run:
        info["mode"] = "dry-run"
        info["prompt_chars"] = len(cmd[-1])
        return info

    log_fp = log_path.open("w", encoding="utf-8")
    log_fp.write(f"# task={task_id} branch={branch} worktree={wt}\n")
    log_fp.write(f"# started={info['started_at']}\n")
    log_fp.write(f"# cmd: {info['cmd_preview']}\n")
    log_fp.flush()

    if foreground:
        info["mode"] = "foreground"
        log_fp.close()
        with open(log_path, "ab", buffering=0) as f:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                cwd=str(wt),
                env={**os.environ},
            )
            assert proc.stdout
            for raw in iter(proc.stdout.readline, b""):
                f.write(raw)
                sys.stdout.buffer.write(raw)
                sys.stdout.buffer.flush()
            rc = proc.wait()
        info["returncode"] = rc
        # 如果 create-chat 之前没成功，从 log 里捞 sid
        if not sid:
            extracted = extract_session_id_from_log(log_path)
            if extracted:
                save_session_id(task_id, extracted)
                info["session_id"] = extracted
        return info

    proc = subprocess.Popen(
        cmd,
        stdout=log_fp,
        stderr=subprocess.STDOUT,
        cwd=str(wt),
        env={**os.environ},
        start_new_session=True,
    )
    info["pid"] = proc.pid
    info["mode"] = "spawned"
    return info


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只打印将要执行的命令")
    ap.add_argument("--execute", action="store_true", help="真派发 cursor-agent")
    ap.add_argument("--only", action="append", default=[], help="只跑指定 task id（可重复）")
    ap.add_argument("--model", default=DEFAULT_MODEL, help="cursor-agent --model 参数（默认 auto）")
    ap.add_argument("--foreground", action="store_true",
                    help="前台运行单个任务（必须配 --only Tn），实时把输出连到当前 terminal log")
    ap.add_argument("--base", default=None,
                    help="worktree 基于的 ref（默认是当前分支）")
    ap.add_argument("--resume", action="store_true",
                    help="resume 已有 session（必须配 --only + --followup）")
    ap.add_argument("--followup", default=None,
                    help="发给已有 session 的 followup prompt（必须配 --resume）")
    args = ap.parse_args()

    global DISPATCH_BASE
    DISPATCH_BASE = args.base

    if not args.dry_run and not args.execute:
        ap.error("必须指定 --dry-run 或 --execute 之一")

    ok, msg = env_check()
    print(f"[env-check] {msg}")
    if not ok:
        return 2
    if args.execute and not os.environ.get("CURSOR_API_KEY"):
        print("ERROR: 未设置 CURSOR_API_KEY，--execute 模式会立刻 401。")
        print("请先在 Cursor Dashboard → Cloud Agents → Secrets 中配置后重试。")
        return 3

    selected = [(tid, name, br) for tid, name, br in TASKS
                if not args.only or tid in args.only]
    if not selected:
        print(f"没有匹配的任务（--only={args.only}）")
        return 1

    if args.foreground and len(selected) != 1:
        ap.error("--foreground 必须配 --only 单个任务")

    print(f"准备派发 {len(selected)} 个任务："
          f" {', '.join(tid for tid, _, _ in selected)}")

    if args.resume and not args.followup:
        ap.error("--resume 必须配 --followup")
    if args.followup and not args.resume:
        ap.error("--followup 必须配 --resume")

    results: list[dict] = []
    for tid, name, br in selected:
        info = dispatch_one(tid, br, dry_run=args.dry_run, model=args.model or None,
                            foreground=args.foreground,
                            resume=args.resume,
                            followup_prompt=args.followup)
        results.append(info)
        if args.dry_run:
            print(f"  [{tid}/{name}] dry-run, prompt={info['prompt_chars']} chars,"
                  f" branch={br}")
        elif args.foreground:
            print(f"  [{tid}/{name}] finished returncode={info.get('returncode')}"
                  f" log={info['log']}")
        else:
            print(f"  [{tid}/{name}] spawned pid={info['pid']} log={info['log']}")
        time.sleep(0.2)

    summary_path = LOGS_DIR / f"dispatch_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(f"\nDispatch summary: {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
