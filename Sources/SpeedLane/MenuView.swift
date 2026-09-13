import SwiftUI

/// 弹窗里的实时速率行(单独观察 monitor,每秒刷新不影响其他部分)
private struct TrafficRateLine: View {
    @ObservedObject var monitor: TrafficMonitor

    var body: some View {
        HStack(spacing: 10) {
            // 定宽格式,速率变化时两项不会互相推挤
            Label("\(TrafficMonitor.compactFixed(monitor.downloadRate))/s", systemImage: "arrow.down")
            Label("\(TrafficMonitor.compactFixed(monitor.uploadRate))/s", systemImage: "arrow.up")
            Spacer()
            Text("累计 \(TrafficMonitor.readable(monitor.totalReceived + monitor.totalSent))")
                .foregroundStyle(.tertiary)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.top, 1)
    }
}

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
            // 站点区域有上限高度,超出在内部滚动
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
        let groups = Presets.groups.count + (settings.customSites.isEmpty ? 0 : 1)
        let rowHeight: CGFloat = 22.5
        let groupHeight: CGFloat = 26
        let fixed: CGFloat = 28 // 标题行
        let total = CGFloat(rows) * rowHeight + CGFloat(groups) * groupHeight + fixed
        return min(total, 360)
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

            if controller.isEnabled, controller.hasTrafficStats {
                TrafficRateLine(monitor: controller.monitor)
            }
        }
    }

    // MARK: - 连接 / 断开

    private var connectButton: some View {
        Button {
            controller.toggle(!controller.isEnabled)
        } label: {
            HStack(spacing: 6) {
                switch controller.phase {
                case .connecting, .disconnecting:
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(controller.phase == .connecting ? "连接中…" : "断开中…")
                case .connected:
                    Image(systemName: "bolt.slash.fill")
                    Text("断开")
                case .disconnected:
                    Image(systemName: "bolt.fill")
                    Text("连接选中站点")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(connectButtonTint)
        .controlSize(.large)
        .disabled(controller.isBusy)
        .animation(.easeInOut(duration: 0.2), value: controller.phase)
    }

    private var connectButtonTint: Color {
        switch controller.phase {
        case .connected, .disconnecting: return .red
        case .connecting, .disconnected: return .accentColor
        }
    }

    /// 状态点同样只看 phase,和文案、按钮保持一致
    private var statusColor: Color {
        if controller.lastError != nil { return .red }
        switch controller.phase {
        case .disconnected: return .gray
        case .connecting, .disconnecting: return .yellow
        case .connected: return .green
        }
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
                NSApp.terminate(nil)
            }
        }
    }
}
