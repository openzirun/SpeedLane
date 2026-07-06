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
    private var cancellable: AnyCancellable?

    init(controller: AppController, settings: AppSettings) {
        self.controller = controller
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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

        cancellable = controller.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.updateIcon(enabled: enabled)
            }
    }

    private func updateIcon(enabled: Bool) {
        let name = enabled ? "bolt.fill" : "bolt.slash"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SpeedLane")
        image?.isTemplate = true
        statusItem.button?.image = image
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

    @objc private func quit() {
        controller.disable()
        NSApp.terminate(nil)
    }
}
