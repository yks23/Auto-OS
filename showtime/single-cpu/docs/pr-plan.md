# PR Plan

这个文件记录后续准备 PR 时可直接复用的拆分方式、描述格式和测试证据。

## 拆分原则

- 一个 PR 只修一个行为问题。
- 每个 PR 都要有独立测例或明确已有测例。
- 文档/注释修改和行为修复可以在同一 PR 内，但不要混入无关重构。
- CI 抖动要在 PR 评论中说明，不要用 unrelated code change 掩盖。

## PR 描述模板

```md
## Summary

- ...
- ...

## Tests

- ...

## Notes

- ...
```

## 当前 PR 队列

| PR | 类型 | 状态 | 下一步 |
| --- | --- | --- | --- |
| #692 | robust futex cleanup | 新提交已触发 CI | 等 CI 完成 |
| #693 | vfork/clone behavior | 代码侧暂无新问题 | 需要有权限者 rerun CI |
| #694 | IPv4-mapped IPv6 socket | 代码侧暂无新问题 | 需要有权限者 rerun CI |
| #695 | rsext4 inode bitmap | CI 绿 | 等 review/merge |

## 新 PR 候选

- 单 CPU baseline 复现文档/脚本：binary、guest self-build log 和一次 host QEMU boot smoke 已落到 showtime；等交互 shell/`ls /` smoke 补齐后可提文档/脚本类 PR，注意不要把本地展示目录直接作为 TGOSKit 上游结构提交。
- M6 checkpoint 反馈链路优化：把最终 ELF/bin 先复制到小文件输出区，再保存大 checkpoint；checkpoint 保存后立即做 readback/size/hash 验证，让失败更早暴露。
- rsext4/axfs-ng 大文件 readback regression：从本次 `target.tar` duplicate extent 现象里抽最小 OS/filesystem 测例，再单独提功能修复 PR。
- guest Starry QEMU 支撑修复：只有在实际跑 guest QEMU 时发现明确 syscall/device 缺口后再拆。
- 多 CPU 相关修复：放到 `../../multi-cpu/docs/pr-candidates.md` 维护。
