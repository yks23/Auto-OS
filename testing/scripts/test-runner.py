#!/usr/bin/env python3
"""
Auto-OS 统一测试入口
编译测试 → 注入 rootfs → 启动 QEMU → 收集输出 → 解析结果 → 生成报告
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # testing/
PROJECT = ROOT.parent                          # Auto-OS/
UNIT_TESTS = PROJECT / "test-cases" / "custom"
LTP_LIST = PROJECT / "test-cases" / "ltp-subset" / "ltp-syscalls.list"
INTEGRATION = PROJECT / "test-cases" / "integration"
RESULTS_DIR = ROOT / "results"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)

MUSL_GCC = {
    "riscv64": "riscv64-linux-musl-gcc",
    "aarch64": "aarch64-linux-musl-gcc",
    "loongarch64": "loongarch64-linux-musl-gcc",
    "x86_64": "x86_64-linux-musl-gcc",
}


def log(msg):
    print(f"[test-runner] {msg}")


# ── L1: 自编单元测试 ──────────────────────────────────────

def build_unit_tests(arch: str, out_dir: Path) -> list[Path]:
    gcc = MUSL_GCC.get(arch, f"{arch}-linux-musl-gcc")
    out_dir.mkdir(parents=True, exist_ok=True)
    built = []
    for src in sorted(UNIT_TESTS.glob("test_*.c")):
        name = src.stem
        out = out_dir / name
        cmd = [gcc, "-static", "-o", str(out), str(src), "-lpthread"]
        try:
            subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=30)
            built.append(out)
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            log(f"  编译失败: {name} ({e})")
    log(f"L1: 编译 {len(built)}/{len(list(UNIT_TESTS.glob('test_*.c')))} 个测试")
    return built


def parse_test_output(output: str) -> dict:
    """解析 [TEST] name ... PASS/FAIL 格式的输出。"""
    tests = []
    for line in output.split("\n"):
        line = line.strip()
        if line.startswith("[TEST]"):
            m = re.match(r"\[TEST\]\s+(.+?)\s+\.\.\.\s+(PASS|FAIL.*)", line)
            if m:
                tests.append({
                    "name": m.group(1),
                    "result": "pass" if m.group(2) == "PASS" else "fail",
                    "detail": m.group(2) if m.group(2) != "PASS" else "",
                })
    summary_m = re.search(r"SUMMARY:\s*(\d+)/(\d+)\s*passed", output)
    return {
        "tests": tests,
        "passed": sum(1 for t in tests if t["result"] == "pass"),
        "failed": sum(1 for t in tests if t["result"] == "fail"),
        "total": len(tests),
        "summary_line": summary_m.group(0) if summary_m else None,
    }


def run_unit_tests_local(binaries: list[Path]) -> dict:
    """在本机运行测试（仅限 x86_64 或交叉编译到本机架构时）。"""
    results = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "details": []}

    for binary in binaries:
        name = binary.name
        try:
            result = subprocess.run(
                [str(binary)], capture_output=True, text=True, timeout=30)
            parsed = parse_test_output(result.stdout)
            status = "pass" if result.returncode == 0 else "fail"
            results["total"] += 1
            if status == "pass":
                results["passed"] += 1
            else:
                results["failed"] += 1
            results["details"].append({
                "name": name,
                "status": status,
                "exit_code": result.returncode,
                "sub_tests": parsed["tests"],
            })
        except subprocess.TimeoutExpired:
            results["total"] += 1
            results["failed"] += 1
            results["details"].append({"name": name, "status": "timeout"})
        except Exception as e:
            results["total"] += 1
            results["skipped"] += 1
            results["details"].append({"name": name, "status": "error", "error": str(e)})

    return results


# ── L2: LTP 子集 ─────────────────────────────────────────

def get_ltp_list() -> list[str]:
    if not LTP_LIST.exists():
        return []
    cases = []
    for line in LTP_LIST.read_text().split("\n"):
        line = line.strip()
        if line and not line.startswith("#"):
            cases.append(line.split()[0])
    return cases


# ── 报告生成 ──────────────────────────────────────────────

def generate_report(results: dict, arch: str) -> dict:
    commit = "unknown"
    try:
        r = subprocess.run(["git", "log", "--format=%h", "-1"],
                           capture_output=True, text=True, cwd=str(PROJECT))
        commit = r.stdout.strip()
    except Exception:
        pass

    report = {
        "timestamp": datetime.now().isoformat(),
        "arch": arch,
        "kernel_commit": commit,
        "levels": {},
        "overall_pass_rate": 0,
        "failed_tests": [],
    }

    total_all, passed_all = 0, 0
    for level, data in results.items():
        t = data.get("total", 0)
        p = data.get("passed", 0)
        f = data.get("failed", 0)
        s = data.get("skipped", 0)
        report["levels"][level] = {"total": t, "passed": p, "failed": f, "skipped": s}
        total_all += t
        passed_all += p

        for detail in data.get("details", []):
            if detail.get("status") in ("fail", "timeout"):
                report["failed_tests"].append({
                    "name": detail["name"],
                    "level": level,
                    "reason": detail.get("error", detail.get("status", "unknown")),
                })

    report["overall_pass_rate"] = round(passed_all / max(total_all, 1) * 100, 1)

    report_path = RESULTS_DIR / "latest.json"
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False))

    history_dir = RESULTS_DIR / "history"
    history_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    (history_dir / f"report-{ts}.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False))

    return report


def print_report(report: dict):
    print()
    print("=" * 60)
    print(f"  测试报告  {report['timestamp'][:19]}")
    print(f"  架构: {report['arch']}  内核: {report['kernel_commit']}")
    print("=" * 60)
    print()

    for level, data in report["levels"].items():
        t, p, f, s = data["total"], data["passed"], data["failed"], data["skipped"]
        pct = p / max(t, 1) * 100
        bar_len = 30
        bar_fill = int(bar_len * p / max(t, 1))
        bar = "█" * bar_fill + "░" * (bar_len - bar_fill)
        print(f"  {level:4s}: {bar} {p}/{t} ({pct:.0f}%)  fail={f} skip={s}")

    print()
    print(f"  总通过率: {report['overall_pass_rate']}%")

    if report["failed_tests"]:
        print()
        print("  ── 失败的测试 ──")
        for ft in report["failed_tests"][:20]:
            print(f"    ✗ [{ft['level']}] {ft['name']}: {ft['reason']}")
        if len(report["failed_tests"]) > 20:
            print(f"    ... 还有 {len(report['failed_tests']) - 20} 个")
    print()


# ── 主入口 ────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Auto-OS Test Runner")
    parser.add_argument("--arch", default="riscv64", help="目标架构")
    parser.add_argument("--level", choices=["l1", "l2", "l3", "l4", "all"], default="all")
    parser.add_argument("--test", help="只运行指定测试")
    parser.add_argument("--report", action="store_true", help="只打印最近报告")
    parser.add_argument("--build-only", action="store_true", help="只编译不运行")
    parser.add_argument("--local", action="store_true",
                        help="在本机运行（仅限 x86_64 测试或交叉编译到本机）")
    args = parser.parse_args()

    if args.report:
        latest = RESULTS_DIR / "latest.json"
        if latest.exists():
            print_report(json.loads(latest.read_text()))
        else:
            print("暂无测试报告。运行 --level l1 先执行一次测试。")
        return

    results = {}
    build_dir = ROOT / "build" / args.arch

    if args.level in ("l1", "all"):
        log("── L1: 自编单元测试 ──")
        binaries = build_unit_tests(args.arch, build_dir / "l1")
        if args.build_only:
            log(f"  已编译到 {build_dir / 'l1'}")
        elif args.local:
            results["l1"] = run_unit_tests_local(binaries)
        else:
            log("  需要 QEMU 运行（使用 --local 可在本机运行 x86_64 测试）")
            results["l1"] = {"total": len(binaries), "passed": 0, "failed": 0,
                             "skipped": len(binaries), "details": []}

    if args.level in ("l2", "all"):
        log("── L2: LTP 子集 ──")
        cases = get_ltp_list()
        log(f"  LTP 测试用例: {len(cases)} 个")
        log("  需要预编译的 LTP 二进制（见 TESTING.md）")
        results["l2"] = {"total": len(cases), "passed": 0, "failed": 0,
                         "skipped": len(cases), "details": []}

    if args.level in ("l3", "all"):
        log("── L3: 集成测试 ──")
        scripts = list(INTEGRATION.glob("test-*.sh"))
        log(f"  集成测试脚本: {len(scripts)} 个")
        results["l3"] = {"total": len(scripts), "passed": 0, "failed": 0,
                         "skipped": len(scripts), "details": []}

    if args.level in ("l4", "all"):
        log("── L4: oscomp 评测 ──")
        log("  需要 Docker 环境（见 TESTING.md）")
        results["l4"] = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "details": []}

    if results:
        report = generate_report(results, args.arch)
        print_report(report)


if __name__ == "__main__":
    main()
