import Foundation

/// 管理 `ssh -N -D` 动态端口转发进程,在本地提供 SOCKS5 代理
@MainActor
final class SSHTunnel: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    /// 隧道意外退出时的回调(启动失败或运行中断开)
    var onFailure: ((String) -> Void)?

    private var process: Process?
    private var confirmTask: Task<Void, Never>?

    // MARK: - 构建 ssh 进程

    /// 密码登录借助 SSH_ASKPASS:密码通过环境变量传给辅助脚本,不出现在命令行参数里
    private nonisolated static func askPassScriptURL() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedLane", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("askpass.sh")
        let script = "#!/bin/sh\nprintf '%s' \"$SPEEDLANE_SSH_PW\"\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    nonisolated static func makeProcess(
        server: ServerConfig,
        password: String?,
        extraArguments: [String],
        remoteCommand: [String] = []
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args: [String] = [
            "-p", "\(server.sshPort)",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if let password, !password.isEmpty {
            args += [
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
            ]
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = try askPassScriptURL().path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
            env["SPEEDLANE_SSH_PW"] = password
            process.environment = env
        } else {
            // 密钥登录:禁止交互,避免卡在密码输入
            args += ["-o", "BatchMode=yes"]
        }
        args += extraArguments
        args.append("\(server.user)@\(server.host)")
        args += remoteCommand
        process.arguments = args
        return process
    }

    // MARK: - 孤儿进程清理

    /// 隧道进程 PID 记录文件:App 被强杀时 ssh 子进程会存活并继续占用端口,
    /// 下次连接前根据此文件回收
    private nonisolated static var pidFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedLane", isDirectory: true)
            .appendingPathComponent("tunnel.pid")
    }

    /// 清理上次 App 异常退出遗留的 ssh 隧道进程(严格校验命令行,不误杀其他程序)
    nonisolated static func reapOrphan() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let (status, command) = runCommand("/bin/ps", ["-p", "\(pid)", "-o", "command="])
        if status == 0, command.contains("/usr/bin/ssh"), command.contains("-D 127.0.0.1:") {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    private nonisolated static func writePidFile(_ pid: Int32) {
        let url = pidFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 隧道

    func start(server: ServerConfig, localPort: Int, password: String?) {
        stop()
        state = .starting

        let pipe = Pipe()
        let process: Process
        do {
            process = try Self.makeProcess(
                server: server,
                password: password,
                extraArguments: [
                    "-N",
                    "-D", "127.0.0.1:\(localPort)",
                    "-o", "ExitOnForwardFailure=yes",
                ]
            )
        } catch {
            state = .failed(error.localizedDescription)
            onFailure?(error.localizedDescription)
            return
        }
        process.standardError = pipe
        process.standardOutput = Pipe()

        process.terminationHandler = { [weak self] proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor [weak self] in
                self?.processDidExit(proc, message: message)
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            onFailure?(error.localizedDescription)
            return
        }

        self.process = process
        Self.writePidFile(process.processIdentifier)

        // ssh -N 成功后不会有任何输出:2 秒后进程仍存活即视为已连接
        confirmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.process?.isRunning == true, self.state == .starting {
                self.state = .running
            }
        }
    }

    func stop() {
        confirmTask?.cancel()
        confirmTask = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        try? FileManager.default.removeItem(at: Self.pidFileURL)
        state = .stopped
    }

    private func processDidExit(_ proc: Process, message: String) {
        // 只处理当前进程的退出(stop() 后残留的回调忽略)
        guard proc === process else { return }
        process = nil
        let reason = message.isEmpty ? "SSH 连接已断开(退出码 \(proc.terminationStatus))" : message
        state = .failed(reason)
        onFailure?(reason)
    }

    // MARK: - 测试连接

    /// 在服务器上执行 echo ok 验证连通性;返回 nil 表示成功,否则为错误信息
    nonisolated static func testConnection(server: ServerConfig, password: String?) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pipe = Pipe()
                let process: Process
                do {
                    process = try makeProcess(
                        server: server,
                        password: password,
                        extraArguments: [],
                        remoteCommand: ["echo", "ok"]
                    )
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, output.contains("ok") {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: output.isEmpty
                        ? "连接失败(退出码 \(process.terminationStatus))"
                        : output)
                }
            }
        }
    }
}
