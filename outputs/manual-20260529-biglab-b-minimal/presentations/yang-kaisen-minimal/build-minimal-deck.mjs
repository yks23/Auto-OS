#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";
import { spawnSync } from "node:child_process";

import {
  Presentation,
  PresentationFile,
} from "file:///Users/txc/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs";

const ROOT = "/Users/txc/code/Auto-OS";
const WORKSPACE = `${ROOT}/outputs/manual-20260529-biglab-b-minimal/presentations/yang-kaisen-minimal`;
const PREVIEW_DIR = path.join(WORKSPACE, "preview");
const OUT_DIR = `${ROOT}/showtime-2/final`;
const PPTX_OUT = path.join(OUT_DIR, "biglab-b-final-yang-kaisen-minimal.pptx");
const CONTACT_SHEET = path.join(OUT_DIR, "biglab-b-final-yang-kaisen-minimal-contact-sheet.png");

const W = 1280;
const H = 720;
const C = {
  ink: "#111827",
  muted: "#5B6472",
  faint: "#EEF2F7",
  paper: "#FAFBFC",
  white: "#FFFFFF",
  blue: "#2563EB",
  green: "#148A5A",
  orange: "#C45A18",
  violet: "#6A42B8",
  red: "#B42318",
  dark: "#0B1220",
  line: "#D8DEE8",
};

function line(fill = "#00000000", width = 0) {
  return { style: "solid", fill, width };
}

function rect(slide, x, y, w, h, fill = C.white, stroke = "#00000000", sw = 0) {
  return slide.shapes.add({
    geometry: "rect",
    position: { left: x, top: y, width: w, height: h },
    fill,
    line: line(stroke, sw),
  });
}

function text(slide, value, opt = {}) {
  const {
    x = 0,
    y = 0,
    w = 320,
    h = 40,
    size = 24,
    color = C.ink,
    bold = false,
    align = "left",
    valign = "top",
    fill = "#00000000",
    stroke = "#00000000",
    sw = 0,
    font = "PingFang SC",
    inset = 0,
  } = opt;
  const shape = rect(slide, x, y, w, h, fill, stroke, sw);
  shape.text = value;
  shape.text.fontSize = size;
  shape.text.color = color;
  shape.text.bold = bold;
  shape.text.typeface = font;
  shape.text.alignment = align;
  shape.text.verticalAlignment = valign;
  shape.text.insets = { left: inset, right: inset, top: inset, bottom: inset };
  return shape;
}

function base(presentation, no, title, claim) {
  const slide = presentation.slides.add();
  slide.background.fill = C.paper;
  rect(slide, 0, 0, 8, H, C.blue);
  text(slide, "BigLab-B / StarryOS", { x: 54, y: 30, w: 360, h: 26, size: 14, color: C.blue, bold: true });
  text(slide, no, { x: 1140, y: 30, w: 70, h: 26, size: 14, color: C.muted, align: "right" });
  text(slide, title, { x: 54, y: 78, w: 900, h: 54, size: 34, color: C.ink, bold: true });
  if (claim) {
    text(slide, claim, { x: 56, y: 140, w: 1060, h: 54, size: 20, color: C.muted });
  }
  return slide;
}

function metric(slide, value, label, x, y, w, accent = C.blue) {
  rect(slide, x, y, w, 122, C.white, C.line, 1);
  rect(slide, x, y, w, 5, accent);
  text(slide, value, { x: x + 18, y: y + 26, w: w - 36, h: 38, size: 30, color: accent, bold: true, align: "center" });
  text(slide, label, { x: x + 18, y: y + 75, w: w - 36, h: 36, size: 15, color: C.muted, align: "center" });
}

function card(slide, title, body, x, y, w, h, accent = C.blue) {
  rect(slide, x, y, w, h, C.white, C.line, 1);
  rect(slide, x, y, 5, h, accent);
  text(slide, title, { x: x + 24, y: y + 22, w: w - 48, h: 32, size: 22, color: C.ink, bold: true });
  text(slide, body, { x: x + 24, y: y + 66, w: w - 48, h: h - 78, size: 17, color: C.muted });
}

function bullet(slide, items, x, y, w, gap = 48, size = 22) {
  items.forEach((item, i) => {
    const yy = y + i * gap;
    const color = item.color || C.blue;
    rect(slide, x, yy + 11, 8, 8, color);
    text(slide, item.text || item, { x: x + 24, y: yy, w: w - 24, h: gap, size, color: item.textColor || C.ink });
  });
}

function split(slide, leftTitle, leftItems, rightTitle, rightItems) {
  card(slide, leftTitle, "", 74, 218, 520, 356, C.blue);
  card(slide, rightTitle, "", 686, 218, 520, 356, C.green);
  bullet(slide, leftItems.map((text) => ({ text, color: C.blue })), 112, 296, 430, 58, 20);
  bullet(slide, rightItems.map((text) => ({ text, color: C.green })), 724, 296, 430, 58, 20);
}

function footer(slide, value) {
  text(slide, value, { x: 90, y: 640, w: 1100, h: 42, size: 18, color: C.white, bold: true, align: "center", valign: "middle", fill: C.dark, inset: 8 });
}

function cover(p) {
  const s = p.slides.add();
  s.background.fill = C.dark;
  rect(s, 0, 0, 8, H, C.blue);
  text(s, "StarryOS 自举编译与内核改进成果汇报", { x: 72, y: 86, w: 980, h: 64, size: 39, color: C.white, bold: true });
  text(s, "BigLab-B 最终汇报 | 杨凯森 | 2026-05", { x: 74, y: 198, w: 640, h: 34, size: 20, color: "#CBD5E1" });
  text(s, "目标：让 StarryOS 承载一个真实的大型 Rust/Cargo workload，在 guest 内编译出 StarryOS 自己。", {
    x: 76,
    y: 260,
    w: 1040,
    h: 44,
    size: 25,
    color: "#F8FAFC",
    bold: true,
  });
  text(s, "这件事会系统性暴露 OS 层问题：进程创建、futex 退出、文件系统、SMP 同步、调度唤醒、用户态 ABI 和 QEMU/HVF 边界。", {
    x: 76,
    y: 318,
    w: 1050,
    h: 54,
    size: 21,
    color: "#CBD5E1",
  });
  bullet(s, [
    { text: "方法：用 AI 驱动的持续迭代框架，把长时间实验拆成可复现、可验证、可提交的 OS 修复。", color: C.green, textColor: "#E5E7EB" },
    { text: "成果：12 个 OS PR 已合入 TGOSKit dev；8 核 AArch64/HVF guest 完成 StarryOS self-build。", color: C.orange, textColor: "#E5E7EB" },
    { text: "分析：用 host 对齐参考和微基准拆清 Cargo、OS、QEMU 各自承担的性能成本。", color: C.blue, textColor: "#E5E7EB" },
  ], 84, 420, 930, 56, 21);
  rect(s, 990, 430, 166, 154, "#111C2F", "#334155", 1);
  text(s, "路线", { x: 1018, y: 454, w: 110, h: 26, size: 20, color: "#93C5FD", bold: true, align: "center" });
  text(s, "真实 workload\n暴露 OS 问题\n形成 PR 与测例\n再做性能诊断", {
    x: 1012,
    y: 492,
    w: 122,
    h: 72,
    size: 16,
    color: "#CBD5E1",
    align: "center",
  });
}

function bigLabA(p) {
  const s = base(p, "02", "BigLab-A：基础实验回顾", "本页先留作 BigLab-A 内容占位，后续按任务一实验记录补齐。");
  rect(s, 86, 214, 1108, 344, C.white, C.line, 1);
  text(s, "待补充", { x: 120, y: 248, w: 1040, h: 56, size: 32, color: C.muted, bold: true, align: "center" });
  text(s, "这里后续放 BigLab-A 的实验目标、完成情况、关键收获与仓库链接。", {
    x: 160,
    y: 330,
    w: 960,
    h: 42,
    size: 22,
    color: C.ink,
    align: "center",
  });
  text(s, "当前汇报重点放在 BigLab-B：AI 迭代框架、OS PR、StarryOS 自举编译与多核性能分析。", {
    x: 150,
    y: 400,
    w: 980,
    h: 50,
    size: 20,
    color: C.muted,
    align: "center",
  });
}

function task1(p) {
  const s = base(p, "03", "BigLab-B Task 1：AI 驱动工程框架", "Task 1 的重点不是单次修 bug，而是建立一套能持续同步、运行、定位、修复和提交的工作流。");
  card(s, "目标", "把 AI 辅助开发放进真实 OS 工程闭环：从问题发现到 PR 合并都保留证据。", 76, 226, 340, 186, C.blue);
  card(s, "原则", "反馈链路超过 2 小时就先缩短：小测例、低日志、resume/cache、宿主预检、直接 QEMU。", 470, 226, 340, 186, C.orange);
  card(s, "产物", "规则、harness、自动同步、PR 检测、日志归档、showtime 文档与可复现脚本。", 864, 226, 340, 186, C.green);
  bullet(s, [
    { text: "持续和 TGOSKit dev 对齐，避免长期偏离上游导致 PR 难合并。", color: C.blue },
    { text: "发现 OS bug 后，不停留在实验日志，而是整理 root cause、test-suite 和 PR 文案。", color: C.green },
    { text: "长任务用于验收，短任务用于定位；两者分开，减少无效等待。", color: C.orange },
  ], 116, 480, 1030, 46, 21);
}

function harnessPhaseOne(p) {
  const s = base(p, "04", "Task 2 Harness 第一阶段：模型驱动测试挖掘", "第一阶段尝试让模型生成测试并自动运行，用测试失败来反推 StarryOS 的 bug。");
  split(
    s,
    "做法",
    ["围绕 syscall、busybox 小命令和文件系统行为生成测试用例。", "模型读日志、提出怀疑点、继续补 case 或定位代码。"],
    "经验",
    ["能快速覆盖很多边界输入，但缺乏 workload 方向性。", "真实 OS bug 数量不稳定，容易陷入泛化测试和低价值失败。"],
  );
  footer(s, "结论：纯测试挖掘可以作为补充，但不足以支撑大实验主线；后续改为真实 workload 驱动。");
}

function harnessCurrent(p) {
  const s = base(p, "05", "Task 2 Harness 当前方案：与 StarryOS dev 紧密联动", "现在的框架以可合并 PR 为目标：每天同步 dev，在真实 StarryOS 任务中暴露问题，并沉淀测例。");
  const xs = [78, 308, 538, 768, 998];
  const items = [
    ["09:00", "同步 dev", C.blue],
    ["Run", "编译/运行任务", C.orange],
    ["Read", "读取输出", C.violet],
    ["Fix", "修改内核", C.green],
    ["PR", "测例+提交", C.red],
  ];
  items.forEach(([top, bottom, color], i) => {
    rect(s, xs[i], 258, 150, 92, C.white, C.line, 1);
    text(s, top, { x: xs[i] + 16, y: 278, w: 118, h: 28, size: 23, color, bold: true, align: "center" });
    text(s, bottom, { x: xs[i] + 16, y: 314, w: 118, h: 24, size: 17, color: C.ink, align: "center" });
    if (i < items.length - 1) rect(s, xs[i] + 160, 302, 70, 4, items[i + 1][2]);
  });
  card(s, "自动同步", "每天早上 9:00 拉取最新 dev，专门同步分支，减少上游快速演进带来的冲突成本。", 90, 420, 320, 128, C.blue);
  card(s, "自动修复闭环", "在 StarryOS 上跑具体任务；一旦发现相关 bug，整理 root cause 与 Test Suite，随 OS 改动提 PR 到 dev。", 480, 420, 320, 128, C.green);
  card(s, "PR 守护", "定时检查 PR CI 状态；未通过则继续收集失败、修复、推送，直到达到可合并状态。", 870, 420, 320, 128, C.orange);
}

function numbers(p) {
  const s = base(p, "02", "成果总览：PR、性能与复现", "本页汇总已完成的内核改进、StarryOS 自举编译结果和多核加速证据。");
  metric(s, "12 PR", "#692 #693 #694 #695 #800 #842 #843 #844 #878 #879 #885 #926", 70, 238, 260, C.green);
  metric(s, "331s", "AArch64/HVF 8 核 guest 内完整 self-build PASS", 365, 238, 260, C.orange);
  metric(s, "951s -> 331s", "guest 端到端调优 2.87x", 660, 238, 260, C.blue);
  metric(s, "20/11/5/3s", "1000 次 fork/exec/wait，8 路 6.67x", 955, 238, 260, C.violet);
  rect(s, 134, 440, 1012, 82, C.white, C.line, 1);
  text(s, "宿主对齐参考：85s -> 29s = 2.93x", { x: 164, y: 466, w: 460, h: 34, size: 25, color: C.ink, bold: true });
  text(s, "同一 StarryOS AArch64/SMP8 kernel 配置与同 profile；只把 cargo/rustc 从 guest 移到 host。", {
    x: 612,
    y: 458,
    w: 500,
    h: 44,
    size: 16,
    color: C.muted,
  });
  footer(s, "结论：host 参考和 guest 对齐到同一构建任务；差别只剩运行在哪个 OS/FS/scheduler 上。");
}

function framework(p) {
  const s = base(p, "02", "实验 1：AI 驱动的内核迭代框架", "框架目标是把 AI 辅助开发接入真实 OS 工程流程，保证每次改动可验证、可回溯、可提交。");
  const xs = [96, 338, 580, 822, 1064];
  const labels = ["同步 dev", "复现实验", "修复内核", "测试用例", "PR/CI"];
  const colors = [C.blue, C.orange, C.green, C.violet, C.red];
  labels.forEach((label, i) => {
    rect(s, xs[i] - 40, 284, 160, 96, C.white, C.line, 1);
    text(s, label, { x: xs[i] - 24, y: 312, w: 128, h: 34, size: 21, color: colors[i], bold: true, align: "center" });
    if (i < labels.length - 1) {
      rect(s, xs[i] + 134, 326, 120, 4, colors[i + 1]);
    }
  });
  bullet(s, [
    { text: "每日同步 TGOSKit dev 基线，PR 只基于 dev。", color: C.blue },
    { text: "反馈链路超过 2h 就缩短：小测例、低日志、resume/cache、宿主预检。", color: C.orange },
    { text: "确认 OS bug 后立刻转成 PR：root cause、最小修复、test-suite、CI。", color: C.green },
  ], 140, 450, 990, 48, 21);
}

function prMap(p) {
  const s = base(p, "06", "Task 2 PR：12 个已合入 OS 修复", "这些 PR 不按“改了多少文件”讲，而按 OS 行为边界拆分：进程线程、文件系统、网络 ABI、SMP 同步和调度前进性。");
  card(s, "进程 / 线程 / futex", "#692 robust futex cleanup\n#693 vfork parent blocking\n#878 teardown context", 70, 230, 340, 194, C.blue);
  card(s, "文件系统 / 设备", "#695 rsext4 inode bitmap\n#800 device full transfer\n#844 tmpfs rename exec", 470, 230, 340, 194, C.green);
  card(s, "SMP / 同步 / 调度", "#842 CPU topology\n#879 raw mutex handoff\n#885 syscall entry snapshot\n#926 SMP wakeup progress", 870, 230, 340, 194, C.orange);
  card(s, "网络 ABI", "#694 IPv4-mapped IPv6 socket\n保持 IPv6 用户态语义，内部复用 IPv4 backend。", 270, 466, 340, 130, C.violet);
  card(s, "验证标准", "每个 PR 均包含问题根因、修复范围、测试用例和 CI 或本地复现证据。", 670, 466, 340, 130, C.red);
}

function prVfork(p) {
  const s = base(p, "07", "重点 PR 1：vfork / clone 语义修复", "背景：vfork 是 Linux 中为了快速创建子进程的特殊 clone；父子共享地址空间，父进程必须等子进程 exec 或 exit。");
  split(
    s,
    "问题背景",
    ["posix_spawn、shell 执行命令时经常走 fork/vfork + exec。", "如果父进程过早继续运行，会破坏子进程尚未 exec 前的同步顺序。"],
    "修复与测例",
    ["修复 CLONE_VFORK 等待条件，保证父进程等待 vfork_done。", "测例：test-vfork。", "影响范围：BusyBox / shell / cargo 子进程创建路径。"],
  );
  footer(s, "成果：修复进程创建 ABI 语义，使 BusyBox、shell 和 cargo 子进程创建路径具备更稳定的行为基础。");
}

function prFutex(p) {
  const s = base(p, "08", "重点 PR 2：futex 与线程退出清理", "背景：futex 是 Linux 用户态锁的内核等待/唤醒机制；线程退出时 robust-list 要把可能遗留的锁状态清掉。");
  split(
    s,
    "问题背景",
    ["用户态可以传坏 robust-list 指针，内核不能因此拖垮退出路径。", "pending futex 与普通 entry 混在一起，会让 pthread 退出/回收变得脆弱。"],
    "修复与测例",
    ["坏 entry 容错清理，pending 单独处理。", "测例：test-futex-robust-list。", "关联：teardown/context usercopy 修复退出路径。"],
  );
  footer(s, "成果：退出清理路径可以安全处理用户态异常输入，避免单个坏 robust-list 破坏进程回收流程。");
}

function prFs(p) {
  const s = base(p, "09", "重点 PR 3：文件系统与 VFS 正确性", "背景：Cargo 编译会大量创建、写入、rename、unlink 小文件；文件系统细节会直接影响真实应用。");
  card(s, "#695 rsext4 inode bitmap", "ext4 block group 可标记 inode bitmap 未初始化；allocator 需要识别并初始化，再继续分配 inode。", 82, 230, 330, 208, C.green);
  card(s, "#844 tmpfs rename exec", "tmpfs 的目录项和可执行文件生命周期要一致；rename/unlink 不能让后续 exec/open 看到错乱状态。", 476, 230, 330, 208, C.orange);
  card(s, "#800 device transfer", "VFS 设备节点读写要遵守完整 transfer 语义，否则 busybox、构建脚本等用户态工具会拿到短读写。", 870, 230, 330, 208, C.blue);
  footer(s, "成果：文件系统层面对真实应用的目录项、inode 和设备 I/O 行为更加接近 Linux 预期。");
}

function prSmp(p) {
  const s = base(p, "07", "重点 PR 四：SMP 同步与调度前进性", "多核自举编译暴露了短任务、等待唤醒和远端 runqueue 上的前进性问题。");
  card(s, "#842 CPU topology", "给用户态暴露正确 CPU 拓扑，避免多核环境下配置和调度判断失真。", 80, 230, 335, 190, C.blue);
  card(s, "#879 RawMutex handoff", "修复同步原语 handoff 边界，降低锁竞争下的错误唤醒风险。", 472, 230, 335, 190, C.green);
  card(s, "#926 wakeup progress", "wait queue / remote runqueue wakeup 需要保证前进性。", 864, 230, 335, 190, C.orange);
  bullet(s, [
    { text: "验证：fork/exec/wait 1000 次在 j1/j2/j4/j8 下为 20/11/5/3s。", color: C.green },
    { text: "分析：完整 cargo 的剩余瓶颈集中在 T_wait、T_smp、T_fs 和串行尾段。", color: C.orange },
  ], 130, 486, 1020, 50, 22);
}

function selfBuild(p) {
  const s = base(p, "10", "实验 4：StarryOS guest 内自举编译", "实验目标是在 StarryOS userland 中运行 cargo build，完成 StarryOS 自身构建并输出 PASS marker。");
  const steps = ["启动内核", "挂载 rootfs", "运行 cargo", "定位 ELF", "PASS"];
  const colors = [C.blue, C.violet, C.orange, C.green, C.red];
  steps.forEach((step, i) => {
    const x = 78 + i * 236;
    rect(s, x, 286, 160, 92, C.white, C.line, 1);
    text(s, step, { x: x + 14, y: 315, w: 132, h: 30, size: 20, color: colors[i], bold: true, align: "center" });
    if (i < steps.length - 1) rect(s, x + 172, 329, 76, 4, colors[i + 1]);
  });
  bullet(s, [
    { text: "宿主对齐参考：同 StarryOS kernel 配置、同 target/profile，host cargo j1=85s，j8=29s。", color: C.blue },
    { text: "guest 最优：AArch64/HVF 8 核 StarryOS guest，完整 self-build 331s。", color: C.green },
    { text: "判据：进入 userland、找到 rootfs 内 StarryOS ELF、打印 PASS、无 panic/trap/FATAL/error。", color: C.orange },
  ], 130, 462, 1030, 48, 21);
}

function speed(p) {
  const s = base(p, "11", "多核编译性能结果", "通过脚本和构建参数调节，guest 完整 self-build 从 951s 降到 331s，约 3 倍，已稳定进入 400s 内。");
  metric(s, "951s", "最慢 guest baseline", 95, 250, 210, C.red);
  metric(s, "642s", "默认 8 核 guest", 328, 250, 210, C.orange);
  metric(s, "331s", "当前最快 guest", 561, 250, 210, C.green);
  metric(s, "29s", "host cargo j8", 794, 250, 210, C.blue);
  metric(s, "85s", "host cargo j1", 1027, 250, 160, C.violet);
  rect(s, 132, 430, 1016, 126, C.white, C.line, 1);
  text(s, "端到端真正收益：951s / 331s = 2.87x", { x: 154, y: 448, w: 460, h: 30, size: 20, color: C.green, bold: true });
  text(s, "guest 编译并行：422s / 341s = 1.24x", { x: 154, y: 482, w: 460, h: 30, size: 20, color: C.orange, bold: true });
  text(s, "host 对齐参考：85s / 29s = 2.93x", { x: 654, y: 448, w: 430, h: 30, size: 20, color: C.blue, bold: true });
  text(s, "链接/串行尾段：642s / 427s = 1.50x", { x: 654, y: 482, w: 430, h: 30, size: 20, color: C.violet, bold: true });
  text(s, "注：host 与 guest 编译同一 AArch64/SMP8 StarryOS kernel；host 不进入 guest，链接项不是独立 link-only benchmark。", { x: 154, y: 522, w: 930, h: 22, size: 15, color: C.muted });
  footer(s, "结论：完整 guest self-build 已完成；并行收益受 Cargo critical path、guest OS/FS/SMP 和串行尾段共同限制。");
}

function timeModel(p) {
  const s = base(p, "12", "性能模型与测试细项", "每个瓶颈都用接近 Cargo 行为的微基准拆开验证，而不是只给粗略归因。");
  text(s, "T_build(N) = T_std/cache + T_serial + T_parallel/N + T_fs(N) + T_smp(N) + T_wait(N)", {
    x: 96,
    y: 206,
    w: 1088,
    h: 60,
    size: 25,
    color: C.white,
    bold: true,
    align: "center",
    valign: "middle",
    fill: C.dark,
    inset: 8,
  });
  card(s, "进程链路", "fork/exec/wait 1000 次：20/11/5/3s，8 路 6.67x。模拟 cargo 反复 spawn rustc。", 64, 320, 270, 152, C.green);
  card(s, "短任务 wave", "24 个 build-script：27/22/27/32/32s。2 路最快，过并行会被 OS/FS/SMP 成本吃掉。", 356, 320, 270, 152, C.orange);
  card(s, "FS metadata", "rsext4 fileio jobs=8：47.5s→14.5s。模拟 target 小文件 create/write/rename/unlink。", 648, 320, 270, 152, C.blue);
  card(s, "宿主/QEMU参考", "host 同构建任务 85/29=2.93x；guest jobs-only 422/341=1.24x。raw CPU MTTCG 3.17x 不作 RISC-V correctness。", 940, 320, 270, 152, C.violet);
  text(s, "final link timestamp：artifact tail 约 2s，starry-kernel 后段约 17-20s；331s 版本主瓶颈不是纯链接。", { x: 100, y: 522, w: 1080, h: 34, size: 20, color: C.ink, bold: true, align: "center" });
}

function cpuTimeline(p) {
  const s = base(p, "13", "SMP8 CPU 利用率与阶段分析", "诊断 run 使用 GUEST_CPU_MONITOR=1 和 cargo JSON timing，耗时 457s；监控有开销，但能解释 8 核为什么没有线性加速。");
  const chartX = 112;
  const chartY = 222;
  const chartW = 760;
  const chartH = 250;
  rect(s, chartX, chartY, chartW, chartH, C.white, C.line, 1);
  for (let i = 0; i <= 4; i += 1) {
    const y = chartY + chartH - 34 - i * 45;
    rect(s, chartX + 58, y, chartW - 98, 1, C.faint);
    text(s, `${i * 25}%`, { x: chartX + 8, y: y - 10, w: 44, h: 18, size: 12, color: C.muted, align: "right" });
  }
  const phases = [
    { label: "0-90s", pct: 67, color: C.green, note: "build-std/proc-macro 启动" },
    { label: "90-180s", pct: 52, color: C.orange, note: "core/compiler_builtins 长链" },
    { label: "180-270s", pct: 70, color: C.blue, note: "crate 图中段并行" },
    { label: "270-360s", pct: 54, color: C.violet, note: "FS/等待/短任务波动" },
    { label: "360-457s", pct: 22, color: C.red, note: "starry-kernel / final tail" },
  ];
  phases.forEach((phase, i) => {
    const barW = 92;
    const x = chartX + 82 + i * 126;
    const maxH = 180;
    const h = Math.max(12, (phase.pct / 100) * maxH);
    const y = chartY + chartH - 34 - h;
    rect(s, x, y, barW, h, phase.color);
    text(s, `${phase.pct}%`, { x, y: y - 26, w: barW, h: 20, size: 15, color: phase.color, bold: true, align: "center" });
    text(s, phase.label, { x: x - 10, y: chartY + chartH - 24, w: barW + 20, h: 20, size: 13, color: C.muted, align: "center" });
    text(s, phase.note, { x: x - 20, y: chartY + chartH + 8, w: barW + 40, h: 44, size: 12, color: C.muted, align: "center" });
  });
  card(s, "怎么看这张图", "前中段能吃到并行，但并不是 8 核常满；后段掉到低利用率，说明瓶颈转成 Cargo critical path、单个大 crate codegen、文件系统 metadata 与 wait/wakeup。", 930, 222, 270, 142, C.blue);
  card(s, "监控暴露的问题", "旧 /proc/stat aggregate 曾出现非单调，说明 CPU 计数本身也需要内核修复；因此这里同时结合 cargo JSON timing 与微基准解释。", 930, 394, 270, 142, C.orange);
  footer(s, "结论：8 核是有效的，但完整 cargo 的可并行段、OS 开销和串行尾段不均衡；下一步应优化 T_wait、T_fs、T_smp。");
}

function alignedAnalysis(p) {
  const s = base(p, "14", "对齐对比：为什么 host 能 2.93x，guest 只有 1.24x", "这页把同一 StarryOS kernel 构建任务的 host 参考和 guest jobs-only 放在一起，说明差距来自哪里。");
  metric(s, "85s -> 29s", "host 对齐参考，2.93x", 118, 238, 300, C.blue);
  metric(s, "422s -> 341s", "guest jobs-only，1.24x", 490, 238, 300, C.orange);
  metric(s, "951s -> 331s", "guest 端到端调优，2.87x", 862, 238, 300, C.green);
  card(s, "Host 参考", "同源码、同 AArch64/SMP8 kernel config、同 release profile；cargo/rustc 跑在宿主机。", 118, 430, 300, 126, C.blue);
  card(s, "Guest 真实承载", "同 profile 只改 jobs，但要承担 syscall、VFS、scheduler、pipe/wait 和虚拟化边界。", 490, 430, 300, 126, C.orange);
  card(s, "结论", "并行空间存在；full cargo 的剩余差距来自 OS 短任务成本和串行尾段叠加。", 862, 430, 300, 126, C.green);
  footer(s, "现场讲法：host 是可并行上界；guest 是 OS 真实承载能力；两者差距就是本实验定位和修复的对象。");
}

function causeMatrix(p) {
  const s = base(p, "15", "成因拆解：Cargo、OS、QEMU 分别承担什么", "最后把瓶颈按归属拆清楚，避免把所有慢都归因给 QEMU 或 Cargo。");
  text(s, "观测", { x: 72, y: 226, w: 120, h: 28, size: 20, color: C.muted, bold: true });
  text(s, "归因", { x: 372, y: 226, w: 120, h: 28, size: 20, color: C.muted, bold: true });
  text(s, "已经做了什么", { x: 762, y: 226, w: 180, h: 28, size: 20, color: C.muted, bold: true });
  const rows = [
    ["host 2.93x\n但 guest jobs-only 1.24x", C.blue, "Cargo 图有并行空间；差距主要出在 guest 运行成本。", "对齐 host/guest profile，拆分 syscall、VFS、scheduler、QEMU 边界。"],
    ["fork/exec/wait\n8 路 6.67x", C.green, "进程创建和等待这条 OS 热路径本身可以扩展。", "#842 CPU topology、#926 wakeup progress、#879 RawMutex handoff。"],
    ["build-script wave\n2 路最快，8 路变慢", C.orange, "Cargo 短任务过并行后，被 pipe/wait、文件 metadata 和锁竞争反吃。", "用短基准定位 T_wait(N)、T_fs(N)、T_smp(N)，避免只等完整 build。"],
    ["final link tail\n约 2s", C.violet, "331s 版本主瓶颈不是纯链接器，而是 build graph 和 codegen 尾段。", "关闭 LTO、opt0、cgu256，串行尾段 642s -> 427s。"],
  ];
  rows.forEach(([obs, color, why, action], i) => {
    const y = 270 + i * 78;
    rect(s, 72, y, 220, 56, "#FFFFFF", C.line, 1);
    rect(s, 72, y, 6, 56, color);
    text(s, obs, { x: 94, y: y + 8, w: 170, h: 42, size: 17, color: C.ink, bold: true });
    rect(s, 314, y + 26, 32, 4, color);
    text(s, why, { x: 372, y: y + 2, w: 324, h: 56, size: 18, color: C.ink });
    rect(s, 720, y + 26, 32, 4, color);
    text(s, action, { x: 762, y: y + 2, w: 400, h: 56, size: 18, color: C.ink });
  });
  rect(s, 102, 604, 1076, 52, C.dark);
  text(s, "结论：self-build 已跑通；多核不是无效，剩余瓶颈已拆成 Cargo critical path、OS 短任务成本和虚拟化边界三类。", {
    x: 132,
    y: 618,
    w: 1016,
    h: 24,
    size: 19,
    color: C.white,
    bold: true,
    align: "center",
  });
}

function demo(p) {
  const s = base(p, "13", "复现材料与答辩支撑", "所有关键结果均保留复现命令、运行日志、PASS marker、PR 记录和最终报告材料。");
  card(s, "结果文档", "showtime-2/final/README.md\n包含性能 setting、日志路径和复现入口。", 78, 230, 335, 180, C.blue);
  card(s, "运行日志", "showtime-2/logs/*\nlive-demo/out/*.log\n包含 PASS marker、elapsed、arch、smp、jobs 等字段。", 472, 230, 335, 180, C.green);
  card(s, "PR 记录", "success-pr/PR-TRACKING.md\n记录已合入 PR、验证证据和重点修复说明。", 866, 230, 335, 180, C.orange);
  footer(s, "总结：本工作完成了 StarryOS 自举编译验证，并将真实 workload 暴露的问题沉淀为可合入的 OS 修复与测例。");
}

async function main() {
  await fs.mkdir(PREVIEW_DIR, { recursive: true });
  await fs.mkdir(OUT_DIR, { recursive: true });

  const presentation = Presentation.create({ slideSize: { width: W, height: H } });
  cover(presentation);
  bigLabA(presentation);
  task1(presentation);
  harnessPhaseOne(presentation);
  harnessCurrent(presentation);
  prMap(presentation);
  prVfork(presentation);
  prFutex(presentation);
  prFs(presentation);
  selfBuild(presentation);
  speed(presentation);
  timeModel(presentation);
  cpuTimeline(presentation);
  alignedAnalysis(presentation);
  causeMatrix(presentation);

  const previewPaths = [];
  for (let i = 0; i < presentation.slides.count; i += 1) {
    const slide = presentation.slides.getItem(i);
    const previewPath = path.join(PREVIEW_DIR, `slide-${String(i + 1).padStart(2, "0")}.png`);
    const preview = await presentation.export({ slide, format: "png", scale: 1 });
    await fs.writeFile(previewPath, Buffer.from(await preview.arrayBuffer()));
    previewPaths.push(previewPath);
  }

  const pptx = await PresentationFile.exportPptx(presentation);
  await pptx.save(PPTX_OUT);

  const python = "/Users/txc/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3";
  const makeSheet = "/Users/txc/.codex/plugins/cache/openai-primary-runtime/presentations/26.521.10419/skills/presentations/scripts/make_contact_sheet.py";
  const sheet = spawnSync(python, [makeSheet, "--output", CONTACT_SHEET, ...previewPaths], { encoding: "utf8" });
  if (sheet.status !== 0) {
    throw new Error(`contact sheet failed\n${sheet.stdout}\n${sheet.stderr}`);
  }

  const manifest = {
    output: PPTX_OUT,
    contactSheet: CONTACT_SHEET,
    slideCount: presentation.slides.count,
    previewDir: PREVIEW_DIR,
    previewPaths,
  };
  await fs.writeFile(path.join(OUT_DIR, "biglab-b-final-yang-kaisen-minimal-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  console.log(JSON.stringify(manifest, null, 2));
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
