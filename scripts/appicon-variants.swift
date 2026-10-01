#!/usr/bin/env swift
// The alternative app icons, as image sets Settings can switch between at run time: the light and the dark
// plate as drawn, and the same wings laid over backgrounds sampled from those plates. Also the wings alone.
//
//   swift scripts/appicon-variants.swift <art folder> Savoia/Assets.xcassets Savoia
//
// The bundle's own icon is a pair of full-bleed pictures, light and dark, in an Icon Composer document
// (AppIcon.icon, and AppIcon-Dev.icon with the DEV band): the system draws a quit app from it and picks the
// appearance itself.
//
// The art folder holds sky.png, light.png, dark.png (full plates), wings-light.png (one pair of wings, transparent) and
// wings-pair.png (light wings on the left, dark on the right, transparent).
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let art = URL(fileURLWithPath: args[1]), catalog = URL(fileURLWithPath: args[2]), sources = URL(fileURLWithPath: args[3])

func load(_ name: String) -> CGImage {
    let image = NSImage(contentsOf: art.appending(path: name))!
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

let S = 1024
let canvas = CGFloat(S)
let bodySize = canvas * 0.82
var body = CGRect(x: (canvas - bodySize) / 2, y: (canvas - bodySize) / 2, width: bodySize, height: bodySize)
let radius = bodySize * 0.225
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// The plate's own square inside its picture, in top-left pixels.
let lightPlate = CGRect(x: 46, y: 46, width: 1164, height: 1164)
let darkPlate = CGRect(x: 56, y: 50, width: 1135, height: 1135)

func colour(at point: CGPoint, in image: CGImage) -> CGColor {
    let data = NSBitmapImageRep(cgImage: image)
    var r = 0.0, g = 0.0, b = 0.0, n = 0.0
    for dx in -6...6 {
        for dy in -6...6 {
            guard let c = data.colorAt(x: Int(point.x) + dx, y: Int(point.y) + dy)?.usingColorSpace(.sRGB) else { continue }
            r += c.redComponent; g += c.greenComponent; b += c.blueComponent; n += 1
        }
    }
    return CGColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
}

/// Four corner colours blended across the body — the bilinear sky of the plates, wings left out.
func gradient(_ ctx: CGContext, tl: CGColor, tr: CGColor, bl: CGColor, br: CGColor) {
    let steps = 96
    let cell = body.width / CGFloat(steps)
    func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> [CGFloat] {
        let x = a.components!, y = b.components!
        return (0..<3).map { x[$0] + (y[$0] - x[$0]) * t }
    }
    for i in 0..<steps {
        for j in 0..<steps {
            let u = CGFloat(i) / CGFloat(steps - 1), v = CGFloat(j) / CGFloat(steps - 1)
            let top = mix(tl, tr, u), bottom = mix(bl, br, u)
            let c = (0..<3).map { top[$0] + (bottom[$0] - top[$0]) * v }
            ctx.setFillColor(CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1))
            ctx.fill(CGRect(x: body.minX + CGFloat(i) * cell, y: body.maxY - CGFloat(j + 1) * cell,
                            width: cell + 1, height: cell + 1))
        }
    }
}

func glow(_ ctx: CGContext, at point: CGPoint, radius: CGFloat, color: CGColor) {
    let colors = [color, color.copy(alpha: 0)!] as CFArray
    let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: point, startRadius: 0, endCenter: point, endRadius: radius, options: [])
}

/// Wings scaled so their drawn extent is a share of the body, centred on it.
func place(_ ctx: CGContext, wings: CGImage, share: CGFloat, lift: CGFloat = 0) {
    let rep = NSBitmapImageRep(cgImage: wings)
    var minX = wings.width, maxX = 0, minY = wings.height, maxY = 0
    for y in 0..<wings.height {
        for x in 0..<wings.width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let extent = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    let crop = wings.cropping(to: extent)!
    let scale = body.width * share / extent.width
    let size = CGSize(width: extent.width * scale, height: extent.height * scale)
    ctx.draw(crop, in: CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2 + lift * body.height,
                              width: size.width, height: size.height))
}

func render(_ name: String, fill: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.025,
                  color: CGColor(gray: 0, alpha: 0.30))
    ctx.addPath(shape); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    fill(ctx)
    ctx.restoreGState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let folder = catalog.appending(path: "\(name).imageset")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: folder.appending(path: "\(name).png"))
    let contents = """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! contents.write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

/// The picture over the whole canvas, no mask and no shadow, for the bundle's icon document.
func bleed(_ file: String, document: String, band: Bool, fill: (CGContext) -> Void) {
    let kept = body
    body = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    defer { body = kept }
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    fill(ctx)
    if band {
        ctx.translateBy(x: canvas * 0.70, y: canvas * 0.26)
        ctx.rotate(by: .pi / 4)
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.62, blue: 0.10, alpha: 1))
        ctx.fill(CGRect(x: -canvas, y: -canvas * 0.075, width: 2 * canvas, height: canvas * 0.15))
        let font = NSFont.systemFont(ofSize: canvas * 0.095, weight: .heavy)
        let text = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor.black, .kern: canvas * 0.01])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2 - bounds.minY)
        CTLineDraw(line, ctx)
    }
    let folder = sources.appending(path: "\(document).icon/Assets")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: folder.appending(path: file))
    let json = """
    {
      "fill" : "system-light",
      "groups" : [
        {
          "layers" : [
            {
              "glass" : false,
              "image-name" : "light.png",
              "image-name-specializations" : [
                {
                  "appearance" : "dark",
                  "value" : "dark.png"
                }
              ],
              "name" : "picture"
            }
          ],
          "shadow" : {
            "kind" : "none",
            "opacity" : 0
          },
          "translucency" : {
            "enabled" : false,
            "value" : 0
          }
        }
      ],
      "supported-platforms" : {
        "squares" : [
          "macOS"
        ]
      }
    }

    """
    try! json.write(to: sources.appending(path: "\(document).icon/icon.json"), atomically: true, encoding: .utf8)
}

func plate(_ image: CGImage, square: CGRect) -> (CGContext) -> Void {
    { ctx in
        let crop = image.cropping(to: square)!
        ctx.draw(crop, in: body)
    }
}

let light = load("light.png"), dark = load("dark.png"), sky = load("sky.png")
let wingsLight = load("wings-light.png"), pair = load("wings-pair.png")
let wingsDark = pair.cropping(to: CGRect(x: pair.width / 2, y: 0, width: pair.width / 2, height: pair.height))!

render("IconSky", fill: plate(sky, square: CGRect(x: 68, y: 73, width: 1122, height: 1122)))
render("IconLight", fill: plate(light, square: lightPlate))
render("IconDark", fill: plate(dark, square: darkPlate))

let lightSky = (
    tl: colour(at: CGPoint(x: 150, y: 150), in: light), tr: colour(at: CGPoint(x: 1090, y: 110), in: light),
    bl: colour(at: CGPoint(x: 220, y: 1160), in: light), br: colour(at: CGPoint(x: 1090, y: 1150), in: light)
)
render("IconLightWings") { ctx in
    gradient(ctx, tl: lightSky.tl, tr: lightSky.tr, bl: lightSky.bl, br: lightSky.br)
    place(ctx, wings: wingsLight, share: 0.80)
}

let darkSky = (
    tl: colour(at: CGPoint(x: 150, y: 150), in: dark), tr: colour(at: CGPoint(x: 1090, y: 110), in: dark),
    bl: colour(at: CGPoint(x: 220, y: 1130), in: dark), br: colour(at: CGPoint(x: 1090, y: 1130), in: dark)
)
render("IconDarkWings") { ctx in
    gradient(ctx, tl: darkSky.tl, tr: darkSky.tr, bl: darkSky.bl, br: darkSky.br)
    glow(ctx, at: CGPoint(x: body.maxX, y: body.minY + body.height * 0.38), radius: body.width * 0.7,
         color: CGColor(srgbRed: 0.97, green: 0.55, blue: 0.27, alpha: 0.55))
    place(ctx, wings: wingsDark, share: 0.80)
}

for (document, band) in [("AppIcon", false), ("AppIcon-Dev", true)] {
    bleed("light.png", document: document, band: band) { ctx in
        gradient(ctx, tl: lightSky.tl, tr: lightSky.tr, bl: lightSky.bl, br: lightSky.br)
        place(ctx, wings: wingsLight, share: 0.74)
    }
    bleed("dark.png", document: document, band: band) { ctx in
        gradient(ctx, tl: darkSky.tl, tr: darkSky.tr, bl: darkSky.bl, br: darkSky.br)
        glow(ctx, at: CGPoint(x: body.maxX, y: body.minY + body.height * 0.38), radius: body.width * 0.7,
             color: CGColor(srgbRed: 0.97, green: 0.55, blue: 0.27, alpha: 0.55))
        place(ctx, wings: wingsDark, share: 0.74)
    }
}

// The wings alone, on transparency, for the start page: the pair drawn for light grounds and for dark ones.
func save(_ image: CGImage, as name: String) {
    let folder = catalog.appending(path: "\(name).imageset")
    try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        .write(to: folder.appending(path: "\(name).png"))
    try! """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """.write(to: folder.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}

save(wingsLight, as: "Wings")
save(wingsDark, as: "WingsDark")
