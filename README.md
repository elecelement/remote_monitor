# Remote Monitor · GPU 工作台

通过 SSH 查看 Linux 服务器的 NVIDIA GPU 状态，并在 macOS 的内置终端中创建或接回 tmux 工作会话。

- **GPU 概览** · 每张卡分别显示利用率与显存占用。应用在前台通过一条 SSH 连接约每 5 秒采样，断线后保留最近一次读数及采样时间。
- **工作快捷方式** · 保存 tmux 会话名、Conda 环境和工作目录，支持一次打开多个快捷方式。新会话默认是上二下一的三个窗格。
- **终端标签** · 可在 GPU 概览和终端之间切换，按 `⌘1` 返回概览。退出应用会断开本地 SSH 连接，远端 tmux 会话与运行中的任务可以继续运行。

## 构建

Mac 需要 macOS 14 或以上、命令行开发工具，以及 Swift 6.1 或兼容工具链。首次构建会下载 `Package.resolved` 锁定的依赖。

```sh
bash Packaging/build-app.sh
open "dist/GPU 工作台.app"
```

构建脚本生成适用于当前 Mac 架构的应用，并完成本地签名。项目通过 Swift Package Manager 使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 实现终端界面。

## 连接服务器

远端需要支持 SSH 公钥登录，并提供 `/usr/bin/python3`（3.8 或以上）、Bash 和 tmux 3.2 或以上。自动初始化环境需要 Conda，GPU 概览需要可用的 `nvidia-smi`。如果服务器依赖 VPN，先在 Mac 上接入对应网络。

1. 在「添加服务器」中填写主机与用户名，选择 Mac 上的 SSH 私钥文件。普通 SSH 保持默认端口即可。
2. 获取主机指纹，从管理员或已有可信记录核对 SHA-256 指纹后保存。带口令的私钥可以通过「解锁密钥」交给系统 SSH 代理。
3. 在「快捷方式」中新建一项，填写会话名、Conda 环境名和服务器上已存在的工作目录。例如 `research`、`ml` 和 `/work/example-project`。
4. 点击「打开」。应用会在三个新窗格中进入指定目录并准备 Conda 环境。每个窗格都会停在终端提示符，供你继续操作。

Conda 默认从常见安装位置查找，也可在「连接设置」填写安装根目录或 `bin/conda` 的绝对路径。如果遇到附加激活脚本、无法核对环境或自定义激活配置，应用会提示手动激活。

## 共享服务器与本机配置

- 使用系统 OpenSSH，并固定经用户确认的主机指纹。指纹变化时停止连接。服务器资料、快捷方式和可信指纹保存在 Mac 的 `~/Library/Application Support/GPUWorkbench/`，私钥保留在原位置。
- 启动逻辑随 SSH 请求执行。服务器保留正常的 SSH 日志和 tmux 运行状态，包括默认 socket 与会话本身。应用无需在远端安装代理或写入启动脚本。
- 创建新会话时，工作目录与 Conda 变量只应用到各窗格新建的 Bash 进程。接回已有会话时保留当前布局与任务。对于手动创建的同名会话，确认它属于自己后，再打开快捷方式里的「接回我已有的同名 tmux 会话」。
- 自动操作限于 GPU 查询、会话检查、创建与接回。内置终端中的手动命令使用当前 Linux 账号的权限。服务器自己的登录和审计机制照常运行。

## 运行测试

```sh
swift test --disable-xctest
python3 -B -m unittest discover -s Tests/Remote -v
```

Python 测试默认从 `PATH` 查找 tmux，也可用 `GWB_TEST_TMUX` 指定绝对路径。设置 `GWB_TEST_CONDA` 后可运行实际 Conda 的激活测试。测试使用临时会话和通用夹具。
