import AppKit
import Combine
import SwiftUI

/// 菜单栏图标:左键弹出主面板,右键弹出快捷菜单
@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let controller: AppController
    private let settings: AppSettings
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        // 图标右边要显示速率数字,宽度随内容变化
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(
            rootView: MenuView()
                .environmentObject(controller)
                .environmentObject(settings)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon(enabled: controller.isEnabled)
        updateRate()

        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.updateIcon(enabled: phase == .connected)
                self?.updateRate()
            }
            .store(in: &cancellables)

        // 速率每秒更新一次,驱动图标旁边的数字
        controller.monitor.$uploadRate
            .combineLatest(controller.monitor.$downloadRate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateRate()
            }
            .store(in: &cancellables)

        // 设置里开关切换后立即生效
        settings.$showTrafficInMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateRate()
            }
            .store(in: &cancellables)
    }

    private func updateIcon(enabled: Bool) {
        let name = enabled ? "bolt.fill" : "bolt.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SpeedLane")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// 图标右边的实时速率:未连接或该模式拿不到统计时不显示数字
    private func updateRate() {
        guard let button = statusItem.button else { return }
        guard settings.showTrafficInMenuBar, controller.isEnabled, controller.hasTrafficStats else {
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = nil
            return
        }
        let monitor = controller.monitor
        let total = monitor.uploadRate + monitor.downloadRate
        // 定宽格式 + 全等宽字体(空格和 B/K/M/G 也等宽),菜单栏宽度恒定
        button.attributedTitle = NSAttributedString(
            string: " " + TrafficMonitor.compactFixed(total),
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        button.toolTip = """
        ↓ \(TrafficMonitor.compact(monitor.downloadRate))/s  ↑ \(TrafficMonitor.compact(monitor.uploadRate))/s
        本次累计 ↓ \(TrafficMonitor.readable(monitor.totalReceived))  ↑ \(TrafficMonitor.readable(monitor.totalSent))
        """
    }

    /// 供截图/调试用(--show-popover 启动参数):直接弹出主面板
    func showPopover() {
        if !popover.isShown { togglePopover() }
    }

    /// 供截图用:主面板所在的窗口
    var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    // MARK: - 点击分发

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        // accessory 应用必须先真正激活,弹窗里的输入框才能接收键盘事件
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        popover.performClose(nil)
        let menu = NSMenu()

        let connectItem = NSMenuItem(
            title: controller.isEnabled ? "断开连接" : "连接选中站点",
            action: #selector(toggleConnection),
            keyEquivalent: ""
        )
        connectItem.target = self
        menu.addItem(connectItem)

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "开机自动运行", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 SpeedLane", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        if let button = statusItem.button {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 4),
                in: button
            )
        }
    }

    @objc private func toggleConnection() {
        controller.toggle(!controller.isEnabled)
    }

    @objc private func openSettings() {
        SettingsWindowManager.shared.show(controller: controller, settings: settings)
    }

    @objc private func toggleLaunchAtLogin() {
        _ = LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    /// 退出前先把界面撤掉,让退出看起来是即时的(真正的清理在 AppDelegate 里异步进行)
    ///
    /// 这里必须用 removeStatusItem:NSStatusItem.isVisible 会被系统写进偏好并在
    /// 下次启动时恢复,设成 false 会导致重新打开 App 后菜单栏里根本看不到图标
    func prepareForQuit() {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
