# Lab GUI — 本地 Web 控制台（SSE 串流）

在浏览器里一键跑仓库常见测试脚本，实时查看 **stdout+stderr** 合并输出；默认仅监听 **`127.0.0.1`**。

打开页面后**默认不预填命令**（下拉首项为「留空」）：可先改环境变量与工作目录，再选预设或手写命令行，最后点「运行」。

## 启动

依赖（任选其一安装 Flask）：

```bash
python3 -m pip install -r requirements.txt
```

从本目录启动：

```bash
./run.sh
# 或：
export PYTHONPATH="$(pwd)"
python3 -m lab_gui
```

等价参数：

- `--host` 默认 `127.0.0.1`
- `--port` 默认 `8765`，也可用环境变量 `LAB_GUI_PORT`

打开浏览器：**http://127.0.0.1:8765/** （端口以终端打印为准）。

## 仓库根目录

- 默认：由 `tools/lab-gui/lab_gui/server.py` 相对路径推导指向 Auto-OS 仓库根。
- 可选：设置 **`AUTO_OS_ROOT`** 指向另一份检出路径（工作目录、脚本路径解析均以此为根）。

## 安全模型（必读）

本工具在你的用户权限下 **`subprocess.Popen` 不经 shell** 启动子进程：

1. **预设命令**：与代码里 **allowlist 完全一致**的 `bash`/`python3` argv 才可运行。
2. **改写命令行**：若与 allowlist 不同，则走「自定义」校验：
   - 第一个参数须为 **`bash` 或 `python3`**（或绝对路径，但 basename 须为二者之一）；
   - **禁止 `bash -c`**；
   - 须定位到仓库内的一份**真实脚本文件**（首个脚本参数经解析后在 `AUTO_OS_ROOT` 下）；
   - 可在其后附加任意参数（如 `ARCH=riscv64`、`KERNEL=` 等）；
   - 原始命令行中含 `;`、`|`、反引、`$(`、`${`、换行等会被拒绝。
3. **风险**：获准的脚本若本身会执行破坏性操作（删盘、挂载等），仍等同于你在终端亲手运行。**Stop** 会向子进程所在 **进程组** 发 `SIGTERM`（POSIX），必要时 `SIGKILL`。

## 环境与文档

左侧预设 **「访客 onecrate + syscall 证据」** 对应：

```bash
bash scripts/guest-onecrate-syscall-evidence.sh
```

环境变量说明见 **`scripts/guest-onecrate-syscall-evidence.sh` 顶部注释**（`GUEST_ONECRATE_*` 等）。**`AX_LOG` 等为编译期选项**，不能指望仅靠运行时 export 改变已编译内核日志级别。

预设 **verify syscall monitor smoke**：`scripts/verify-syscall-monitor-smoke.sh` 在注释中标明为**宿主侧伪造 SYSCALL_STATS 文本**，仅测解析链，不能与 QEMU 内真实访客 syscall 计数混为一谈。

可选 **`python3 scripts/tail-http-serve.py …`**：`PATH`/`PORT`/行数等在脚本内有说明；可把命令行改为你的日志路径。
