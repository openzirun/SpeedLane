import SwiftUI

/// 设置窗口的"日志"标签页:显示经过本地中继的每条连接
struct TrafficLogTab: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        TrafficLogContent(
            monitor: controller.monitor,
            isEnabled: controller.isEnabled,
            hasTrafficStats: controller.hasTrafficStats
        )
    }
}

private struct TrafficLogContent: View {
    @ObservedObject var monitor: TrafficMonitor
    let isEnabled: Bool
    let hasTrafficStats: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            Divider()
            if monitor.entries.isEmpty {
                emptyHint
            } else {
                table
            }
            footer
        }
        .padding(10)
    }

    // MARK: - 顶部汇总

    private var summary: some View {
        HStack(spacing: 16) {
            rateBadge(
                symbol: "arrow.down",
                title: "下行",
                rate: monitor.downloadRate,
                total: monitor.totalReceived
            )
            rateBadge(
                symbol: "arrow.up",
                title: "上行",
                rate: monitor.uploadRate,
                total: monitor.totalSent
            )
            Spacer()
            Text("\(monitor.entries.count) 条记录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rateBadge(symbol: String, title: String, rate: Int, total: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(title) \(TrafficMonitor.compactFixed(rate))/s")
                    .font(.system(.body, design: .monospaced))
                Text("累计 \(TrafficMonitor.readable(total))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 表格

    private var table: some View {
        Table(monitor.entries) {
            TableColumn("时间") { entry in
                Text(Self.timeFormatter.string(from: entry.startedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(66)

            TableColumn("目标") { entry in
                Text(entry.port == 443 ? entry.host : "\(entry.host):\(entry.port)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .help("\(entry.host):\(entry.port)")
            }
            .width(min: 160, ideal: 240)

            TableColumn("下行") { entry in
                Text(TrafficMonitor.readable(entry.received))
                    .font(.caption.monospacedDigit())
            }
            .width(76)

            TableColumn("上行") { entry in
                Text(TrafficMonitor.readable(entry.sent))
                    .font(.caption.monospacedDigit())
            }
            .width(76)

            TableColumn("状态") { entry in
                stateLabel(entry.state)
            }
            .width(min: 70, ideal: 96)
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: ConnectionEntry.State) -> some View {
        switch state {
        case .active:
            Text("传输中").font(.caption).foregroundStyle(.green)
        case .closed:
            Text("已结束").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).help(message)
        }
    }

    // MARK: - 空状态与底部说明

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            if !isEnabled {
                Text("尚未连接")
                    .font(.callout)
                Text("连接之后,经过加速的每条请求都会出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !hasTrafficStats {
                Text("当前服务器用的是 HTTP 代理模式,没有流量统计")
                    .font(.callout)
                Text("浏览器直接与 HTTP 代理通信,不经过本地中继,所以拿不到连接明细。改用 SSH 隧道或 SOCKS5 模式即可看到日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("还没有请求经过")
                    .font(.callout)
                Text("访问一个已开启加速的网站试试,记录会实时出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text("日志只保留在内存里,最多 500 条,退出 App 即清空,不会写入任何文件")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("清空") {
                monitor.clearLog()
            }
            .controlSize(.small)
            .disabled(monitor.entries.isEmpty)
        }
    }
}
