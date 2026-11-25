import Foundation
import Testing
@testable import WorkbenchCore

struct ProjectSyncTests {
    @Test func filtersCopyOnlyProjectScriptsAndNeverDeleteExtras() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project")
        let dest = root.appendingPathComponent("destination")
        try put("src/train.py", in: source, value: "new")
        try put("src/launch.sh", in: source)
        try put("GPUWorkbench/Sources/remote.py", in: source)
        try put("nested/GPUWorkbench/Packaging/build-app.sh", in: source)
        try put("nested/Example.app/Contents/helper.py", in: source)
        for path in ["remote_monitor/tools/helper.py", "nested/Remote_Monitor/Sources/remote.py",
                     "manuscript/draft.py", "example2040-2/scripts/demo.sh", "article-revision/run.py",
                     ".scratch/private.sh", "reviews/notes.py"] {
            try put(path, in: source)
        }
        try put("nested/renamed/Packaging/build-app.sh", in: source)
        try put("nested/renamed/Sources/WorkbenchCore/SSHTransport.swift", in: source)
        try put("nested/renamed/Tests/check.py", in: source)
        try put("out/result.py", in: source)
        try put("config.txt", in: source)
        try put("src/train.py", in: dest, value: "old-longer")
        try put("remote-only.py", in: dest)

        let output = try run(source, to: dest, preview: true)
        let plan = try ProjectSync.changes(in: output, source: source)
        #expect(plan.map(\.path) == ["src/launch.sh", "src/train.py"])
        #expect(plan.map(\.isNew) == [true, false])
        #expect(try String(contentsOf: dest.appendingPathComponent("src/train.py"), encoding: .utf8) == "old-longer")
        try put("src/unreviewed.py", in: source)
        let manifest = root.appendingPathComponent("files")
        try (plan.map { "./" + $0.path }.joined(separator: "\n") + "\n")
            .write(to: manifest, atomically: true, encoding: .utf8)
        _ = try run(source, to: dest, preview: false, manifest: manifest)
        #expect(try String(contentsOf: dest.appendingPathComponent("src/train.py"), encoding: .utf8) == "new")
        for file in ["src/launch.sh", "remote-only.py"] {
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(file).path))
        }
        for file in ["GPUWorkbench", "remote_monitor", "nested", "manuscript", "example2040-2",
                     "article-revision", ".scratch", "reviews", "out", "config.txt", "src/unreviewed.py"] {
            #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(file).path))
        }
    }

    @Test func rejectsNestedWorkbenchSourceAndDestinationBeforeSSHSetup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try put("custom/Packaging/build-app.sh", in: root)
        try put("custom/Sources/WorkbenchCore/SSHTransport.swift", in: root)
        try put("Remote_Monitor/tools/check.py", in: root)
        try put("project/train.py", in: root)
        let profile = ServerProfile(label: "Fixture", host: "fixture.invalid", username: "tester",
                                    keyPath: "/example/key")
        var shortcut = Shortcut(serverID: profile.id, title: "Example", name: "demo", environment: "demo",
                                directory: "/work/project")
        func errorMessage(_ folder: String) -> String? {
            do {
                _ = try ProjectSync.arguments(profile, shortcut: shortcut, source: root.appendingPathComponent(folder),
                                              preview: true, pinDirectory: root.appendingPathComponent("pins"))
                return nil
            } catch { return error.localizedDescription }
        }
        let validSource = try #require(errorMessage("project")) // Reaches the check for a verified host key.
        let invalidSource = try #require(errorMessage("custom/Sources"))
        #expect(invalidSource != validSource)
        #expect(errorMessage("Remote_Monitor/tools") == invalidSource)
        shortcut.directory = "/work/remote_monitor/subdir"
        let invalidDestination = try #require(errorMessage("project"))
        #expect(invalidDestination != validSource)
        #expect(invalidDestination != invalidSource)
    }

    private func put(_ path: String, in directory: URL, value: String = "fixture") throws {
        let file = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: file, atomically: true, encoding: .utf8)
    }

    private func run(_ source: URL, to dest: URL, preview: Bool, manifest: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        var arguments = ["-rtiv", "--prune-empty-dirs", "--out-format=%i|%n"]
        arguments += ProjectSync.filters
        if preview { arguments.append("--dry-run") }
        if let manifest { arguments.append("--files-from=" + manifest.path) }
        arguments += ["--", source.path + "/", dest.path + "/"]
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return String(decoding: bytes, as: UTF8.self)
    }
}
