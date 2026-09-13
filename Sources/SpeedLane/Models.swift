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

    /// 是否经本地 SOCKS5 中继转发(中继负责流量统计与连接日志)
    /// HTTP 代理模式浏览器直接说 HTTP 代理协议,没法用 SOCKS5 中继,因此没有统计
    var usesRelay: Bool {
        self == .sshTunnel || self == .remoteSOCKS5
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

/// 预设的可加速站点(一个服务对应一组域名,由一个开关统一控制)
struct SitePreset: Identifiable {
    let id: String
    let name: String
    let domains: [String]
}

/// 站点分组:把相关服务归在一起,组级开关批量开/关组内所有服务
struct SiteGroup: Identifiable {
    let id: String
    let name: String
    let presets: [SitePreset]
}

/// 用户自定义的加速站点:一个名称对应一组域名,可单独开/关
struct CustomSite: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var domains: [String]
    var enabled: Bool = true

    init(id: UUID = UUID(), name: String, domains: [String], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.domains = domains
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, domains, enabled, domain
    }

    /// 兼容旧版单域名格式({domain, enabled}):名称取域名本身
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let domains = try c.decodeIfPresent([String].self, forKey: .domains) {
            self.domains = domains
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? domains.first ?? ""
        } else {
            let legacy = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
            domains = legacy.isEmpty ? [] : [legacy]
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? legacy
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(domains, forKey: .domains)
        try c.encode(enabled, forKey: .enabled)
    }
}

/// 域名输入的统一清洗:去协议、去路径、小写、去空白
enum DomainParser {
    static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
    }

    /// 解析多域名输入(逗号、空格、换行、分号分隔),过滤无效项并去重
    static func parseList(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw
            .components(separatedBy: CharacterSet(charactersIn: ",;\n\t "))
            .map(clean)
            .filter { !$0.isEmpty && $0.contains(".") && seen.insert($0).inserted }
    }
}

enum Presets {
    static let groups: [SiteGroup] = [
        SiteGroup(id: "ai", name: "AI 助手", presets: [
            SitePreset(id: "chatgpt", name: "ChatGPT", domains: [
                // 网页版与桌面版共用;桌面版走系统代理,语音模式经 livekit,登录需 Cloudflare 验证同出口
                "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
                "ai.com", "livekit.cloud", "challenges.cloudflare.com",
            ]),
            SitePreset(id: "claude", name: "Claude", domains: [
                "claude.ai", "anthropic.com", "claudeusercontent.com",
            ]),
            SitePreset(id: "gemini", name: "Gemini", domains: [
                // 登录依赖 accounts.google.com,页面资源来自 gstatic / googleusercontent
                "gemini.google.com", "aistudio.google.com", "generativelanguage.googleapis.com",
                "deepmind.google", "accounts.google.com", "gstatic.com", "googleusercontent.com",
            ]),
            SitePreset(id: "perplexity", name: "Perplexity", domains: [
                "perplexity.ai", "pplx.ai",
            ]),
            SitePreset(id: "grok", name: "Grok", domains: [
                "grok.com", "x.ai",
            ]),
        ]),
        SiteGroup(id: "dev", name: "开发工具", presets: [
            SitePreset(id: "github", name: "GitHub", domains: [
                // 含 Copilot 接口域名(githubcopilot.com)
                "github.com", "githubusercontent.com", "githubassets.com",
                "github.io", "githubapp.com", "ghcr.io", "github.dev", "githubcopilot.com",
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
            SitePreset(id: "golang", name: "Go 模块代理", domains: [
                "proxy.golang.org", "sum.golang.org", "go.dev", "golang.org",
            ]),
            SitePreset(id: "k8s", name: "Kubernetes 镜像", domains: [
                "k8s.io", "gcr.io", "pkg.dev",
            ]),
            SitePreset(id: "crates", name: "crates.io", domains: [
                "crates.io",
            ]),
            SitePreset(id: "vscode", name: "VS Code 插件市场", domains: [
                "marketplace.visualstudio.com", "vsassets.io", "vscode-cdn.net",
            ]),
            SitePreset(id: "vercel", name: "Vercel", domains: [
                "vercel.com", "vercel.app",
            ]),
        ]),
        SiteGroup(id: "google", name: "Google 服务", presets: [
            SitePreset(id: "google", name: "Google", domains: [
                "google.com", "googleapis.com", "gstatic.com",
                "googleusercontent.com", "ggpht.com", "gvt1.com", "googlesource.com",
            ]),
            SitePreset(id: "youtube", name: "YouTube", domains: [
                "youtube.com", "ytimg.com", "googlevideo.com", "youtu.be",
            ]),
        ]),
        SiteGroup(id: "community", name: "社区", presets: [
            SitePreset(id: "reddit", name: "Reddit", domains: [
                "reddit.com", "redd.it", "redditstatic.com", "redditmedia.com",
            ]),
            SitePreset(id: "medium", name: "Medium", domains: [
                "medium.com",
            ]),
            SitePreset(id: "discord", name: "Discord", domains: [
                // 语音走 UDP,SOCKS 隧道下不可用,文字与图片正常
                "discord.com", "discord.gg", "discordapp.com", "discordapp.net", "discord.media",
            ]),
            SitePreset(id: "x", name: "X (Twitter)", domains: [
                "x.com", "twitter.com", "twimg.com", "t.co",
            ]),
        ]),
        SiteGroup(id: "reference", name: "资料", presets: [
            SitePreset(id: "wikipedia", name: "Wikipedia", domains: [
                "wikipedia.org", "wikimedia.org",
            ]),
            SitePreset(id: "udemy", name: "Udemy", domains: [
                "udemy.com", "udemycdn.com",
            ]),
            SitePreset(id: "archive", name: "Internet Archive", domains: [
                "archive.org",
            ]),
        ]),
    ]

    /// 所有预设的平铺列表(按分组顺序)
    static let all: [SitePreset] = groups.flatMap(\.presets)
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
    /// 用户给预设追加的域名,按预设 id 存
    @Published var presetExtraDomains: [String: [String]] { didSet { persistJSON(presetExtraDomains, key: "presetExtraDomains") } }
    /// 用户从预设里删掉的域名,按预设 id 存
    @Published var presetRemovedDomains: [String: [String]] { didSet { persistJSON(presetRemovedDomains, key: "presetRemovedDomains") } }
    /// App 启动后自动连接
    @Published var autoConnect: Bool { didSet { store.set(autoConnect, forKey: "autoConnect") } }
    /// 菜单栏图标旁是否显示实时流量数字(关掉只是不显示,统计与日志照常)
    @Published var showTrafficInMenuBar: Bool { didSet { store.set(showTrafficInMenuBar, forKey: "showTrafficInMenuBar") } }

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
        showTrafficInMenuBar = store.object(forKey: "showTrafficInMenuBar") as? Bool ?? true

        if let data = store.data(forKey: "customSites"),
           let decoded = try? JSONDecoder().decode([CustomSite].self, from: data) {
            customSites = decoded
        } else {
            // 从旧版纯字符串列表迁移,默认全部开启
            customSites = (store.stringArray(forKey: "customDomains") ?? [])
                .map { CustomSite(name: $0, domains: [$0]) }
        }
        presetExtraDomains = Self.loadJSON([String: [String]].self, store: store, key: "presetExtraDomains") ?? [:]
        presetRemovedDomains = Self.loadJSON([String: [String]].self, store: store, key: "presetRemovedDomains") ?? [:]

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
        store.set(showTrafficInMenuBar, forKey: "showTrafficInMenuBar")
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

    private func persistJSON<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            store.set(data, forKey: key)
        }
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, store: UserDefaults, key: String) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - 预设域名的用户修改

    /// 预设实际生效的域名:默认列表去掉用户删除的,再加上用户追加的
    func effectiveDomains(for preset: SitePreset) -> [String] {
        let removed = Set(presetRemovedDomains[preset.id] ?? [])
        var result = preset.domains.filter { !removed.contains($0) }
        for domain in presetExtraDomains[preset.id] ?? [] where !result.contains(domain) {
            result.append(domain)
        }
        return result
    }

    func isPresetModified(_ preset: SitePreset) -> Bool {
        !(presetExtraDomains[preset.id] ?? []).isEmpty || !(presetRemovedDomains[preset.id] ?? []).isEmpty
    }

    func addDomain(_ domain: String, to preset: SitePreset) {
        guard !domain.isEmpty else { return }
        // 之前删掉的默认域名重新加回来,只需撤销删除
        if preset.domains.contains(domain) {
            presetRemovedDomains[preset.id]?.removeAll { $0 == domain }
            if presetRemovedDomains[preset.id]?.isEmpty == true { presetRemovedDomains[preset.id] = nil }
            return
        }
        var extra = presetExtraDomains[preset.id] ?? []
        guard !extra.contains(domain) else { return }
        extra.append(domain)
        presetExtraDomains[preset.id] = extra
    }

    func removeDomain(_ domain: String, from preset: SitePreset) {
        if preset.domains.contains(domain) {
            var removed = presetRemovedDomains[preset.id] ?? []
            if !removed.contains(domain) { removed.append(domain) }
            presetRemovedDomains[preset.id] = removed
        } else {
            presetExtraDomains[preset.id]?.removeAll { $0 == domain }
            if presetExtraDomains[preset.id]?.isEmpty == true { presetExtraDomains[preset.id] = nil }
        }
    }

    func resetPreset(_ preset: SitePreset) {
        presetExtraDomains[preset.id] = nil
        presetRemovedDomains[preset.id] = nil
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
            result.append(contentsOf: effectiveDomains(for: preset))
        }
        result.append(contentsOf: customSites.filter(\.enabled).flatMap(\.domains))
        var seen = Set<String>()
        return result.map { $0.lowercased() }.filter { seen.insert($0).inserted }
    }
}
