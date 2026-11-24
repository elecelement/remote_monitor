import AppKit
import SwiftUI
import WorkbenchCore

@main
struct GPUWorkbenchApp: App {
    @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var delegate
    @StateObject private var store = WorkbenchStore()

    var body: some Scene {
        Window("GPU 工作台", id: "workbench") {
            WorkbenchView(store: store)
                .frame(minWidth: 860, minHeight: 570)
                .tint(WorkbenchStyle.accent)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
    }
}

final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum WorkbenchStyle {
    static let accent = Color(red: 0.02, green: 0.46, blue: 0.39)
    static let rail = Color(red: 0.07, green: 0.16, blue: 0.17)
    static let mint = Color(red: 0.53, green: 0.90, blue: 0.75)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

struct Notice: View {
    let text: String
    var symbol = "exclamationmark.circle"
    var color = Color.orange

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: text).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
