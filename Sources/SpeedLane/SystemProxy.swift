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
    static func enablePAC(url: String) -> String? {
        var errors: [String] = []
        for service in activeServices() {
            let (s1, o1) = runCommand(tool, ["-setautoproxyurl", service, url])
            let (s2, o2) = runCommand(tool, ["-setautoproxystate", service, "on"])
            if s1 != 0 { errors.append("\(service): \(o1.trimmingCharacters(in: .whitespacesAndNewlines))") }
            if s2 != 0 { errors.append("\(service): \(o2.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }

    /// 关闭所有网络服务的自动代理
    static func disablePAC() {
        for service in activeServices() {
            runCommand(tool, ["-setautoproxystate", service, "off"])
        }
    }
}
