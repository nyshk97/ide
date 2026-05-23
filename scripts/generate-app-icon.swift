#!/usr/bin/env swift
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: generate-app-icon.swift <output.png> [size] [variant] [source.png]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let size: CGFloat = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1024) : 1024
// variant == "dev" のとき右下に DEV バッジを追加する。それ以外は素の本番アイコン。
let variant: String = args.count >= 4 ? args[3] : "release"

// ソース PNG (polepole-icon.png) を読む。引数で渡されなければスクリプトの 2 つ上から探す。
let sourcePath: String
if args.count >= 5 {
    sourcePath = args[4]
} else {
    let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    let scriptRoot = (scriptDir as NSString).deletingLastPathComponent
    sourcePath = (scriptRoot as NSString).appendingPathComponent("polepole-icon.png")
}

guard
    let sourceImage = NSImage(contentsOfFile: sourcePath),
    let rawSourceCG = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("failed to load source: \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

let cs = CGColorSpaceCreateDeviceRGB()

// polepole-icon.png は alpha なしで白背景が焼き込まれている。
// 外周から flood-fill で白〜近白を透過にする (象の内部にある highlight は border に
// 触れないので残る)。これによって下に敷くグラデーション背景が透けて見える。
let sourceCG: CGImage = {
    let w = rawSourceCG.width
    let h = rawSourceCG.height
    let bytesPerRow = w * 4
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let buf = CGContext(
        data: &px, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
    ) else { return rawSourceCG }
    buf.draw(rawSourceCG, in: CGRect(x: 0, y: 0, width: w, height: h))
    let threshold = 20
    @inline(__always) func idx(_ x: Int, _ y: Int) -> Int { (y * w + x) * 4 }
    @inline(__always) func isNearWhite(_ x: Int, _ y: Int) -> Bool {
        let i = idx(x, y)
        return (255 - Int(px[i])) <= threshold
            && (255 - Int(px[i + 1])) <= threshold
            && (255 - Int(px[i + 2])) <= threshold
    }
    var visited = [Bool](repeating: false, count: w * h)
    var stack: [(Int, Int)] = []
    for x in 0..<w {
        if isNearWhite(x, 0) { stack.append((x, 0)) }
        if isNearWhite(x, h - 1) { stack.append((x, h - 1)) }
    }
    for y in 0..<h {
        if isNearWhite(0, y) { stack.append((0, y)) }
        if isNearWhite(w - 1, y) { stack.append((w - 1, y)) }
    }
    while let (x, y) = stack.popLast() {
        if x < 0 || y < 0 || x >= w || y >= h { continue }
        let v = y * w + x
        if visited[v] { continue }
        if !isNearWhite(x, y) { continue }
        visited[v] = true
        px[idx(x, y) + 3] = 0
        stack.append((x + 1, y))
        stack.append((x - 1, y))
        stack.append((x, y + 1))
        stack.append((x, y - 1))
    }
    return buf.makeImage() ?? rawSourceCG
}()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

let cornerRadius = size * 0.2237  // macOS squircle approximation
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// squircle の中だけグラデーション背景 (淡い空色 → 中間の青)。
let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.85, green: 0.92, blue: 1.00, alpha: 1), // #D9EBFF (top)
        CGColor(red: 0.62, green: 0.78, blue: 0.98, alpha: 1), // #9EC7FA (bottom)
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// ソース画像をアスペクト比維持でフィット (短辺合わせ) し、padding 分だけ拡大する。
// source PNG (polepole-icon.png) は象の周囲に余白を含んでおり、そのまま fit すると
// squircle 内で小さく見える。zoom > 1 で実質的に padding を削る（squircle で clip 済み）。
let srcW = CGFloat(sourceCG.width)
let srcH = CGFloat(sourceCG.height)
let zoom: CGFloat = 1.45
let scale = min(size / srcW, size / srcH) * zoom
let drawW = srcW * scale
let drawH = srcH * scale
let drawRect = CGRect(
    x: (size - drawW) / 2,
    y: (size - drawH) / 2,
    width: drawW,
    height: drawH
)
ctx.draw(sourceCG, in: drawRect)

ctx.restoreGState()

if variant == "dev" {
    let badgeRadius = size * 0.27
    let badgeCX = size * 0.78
    let badgeCY = size * 0.22  // CG 座標（y up）。右下に配置。
    let badgeRect = CGRect(
        x: badgeCX - badgeRadius,
        y: badgeCY - badgeRadius,
        width: badgeRadius * 2,
        height: badgeRadius * 2
    )

    // ドロップシャドウ付きで赤バッジを描く。
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.010),
        blur: size * 0.022,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    )
    ctx.addEllipse(in: badgeRect)
    let badgeGradient = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor(red: 0.97, green: 0.32, blue: 0.32, alpha: 1.0),
            CGColor(red: 0.78, green: 0.10, blue: 0.10, alpha: 1.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.saveGState()
    ctx.clip()
    ctx.drawLinearGradient(
        badgeGradient,
        start: CGPoint(x: badgeCX, y: badgeCY + badgeRadius),
        end: CGPoint(x: badgeCX, y: badgeCY - badgeRadius),
        options: []
    )
    ctx.restoreGState()
    ctx.restoreGState()

    // 白い細い縁取り。
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(size * 0.013)
    ctx.strokeEllipse(in: badgeRect)
    ctx.restoreGState()

    // "DEV" の白テキスト。AppKit 経由で描画。
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font = NSFont.systemFont(ofSize: size * 0.115, weight: .heavy)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: size * 0.004,
        .paragraphStyle: paragraph,
    ]
    let text = NSAttributedString(string: "DEV", attributes: attrs)
    let textSize = text.size()
    let textRect = CGRect(
        x: badgeCX - textSize.width / 2,
        // baseline 調整: 視覚的に縦中央にくるよう少し下げる。
        y: badgeCY - textSize.height / 2 - size * 0.008,
        width: textSize.width,
        height: textSize.height
    )
    text.draw(in: textRect)
    NSGraphicsContext.restoreGraphicsState()
}

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
