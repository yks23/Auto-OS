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
WORKSPACE = ROOT.parent
TGOSKITS = WORKSPACE / "tgoskits"

AGENT_BIN = os.path.expanduser("~/.local/bin/cursor-agent")
DEFAULT_MODEL = os.environ.get("DISPATCHER_MODEL", "")  # 空 = Auto

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


def build_prompt(task_id: str, branch: str) -> str:
    body = find_task_file(task_id).read_text(encoding="utf-8")
    header = f"""你是 StarryOS self-hosting 计划的子工程师。

工作目录：{TGOSKITS}（这是 git submodule，已经 checkout 到 dev 分支）。
你需要在 {TGOSKITS} 内：
  1. `git fetch origin && git checkout -B {branch} origin/dev`
  2. 严格按下面"任务包"完成实现。
  3. 自检 acceptance criteria 后，在 {TGOSKITS} 内 git add/commit，按 conventional commits 拆 commit。
  4. `git push -u origin {branch}` 推送到 fork。
  5. 用 gh CLI（已在环境中预装）或在 PR body 内写出完整内容，提 PR 到 `rcore-os/tgoskits` 的 `dev` 分支。

完成后输出：
  - 你创建的 commit SHA 列表
  - 推送的分支名
  - 创建/更新的 PR URL（如有）
  - acceptance criteria 自检表（每条 ✅/⚠️/❌ 并附简短说明）

如果中途遇到必须由总监决策的事（例如方案选择不明、上游 API 缺失）：**不要静默改方案**，
请先在最终输出里清晰列出"待决策项"，再按你认为最稳的最低交付路径推进。

================ 以下是你的任务包 ================

{body}
"""
    return header


def cmd_for(task_id: str, branch: str, model: str | None) -> list[str]:
    prompt = build_prompt(task_id, branch)
    cmd = [
        AGENT_BIN,
        "-p",
        "--output-format", "stream-json",
        "--stream-partial-output",
        "--force",
        "--trust",
        "--workspace", str(WORKSPACE),
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
    cmd = cmd_for(task_id, branch, model)

    info = {
        "task": task_id,
        "branch": branch,
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
    log_fp.write(f"# task={task_id} branch={branch} started={info['started_at']}\n")
    log_fp.write(f"# cmd: {info['cmd_preview']}\n")
    log_fp.flush()

    proc = subprocess.Popen(
        cmd,
        stdout=log_fp,
        stderr=subprocess.STDOUT,
        cwd=str(WORKSPACE),
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
