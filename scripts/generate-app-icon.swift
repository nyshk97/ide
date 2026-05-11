#!/usr/bin/env swift
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: generate-app-icon.swift <output.png> [size] [variant]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let size: CGFloat = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1024) : 1024
// variant == "dev" のとき右下に DEV バッジを追加する。それ以外は素の本番アイコン。
let variant: String = args.count >= 4 ? args[3] : "release"

let cs = CGColorSpaceCreateDeviceRGB()
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

let bgGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.105, green: 0.110, blue: 0.140, alpha: 1.0),
        CGColor(red: 0.035, green: 0.035, blue: 0.060, alpha: 1.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: 0),
    options: []
)

let topGlow = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.07),
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    topGlow,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: 0, y: size * 0.55),
    options: []
)

let cx = size * 0.430
let cy = size * 0.515
let chevW = size * 0.290
let chevH = size * 0.410
let stroke = size * 0.130

let chevPath = CGMutablePath()
chevPath.move(to: CGPoint(x: cx - chevW / 2, y: cy + chevH / 2))
chevPath.addLine(to: CGPoint(x: cx + chevW / 2, y: cy))
chevPath.addLine(to: CGPoint(x: cx - chevW / 2, y: cy - chevH / 2))

let strokedChev = chevPath.copy(
    strokingWithWidth: stroke,
    lineCap: .round,
    lineJoin: .round,
    miterLimit: 10
)

ctx.saveGState()
ctx.addPath(strokedChev)
ctx.clip()

let chevGradient = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.000, green: 0.780, blue: 1.000, alpha: 1.0),
        CGColor(red: 0.482, green: 0.357, blue: 1.000, alpha: 1.0),
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    chevGradient,
    start: CGPoint(x: cx - chevW / 2, y: cy + chevH / 2 + stroke / 2),
    end: CGPoint(x: cx + chevW / 2, y: cy - chevH / 2 - stroke / 2),
    options: []
)
ctx.restoreGState()

let cursorW = size * 0.110
let cursorH = size * 0.028
let cursorX = cx + chevW / 2 + stroke * 0.60
let cursorY = cy - chevH / 2 - cursorH * 0.5
let cursorRect = CGRect(x: cursorX, y: cursorY, width: cursorW, height: cursorH)
let cursorPath = CGPath(
    roundedRect: cursorRect,
    cornerWidth: cursorH / 2,
    cornerHeight: cursorH / 2,
    transform: nil
)

ctx.addPath(cursorPath)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

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
