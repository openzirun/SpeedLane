import AppKit

@main
enum SpeedLaneMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 菜单栏工具,不显示 Dock 图标
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
