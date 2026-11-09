// Resize the rendered platform masters; preserve macOS alpha, remove iOS alpha.
import CoreGraphics
import Foundation
import ImageIO

struct AppIconManifest: Decodable {
    struct Entry: Decodable {
        let filename: String
        let size: String
        let scale: String
    }
    let images: [Entry]
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "AlgerIconExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func load(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "AlgerIconExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot decode \(url.path)"])
    }
    return image
}

func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "AlgerIconExport", code: 3)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

func write(_ image: CGImage, size: Int, opaque: Bool, to url: URL) throws {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue) else {
        throw NSError(domain: "AlgerIconExport", code: 4)
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let output = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "AlgerIconExport", code: 5)
    }
    CGImageDestinationAddImage(destination, output, nil)
    try require(CGImageDestinationFinalize(destination), "Cannot write \(url.path)")
    let check = try load(url)
    try require(check.width == size && check.height == size, "Wrong dimensions: \(url.path)")
    if opaque {
        // CoreGraphics may decode RGB into padded RGBX storage. Check the PNG
        // IHDR color type itself: type 2 is RGB, type 6 would retain alpha.
        let header = try Data(contentsOf: url)
        try require(header.count > 25 && header[25] == 2, "iOS PNG must have no alpha channel: \(url.path)")
    }
}

do {
    if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--verify-png" {
        let before = try load(URL(fileURLWithPath: CommandLine.arguments[2]))
        let after = try load(URL(fileURLWithPath: CommandLine.arguments[3]))
        try require(before.width == after.width && before.height == after.height, "ICNS changed image dimensions")
        let beforePixels = try rgbaPixels(before)
        let afterPixels = try rgbaPixels(after)
        try require(beforePixels == afterPixels, "ICNS changed rendered image pixels")
        print("Verified ICNS round-trip pixels; PNG metadata may differ.")
        exit(0)
    }
    try require(CommandLine.arguments.count == 3, "Usage: export-icons.swift STAGING_DIRECTORY APPICON_CONTENTS_JSON")
    let stage = URL(fileURLWithPath: CommandLine.arguments[1])
    let manifestURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let mac = try load(stage.appendingPathComponent("macos/1024x1024.png"))
    let ios = try load(stage.appendingPathComponent("ios/1024x1024.png"))
    try require(mac.width == 1024 && mac.height == 1024 && ios.width == 1024 && ios.height == 1024, "Masters must be 1024 square")

    let macPixels = try rgbaPixels(mac)
    let iosPixels = try rgbaPixels(ios)
    for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023)] {
        let index = (y * 1024 + x) * 4
        try require(macPixels[index + 3] == 0, "macOS exterior must be transparent")
        try require(iosPixels[index + 3] == 255, "iOS corners must be opaque; do not bake rounded corners")
        try require(iosPixels[index] < 160 && iosPixels[index + 1] < 160 && iosPixels[index + 2] < 160, "iOS background must reach every corner")
    }
    for index in stride(from: 3, to: iosPixels.count, by: 4) {
        try require(iosPixels[index] == 255, "iOS master contains transparent pixels")
    }
    // The macOS tile occupies 896px of the 1024px canvas, with no second inset.
    for (x, y) in [(64, 512), (959, 512), (512, 64), (512, 959)] {
        try require(macPixels[(y * 1024 + x) * 4 + 3] > 200, "Unexpected extra padding around the macOS tile")
    }

    let files = FileManager.default
    let desktop = stage.appendingPathComponent("desktop")
    let iconset = stage.appendingPathComponent("AppIcon.iconset")
    let iosAssets = stage.appendingPathComponent("ios-assets")
    for directory in [desktop, iconset, iosAssets] {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try files.copyItem(at: stage.appendingPathComponent("macos/1024x1024.png"), to: desktop.appendingPathComponent("icon-macos.png"))
    for (name, size) in [("32x32.png", 32), ("128x128.png", 128), ("128x128@2x.png", 256), ("icon.png", 512)] {
        try write(mac, size: size, opaque: false, to: desktop.appendingPathComponent(name))
    }
    for size in [16, 32, 128, 256, 512] {
        try write(mac, size: size, opaque: false, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        try write(mac, size: size * 2, opaque: false, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    try write(ios, size: 1024, opaque: true, to: desktop.appendingPathComponent("icon-ios.png"))
    let manifest = try JSONDecoder().decode(AppIconManifest.self, from: Data(contentsOf: manifestURL))
    try require(manifest.images.count == 18, "Expected the existing 18-entry iOS AppIcon catalog")
    for entry in manifest.images {
        guard let points = Double(entry.size.components(separatedBy: "x")[0]),
              let scale = Double(entry.scale.replacingOccurrences(of: "x", with: "")) else {
            throw NSError(domain: "AlgerIconExport", code: 6)
        }
        try write(ios, size: Int((points * scale).rounded()), opaque: true,
                  to: iosAssets.appendingPathComponent(entry.filename))
    }
    print("Verified platform masters, transparent macOS exterior, full-bleed opaque iOS canvas, and all PNG export sizes.")
} catch {
    fputs("Icon export failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
