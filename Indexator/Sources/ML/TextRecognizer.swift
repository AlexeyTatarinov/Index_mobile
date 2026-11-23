// SPDX-License-Identifier: GPL-3.0-or-later
//
// On-device OCR (Vision) for text on photos, screenshots and scans.

import CoreGraphics
import Vision

enum TextRecognizer {
    /// Returns recognized lines joined by newlines, or "" when there is no text.
    static func recognize(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
