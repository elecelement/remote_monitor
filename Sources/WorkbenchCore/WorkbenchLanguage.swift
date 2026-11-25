import Foundation

public enum WorkbenchLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    public static let preferenceKey = "workbenchLanguage"

    public static var preferred: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .chinese
    }

    public func text(_ chinese: String, _ english: String) -> String {
        self == .english ? english : chinese
    }

    /// Stored errors and remote replies use the original Chinese messages.
    /// Translate only known messages and their fixed prefixes. Filenames,
    /// commands, usernames and diagnostic output are displayed verbatim.
    public func diagnostic(_ message: String) -> String {
        guard self == .english else { return message }
        if let translation = Self.messages[message] { return translation }
        for (prefix, english) in Self.diagnosticPrefixes where message.hasPrefix(prefix) {
            return english + message.dropFirst(prefix.count)
        }
        if let boundary = message.firstIndex(of: "；"),
           let reason = Self.condaReasons[String(message[..<boundary])] {
            let advice = message[message.index(after: boundary)...]
            for (prefix, english) in Self.activationInstructions where advice.hasPrefix(prefix) {
                return reason + " " + english + advice.dropFirst(prefix.count)
            }
        }
        return message
    }

    private static let messages = [
        // Server profiles and shortcut library
        "请填写有效的服务器资料、绝对路径，并先核对主机指纹。": "Enter valid server details and absolute paths, then verify the host fingerprint.",
        "主机、账号或指纹发生变化。请单独添加并核对新的服务器。": "The host, account, or fingerprint has changed. Add a separate server and verify its fingerprint.",
        "请填写快捷方式的显示名称和远程工作目录的绝对路径。": "Enter a display name and an absolute path for the remote working directory.",
        "会话名最长 64 个字符，可使用文字、数字、下划线和连字符，首字符不能为连字符。": "Use up to 64 letters, digits, underscores, or hyphens for the session name. Start with a letter, digit, or underscore.",
        "请输入 Conda 环境名称，首字符为文字、数字或下划线，名称中可包含点和连字符。": "Start the Conda environment name with a letter, digit, or underscore. It can also contain dots and hyphens.",
        "请先保存并核对目标服务器。": "Verify and save the destination server first.",
        "该服务器已有此会话名，请选择另一个名称。": "A shortcut on this server already uses this session name. Choose another name.",
        "请选择本地项目目录。": "Choose a local project folder.",
        "找不到用于同步的快捷方式。": "The shortcut for this sync could not be found.",
        "无法读取此版本的本地配置。": "This version of the local configuration is unsupported.",

        // SSH authentication, transport and GPU monitoring
        "无法获取服务器主机指纹。请检查地址、端口和 VPN，再重试。": "Could not retrieve the host fingerprint. Check the address, port, and VPN, then retry.",
        "无法查询显卡。": "Could not query the GPUs.",
        "GPU 监控连接已中断。": "The GPU monitoring connection was interrupted.",
        "服务器响应格式异常。请确认远端有系统 Python 3，并检查 SSH 登录脚本是否向标准输出写入了额外文字。": "The server returned an unexpected response. Check that system Python 3 is installed and that SSH login scripts keep standard output clear.",
        "远程操作未能完成。": "The remote operation could not be completed.",
        "主机密钥与已确认指纹不匹配，连接已阻止。请通过可信渠道核实服务器身份。": "The host key differs from the verified fingerprint. The connection was blocked. Verify the server identity through a trusted channel.",
        "公钥认证失败。请检查用户名和密钥文件；加密密钥可先用「解锁密钥」加入系统 SSH agent。": "Public-key authentication failed. Check the username and key file. For an encrypted key, use Unlock Key to add it to the system SSH agent.",
        "服务器连接中断或网络不可达。请检查主机、端口和 VPN。": "The connection was interrupted or the server is unreachable. Check the host, port, and VPN.",
        "服务器缺少 /usr/bin/python3，请联系管理员。": "The server is missing /usr/bin/python3. Contact its administrator.",
        "SSH 连接已中断。": "The SSH connection was interrupted.",
        "快捷方式与当前服务器不匹配。": "This shortcut belongs to another server.",
        "不支持的自动操作。": "This automated operation is unsupported.",
        "快捷方式内容超过大小限制。": "The shortcut exceeds the size limit.",
        "SSH 用户名只支持字母、数字、横线、下划线和点。": "Use letters, digits, hyphens, underscores, or dots for the SSH username.",
        "请先核对此主机和端口的服务器指纹。": "Verify the host fingerprint for this server and port first.",
        "本地应用数据路径包含 SSH 无法安全处理的字符。": "The local application data path contains characters SSH cannot safely handle.",
        "应用资源缺少远程启动程序。": "The remote launcher is missing from the app bundle.",
        "请选择绝对路径的本地密钥文件，路径不能包含 SSH 替换符或控制字符。": "Choose a local key file with an absolute path free of SSH substitution tokens and control characters.",
        "无法读取选中的密钥文件，请重新选择。": "The selected key file could not be read. Choose it again.",
        "请输入有效的主机名、IPv4 或 IPv6 地址和 SSH 端口。": "Enter a valid hostname, IPv4 or IPv6 address, and SSH port.",
        "操作超时，请检查网络和服务器状态。": "The operation timed out. Check the network and server status.",
        "服务器响应超过大小限制。": "The server response exceeds the size limit.",
        "GPU 监控长时间没有收到数据。": "The GPU monitor timed out waiting for a sample.",
        "GPU 数据帧超过大小限制。": "The GPU sample exceeds the size limit.",
        "无法创建本地终端。请关闭闲置的本地标签页后重试。": "Could not open a local terminal. Close an unused terminal tab and try again.",

        // File sync
        "预演后的变更清单已变化，请重新预演确认。尚未上传文件。": "The file list has changed since the preview. Preview it again before uploading.",
        "无法识别 rsync 的逐文件预演输出，已停止同步。": "The rsync file list could not be read. Sync stopped.",
        "预演包含无法确认的文件类型或操作，已停止同步。": "The preview contains an unknown file type or operation. Sync stopped.",
        "预演清单包含无法安全确认的路径，请检查本地文件后重新预演。": "The preview contains a path that could not be verified. Check the local files and preview again.",
        "请选择本地项目目录。GPU Workbench 源码目录和应用包不能作为同步来源。": "Choose a local project folder outside the GPU Workbench source tree and app bundle.",
        "同步目标须为该服务器快捷方式中的项目绝对路径，路径可使用英文字母、数字、点、下划线和连字符。": "Use the absolute project path from this server's shortcut. Path components can contain ASCII letters, digits, dots, underscores, and hyphens.",
        "上传前需要确认文件清单。": "Review and confirm the file list before uploading.",

        // Status and errors from the fixed remote launcher
        "未找到原会话。它可能已结束、改名或被同名会话替代。": "The original session could not be found. It may have ended, been renamed, or been replaced by a session of the same name.",
        "该名称已被会话使用。请选用其他名称，或核实后接回。": "A session already uses this name. Choose another name, or verify the session before attaching.",
        "发现同名会话，无法确认它由此快捷方式创建。": "A session with this name exists. Its identity does not match this shortcut.",
        "驱动返回了无法识别的 GPU 数据。": "The driver returned unrecognized GPU data.",
        "无法读取 NVIDIA 驱动数据。": "Could not read the NVIDIA driver data.",
        "会话标识无效。": "Invalid session identifier.",
        "会话名或环境名的字符无效。": "The session or environment name contains invalid characters.",
        "请使用远程绝对路径。": "Use an absolute path on the server.",
        "无法确认 tmux 会话标识。": "Could not verify the tmux session identifier.",
        "工作目录不存在或没有进入权限。": "The working directory is missing or inaccessible.",
        "无法确认新建会话的标识。": "Could not verify the new session's identifier.",
        "未能确认三个终端都进入了指定目录。会话已保留，请检查 tmux。": "Could not verify the working directory in all three panes. The session is still available for inspection in tmux.",
        "已找到已有会话，接回时保留当前布局、环境和任务。": "Found the existing session. Attaching preserves its layout, environment, and tasks.",
        "请求过长。": "The request exceeds the size limit.",
        "不支持此操作。": "This operation is unsupported."
    ]

    private static let diagnosticPrefixes = [
        "无法读取本地配置，已保留原文件。\n": "Could not read the local configuration. The original file is preserved.\n",
        "SSH 未完成连接。\n": "SSH could not connect.\n",
        "同步退出码 ": "Sync exit code ",
        "没有找到可执行的 ": "Could not find executable ",
        "已进入工作目录并激活 ": "Opened the working directory and activated ",
        "无法读取 tmux 会话列表。": "Could not read the tmux session list. ",
        "无法完成三窗格启动。现有会话将保留，请在终端检查。 ": "Could not finish opening all three panes. Inspect the existing session in the terminal. "
    ]

    private static let condaReasons = [
        "未能确认 Conda 安装位置": "Could not verify the Conda installation.",
        "未能确认目标环境": "Could not verify the target environment.",
        "环境包含额外激活脚本或变量": "The environment has extra activation scripts or variables.",
        "环境包含自定义状态": "The environment has custom activation state.",
        "激活结果无法安全确认": "Could not verify the activation result."
    ]

    private static let activationInstructions = [
        "可手动初始化 Conda 后运行 conda activate ": "Initialize Conda manually, then run conda activate ",
        "请在此终端手动运行 conda activate ": "In this terminal, run conda activate "
    ]
}
