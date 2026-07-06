// 生成 App 图标:蓝色渐变圆角矩形 + 白色闪电
// 用法: swift scripts/generate_icon.swift  (在项目根目录执行,输出 Resources/AppIcon.icns)
import AppKit

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    // macOS 图标规范:内容区约占画布 82%,四周留透明边
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.62, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.00, green: 0.27, blue: 0.85, alpha: 1)
    )!.draw(in: path, angle: -90)

    // 白色闪电(SF Symbol)
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let white = NSImage(size: symbol.size)
        white.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        white.unlockFocus()

        let scale = (rect.height * 0.62) / white.size.height
        let drawSize = NSSize(width: white.size.width * scale, height: white.size.height * scale)
        let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        white.draw(in: NSRect(origin: origin, size: drawSize))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let files: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for file in files {
    let rep = renderIcon(pixels: file.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(file.name).png"))
}
print("已生成 \(iconset),转换 icns…")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print(task.terminationStatus == 0 ? "完成: Resources/AppIcon.icns" : "iconutil 失败")
