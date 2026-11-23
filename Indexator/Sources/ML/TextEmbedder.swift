// SPDX-License-Identifier: GPL-3.0-or-later
//
// Multilingual sentence embeddings with intfloat/multilingual-e5-small (Core ML,
// converted in CI by scripts/convert-e5.py). Russian works natively.
// e5 expects "query: " / "passage: " prefixes; the model output is mean pooled
// and L2-normalized, so the dot product is the cosine similarity.

import CoreML
import Foundation

enum TextEmbedderError: LocalizedError {
    case missingResource(String)
    case unexpectedModel(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Не найден ресурс текстовой модели: \(name)"
        case .unexpectedModel(let detail): return "Неожиданный формат текстовой модели: \(detail)"
        case .noOutput: return "Текстовая модель не вернула вектор"
        }
    }
}

final class TextEmbedder {
    static let modelName = "multilingual-e5-small"
    static let sequenceLength = 256
    let dimension = 384

    private let model: MLModel
    private let tokenizer: SentencePieceTokenizer
    /// Serializes tokenize + predict, so one instance can be shared between queues.
    private let lock = NSLock()

    private static let sharedLock = NSLock()
    private static var sharedInstance: TextEmbedder?

    /// One lazily loaded instance for the whole app. A failed load is retried on the next call.
    static func shared() throws -> TextEmbedder {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let instance = sharedInstance {
            return instance
        }
        let instance = try TextEmbedder()
        sharedInstance = instance
        return instance
    }

    init() throws {
        func resource(_ name: String, _ ext: String) throws -> URL {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Models") {
                return url
            }
            throw TextEmbedderError.missingResource("\(name).\(ext)")
        }

        let config = MLModelConfiguration()
        // Not .all: on the GPU, MPSGraph unpacks the int8 weights into a huge constant
        // table at first prediction and aborts with bad_alloc (crash on iPhone 16 Pro,
        // build 0.3.0 (12), while embedding ~1000 emails). CPU + Neural Engine run
        // the quantized model directly.
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: try resource("multilingual_e5_small", "mlmodelc"), configuration: config)
        tokenizer = try SentencePieceTokenizer(tokenizerJSON: try resource("e5_tokenizer", "json"))

        let inputs = model.modelDescription.inputDescriptionsByName
        guard inputs["input_ids"] != nil, inputs["attention_mask"] != nil else {
            throw TextEmbedderError.unexpectedModel("входы \(inputs.keys.sorted())")
        }
    }

    func embed(query: String) throws -> [Float] {
        try embed(raw: "query: " + query)
    }

    func embed(passage: String) throws -> [Float] {
        try embed(raw: "passage: " + passage)
    }

    func embed(passages: [String]) throws -> [[Float]] {
        try passages.map { try embed(passage: $0) }
    }

    /// Embeds text as is, without the e5 prefix.
    func embed(raw: String) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let length = Self.sequenceLength
        let ids = tokenizer.encode(raw, maxLength: length)
        let shape: [NSNumber] = [1, NSNumber(value: length)]
        let inputIds = try MLMultiArray(shape: shape, dataType: .int32)
        let mask = try MLMultiArray(shape: shape, dataType: .int32)
        let idsPointer = inputIds.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let maskPointer = mask.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0..<length {
            if i < ids.count {
                idsPointer[i] = ids[i]
                maskPointer[i] = 1
            } else {
                idsPointer[i] = tokenizer.padId
                maskPointer[i] = 0
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIds),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let output = try model.prediction(from: provider)

        var array = output.featureValue(for: "embedding")?.multiArrayValue
        if array == nil {
            for name in output.featureNames.sorted() {
                if let value = output.featureValue(for: name)?.multiArrayValue {
                    array = value
                    break
                }
            }
        }
        guard let embedding = array, embedding.count > 0 else {
            throw TextEmbedderError.noOutput
        }
        var vector = [Float](repeating: 0, count: embedding.count)
        for i in 0..<embedding.count {
            vector[i] = embedding[i].floatValue
        }
        return VectorMath.normalized(vector)
    }
}
