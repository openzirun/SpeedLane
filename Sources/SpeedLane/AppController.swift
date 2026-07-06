import Foundation
import SwiftUI

/// 总控制:串联 SSH 隧道、PAC 服务和系统代理设置
@MainActor
final class AppController: ObservableObject {
    let settings: AppSettings
    let tunnel = SSHTunnel()

    @Published private(set) var isEnabled = false
    @Published var lastError: String?

    /// 启用时锁定的服务器配置(设置里改动不影响当前连接,直到重连)
    private(set) var activeServer: ServerConfig?

    private var pacServer: PACServer?
    /// 每次内容变化时递增,拼进 PAC URL 让系统强制重新拉取
    private var pacVersion = 0

    init(settings: AppSettings) {
        self.settings = settings
        tunnel.onFailure = { [weak self] message in
            guard let self, self.isEnabled else { return }
            self.disable()
            self.lastError = "连接失败:\(message)"
        }
    }

    var usesTunnel: Bool { activeServer?.mode == .sshTunnel }

    var statusText: String {
        if let lastError { return lastError }
        if !isEnabled { return "未启用,所有流量直连" }
        let name = activeServer?.name ?? ""
        if usesTunnel {
            switch tunnel.state {
            case .starting: return "正在连接 \(name)…"
            case .running: return "已连接 \(name),仅所选站点走加速"
            case .stopped, .failed: return "隧道未运行"
            }
        }
        return "已启用 \(name),仅所选站点走加速"
    }

    // MARK: - 开关

    func toggle(_ on: Bool) {
        if on { enable() } else { disable() }
    }

    func enable() {
        lastError = nil
        guard !settings.activeDomains.isEmpty else {
            lastError = "请先勾选至少一个要加速的站点"
            return
        }
        guard let server = settings.defaultServer, !server.host.isEmpty else {
            lastError = "请先在“设置 → 服务器”中添加服务器"
            return
        }

        var password: String?
        if server.mode == .sshTunnel, server.auth == .password {
            password = KeychainStore.password(for: server.id)
            guard let pw = password, !pw.isEmpty else {
                lastError = "服务器「\(server.name)」使用密码登录,请先在设置中填写密码"
                return
            }
        }

        activeServer = server

        if server.mode == .sshTunnel {
            tunnel.start(server: server, localPort: settings.localPort, password: password)
        }

        let pacServer = PACServer { [weak self] in
            guard let self else { return "function FindProxyForURL(u,h){return \"DIRECT\";}" }
            return PACBuilder.build(domains: self.settings.activeDomains, proxyLine: self.proxyLine)
        }
        do {
            try pacServer.start()
        } catch {
            tunnel.stop()
            activeServer = nil
            lastError = "本地 PAC 服务启动失败:\(error.localizedDescription)"
            return
        }
        self.pacServer = pacServer

        pacVersion += 1
        if let error = SystemProxy.enablePAC(url: "\(pacServer.baseURL)?v=\(pacVersion)") {
            pacServer.stop()
            self.pacServer = nil
            tunnel.stop()
            activeServer = nil
            lastError = "设置系统代理失败:\(error)"
            return
        }

        // git 命令行加速始终开启,仅对所选域名生效
        GitProxy.apply(domains: settings.activeDomains, proxyURL: gitProxyURL)

        isEnabled = true
    }

    func disable() {
        SystemProxy.disablePAC()
        pacServer?.stop()
        pacServer = nil
        tunnel.stop()
        GitProxy.clear()
        activeServer = nil
        isEnabled = false
    }

    /// 站点勾选变化后调用:已启用时刷新 PAC 与 git 配置
    func settingsChanged() {
        guard isEnabled else { return }
        pacVersion += 1
        if let pacServer {
            _ = SystemProxy.enablePAC(url: "\(pacServer.baseURL)?v=\(pacVersion)")
        }
        GitProxy.apply(domains: settings.activeDomains, proxyURL: gitProxyURL)
    }

    /// 服务器信息或默认服务器变化:已启用时重建整个链路
    func connectionSettingsChanged() {
        guard isEnabled else { return }
        disable()
        enable()
    }

    // MARK: - 代理地址

    /// PAC 中的代理指令
    private var proxyLine: String {
        guard let server = activeServer else { return "DIRECT" }
        switch server.mode {
        case .sshTunnel:
            return "SOCKS5 127.0.0.1:\(settings.localPort); SOCKS 127.0.0.1:\(settings.localPort)"
        case .remoteSOCKS5:
            return "SOCKS5 \(server.host):\(server.remotePort); SOCKS \(server.host):\(server.remotePort)"
        case .remoteHTTP:
            return "PROXY \(server.host):\(server.remotePort)"
        }
    }

    /// 给 git 用的代理 URL(socks5h = 域名也在代理端解析)
    private var gitProxyURL: String {
        guard let server = activeServer else { return "" }
        switch server.mode {
        case .sshTunnel:
            return "socks5h://127.0.0.1:\(settings.localPort)"
        case .remoteSOCKS5:
            return "socks5h://\(server.host):\(server.remotePort)"
        case .remoteHTTP:
            return "http://\(server.host):\(server.remotePort)"
        }
    }
}
