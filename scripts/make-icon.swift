import AppKit
import Foundation
import QuickLookThumbnailing

enum IconError: LocalizedError {
    case invalidArguments
    case thumbnailGenerationFailed
    case pngEncodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "usage: make-icon.swift <input.svg> <output.iconset>"
        case .thumbnailGenerationFailed:
            return "failed to generate thumbnail from SVG"
        case .pngEncodingFailed(let name):
            return "failed to encode PNG for \(name)"
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    throw IconError.invalidArguments
}

let inputURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = URL(fileURLWithPath: arguments[2])
let fileManager = FileManager.default

if fileManager.fileExists(atPath: iconsetURL.path) {
    try fileManager.removeItem(at: iconsetURL)
}
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let request = QLThumbnailGenerator.Request(
    fileAt: inputURL,
    size: CGSize(width: 1024, height: 1024),
    scale: 1,
    representationTypes: .all
)

let semaphore = DispatchSemaphore(value: 0)
var generatedImage: NSImage?

QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, error in
    if let thumbnail {
        generatedImage = thumbnail.nsImage
    } else if error != nil {
        generatedImage = nil
    }
    semaphore.signal()
}

semaphore.wait()

guard let baseImage = generatedImage else {
    throw IconError.thumbnailGenerationFailed
}

let iconSpecs: [(name: String, points: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for spec in iconSpecs {
    let image = NSImage(size: NSSize(width: spec.points, height: spec.points))
    image.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    baseImage.draw(in: NSRect(x: 0, y: 0, width: spec.points, height: spec.points))
    image.unlockFocus()

    guard
        let tiffData = image.tiffRepresentation,
        let bitmapRep = NSBitmapImageRep(data: tiffData),
        let pngData = bitmapRep.representation(using: .png, properties: [:])
    else {
        throw IconError.pngEncodingFailed(spec.name)
    }

    try pngData.write(to: iconsetURL.appendingPathComponent(spec.name))
}
