import AppKit
import Foundation

// 生成 AppIcon.icns：圆角蓝底 + 白色清单表示意（macOS 图标规范留白约 10%）
// 用法： swift tools/make_icon.swift <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Packaging"
let iconsetURL = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    // 底板（macOS 圆角方形，四周留 8%）
    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.78, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.22, blue: 0.55, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: rect.minX, y: rect.maxY),
                               end: CGPoint(x: rect.maxX, y: rect.minY),
                               options: [])
    }
    ctx.restoreGState()

    // 白色「清单」面板
    let panel = rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.20)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: rect.width * 0.06,
                           cornerHeight: rect.width * 0.06, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01),
                  blur: size * 0.04,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(panelPath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // 表格横线与数字列
    let rows = 4
    let rowH = panel.height / CGFloat(rows + 1)
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.80, alpha: 1).cgColor)
    ctx.setLineWidth(max(size * 0.008, 1))
    for i in 1...rows {
        let y = panel.maxY - rowH * CGFloat(i)
        ctx.move(to: CGPoint(x: panel.minX + panel.width * 0.10, y: y))
        ctx.addLine(to: CGPoint(x: panel.maxX - panel.width * 0.10, y: y))
    }
    ctx.strokePath()

    // 首列高亮（蓝色小方块，示意“选中行”）
    let cell = CGRect(x: panel.minX + panel.width * 0.12,
                      y: panel.maxY - rowH * 1.25,
                      width: panel.width * 0.20 / 2,
                      height: rowH * 0.42)
    ctx.setFillColor(NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.86, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: cell, cornerWidth: cell.height * 0.3,
                       cornerHeight: cell.height * 0.3, transform: nil))
    ctx.fillPath()

    // 金额文字
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: panel.height * 0.20, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.09, green: 0.22, blue: 0.55, alpha: 1)
    ]
    let text = "¥" as NSString
    let ts = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: panel.midX - ts.width / 2 + panel.width * 0.12,
                          y: panel.minY + panel.height * 0.08), withAttributes: attrs)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

for (px, name) in sizes {
    let img = drawIcon(size: CGFloat(px))
    savePNG(img, to: iconsetURL.appendingPathComponent("\(name).png"), pixelSize: px)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetURL.path, "-o",
                  URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print("icns: \(outDir)/AppIcon.icns")
