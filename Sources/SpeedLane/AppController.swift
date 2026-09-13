import Foundation
import SwiftUI

/// 总控制:串联 SSH 隧道、PAC 服务和系统代理设置
@MainActor
final class AppController: ObservableObject {
    let settings: AppSettings
    let tunnel = SSHTunnel()
    /// 流量统计与连接日志(数据来自本地 SOCKS5 中继)
    let monitor = TrafficMonitor()

    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    /// 连接生命周期状态,驱动按钮的连接动画与文案
    @Published private(set) var phase: Phase = .disconnected
    @Published var lastError: String?

    /// 是否处于已连接状态(供菜单栏图标、菜单文案等读取)
    var isEnabled: Bool { phase == .connected }
    /// 正在连接或断开中(此时按钮显示动画且禁用,避免重复点击)
    var isBusy: Bool { phase == .connecting || phase == .disconnecting }

    /// 启用时锁定的服务器配置(设置里改动不影响当前连接,直到重连)
    private(set) var activeServer: ServerConfig?

    private var pacServer: PACServer?
    /// 每次内容变化时递增,拼进 PAC URL 让系统强制重新拉取
    private var pacVersion = 0
    /// 本次连接实际使用的本地 SOCKS 端口(首选端口被占用时自动换用空闲端口)
    /// 走中继时这是中继的监听端口,PAC 与 git 都指向它
    private var activeLocalPort = 1080
    /// ssh -D 实际监听的端口(中继的上游),与 activeLocalPort 错开
    private var tunnelPort = 1081
    /// 本地 SOCKS5 中继,负责统计流量与记录连接日志
    private var relay: SOCKS5Relay?
    /// 是否动过系统代理设置:没动过就不必在退出时跑一遍 networksetup
    private var didEnableSystemProxy = false
    /// 退出清理只做一次(退出按钮和 applicationWillTerminate 都会调到)
    private var didTeardown = false

    init(settings: AppSettings) {
        self.settings = settings
        tunnel.onFailure = { [weak self] message in
            guard let self, self.isEnabled else { return }
            Task { @MainActor in
                await self.disable()
                self.lastError = "连接失败:\(message)"
            }
        }
    }

    var usesTunnel: Bool { activeServer?.mode == .sshTunnel }

    /// 当前连接是否有流量统计(HTTP 代理模式不经中继,拿不到数据)
    var hasTrafficStats: Bool { activeServer?.mode.usesRelay ?? false }

    /// 状态文案只由 phase 决定,保证和按钮显示的状态始终一致
    var statusText: String {
        if let lastError { return lastError }
        let name = activeServer?.name ?? ""
        switch phase {
        case .disconnected:
            return "未启用,所有流量直连"
        case .connecting:
            return name.isEmpty ? "正在连接…" : "正在连接 \(name)…"
        case .disconnecting:
            return "正在断开…"
        case .connected:
            if usesTunnel, activeLocalPort != settings.localPort {
                return "已连接 \(name)(端口 \(settings.localPort) 被占用,改用 \(activeLocalPort))"
            }
            return "已连接 \(name),仅所选站点走加速"
        }
    }

    // MARK: - 开关

    /// 按钮/菜单入口:立即返回,真正的连接/断开在后台异步执行,UI 不卡顿
    func toggle(_ on: Bool) {
        guard !isBusy else { return }
        Task { on ? await enable() : await disable() }
    }

    func enable() async {
        guard phase == .disconnected else { return }
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

        // 立刻进入“连接中”,按钮马上显示连接动画
        phase = .connecting
        activeServer = server

        // 中继监听用户配置的端口,PAC 与 git 都指向它;隧道另起一个端口作为中继的上游
        let preferredPort = settings.localPort
        if server.mode.usesRelay {
            guard let port = await runOffMain({ Self.findFreeLocalPort(startingAt: preferredPort) }) else {
                activeServer = nil
                phase = .disconnected
                lastError = "本地端口 \(preferredPort) 起的 20 个端口都被占用,请在“设置 → 通用”修改本地 SOCKS5 端口"
                return
            }
            guard phase == .connecting else { return }
            activeLocalPort = port
        }

        if server.mode == .sshTunnel {
            // 回收上次异常退出遗留的隧道进程、探测可用端口,都是阻塞操作,放后台线程
            await runOffMain { SSHTunnel.reapOrphan() }
            guard phase == .connecting else { return }
            let searchFrom = activeLocalPort + 1
            guard let port = await runOffMain({ Self.findFreeLocalPort(startingAt: searchFrom) }) else {
                activeServer = nil
                phase = .disconnected
                lastError = "本地端口 \(searchFrom) 起的 20 个端口都被占用,请在“设置 → 通用”修改本地 SOCKS5 端口"
                return
            }
            guard phase == .connecting else { return }
            tunnelPort = port
            tunnel.start(server: server, localPort: port, password: password)

            // ssh -N 连上后没有任何输出,需要等进程存活确认才算真正连上;
            // 确认之前不碰系统代理,免得隧道没起来却把流量指过去
            await tunnel.waitUntilSettled()
            guard phase == .connecting else { return }
            if case .failed(let message) = tunnel.state {
                tunnel.stop()
                activeServer = nil
                phase = .disconnected
                lastError = "连接失败:\(message)"
                return
            }
        }

        // 中继夹在浏览器和上游代理之间,流量统计和连接日志都来自这里
        if server.mode.usesRelay {
            let relay = SOCKS5Relay(
                listenPort: UInt16(activeLocalPort),
                upstreamHost: server.mode == .sshTunnel ? "127.0.0.1" : server.host,
                upstreamPort: UInt16(server.mode == .sshTunnel ? tunnelPort : server.remotePort),
                monitor: monitor
            )
            do {
                try relay.start()
            } catch {
                tunnel.stop()
                activeServer = nil
                phase = .disconnected
                lastError = "本地中继启动失败:\(error.localizedDescription)"
                return
            }
            self.relay = relay
        }

        let pacServer = PACServer { [weak self] in
            guard let self else { return "function FindProxyForURL(u,h){return \"DIRECT\";}" }
            return PACBuilder.build(domains: self.settings.activeDomains, proxyLine: self.proxyLine)
        }
        do {
            try pacServer.start()
        } catch {
            stopRelay()
            tunnel.stop()
            activeServer = nil
            phase = .disconnected
            lastError = "本地 PAC 服务启动失败:\(error.localizedDescription)"
            return
        }
        self.pacServer = pacServer

        pacVersion += 1
        let pacURL = "\(pacServer.baseURL)?v=\(pacVersion)"
        // 只要调用过就要负责还原:可能部分服务已设置成功
        didEnableSystemProxy = true
        // networksetup 会对每个网络服务连续调用多次、耗时较久,放后台执行
        if let error = await runOffMain({ SystemProxy.enablePAC(url: pacURL) }) {
            pacServer.stop()
            self.pacServer = nil
            stopRelay()
            tunnel.stop()
            // 回滚已经设置成功的那部分,否则系统代理会指向已关闭的中继
            await runOffMain { SystemProxy.disablePAC() }
            didEnableSystemProxy = false
            activeServer = nil
            phase = .disconnected
            lastError = "设置系统代理失败:\(error)"
            return
        }
        guard phase == .connecting else { return }

        // git 命令行加速始终开启,仅对所选域名生效(逐域名执行 git config,同样放后台)
        let domains = settings.activeDomains
        let gitURL = gitProxyURL
        await runOffMain { GitProxy.apply(domains: domains, proxyURL: gitURL) }

        if server.mode.usesRelay {
            monitor.resetTotals()
            monitor.startSampling()
        }
        phase = .connected
    }

    private func stopRelay() {
        relay?.stop()
        relay = nil
    }

    func disable() async {
        guard phase == .connected || phase == .connecting else { return }
        phase = .disconnecting
        monitor.stopSampling()
        stopRelay()
        tunnel.stop()
        let pac = pacServer
        pacServer = nil
        pac?.stop()
        // 还原系统代理与 git 配置,阻塞命令放后台,主线程保持流畅
        let shouldRestoreProxy = didEnableSystemProxy
        await runOffMain {
            if shouldRestoreProxy { SystemProxy.disablePAC() }
            GitProxy.clear()
        }
        didEnableSystemProxy = false
        activeServer = nil
        phase = .disconnected
    }

    /// 退出流程:本地服务立刻停掉(毫秒级),耗时的系统设置还原放后台,完成后回调
    ///
    /// networksetup 每个网络服务要上百毫秒且内部有锁,机器上有七八个服务时
    /// 同步还原会让退出卡住一秒以上,所以让界面先消失、后台还原完再真正退出。
    /// 退出按钮和系统退出回调都会走到这里,用标志保证只做一次。
    func beginTeardown(completion: @escaping @MainActor @Sendable () -> Void) {
        guard !didTeardown else {
            completion()
            return
        }
        didTeardown = true
        stopLocalServices()

        let shouldRestoreProxy = didEnableSystemProxy
        didEnableSystemProxy = false
        DispatchQueue.global(qos: .userInitiated).async {
            if shouldRestoreProxy { SystemProxy.disablePAC() }
            GitProxy.clear()
            Task { @MainActor in completion() }
        }
    }

    /// 同步拆除,给拿不到异步机会的场景兜底(例如系统强制退出)
    func teardownSync() {
        guard !didTeardown else { return }
        didTeardown = true
        stopLocalServices()
        if didEnableSystemProxy {
            SystemProxy.disablePAC()
            didEnableSystemProxy = false
        }
        GitProxy.clear()
    }

    /// 停掉本机上的隧道、中继与 PAC 服务,都是瞬时操作
    private func stopLocalServices() {
        monitor.stopSampling()
        stopRelay()
        tunnel.stop()
        pacServer?.stop()
        pacServer = nil
        activeServer = nil
        phase = .disconnected
    }

    /// 把阻塞式工作丢到后台线程执行,主线程不卡顿
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    /// 站点勾选变化后调用:已启用时刷新 PAC 与 git 配置(阻塞命令放后台,勾选不卡顿)
    func settingsChanged() {
        guard isEnabled, let pacServer else { return }
        pacVersion += 1
        let pacURL = "\(pacServer.baseURL)?v=\(pacVersion)"
        let domains = settings.activeDomains
        let gitURL = gitProxyURL
        Task { [weak self] in
            await self?.runOffMain {
                _ = SystemProxy.enablePAC(url: pacURL)
                GitProxy.apply(domains: domains, proxyURL: gitURL)
            }
        }
    }

    /// 服务器信息或默认服务器变化:已启用时重建整个链路
    func connectionSettingsChanged() {
        guard isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.disable()
            await self.enable()
        }
    }

    // MARK: - 代理地址

    /// PAC 中的代理指令
    private var proxyLine: String {
        guard let server = activeServer else { return "DIRECT" }
        switch server.mode {
        case .sshTunnel, .remoteSOCKS5:
            // 两种模式都经本地中继,PAC 统一指向中继端口
            return "SOCKS5 127.0.0.1:\(activeLocalPort); SOCKS 127.0.0.1:\(activeLocalPort)"
        case .remoteHTTP:
            return "PROXY \(server.host):\(server.remotePort)"
        }
    }

    /// 从首选端口起找一个空闲的本地端口(bind 探测,最多尝试 20 个)
    private nonisolated static func findFreeLocalPort(startingAt preferred: Int) -> Int? {
        for port in preferred..<min(preferred + 20, 65536) where isPortFree(port) {
            return port
        }
        return nil
    }

    private nonisolated static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 给 git 用的代理 URL(socks5h = 域名也在代理端解析)
    private var gitProxyURL: String {
        guard let server = activeServer else { return "" }
        switch server.mode {
        case .sshTunnel, .remoteSOCKS5:
            return "socks5h://127.0.0.1:\(activeLocalPort)"
        case .remoteHTTP:
            return "http://\(server.host):\(server.remotePort)"
        }
    }
}
