// SPDX-License-Identifier: GPL-3.0-or-later
//
// Thin wrapper around Apple's MobileCLIP Core ML exports (image + text towers).
// Input and output names are discovered at runtime so the code does not depend
// on how a particular export named its features.

import CoreGraphics
import CoreML
import Foundation
import Vision

enum MobileCLIPError: LocalizedError {
    case missingResource(String)
    case unexpectedInput(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Не найден ресурс модели: \(name)"
        case .unexpectedInput(let detail): return "Неожиданный вход модели: \(detail)"
        case .noOutput: return "Модель не вернула вектор"
        }
    }
}

final class MobileCLIP {
    static let variant = "mobileclip_s0"

    private let imageModel: MLModel
    private let textModel: MLModel
    let tokenizer: CLIPTokenizer

    private let imageInputName: String
    private let imageInput: MLFeatureDescription
    private let textInputName: String
    private let textInput: MLFeatureDescription

    init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all

        func resource(_ name: String, _ ext: String) throws -> URL {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models") {
                return url
            }
            throw MobileCLIPError.missingResource("\(name).\(ext)")
        }

        imageModel = try MLModel(contentsOf: try resource("\(MobileCLIP.variant)_image", "mlmodelc"), configuration: config)
        textModel = try MLModel(contentsOf: try resource("\(MobileCLIP.variant)_text", "mlmodelc"), configuration: config)
        tokenizer = try CLIPTokenizer(vocabURL: try resource("bpe_simple_vocab_16e6", "txt"))

        guard let image = imageModel.modelDescription.inputDescriptionsByName.first else {
            throw MobileCLIPError.unexpectedInput("image model has no inputs")
        }
        imageInputName = image.key
        imageInput = image.value

        guard let text = textModel.modelDescription.inputDescriptionsByName.first else {
            throw MobileCLIPError.unexpectedInput("text model has no inputs")
        }
        textInputName = text.key
        textInput = text.value
    }

    /// Short human readable description of model inputs and outputs, for the diagnostics screen.
    var summary: String {
        func describe(_ model: MLModel) -> String {
            let ins = model.modelDescription.inputDescriptionsByName.map { "\($0.key): \(Self.describe($0.value))" }
            let outs = model.modelDescription.outputDescriptionsByName.map { "\($0.key): \(Self.describe($0.value))" }
            return "in [\(ins.joined(separator: ", "))] out [\(outs.joined(separator: ", "))]"
        }
        return "image \(describe(imageModel))\ntext \(describe(textModel))"
    }

    private static func describe(_ d: MLFeatureDescription) -> String {
        if let c = d.imageConstraint {
            return "image \(c.pixelsWide)x\(c.pixelsHigh)"
        }
        if let c = d.multiArrayConstraint {
            return "array \(c.shape.map { $0.intValue }) \(c.dataType.rawValue)"
        }
        return "type \(d.type.rawValue)"
    }

    // MARK: - Image

    func embed(image: CGImage) throws -> [Float] {
        let value: MLFeatureValue
        if let constraint = imageInput.imageConstraint {
            value = try MLFeatureValue(
                cgImage: image,
                constraint: constraint,
                options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue]
            )
        } else if let constraint = imageInput.multiArrayConstraint {
            value = MLFeatureValue(multiArray: try Self.pixelArray(from: image, constraint: constraint))
        } else {
            throw MobileCLIPError.unexpectedInput("image input type \(imageInput.type.rawValue)")
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [imageInputName: value])
        let output = try imageModel.prediction(from: provider)
        return try Self.normalizedVector(from: output)
    }

    /// Fallback for exports whose image input is a [1, 3, H, W] tensor in 0...1.
    private static func pixelArray(from image: CGImage, constraint: MLMultiArrayConstraint) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        guard shape.count == 4, shape[1] == 3 else {
            throw MobileCLIPError.unexpectedInput("image tensor shape \(shape)")
        }
        let height = shape[2], width = shape[3]
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw MobileCLIPError.unexpectedInput("cannot create bitmap context")
        }
        // Center crop to square, then scale.
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        let source = image.cropping(to: crop) ?? image
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        let array = try MLMultiArray(shape: constraint.shape, dataType: .float32)
        let plane = width * height
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: plane * 3)
        for i in 0..<plane {
            pointer[i] = Float(rgba[i * 4]) / 255
            pointer[plane + i] = Float(rgba[i * 4 + 1]) / 255
            pointer[2 * plane + i] = Float(rgba[i * 4 + 2]) / 255
        }
        return array
    }

    // MARK: - Text

    func embed(text: String) throws -> [Float] {
        guard let constraint = textInput.multiArrayConstraint else {
            throw MobileCLIPError.unexpectedInput("text input type \(textInput.type.rawValue)")
        }
        let tokens = tokenizer.tokenize(text)
        let dataType: MLMultiArrayDataType = constraint.dataType == .float32 ? .float32 : .int32
        let array = try MLMultiArray(shape: [1, NSNumber(value: tokens.count)], dataType: dataType)
        for (i, token) in tokens.enumerated() {
            array[i] = NSNumber(value: token)
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [textInputName: MLFeatureValue(multiArray: array)])
        let output = try textModel.prediction(from: provider)
        return try Self.normalizedVector(from: output)
    }

    // MARK: - Output

    private static func normalizedVector(from output: MLFeatureProvider) throws -> [Float] {
        for name in output.featureNames.sorted() {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
            var vector = [Float](repeating: 0, count: array.count)
            for i in 0..<array.count {
                vector[i] = array[i].floatValue
            }
            return VectorMath.normalized(vector)
        }
        throw MobileCLIPError.noOutput
    }
}
