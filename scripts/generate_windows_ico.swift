// 生成 Windows 图标 windows/AppIcon.ico(与 macOS 图标同款:蓝色渐变 + 白色闪电)
// 用法: swift scripts/generate_windows_ico.swift  (在项目根目录执行)
import AppKit

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let size = CGFloat(pixels)
    // Windows 图标铺满画布,圆角略小
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
    NSGradient(
        starting: NSColor(calibratedRed: 0.20, green: 0.62, blue: 1.00, alpha: 1),
        ending: NSColor(calibratedRed: 0.00, green: 0.27, blue: 0.85, alpha: 1)
    )!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let white = NSImage(size: symbol.size)
        white.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        white.unlockFocus()

        let scale = (size * 0.66) / white.size.height
        let drawSize = NSSize(width: white.size.width * scale, height: white.size.height * scale)
        let origin = NSPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        white.draw(in: NSRect(origin: origin, size: drawSize))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ICO 容器:文件头 + 目录项 + PNG 数据(Vista+ 支持 PNG 压缩的图标项)
let sizes = [16, 24, 32, 48, 64, 128, 256]
let images = sizes.map { renderIcon(pixels: $0) }

var data = Data()
func appendU16(_ v: Int) { data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF)) }
func appendU32(_ v: Int) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
}

appendU16(0)            // 保留
appendU16(1)            // 类型:图标
appendU16(sizes.count)  // 数量

var offset = 6 + sizes.count * 16
for (index, size) in sizes.enumerated() {
    data.append(UInt8(size >= 256 ? 0 : size)) // 宽(0 表示 256)
    data.append(UInt8(size >= 256 ? 0 : size)) // 高
    data.append(0)                              // 调色板
    data.append(0)                              // 保留
    appendU16(1)                                // 平面数
    appendU16(32)                               // 位深
    appendU32(images[index].count)              // 数据长度
    appendU32(offset)                           // 数据偏移
    offset += images[index].count
}
for image in images { data.append(image) }

try! data.write(to: URL(fileURLWithPath: "windows/AppIcon.ico"))
print("完成: windows/AppIcon.ico (\(data.count) 字节)")
