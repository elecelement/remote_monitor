import AppKit
import SwiftUI
import Testing
@testable import WorkbenchCore
@testable import GPUWorkbench

@MainActor
struct LanguageSwitchingTests {
    @Test func sidebarPickerSavesTheSelectionBeforeConnecting() async throws {
        _ = NSApplication.shared
        let suite = "LanguageFixture-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkbenchStore(directory: directory)
        let host = NSHostingView(rootView: SidebarFixture(store: store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 570),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let picker = try #require(allViews(in: host).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(picker.segmentCount == 2)
        #expect(picker.selectedSegment == 0)
        picker.selectedSegment = 1
        _ = picker.sendAction(picker.action, to: picker.target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.string(forKey: WorkbenchLanguage.preferenceKey) == WorkbenchLanguage.english.rawValue)
        #expect(picker.selectedSegment == 1)
        picker.selectedSegment = 0
        _ = picker.sendAction(picker.action, to: picker.target)
        try await Task.sleep(for: .milliseconds(100))
        #expect(defaults.string(forKey: WorkbenchLanguage.preferenceKey) == WorkbenchLanguage.chinese.rawValue)
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    @Test func switchingLanguageRetainsDraftInOpenEditor() async throws {
        _ = NSApplication.shared
        let setting = LanguageSetting()
        let host = NSHostingView(rootView: EditorFixture(setting: setting))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 535, height: 525),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func field(withPrompt prompt: String) async throws -> NSTextField {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while clock.now < deadline {
                host.layoutSubtreeIfNeeded()
                if let field = textFields(in: host).first(where: { $0.placeholderString == prompt }) {
                    return field
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CocoaError(.coderValueNotFound)
        }
        let original = try await field(withPrompt: "主机名或 IP 地址")
        original.stringValue = "demo.invalid"
        original.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: original))
        setting.language = .english
        let english = try await field(withPrompt: "Hostname or IP address")
        #expect(english.stringValue == "demo.invalid")
        setting.language = .chinese
        let chinese = try await field(withPrompt: "主机名或 IP 地址")
        #expect(chinese.stringValue == "demo.invalid")
    }

    @Test func terminalAndMonitorStatusesRerenderInEitherLanguage() {
        let status = TerminalLaunchStatus.attached
        #expect(status.text(in: .english) == "Attached · Existing panes preserved")
        #expect(status.text(in: .chinese) == "已接回 · 沿用原有窗格")
        let retry = MonitorNotice.retry("SSH diagnostic /tmp/实验", 5)
        #expect(retry.text(in: .english) == "SSH diagnostic /tmp/实验\nRetrying in 5 seconds.")
        #expect(retry.text(in: .chinese) == "SSH diagnostic /tmp/实验\n5 秒后自动重试。")
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap(textFields)
    }
}

private struct SidebarFixture: View {
    @ObservedObject var store: WorkbenchStore
    @AppStorage(WorkbenchLanguage.preferenceKey) var language = WorkbenchLanguage.chinese

    var body: some View {
        WorkbenchView(store: store).environment(\.workbenchLanguage, language)
    }
}

private final class LanguageSetting: ObservableObject {
    @Published var language = WorkbenchLanguage.chinese
}

private struct EditorFixture: View {
    @ObservedObject var setting: LanguageSetting

    var body: some View {
        ServerEditor(existing: nil, condaLocked: false) { _ in }
            .environment(\.workbenchLanguage, setting.language)
            .environment(\.locale, Locale(identifier: setting.language.rawValue))
    }
}
