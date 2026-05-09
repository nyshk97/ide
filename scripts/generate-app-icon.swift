#!/usr/bin/env swift
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: generate-app-icon.swift <output.png> [size]\n".data(using: .utf8)!)
    exit(2)
}
let outPath = args[1]
let size: CGFloat = args.count >= 3 ? CGFloat(Double(args[2]) ?? 1024) : 1024

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

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
rep.size = NSSize(width: size, height: size)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
