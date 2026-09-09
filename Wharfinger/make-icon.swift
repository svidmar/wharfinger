// Draws the Wharfinger app icon (a mooring bollard on a harbour-blue tile) and writes AppIcon.icns.
// Run via ./build.sh --icon. Output: Wharfinger/AppIcon.icns

import AppKit

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let inset = s * 0.05                          // macOS icons leave a margin inside the tile
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.225

    // Tile: deep harbour blue → teal
    let bg = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
    NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.19, blue: 0.36, alpha: 1),
                        NSColor(calibratedRed: 0.03, green: 0.42, blue: 0.53, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // Water line at the bottom
    let water = NSBezierPath()
    let wy = tile.minY + tile.height * 0.22
    water.move(to: NSPoint(x: tile.minX, y: wy))
    let waves = 5
    let ww = tile.width / CGFloat(waves)
    for i in 0..<waves {
        let x0 = tile.minX + ww * CGFloat(i)
        water.curve(to: NSPoint(x: x0 + ww, y: wy),
                    controlPoint1: NSPoint(x: x0 + ww * 0.25, y: wy + tile.height * 0.035),
                    controlPoint2: NSPoint(x: x0 + ww * 0.75, y: wy - tile.height * 0.035))
    }
    water.line(to: NSPoint(x: tile.maxX, y: tile.minY))
    water.line(to: NSPoint(x: tile.minX, y: tile.minY))
    water.close()
    bg.addClip()
    NSColor(calibratedRed: 0.02, green: 0.30, blue: 0.45, alpha: 0.9).setFill()
    water.fill()

    // Quay: a dark ledge the bollard stands on
    let quay = NSRect(x: tile.minX, y: wy - tile.height * 0.01, width: tile.width, height: tile.height * 0.08)
    NSColor(calibratedWhite: 0.12, alpha: 0.55).setFill()
    NSBezierPath(rect: quay).fill()

    // Bollard: post + cap, in warm white
    let cx = tile.midX
    let postW = tile.width * 0.26
    let postBottom = quay.maxY
    let postTop = tile.minY + tile.height * 0.70
    let post = NSBezierPath(roundedRect: NSRect(x: cx - postW / 2, y: postBottom, width: postW, height: postTop - postBottom),
                            xRadius: postW * 0.12, yRadius: postW * 0.12)
    let capW = postW * 1.55
    let capH = tile.height * 0.13
    let cap = NSBezierPath(roundedRect: NSRect(x: cx - capW / 2, y: postTop - capH * 0.35, width: capW, height: capH),
                           xRadius: capH * 0.5, yRadius: capH * 0.5)
    let ivory = NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.88, alpha: 1)
    let ropeColor = NSColor(calibratedRed: 0.93, green: 0.56, blue: 0.18, alpha: 1)
    let ry = postBottom + (postTop - postBottom) * 0.42
    let loop = NSRect(x: cx - postW * 0.85, y: ry - tile.height * 0.055, width: postW * 1.7, height: tile.height * 0.11)
    // back half of the rope loop goes behind the post
    let back = NSBezierPath()
    back.appendArc(withCenter: NSPoint(x: loop.midX, y: loop.midY), radius: 1, startAngle: 0, endAngle: 180)
    let backT = AffineTransform(translationByX: loop.midX, byY: loop.midY)
    var scaleT = AffineTransform(scaleByX: loop.width / 2, byY: loop.height / 2)
    scaleT.append(backT)
    let backArc = NSBezierPath()
    backArc.appendArc(withCenter: .zero, radius: 1, startAngle: 0, endAngle: 180)
    backArc.transform(using: scaleT)
    backArc.lineWidth = s * 0.045
    ropeColor.shadow(withLevel: 0.25)!.setStroke()
    backArc.stroke()
    // soft shadow
    NSColor(calibratedWhite: 0, alpha: 0.25).setFill()
    post.transform(using: AffineTransform(translationByX: s * 0.012, byY: -s * 0.012)); post.fill()
    cap.transform(using: AffineTransform(translationByX: s * 0.012, byY: -s * 0.012)); cap.fill()
    post.transform(using: AffineTransform(translationByX: -s * 0.012, byY: s * 0.012))
    cap.transform(using: AffineTransform(translationByX: -s * 0.012, byY: s * 0.012))
    ivory.setFill()
    post.fill()
    cap.fill()

    // Front half of the rope loop, in front of the post
    let frontArc = NSBezierPath()
    frontArc.appendArc(withCenter: .zero, radius: 1, startAngle: 180, endAngle: 360)
    frontArc.transform(using: scaleT)
    frontArc.lineWidth = s * 0.045
    frontArc.lineCapStyle = .round
    ropeColor.setStroke()
    frontArc.stroke()
    // rope tail running off to the right, into the water
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: loop.maxX, y: loop.midY))
    tail.curve(to: NSPoint(x: tile.maxX, y: wy - tile.height * 0.06),
               controlPoint1: NSPoint(x: cx + postW * 1.6, y: ry - tile.height * 0.02),
               controlPoint2: NSPoint(x: tile.maxX - tile.width * 0.12, y: wy + tile.height * 0.04))
    tail.lineWidth = s * 0.045
    tail.lineCapStyle = .round
    tail.stroke()

    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Wharfinger/AppIcon.icns"
let set = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! png(draw(size: CGFloat(px)), px).write(to: URL(fileURLWithPath: set + "/" + name))
    }
}
try? FileManager.default.createDirectory(atPath: "docs", withIntermediateDirectories: true)
try! png(draw(size: 256), 256).write(to: URL(fileURLWithPath: "docs/icon.png"))   // used by the README
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set, "-o", out]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
