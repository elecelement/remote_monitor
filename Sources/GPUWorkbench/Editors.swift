import AppKit
import SwiftUI
import WorkbenchCore

struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workbenchLanguage) private var language
    let existing: ServerProfile?
    let condaLocked: Bool
    let save: (ServerProfile) throws -> Void
    @State private var label: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var keyPath: String
    @State private var conda: String
    @State private var showConnectionOptions: Bool
    @State private var candidate: HostPin?
    @State private var scanning = false
    @State private var error: String?
    @State private var id: UUID

    init(existing: ServerProfile?, condaLocked: Bool, save: @escaping (ServerProfile) throws -> Void) {
        self.existing = existing
        self.condaLocked = condaLocked
        self.save = save
        _id = State(initialValue: existing?.id ?? UUID())
        _label = State(initialValue: existing?.label ?? "")
        _host = State(initialValue: existing?.host ?? "")
        let customPort = existing.flatMap { $0.port == 22 ? nil : $0.port }
        _port = State(initialValue: customPort.map { String($0) } ?? "")
        _username = State(initialValue: existing?.username ?? "")
        _keyPath = State(initialValue: existing?.keyPath ?? "")
        _conda = State(initialValue: existing?.conda ?? "")
        _showConnectionOptions = State(initialValue: customPort != nil || !(existing?.conda ?? "").isEmpty)
    }

    private var effectivePort: Int? {
        port.trimmed.isEmpty ? 22 : Int(port.trimmed)
    }

    private func profile(pin: HostPin?) -> ServerProfile {
        ServerProfile(id: id, label: label.trimmed, host: host.trimmed, port: effectivePort ?? 0,
                      username: username.trimmed, keyPath: keyPath, conda: conda.trimmed, pin: pin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.teal)
                Text(existing == nil ? language.text("添加服务器", "Add Server") : language.text("连接设置", "Connection Settings")).font(.title2.weight(.semibold))
                Spacer()
            }.padding(22)
            Divider()
            Form {
                Section(language.text("SSH 连接", "SSH Connection")) {
                    TextField(language.text("显示名称", "Display name"), text: $label, prompt: Text(language.text("实验室服务器", "Lab server")))
                    TextField(language.text("主机地址", "Host"), text: $host, prompt: Text(language.text("主机名或 IP 地址", "Hostname or IP address"))).disabled(existing?.pin != nil)
                    TextField(language.text("用户名", "Username"), text: $username).disabled(existing?.pin != nil)
                    LabeledContent(language.text("本地私钥", "Private key")) {
                        HStack {
                            TextField(language.text("私钥文件路径", "Private key path"), text: $keyPath).labelsHidden()
                            Button(language.text("选择文件…", "Choose File…"), action: chooseKey)
                        }
                    }
                }.disabled(scanning || candidate != nil)
                Section {
                    DisclosureGroup(language.text("更多连接选项", "More connection options"), isExpanded: $showConnectionOptions) {
                        TextField(language.text("SSH 端口", "SSH port"), text: $port, prompt: Text(language.text("默认端口", "Default port")))
                            .disabled(existing?.pin != nil)
                        TextField(language.text("Conda 安装位置", "Conda location"), text: $conda, prompt: Text(language.text("自动查找，或填写绝对路径", "Auto-detect, or enter an absolute path")))
                            .disabled(condaLocked)
                        if condaLocked {
                            Text(language.text("此服务器的终端正在使用当前设置。关闭标签后可修改 Conda 位置。", "Close this server’s terminal tabs to change its Conda location."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.disabled(scanning || candidate != nil)
                if let pin = candidate ?? existing?.pin {
                    Section(candidate == nil ? language.text("已固定的主机指纹", "Pinned host fingerprint") : language.text("核对服务器指纹", "Verify host fingerprint")) {
                        Text(verbatim: pin.fingerprint).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if candidate != nil {
                            Text(language.text("请从管理员或已有的可信记录核对 SHA-256 指纹。确认相同后再保存连接。", "Compare this SHA-256 fingerprint with your administrator or a trusted record before saving."))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Notice(text: language.diagnostic(error)) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button(language.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                if candidate != nil { Button(language.text("返回修改", "Back to Edit")) { candidate = nil; error = nil } }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                if candidate != nil || existing?.pin != nil {
                    Button(candidate == nil ? language.text("保存", "Save") : language.text("指纹一致，保存连接", "Fingerprint Matches · Save")) { commit() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(language.text("获取主机指纹", "Get Host Fingerprint")) { scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scanning || label.trimmed.isEmpty || host.trimmed.isEmpty || username.trimmed.isEmpty || keyPath.isEmpty || !(1...65535).contains(effectivePort ?? 0))
                }
            }.padding(18)
        }.frame(width: 535, height: 525)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = language.text("选择 SSH 私钥", "Choose an SSH Private Key")
        panel.prompt = language.text("选择", "Choose")
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }

    private func scan() {
        error = nil
        scanning = true
        let draft = profile(pin: nil)
        Task { @MainActor in
            defer { scanning = false }
            do { candidate = try await SSHTransport.scanPin(draft) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func commit() {
        do {
            try save(profile(pin: candidate ?? existing?.pin))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ShortcutEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workbenchLanguage) private var language
    let profile: ServerProfile
    let existing: Shortcut?
    let save: (Shortcut) throws -> Void
    @State private var customTitle = ""
    @State private var name = ""
    @State private var environment = ""
    @State private var directory = ""
    @State private var showTitle: Bool
    @State private var error: String?

    init(profile: ServerProfile, existing: Shortcut?, save: @escaping (Shortcut) throws -> Void) {
        self.profile = profile
        self.existing = existing
        self.save = save
        let customTitle = existing.flatMap { $0.title == $0.name ? nil : $0.title } ?? ""
        _customTitle = State(initialValue: customTitle)
        _showTitle = State(initialValue: !customTitle.isEmpty)
        _name = State(initialValue: existing?.name ?? "")
        _environment = State(initialValue: existing?.environment ?? "")
        _directory = State(initialValue: existing?.directory ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(existing == nil ? language.text("新建快捷方式", "New Shortcut") : language.text("编辑快捷方式", "Edit Shortcut"), systemImage: "terminal")
                .font(.title2.weight(.semibold)).padding(22)
            Divider()
            Form {
                Section(profile.label) {
                    TextField(language.text("tmux 会话名", "tmux session name"), text: $name, prompt: Text("train-01"))
                    TextField(language.text("Conda 环境", "Conda environment"), text: $environment, prompt: Text("pytorch"))
                    TextField(language.text("远程工作目录", "Remote working directory"), text: $directory, prompt: Text("/work/my-project"))
                }
                Section {
                    HStack(spacing: 14) {
                        VStack(spacing: 3) {
                            HStack(spacing: 3) {
                                pane
                                pane
                            }
                            pane
                        }
                        .frame(width: 68, height: 46)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(language.text("新会话 · 上二下一", "New session · two above, one below")).font(.headline)
                            Text(language.text("三个窗格都会进入所填目录并准备所选环境。接回时沿用已有窗格和任务。", "All three panes start in this directory and prepare the selected environment. Reconnecting keeps existing panes and jobs."))
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section {
                    DisclosureGroup(language.text("自定义显示名称", "Customize display name"), isExpanded: $showTitle) {
                        TextField(language.text("显示名称", "Display name"), text: $customTitle,
                                  prompt: Text(name.trimmed.isEmpty ? language.text("默认使用会话名", "Uses session name") : name.trimmed))
                    }
                }
                if let error { Notice(text: language.diagnostic(error)) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button(language.text("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(language.text("保存快捷方式", "Save Shortcut")) {
                    do {
                        let title = customTitle.trimmed.isEmpty ? name.trimmed : customTitle.trimmed
                        try save(Shortcut(id: existing?.id ?? UUID(), serverID: profile.id, title: title, name: name.trimmed,
                                          environment: environment.trimmed, directory: directory))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled([name, environment, directory].contains { $0.trimmed.isEmpty })
            }.padding(18)
        }.frame(width: 530, height: 470)
    }

    private var pane: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.teal.opacity(0.15))
            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.teal.opacity(0.65)) }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
