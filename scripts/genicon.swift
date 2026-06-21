// NeatZip アプリアイコンを生成する。リポジトリ直下で実行:
//   swift scripts/genicon.swift
// doc.zipper(SF Symbol) を白で、ブルーのスクワークル背景に描き、AppIcon.appiconset へ各サイズ書き出す。
import AppKit
import Foundation

let outDir = FileManager.default.currentDirectoryPath
    + "/Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func whiteSymbol(pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    let base = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let tinted = NSImage(size: base.size)
    tinted.lockFocus()
    base.draw(at: .zero, from: NSRect(origin: .zero, size: base.size), operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func makeIcon(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let radius = rect.width * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let grad = NSGradient(starting: NSColor(srgbRed: 0.29, green: 0.57, blue: 0.90, alpha: 1),
                          ending:   NSColor(srgbRed: 0.16, green: 0.40, blue: 0.74, alpha: 1))!
    grad.draw(in: path, angle: -90)

    let sym = whiteSymbol(pointSize: size * 0.5)
    let target = size * 0.52
    let aspect = sym.size.width / sym.size.height
    let w = aspect >= 1 ? target : target * aspect
    let h = aspect >= 1 ? target / aspect : target
    let symRect = NSRect(x: (size - w)/2, y: (size - h)/2, width: w, height: h)
    sym.draw(in: symRect, from: NSRect(origin: .zero, size: sym.size), operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    try! makeIcon(px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
    print("wrote icon_\(px).png")
}
print("done")
