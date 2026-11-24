import AppKit
import SwiftUI
import WorkbenchCore

private enum EditorSheet: Identifiable {
    case server(ServerProfile?)
    case shortcut(ServerProfile, Shortcut?)
    var id: String {
        switch self {
        case let .server(profile): return "server-" + (profile?.id.uuidString ?? "new")
        case let .shortcut(server, shortcut): return server.id.uuidString + (shortcut?.id.uuidString ?? "new")
        }
    }
}

struct GPUSnapshot {
    var readings: [GPUReading] = []
    var sampledAt: Date?
    var error: String?
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

struct WorkbenchView: View {
    @ObservedObject var store: WorkbenchStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lastSelectedServer") private var lastSelected = ""
    @State private var sheet: EditorSheet?
    @State private var tabs: [TerminalTab] = []
    @State private var activeTab: UUID?
    @State private var checked: Set<UUID> = []
    @State private var pending: Set<UUID> = []
    @State private var failures: [UUID: String] = [:]
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
                                close(tab)
                                open(shortcut, on: server, focus: true)
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
                    failures[saved.id] = nil
                }
            }
        }
        .task(id: pollKey) { [key = pollKey] in
            guard key.active, let profile = key.profile, profile.pin != nil else { return }
            await monitor(profile, revision: key.revision)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            tabs.forEach { $0.disconnect() }
        }
        .alert("操作未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(verbatim: message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(WorkbenchStyle.mint)
                Text("GPU 工作台").font(.headline.weight(.bold)).foregroundStyle(.white)
            }.padding(.top, 26).padding(.horizontal, 19)
            HStack {
                Text("服务器").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.63))
                Spacer()
                Button { sheet = .server(nil) } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(WorkbenchStyle.mint).help("添加服务器").accessibilityLabel("添加服务器")
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
            if let server {
                VStack(alignment: .leading, spacing: 16) {
                    Button { unlock(server) } label: { Label("解锁密钥", systemImage: "key") }
                    Button { sheet = .server(server) } label: { Label("连接设置", systemImage: "slider.horizontal.3") }
                }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.85)).padding(19)
            }
        }.frame(width: 175).frame(maxHeight: .infinity)
            .background(WorkbenchStyle.rail)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer")
                Image(systemName: "ellipsis").font(.body)
                Image(systemName: "server.rack")
            }.font(.system(size: 36, weight: .light)).foregroundStyle(.teal)
            Text("连接你的第一台服务器").font(.largeTitle.weight(.semibold))
            Text("通过 SSH 密钥查看显卡占用，在独立标签页打开常用的 tmux 工作环境。")
                .foregroundStyle(.secondary).font(.body)
            Button { sheet = .server(nil) } label: { Label("添加服务器", systemImage: "plus") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let error = store.storageError { Notice(text: error) }
        }
        .padding(42).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func tabStrip(for profile: ServerProfile) -> some View {
        HStack(spacing: 7) {
            Button { activeTab = nil } label: {
                Label("概览", systemImage: "square.grid.2x2")
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                    .background(selectedTab == nil ? Color.teal.opacity(0.16) : .clear, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("1", modifiers: .command)

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(tabs.filter { $0.serverID == profile.id }) { tab in
                        HStack(spacing: 0) {
                            Button { activate(tab) } label: {
                                Label(tab.title, systemImage: tab.isUnlock ? "key" : "terminal")
                                    .padding(.leading, 9).padding(.trailing, 5)
                                    .frame(minHeight: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { close(tab) } label: {
                                Image(systemName: "xmark").font(.caption2)
                                    .frame(width: 28, height: 28).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help("关闭标签并断开本地连接").accessibilityLabel("关闭 \(tab.title)")
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
                        Text(verbatim: "\(profile.username)@\(profile.host) · \(profile.port)")
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { resumeMonitoring(profile.id) } label: { Label("刷新", systemImage: "arrow.clockwise") }
                }
                GPUSection(snapshot: snapshots[profile.id])
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Label("快捷方式", systemImage: "terminal").font(.title3.weight(.semibold))
                        Spacer()
                        if !checked.isEmpty {
                            Button("打开所选（\(checked.count)）") { openSelected(on: profile) }.buttonStyle(.borderedProminent)
                        }
                        Button { sheet = .shortcut(profile, nil) } label: { Label("新建", systemImage: "plus") }
                    }
                    if shortcuts.isEmpty {
                        Button { sheet = .shortcut(profile, nil) } label: {
                            Label("保存第一个 tmux 工作环境", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity).padding(22)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        ForEach(shortcuts) { shortcut in shortcutRow(shortcut, profile: profile) }
                    }
                }
                if let error = store.storageError { Notice(text: error) }
            }.padding(26).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func shortcutRow(_ item: Shortcut, profile: ServerProfile) -> some View {
        let isPending = pending.contains(item.id)
        let tab = tabs.first { $0.id == item.id }
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Toggle("选择 \(item.title)", isOn: Binding(get: { checked.contains(item.id) }, set: { selected in
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
                if isPending { ProgressView().controlSize(.small).help("正在准备会话") }
                Button(tab == nil ? "打开" : "查看标签") { open(item, on: profile, focus: true) }.disabled(isPending)
                Menu {
                    Button("编辑快捷方式") { sheet = .shortcut(profile, item) }.disabled(tab != nil || isPending)
                    Button("移除本地快捷方式") {
                        do { try store.removeShortcut(item.id); checked.remove(item.id); failures[item.id] = nil }
                        catch { message = error.localizedDescription }
                    }.disabled(isPending || tab != nil)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("快捷方式选项")
            }
            if let failure = failures[item.id] { Notice(text: failure) }
        }.padding(13).background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 9))
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
                monitoringFailed(id, detail: "监控连接已结束。", reachedServer: false, retry: false)
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

    private func monitoringFailed(_ id: UUID, detail: String, reachedServer: Bool, retry: Bool) {
        var snapshot = snapshots[id] ?? GPUSnapshot()
        snapshot.online = reachedServer
        if retry {
            let delay = snapshot.nextRetryDelay
            snapshot.retryAfter = ContinuousClock.now.advanced(by: .seconds(delay))
            snapshot.nextRetryDelay = min(delay * 2, 60)
            snapshot.error = "\(detail)\n\(delay) 秒后自动重试。"
        } else {
            snapshot.monitoringPaused = true
            snapshot.retryAfter = nil
            snapshot.error = "\(detail)\n监控已暂停，点击刷新或修正设置后重试。"
        }
        snapshots[id] = snapshot
    }

    private func resumeMonitoring(_ id: UUID) {
        if var snapshot = snapshots[id] {
            snapshot.monitoringPaused = false
            snapshot.nextRetryDelay = 5
            snapshot.retryAfter = nil
            if snapshot.error != nil { snapshot.error = "正在重新连接…" }
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
        for item in queue { pending.insert(item.id); failures[item.id] = nil }
        Task { @MainActor in
            for item in queue { await prepare(item, on: profile, focus: false) }
        }
    }

    private func open(_ item: Shortcut, on profile: ServerProfile, focus: Bool) {
        if let tab = tabs.first(where: { $0.id == item.id }) {
            if focus { activate(tab) }
            return
        }
        guard pending.insert(item.id).inserted else { return }
        failures[item.id] = nil
        Task { @MainActor in await prepare(item, on: profile, focus: focus) }
    }

    @MainActor private func prepare(_ item: Shortcut, on profile: ServerProfile, focus: Bool) async {
        defer { pending.remove(item.id) }
        do {
            let result = try await SSHTransport.ensure(profile, item)
            let tab = try TerminalTab(id: item.id, profile: profile, shortcut: item, result: result)
            tabs.append(tab)
            if focus && server?.id == profile.id { activate(tab) }
        } catch { failures[item.id] = error.localizedDescription }
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
        if activeTab == tab.id { activeTab = nil }
    }
}
