import Foundation
import Network

/// 极简本地 HTTP 服务,只在 127.0.0.1 上向系统提供 PAC 文件
final class PACServer {
    let port: UInt16
    private var listener: NWListener?
    private let pacProvider: () -> String

    init(port: UInt16 = 17890, pacProvider: @escaping () -> String) {
        self.port = port
        self.pacProvider = pacProvider
    }

    var baseURL: String { "http://127.0.0.1:\(port)/proxy.pac" }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 只监听回环地址,不暴露到局域网
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let body = Data(self.pacProvider().utf8)
            let header = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/x-ns-proxy-autoconfig\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(
                content: Data(header.utf8) + body,
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
    }
}

enum PACBuilder {
    /// 生成 PAC 脚本:命中列表内域名(含子域名)走代理,其余全部直连
    static func build(domains: [String], proxyLine: String) -> String {
        let list = domains.map { "\"\($0)\"" }.joined(separator: ",\n  ")
        return """
        var domains = [
          \(list)
        ];

        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          for (var i = 0; i < domains.length; i++) {
            var d = domains[i];
            if (host === d ||
                (host.length > d.length &&
                 host.substring(host.length - d.length - 1) === "." + d)) {
              return "\(proxyLine)";
            }
          }
          return "DIRECT";
        }
        """
    }
}
