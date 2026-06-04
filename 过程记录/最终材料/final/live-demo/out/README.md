# Live Demo Output Evidence

这个目录保存最终演示脚本产生的小型证据文件。GitHub 上保留日志、测速摘要和 PASS marker 证据；rootfs、ELF、bin 等本地生成物不上传。

## 会上传的文件

| 类型 | 示例 | 说明 |
| --- | --- | --- |
| host build logs | `01-build-starryos-*.log` | host 构建 StarryOS 的脚本输出。 |
| guest build logs | `02-guest-build-starryos-*.log` | guest self-build 的 runner/serial/marker 日志。 |
| kernel test logs | `03-test-kernel-result.log` | 启动 kernel 并进入 userland 的 PASS 证据。 |
| speed summary | `05-speed-ratios-summary.txt` | demo benchmark、guest 实际编译、macOS host 编译的 `1 -> 8` 速比摘要。 |

## 不上传的本地生成物

这些文件可由 `../01-build-starryos`、`../02-guest-build-starryos` 重新生成，或过大不适合进 Git：

```text
rootfs-*.img
*.elf
*.bin
```

## 重新生成

从仓库根目录执行：

```bash
bash 过程记录/最终材料/final/live-demo/01-build-starryos
bash 过程记录/最终材料/final/live-demo/02-guest-build-starryos
bash 过程记录/最终材料/final/live-demo/03-test-kernel-result
bash 过程记录/最终材料/final/live-demo/05-speed-ratios
```
