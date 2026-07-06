import Foundation

/// 为 git 命令行按域名设置代理(只影响列表内的域名,其余仓库不走代理)
/// 例如:git config --global http.https://github.com/.proxy socks5h://127.0.0.1:1080
enum GitProxy {
    private static let git = "/usr/bin/git"
    private static let appliedKey = "appliedGitDomains"

    static func apply(domains: [String], proxyURL: String) {
        clear()
        var applied: [String] = []
        for domain in domains {
            let (status, _) = runCommand(git, [
                "config", "--global",
                "http.https://\(domain)/.proxy", proxyURL,
            ])
            if status == 0 { applied.append(domain) }
        }
        UserDefaults.standard.set(applied, forKey: appliedKey)
    }

    static func clear() {
        let applied = UserDefaults.standard.stringArray(forKey: appliedKey) ?? []
        for domain in applied {
            runCommand(git, [
                "config", "--global",
                "--unset-all", "http.https://\(domain)/.proxy",
            ])
        }
        UserDefaults.standard.removeObject(forKey: appliedKey)
    }
}
