import Combine
import Darwin
import Foundation

public struct ServerProfile: Codable, Identifiable, Hashable {
    public let id: UUID
    public var label: String
    public var host: String
    public var port: Int
    public var username: String
    public var keyPath: String
    public var conda: String
    public var pin: HostPin?

    public init(id: UUID = UUID(), label: String, host: String, port: Int = 22,
                username: String, keyPath: String, conda: String = "", pin: HostPin? = nil) {
        self.id = id
        self.label = label
        self.host = host
        self.port = port
        self.username = username
        self.keyPath = keyPath
        self.conda = conda
        self.pin = pin
    }
}

public struct Shortcut: Codable, Identifiable, Hashable {
    public let id: UUID
    public var serverID: UUID
    public var title: String
    public var name: String
    public var environment: String
    public var directory: String
    public var allowExisting: Bool?
    public private(set) var socketID: String
    public private(set) var sessionID: String

    public init(id: UUID = UUID(), serverID: UUID, title: String, name: String,
                environment: String, directory: String, allowExisting: Bool = false) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.name = name
        self.environment = environment
        self.directory = directory
        self.allowExisting = allowExisting
        self.socketID = Self.token()
        self.sessionID = Self.token()
    }

    fileprivate mutating func renewSession() {
        socketID = Self.token()
        sessionID = Self.token()
    }

    fileprivate mutating func keepSession(of other: Self) {
        socketID = other.socketID
        sessionID = other.sessionID
    }

    private static func token() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private struct Library: Codable {
    var version = 1
    var servers: [ServerProfile] = []
    var shortcuts: [Shortcut] = []
}

private struct LibraryError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
public final class WorkbenchStore: ObservableObject {
    @Published public private(set) var servers: [ServerProfile] = []
    @Published public private(set) var shortcuts: [Shortcut] = []
    @Published public private(set) var storageError: String?
    private let directory: URL

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(directory: support.appendingPathComponent("GPUWorkbench", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        do { publish(try read()) }
        catch { storageError = error.localizedDescription }
    }

    public func save(_ server: ServerProfile) throws {
        guard Self.text(server.label), Self.text(server.host), Self.text(server.username),
              (1...65535).contains(server.port), Self.path(server.keyPath),
              server.conda.isEmpty || Self.path(server.conda), server.pin != nil else {
            throw LibraryError("请填写有效的服务器资料、绝对路径，并先核对主机指纹。")
        }
        try update { library in
            if let index = library.servers.firstIndex(where: { $0.id == server.id }) {
                let original = library.servers[index]
                guard original.host == server.host, original.port == server.port,
                      original.username == server.username, original.pin == server.pin else {
                    throw LibraryError("主机、账号或指纹发生变化。请单独添加并核对新的服务器。")
                }
                if original.conda != server.conda {
                    for i in library.shortcuts.indices where library.shortcuts[i].serverID == server.id {
                        library.shortcuts[i].renewSession()
                    }
                }
                library.servers[index] = server
            } else {
                library.servers.append(server)
            }
        }
    }

    public func save(_ shortcut: Shortcut) throws {
        guard Self.text(shortcut.title), Self.path(shortcut.directory) else {
            throw LibraryError("请填写快捷方式的显示名称和远程工作目录的绝对路径。")
        }
        guard Self.identifier(shortcut.name, maxLength: 64, punctuation: "_-") else {
            throw LibraryError("会话名最长 64 个字符，可使用文字、数字、下划线和连字符，首字符不能为连字符。")
        }
        guard Self.identifier(shortcut.environment, maxLength: 128, punctuation: "_.-") else {
            throw LibraryError("请输入 Conda 环境名称，首字符为文字、数字或下划线，名称中可包含点和连字符。")
        }
        try update { library in
            guard library.servers.contains(where: { $0.id == shortcut.serverID }) else {
                throw LibraryError("请先保存并核对目标服务器。")
            }
            if library.shortcuts.contains(where: {
                $0.serverID == shortcut.serverID && $0.name == shortcut.name && $0.id != shortcut.id
            }) { throw LibraryError("该服务器已有此会话名，请选择另一个名称。") }
            var value = shortcut
            if let index = library.shortcuts.firstIndex(where: { $0.id == value.id }) {
                let old = library.shortcuts[index]
                if old.serverID == value.serverID, old.name == value.name,
                   old.environment == value.environment, old.directory == value.directory {
                    value.keepSession(of: old)
                } else {
                    value.renewSession()
                }
                library.shortcuts[index] = value
            } else {
                library.shortcuts.append(value)
            }
        }
    }

    public func removeShortcut(_ id: UUID) throws {
        try update { $0.shortcuts.removeAll { $0.id == id } }
    }

    private static func text(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func path(_ value: String) -> Bool {
        value.hasPrefix("/") && value.unicodeScalars.count <= 4096 && text(value)
    }

    private static func identifier(_ name: String, maxLength: Int, punctuation: String) -> Bool {
        let scalars = name.unicodeScalars
        let letters = CharacterSet.alphanumerics
        guard let first = scalars.first, scalars.count <= maxLength,
              letters.contains(first) || first == "_" else { return false }
        return scalars.allSatisfy { letters.contains($0) || punctuation.unicodeScalars.contains($0) }
    }

    private var file: URL { directory.appendingPathComponent("library.json") }

    private func read() throws -> Library {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Library() }
        do {
            let result = try JSONDecoder().decode(Library.self, from: data)
            guard result.version == 1 else { throw LibraryError("无法读取此版本的本地配置。") }
            return result
        } catch {
            throw LibraryError("无法读取本地配置，已保留原文件。\n\(file.path)")
        }
    }

    private func update(_ mutate: (inout Library) throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent("library.lock").path,
                        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(lock, LOCK_UN) }
        var library = try read()
        try mutate(&library)
        try JSONEncoder().encode(library).write(to: file, options: .atomic)
        publish(library)
    }

    private func publish(_ library: Library) {
        servers = library.servers
        shortcuts = library.shortcuts
        storageError = nil
    }
}
