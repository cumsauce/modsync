// Renders the modsync app icon at 1024x1024.
//
// Drawn with CoreGraphics rather than shipped as a binary blob so the mark is
// reproducible and reviewable in the repo: an Arctic Cyan rounded tile carrying
// two opposed arrows, which reads as "sync" even at 16px.
//
// Usage: swift scripts/make-icon.swift <out.png>

import CoreGraphics
import Foundation
import ImageIO

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-1024.png"

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()

guard let ctx = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("cannot create bitmap context\n".data(using: .utf8)!)
    exit(1)
}

// Flip to a top-left origin so the numbers below read like CSS.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let accent = rgb(125, 227, 245)      // #7DE3F5
let tileTop = rgb(11, 17, 22)        // #0B1116
let tileBottom = rgb(9, 13, 16)      // #090D10

// macOS icon grid: 824x824 artwork centred on a 1024 canvas.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tile = CGPath(
    roundedRect: tileRect,
    cornerWidth: 185,
    cornerHeight: 185,
    transform: nil
)

ctx.saveGState()
ctx.addPath(tile)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: space,
    colors: [tileTop, tileBottom] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 512, y: 100),
    end: CGPoint(x: 512, y: 924),
    options: []
)

// Soft cyan bloom in the upper third, so the tile has a light source.
let bloom = CGGradient(
    colorsSpace: space,
    colors: [rgb(0, 200, 242, 0.30), rgb(0, 200, 242, 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(
    bloom,
    startCenter: CGPoint(x: 512, y: 370),
    startRadius: 0,
    endCenter: CGPoint(x: 512, y: 370),
    endRadius: 430,
    options: []
)
ctx.restoreGState()

// Hairline highlight on the tile edge.
ctx.addPath(CGPath(
    roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5),
    cornerWidth: 184,
    cornerHeight: 184,
    transform: nil
))
ctx.setStrokeColor(rgb(255, 255, 255, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

// Two opposed arrows: right on the upper line, left on the lower one.
ctx.setFillColor(accent)
ctx.setStrokeColor(accent)
ctx.setLineWidth(66)
ctx.setLineCap(.round)

// Upper arrow, pointing right.
ctx.move(to: CGPoint(x: 310, y: 440))
ctx.addLine(to: CGPoint(x: 620, y: 440))
ctx.strokePath()
ctx.addLines(between: [
    CGPoint(x: 620, y: 375),
    CGPoint(x: 715, y: 440),
    CGPoint(x: 620, y: 505),
])
ctx.closePath()
ctx.fillPath()

// Lower arrow, pointing left.
ctx.move(to: CGPoint(x: 714, y: 584))
ctx.addLine(to: CGPoint(x: 404, y: 584))
ctx.strokePath()
ctx.addLines(between: [
    CGPoint(x: 404, y: 519),
    CGPoint(x: 309, y: 584),
    CGPoint(x: 404, y: 649),
])
ctx.closePath()
ctx.fillPath()

guard let image = ctx.makeImage() else {
    FileHandle.standardError.write("cannot make image\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(
    url as CFURL,
    "public.png" as CFString,
    1,
    nil
) else {
    FileHandle.standardError.write("cannot create png destination\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("cannot write png\n".data(using: .utf8)!)
    exit(1)
}
