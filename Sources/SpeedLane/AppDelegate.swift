import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var statusBar: StatusBarController?
    /// 只能回复系统一次,后台清理与超时兜底谁先到都算
    private var didReplyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let settings = AppSettings.shared
        let controller = AppController(settings: settings)
        self.controller = controller
        statusBar = StatusBarController(controller: controller, settings: settings)

        if settings.autoConnect {
            controller.toggle(true)
        }

        // 截图/调试辅助:--show-popover 弹出主面板,--show-settings 打开设置窗口,
        // --capture <目录> 自动截取主面板和设置窗口后退出(用于生成 README 配图)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusBar?.showPopover()
            }
        }
        if arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowManager.shared.show(controller: controller, settings: settings)
            }
        }
        if let index = arguments.firstIndex(of: "--capture"), arguments.count > index + 1 {
            runCaptureFlow(directory: arguments[index + 1], controller: controller, settings: settings)
        }
    }

    // MARK: - 自动截图(截取自己的窗口无需屏幕录制权限)

    private func runCaptureFlow(directory: String, controller: AppController, settings: AppSettings) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.statusBar?.showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let window = self.statusBar?.popoverWindow {
                    Self.capture(window: window, to: "\(directory)/popover.png")
                }
                SettingsWindowManager.shared.show(controller: controller, settings: settings)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if let window = SettingsWindowManager.shared.window {
                        Self.capture(window: window, to: "\(directory)/settings.png")
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func capture(window: NSWindow, to path: String) {
        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, windowID,
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            NSLog("capture failed for \(path)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }

    /// AppKit 手动启动时没有主菜单,装一个最小的编辑菜单,
    /// 否则输入框里 Cmd+C/V/X/A 等快捷键全部失效
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 SpeedLane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// 统一的退出入口:不管从退出按钮、菜单还是 Cmd+Q 触发都走这里
    ///
    /// 菜单栏图标先消失让退出看起来是即时的,还原系统代理放后台,
    /// 完成后再回复系统可以结束进程;万一后台卡住,兜底 3 秒后照常退出
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        statusBar?.prepareForQuit()

        controller.beginTeardown { [weak self] in
            self?.replyToTerminate()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正常路径上 beginTeardown 已经做完了,这里只为异常退出兜底
        controller?.teardownSync()
    }
}
