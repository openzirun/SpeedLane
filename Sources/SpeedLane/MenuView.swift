import SwiftUI

struct MenuView: View {
    @EnvironmentObject var controller: AppController
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            serverSection
            Divider()
            ScrollView {
                SitesConfigView(allowsEditing: false)
            }
            // 最多显示约 10 行站点,超出在内部滚动
            .frame(height: sitesAreaHeight)
            connectButton
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
    }

    private var sitesAreaHeight: CGFloat {
        let rows = Presets.all.count + settings.customSites.count
        let rowHeight: CGFloat = 27
        let fixed: CGFloat = 22 // 标题行
        return CGFloat(min(rows, 10)) * rowHeight + fixed
    }

    // MARK: - 顶部标题与状态

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("网站加速").font(.headline)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(controller.lastError == nil ? .secondary : Color.red)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - 连接 / 断开

    private var connectButton: some View {
        Button {
            controller.toggle(!controller.isEnabled)
        } label: {
            Label(
                controller.isEnabled ? "断开" : "连接选中站点",
                systemImage: controller.isEnabled ? "bolt.slash.fill" : "bolt.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isEnabled ? .red : .accentColor)
        .controlSize(.large)
    }

    private var statusColor: Color {
        if controller.lastError != nil { return .red }
        guard controller.isEnabled else { return .gray }
        if controller.usesTunnel {
            switch controller.tunnel.state {
            case .running: return .green
            case .starting: return .yellow
            case .stopped, .failed: return .red
            }
        }
        return .green
    }

    // MARK: - 服务器选择

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("连接服务器")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.servers.isEmpty {
                Text("尚未配置服务器,请打开设置添加")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Picker("", selection: Binding(
                    get: { settings.defaultServer?.id },
                    set: { id in
                        settings.defaultServerID = id
                        controller.connectionSettingsChanged()
                    }
                )) {
                    ForEach(settings.servers) { server in
                        Text(server.host.isEmpty ? server.name : "\(server.name)(\(server.host))")
                            .tag(Optional(server.id))
                    }
                }
                .labelsHidden()
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button {
                SettingsWindowManager.shared.show(controller: controller, settings: settings)
            } label: {
                Label("设置…", systemImage: "gearshape")
            }
            Spacer()
            Button("退出") {
                controller.disable()
                NSApp.terminate(nil)
            }
        }
    }
}
