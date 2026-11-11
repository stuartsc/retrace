import CoreML
import Foundation

/// One bounded local runtime; it neither admits evidence nor publishes an index.
/// Callers must recheck the canonical source/revision/policy after inference.
///
/// All filesystem, tokenizer, compilation and prediction work is actor-isolated
/// off the main actor. Core ML runs on CPU only, one fixed window at a time.
/// Core ML does not expose an exact CPU thread-count control; serialized calls
/// are not a claim that its internal worker pool is limited to one thread.
actor MiniLMEmbeddingRuntime {
    private let configuration: MiniLMEmbeddingConfiguration
    /// Enqueue a content-free event only. The owner drains its bounded metric
    /// inbox into daily_metrics; this callback must not perform blocking I/O.
    private let recordMetric: @Sendable (MiniLMRuntimeMetric) -> Void
    private var artifacts: VerifiedMiniLMArtifacts?
    private var tokenizerData: Data?
    private var tokenizer: MiniLMWordPieceTokenizer?
    private var model: MLModel?
    private var closed = false
    private var embedding = false
    private var completedWindowCount = 0
    private var totalWindowCount = 0
    private var embeddingFinished: CheckedContinuation<Void, Never>?
    private var closeOperation: (id: UUID, task: Task<Void, Error>)?
    private var cleanupComplete = false

    init(configuration: MiniLMEmbeddingConfiguration,
         recordMetric: @escaping @Sendable (MiniLMRuntimeMetric) -> Void) {
        self.configuration = configuration
        self.recordMetric = recordMetric
    }

    func prepare() async throws {
        guard !closed else { throw MiniLMRuntimeError.closed }
        let start = Date()
        do {
            try Task.checkCancellation()
            try prepareModel()
            try Task.checkCancellation()
            emit(.preparation, .completed, windows: 0, since: start)
        } catch {
            emit(.preparation, outcome(error), windows: 0, since: start)
            throw error
        }
    }

    func embed(_ text: String) async throws -> [MiniLMEmbeddingWindow] {
        let start = Date()
        guard !closed else {
            throw MiniLMRuntimeError.closed
        }
        guard !embedding else {
            emit(.embedding, .rejected, windows: 0, since: start)
            throw MiniLMRuntimeError.busy
        }
        embedding = true
        completedWindowCount = 0
        totalWindowCount = 0
        defer { finishEmbedding() }
        do {
            try Task.checkCancellation()
            guard text.utf16.prefix(MiniLMWordPieceTokenizer.maximumInputUTF16 + 1).count <= MiniLMWordPieceTokenizer.maximumInputUTF16 else {
                throw MiniLMRuntimeError.inputTooLarge
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MiniLMRuntimeError.emptyInput
            }
            let currentTokenizer = try loadTokenizer()
            let windows: [MiniLMTokenWindow]
            do { windows = try currentTokenizer.windows(text) }
            catch MiniLMWordPieceTokenizer.Failure.inputTooLarge { throw MiniLMRuntimeError.inputTooLarge }
            guard !windows.isEmpty else { throw MiniLMRuntimeError.emptyInput }
            guard windows.count <= MiniLMModelPin.maximumWindows else { throw MiniLMRuntimeError.inputTooLarge }
            totalWindowCount = windows.count
            try prepareModel()
            var result: [MiniLMEmbeddingWindow] = []
            result.reserveCapacity(windows.count)
            for window in windows {
                try Task.checkCancellation()
                guard !closed, let currentModel = model else { throw MiniLMRuntimeError.closed }
                let vector = try autoreleasepool { try predict(window, using: currentModel) }
                try Task.checkCancellation()
                result.append(.init(tokenStart: window.tokenStart, tokenEnd: window.tokenEnd,
                                    utf16Location: window.utf16Location, utf16Length: window.utf16Length,
                                    vector: vector))
                completedWindowCount += 1
                // Allows cancellation, status reads and close between real
                // completed predictions. No partial vector set escapes.
                await Task.yield()
            }
            try Task.checkCancellation()
            guard !closed else { throw MiniLMRuntimeError.closed }
            emit(.embedding, .completed, windows: completedWindowCount, since: start)
            return result
        } catch {
            emit(.embedding, outcome(error), windows: completedWindowCount, since: start)
            throw error
        }
    }

    func status() -> MiniLMRuntimeStatus {
        .init(isPrepared: model != nil && !closed, isEmbedding: embedding,
              completedWindowCount: completedWindowCount, totalWindowCount: totalWindowCount)
    }

    /// Joined cleanup; cancellation does not prevent releasing private files.
    /// Close is terminal, including while another request is between windows.
    func close() async throws {
        if cleanupComplete { return }
        closed = true
        let operation: (id: UUID, task: Task<Void, Error>)
        if let current = closeOperation {
            operation = current
        } else {
            let start = Date()
            operation = (UUID(), Task { try await self.finishClosing(since: start) })
            closeOperation = operation
        }
        defer {
            if closeOperation?.id == operation.id { closeOperation = nil }
        }
        // An unstructured owning task is intentionally independent of a close
        // caller's cancellation. Repeated close calls join this same operation.
        try await operation.task.value
    }

    private func finishEmbedding() {
        embedding = false
        let completion = embeddingFinished
        embeddingFinished = nil
        // Called after the operation's final metric and all owned effects.
        completion?.resume()
    }

    private func finishClosing(since start: Date) async throws {
        if embedding {
            await withCheckedContinuation { embeddingFinished = $0 }
        }
        model = nil
        tokenizer = nil
        tokenizerData = nil
        do {
            try artifacts?.remove()
            artifacts = nil
            cleanupComplete = true
            emit(.cleanup, .completed, windows: 0, since: start)
        } catch {
            emit(.cleanup, .failed, windows: 0, since: start)
            throw MiniLMRuntimeError.cleanupFailed
        }
    }

    private func loadTokenizer() throws -> MiniLMWordPieceTokenizer {
        if let tokenizer { return tokenizer }
        do {
            let bytes = try VerifiedMiniLMArtifacts.tokenizerData(at: configuration.tokenizerURL)
            let value = try MiniLMWordPieceTokenizer(data: bytes)
            tokenizerData = bytes
            tokenizer = value
            return value
        } catch {
            if error is CancellationError { throw error }
            throw (error as? MiniLMRuntimeError) ?? .artifactInvalid
        }
    }

    private func prepareModel() throws {
        if model != nil { return }
        try Task.checkCancellation()
        _ = try loadTokenizer()
        guard let tokenizerData else { throw MiniLMRuntimeError.artifactInvalid }
        var candidate: VerifiedMiniLMArtifacts?
        do {
            let owned = try VerifiedMiniLMArtifacts.create(configuration: configuration, tokenizerData: tokenizerData)
            candidate = owned
            // The synchronous Core ML interface runs on this actor's executor.
            // It returns only its own temporary output; copy/move it into our
            // owned namespace before any model is loaded or published.
            let compiled = try MLModel.compileModel(at: owned.modelPackageURL)
            defer { try? FileManager.default.removeItem(at: compiled) }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: compiled, to: owned.compiledModelURL)
            let options = MLModelConfiguration()
            options.computeUnits = .cpuOnly
            let value = try MLModel(contentsOf: owned.compiledModelURL, configuration: options)
            try Self.validate(value.modelDescription)
            try Task.checkCancellation()
            artifacts = owned
            model = value
        } catch {
            try? candidate?.remove()
            self.tokenizer = nil
            self.tokenizerData = nil
            if error is CancellationError { throw error }
            throw (error as? MiniLMRuntimeError) ?? .modelInvalid
        }
    }

    private static func validate(_ description: MLModelDescription) throws {
        let inputs: Set<String> = ["input_ids", "attention_mask", "token_type_ids"]
        guard Set(description.inputDescriptionsByName.keys) == inputs,
              Set(description.outputDescriptionsByName.keys) == ["embedding"] else {
            throw MiniLMRuntimeError.modelInvalid
        }
        for name in inputs {
            guard let feature = description.inputDescriptionsByName[name], !feature.isOptional,
                  feature.type == .multiArray, let constraint = feature.multiArrayConstraint,
                  constraint.dataType == .int32, hasExactShape(constraint, [1, 256]) else {
                throw MiniLMRuntimeError.modelInvalid
            }
        }
        guard let output = description.outputDescriptionsByName["embedding"], !output.isOptional,
              output.type == .multiArray, let constraint = output.multiArrayConstraint,
              constraint.dataType == .float32, hasExactShape(constraint, [1, 384]) else {
            throw MiniLMRuntimeError.modelInvalid
        }
    }

    private static func hasExactShape(_ constraint: MLMultiArrayConstraint, _ expected: [Int]) -> Bool {
        guard constraint.shape.map(\.intValue) == expected else { return false }
        switch constraint.shapeConstraint.type {
        case .unspecified:
            return true
        case .enumerated:
            return constraint.shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) } == [expected]
        case .range:
            let bounds = constraint.shapeConstraint.sizeRangeForDimension.map(\.rangeValue)
            return bounds.count == expected.count && zip(bounds, expected).allSatisfy {
                $0.location == $1 && $0.length == 1
            }
        @unknown default:
            return false
        }
    }

    private func predict(_ window: MiniLMTokenWindow, using model: MLModel) throws -> [Float] {
        do {
            func array(_ values: [Int32]) throws -> MLMultiArray {
                guard values.count == 256 else { throw MiniLMRuntimeError.predictionFailed }
                let value = try MLMultiArray(shape: [1, 256], dataType: .int32)
                for index in values.indices { value[index] = NSNumber(value: values[index]) }
                return value
            }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": array(window.inputIDs),
                "attention_mask": array(window.attentionMask),
                "token_type_ids": array([Int32](repeating: 0, count: 256))
            ])
            let prediction = try model.prediction(from: features)
            guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
                  output.dataType == .float32, output.shape.map(\.intValue) == [1, 384], output.count == 384 else {
                throw MiniLMRuntimeError.invalidOutput
            }
            let vector = (0..<384).map { output[[0, NSNumber(value: $0)]].floatValue }
            guard vector.allSatisfy(\.isFinite) else { throw MiniLMRuntimeError.invalidOutput }
            let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard abs(norm - 1) <= 0.00001 else { throw MiniLMRuntimeError.invalidOutput }
            return vector
        } catch {
            if error is CancellationError { throw error }
            throw (error as? MiniLMRuntimeError) ?? .predictionFailed
        }
    }

    private func outcome(_ error: Error) -> MiniLMRuntimeMetric.Outcome {
        if error is CancellationError { return .cancelled }
        if let failure = error as? MiniLMRuntimeError,
           [.inputTooLarge, .emptyInput, .busy, .closed].contains(failure) { return .rejected }
        return .failed
    }

    private func emit(_ operation: MiniLMRuntimeMetric.Operation, _ outcome: MiniLMRuntimeMetric.Outcome,
                      windows: Int, since start: Date) {
        recordMetric(.init(operation: operation, outcome: outcome, windowCount: windows,
                           elapsedMilliseconds: max(0, Date().timeIntervalSince(start) * 1_000)))
    }
}
