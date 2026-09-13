import Foundation
import Network

/// 本地 SOCKS5 中继
///
/// 浏览器通过 PAC 连到这里,中继解析出目标域名后再连上游代理(ssh -D 起的本地
/// SOCKS5,或服务器上现成的 SOCKS5),在中间统计双向字节数并记录连接日志。
/// 只处理 CONNECT 命令,`ssh -D` 本身也只支持 TCP CONNECT。
final class SOCKS5Relay: @unchecked Sendable {
    enum RelayError: Error {
        case closed
        case badRequest
        case unsupportedCommand
        case upstreamRejected(UInt8)
    }

    private static let bufferSize = 65536

    /// 连上游用的参数:加连接超时,免得隧道刚断时请求一直挂着
    private static let upstreamParameters: NWParameters = {
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 10
        options.noDelay = true
        return NWParameters(tls: nil, tcp: options)
    }()

    let listenPort: UInt16
    private let upstreamHost: String
    private let upstreamPort: UInt16
    private let monitor: TrafficMonitor
    private let queue = DispatchQueue(label: "dev.speedlane.relay", qos: .userInitiated)

    private var listener: NWListener?

    init(listenPort: UInt16, upstreamHost: String, upstreamPort: UInt16, monitor: TrafficMonitor) {
        self.listenPort = listenPort
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.monitor = monitor
    }

    // MARK: - 生命周期

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只监听回环地址,不暴露到局域网
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: listenPort)!
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handle(client: connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 单个连接的处理流程

    private func handle(client: NWConnection) async {
        client.start(queue: queue)
        do {
            try await waitReady(client)
            try await negotiate(client)
            let (request, host, port) = try await readRequest(client)

            let id = monitor.beginConnection(host: host, port: port)
            let upstream = NWConnection(
                host: NWEndpoint.Host(upstreamHost),
                port: NWEndpoint.Port(rawValue: upstreamPort)!,
                using: Self.upstreamParameters
            )
            upstream.start(queue: queue)

            do {
                try await waitReady(upstream)
                try await handshakeUpstream(upstream)
                try await send(request, to: upstream)
                let reply = try await readReply(upstream)
                try await send(reply, to: client)
                // 上游返回非 0 表示目标连不上,如实转给客户端后结束
                if reply.count > 1, reply[1] != 0x00 {
                    monitor.endConnection(id: id, error: Self.replyMessage(reply[1]))
                    client.cancel()
                    upstream.cancel()
                    return
                }
            } catch {
                // 上游握手失败:给客户端回一个标准的失败应答,避免浏览器一直等
                try? await send(Self.failureReply, to: client)
                monitor.endConnection(id: id, error: Self.describe(error))
                client.cancel()
                upstream.cancel()
                return
            }

            await relay(client: client, upstream: upstream, id: id)
        } catch {
            client.cancel()
        }
    }

    /// SOCKS5 握手:只接受"无需认证",本地回环连接不做额外鉴权
    private func negotiate(_ client: NWConnection) async throws {
        let header = try await receiveExactly(2, from: client)
        guard header[header.startIndex] == 0x05 else { throw RelayError.badRequest }
        let methodCount = Int(header[header.startIndex + 1])
        if methodCount > 0 {
            _ = try await receiveExactly(methodCount, from: client)
        }
        try await send(Data([0x05, 0x00]), to: client)
    }

    /// 读取 CONNECT 请求,返回原始字节(原样转发给上游)和解析出的目标
    private func readRequest(_ client: NWConnection) async throws -> (Data, String, Int) {
        let head = try await receiveExactly(4, from: client)
        let base = head.startIndex
        guard head[base] == 0x05 else { throw RelayError.badRequest }
        guard head[base + 1] == 0x01 else { throw RelayError.unsupportedCommand }

        let addressType = head[base + 3]
        var request = head
        let host: String

        switch addressType {
        case 0x01:
            let raw = try await receiveExactly(4, from: client)
            request.append(raw)
            host = raw.map(String.init).joined(separator: ".")
        case 0x03:
            let lengthByte = try await receiveExactly(1, from: client)
            request.append(lengthByte)
            let length = Int(lengthByte[lengthByte.startIndex])
            let raw = try await receiveExactly(length, from: client)
            request.append(raw)
            host = String(data: raw, encoding: .utf8) ?? "?"
        case 0x04:
            let raw = try await receiveExactly(16, from: client)
            request.append(raw)
            host = Self.formatIPv6(raw)
        default:
            throw RelayError.badRequest
        }

        let portBytes = try await receiveExactly(2, from: client)
        request.append(portBytes)
        let portBase = portBytes.startIndex
        let port = Int(portBytes[portBase]) << 8 | Int(portBytes[portBase + 1])
        return (request, host, port)
    }

    /// 以客户端身份完成对上游代理的握手
    private func handshakeUpstream(_ upstream: NWConnection) async throws {
        try await send(Data([0x05, 0x01, 0x00]), to: upstream)
        let response = try await receiveExactly(2, from: upstream)
        let base = response.startIndex
        guard response[base] == 0x05, response[base + 1] == 0x00 else {
            throw RelayError.upstreamRejected(response[base + 1])
        }
    }

    /// 读取上游对 CONNECT 的完整应答(地址部分是变长的)
    private func readReply(_ upstream: NWConnection) async throws -> Data {
        let head = try await receiveExactly(4, from: upstream)
        var reply = head
        let base = head.startIndex
        switch head[base + 3] {
        case 0x01: reply.append(try await receiveExactly(4, from: upstream))
        case 0x03:
            let lengthByte = try await receiveExactly(1, from: upstream)
            reply.append(lengthByte)
            reply.append(try await receiveExactly(Int(lengthByte[lengthByte.startIndex]), from: upstream))
        case 0x04: reply.append(try await receiveExactly(16, from: upstream))
        default: throw RelayError.badRequest
        }
        reply.append(try await receiveExactly(2, from: upstream))
        return reply
    }

    /// 双向转发
    ///
    /// 某个方向读到 EOF 时只关闭该方向的写端(发 FIN),另一方向继续传完,
    /// 避免服务器先关读端时把还没传完的响应截断。两个方向都结束后才断开连接。
    private func relay(client: NWConnection, upstream: NWConnection, id: UInt64) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pump(from: client, to: upstream) { [weak self] count in
                    self?.monitor.addTraffic(id: id, sent: count)
                }
                Self.finishWriting(upstream)
            }
            group.addTask { [weak self] in
                guard let self else { return }
                await self.pump(from: upstream, to: client) { [weak self] count in
                    self?.monitor.addTraffic(id: id, received: count)
                }
                Self.finishWriting(client)
            }
            await group.waitForAll()
        }
        client.cancel()
        upstream.cancel()
        monitor.endConnection(id: id)
    }

    /// 关闭写端:告诉对端"我不会再发数据了",但仍可继续接收
    private static func finishWriting(_ connection: NWConnection) {
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .idempotent
        )
    }

    private func pump(
        from source: NWConnection,
        to destination: NWConnection,
        onBytes: @escaping (Int) -> Void
    ) async {
        while true {
            guard let data = try? await receiveSome(from: source), !data.isEmpty else { return }
            onBytes(data.count)
            do {
                try await send(data, to: destination)
            } catch {
                return
            }
        }
    }

    // MARK: - NWConnection 的 async 包装

    private func waitReady(_ connection: NWConnection) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume() }
                case .failed(let error):
                    if once.take() { continuation.resume(throwing: error) }
                // 连接被拒绝时 Network.framework 会进入等待重试,
                // 对代理上游来说等下去没有意义,直接当失败处理并立刻告诉客户端
                case .waiting(let error):
                    if once.take() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.take() { continuation.resume(throwing: RelayError.closed) }
                default:
                    break
                }
            }
        }
    }

    /// 读满指定字节数,不够就一直等;连接关闭时抛出
    private func receiveExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: RelayError.closed)
                }
            }
        }
    }

    /// 读一段可用数据,返回空表示对端已关闭
    private func receiveSome(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.bufferSize) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - 杂项

    /// 上游不可用时回给客户端的标准失败应答
    private static let failureReply = Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])

    private static func replyMessage(_ code: UInt8) -> String {
        switch code {
        case 0x02: return "连接不被允许"
        case 0x03: return "网络不可达"
        case 0x04: return "主机不可达"
        case 0x05: return "目标拒绝连接"
        case 0x06: return "TTL 超时"
        case 0x08: return "地址类型不支持"
        default: return "代理返回错误(代码 \(code))"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let relayError = error as? RelayError {
            switch relayError {
            case .closed: return "隧道连接已关闭"
            case .badRequest: return "请求格式错误"
            case .unsupportedCommand: return "不支持的 SOCKS 命令"
            case .upstreamRejected(let code): return "隧道拒绝握手(代码 \(code))"
            }
        }
        if case .posix(let code)? = error as? NWError {
            switch code {
            case .ECONNREFUSED: return "隧道未就绪(连接被拒绝)"
            case .ETIMEDOUT: return "连接隧道超时"
            case .ECONNRESET: return "隧道连接被重置"
            case .ENETDOWN, .ENETUNREACH: return "网络不可用"
            case .EHOSTUNREACH: return "隧道主机不可达"
            default: return "隧道连接失败(错误码 \(code.rawValue))"
            }
        }
        return error.localizedDescription
    }

    private static func formatIPv6(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 2)
            .map { index -> String in
                let base = data.startIndex + index
                return String(format: "%x", Int(data[base]) << 8 | Int(data[base + 1]))
            }
            .joined(separator: ":")
    }
}

/// 保证 continuation 只被 resume 一次
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
