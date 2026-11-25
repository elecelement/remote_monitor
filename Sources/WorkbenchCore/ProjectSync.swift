import Foundation

public enum ProjectSync {
    public struct Change: Identifiable, Hashable, Sendable {
        public let path: String
        public let isNew: Bool
        public var id: String { path }
    }

    public struct Preview: Sendable {
        public let changes: [Change]
        fileprivate let profile: ServerProfile
        fileprivate let shortcut: Shortcut
        fileprivate let source: URL
    }

    static let filters = [
        "GPUWorkbench/", "remote_monitor/", "*.app/", "out/", "output/", "outputs/", "build/",
        "/manuscript/", "/*[0-9][0-9][0-9][0-9]-[0-9]*/", "/*-revision/", "/reviews/", "/tmp/", "/.*/",
        ".git", ".idea/", "__pycache__/", ".build/", ".swiftpm/", ".ssh/", ".aws/"
    ].map { "--exclude=" + $0 } +
        ["--include=*/", "--include=*.py", "--include=*.sh", "--exclude=*"]

    public static func preview(_ profile: ServerProfile, shortcut: Shortcut, source: URL) async throws -> Preview {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let args = try arguments(profile, shortcut: shortcut, source: source, preview: true)
        let output = try await run(args, timeout: 90)
        return Preview(changes: try changes(in: output, source: source), profile: profile,
                       shortcut: shortcut, source: source)
    }

    public static func upload(_ preview: Preview) async throws {
        guard !preview.changes.isEmpty else { return }
        let current = try await Self.preview(preview.profile, shortcut: preview.shortcut, source: preview.source)
        guard current.changes == preview.changes else {
            throw TransportError("预演后的变更清单已变化，请重新预演确认。尚未上传文件。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("files")
        try (preview.changes.map { "./" + $0.path }.joined(separator: "\n") + "\n")
            .write(to: manifest, atomically: true, encoding: .utf8)
        let args = try arguments(preview.profile, shortcut: preview.shortcut, source: preview.source,
                                 preview: false, manifest: manifest)
        _ = try await run(args, timeout: nil)
    }

    static func changes(in output: String, source: URL) throws -> [Change] {
        var changes: [Change] = []
        var workbenchDirectories: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let code = fields[0]
            guard [9, 11].contains(code.count) else {
                throw TransportError("无法识别 rsync 的逐文件预演输出，已停止同步。")
            }
            if code.dropFirst().first == "d" { continue }
            guard code.dropFirst().first == "f", let operation = code.first,
                  [">", "<", "."].contains(operation) else {
                throw TransportError("预演包含无法确认的文件类型或操作，已停止同步。")
            }
            let path = String(fields[1])
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            let file = source.appendingPathComponent(path)
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  path.rangeOfCharacter(from: .controlCharacters) == nil, !path.contains("\\"),
                  ["py", "sh"].contains(file.pathExtension),
                  file.resolvingSymlinksInPath().path == file.path,
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw TransportError("预演清单包含无法安全确认的路径，请检查本地文件后重新预演。")
            }
            if !insideWorkbench(file.deletingLastPathComponent(), cache: &workbenchDirectories) {
                changes.append(Change(path: path, isNew: code.dropFirst(2).allSatisfy { $0 == "+" }))
            }
        }
        return changes.sorted { $0.path < $1.path }
    }

    private static func protectedDirectory(_ name: some StringProtocol) -> Bool {
        let lower = name.lowercased()
        return lower == "gpuworkbench" || lower == "remote_monitor" || lower.hasSuffix(".app")
    }

    // A checkout can be renamed, selected through a subfolder, or nested in a project.
    private static func insideWorkbench(_ directory: URL, cache: inout [String: Bool]) -> Bool {
        let path = directory.path
        if let result = cache[path] { return result }
        guard path != "/", !path.isEmpty else { return false }
        let files = FileManager.default
        let protected = protectedDirectory(directory.lastPathComponent) ||
            (files.fileExists(atPath: directory.appendingPathComponent("Packaging/build-app.sh").path) &&
             files.fileExists(atPath: directory.appendingPathComponent("Sources/WorkbenchCore/SSHTransport.swift").path)) ||
            insideWorkbench(directory.deletingLastPathComponent(), cache: &cache)
        cache[path] = protected
        return protected
    }

    private static func run(_ args: [String], timeout: TimeInterval?) async throws -> String {
        let result = try await LocalProcess.run("/usr/bin/rsync", args, timeout: timeout)
        let output = String(decoding: result.output, as: UTF8.self)
        let errors = String(decoding: result.errors, as: UTF8.self)
        guard result.status == 0 else {
            throw TransportError("同步退出码 \(result.status)\n" + errors + output)
        }
        return output
    }

    static func arguments(_ profile: ServerProfile, shortcut: Shortcut, source: URL,
                          preview: Bool, manifest: URL? = nil, pinDirectory: URL? = nil) throws -> [String] {
        let local = source.resolvingSymlinksInPath().standardizedFileURL
        var workbenchDirectories: [String: Bool] = [:]
        guard source.isFileURL, local.path != "/",
              (try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              !insideWorkbench(local, cache: &workbenchDirectories) else {
            throw TransportError("请选择本地项目目录。GPU 工作台源码目录和应用包不能作为同步来源。")
        }
        let remote = shortcut.directory
        let parts = remote.split(separator: "/")
        guard shortcut.serverID == profile.id, remote.hasPrefix("/"), !parts.isEmpty,
              !parts.contains("."), !parts.contains(".."),
              remote.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 47, 95].contains($0) }),
              !parts.contains(where: protectedDirectory) else {
            throw TransportError("同步目标须为该服务器快捷方式中的项目绝对路径，路径可使用英文字母、数字、点、下划线和连字符。")
        }
        let ssh = try SSHTransport.connectionArguments(profile, pinDirectory: pinDirectory)
        let shell = (["/usr/bin/ssh"] + ssh).map { token in
            "'" + token.replacingOccurrences(of: "'", with: "''") + "'"
        }.joined(separator: " ")
        let host = profile.host.contains(":") ? "[\(profile.host)]" : profile.host
        let target = "/" + parts.joined(separator: "/")
        var args = ["-rtiv", "--prune-empty-dirs", "--timeout=60", "--out-format=%i|%n", "-e", shell,
                    "--rsync-path=test -d '\(target)' && exec rsync"]
        args += filters
        if preview { args.append("--dry-run") }
        if let manifest { args.append("--files-from=" + manifest.path) }
        guard preview || manifest != nil else { throw TransportError("上传前需要确认文件清单。") }
        args += ["--", local.path + "/", host + ":" + target + "/"]
        return args
    }
}
