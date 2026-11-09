// Рисует иконку NotchStash: swift Assets/make-icon.swift Assets/
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // плитка по сетке macOS: 824×824 с отступом 100, радиус ~185
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.16, green: 0.13, blue: 0.30, alpha: 1).cgColor,
        NSColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // карточки, которые «выезжают» из чёлки
    let cards: [(CGFloat, CGFloat, NSColor)] = [
        (-9, 300, NSColor(red: 0.40, green: 0.36, blue: 0.95, alpha: 1)),
        (6, 360, NSColor(red: 1.00, green: 0.42, blue: 0.48, alpha: 1)),
        (0, 425, NSColor(white: 0.97, alpha: 1)),
    ]
    for (angle, y, color) in cards {
        ctx.saveGState()
        ctx.translateBy(x: 512, y: y + 130)
        ctx.rotate(by: angle * .pi / 180)
        let r = CGRect(x: -235, y: -130, width: 470, height: 260)
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 46, cornerHeight: 46, transform: nil))
        ctx.setFillColor(color.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
    // строки «текста» на верхней карточке
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 555)
    for (i, w) in [300.0, 360.0, 220.0].enumerated() {
        let r = CGRect(x: -180, y: 60 - CGFloat(i) * 62, width: CGFloat(w), height: 30)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 15, cornerHeight: 15, transform: nil))
    }
    ctx.setFillColor(NSColor(white: 0.12, alpha: 0.85).cgColor); ctx.fillPath()
    ctx.restoreGState()

    // чёлка сверху — с «ушами», как у MacBook
    let nw: CGFloat = 400, nh: CGFloat = 120, ear: CGFloat = 26, rad: CGFloat = 52
    let left = 512 - nw / 2, right = 512 + nw / 2, top: CGFloat = 924, bottom = top - nh
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left - ear, y: top))
    p.addQuadCurve(to: CGPoint(x: left, y: top - ear), control: CGPoint(x: left, y: top))
    p.addLine(to: CGPoint(x: left, y: bottom + rad))
    p.addQuadCurve(to: CGPoint(x: left + rad, y: bottom), control: CGPoint(x: left, y: bottom))
    p.addLine(to: CGPoint(x: right - rad, y: bottom))
    p.addQuadCurve(to: CGPoint(x: right, y: bottom + rad), control: CGPoint(x: right, y: bottom))
    p.addLine(to: CGPoint(x: right, y: top - ear))
    p.addQuadCurve(to: CGPoint(x: right + ear, y: top), control: CGPoint(x: right, y: top))
    p.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: NSColor.black.withAlphaComponent(0.6).cgColor)
    ctx.addPath(p); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()
    // камера в чёлке
    ctx.setFillColor(NSColor(red: 0.13, green: 0.14, blue: 0.22, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: 498, y: 856, width: 28, height: 28))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: out).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! draw(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out).appendingPathComponent("icon-1024.png"))
print("ok")
