import Foundation
import LocallyCore

/// Decision runtime: answers a set of typed questions about a state document
/// using an underlying text-capable backend. Input arrives as
/// `AIInput.json` carrying the decision schema document (`state` +
/// `questions`). Emits one `.decision` event per question as it is answered,
/// then exactly one terminal event: `.completed` with all results, or
/// `.failed`.
public final class DecisionRuntime: ModelCompatibleRuntime, @unchecked Sendable {
    public let kind: RuntimeKind = .decision

    private let engine: DecisionEngine
    /// The text runtime this runtime delegates to in generation mode; kept
    /// so `load`/`unload` forward to it. Nil when a pure scoring backend is
    /// wired (integration step).
    private let textRuntime: (any AIRuntime)?

    public init(engine: DecisionEngine, textRuntime: (any AIRuntime)? = nil) {
        self.engine = engine
        self.textRuntime = textRuntime
    }

    /// Convenience: wrap an existing text runtime (e.g. GGUFRuntime). When
    /// the runtime exposes a `TokenScoringBackend` (llama.cpp does), the
    /// engine prefers calibrated scoring; otherwise it falls back to
    /// generation with schema validation.
    public convenience init(wrapping textRuntime: any AIRuntime, model: ModelDescriptor) {
        let adapter = GenerationBackendAdapter(runtime: textRuntime, model: model)
        let scoring = (textRuntime as? GGUFRuntime)?.makeScoringBackend()
        self.init(
            engine: DecisionEngine(scoringBackend: scoring, generationBackend: adapter),
            textRuntime: textRuntime)
    }

    /// Whether a question will be answered by scoring or generation with the
    /// currently configured backends; nil when neither is available.
    public func method(for question: DecisionSchema.Question) -> DecisionResult.Method? {
        engine.method(for: question)
    }

    // MARK: - AIRuntime

    public func isSupported(on device: DeviceCapabilities) -> Bool {
        textRuntime?.isSupported(on: device) ?? (engine.scoringBackend != nil)
    }

    public func compatibility(with model: ModelDescriptor,
                              on device: DeviceCapabilities) -> CompatibilityRating {
        guard model.modality == .decision || model.modality == .text else {
            return .unsupported(reason: "decision runtime requires a text-capable model")
        }
        if let textRuntime {
            if let compatible = textRuntime as? ModelCompatibleRuntime {
                switch compatible.compatibility(with: model, on: device) {
                case .supported:
                    return .supported
                case .risky(let reason):
                    return .risky(reason: "underlying text runtime: \(reason)")
                case .unsupported(let reason):
                    return .unsupported(reason: "underlying text runtime: \(reason)")
                }
            }
            return textRuntime.isSupported(on: device)
                ? .risky(reason: "underlying runtime reports no compatibility details")
                : .unsupported(reason: "underlying text runtime is not supported on this device")
        }
        return engine.scoringBackend != nil
            ? .risky(reason: "scoring backend is wired but carries no device compatibility signal")
            : .unsupported(reason: "no decision backend configured")
    }

    public func load(_ model: ModelDescriptor) async throws {
        if let textRuntime {
            try await textRuntime.load(model)
        }
    }

    public func unload() async {
        if let textRuntime {
            await textRuntime.unload()
        }
    }

    public func run(_ request: AIRequest) -> AsyncThrowingStream<AIEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.execute(request: request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(request: AIRequest,
                         continuation: AsyncThrowingStream<AIEvent, Error>.Continuation) async {
        continuation.yield(.started(requestID: request.id))
        let start = ContinuousClock.now

        let schema: DecisionSchema
        switch request.input {
        case .json(let object):
            do {
                schema = try DecisionSchemaParser.parse(.object(object))
            } catch let error as DecisionSchemaError {
                continuation.yield(.failed(.unknown(
                    userMessage: error.userMessage, technicalDetail: error.description)))
                continuation.finish()
                return
            } catch {
                continuation.yield(.failed(.unknown(
                    userMessage: "The decision request is invalid.",
                    technicalDetail: "\(error)")))
                continuation.finish()
                return
            }
        case .text(let text):
            guard let data = text.data(using: .utf8) else {
                continuation.yield(.failed(.unknown(
                    userMessage: "The decision request is invalid.",
                    technicalDetail: "text input is not valid UTF-8")))
                continuation.finish()
                return
            }
            do {
                schema = try DecisionSchemaParser.parse(data: data)
            } catch let error as DecisionSchemaError {
                continuation.yield(.failed(.unknown(
                    userMessage: error.userMessage, technicalDetail: error.description)))
                continuation.finish()
                return
            } catch {
                continuation.yield(.failed(.unknown(
                    userMessage: "The decision request is invalid.",
                    technicalDetail: "\(error)")))
                continuation.finish()
                return
            }
        default:
            continuation.yield(.failed(.unsupportedModality(
                userMessage: "Decision runtime expects a JSON decision schema.",
                technicalDetail: "input is \(request.input.kindName); use .json or .text")))
            continuation.finish()
            return
        }

        var results: [DecisionResult] = []
        var firstAnswerTime: TimeInterval?
        do {
            continuation.yield(.preparing("decisions"))
            for question in schema.questions {
                if Task.isCancelled {
                    continuation.yield(.failed(.cancelled))
                    continuation.finish()
                    return
                }
                let result = try await engine.answer(question: question, schema: schema)
                if firstAnswerTime == nil {
                    firstAnswerTime = start.duration(to: .now).magnitudeSeconds
                }
                results.append(result)
                continuation.yield(.decision(result))
            }
        } catch let error as DecisionError {
            let locally = error.locallyError
            Log.error(.inference, "decision failed: \(locally.technicalDetail)")
            continuation.yield(.failed(locally))
            continuation.finish()
            return
        } catch {
            continuation.yield(.failed(.inferenceFailed(
                userMessage: "The decision run failed.", technicalDetail: "\(error)")))
            continuation.finish()
            return
        }

        let metadata = InferenceMetadata(
            ttft: firstAnswerTime ?? start.duration(to: .now).magnitudeSeconds)
        continuation.yield(.completed(result: AIResult(
            requestID: request.id,
            artifacts: results.map { .decision($0) },
            metadata: metadata)))
        continuation.finish()
    }
}

private extension AIInput {
    var kindName: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .audio: return "audio"
        case .videoFrame: return "videoFrame"
        case .chat: return "chat"
        case .json: return "json"
        }
    }
}
