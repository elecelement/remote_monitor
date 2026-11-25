import AppKit
import SwiftUI
import WorkbenchCore

private struct SyncReview {
    let plan: ProjectSync.Preview
    let overwrites: [ProjectSync.Change]
    let additions: [ProjectSync.Change]

    init(_ plan: ProjectSync.Preview) {
        self.plan = plan
        overwrites = plan.changes.filter { !$0.isNew }
        additions = plan.changes.filter(\.isNew)
    }

    func summary(in language: WorkbenchLanguage) -> String {
        language.text("新增 \(additions.count) 个文件，覆盖 \(overwrites.count) 个同名文件",
                      "Additions \(additions.count) · Overwrites \(overwrites.count)")
    }
}

struct SyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workbenchLanguage) private var language
    let profile: ServerProfile
    let shortcut: Shortcut
    let store: WorkbenchStore
    @State private var chosen: URL?
    @State private var failure: String?
    @State private var busy = false
    @State private var review: SyncReview?
    @State private var finished = false
    @State private var confirming = false

    private var source: URL? {
        chosen ?? shortcut.syncSource.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(language.text("同步项目代码", "Sync Project Code"), systemImage: "arrow.up.circle").font(.title2.bold())
            LabeledContent(language.text("本地目录", "Local folder")) {
                HStack {
                    Text(source?.path ?? language.text("尚未选择", "No folder selected")).lineLimit(2).truncationMode(.middle)
                    Button(language.text("选择目录…", "Choose Folder…"), action: chooseFolder).disabled(busy)
                }
            }
            LabeledContent(language.text("远端目录", "Remote directory"), value: profile.username + "@" + profile.host + ":" + shortcut.directory)
            Text(language.text("仅同步 Python 和 Shell 源码。排除 GPUWorkbench、应用包和构建输出。同步可更新远端同名文件，保留远端多出的文件。", "Only Python and shell files are synced. GPUWorkbench, app bundles and build outputs are excluded. Matching remote files may be overwritten. Remote-only files are kept."))
                .font(.callout).foregroundStyle(.secondary)
            if let review, !review.plan.changes.isEmpty {
                HStack {
                    if finished {
                        Label(language.text("同步完成", "Sync complete"), systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                    } else {
                        Text(busy ? language.text("正在核对清单并上传…", "Checking files and uploading…") : language.text("待上传文件", "Files to upload"))
                    }
                    Spacer()
                    Text(review.summary(in: language)).font(.callout).foregroundStyle(.secondary)
                }.font(.headline)
                List {
                    ForEach(review.overwrites) { change in
                        changeRow(change)
                    }
                    ForEach(review.additions) { change in
                        changeRow(change)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView {
                    Text(verbatim: statusText)
                        .foregroundStyle(failure == nil ? Color.primary : Color.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(WorkbenchStyle.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button(language.text("关闭", "Close")) { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(language.text("预演", "Preview")) { preview() }.disabled(source == nil || busy)
                if !finished {
                    Button(language.text("继续同步…", "Continue…")) { confirming = true }
                        .buttonStyle(.borderedProminent).disabled(review?.plan.changes.isEmpty != false || busy)
                }
            }
        }
        .padding(24).frame(width: 690, height: 455)
        .interactiveDismissDisabled(busy)
        .alert(language.text("上传到「\(profile.label)」？", "Upload to “\(profile.label)”?"), isPresented: $confirming, presenting: review) { reviewed in
            Button(language.text("返回清单", "Back to File List"), role: .cancel) {}
            Button(language.text("确认上传 \(reviewed.plan.changes.count) 个文件", "Confirm Upload (\(reviewed.plan.changes.count))")) { upload(reviewed.plan) }
        } message: { reviewed in
            Text(verbatim: "\(profile.username)@\(profile.host):\(shortcut.directory)\n\(reviewed.summary(in: language))")
        }
    }

    private func changeRow(_ change: ProjectSync.Change) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(change.isNew ? language.text("新增", "New") : language.text("覆盖", "Overwrite"))
                .foregroundStyle(change.isNew ? Color.teal : Color.orange)
            Text(verbatim: change.path).fontDesign(.monospaced).textSelection(.enabled)
        }
    }

    private var statusText: String {
        if let failure { return language.diagnostic(failure) }
        if busy { return language.text("正在预演…", "Generating preview…") }
        if review != nil { return language.text("没有待上传的文件。", "No files to upload.") }
        return language.text("先预演，查看将上传的文件。", "Preview the changes to see which files will be uploaded.")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = language.text("选择本地项目目录", "Choose Local Project Folder")
        panel.prompt = language.text("选择", "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = source
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            try store.setSyncSource(folder, for: shortcut.id)
            chosen = folder
            failure = nil
            review = nil
            finished = false
        } catch {
            review = nil
            finished = false
            failure = error.localizedDescription
        }
    }

    private func preview() {
        guard let source else { return }
        review = nil
        finished = false
        perform {
            let result = try await ProjectSync.preview(profile, shortcut: shortcut, source: source)
            review = SyncReview(result)
        }
    }

    private func upload(_ reviewed: ProjectSync.Preview) {
        perform {
            try await ProjectSync.upload(reviewed)
            finished = true
        }
    }

    private func perform(operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                try await operation()
            } catch {
                review = nil
                failure = error.localizedDescription
            }
        }
    }
}
