import AppKit

// Иконка: скруглённый квадрат с градиентом раскладок и парой «A Я».
// Запуск: swift icon/make-icon.swift  (создаёт AppIcon.icns)

let orange = NSColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1)
let blue = NSColor(red: 0.15, green: 0.55, blue: 1.00, alpha: 1)

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.06
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: body, xRadius: size * 0.22, yRadius: size * 0.22)

    // Тёмная основа, чтобы буквы читались на любом фоне
    NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
    shape.fill()

    // Свечение вдоль нижнего края — подпись приложения
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip()
    let glowHeight = body.height * 0.34
    let glow = NSGradient(colors: [orange.withAlphaComponent(0.0), orange.withAlphaComponent(0.85)])
    glow?.draw(in: NSRect(x: body.minX, y: body.minY, width: body.width, height: glowHeight), angle: -90)
    let topGlow = NSGradient(colors: [blue.withAlphaComponent(0.45), blue.withAlphaComponent(0.0)])
    topGlow?.draw(in: NSRect(x: body.minX, y: body.maxY - glowHeight, width: body.width, height: glowHeight), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Пара букв: латиница и кириллица
    let fontSize = size * 0.42
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    func draw(_ text: String, color: NSColor, centerX: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attrs)
        let bounds = string.size()
        string.draw(at: NSPoint(x: centerX - bounds.width / 2, y: size / 2 - bounds.height * 0.46))
    }
    draw("A", color: .white, centerX: size * 0.36)
    draw("Я", color: orange, centerX: size * 0.65)

    // Тонкая светлая окантовка для контраста на тёмных обоях
    NSColor.white.withAlphaComponent(0.14).setStroke()
    shape.lineWidth = max(1, size * 0.006)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = "icon/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    let rep = drawIcon(size: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try? data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("iconset готов: \(iconset)")
