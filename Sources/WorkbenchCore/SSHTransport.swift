import CryptoKit
import Foundation
import Darwin

public struct HostPin: Codable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let keyType: String
    public let publicKey: String

    public var fingerprint: String {
        let digest = SHA256.hash(data: Data(base64Encoded: publicKey) ?? Data())
        return "SHA256:" + Data(digest).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate var algorithms: String? {
        switch keyType {
        case "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            return keyType
        case "ssh-rsa":
            return "rsa-sha2-512,rsa-sha2-256"
        default:
            return nil
        }
    }

    fileprivate var hasValidKey: Bool {
        guard algorithms != nil, publicKey.utf8.count <= 16_384,
              let blob = Data(base64Encoded: publicKey), blob.count >= 5,
              blob.base64EncodedString() == publicKey else { return false }
        let count = blob.prefix(4).reduce(0) { ($0 << 8) + Int($1) }
        guard count == keyType.utf8.count, blob.count > count + 4 else { return false }
        return blob.dropFirst(4).prefix(count).elementsEqual(keyType.utf8)
    }
}

public struct GPUReading: Codable, Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let name: String
    public let utilization: Double?
    public let memoryUsed: Double?
    public let memoryTotal: Double?
    public let memoryFree: Double?
}

public enum SessionOrigin: String, Decodable, Sendable {
    case created, resumed
}

public enum SessionIssue: LocalizedError, Sendable {
    case missing
    case collision(String)

    public var errorDescription: String? {
        switch self {
        case .missing: return "未找到原会话。它可能已结束、改名或被同名会话替代。"
        case .collision: return "该名称已被会话使用。请选用其他名称，或核实后接回。"
        }
    }
}

public struct LaunchResult: Hashable, Sendable {
    public let state: String
    public let detail: String
    public let origin: SessionOrigin
    public let sessionToken: String
    fileprivate let confirmedExisting: Bool
}

public struct TransportError: LocalizedError, Sendable {
    public let errorDescription: String?
    public let reachedServer: Bool
    public let canRetryMonitoring: Bool
    init(_ message: String, reachedServer: Bool = false, canRetryMonitoring: Bool = false) {
        errorDescription = message
        self.reachedServer = reachedServer
        self.canRetryMonitoring = canRetryMonitoring
    }
}

public enum SSHTransport {
    private static let pinAlias = "gpuworkbench-pinned-host"

    /// Obtains a candidate only. The caller must obtain explicit confirmation of the fingerprint.
    public static func scanPin(_ profile: ServerProfile) async throws -> HostPin {
        let host = try endpoint(profile)
        let result = try await LocalProcess.run("/usr/bin/ssh-keyscan",
            ["-T", "6", "-p", String(profile.port), "-t", "ed25519,ecdsa,rsa", "--", host], timeout: 12)
        if let pin = candidate(in: result.output, host: host, port: profile.port) { return pin }
        throw TransportError("无法获取服务器主机指纹。请检查地址、端口和 VPN，再重试。")
    }

    static func candidate(in output: Data, host: String, port: Int) -> HostPin? {
        let keys: [HostPin] = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count == 3, !line.hasPrefix("#") else { return nil }
                let pin = HostPin(host: host, port: port, keyType: String(parts[1]), publicKey: String(parts[2]))
                return pin.hasValidKey ? pin : nil
            }
        return keys.first { $0.keyType == "ssh-ed25519" }
            ?? keys.first { $0.keyType.hasPrefix("ecdsa-") } ?? keys.first
    }

    public static func fetchGPUs(_ profile: ServerProfile) async throws -> [GPUReading] {
        let response = try await request(profile, shortcut: nil, mode: "gpu", timeout: 20)
        guard let readings = response.gpus else { throw invalidResponse }
        return readings
    }

    /// One SSH login per foreground subscription. Closing the stream closes only its local SSH client.
    public static func gpuFrames(_ profile: ServerProfile) -> AsyncThrowingStream<[GPUReading], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let args = try arguments(profile, shortcut: nil, mode: "watchGPU")
                    let result = try await LocalProcess.run("/usr/bin/ssh", args, timeout: nil) { line in
                        guard let reply = try? JSONDecoder().decode(Response.self, from: line) else {
                            throw invalidResponse
                        }
                        guard reply.ok else {
                            throw TransportError(clean(reply.error ?? "无法查询显卡。"), reachedServer: true)
                        }
                        guard let readings = reply.gpus else { throw invalidResponse }
                        if case .terminated = continuation.yield(readings) { throw CancellationError() }
                    }
                    if result.status != 0 { throw sshError(result.errors) }
                    throw TransportError("GPU 监控连接已中断。", canRetryMonitoring: true)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func ensure(_ profile: ServerProfile, _ shortcut: Shortcut) async throws -> LaunchResult {
        try await prepare(profile, shortcut, mode: "ensure")
    }

    public static func create(_ profile: ServerProfile, _ shortcut: Shortcut) async throws -> LaunchResult {
        try await prepare(profile, shortcut, mode: "create")
    }

    public static func reconnect(_ profile: ServerProfile, _ shortcut: Shortcut,
                                 sessionToken: String) async throws -> LaunchResult {
        try await prepare(profile, shortcut, mode: "reconnect", sessionToken: sessionToken)
    }

    public static func confirmExisting(_ profile: ServerProfile, _ shortcut: Shortcut,
                                       sessionToken: String) async throws -> LaunchResult {
        try await prepare(profile, shortcut, mode: "confirm", sessionToken: sessionToken)
    }

    private static func prepare(_ profile: ServerProfile, _ shortcut: Shortcut, mode: String,
                                sessionToken: String? = nil) async throws -> LaunchResult {
        let response = try await request(profile, shortcut: shortcut, mode: mode,
                                         timeout: 65, sessionToken: sessionToken)
        guard let state = response.state, ["ready", "manual"].contains(state),
              let detail = response.detail, let token = response.sessionToken,
              let origin = response.origin, mode != "create" || origin == .created,
              sessionToken == nil || (sessionToken == token && origin == .resumed)
        else { throw invalidResponse }
        return LaunchResult(state: state, detail: clean(detail), origin: origin, sessionToken: token,
                            confirmedExisting: mode == "confirm")
    }

    public static func attachArguments(_ profile: ServerProfile, _ shortcut: Shortcut,
                                       result: LaunchResult) throws -> [String] {
        try arguments(profile, shortcut: shortcut, mode: result.confirmedExisting ? "attachConfirmed" : "attach",
                      sessionToken: result.sessionToken)
    }

    /// Run in a local PTY so the system tool talks directly to the user and agent.
    public static func unlockArguments(_ profile: ServerProfile) throws -> [String] {
        [try identityPath(profile)]
    }

    private struct Response: Decodable {
        let ok: Bool
        let error: String?
        let gpus: [GPUReading]?
        let state: String?
        let detail: String?
        let origin: SessionOrigin?
        let sessionToken: String?
        let code: String?
    }

    private static var invalidResponse: TransportError {
        TransportError("服务器响应格式异常。请确认远端有系统 Python 3，并检查 SSH 登录脚本是否向标准输出写入了额外文字。", reachedServer: true)
    }

    private static func request(_ profile: ServerProfile, shortcut: Shortcut?, mode: String,
                                timeout: TimeInterval, sessionToken: String? = nil) async throws -> Response {
        let arguments = try arguments(profile, shortcut: shortcut, mode: mode, sessionToken: sessionToken)
        let result = try await LocalProcess.run("/usr/bin/ssh", arguments, timeout: timeout)
        if result.status == 255 { throw sshError(result.errors) }
        guard let response = try? JSONDecoder().decode(Response.self, from: result.output) else {
            if result.status != 0 { throw sshError(result.errors) }
            throw invalidResponse
        }
        guard response.ok, result.status == 0 else {
            if shortcut != nil, response.code == "missing" { throw SessionIssue.missing }
            if shortcut != nil, response.code == "collision", let token = response.sessionToken {
                throw SessionIssue.collision(token)
            }
            throw TransportError(clean(response.error ?? "远程操作未能完成。"), reachedServer: true)
        }
        return response
    }

    private static func clean(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.prefix(600)
            .filter { !CharacterSet.controlCharacters.contains($0) }))
    }

    static func sshError(_ errors: Data) -> TransportError {
        let message = String(decoding: errors, as: UTF8.self)
        let lower = message.lowercased()
        if ["host key verification failed", "host identification has changed",
            "no matching host key type", "no ed25519 host key is known",
            "offending ", "no ecdsa host key is known", "no rsa host key is known"]
            .contains(where: lower.contains) {
            return TransportError("主机密钥与已确认指纹不匹配，连接已阻止。请通过可信渠道核实服务器身份。")
        }
        if lower.contains("permission denied") || lower.contains("sign_and_send_pubkey") {
            return TransportError("公钥认证失败。请检查用户名和密钥文件；加密密钥可先用「解锁密钥」加入系统 SSH agent。")
        }
        if ["connection refused", "timed out", "could not resolve hostname", "no route to host",
            "network is unreachable", "connection reset", "connection closed", "closed by remote host",
            "broken pipe", "timeout, server"].contains(where: lower.contains) {
            return TransportError("服务器连接中断或网络不可达。请检查主机、端口和 VPN。", canRetryMonitoring: true)
        }
        if lower.contains("python3") && (lower.contains("not found") || lower.contains("no such file")) {
            return TransportError("服务器缺少 /usr/bin/python3，请联系管理员。", reachedServer: true)
        }
        let detail = clean(message)
        return TransportError(detail.isEmpty ? "SSH 连接已中断。" : "SSH 未完成连接。\n" + detail)
    }

    static func arguments(_ profile: ServerProfile, shortcut: Shortcut?, mode: String,
                          sessionToken: String? = nil, pinDirectory: URL? = nil,
                          language: WorkbenchLanguage = .preferred) throws -> [String] {
        let interactive = mode == "attach" || mode == "attachConfirmed"
        var args = try connectionArguments(profile, interactive: interactive, pinDirectory: pinDirectory)
        args += ["--", try endpoint(profile)]
        var payload = ["mode": mode]
        switch mode {
        case "gpu", "watchGPU":
            guard shortcut == nil else { throw invalidResponse }
        case "ensure", "create", "attach", "attachConfirmed", "confirm", "reconnect":
            guard let shortcut, shortcut.serverID == profile.id else {
                throw TransportError("快捷方式与当前服务器不匹配。")
            }
            payload["language"] = language.rawValue
            if mode != "ensure" && mode != "create" {
                guard let sessionToken, !sessionToken.isEmpty else { throw invalidResponse }
                payload["sessionToken"] = sessionToken
            }
            payload.merge(["socketID": shortcut.socketID, "sessionID": shortcut.sessionID,
                "name": shortcut.name, "environment": shortcut.environment, "directory": shortcut.directory,
                "conda": profile.conda]) { _, new in new }
        default:
            throw TransportError("不支持的自动操作。")
        }
        let data = try JSONEncoder().encode(payload)
        guard data.count <= 16_384 else { throw TransportError("快捷方式内容超过大小限制。") }
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        args.append("exec /usr/bin/python3 -I -B -S -c " + (try remoteSource.get()) + " '" + encoded + "'")
        return args
    }

    static func connectionArguments(_ profile: ServerProfile, interactive: Bool = false,
                                    pinDirectory: URL? = nil) throws -> [String] {
        let host = try endpoint(profile)
        let username = profile.username
        guard !username.isEmpty, username.utf8.count <= 128, !username.hasPrefix("-"),
              username.utf8.allSatisfy({ asciiAlnum($0) || [45, 46, 95].contains($0) }) else {
            throw TransportError("SSH 用户名只支持字母、数字、横线、下划线和点。")
        }
        guard let pin = profile.pin, pin.host == host, pin.port == profile.port,
              pin.hasValidKey, let algorithms = pin.algorithms else {
            throw TransportError("请先核对此主机和端口的服务器指纹。")
        }
        let keyPath = try identityPath(profile)
        let directory = try pinDirectory ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GPUWorkbench/HostKeys", isDirectory: true)
        let pinFile = try installPin(pin, in: directory)
        let knownHosts = pinFile.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%")
        guard !knownHosts.contains("${"), !hasControl(knownHosts) else {
            throw TransportError("本地应用数据路径包含 SSH 无法安全处理的字符。")
        }
        let options = ["BatchMode=yes", "UseKeychain=yes", "PreferredAuthentications=publickey",
            "IdentitiesOnly=yes", "PasswordAuthentication=no", "KbdInteractiveAuthentication=no",
            "StrictHostKeyChecking=yes", "HostKeyAlias=" + pinAlias, "HostKeyAlgorithms=" + algorithms,
            "UserKnownHostsFile=\"" + knownHosts + "\"", "GlobalKnownHostsFile=/dev/null",
            "VerifyHostKeyDNS=no", "UpdateHostKeys=no", "ForwardAgent=no", "ForwardX11=no",
            "ClearAllForwardings=yes", "PermitLocalCommand=no", "EscapeChar=none",
            "ControlMaster=no", "ControlPath=none", "ConnectTimeout=8", "ConnectionAttempts=1",
            "ServerAliveInterval=15", "ServerAliveCountMax=2", "LogLevel=ERROR"]
        var args = ["-F", "/dev/null", interactive ? "-tt" : "-T"]
        for option in options { args += ["-o", option] }
        args += ["-p", String(profile.port), "-l", username, "-i", keyPath]
        return args
    }

    private static let remoteSource: Result<String, Error> = Result {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let url = bundle.url(forResource: "remote", withExtension: "py") else {
            throw TransportError("应用资源缺少远程启动程序。")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return "'" + source.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func installPin(_ pin: HostPin, in directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let contents = Data("\(pinAlias) \(pin.keyType) \(pin.publicKey)\n".utf8)
        let name = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let url = directory.appendingPathComponent(name)
        // Concurrent connects may publish the same immutable key. Atomic replacement always contains identical bytes.
        if (try? Data(contentsOf: url)) != contents {
            try contents.write(to: url, options: .atomic)
        }
        return url
    }

    private static func identityPath(_ profile: ServerProfile) throws -> String {
        let path = (profile.keyPath as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), !path.contains("%"), !path.contains("${"), !hasControl(path) else {
            throw TransportError("请选择绝对路径的本地密钥文件，路径不能包含 SSH 替换符或控制字符。")
        }
        let url = URL(fileURLWithPath: path)
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: path) else {
            throw TransportError("无法读取选中的密钥文件，请重新选择。")
        }
        return path
    }

    private static func endpoint(_ profile: ServerProfile) throws -> String {
        let host = profile.host.lowercased()
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        var v6 = in6_addr()
        let ipv6 = inet_pton(AF_INET6, host, &v6) == 1
        let dns = !host.isEmpty && host.utf8.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { asciiAlnum($0) || $0 == 45 }
        }
        guard !hasControl(host), !host.contains("\0"), (1...65535).contains(profile.port), ipv6 || dns else {
            throw TransportError("请输入有效的主机名、IPv4 或 IPv6 地址和 SSH 端口。")
        }
        return host
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func asciiAlnum(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value)
    }
}

struct ProcessOutput: Sendable {
    let output: Data
    let errors: Data
    let status: Int32
}

/// Runs a fixed system tool and drains both output streams concurrently.
final class LocalProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stopped: Error?

    typealias LineReceiver = @Sendable (Data) throws -> Void

    static func run(_ executable: String, _ args: [String], timeout: TimeInterval?,
                    onLine: LineReceiver? = nil) async throws -> ProcessOutput {
        let runner = LocalProcess()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try runner.execute(executable, args, timeout: timeout, onLine: onLine)
                    })
                }
            }
        } onCancel: {
            runner.stop(CancellationError())
        }
    }

    private func stop(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if stopped == nil { stopped = error }
        if process.isRunning { process.terminate() }
    }

    private func execute(_ executable: String, _ args: [String], timeout: TimeInterval?,
                         onLine: LineReceiver?) throws -> ProcessOutput {
        let out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
                   "SSH_ASKPASS_REQUIRE": "never", "HOME": NSHomeDirectory()]
        if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { env["SSH_AUTH_SOCK"] = socket }
        process.environment = env
        lock.lock()
        do {
            if let stopped { throw stopped }
            try process.run()
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        let timer = DispatchWorkItem { [weak self] in
            self?.stop(TransportError("操作超时，请检查网络和服务器状态。", canRetryMonitoring: true))
        }
        if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer) }
        defer { timer.cancel() }

        let group = DispatchGroup()
        let errorBytes = Capture()
        group.enter()
        DispatchQueue.global().async {
            errorBytes.read(err.fileHandleForReading)
            group.leave()
        }
        let output = Capture()
        if let onLine {
            do { try Self.readLines(out.fileHandleForReading, receive: onLine) }
            catch { stop(error) }
        } else {
            output.read(out.fileHandleForReading)
        }
        process.waitUntilExit()
        group.wait()
        lock.lock()
        let failure = stopped
        lock.unlock()
        if let failure { throw failure }
        guard !output.truncated else { throw TransportError("服务器响应超过大小限制。") }
        return ProcessOutput(output: output.data, errors: errorBytes.data, status: process.terminationStatus)
    }

    private static func readLines(_ handle: FileHandle, receive: LineReceiver) throws {
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&descriptor, 1, 30_000)
            if ready == 0 {
                throw TransportError("GPU 监控长时间没有收到数据。", canRetryMonitoring: true)
            }
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { return }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                try receive(Data(pending[..<newline]))
                pending.removeSubrange(...newline)
            }
            guard pending.count <= 1_048_576 else { throw TransportError("GPU 数据帧超过大小限制。") }
        }
    }

    private final class Capture: @unchecked Sendable {
        var data = Data()
        var truncated = false
        func read(_ handle: FileHandle) {
            while let bytes = try? handle.read(upToCount: 16_384), !bytes.isEmpty {
                let remaining = 1_048_576 - data.count
                if bytes.count > remaining { truncated = true }
                data.append(bytes.prefix(remaining))
            }
        }
    }
}
