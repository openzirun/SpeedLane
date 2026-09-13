import Foundation

/// 通过 networksetup 管理系统的"自动代理配置(PAC)"
enum SystemProxy {
    private static let tool = "/usr/sbin/networksetup"

    /// 当前启用的网络服务(Wi-Fi、以太网等),跳过被禁用的(以 * 开头)
    static func activeServices() -> [String] {
        let (status, output) = runCommand(tool, ["-listallnetworkservices"])
        guard status == 0 else { return [] }
        return output
            .split(separator: "\n")
            .dropFirst() // 第一行是说明文字
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// 为所有启用的网络服务设置 PAC 地址并打开自动代理
    ///
    /// 单次 networksetup 调用约 100 毫秒,机器上的网络服务动辄七八个,
    /// 串行下来要一秒以上,因此按服务并发执行(各服务配置互相独立)
    static func enablePAC(url: String) -> String? {
        let services = activeServices()
        guard !services.isEmpty else { return nil }
        let lock = NSLock()
        var errors: [String] = []
        forEachConcurrently(services) { service in
            let (urlStatus, urlOutput) = runCommand(tool, ["-setautoproxyurl", service, url])
            let (stateStatus, stateOutput) = runCommand(tool, ["-setautoproxystate", service, "on"])
            var messages: [String] = []
            if urlStatus != 0 {
                messages.append("\(service): \(urlOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if stateStatus != 0 {
                messages.append("\(service): \(stateOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard !messages.isEmpty else { return }
            lock.lock()
            errors.append(contentsOf: messages)
            lock.unlock()
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    /// 关闭所有网络服务的自动代理(同样并发,退出时要尽快完成)
    static func disablePAC() {
        let services = activeServices()
        guard !services.isEmpty else { return }
        forEachConcurrently(services) { service in
            runCommand(tool, ["-setautoproxystate", service, "off"])
        }
    }

    /// 每个服务起一个任务并发执行、全部完成后返回
    /// networksetup 是阻塞的子进程调用,concurrentPerform 那套按核心数调度的并发度不够
    private static func forEachConcurrently(_ services: [String], _ work: @escaping (String) -> Void) {
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for service in services {
            group.enter()
            queue.async {
                work(service)
                group.leave()
            }
        }
        group.wait()
    }
}
