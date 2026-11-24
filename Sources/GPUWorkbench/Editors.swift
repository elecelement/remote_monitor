import AppKit
import SwiftUI
import WorkbenchCore

struct ServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: ServerProfile?
    let condaLocked: Bool
    let save: (ServerProfile) throws -> Void
    @State private var label: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var keyPath: String
    @State private var conda: String
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
        _port = State(initialValue: String(existing?.port ?? 22))
        _username = State(initialValue: existing?.username ?? "")
        _keyPath = State(initialValue: existing?.keyPath ?? "")
        _conda = State(initialValue: existing?.conda ?? "")
    }

    private func profile(pin: HostPin?) -> ServerProfile {
        ServerProfile(id: id, label: label.trimmed, host: host.trimmed, port: Int(port) ?? 0,
                      username: username.trimmed, keyPath: keyPath, conda: conda.trimmed, pin: pin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.title2).foregroundStyle(.teal)
                Text(existing == nil ? "添加服务器" : "连接设置").font(.title2.weight(.semibold))
                Spacer()
            }.padding(22)
            Divider()
            Form {
                Section("SSH 连接") {
                    TextField("显示名称", text: $label, prompt: Text("实验室服务器"))
                    TextField("主机地址", text: $host, prompt: Text("主机名或 IP 地址")).disabled(existing?.pin != nil)
                    TextField("SSH 端口", text: $port).disabled(existing?.pin != nil)
                    TextField("用户名", text: $username).disabled(existing?.pin != nil)
                    LabeledContent("本地私钥") {
                        HStack {
                            TextField("私钥文件路径", text: $keyPath).labelsHidden()
                            Button("选择文件…", action: chooseKey)
                        }
                    }
                }.disabled(scanning || candidate != nil)
                Section("Conda") {
                    TextField("安装位置", text: $conda, prompt: Text("自动查找，或填写绝对路径"))
                        .disabled(condaLocked)
                    if condaLocked {
                        Text("此服务器的终端正在使用当前设置。关闭标签后可修改 Conda 位置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(scanning || candidate != nil)
                if let pin = candidate ?? existing?.pin {
                    Section(candidate == nil ? "已固定的主机指纹" : "核对服务器指纹") {
                        Text(verbatim: pin.fingerprint).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if candidate != nil {
                            Text("请从管理员或已有的可信记录核对 SHA-256 指纹。确认相同后再保存连接。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error { Notice(text: error) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                if candidate != nil { Button("返回修改") { candidate = nil; error = nil } }
                Spacer()
                if scanning { ProgressView().controlSize(.small) }
                if candidate != nil || existing?.pin != nil {
                    Button(candidate == nil ? "保存" : "指纹一致，保存连接") { commit() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("获取主机指纹") { scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scanning || label.trimmed.isEmpty || host.trimmed.isEmpty || username.trimmed.isEmpty || keyPath.isEmpty || !(1...65535).contains(Int(port) ?? 0))
                }
            }.padding(18)
        }.frame(width: 535, height: 525)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "选择 SSH 私钥"
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
    let profile: ServerProfile
    let existing: Shortcut?
    let save: (Shortcut) throws -> Void
    @State private var title = ""
    @State private var name = ""
    @State private var environment = ""
    @State private var directory = ""
    @State private var allowExisting = false
    @State private var error: String?

    init(profile: ServerProfile, existing: Shortcut?, save: @escaping (Shortcut) throws -> Void) {
        self.profile = profile
        self.existing = existing
        self.save = save
        _title = State(initialValue: existing?.title ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _environment = State(initialValue: existing?.environment ?? "")
        _directory = State(initialValue: existing?.directory ?? "")
        _allowExisting = State(initialValue: existing?.allowExisting == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(existing == nil ? "新建快捷方式" : "编辑快捷方式", systemImage: "terminal")
                .font(.title2.weight(.semibold)).padding(22)
            Divider()
            Form {
                Section(profile.label) {
                    TextField("显示名称", text: $title, prompt: Text("模型训练"))
                    TextField("tmux 会话名", text: $name, prompt: Text("train-01"))
                    TextField("Conda 环境", text: $environment, prompt: Text("pytorch"))
                    TextField("远程工作目录", text: $directory, prompt: Text("/work/my-project"))
                    Toggle("接回我已有的同名 tmux 会话", isOn: $allowExisting)
                    Text("新建会话时使用上二下一的布局。接回已有会话时，保留现有窗格和任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Notice(text: error) }
            }.formStyle(.grouped).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存快捷方式") {
                    do {
                        try save(Shortcut(id: existing?.id ?? UUID(), serverID: profile.id, title: title.trimmed, name: name.trimmed,
                                          environment: environment.trimmed, directory: directory,
                                          allowExisting: allowExisting))
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled([title, name, environment, directory].contains { $0.trimmed.isEmpty })
            }.padding(18)
        }.frame(width: 510, height: 400)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
