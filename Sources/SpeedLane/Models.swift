import Foundation

/// 代理连接方式
enum ProxyMode: String, CaseIterable, Identifiable, Codable {
    /// App 自动通过 ssh -D 在本地建立 SOCKS5 隧道(服务器只需支持 SSH 登录)
    case sshTunnel
    /// 服务器上已经运行了 SOCKS5 代理,PAC 直接指向服务器
    case remoteSOCKS5
    /// 服务器上已经运行了 HTTP 代理,PAC 直接指向服务器
    case remoteHTTP

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sshTunnel:    return "SSH 隧道(推荐,服务器无需配置)"
        case .remoteSOCKS5: return "服务器上的 SOCKS5 代理"
        case .remoteHTTP:   return "服务器上的 HTTP 代理"
        }
    }
}

/// SSH 认证方式
enum AuthMethod: String, CaseIterable, Identifiable, Codable {
    case key
    case password

    var id: String { rawValue }

    var label: String {
        switch self {
        case .key:      return "SSH 密钥(免密登录)"
        case .password: return "密码"
        }
    }
}

/// 一台加速服务器的配置(密码单独存钥匙串,不落盘)
struct ServerConfig: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = "新服务器"
    var host: String = ""
    var sshPort: Int = 22
    var user: String = "root"
    var auth: AuthMethod = .key
    var mode: ProxyMode = .sshTunnel
    /// remoteSOCKS5 / remoteHTTP 模式下服务器上的代理端口
    var remotePort: Int = 1080
}

/// 预设的可加速站点分组
struct SitePreset: Identifiable {
    let id: String
    let name: String
    let domains: [String]
}

/// 用户自定义的加速域名,可单独开/关
struct CustomSite: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var domain: String
    var enabled: Bool = true
}

enum Presets {
    static let all: [SitePreset] = [
        SitePreset(id: "github", name: "GitHub", domains: [
            "github.com", "githubusercontent.com", "githubassets.com",
            "github.io", "githubapp.com", "ghcr.io", "github.dev",
        ]),
        SitePreset(id: "google", name: "Google", domains: [
            "google.com", "googleapis.com", "gstatic.com",
            "googleusercontent.com", "ggpht.com", "gvt1.com", "googlesource.com",
        ]),
        SitePreset(id: "youtube", name: "YouTube", domains: [
            "youtube.com", "ytimg.com", "googlevideo.com", "youtu.be",
        ]),
        SitePreset(id: "stackoverflow", name: "Stack Overflow", domains: [
            "stackoverflow.com", "stackexchange.com", "sstatic.net",
            "superuser.com", "serverfault.com",
        ]),
        SitePreset(id: "huggingface", name: "Hugging Face", domains: [
            "huggingface.co", "hf.co",
        ]),
        SitePreset(id: "docker", name: "Docker Hub", domains: [
            "docker.io", "docker.com",
        ]),
        SitePreset(id: "npm", name: "npm", domains: [
            "npmjs.com", "npmjs.org",
        ]),
        SitePreset(id: "wikipedia", name: "Wikipedia", domains: [
            "wikipedia.org", "wikimedia.org",
        ]),
    ]
}

/// 用户设置,持久化到 UserDefaults
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let store = UserDefaults.standard

    @Published var servers: [ServerConfig] { didSet { persistServers() } }
    /// 默认连接的服务器
    @Published var defaultServerID: UUID? { didSet { store.set(defaultServerID?.uuidString, forKey: "defaultServerID") } }
    /// SSH 隧道模式下本地 SOCKS5 端口
    @Published var localPort: Int { didSet { store.set(localPort, forKey: "localPort") } }
    @Published var enabledPresets: Set<String> { didSet { store.set(Array(enabledPresets), forKey: "enabledPresets") } }
    @Published var customSites: [CustomSite] { didSet { persistCustomSites() } }
    /// App 启动后自动连接
    @Published var autoConnect: Bool { didSet { store.set(autoConnect, forKey: "autoConnect") } }

    private init() {
        // 项目更名导致 bundle id 变化时,把旧偏好设置整体导入一次
        if store.object(forKey: "servers") == nil,
           let legacy = store.persistentDomain(forName: "local.githubfast") {
            for (key, value) in legacy {
                store.set(value, forKey: key)
            }
        }

        localPort = store.object(forKey: "localPort") as? Int ?? 1080
        enabledPresets = Set(store.stringArray(forKey: "enabledPresets") ?? ["github"])
        autoConnect = store.object(forKey: "autoConnect") as? Bool ?? false

        if let data = store.data(forKey: "customSites"),
           let decoded = try? JSONDecoder().decode([CustomSite].self, from: data) {
            customSites = decoded
        } else {
            // 从旧版纯字符串列表迁移,默认全部开启
            customSites = (store.stringArray(forKey: "customDomains") ?? [])
                .map { CustomSite(domain: $0) }
        }

        if let data = store.data(forKey: "servers"),
           let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        } else if let host = store.string(forKey: "serverHost") {
            // 从旧版单服务器设置迁移
            var server = ServerConfig()
            server.name = "我的服务器"
            server.host = host
            server.user = store.string(forKey: "sshUser") ?? "root"
            server.sshPort = store.object(forKey: "sshPort") as? Int ?? 22
            server.mode = ProxyMode(rawValue: store.string(forKey: "mode") ?? "") ?? .sshTunnel
            server.remotePort = store.object(forKey: "remotePort") as? Int ?? 1080
            servers = [server]
        } else {
            // 全新安装:不预设任何服务器,由用户在设置中添加
            servers = []
        }
        defaultServerID = store.string(forKey: "defaultServerID").flatMap(UUID.init(uuidString:))
            ?? servers.first?.id

        // init 中赋值不触发 didSet,手动落盘一次,保证迁移生成的 UUID 稳定
        persistServers()
        persistCustomSites()
        store.set(defaultServerID?.uuidString, forKey: "defaultServerID")
    }

    private func persistServers() {
        if let data = try? JSONEncoder().encode(servers) {
            store.set(data, forKey: "servers")
        }
    }

    private func persistCustomSites() {
        if let data = try? JSONEncoder().encode(customSites) {
            store.set(data, forKey: "customSites")
        }
    }

    /// 当前默认连接的服务器(没设置时取第一台)
    var defaultServer: ServerConfig? {
        if let id = defaultServerID, let server = servers.first(where: { $0.id == id }) {
            return server
        }
        return servers.first
    }

    /// 当前所有需要走代理的域名(去重、小写,只含已开启的)
    var activeDomains: [String] {
        var result: [String] = []
        for preset in Presets.all where enabledPresets.contains(preset.id) {
            result.append(contentsOf: preset.domains)
        }
        result.append(contentsOf: customSites.filter(\.enabled).map(\.domain))
        var seen = Set<String>()
        return result.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }
}
