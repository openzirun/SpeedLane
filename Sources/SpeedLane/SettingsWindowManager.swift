import AppKit
import SwiftUI

/// 设置窗口的创建与复用(AppKit 生命周期下手动管理)
@MainActor
final class SettingsWindowManager {
    static let shared = SettingsWindowManager()

    private(set) var window: NSWindow?

    private init() {}

    func show(controller: AppController, settings: AppSettings) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(controller)
                    .environmentObject(settings)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "SpeedLane 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
