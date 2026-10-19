#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Keep the Imagegen artwork intact. This only applies the macOS icon canvas and
// continuous corner mask, then downsamples the result for both build paths.
let roomDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resources = roomDirectory.appendingPathComponent("Resources")
let artwork = resources.appendingPathComponent("roomy-icon-master.png")
let catalog = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")

func fail(_ message: String) -> Never {
    fputs("Icon generation failed: \(message)\n", stderr)
    exit(1)
}

guard let source = CGImageSourceCreateWithURL(artwork as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
      original.width == original.height else {
    fail("roomy-icon-master.png must contain square artwork")
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func context(_ size: Int) -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not allocate the \(size)-pixel canvas")
    }
    context.interpolationQuality = .high
    return context
}

// The established macOS 1024-pixel grid has an 824-pixel icon body, centered.
// The source image's interior, lighting, and reflections are never redrawn.
let canvas = context(1024)
let outline = CGMutablePath()
outline.move(to: CGPoint(x: 512, y: 100))
outline.addCurve(to: CGPoint(x: 863, y: 161), control1: CGPoint(x: 712, y: 100), control2: CGPoint(x: 802, y: 100))
outline.addCurve(to: CGPoint(x: 924, y: 512), control1: CGPoint(x: 924, y: 222), control2: CGPoint(x: 924, y: 312))
outline.addCurve(to: CGPoint(x: 863, y: 863), control1: CGPoint(x: 924, y: 712), control2: CGPoint(x: 924, y: 802))
outline.addCurve(to: CGPoint(x: 512, y: 924), control1: CGPoint(x: 802, y: 924), control2: CGPoint(x: 712, y: 924))
outline.addCurve(to: CGPoint(x: 161, y: 863), control1: CGPoint(x: 312, y: 924), control2: CGPoint(x: 222, y: 924))
outline.addCurve(to: CGPoint(x: 100, y: 512), control1: CGPoint(x: 100, y: 802), control2: CGPoint(x: 100, y: 712))
outline.addCurve(to: CGPoint(x: 161, y: 161), control1: CGPoint(x: 100, y: 312), control2: CGPoint(x: 100, y: 222))
outline.addCurve(to: CGPoint(x: 512, y: 100), control1: CGPoint(x: 222, y: 100), control2: CGPoint(x: 312, y: 100))
outline.closeSubpath()
canvas.addPath(outline)
canvas.clip()
canvas.draw(original, in: CGRect(x: 100, y: 100, width: 824, height: 824))
guard let master = canvas.makeImage() else { fail("could not render the master") }

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finish \(url.lastPathComponent)") }
}

write(master, to: resources.appendingPathComponent("roomy-icon-1024.png"))
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let scaled = context(pixels)
        scaled.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = scaled.makeImage() else { fail("could not resize to \(pixels)") }
        let suffix = scale == 1 ? "" : "@2x"
        write(image, to: catalog.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
print("Roomy icon: original \(original.width)×\(original.height) artwork → 1024 master and all 10 macOS icon slots")
