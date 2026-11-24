import Foundation
import Testing
@testable import WorkbenchCore

@MainActor
struct LibraryTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var server: ServerProfile {
        let pin = HostPin(host: "test.invalid", port: 22, keyType: "ssh-ed25519", publicKey: "fixture")
        return ServerProfile(label: "测试服务器", host: pin.host, username: "tester",
                             keyPath: "/fixture/key", pin: pin)
    }

    @Test func remembersOnlyLocalMetadataAndReusesIdentityAcrossLaunches() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = server
        let first = WorkbenchStore(directory: directory)
        #expect(first.storageError == nil)
        try first.save(profile)
        let item = Shortcut(serverID: profile.id, title: "训练", name: "train-01",
                            environment: "pytorch", directory: "/work/项目 A")
        try first.save(item)
        let reopened = WorkbenchStore(directory: directory)
        #expect(reopened.shortcuts == [item])
        var renamed = item
        renamed.title = "训练一"
        try reopened.save(renamed)
        #expect(reopened.shortcuts[0].sessionID == item.sessionID)
        renamed.directory = "/work/项目 B"
        try reopened.save(renamed)
        #expect(reopened.shortcuts[0].sessionID != item.sessionID)
        #expect(reopened.shortcuts[0].socketID != item.socketID)
        let another = Shortcut(serverID: profile.id, title: "分析", name: "analysis",
                               environment: "stats", directory: "/work/分析")
        try first.save(another)
        #expect(first.shortcuts.map(\.id) == [item.id, another.id])
        try reopened.removeShortcut(item.id)
        #expect(WorkbenchStore(directory: directory).shortcuts == [another])
    }

    @Test func protectsExistingIdentityAndConflictingNames() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkbenchStore(directory: directory)
        let profile = server
        try store.save(profile)
        var changed = profile
        changed.username = "different-user"
        #expect(throws: (any Error).self) { try store.save(changed) }
        let item = Shortcut(serverID: profile.id, title: "one", name: "train",
                            environment: "env", directory: "/work")
        try store.save(item)
        let duplicate = Shortcut(serverID: profile.id, title: "two", name: "train",
                                 environment: "env2", directory: "/work")
        #expect(throws: (any Error).self) { try store.save(duplicate) }
        var changedConda = profile
        changedConda.conda = "/opt/conda"
        try store.save(changedConda)
        #expect(store.shortcuts.first?.socketID != item.socketID)
        #expect(store.servers.first?.username == profile.username)
    }

    @Test func damagedLibraryIsPreserved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("library.json")
        let bytes = Data("existing, unreadable library".utf8)
        try bytes.write(to: file)
        let store = WorkbenchStore(directory: directory)
        #expect(store.storageError != nil)
        #expect(throws: (any Error).self) { try store.save(server) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
