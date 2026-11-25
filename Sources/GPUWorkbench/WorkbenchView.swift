import AppKit
import SwiftUI
import WorkbenchCore

private enum EditorSheet: Identifiable {
    case server(ServerProfile?)
    case shortcut(ServerProfile, Shortcut?)
    case sync(ServerProfile, Shortcut)
    var id: String {
        switch self {
        case let .server(profile): return "server-" + (profile?.id.uuidString ?? "new")
        case let .shortcut(server, shortcut): return server.id.uuidString + (shortcut?.id.uuidString ?? "new")
        case let .sync(_, shortcut): return "sync-" + shortcut.id.uuidString
        }
    }
}

enum MonitorNotice {
    case retry(String, Int)
    case paused(String?)
    case reconnecting

    func text(in language: WorkbenchLanguage) -> String {
        switch self {
        case let .retry(detail, seconds):
            return language.diagnostic(detail) + "\n" + language.text(
                "\(seconds) 秒后自动重试。", "Retrying in \(seconds) seconds.")
        case let .paused(detail):
            let reason = detail.map(language.diagnostic) ?? language.text("监控连接已结束。", "The monitoring connection ended.")
            return reason + "\n" + language.text(
                "监控已暂停，点击刷新或修正设置后重试。", "Monitoring paused. Refresh or update the connection settings to retry.")
        case .reconnecting:
            return language.text("正在重新连接…", "Reconnecting…")
        }
    }
}

struct GPUSnapshot {
    var readings: [GPUReading] = []
    var sampledAt: Date?
    var error: MonitorNotice?
    var online = false
    var monitoringPaused = false
    var retryAfter: ContinuousClock.Instant?
    var nextRetryDelay = 5
}

private struct PollKey: Equatable {
    let profile: ServerProfile?
    let active: Bool
    let revision: Int
}

private enum SessionAction {
    case open
    case create
    case reconnect(String)
    case confirmExisting(String)

    func prepare(_ profile: ServerProfile, _ item: Shortcut) async throws -> LaunchResult {
        switch self {
        case .open: return try await SSHTransport.ensure(profile, item)
        case .create: return try await SSHTransport.create(profile, item)
        case let .reconnect(token): return try await SSHTransport.reconnect(profile, item, sessionToken: token)
        case let .confirmExisting(token): return try await SSHTransport.confirmExisting(profile, item, sessionToken: token)
        }
    }
}

private enum SessionFeedback {
    case missing
    case collision(String)
    case failure(String)
}

struct WorkbenchView: View {
    @ObservedObject var store: WorkbenchStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.workbenchLanguage) private var language
    @AppStorage(WorkbenchLanguage.preferenceKey) private var preferredLanguage = WorkbenchLanguage.chinese
    @AppStorage("lastSelectedServer") private var lastSelected = ""
    @State private var sheet: EditorSheet?
    @State private var tabs: [TerminalTab] = []
    @State private var activeTab: UUID?
    @State private var checked: Set<UUID> = []
    @State private var pending: Set<UUID> = []
    @State private var feedback: [UUID: SessionFeedback] = [:]
    @State private var snapshots: [UUID: GPUSnapshot] = [:]
    @State private var pollRevisions: [UUID: Int] = [:]
    @State private var message: String?

    private var server: ServerProfile? {
        store.servers.first { $0.id.uuidString == lastSelected } ?? store.servers.first
    }
    private var shortcuts: [Shortcut] { store.shortcuts.filter { $0.serverID == server?.id } }
    private var selectedTab: TerminalTab? { tabs.first { $0.id == activeTab && $0.serverID == server?.id } }
    private var pollKey: PollKey {
        PollKey(profile: server, active: scenePhase == .active,
                revision: server.flatMap { pollRevisions[$0.id] } ?? 0)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                if let server {
                    tabStrip(for: server)
                        .zIndex(1)
                    if let tab = selectedTab {
                        TerminalPane(tab: tab) {
                            if let shortcut = shortcuts.first(where: { $0.id == tab.id }) {
                                sessionControls(shortcut, on: server, endedTab: tab)
                            }
                        }.id(ObjectIdentifier(tab))
                    } else {
                        dashboard(server)
                    }
                } else {
                    welcome
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $sheet) { item in
            switch item {
            case let .server(existing):
                ServerEditor(existing: existing, condaLocked: existing.map { item in
                    tabs.contains { $0.serverID == item.id && !$0.isUnlock } ||
                        store.shortcuts.contains { $0.serverID == item.id && pending.contains($0.id) }
                } ?? false) { saved in
                    try store.save(saved)
                    select(saved)
                    resumeMonitoring(saved.id)
                }
            case let .shortcut(profile, existing):
                ShortcutEditor(profile: profile, existing: existing) { saved in
                    try store.save(saved)
                    if let tab = tabs.first(where: { $0.id == saved.id && $0.ended }), saved.name != existing?.name {
                        close(tab)
                    }
                    feedback[saved.id] = nil
                }
            case let .sync(profile, shortcut):
                SyncSheet(profile: profile, shortcut: shortcut, store: store)
            }
        }
        .task(id: pollKey) { [key = pollKey] in
            guard key.active, let profile = key.profile, profile.pin != nil else { return }
            await monitor(profile, revision: key.revision)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            tabs.forEach { $0.disconnect() }
        }
        .alert(language.text("操作未完成", "Action Couldn’t Be Completed"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(language.text("好", "OK")) { message = nil }
        } message: { Text(verbatim: language.diagnostic(message ?? "")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 30, height: 30).accessibilityHidden(true)
                Text(verbatim: GPUWorkbenchApp.displayName).font(.headline.weight(.bold)).foregroundStyle(.white)
            }.padding(.top, 26).padding(.horizontal, 19)
            HStack {
                Text(language.text("服务器", "Servers")).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.63))
                Spacer()
                Button { sheet = .server(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(WorkbenchStyle.mint).help(language.text("添加服务器", "Add Server")).accessibilityLabel(language.text("添加服务器", "Add Server"))
            }.padding(.horizontal, 19).padding(.top, 40).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.servers) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "server.rack")
                                Text(item.label).lineLimit(1)
                                Spacer(minLength: 1)
                                if let snap = snapshots[item.id] {
                                    Circle().fill(snap.online ? WorkbenchStyle.mint : .gray)
                                        .frame(width: 6, height: 6)
                                }
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .foregroundStyle(server?.id == item.id ? .white : .white.opacity(0.72))
                            .background(.white.opacity(server?.id == item.id ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 7))
                    }
                }.padding(.horizontal, 9)
            }
            VStack(alignment: .leading, spacing: 16) {
                if let server {
                    Button { unlock(server) } label: { Label(language.text("解锁密钥", "Unlock Key"), systemImage: "key") }
                    Button { sheet = .server(server) } label: { Label(language.text("连接设置", "Connection Settings"), systemImage: "slider.horizontal.3") }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(language.text("语言 / Language", "Language / 语言"), systemImage: "globe")
                        .font(.caption.weight(.medium))
                    Picker(language.text("语言 / Language", "Language / 语言"), selection: $preferredLanguage) {
                        Text(verbatim: "简体中文").tag(WorkbenchLanguage.chinese)
                        Text(verbatim: "English").tag(WorkbenchLanguage.english)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                }
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).padding(19)
        }.frame(width: 193).frame(maxHeight: .infinity)
            .background(WorkbenchStyle.rail)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "ellipsis").font(.body)
                Image(systemName: "server.rack")
            }.font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
            Text(language.text("连接你的第一台服务器", "Connect your first server")).font(.largeTitle.weight(.semibold))
            Text(language.text("通过 SSH 密钥查看显卡占用，在独立标签页打开常用的 tmux 工作环境。", "Connect with an SSH key to view GPU usage and open your tmux workspaces in separate tabs."))
                .foregroundStyle(.secondary).font(.body)
            Button { sheet = .server(nil) } label: { Label(language.text("添加服务器", "Add Server"), systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let error = store.storageError { Notice(text: language.diagnostic(error)) }
        }
        .padding(42).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func tabStrip(for profile: ServerProfile) -> some View {
        HStack(spacing: 7) {
            Button { activeTab = nil } label: {
                Label(selectedTab == nil ? language.text("概览", "Overview") : language.text("返回概览", "Back to Overview"),
                      systemImage: selectedTab == nil ? "square.grid.2x2" : "chevron.left")
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .background(selectedTab == nil ? Color.teal.opacity(0.16) : .clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("1", modifiers: .command)
            .help(language.text("返回 GPU 概览（⌘1）", "Back to GPU overview (⌘1)"))

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(tabs.filter { $0.serverID == profile.id }) { tab in
                        HStack(spacing: 0) {
                            Button { activate(tab) } label: {
                                Label(tab.title(in: language), systemImage: tab.isUnlock ? "key" : "terminal")
                                    .padding(.leading, 9).padding(.trailing, 5)
                                    .frame(minHeight: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { close(tab) } label: {
                                Image(systemName: "xmark").font(.caption2)
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help(tab.isUnlock ? language.text("关闭本地密钥解锁标签", "Close the local key unlock tab") : language.text("断开本机连接，远端 tmux 任务继续运行", "Disconnect locally. Remote tmux jobs keep running."))
                                .accessibilityLabel(language.text("关闭 \(tab.title(in: language))", "Close \(tab.title(in: language))"))
                        }
                        .background(activeTab == tab.id ? Color.teal.opacity(0.16) : WorkbenchStyle.panel, in: Capsule())
                    }
                }
            }.scrollIndicators(.hidden)
        }
        .padding(.horizontal, 18).padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
    }

    private func dashboard(_ profile: ServerProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.label).font(.largeTitle.weight(.semibold))
                        Text(verbatim: "\(profile.username)@\(profile.host)" + (profile.port == 22 ? "" : " · \(profile.port)"))
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { resumeMonitoring(profile.id) } label: { Label(language.text("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                }
                GPUSection(snapshot: snapshots[profile.id])
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label(language.text("快捷方式", "Shortcuts"), systemImage: "terminal").font(.title3.weight(.semibold))
                        Spacer()
                        if !checked.isEmpty {
                            Button(language.text("打开所选（\(checked.count)）", "Open Selected (\(checked.count))")) { openSelected(on: profile) }.buttonStyle(.borderedProminent)
                        }
                        Button { sheet = .shortcut(profile, nil) } label: { Label(language.text("新建", "New"), systemImage: "plus") }
                    }
                    if shortcuts.isEmpty {
                        Button { sheet = .shortcut(profile, nil) } label: {
                            Label(language.text("保存第一个 tmux 工作环境", "Save your first tmux workspace"), systemImage: "plus.circle")
                                .frame(maxWidth: .infinity).padding(22)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(shortcuts) { shortcut in shortcutRow(shortcut, profile: profile) }
                    }
                }
                if let error = store.storageError { Notice(text: language.diagnostic(error)) }
            }.padding(26).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func shortcutRow(_ item: Shortcut, profile: ServerProfile) -> some View {
        let isPending = pending.contains(item.id)
        let tab = tabs.first { $0.id == item.id }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Toggle(language.text("选择 \(item.title)", "Select \(item.title)"), isOn: Binding(get: { checked.contains(item.id) }, set: { selected in
                    if selected { checked.insert(item.id) } else { checked.remove(item.id) }
                })).toggleStyle(.checkbox).labelsHidden()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.title).font(.headline)
                        if item.title != item.name { Text(item.name).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                    HStack(spacing: 10) {
                        Label(item.environment, systemImage: "shippingbox")
                        Label(item.directory, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                if isPending { ProgressView().controlSize(.small).help(language.text("正在准备会话", "Preparing session")) }
                Button(tab == nil ? language.text("打开工作环境", "Open Workspace") : language.text("查看标签", "Show Tab")) { open(item, on: profile, focus: true) }.disabled(isPending)
                Button(language.text("同步代码", "Sync Code")) { sheet = .sync(profile, item) }
                Menu {
                    Button(language.text("编辑快捷方式", "Edit Shortcut")) { sheet = .shortcut(profile, item) }.disabled(tab != nil || isPending)
                    Button(language.text("移除本地快捷方式", "Remove Local Shortcut")) {
                        do { try store.removeShortcut(item.id); checked.remove(item.id); feedback[item.id] = nil }
                        catch { message = error.localizedDescription }
                    }.disabled(isPending || tab != nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(language.text("快捷方式选项", "Shortcut options"))
            }
            if tab == nil, feedback[item.id] != nil { sessionControls(item, on: profile, endedTab: nil) }
        }.padding(13).background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private func sessionControls(_ item: Shortcut, on profile: ServerProfile, endedTab: TerminalTab?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch feedback[item.id] {
            case .missing:
                Notice(text: language.text("未找到原会话。它可能已结束、改名或被同名会话替代。", "The original session could not be found. It may have ended, been renamed, or been replaced."), symbol: "terminal")
                Button(language.text("新建同名会话", "Create a New Session with This Name")) { start(.create, item, on: profile, replacing: endedTab) }
            case let .collision(token):
                Notice(text: language.text("服务器上已有名为「\(item.name)」的会话。请核实它属于你，再决定是否接回。", "The server already has a session named “\(item.name)”. Verify that it belongs to you before attaching."))
                HStack {
                    Button(language.text("换个会话名", "Choose Another Name")) { sheet = .shortcut(profile, item) }.buttonStyle(.borderedProminent)
                    Button(language.text("我已核实，接回这一次", "I’ve Verified It · Attach Once")) {
                        start(.confirmExisting(token), item, on: profile, replacing: endedTab)
                    }
                }
            default:
                if case let .failure(text) = feedback[item.id] { Notice(text: language.diagnostic(text)) }
                if let token = endedTab?.sessionToken {
                    if feedback[item.id] == nil {
                        Notice(text: language.text("终端连接已断开。可以尝试接回原会话。", "The terminal disconnected. You can reconnect to the original session."), symbol: "cable.connector.slash")
                    }
                    Button(language.text("重新连接", "Reconnect")) { start(.reconnect(token), item, on: profile, replacing: endedTab) }
                }
            }
            if endedTab != nil && pending.contains(item.id) {
                ProgressView(language.text("正在连接…", "Connecting…")).controlSize(.small)
            }
        }.disabled(pending.contains(item.id))
    }

    private func select(_ server: ServerProfile) {
        lastSelected = server.id.uuidString
        activeTab = nil
        checked.removeAll()
    }

    @MainActor private func monitor(_ profile: ServerProfile, revision: Int) async {
        let id = profile.id
        let clock = ContinuousClock()
        func isCurrent() -> Bool { !Task.isCancelled && pollRevisions[id, default: 0] == revision }
        while isCurrent() {
            guard snapshots[id]?.monitoringPaused != true else { return }
            if let deadline = snapshots[id]?.retryAfter {
                do { try await clock.sleep(until: deadline) } catch { return }
            }
            guard isCurrent() else { return }
            do {
                for try await readings in SSHTransport.gpuFrames(profile) {
                    // Let the iterator observe task cancellation and close its SSH process.
                    guard isCurrent() else { continue }
                    snapshots[id] = GPUSnapshot(readings: readings, sampledAt: Date(), online: true)
                }
                guard isCurrent() else { return }
                monitoringFailed(id, detail: nil, reachedServer: false, retry: false)
                return
            } catch {
                guard isCurrent() else { return }
                let transport = error as? TransportError
                let retry = transport?.canRetryMonitoring == true
                monitoringFailed(id, detail: error.localizedDescription, reachedServer: transport?.reachedServer == true,
                                 retry: retry)
                if !retry { return }
            }
        }
    }

    private func monitoringFailed(_ id: UUID, detail: String?, reachedServer: Bool, retry: Bool) {
        var snapshot = snapshots[id] ?? GPUSnapshot()
        snapshot.online = reachedServer
        if retry, let detail {
            let delay = snapshot.nextRetryDelay
            snapshot.retryAfter = ContinuousClock.now.advanced(by: .seconds(delay))
            snapshot.nextRetryDelay = min(delay * 2, 60)
            snapshot.error = .retry(detail, delay)
        } else {
            snapshot.monitoringPaused = true
            snapshot.retryAfter = nil
            snapshot.error = .paused(detail)
        }
        snapshots[id] = snapshot
    }

    private func resumeMonitoring(_ id: UUID) {
        if var snapshot = snapshots[id] {
            snapshot.monitoringPaused = false
            snapshot.nextRetryDelay = 5
            snapshot.retryAfter = nil
            if snapshot.error != nil { snapshot.error = .reconnecting }
            snapshots[id] = snapshot
        }
        pollRevisions[id, default: 0] += 1
    }

    private func openSelected(on profile: ServerProfile) {
        let items = shortcuts.filter { checked.contains($0.id) }
        if items.count == 1, let item = items.first {
            open(item, on: profile, focus: true)
            return
        }
        let queue = items.filter { item in
            !tabs.contains(where: { $0.id == item.id }) && !pending.contains(item.id)
        }
        for item in queue { pending.insert(item.id); feedback[item.id] = nil }
        Task { @MainActor in
            for item in queue { await prepare(.open, item, on: profile, focus: false, replacing: nil) }
        }
    }

    private func open(_ item: Shortcut, on profile: ServerProfile, focus: Bool) {
        if let tab = tabs.first(where: { $0.id == item.id }) {
            if focus { activate(tab) }
            return
        }
        start(.open, item, on: profile, focus: focus)
    }

    private func start(_ action: SessionAction, _ item: Shortcut, on profile: ServerProfile,
                       focus: Bool = true, replacing endedTab: TerminalTab? = nil) {
        guard pending.insert(item.id).inserted else { return }
        Task { @MainActor in await prepare(action, item, on: profile, focus: focus, replacing: endedTab) }
    }

    @MainActor private func prepare(_ action: SessionAction, _ item: Shortcut, on profile: ServerProfile,
                                    focus: Bool, replacing endedTab: TerminalTab?) async {
        defer { pending.remove(item.id) }
        func stillOpen() -> Bool { endedTab == nil || tabs.contains { $0 === endedTab } }
        do {
            let result = try await action.prepare(profile, item)
            guard stillOpen() else { return }
            let tab = try TerminalTab(id: item.id, profile: profile, shortcut: item, result: result)
            feedback[item.id] = nil
            if let old = endedTab, let index = tabs.firstIndex(where: { $0 === old }) {
                tabs[index] = tab
            } else {
                tabs.append(tab)
                if focus && server?.id == profile.id { activate(tab) }
            }
        } catch {
            guard stillOpen() else { return }
            switch error {
            case SessionIssue.missing: feedback[item.id] = .missing
            case let SessionIssue.collision(token): feedback[item.id] = .collision(token)
            default: feedback[item.id] = .failure(error.localizedDescription)
            }
        }
    }

    private func unlock(_ profile: ServerProfile) {
        if let existing = tabs.first(where: { $0.serverID == profile.id && $0.isUnlock }) {
            if !existing.ended { activate(existing); return }
            close(existing)
        }
        do {
            let tab = try TerminalTab(id: UUID(), profile: profile, shortcut: nil, result: nil)
            tab.onExit = { [weak tab] in
                if tab?.exitCode == 0 { resumeMonitoring(profile.id) }
            }
            tabs.append(tab)
            activate(tab)
        } catch { message = error.localizedDescription }
    }

    private func activate(_ tab: TerminalTab) {
        // Newly visible terminals request focus when AppKit mounts them.
        if activeTab == tab.id { tab.terminal.focusKeyboard() }
        activeTab = tab.id
    }

    private func close(_ tab: TerminalTab) {
        tab.disconnect()
        tabs.removeAll { $0.id == tab.id }
        feedback[tab.id] = nil
        if activeTab == tab.id { activeTab = nil }
    }
}
