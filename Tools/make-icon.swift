#!/usr/bin/env swift
//
// Draws m_text's app icon and writes an `.iconset` directory (T105).
//
// The icon is **drawn in code** rather than checked in as binary art: this project has no
// design tools, no network, and no third-party dependencies, and a generated icon can be
// regenerated at any size without anyone needing the original artboard. It also keeps the
// repository free of a binary blob nobody can diff.
//
// Run via `make icon`, which then hands the .iconset to `iconutil`. Uses only CoreGraphics
// and Foundation, both of which ship with the Command Line Tools.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The sizes macOS wants in an `.iconset`. Each appears at 1x and 2x, and `iconutil`
/// rejects the set if any are missing.
let sizes = [16, 32, 128, 256, 512]

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/m_text.iconset"

try? FileManager.default.createDirectory(atPath: outputDirectory,
                                         withIntermediateDirectories: true)

/// Draws the icon at `pixels` × `pixels`.
///
/// A dark rounded rectangle with a text cursor and three "lines of text", scaled from the
/// canvas size so the 16pt version stays legible rather than being a shrunken 512.
func drawIcon(pixels: Int) -> CGImage? {
    let size = CGFloat(pixels)
    guard let context = CGContext(data: nil,
                                  width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // macOS icons sit inside a margin rather than filling the square.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.22

    let background = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                            transform: nil)
    context.addPath(background)
    context.setFillColor(CGColor(red: 0.13, green: 0.15, blue: 0.20, alpha: 1))
    context.fillPath()

    // A thin lighter edge, so the icon reads on a dark Dock as well as a light one.
    context.addPath(background)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    context.setLineWidth(max(1, size * 0.008))
    context.strokePath()

    // Three text lines of decreasing length, suggesting a document.
    let lineHeight = rect.height * 0.075
    let leftMargin = rect.minX + rect.width * 0.20
    let widths: [CGFloat] = [0.44, 0.34, 0.24]
    context.setFillColor(CGColor(red: 0.55, green: 0.60, blue: 0.70, alpha: 1))
    for (index, factor) in widths.enumerated() {
        let y = rect.midY + rect.height * 0.10 - CGFloat(index) * lineHeight * 2.1
        let bar = CGRect(x: leftMargin, y: y, width: rect.width * factor, height: lineHeight)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: lineHeight / 2,
                               cornerHeight: lineHeight / 2, transform: nil))
        context.fillPath()
    }

    // The caret — the one accented element, so the icon has a focal point at small sizes.
    let caretWidth = max(1.5, rect.width * 0.035)
    let caret = CGRect(x: leftMargin - caretWidth * 2.4,
                       y: rect.midY - rect.height * 0.20,
                       width: caretWidth,
                       height: rect.height * 0.46)
    context.setFillColor(CGColor(red: 0.36, green: 0.70, blue: 1.0, alpha: 1))
    context.addPath(CGPath(roundedRect: caret, cornerWidth: caretWidth / 2,
                           cornerHeight: caretWidth / 2, transform: nil))
    context.fillPath()

    return context.makeImage()
}

func write(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString,
                                                            1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

var wrote = 0
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let image = drawIcon(pixels: pixels) else {
            FileHandle.standardError.write(Data("could not draw \(pixels)px\n".utf8))
            exit(1)
        }
        let suffix = scale == 1 ? "" : "@2x"
        let path = "\(outputDirectory)/icon_\(size)x\(size)\(suffix).png"
        guard write(image, to: path) else {
            FileHandle.standardError.write(Data("could not write \(path)\n".utf8))
            exit(1)
        }
        wrote += 1
    }
}
print("wrote \(wrote) icon images to \(outputDirectory)")
