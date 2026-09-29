#!/usr/bin/env swift
// The app icon from docs/logo.png: the Mac sizes, an opaque square for the 1024 slot, and the same set
// under an orange DEV band for the development build.
//
//   swift scripts/appicon.swift docs/logo.png Savoia/Assets.xcassets/AppIcon.appiconset Savoia/Assets.xcassets/AppIcon-Dev.appiconset
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let logo = NSImage(contentsOfFile: args[1])!
var rect = CGRect(origin: .zero, size: logo.size)
let source = logo.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let W = CGFloat(source.width), H = CGFloat(source.height)
// The white body inside the drawn shadow, for iOS, which masks the corners itself.
let body = CGRect(x: W * 0.088, y: H * 0.080, width: W * 0.830, height: H * 0.830)

func render(_ size: Int, dev: Bool, opaque: Bool) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    if opaque {
        let crop = source.cropping(to: CGRect(x: body.minX, y: H - body.maxY, width: body.width, height: body.height))!
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: s, height: s))
        let whole = CGRect(x: 0, y: 0, width: s, height: s)
        ctx.addRect(whole)
        ctx.addPath(CGPath(roundedRect: whole.insetBy(dx: s * 0.01, dy: s * 0.01), cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
        ctx.setFillColor(NSColor(srgbRed: 0.980, green: 0.973, blue: 0.965, alpha: 1).cgColor)
        ctx.fillPath(using: .evenOdd)
    } else {
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: s, height: s))
    }
    if dev {
        ctx.saveGState()
        if !opaque {
            let inset = s * 0.088
            let path = CGPath(roundedRect: CGRect(x: inset, y: s * 0.09, width: s - 2 * inset, height: s - 2 * inset),
                              cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
            ctx.addPath(path); ctx.clip()
        }
        ctx.translateBy(x: s * 0.70, y: s * 0.26)
        ctx.rotate(by: .pi / 4)
        let band = CGRect(x: -s, y: -s * 0.075, width: 2 * s, height: s * 0.15)
        ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1).cgColor)
        ctx.fill(band)
        if size >= 64 {
            let font = NSFont.systemFont(ofSize: s * 0.095, weight: .heavy)
            let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.black, .kern: s * 0.01])
            let line = CTLineCreateWithAttributedString(text)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2 - bounds.minY)
            CTLineDraw(line, ctx)
        }
        ctx.restoreGState()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let mac: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (folder, dev) in [(args[2], false), (args[3], true)] {
    for (name, size) in mac {
        try! render(size, dev: dev, opaque: false).write(to: URL(fileURLWithPath: folder).appending(path: name))
    }
    try! render(1024, dev: dev, opaque: true).write(to: URL(fileURLWithPath: folder).appending(path: "icon_1024.png"))
}
