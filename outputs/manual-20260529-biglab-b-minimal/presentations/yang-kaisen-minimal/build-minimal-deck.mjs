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
  text(s, "StarryOS 自举编译与内核改进成果汇报", { x: 72, y: 116, w: 980, h: 64, size: 40, color: C.white, bold: true });
  text(s, "BigLab-B 最终汇报 | 杨凯森 | 2026-05", { x: 74, y: 198, w: 640, h: 34, size: 20, color: "#CBD5E1" });
  text(s, "本工作以 StarryOS guest 内自举编译 StarryOS 为目标，形成了 OS 修复、测试验证、多核性能分析和复现文档。", {
    x: 76,
    y: 292,
    w: 980,
    h: 52,
    size: 24,
    color: "#E5E7EB",
  });
  metric(s, "12", "已合入 OS PR", 76, 452, 240, C.green);
  metric(s, "331s", "8 核 guest self-build", 348, 452, 240, C.orange);
  metric(s, "2.87x", "guest 端到端调优", 620, 452, 240, C.blue);
  metric(s, "6.67x", "fork/exec/wait", 892, 452, 240, C.violet);
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
  const s = base(p, "03", "实验 1：AI 驱动的内核迭代框架", "框架目标是把 AI 辅助开发接入真实 OS 工程流程，保证每次改动可验证、可回溯、可提交。");
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
  const s = base(p, "04", "内核改进成果：12 个已合入 PR", "这些 PR 按 OS 行为边界拆分，覆盖进程线程、文件系统、网络 ABI、SMP 同步和调度前进性。");
  card(s, "进程 / 线程 / futex", "#692 robust futex cleanup\n#693 vfork parent blocking\n#878 teardown context", 70, 230, 340, 194, C.blue);
  card(s, "文件系统 / 设备", "#695 rsext4 inode bitmap\n#800 device full transfer\n#844 tmpfs rename exec", 470, 230, 340, 194, C.green);
  card(s, "SMP / 同步 / 调度", "#842 CPU topology\n#879 raw mutex handoff\n#885 syscall entry snapshot\n#926 SMP wakeup progress", 870, 230, 340, 194, C.orange);
  card(s, "网络 ABI", "#694 IPv4-mapped IPv6 socket\n保持 IPv6 用户态语义，内部复用 IPv4 backend。", 270, 466, 340, 130, C.violet);
  card(s, "验证标准", "每个 PR 均包含问题根因、修复范围、测试用例和 CI 或本地复现证据。", 670, 466, 340, 130, C.red);
}

function prVfork(p) {
  const s = base(p, "05", "重点 PR 一：vfork/clone 语义修复", "该 PR 恢复 CLONE_VFORK 父进程等待子进程 exec/exit 的 Linux ABI，影响 posix_spawn 与 shell 子进程路径。");
  split(
    s,
    "问题",
    ["CLONE_VFORK 父进程必须等到子进程 exec 或 exit。", "把等待条件错误收窄到 stack == 0，会破坏 BusyBox、shell、timeout 依赖的父子同步顺序。"],
    "修复与测例",
    ["所有 CLONE_VFORK 子进程都建立并等待 vfork_done。", "测例：test-vfork。", "影响范围：BusyBox / shell / cargo 子进程创建路径。"],
  );
  footer(s, "成果：修复进程创建 ABI 语义，使 BusyBox、shell 和 cargo 子进程创建路径具备更稳定的行为基础。");
}

function prFutex(p) {
  const s = base(p, "06", "重点 PR 二：futex 与线程退出清理", "该组修复提升了线程退出路径对用户态坏地址和 pending futex 状态的容错能力。");
  split(
    s,
    "问题",
    ["robust-list bad head 可能来自用户态坏指针。", "pending futex 和普通 entry 清理混在一起，会污染退出路径。"],
    "修复与测例",
    ["坏 entry 容错清理，pending 单独处理。", "测例：test-futex-robust-list。", "关联：teardown/context usercopy 修复退出路径。"],
  );
  footer(s, "成果：退出清理路径可以安全处理用户态异常输入，避免单个坏 robust-list 破坏进程回收流程。");
}

function prFs(p) {
  const s = base(p, "07", "重点 PR 三：文件系统与 VFS 正确性", "这些修复面向真实应用的文件系统访问模式，补齐 inode 分配、rename/exec 和设备传输语义。");
  card(s, "#695 rsext4 inode bitmap", "未初始化 inode bitmap 不能直接跳过整个 block group；应初始化后继续分配。", 82, 230, 330, 192, C.green);
  card(s, "#844 tmpfs rename exec", "rename/unlink 与 exec/open 组合不能留下不一致目录状态。", 476, 230, 330, 192, C.orange);
  card(s, "#800 device transfer", "设备读写需要支持完整 transfer，避免用户态工具拿到短读写。", 870, 230, 330, 192, C.blue);
  footer(s, "成果：文件系统层面对真实应用的目录项、inode 和设备 I/O 行为更加接近 Linux 预期。");
}

function prSmp(p) {
  const s = base(p, "08", "重点 PR 四：SMP 同步与调度前进性", "多核自举编译暴露了短任务、等待唤醒和远端 runqueue 上的前进性问题。");
  card(s, "#842 CPU topology", "给用户态暴露正确 CPU 拓扑，避免多核环境下配置和调度判断失真。", 80, 230, 335, 190, C.blue);
  card(s, "#879 RawMutex handoff", "修复同步原语 handoff 边界，降低锁竞争下的错误唤醒风险。", 472, 230, 335, 190, C.green);
  card(s, "#926 wakeup progress", "wait queue / remote runqueue wakeup 需要保证前进性。", 864, 230, 335, 190, C.orange);
  bullet(s, [
    { text: "验证：fork/exec/wait 1000 次在 j1/j2/j4/j8 下为 20/11/5/3s。", color: C.green },
    { text: "分析：完整 cargo 的剩余瓶颈集中在 T_wait、T_smp、T_fs 和串行尾段。", color: C.orange },
  ], 130, 486, 1020, 50, 22);
}

function selfBuild(p) {
  const s = base(p, "09", "实验 4：StarryOS guest 内自举编译", "实验目标是在 StarryOS userland 中运行 cargo build，完成 StarryOS 自身构建并输出 PASS marker。");
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
  const s = base(p, "10", "多核编译性能结果", "本页拆分端到端、编译并行、链接/串行尾段三种加速比，避免混用分母。");
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
  const s = base(p, "11", "性能模型与测试细项", "每个瓶颈都用接近 Cargo 行为的微基准拆开验证，而不是只给粗略归因。");
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

function alignedAnalysis(p) {
  const s = base(p, "12", "对齐对比：为什么 host 能 2.93x，guest 只有 1.24x", "这页把同一 StarryOS kernel 构建任务的 host 参考和 guest jobs-only 放在一起，说明差距来自哪里。");
  metric(s, "85s -> 29s", "host 对齐参考，2.93x", 92, 238, 260, C.blue);
  metric(s, "422s -> 341s", "guest jobs-only，1.24x", 380, 238, 260, C.orange);
  metric(s, "951s -> 331s", "guest 端到端调优，2.87x", 668, 238, 260, C.green);
  metric(s, "20/11/5/3s", "进程短链路，6.67x", 956, 238, 230, C.violet);
  rect(s, 92, 430, 1094, 126, C.white, C.line, 1);
  bullet(s, [
    { text: "host 对齐参考：同源码、同 AArch64/SMP8 kernel config、同 release profile；只是不进入 guest，不承担 StarryOS syscall、VFS、scheduler。", color: C.blue },
    { text: "guest jobs-only：同 profile 下只改 jobs，真实承担 fork/exec/wait、pipe、FS metadata、runqueue、锁竞争和虚拟化边界。", color: C.orange },
    { text: "结论：并行空间存在；没有线性加速不是因为多核无效，而是 full cargo 把 OS 短任务成本和串行尾段叠在一起。", color: C.green },
  ], 130, 454, 1000, 35, 19);
  footer(s, "现场讲法：host 是可并行上界；guest 是 OS 真实承载能力；两者差距就是本实验定位和修复的对象。");
}

function causeMatrix(p) {
  const s = base(p, "13", "成因拆解：Cargo、OS、QEMU 分别承担什么", "最后把瓶颈按归属拆清楚，避免把所有慢都归因给 QEMU 或 Cargo。");
  card(s, "Cargo / Rust 部分", "build-std、proc-macro、build.rs、crate critical path 和尾部 codegen/link 形成串行段；`jobs=12`、`-Z threads=4` 都已证明过并行会反吃。", 70, 224, 345, 220, C.blue);
  card(s, "StarryOS 内核部分", "进程等待/唤醒、runqueue 前进性、CPU topology、VFS metadata 和 ext4 sync 策略会影响短任务吞吐；#842/#926 和 rsext4 短测例对应这部分。", 468, 224, 345, 220, C.green);
  card(s, "QEMU/HVF 部分", "AArch64/HVF 去掉了 RISC-V TCG 翻译主开销，但仍有虚拟块设备、中断、VM exit 和 guest/host 边界；RISC-V MTTCG 只作 raw CPU 参考。", 866, 224, 345, 220, C.orange);
  rect(s, 126, 492, 1028, 76, C.white, C.line, 1);
  text(s, "最 solid 的结论：完整 self-build 已跑通；OS 短链路能扩展到 6.67x；full cargo 的剩余瓶颈被拆成可复现、可继续提 PR 的具体问题。", {
    x: 160,
    y: 514,
    w: 960,
    h: 34,
    size: 22,
    color: C.ink,
    bold: true,
    align: "center",
  });
}

function demo(p) {
  const s = base(p, "14", "复现材料与答辩支撑", "所有关键结果均保留复现命令、运行日志、PASS marker、PR 记录和最终报告材料。");
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
  numbers(presentation);
  framework(presentation);
  prMap(presentation);
  prVfork(presentation);
  prFutex(presentation);
  prFs(presentation);
  prSmp(presentation);
  selfBuild(presentation);
  speed(presentation);
  timeModel(presentation);
  alignedAnalysis(presentation);
  causeMatrix(presentation);
  demo(presentation);

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
