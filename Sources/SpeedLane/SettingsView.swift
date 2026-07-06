import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServersSettingsTab()
                .tabItem { Label("服务器", systemImage: "server.rack") }
            SitesSettingsTab()
                .tabItem { Label("加速站点", systemImage: "globe") }
            GeneralSettingsTab()
                .tabItem { Label("通用", systemImage: "gearshape") }
            AboutSettingsTab()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding()
        .frame(width: 600, height: 460)
    }
}

// MARK: - 服务器标签页

struct ServersSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: AppController

    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                serverList
                    .frame(width: 190)
                Divider()
                    .padding(.horizontal, 10)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            Divider()
            HStack {
                Spacer()
                Text("★ 为默认连接的服务器")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            selection = settings.defaultServer?.id ?? settings.servers.first?.id
        }
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(settings.servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                            Text(server.host.isEmpty ? "未填写地址" : server.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if settings.defaultServer?.id == server.id {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .help("默认连接")
                        }
                    }
                    .tag(server.id)
                }
            }
            .listStyle(.bordered)
            HStack(spacing: 10) {
                Button { addServer() } label: { Image(systemName: "plus") }
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let index = settings.servers.firstIndex(where: { $0.id == selection }) {
            ServerDetailForm(server: $settings.servers[index])
        } else {
            VStack {
                Spacer()
                Text("在左侧选择或添加一台服务器")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func addServer() {
        var server = ServerConfig()
        server.name = "服务器 \(settings.servers.count + 1)"
        settings.servers.append(server)
        selection = server.id
        if settings.defaultServerID == nil {
            settings.defaultServerID = server.id
        }
    }

    private func removeSelected() {
        guard let id = selection,
              let index = settings.servers.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = controller.activeServer?.id == id
        KeychainStore.deletePassword(for: id)
        settings.servers.remove(at: index)
        if settings.defaultServerID == id {
            settings.defaultServerID = settings.servers.first?.id
        }
        selection = settings.servers.first?.id
        if wasActive {
            controller.connectionSettingsChanged()
        }
    }
}

// MARK: - 单台服务器表单

struct ServerDetailForm: View {
    @Binding var server: ServerConfig
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: AppController

    @State private var password = ""
    @State private var testing = false
    @State private var testResult: String?

    private var isDefault: Bool { settings.defaultServer?.id == server.id }

    var body: some View {
        Form {
            TextField("名称", text: $server.name)
            TextField("地址(IP / 域名)", text: $server.host)
            Picker("连接方式", selection: $server.mode) {
                ForEach(ProxyMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            if server.mode == .sshTunnel {
                TextField("SSH 端口", text: intBinding($server.sshPort))
                TextField("用户名", text: $server.user)
                Picker("认证方式", selection: $server.auth) {
                    ForEach(AuthMethod.allCases) { auth in
                        Text(auth.label).tag(auth)
                    }
                }
                if server.auth == .password {
                    SecureField("密码", text: $password)
                    Text("密码保存在 macOS 钥匙串中,不写入配置文件")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("需先在终端配置免密登录:\nssh-copy-id \(server.user)@\(server.host.isEmpty ? "服务器地址" : server.host)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            } else {
                TextField("代理端口", text: intBinding($server.remotePort))
            }

            HStack {
                Button(isDefault ? "✓ 默认连接" : "设为默认连接") {
                    settings.defaultServerID = server.id
                    controller.connectionSettingsChanged()
                }
                .disabled(isDefault)

                if server.mode == .sshTunnel {
                    Button(action: runTest) {
                        if testing {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(testing || server.host.isEmpty)
                }
            }
            .padding(.top, 4)

            if let testResult {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult == "✓ 连接成功" ? Color.green : Color.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if controller.isEnabled, controller.activeServer?.id == server.id {
                Button("应用修改并重新连接") {
                    controller.connectionSettingsChanged()
                }
                .font(.caption)
            }
        }
        .onAppear { loadPassword() }
        .onChange(of: server.id) { _ in
            loadPassword()
            testResult = nil
        }
        .onChange(of: password) { newValue in
            KeychainStore.setPassword(newValue, for: server.id)
        }
    }

    private func loadPassword() {
        password = KeychainStore.password(for: server.id) ?? ""
    }

    private func runTest() {
        testing = true
        testResult = nil
        let config = server
        let pw = config.auth == .password ? password : nil
        Task {
            let error = await SSHTunnel.testConnection(server: config, password: pw)
            testing = false
            testResult = error == nil ? "✓ 连接成功" : "失败:\(error!)"
        }
    }

    private func intBinding(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { String(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) ?? value.wrappedValue }
        )
    }
}

// MARK: - 站点标签页

struct SitesSettingsTab: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SitesConfigView()
                Divider()
                Text("git 命令行加速默认开启,仅对所选域名的 clone/push 生效")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(4)
        }
    }
}

// MARK: - 通用标签页

struct GeneralSettingsTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: AppController

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 16) {
                settingRow(
                    title: "开机自动运行",
                    subtitle: "登录 macOS 后自动启动 SpeedLane",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { on in
                            launchError = LaunchAtLogin.set(on)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    )
                )
                if let launchError {
                    Text("设置失败:\(launchError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                settingRow(
                    title: "启动后自动连接",
                    subtitle: "打开 App 后立即连接默认服务器,配合开机自动运行可实现无感使用",
                    isOn: Binding(
                        get: { settings.autoConnect },
                        set: { settings.autoConnect = $0 }
                    )
                )

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地 SOCKS5 端口")
                        Text("SSH 隧道在本机监听的端口,修改后需重新连接")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    TextField("", text: Binding(
                        get: { String(settings.localPort) },
                        set: { settings.localPort = Int($0) ?? settings.localPort }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func settingRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

// MARK: - 关于标签页

struct AboutSettingsTab: View {
    static let repoURL = URL(string: "https://github.com/openzirun/SpeedLane")!
    static let releasesURL = URL(string: "https://github.com/openzirun/SpeedLane/releases")!

    /// 版本号运行时取自 Info.plist,与打包版本单一来源
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("SpeedLane")
                .font(.title2)
                .bold()
            Text("版本 \(version)(Build \(build))")
                .foregroundStyle(.secondary)
            Text("只给选中的网站开一条快车道")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().frame(width: 260)

            VStack(spacing: 6) {
                Link("GitHub 项目主页", destination: Self.repoURL)
                Link("下载最新版本(Releases)", destination: Self.releasesURL)
            }

            Text("MIT License © 2026 SpeedLane Contributors")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
