// Draws the app icon: `swift tools/gen_icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`

import AppKit

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: App Store Connect rejects icons that have one.
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

let colors = [CGColor(red: 0.20, green: 0.13, blue: 0.55, alpha: 1), CGColor(red: 0.05, green: 0.52, blue: 0.86, alpha: 1)]
let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

// Three rows of keys, staggered like a keyboard.
let key: CGFloat = 118, gap: CGFloat = 26
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
for (row, count) in [6, 5, 4].enumerated() {
    let width = CGFloat(count) * key + CGFloat(count - 1) * gap
    let y = 150 + CGFloat(2 - row) * (key + gap)
    for column in 0..<count {
        let x = (CGFloat(size) - width) / 2 + CGFloat(column) * (key + gap)
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: key, height: key), cornerWidth: 26, cornerHeight: 26, transform: nil))
    }
}
context.fillPath()

let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics
let title = NSMutableAttributedString()
let font = NSFont.systemFont(ofSize: 250, weight: .bold)
title.append(NSAttributedString(string: "k", attributes: [.font: font, .foregroundColor: NSColor.white]))
title.append(NSAttributedString(string: "AI", attributes: [.font: font, .foregroundColor: NSColor(red: 1, green: 0.84, blue: 0.3, alpha: 1)]))
let bounds = title.size()
title.draw(at: NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: 610))
graphics.flushGraphics()

let image = NSBitmapImageRep(cgImage: context.makeImage()!)
try! image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
