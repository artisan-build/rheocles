#!/usr/bin/env swift
// Render the menu bar icons: the mark in every state the icon can show,
// as template PNGs for Electron's Tray. Run from php/: `swift bin/make-icons.swift`.
//
// Geometry is site/src/components/Mark.astro's, verbatim, on a 32-unit box —
// the same shape the Swift app draws in RheoclesMark.swift, at the same 18 pt
// with the same 3.2 weight, so the two menu bars show one mark. Three states
// (spec §12): idle dims the whole mark to 40 %, armed is the mark at full
// strength, recording adds a filled dot at the bar's foot. A late-joined
// stream is a shorter stroke that starts to the right of the bar, so the
// recording state is rendered once per four-bit mask, top stroke first.
//
// Electron treats a file whose name ends in `Template` as a template image
// (alpha only, tinted to the bar) and picks the `@2x` file on Retina itself.
import AppKit
import CoreGraphics

let strokes: [(y: CGFloat, c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
    (8.5, CGPoint(x: 12, y: 8), CGPoint(x: 20, y: 9.2), CGPoint(x: 28, y: 8.5)),
    (14, CGPoint(x: 11, y: 13.6), CGPoint(x: 17, y: 14.6), CGPoint(x: 22, y: 14)),
    (19.5, CGPoint(x: 13, y: 19), CGPoint(x: 19, y: 20.2), CGPoint(x: 26, y: 19.5)),
    (25, CGPoint(x: 10, y: 24.7), CGPoint(x: 14, y: 25.4), CGPoint(x: 18, y: 25)),
]
let barX: CGFloat = 5
let lateStart: CGFloat = 13
let side: CGFloat = 18
let weight: CGFloat = 3.2

func render(late: Set<Int>, cueDot: Bool, opacity: CGFloat, scale: CGFloat) -> Data {
    let px = Int(side * scale)
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to top-left origin like SwiftUI/SVG.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    let k = side * scale / 32
    ctx.setLineWidth(weight * k)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: opacity))
    ctx.setFillColor(CGColor(gray: 0, alpha: opacity))

    ctx.move(to: CGPoint(x: barX * k, y: 4 * k))
    ctx.addLine(to: CGPoint(x: barX * k, y: (cueDot ? 25 : 28) * k))
    ctx.strokePath()
    if cueDot {
        let r = 4.6 * k / 2
        ctx.fillEllipse(in: CGRect(x: barX * k - r, y: 30.2 * k - r, width: 2 * r, height: 2 * r))
    }
    for (i, s) in strokes.enumerated() {
        let startX = late.contains(i) ? lateStart : barX
        ctx.move(to: CGPoint(x: startX * k, y: s.y * k))
        ctx.addCurve(
            to: CGPoint(x: s.end.x * k, y: s.end.y * k),
            control1: CGPoint(x: s.c1.x * k, y: s.c1.y * k),
            control2: CGPoint(x: s.c2.x * k, y: s.c2.y * k))
        ctx.strokePath()
    }
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: "resources/menubar", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var states: [(name: String, late: Set<Int>, dot: Bool, opacity: CGFloat)] = [
    ("rheoIdleTemplate", [], false, 0.4),
    ("rheoArmedTemplate", [], false, 1),
]
for mask in 0..<16 {
    var late = Set<Int>()
    var bits = ""
    for i in 0..<4 {
        let on = (mask >> (3 - i)) & 1 == 1
        bits += on ? "1" : "0"
        if on { late.insert(i) }
    }
    states.append(("rheoRecording\(bits)Template", late, true, 1))
}
for s in states {
    try render(late: s.late, cueDot: s.dot, opacity: s.opacity, scale: 1)
        .write(to: out.appending(path: "\(s.name).png"))
    try render(late: s.late, cueDot: s.dot, opacity: s.opacity, scale: 2)
        .write(to: out.appending(path: "\(s.name)@2x.png"))
}
print("rendered \(states.count) states × 2 scales → resources/menubar/")
