// SPDX-License-Identifier: GPL-3.0-or-later
//
// Makes a small H.264 slideshow video from JPEG files, for CI screenshots of video search.
// Usage: swift scripts/make-sample-video.swift out.mp4 seconds-per-image a.jpg b.jpg ...

import AVFoundation
import AppKit
import CoreVideo

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Int(args[2]) else {
    print("usage: make-sample-video.swift out.mp4 seconds-per-image images...")
    exit(1)
}
let outURL = URL(fileURLWithPath: args[1])
try? FileManager.default.removeItem(at: outURL)
let width = 640, height = 480, fps: Int32 = 2

let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func buffer(for path: String) -> CVPixelBuffer? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &pb)
    guard let pb else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    )
    ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

var frame: Int64 = 0
for path in args.dropFirst(3) {
    guard let pb = buffer(for: path) else { print("skip \(path)"); continue }
    for _ in 0..<(seconds * Int(fps)) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        adaptor.append(pb, withPresentationTime: CMTime(value: frame, timescale: fps))
        frame += 1
    }
}
input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: frame, timescale: fps))
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print("wrote \(outURL.path): \(Double(frame) / Double(fps)) s, status \(writer.status.rawValue)")
