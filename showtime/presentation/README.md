# Showtime 展示稿

这个目录放验收/showtime 汇报用的材料。可以直接使用：

- [`showtime-deck.html`](showtime-deck.html)：单文件 HTML 幻灯片，可直接打开演示，也可以用浏览器打印成 PDF。

辅助材料：

- [`slides-outline.md`](slides-outline.md)：按 PPT 页组织的讲稿大纲。
- [`talk-track.md`](talk-track.md)：更接近口头表达的讲述顺序。

展示目标不是把所有细节一次讲完，而是让听众理解这些和内核实现直接相关的结论：

1. 单 CPU M6 guest self-build 已经跑通，并已留下 binary、checksum 和完整日志。
2. guest-built kernel 已经和 reference kernel 做过同环境 A/B boot smoke，证明当前 smoke 下行为一致。
3. 多 CPU 已经看到真实加速信号：hello-world 有约 `2.8x` 加速，M6 `jobs=2` subset 已 PASS。
4. 完整 M6 多核仍按 OS 正确性分阶段推进：v21 暴露 heartbeat stall，v22 已让早期 `starry-kernel` lib 阶段覆盖 SMP 调度代码，并进一步暴露 StoreFault。
5. 当前多核问题要围绕 OS 实现讲清楚：用户态 timer 抢占、用户任务迁移亲和性、run queue 负载、futex/锁后续压力。
6. QEMU/Docker/rootfs 只作为验证环境和边界条件说明，不作为汇报主线。
7. 已提 PR 需要逐个说明问题、修复内容、测例和 CI 状态：#692 robust futex cleanup、#693 vfork child-stack clone、#694 IPv4-mapped IPv6 socket、#695 rsext4 inode bitmap。
