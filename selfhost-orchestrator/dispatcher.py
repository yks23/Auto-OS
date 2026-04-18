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
WORKTREES_DIR = ROOT.parent / ".worktrees"
WORKSPACE = ROOT.parent
TGOSKITS = WORKSPACE / "tgoskits"

# 上游基线分支与集成分支
UPSTREAM_REF = "upstream/dev"     # rcore-os/tgoskits dev
INTEGRATION_BRANCH = "selfhost-dev"  # 在 yks23/tgoskits 上的集成分支

AGENT_BIN = os.path.expanduser("~/.local/bin/cursor-agent")
DEFAULT_MODEL = os.environ.get("DISPATCHER_MODEL", "")  # 空 = Auto
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
    ("T1", "execve-mt",       "cursor/selfhost-execve-mt-7c9d"),
    ("T2", "file-locks",      "cursor/selfhost-file-locks-7c9d"),
    ("T3", "ipv6-socket",     "cursor/selfhost-ipv6-7c9d"),
    ("T4", "mount-ext4-9p",   "cursor/selfhost-mount-fs-7c9d"),
    ("T5", "resource-limits", "cursor/selfhost-resource-limits-7c9d"),
]


def find_task_file(task_id: str) -> Path:
    matches = list(TASKS_DIR.glob(f"{task_id}-*.md"))
    if not matches:
        raise FileNotFoundError(f"No task md for {task_id} under {TASKS_DIR}")
    return matches[0]


def worktree_path(task_id: str) -> Path:
    return WORKTREES_DIR / task_id


def ensure_worktree(task_id: str, branch: str) -> Path:
    """为 task_id 创建/复用一个独立 git worktree。

    每个 subagent 在自己的 worktree 内工作，互不干扰。
    """
    WORKTREES_DIR.mkdir(parents=True, exist_ok=True)
    wt = worktree_path(task_id)

    # 在主 tgoskits 仓内 fetch upstream/origin，确保 ref 是新的
    subprocess.run(["git", "fetch", "upstream", "dev"], cwd=str(TGOSKITS), check=False)
    subprocess.run(["git", "fetch", "origin"], cwd=str(TGOSKITS), check=False)

    if wt.exists():
        # 复用现有 worktree，但更新分支指针到最新 upstream/dev（如果还没有 commit）
        return wt

    cmd = ["git", "worktree", "add", "-B", branch, str(wt), UPSTREAM_REF]
    r = subprocess.run(cmd, cwd=str(TGOSKITS), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"git worktree add failed: {r.stderr}")
    return wt


def build_prompt(task_id: str, branch: str, worktree: Path) -> str:
    body = find_task_file(task_id).read_text(encoding="utf-8")
    header = f"""你是 StarryOS self-hosting 计划的子工程师（subagent），由 Director 派发任务。

## 你的工作环境

- **工作目录**：`{worktree}`（这是一个独立的 git worktree，**只属于你**，可以放心改）
- **当前分支**：`{branch}`（已经基于 `{UPSTREAM_REF}` 创建好）
- **git remotes**：
    - `origin` = `https://github.com/yks23/tgoskits`（你 push 到这里）
    - `upstream` = `https://github.com/rcore-os/tgoskits`（只读基线）
- **集成分支**：`{INTEGRATION_BRANCH}`（在 `origin/yks23` 上，由 Director 维护）
- **PR 目标**：你的 PR 提到 `yks23/tgoskits` 的 `{INTEGRATION_BRANCH}` 分支（不是 upstream）

## 你必须做的事（流程）

1. `cd {worktree}`，确认 `git status` 干净、`git branch --show-current` == `{branch}`。
2. 严格按下面"任务包"实现。**不要扩大范围**：只动任务包列出的文件，遇到必须改其他文件时先在输出里说明。
3. 自检 acceptance criteria。
4. `git add` + 按 conventional commits 拆 commit（每个独立改动一个 commit）。
5. `git push -u origin {branch}` 推到 fork。
   - 如果 push 失败 403：**停下来**，不要 retry，把错误原文输出给 Director。
6. 用 `gh pr create --base {INTEGRATION_BRANCH} --head {branch} --repo yks23/tgoskits --title "..." --body "..."` 开 PR。
   - PR body 必须包含本任务的 acceptance criteria 自检表。

## 你必须返回给 Director 的产出

完成后**最后一段输出**必须是 JSON（包在 ```json``` 代码块里），格式：

```json
{{
  "task_id": "{task_id}",
  "branch": "{branch}",
  "commits": ["sha1", "sha2"],
  "pr_url": "https://github.com/yks23/tgoskits/pull/N",
  "acceptance_criteria": [
    {{"item": "...", "status": "PASS|PARTIAL|FAIL|SKIP", "note": "..."}}
  ],
  "blocked_by": ["可选：列出阻塞你的事项"],
  "decisions_needed": ["可选：必须 Director 决策的事"]
}}
```

## 边界

- **不得**直接 push 到 `{INTEGRATION_BRANCH}` 或 `dev`，只能 PR。
- **不得**rebase/force-push 别的分支。
- 如果 acceptance criteria 中有任何一条做不到，写明 PARTIAL/FAIL/SKIP 与原因，**不要假装完成**。
- 如果方案有多种且任务包没明确，按最低交付路径走，并在 `decisions_needed` 里说明。

================ 以下是你的任务包 ================

{body}
"""
    return header


def cmd_for(task_id: str, branch: str, model: str | None,
            worktree: Path) -> list[str]:
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
    if model:
        cmd += ["--model", model]
    cmd.append(prompt)
    return cmd


def env_check() -> tuple[bool, str]:
    if not Path(AGENT_BIN).exists():
        return False, f"cursor-agent CLI 不存在：{AGENT_BIN}"
    if not (WORKSPACE / "tgoskits" / ".git").exists():
        return False, "tgoskits 子模块未初始化"
    if not os.environ.get("CURSOR_API_KEY"):
        # 不阻塞 dry-run，但执行模式会失败
        return True, "warning: CURSOR_API_KEY 未设置（dry-run 可继续，--execute 会 401）"
    return True, "ok"


def dispatch_one(task_id: str, branch: str, *, dry_run: bool, model: str | None) -> dict:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = LOGS_DIR / f"{task_id}_{ts}.log"

    if dry_run:
        # dry-run 只构造命令，不真创建 worktree
        wt = worktree_path(task_id)
    else:
        wt = ensure_worktree(task_id, branch)

    cmd = cmd_for(task_id, branch, model, wt)

    info = {
        "task": task_id,
        "branch": branch,
        "worktree": str(wt),
        "log": str(log_path),
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
    ap.add_argument("--model", default=DEFAULT_MODEL, help="cursor-agent --model 参数")
    args = ap.parse_args()

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

    print(f"准备派发 {len(selected)} 个任务："
          f" {', '.join(tid for tid, _, _ in selected)}")

    results: list[dict] = []
    for tid, name, br in selected:
        info = dispatch_one(tid, br, dry_run=args.dry_run, model=args.model or None)
        results.append(info)
        if args.dry_run:
            print(f"  [{tid}/{name}] dry-run, prompt={info['prompt_chars']} chars,"
                  f" branch={br}")
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
