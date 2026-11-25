import AppKit
import Darwin
import SwiftUI
import SwiftTerm
import WorkbenchCore

// Only PTY input and size changes cross from the terminal into the host.
// User-initiated native Copy/Paste remains available through the edit menu.
@MainActor
private final class TerminalHostDelegate: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let view = source as? LocalProcessTerminalView, view.process.running else { return }
        view.send(source: source, data: data)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        (source as? LocalProcessTerminalView)?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func bell(source: TerminalView) {}
}

enum TerminalLaunchStatus {
    case ready, needsActivation, attaching, attached

    func text(in language: WorkbenchLanguage) -> String {
        switch self {
        case .ready: return language.text("已新建 · 三个窗格已就绪", "Created · Three panes ready")
        case .needsActivation: return language.text("已新建 · 三个窗格已打开", "Created · Three panes open")
        case .attaching: return language.text("已找到原会话 · 正在接回", "Session found · Attaching")
        case .attached: return language.text("已接回 · 沿用原有窗格", "Attached · Existing panes preserved")
        }
    }
}

@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let serverID: UUID
    private let sessionName: String?
    private let endpoint: String
    private let launch: LaunchResult?
    var isUnlock: Bool { sessionName == nil }
    var sessionToken: String? { launch?.sessionToken }
    @Published private(set) var launchStatus: TerminalLaunchStatus?
    let terminal: WorkbenchTerminalView
    private let hostDelegate = TerminalHostDelegate()
    @Published private(set) var ended = false
    @Published private(set) var exitCode: Int32?
    var onExit: (() -> Void)?

    init(id: UUID, profile: ServerProfile, shortcut: Shortcut?, result: LaunchResult?) throws {
        self.id = id
        serverID = profile.id
        sessionName = shortcut?.name
        endpoint = "\(profile.username)@\(profile.host)"
        launch = result
        switch result?.origin {
        case .created:
            launchStatus = result?.state == "manual" ? .needsActivation : .ready
        case .resumed: launchStatus = .attaching
        case nil: launchStatus = nil
        }
        terminal = WorkbenchTerminalView(frame: CGRect(x: 0, y: 0, width: 780, height: 430))
        let arguments: [String]
        let executable: String
        if let shortcut {
            guard let result else { throw CocoaError(.coderValueNotFound) }
            arguments = try SSHTransport.attachArguments(profile, shortcut, result: result)
            executable = "/usr/bin/ssh"
        } else {
            arguments = try SSHTransport.unlockArguments(profile)
            executable = "/usr/bin/ssh-add"
        }
        super.init()
        terminal.processDelegate = self
        terminal.terminalDelegate = hostDelegate
        if result?.origin == .resumed {
            terminal.onTmuxScreen = { [weak self] in self?.launchStatus = .attached }
        }
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var environment = ["TERM=xterm-256color", "LANG=en_US.UTF-8", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                environment.append("\(key)=\(value)")
            }
        }
        terminal.startProcess(executable: executable, args: arguments, environment: environment)
        if terminal.process.shellPid == 0 {
            throw NSError(domain: "GPUWorkbench.Terminal", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "无法创建本地终端。请关闭闲置的本地标签页后重试。"
            ])
        }
    }

    func disconnect() {
        onExit = nil
        guard !ended, terminal.process.running else { return }
        let localPID = terminal.process.shellPid
        guard localPID > 0 else { return }
        terminal.terminate()
        // SwiftTerm 1.20 cancels its exit monitor on explicit termination.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(localPID, &status, 0) < 0 && errno == EINTR {}
        }
    }

    func title(in language: WorkbenchLanguage) -> String {
        sessionName ?? language.text("本地密钥解锁", "Unlock Key")
    }

    func subtitle(in language: WorkbenchLanguage) -> String {
        isUnlock ? language.text("本机 · 系统 SSH 代理", "Local · System SSH agent") : endpoint + " · tmux"
    }

    func activationNotice(in language: WorkbenchLanguage) -> String? {
        guard let launch, launch.state == "manual" else { return nil }
        if launch.origin == .created {
            return language.text("待手动激活 · ", "Manual activation required · ") + language.diagnostic(launch.detail)
        }
        return language.text("此会话创建时需要手动激活 Conda。接回后请以各窗格的当前环境为准。",
                             "This session needed manual Conda activation when it was created. Check the current environment in each pane.")
    }

    func dismissStatus(_ message: TerminalLaunchStatus) {
        if launchStatus == message { launchStatus = nil }
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.ended = true
            self?.exitCode = exitCode
            self?.onExit?()
        }
    }
}

final class WorkbenchTerminalView: LocalProcessTerminalView {
    var onTmuxScreen: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // A plain SSH error can reach the PTY before a successful tmux attachment.
        if let callback = onTmuxScreen, terminal.isCurrentBufferAlternate {
            onTmuxScreen = nil
            callback()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusKeyboard()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    func focusKeyboard() {
        // SwiftUI may finish restoring the button's focus after mounting the AppKit view.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, !isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(self)
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let tab: TerminalTab

    func makeNSView(context: Context) -> NSView {
        let host = TerminalViewport()
        let terminal = tab.terminal
        terminal.removeFromSuperview()
        terminal.frame = host.bounds
        terminal.autoresizingMask = [.width, .height]
        host.addSubview(terminal)
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class TerminalViewport: NSView {
    override var wantsDefaultClipping: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

struct TerminalPane<RecoveryControls: View>: View {
    @Environment(\.workbenchLanguage) private var language
    @ObservedObject var tab: TerminalTab
    @ViewBuilder let recoveryControls: () -> RecoveryControls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(tab.title(in: language)).font(.title2.weight(.semibold))
                        if !tab.ended, let status = tab.launchStatus {
                            Label(status.text(in: language), systemImage: "terminal")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Text(tab.subtitle(in: language)).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if tab.isUnlock {
                Notice(text: tab.ended
                    ? (tab.exitCode == 0 ? language.text("密钥已解锁，可返回概览连接服务器。", "Key unlocked. Return to Overview to connect.")
                       : language.text("密钥解锁已结束，请查看终端输出。", "Key unlock finished. Check the terminal output."))
                    : language.text("在下方本地终端输入密钥口令，输入时不会显示字符。", "Enter the key passphrase in the local terminal below. Characters stay hidden as you type."), symbol: "key.fill", color: .teal)
            } else if tab.ended {
                recoveryControls()
            } else if let message = tab.activationNotice(in: language) {
                Notice(text: message)
            }
            TerminalSurface(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: tab.launchStatus) {
            guard let status = tab.launchStatus else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            tab.dismissStatus(status)
        }
    }
}
