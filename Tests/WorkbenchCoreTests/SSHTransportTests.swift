import Foundation
import Darwin
import SwiftTerm
import Testing
@testable import WorkbenchCore

struct SSHTransportTests {
    private func key(_ fill: UInt8) -> String {
        var blob = Data([0, 0, 0, 11])
        blob.append(contentsOf: "ssh-ed25519".utf8)
        blob.append(contentsOf: [0, 0, 0, 32])
        blob.append(Data(repeating: fill, count: 32))
        return blob.base64EncodedString()
    }

    private func fixture(_ body: (URL, ServerProfile) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPU Workbench fixture " + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let identity = base.appendingPathComponent("identity file")
        try Data("local test fixture only".utf8).write(to: identity)
        let pin = HostPin(host: "fixture.invalid", port: 2202, keyType: "ssh-ed25519", publicKey: key(17))
        let profile = ServerProfile(label: "Test", host: "fixture.invalid", port: 2202,
                                    username: "researcher", keyPath: identity.path, pin: pin)
        try body(base, profile)
    }

    @Test func pinParsingAndRotation() throws {
        let a = key(17), b = key(91)
        let pin = try #require(SSHTransport.candidate(
            in: Data("# SSH-2.0\nfixture ssh-ed25519 \(a)\n".utf8), host: "fixture", port: 22))
        let changed = try #require(SSHTransport.candidate(
            in: Data("fixture ssh-ed25519 \(b)\n".utf8), host: "fixture", port: 22))
        #expect(pin.fingerprint.hasPrefix("SHA256:"))
        #expect(pin.fingerprint != changed.fingerprint)
        #expect(SSHTransport.candidate(in: Data("fixture ssh-rsa \(a)\n".utf8), host: "fixture", port: 22) == nil)
        let reason = SSHTransport.sshError(Data("Host key verification failed.".utf8))
        #expect(reason.localizedDescription.contains("指纹"))
        #expect(!reason.reachedServer)
        #expect(!reason.canRetryMonitoring)
        #expect(!SSHTransport.sshError(Data("Permission denied (publickey).".utf8)).canRetryMonitoring)
        #expect(SSHTransport.sshError(Data("Connection reset by peer".utf8)).canRetryMonitoring)
        #expect(SSHTransport.sshError(Data("Connection timed out".utf8)).canRetryMonitoring)
    }

    @Test func enforcedOpenSSHConfiguration() throws {
        try fixture { base, profile in
            let keys = base.appendingPathComponent("known hosts")
            let args = try SSHTransport.arguments(profile, shortcut: nil, mode: "gpu", pinDirectory: keys)
            #expect(args.prefix(3) == ["-F", "/dev/null", "-T"])
            #expect(args.contains("HostKeyAlgorithms=ssh-ed25519"))
            let files = try FileManager.default.contentsOfDirectory(at: keys, includingPropertiesForKeys: nil)
            #expect(files.count == 1)
            let saved = try String(contentsOf: #require(files.first), encoding: .utf8)
            #expect(saved == "gpuworkbench-pinned-host ssh-ed25519 \(key(17))\n")

            // -G evaluates the system OpenSSH option parser without connecting to a network.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-G"] + args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
            let lines = Set(output.split(separator: "\n").map(String.init))
            for line in ["hostkeyalias gpuworkbench-pinned-host", "stricthostkeychecking true",
                         "clearallforwardings yes", "forwardagent no", "forwardx11 no",
                         "batchmode yes", "identitiesonly yes", "preferredauthentications publickey",
                         "permitlocalcommand no", "updatehostkeys false", "globalknownhostsfile /dev/null",
                         "port 2202", "user researcher"] {
                #expect(lines.contains(line), "OpenSSH config missing \(line)")
            }
            let prefix = "userknownhostsfile "
            let knownLine = try #require(lines.first { $0.hasPrefix(prefix) })
            let effective = URL(fileURLWithPath: String(knownLine.dropFirst(prefix.count)))
            #expect(effective.resolvingSymlinksInPath().path == files[0].resolvingSymlinksInPath().path)
        }
    }

    @Test func fieldsTravelAsDataAcrossBothShells() throws {
        try fixture { base, profile in
            let directory = "/work/实验 (A)/quote'&space"
            let shortcut = Shortcut(serverID: profile.id, title: "analysis", name: "work",
                                    environment: "science", directory: directory)
            let args = try SSHTransport.arguments(profile, shortcut: shortcut, mode: "attach", pinDirectory: base)
            #expect(args.contains("-tt"))
            let command = try #require(args.last)
            #expect(command.hasPrefix("exec /usr/bin/python3 -I -B -S -c '"))
            #expect(!command.contains(directory))
            let tail = try #require(command.dropLast().split(separator: "'").last)
            let raw = String(tail).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let data = try #require(Data(base64Encoded: raw))
            let body = try JSONDecoder().decode([String: String].self, from: data)
            #expect(body["mode"] == "attach")
            #expect(body["directory"] == directory)
            #expect(body["socketID"] == shortcut.socketID)
            #expect(body["sessionID"] == shortcut.sessionID)
        }
    }

    @Test func rejectsUnexpectedTargetAndOperation() throws {
        try fixture { base, profile in
            var changed = profile
            changed.port += 1
            #expect(throws: TransportError.self) {
                try SSHTransport.arguments(changed, shortcut: nil, mode: "gpu", pinDirectory: base)
            }
            changed = profile
            changed.host = "-unsupported"
            #expect(throws: TransportError.self) {
                try SSHTransport.arguments(changed, shortcut: nil, mode: "gpu", pinDirectory: base)
            }
            #expect(throws: TransportError.self) {
                try SSHTransport.arguments(profile, shortcut: nil, mode: "other", pinDirectory: base)
            }
            let other = Shortcut(serverID: UUID(), title: "Other", name: "other", environment: "env", directory: "/work")
            #expect(throws: TransportError.self) {
                try SSHTransport.arguments(profile, shortcut: other, mode: "ensure", pinDirectory: base)
            }
        }
    }

    /// Opt in only for an ephemeral Linux sshd listening on a forwarded loopback port.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GPUWORKBENCH_E2E"] == "1"))
    func isolatedLinuxRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(Int(env["GPUWORKBENCH_E2E_PORT"] ?? ""))
        try #require((1024...65535).contains(port))
        let expectedPin = try #require(env["GPUWORKBENCH_E2E_PIN"])
        let key = try #require(env["GPUWORKBENCH_E2E_KEY"])
        let testHome = try #require(env["CFFIXED_USER_HOME"])
        let temporaryRoots = [URL(fileURLWithPath: "/private/tmp"), FileManager.default.temporaryDirectory]
            .map { $0.resolvingSymlinksInPath().path + "/" }
        for path in [key, testHome] {
            let absolute = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            try #require(temporaryRoots.contains(where: absolute.hasPrefix))
        }
        var profile = ServerProfile(label: "Isolated fixture", host: "127.0.0.1", port: port,
                                    username: "tester", keyPath: key, conda: "/opt/fixture-conda")
        let pin = try await SSHTransport.scanPin(profile)
        try #require(pin.fingerprint == expectedPin)
        profile.pin = pin
        let metrics = try await SSHTransport.fetchGPUs(profile)
        try #require(metrics.contains { !$0.name.isEmpty && $0.memoryTotal != nil })
        try await checkMonitorCancellation(profile, expected: metrics)
        let shortcut = Shortcut(serverID: profile.id, title: "Fixture", name: "fixture",
                                environment: "plain", directory: "/home/tester/work")
        let first = try await SSHTransport.ensure(profile, shortcut)
        try #require(first.state == "ready", "\(first.detail)")
        let pid = try shellPIDThenDetach(profile: profile, shortcut: shortcut)
        let resumed = try await SSHTransport.ensure(profile, shortcut)
        try #require(resumed.state == "ready", "\(resumed.detail)")
        let resumedPID = try shellPIDThenDetach(profile: profile, shortcut: shortcut)
        #expect(resumedPID == pid)
    }

    private func checkMonitorCancellation(_ profile: ServerProfile, expected: [GPUReading]) async throws {
        let consumer = Task { () throws -> Set<Int32> in
            var frames = SSHTransport.gpuFrames(profile).makeAsyncIterator()
            for _ in 0..<2 {
                let next = try await frames.next()
                try #require(next == expected)
            }
            let workers = try localSSHChildren()
            try #require(workers.count == 1)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let afterCancellation = try await frames.next()
                try #require(afterCancellation == nil)
            } catch is CancellationError {}
            return workers
        }
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            consumer.cancel()
        }
        defer { deadline.cancel() }
        let workers = try await consumer.value
        // Consumer cancellation must also close its SSH child. Inspect this test process's children only.
        for _ in 0..<50 {
            if try workers.isDisjoint(with: localSSHChildren()) { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        throw TransportError("取消 GPU 监控后，本地测试 SSH 客户端仍然存活。")
    }

    private func localSSHChildren() throws -> Set<Int32> {
        let command = Process(), output = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        command.arguments = ["-P", String(getpid()), "-x", "ssh"]
        command.standardOutput = output
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        try #require([0, 1].contains(command.terminationStatus))
        return Set(String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
    }

    private func shellPIDThenDetach(profile: ServerProfile, shortcut: Shortcut) throws -> String {
        var master: Int32 = -1, slave: Int32 = -1
        var size = winsize(ws_row: 28, ws_col: 180, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.ENXIO) }
        let terminal = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        let childTTY = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try SSHTransport.attachArguments(profile, shortcut)
        process.standardInput = childTTY
        process.standardOutput = childTTY
        process.standardError = childTTY
        process.environment = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try childTTY.close()
        defer { if process.isRunning { process.terminate() } }

        // tmux replays history on attach and sends cursor movements between pieces of text.
        // Challenge each attachment separately and inspect the same emulated screen as the app.
        let token = UUID().uuidString.prefix(8)
        let responder = PTYResponder(terminal)
        let emulator = Terminal(delegate: responder, options: TerminalOptions(cols: 180, rows: 28, scrollback: 0))
        let expression = try NSRegularExpression(
            pattern: #"GWB_\#(token)\|/home/tester/work\|/opt/fixture-conda/envs/plain\|([0-9]+)\|END_GWB"#)
        var sentQuery = false
        var screen = ""
        var shellPID: String?
        var finalOutput = Data()
        let limit = Date().addingTimeInterval(20)
        while Date() < limit {
            if !process.isRunning { break }
            var event = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            if poll(&event, 1, 100) <= 0 {
                if !process.isRunning { break }
                continue
            }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(master, &buffer, buffer.count)
            if count <= 0 {
                if !process.isRunning { break }
                continue
            }
            if shellPID != nil {
                finalOutput.append(contentsOf: buffer.prefix(count))
                if finalOutput.count > 8192 { finalOutput.removeFirst(finalOutput.count - 8192) }
            }
            emulator.feed(buffer: buffer.prefix(count))
            if let error = responder.error { throw error }
            screen = String(decoding: emulator.getBufferAsData(), as: UTF8.self)
            if !sentQuery && screen.contains("tester@") {
                let query = #"printf '\nGWB_\#(token)|%s|%s|%s|END_GWB\n' "$PWD" "$CONDA_PREFIX" "$BASHPID""#
                try terminal.write(contentsOf: Data((query + "\r").utf8))
                sentQuery = true
            }
            if shellPID == nil,
               let match = expression.firstMatch(in: screen, range: NSRange(screen.startIndex..., in: screen)),
               let range = Range(match.range(at: 1), in: screen) {
                shellPID = String(screen[range])
                // Use tmux's detach command in this fixture's only attached client. Keyboard
                // prefixes have paste-detection timing, which an automated PTY does not reproduce.
                try terminal.write(contentsOf: Data("tmux detach-client\r".utf8))
            }
        }
        if let shellPID {
            // Drain the PTY through EOF before waiting for the OpenSSH child to finish restoring it.
            _ = exited.wait(timeout: .now() + 2)
            if !process.isRunning, process.terminationStatus == 0 { return shellPID }
            let status = process.isRunning ? "running" : String(process.terminationStatus)
            throw TransportError("测试终端分离失败。SSH 状态 " + status + "，屏幕 " + screen +
                "，末次输出 " + String(decoding: finalOutput, as: UTF8.self).debugDescription)
        }
        throw TransportError("测试终端未返回本次查询结果。已发送查询 \(sentQuery)。最终屏幕 " + screen)
    }

    private final class PTYResponder: TerminalDelegate {
        let handle: FileHandle
        var error: Error?

        init(_ handle: FileHandle) { self.handle = handle }

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            do { try handle.write(contentsOf: Data(data)) }
            catch { self.error = error }
        }
    }
}
