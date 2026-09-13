import Combine
import Foundation

/// 一条连接记录:中继每接受一个连接就生成一条,只存在内存里,退出即清
struct ConnectionEntry: Identifiable, Equatable {
    enum State: Equatable {
        case active
        case closed
        case failed(String)
    }

    let id: UInt64
    /// 客户端要访问的目标(浏览器走 SOCKS5 时通常是域名,自己解析过 DNS 的工具则是 IP)
    let host: String
    let port: Int
    let startedAt: Date
    /// 上行字节数(本机发往服务器)
    var sent: Int = 0
    /// 下行字节数(服务器返回本机)
    var received: Int = 0
    var state: State = .active
    var endedAt: Date?
}

/// 流量统计与连接日志
///
/// 中继在后台队列高频写入,主线程每秒采样一次发布给界面,
/// 避免每收发一个包就触发一次 SwiftUI 刷新。
final class TrafficMonitor: ObservableObject, @unchecked Sendable {
    /// 日志最多保留的条数,超出丢弃最早的
    private static let logCapacity = 500

    // MARK: - 发布给界面的状态(只在主线程更新)

    /// 最近一秒的上行速率(字节/秒)
    @Published private(set) var uploadRate = 0
    /// 最近一秒的下行速率(字节/秒)
    @Published private(set) var downloadRate = 0
    /// 本次连接以来的累计上行字节数
    @Published private(set) var totalSent = 0
    /// 本次连接以来的累计下行字节数
    @Published private(set) var totalReceived = 0
    /// 连接日志,最新的排在最前
    @Published private(set) var entries: [ConnectionEntry] = []

    // MARK: - 后台写入的数据(全部由 lock 保护)

    private let lock = NSLock()
    private var pendingSent = 0
    private var pendingReceived = 0
    private var cumulativeSent = 0
    private var cumulativeReceived = 0
    private var log: [UInt64: ConnectionEntry] = [:]
    private var order: [UInt64] = []
    private var nextID: UInt64 = 0
    private var logDirty = false

    private var timer: Timer?

    // MARK: - 采样

    /// 开始每秒采样(连接建立时调用)
    @MainActor
    func startSampling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // common 模式:菜单弹出、窗口拖动时计时器也继续跑
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 停止采样并把速率归零(断开时调用,日志保留供查看)
    @MainActor
    func stopSampling() {
        timer?.invalidate()
        timer = nil
        lock.lock()
        pendingSent = 0
        pendingReceived = 0
        // 仍在传输中的连接统一标记为已结束
        for id in order where log[id]?.state == .active {
            log[id]?.state = .closed
            log[id]?.endedAt = Date()
        }
        let snapshot = orderedEntriesLocked()
        lock.unlock()

        uploadRate = 0
        downloadRate = 0
        entries = snapshot
    }

    @MainActor
    private func sample() {
        lock.lock()
        let up = pendingSent
        let down = pendingReceived
        pendingSent = 0
        pendingReceived = 0
        let totalUp = cumulativeSent
        let totalDown = cumulativeReceived
        let snapshot = logDirty ? orderedEntriesLocked() : nil
        logDirty = false
        lock.unlock()

        uploadRate = up
        downloadRate = down
        totalSent = totalUp
        totalReceived = totalDown
        if let snapshot { entries = snapshot }
    }

    /// 取日志快照(调用前必须已持锁),最新的排在最前
    private func orderedEntriesLocked() -> [ConnectionEntry] {
        order.reversed().compactMap { log[$0] }
    }

    // MARK: - 供中继调用(任意线程)

    /// 新连接开始,返回用于后续更新的记录 id
    func beginConnection(host: String, port: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        let id = nextID
        log[id] = ConnectionEntry(id: id, host: host, port: port, startedAt: Date())
        order.append(id)
        if order.count > Self.logCapacity {
            let dropped = order.removeFirst()
            log[dropped] = nil
        }
        logDirty = true
        return id
    }

    /// 累加某条连接的流量(同时计入全局速率)
    func addTraffic(id: UInt64, sent: Int = 0, received: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        pendingSent += sent
        pendingReceived += received
        cumulativeSent += sent
        cumulativeReceived += received
        if var entry = log[id] {
            entry.sent += sent
            entry.received += received
            log[id] = entry
            logDirty = true
        }
    }

    /// 连接结束,error 为 nil 表示正常关闭
    func endConnection(id: UInt64, error: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = log[id] else { return }
        entry.state = error.map { .failed($0) } ?? .closed
        entry.endedAt = Date()
        log[id] = entry
        logDirty = true
    }

    // MARK: - 清空

    @MainActor
    func clearLog() {
        lock.lock()
        log.removeAll()
        order.removeAll()
        logDirty = false
        lock.unlock()
        entries = []
    }

    /// 重新连接时把累计量归零(日志保留)
    @MainActor
    func resetTotals() {
        lock.lock()
        cumulativeSent = 0
        cumulativeReceived = 0
        pendingSent = 0
        pendingReceived = 0
        lock.unlock()
        totalSent = 0
        totalReceived = 0
        uploadRate = 0
        downloadRate = 0
    }

    // MARK: - 格式化

    /// 菜单栏用的定宽格式:数字恒定 3 位 + 1 位单位,总宽 4 字符,配等宽字体后宽度不会来回跳
    /// 例:`  0B` `999B` `1.0K` ` 98K` `999K` `1.2M` ` 10M` `1.5G`
    static func compactFixed(_ bytesPerSecond: Int) -> String {
        let value = max(0, bytesPerSecond)
        // 只到 999B,再大就进位成 K,保证数字部分不超过 3 位
        if value < 1000 { return pad(value) + "B" }

        // 边界取 9.95 与 999.5:9.96 按一位小数会进成 "10.0"、999.6 会进成 "1000",
        // 都会多占一位,所以提前切到下一档
        let kilobytes = Double(value) / 1024
        if kilobytes < 9.95 { return String(format: "%.1fK", kilobytes) }
        if kilobytes < 999.5 { return pad(Int(kilobytes.rounded())) + "K" }

        let megabytes = kilobytes / 1024
        if megabytes < 9.95 { return String(format: "%.1fM", megabytes) }
        if megabytes < 999.5 { return pad(Int(megabytes.rounded())) + "M" }

        let gigabytes = megabytes / 1024
        if gigabytes < 9.95 { return String(format: "%.1fG", gigabytes) }
        return pad(min(999, Int(gigabytes.rounded()))) + "G"
    }

    /// 右对齐补空格到 3 字符
    private static func pad(_ value: Int) -> String {
        let text = "\(value)"
        return String(repeating: " ", count: max(0, 3 - text.count)) + text
    }

    /// 弹窗里用的紧凑格式,不补空格:0 / 512B / 40K / 1.2M / 1.5G
    static func compact(_ bytesPerSecond: Int) -> String {
        let value = max(0, bytesPerSecond)
        if value == 0 { return "0" }
        if value < 1024 { return "\(value)B" }
        if value < 1024 * 1024 { return "\(value / 1024)K" }
        if value < 1024 * 1024 * 1024 { return String(format: "%.1fM", Double(value) / 1_048_576) }
        return String(format: "%.1fG", Double(value) / 1_073_741_824)
    }

    /// 日志和弹窗用的完整格式:0 B / 12.3 KB / 4.56 MB
    static func readable(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", Double(value) / 1024) }
        if value < 1024 * 1024 * 1024 { return String(format: "%.2f MB", Double(value) / 1_048_576) }
        return String(format: "%.2f GB", Double(value) / 1_073_741_824)
    }
}
