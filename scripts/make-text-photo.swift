// SPDX-License-Identifier: GPL-3.0-or-later
//
// Makes sample photos for the CI search check: a page of text rendered as a JPEG
// (a CV, a shopping list, meeting notes), or a copy of an existing JPEG, optionally
// with a GPS location so place search («Валенсия») has something to find.
// Usage:
//   swift scripts/make-text-photo.swift text out.jpg "line 1\nline 2" [lat lon]
//   swift scripts/make-text-photo.swift copy out.jpg source.jpg [lat lon]

import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: make-text-photo.swift text|copy out.jpg text-or-source [lat lon]")
    exit(1)
}
let mode = args[1], outPath = args[2], payload = args[3]
let location: (Double, Double)? = args.count >= 6 ? (Double(args[4]) ?? 0, Double(args[5]) ?? 0) : nil

func renderText(_ text: String) -> CGImage? {
    let width = 1200, height = 1600
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let lines = text.replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n")
    var y = CGFloat(height - 140)
    for (i, line) in lines.enumerated() {
        let size: CGFloat = i == 0 ? 64 : 40
        let attrs: [NSAttributedString.Key: Any] = [
            .font: i == 0 ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor.black,
        ]
        NSAttributedString(string: line, attributes: attrs).draw(at: CGPoint(x: 90, y: y))
        y -= size * 1.7
    }
    NSGraphicsContext.current = nil
    return ctx.makeImage()
}

let image: CGImage?
switch mode {
case "text": image = renderText(payload)
case "copy":
    image = NSImage(contentsOfFile: payload)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
default: image = nil
}
guard let image,
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.jpeg.identifier as CFString, 1, nil) else {
    print("could not make \(outPath)")
    exit(1)
}
var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
let formatter = DateFormatter()
formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: formatter.string(from: Date())]
if let (lat, lon) = location {
    properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
        kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
    ]
}
CGImageDestinationAddImage(dest, image, properties as CFDictionary)
print(CGImageDestinationFinalize(dest) ? "wrote \(outPath)" : "failed \(outPath)")
