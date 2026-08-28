#!/usr/bin/env swift
import AppKit
import Foundation

// six's icon, drawn rather than painted: the strip itself — three columns side by side, the focused
// one tall and bright in the middle, its neighbours dimmer and running off both edges, which is what
// a niri strip looks like and what no other browser's icon says. At 16 pt the detail goes and the
// silhouette stays: three bars, the middle one taller.
//
//   swift scripts/appicon.swift <AppIcon.appiconset> [<AppIcon-Dev.appiconset>]
//
// The second folder, if given, gets the same icon under an amber DEV ribbon — the development
// build's, so the two can be told apart in the dock (docs/build.md).

func draw(_ pixels: Int, development: Bool) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    // Straight into a bitmap of the exact pixel size: an NSImage with `lockFocus` renders at the
    // screen's backing scale and comes out twice as big on a Retina Mac, which actool rejects.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)

    let inset = size * 0.05
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.235
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let top = NSColor(calibratedRed: 0.49, green: 0.38, blue: 0.95, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.50, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    context.saveGState()
    shape.addClip()

    // Three columns on one baseline, the middle one taller and brighter. The outer two are cut off by
    // the icon's own edge on purpose: a strip continues past the screen, and that is the whole idea.
    let columnWidth = body.width * 0.30
    let gap = body.width * 0.055
    let sideWidth = body.width * 0.38
    let centreHeight = body.height * 0.62
    let sideHeight = body.height * 0.46
    let baseline = body.minY + (body.height - centreHeight) / 2
    let middle = body.midX

    func column(x: CGFloat, width: CGFloat, height: CGFloat, white: CGFloat, alpha: CGFloat) {
        let rect = CGRect(x: x, y: baseline, width: width, height: height)
        let corner = width * 0.19
        let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        NSColor(calibratedWhite: white, alpha: alpha).setFill()
        path.fill()
        // A title bar, once there is room to see one. Below that it is mud.
        guard pixels >= 256 else { return }
        let bar = CGRect(x: rect.minX, y: rect.maxY - height * 0.14, width: width, height: height * 0.14)
        let capped = NSBezierPath(roundedRect: bar, xRadius: corner, yRadius: corner)
        let square = NSBezierPath(rect: CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: bar.height * 0.55))
        capped.append(square)
        NSColor(calibratedWhite: white, alpha: alpha * 0.42).setFill()
        capped.fill()
    }

    // Wide enough to be cut off by the icon's own edge: a strip does not stop at the screen, and the
    // neighbours running out of frame is the one thing that says so.
    column(x: middle - columnWidth / 2 - gap - sideWidth, width: sideWidth,
           height: sideHeight, white: 1, alpha: 0.32)
    column(x: middle + columnWidth / 2 + gap, width: sideWidth,
           height: sideHeight, white: 1, alpha: 0.32)

    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.045,
                      color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
    column(x: middle - columnWidth / 2, width: columnWidth, height: centreHeight, white: 0.99, alpha: 1)
    context.setShadow(offset: .zero, blur: 0, color: nil)

    if development {
        let amber = NSColor(calibratedRed: 1.0, green: 0.63, blue: 0.09, alpha: 1)
        let band = NSBezierPath()
        band.move(to: NSPoint(x: size * 0.30, y: 0))
        band.line(to: NSPoint(x: size, y: size * 0.70))
        band.line(to: NSPoint(x: size, y: size * 0.38))
        band.line(to: NSPoint(x: size * 0.62, y: 0))
        band.close()
        amber.setFill()
        band.fill()
        if pixels >= 64 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.125, weight: .heavy),
                .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.02, alpha: 1),
                .kern: size * 0.012,
            ]
            let text = NSAttributedString(string: "DEV", attributes: attributes)
            context.translateBy(x: size * 0.665, y: size * 0.175)
            context.rotate(by: .pi / 4)
            text.draw(at: NSPoint(x: -text.size().width / 2, y: -text.size().height / 2))
        }
    }
    context.restoreGState()

    // The sheen: a soft highlight over the top third, which is what keeps a flat gradient from
    // reading as a sticker next to the system's own icons.
    context.saveGState()
    shape.addClip()
    let sheen = NSGradient(colors: [NSColor(calibratedWhite: 1, alpha: 0.18),
                                    NSColor(calibratedWhite: 1, alpha: 0)])!
    sheen.draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    context.restoreGState()

    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    shape.lineWidth = max(1, size * 0.006)
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(to folder: URL, development: Bool) {
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var entries: [[String: String]] = []
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = base * scale
            let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
            guard let png = draw(pixels, development: development).representation(using: .png, properties: [:]) else { continue }
            try! png.write(to: folder.appendingPathComponent(name))
            entries.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(base)x\(base)", "filename": name])
        }
    }
    // One 1024 for the phone, which takes a single size and masks it itself.
    if let png = draw(1024, development: development).representation(using: .png, properties: [:]) {
        try! png.write(to: folder.appendingPathComponent("icon_1024.png"))
        entries.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_1024.png"])
    }
    let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
    let data = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try! data.write(to: folder.appendingPathComponent("Contents.json"))
    print("wrote \(entries.count) images to \(folder.lastPathComponent)")
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fatalError("usage: appicon.swift <AppIcon.appiconset> [<AppIcon-Dev.appiconset>]") }
write(to: URL(fileURLWithPath: arguments[1]), development: false)
if arguments.count >= 3 { write(to: URL(fileURLWithPath: arguments[2]), development: true) }
