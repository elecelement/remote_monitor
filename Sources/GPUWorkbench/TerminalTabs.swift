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

@MainActor
final class TerminalTab: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id: UUID
    let serverID: UUID
    let title: String
    let subtitle: String
    let isUnlock: Bool
    let detail: String
    let isManual: Bool
    let terminal: WorkbenchTerminalView
    private let hostDelegate = TerminalHostDelegate()
    @Published private(set) var ended = false
    @Published private(set) var exitCode: Int32?
    var onExit: (() -> Void)?

    init(id: UUID, profile: ServerProfile, shortcut: Shortcut?, result: LaunchResult?) throws {
        self.id = id
        serverID = profile.id
        isUnlock = shortcut == nil
        title = shortcut?.name ?? "本地密钥解锁"
        subtitle = shortcut == nil ? "本机 · 系统 SSH 代理" : "\(profile.username)@\(profile.host) · 手动终端"
        isManual = result?.state == "manual"
        detail = result?.detail ?? ""
        terminal = WorkbenchTerminalView(frame: CGRect(x: 0, y: 0, width: 780, height: 430))
        let arguments: [String]
        let executable: String
        if let shortcut {
            arguments = try SSHTransport.attachArguments(profile, shortcut)
            executable = "/usr/bin/ssh"
        } else {
            arguments = try SSHTransport.unlockArguments(profile)
            executable = "/usr/bin/ssh-add"
        }
        super.init()
        terminal.processDelegate = self
        terminal.terminalDelegate = hostDelegate
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

struct TerminalPane: View {
    @ObservedObject var tab: TerminalTab
    let reconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tab.title).font(.title2.weight(.semibold))
                    Text(tab.subtitle).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if tab.ended && !tab.isUnlock { Button("重新连接", action: reconnect) }
            }
            if tab.isUnlock {
                Notice(text: tab.ended
                    ? (tab.exitCode == 0 ? "密钥已解锁，可返回概览连接服务器。" : "密钥解锁已结束，请查看终端输出。")
                    : "在下方本地终端输入密钥口令，输入时不会显示字符。", symbol: "key.fill", color: .teal)
            } else if tab.ended {
                Notice(text: "终端连接已结束。重新连接可以接回仍在运行的会话。", symbol: "cable.connector.slash")
            } else if tab.isManual {
                Notice(text: "待手动激活 · " + tab.detail)
            }
            TerminalSurface(tab: tab)
                .id(tab.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
