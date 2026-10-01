import XCTest
@testable import LocallyRuntime
import LocallyCore

/// End-to-end tests of DecisionRuntime with mock backends, plus the live
/// GGUF generation-path test gated by LOCALLY_LIVE_LLAMA=1.
final class DecisionRuntimeTests: XCTestCase {

    private let device = DeviceCapabilities(physicalMemory: 8_000_000_000,
                                            metalAvailable: false,
                                            neuralEngineAvailable: false)

    private func model(modality: ModelModality = .decision) -> ModelDescriptor {
        ModelDescriptor(repoID: "local/decision", name: "decision", modality: modality)
    }

    private func request(schemaJSON: String, model explicit: ModelDescriptor? = nil) -> AIRequest {
        let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(schemaJSON.utf8))) ?? .null
        guard case .object(let object) = value else {
            fatalError("test schema must be an object")
        }
        return AIRequest(model: explicit ?? model(), input: .json(object))
    }

    private func collect(_ stream: AsyncThrowingStream<AIEvent, Error>) async -> [AIEvent] {
        var events: [AIEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch {
            events.append(.failed(.unknown(userMessage: "stream threw", technicalDetail: "\(error)")))
        }
        return events
    }

    func testEmitsDecisionPerQuestionThenCompleted() async {
        let backend = MockScoringBackend(scores: ["yes": -0.1, "no": -2.0])
        let runtime = DecisionRuntime(engine: DecisionEngine(scoringBackend: backend))
        let req = request(schemaJSON: #"{"state": "s", "questions": {"a": {"type": "boolean"}, "b": {"type": "boolean"}}}"#)
        let events = await collect(runtime.run(req))
        TerminalEventInvariant.assertExactlyOneTerminalEvent(events)

        XCTAssertEqual(events.first, .started(requestID: req.id))
        let decisions = events.compactMap { event -> DecisionResult? in
            guard case .decision(let d) = event else { return nil }
            return d
        }
        XCTAssertEqual(decisions.map(\.key), ["a", "b"])
        XCTAssertEqual(decisions[0].value, .bool(true))
        XCTAssertEqual(decisions[0].method, .scored)

        guard case .completed(let final) = events.last else {
            return XCTFail("expected final .completed, got \(String(describing: events.last))")
        }
        XCTAssertEqual(final.artifacts.count, 2)
        XCTAssertNotNil(final.metadata.ttft)
    }

    func testInvalidSchemaFailsWithUserMessage() async {
        let backend = MockScoringBackend()
        let runtime = DecisionRuntime(engine: DecisionEngine(scoringBackend: backend))
        let req = request(schemaJSON: #"{"state": "s", "questions": {"a": {"type": "wat"}}}"#)
        let events = await collect(runtime.run(req))
        TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
        guard case .failed(let error) = events.last else {
            return XCTFail("expected .failed, got \(String(describing: events.last))")
        }
        XCTAssertTrue(error.technicalDetail.contains("questions.a.type"))
        XCTAssertTrue(error.technicalDetail.contains("unknown type 'wat'"))
        XCTAssertFalse(error.userMessage.isEmpty)
    }

    func testNonJSONInputFails() async {
        let runtime = DecisionRuntime(engine: DecisionEngine(scoringBackend: MockScoringBackend()))
        let req = AIRequest(model: model(), input: .image(Data([1, 2, 3])))
        let events = await collect(runtime.run(req))
        TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
        guard case .failed(let error) = events.last else {
            return XCTFail("expected .failed")
        }
        if case .unsupportedModality = error {} else { XCTFail("expected unsupportedModality, got \(error)") }
    }

    func testTextInputParsesAsJSON() async {
        let runtime = DecisionRuntime(engine: DecisionEngine(scoringBackend: MockScoringBackend(scores: ["yes": 0, "no": -1])))
        let req = AIRequest(model: model(),
                            input: .text(#"{"state": "s", "questions": {"a": {"type": "boolean"}}}"#))
        let events = await collect(runtime.run(req))
        TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
        guard case .completed(let final) = events.last else {
            return XCTFail("expected .completed, got \(String(describing: events.last))")
        }
        XCTAssertEqual(final.artifacts.count, 1)
    }

    func testCompatibilityRequiresDecisionOrTextModality() {
        let runtime = DecisionRuntime(engine: DecisionEngine(scoringBackend: MockScoringBackend()))
        if case .unsupported = runtime.compatibility(with: model(modality: .imageGeneration), on: device) {} else {
            XCTFail("imageGeneration should be unsupported")
        }
        // decision modality with only a scoring backend: risky (no device signal)
        if case .risky = runtime.compatibility(with: model(), on: device) {} else {
            XCTFail("scoring-only decision runtime should be risky, not supported/unsupported")
        }
    }

    func testCompatibilityDelegatesToTextRuntime() {
        let text = GGUFRuntime()
        let runtime = DecisionRuntime(wrapping: text, model: model(modality: .text))
        let rating = runtime.compatibility(with: model(modality: .text), on: device)
        if GGUFRuntime.isLlamaLinked {
            if case .unsupported = rating { XCTFail("linked gguf runtime should not be unsupported for unknown-arch text model") }
        } else {
            if case .unsupported(let reason) = rating {
                XCTAssertTrue(reason.contains("underlying text runtime"))
            } else {
                XCTFail("unlinked gguf runtime must be unsupported")
            }
        }
    }

    func testMethodReporting() {
        let scored = DecisionRuntime(engine: DecisionEngine(scoringBackend: MockScoringBackend()))
        let generated = DecisionRuntime(engine: DecisionEngine(generationBackend: MockGenerationBackend(responses: ["{}"])))
        let empty = DecisionRuntime(engine: DecisionEngine())
        let q = DecisionSchema.Question(key: "q", type: .boolean, instructions: "")
        XCTAssertEqual(scored.method(for: q), .scored)
        XCTAssertEqual(generated.method(for: q), .generated)
        XCTAssertNil(empty.method(for: q))
    }

    // MARK: - Live tests against the real GGUF runtime

    private var liveModelURL: URL? {
        guard ProcessInfo.processInfo.environment["LOCALLY_LIVE_LLAMA"] == "1" else { return nil }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent(".deps/models/SmolLM2-135M-Instruct-Q4_K_M.gguf")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func liveDescriptor(_ url: URL) -> ModelDescriptor {
        var descriptor = ModelDescriptor(repoID: "bartowski/SmolLM2-135M-Instruct-GGUF",
                                         name: "SmolLM2-135M-Instruct", architecture: "llama",
                                         modality: .text, formats: [.gguf])
        descriptor.metadata["localPath"] = url.path
        return descriptor
    }

    /// Live scoring-path test: boolean + choice + probability questions
    /// answered by llama token log-probabilities. Asserts the stream
    /// contract, schema-valid values, and a normalized distribution.
    func testLiveDecisionViaScoringPath() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        let descriptor = liveDescriptor(url)

        let gguf = GGUFRuntime()
        try await gguf.load(descriptor)
        defer { Task { await gguf.unload() } }
        XCTAssertNotNil(gguf.makeScoringBackend())

        let runtime = DecisionRuntime(wrapping: gguf, model: descriptor)
        let schemaJSON = """
        {"state": "A customer requests a refund for a broken product, 10 days after purchase.",
         "questions": {
           "approve": {"type": "boolean", "instructions": "Should the refund be approved?"},
           "category": {"type": "choice", "options": ["refund", "exchange", "reject"],
                        "instructions": "Pick the best resolution."},
           "confidence": {"type": "probability",
                          "instructions": "How likely is the customer to stay?"}
        }}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(schemaJSON.utf8))
        guard case .object(let object) = value else { return XCTFail("schema not an object") }
        let req = AIRequest(model: descriptor, input: .json(object))

        let events = await TerminalEventInvariant.assertStream(runtime.run(req))
        XCTAssertEqual(events.first, .started(requestID: req.id))
        guard case .completed = events.last else {
            return XCTFail("expected terminal .completed, got \(events)")
        }

        var results: [DecisionResult] = []
        for event in events {
            if case .decision(let d) = event { results.append(d) }
        }
        let byKey = Dictionary(results.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        print("LIVE SCORED DECISION >>> "
              + "approve=\(String(describing: byKey["approve"])) "
              + "category=\(String(describing: byKey["category"])) "
              + "confidence=\(String(describing: byKey["confidence"]))")
        XCTAssertEqual(byKey.count, 3)

        for (key, result) in byKey {
            XCTAssertEqual(result.method, .scored, "\(key) should be scored, not generated")
            if let probs = result.probabilities {
                let sum = probs.values.reduce(0, +)
                XCTAssertEqual(sum, 1.0, accuracy: 1e-3,
                               "\(key) probabilities must sum to 1: \(probs)")
                for (option, p) in probs {
                    XCTAssertGreaterThanOrEqual(p, 0, "\(key).\(option) < 0")
                    XCTAssertLessThanOrEqual(p, 1, "\(key).\(option) > 1")
                }
            } else {
                XCTFail("\(key) scored result must carry probabilities")
            }
        }
        if let approve = byKey["approve"] {
            guard case .bool = approve.value else {
                return XCTFail("approve value is not a bool: \(approve.value)")
            }
        }
        if let category = byKey["category"] {
            guard case .string(let s) = category.value else {
                return XCTFail("category value is not a string: \(category.value)")
            }
            XCTAssertTrue(["refund", "exchange", "reject"].contains(s))
        }
        if let confidence = byKey["confidence"] {
            guard case .number(let p) = confidence.value else {
                return XCTFail("confidence value is not a number: \(confidence.value)")
            }
            XCTAssertGreaterThanOrEqual(p, 0)
            XCTAssertLessThanOrEqual(p, 1)
        }
    }

    /// Live generation-path test (no scoring backend wired): the 135M model
    /// may answer poorly, so two acceptable outcomes: (a) schema-valid
    /// results for both questions, or (b) a clean validation error (never
    /// unvalidated output).
    func testLiveDecisionViaGenerationPath() async throws {
        guard let url = liveModelURL else {
            throw XCTSkip("LOCALLY_LIVE_LLAMA not set or model missing")
        }
        let descriptor = liveDescriptor(url)

        let gguf = GGUFRuntime()
        try await gguf.load(descriptor)
        defer { Task { await gguf.unload() } }

        // Force generation-only: a DecisionRuntime whose engine has no
        // scoring backend, wrapping the same text runtime.
        let adapter = GenerationBackendAdapter(runtime: gguf, model: descriptor)
        let runtime = DecisionRuntime(
            engine: DecisionEngine(generationBackend: adapter), textRuntime: gguf)
        let schemaJSON = """
        {"state": "A customer requests a refund for a broken product, 10 days after purchase.",
         "questions": {
           "approve": {"type": "boolean", "instructions": "Should the refund be approved?"},
           "category": {"type": "choice", "options": ["refund", "exchange", "reject"],
                        "instructions": "Pick the best resolution."}
        }}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(schemaJSON.utf8))
        guard case .object(let object) = value else { return XCTFail("schema not an object") }
        let req = AIRequest(model: descriptor, input: .json(object))

        let events = await TerminalEventInvariant.collect(runtime.run(req))
        var results: [DecisionResult] = []
        var failure: LocallyError?
        for event in events {
            switch event {
            case .decision(let d):
                results.append(d)
            case .completed(let result):
                for artifact in result.artifacts {
                    if case .decision(let d) = artifact { results.append(d) }
                }
            case .failed(let error):
                failure = error
            default: break
            }
        }
        // Dedupe: a question appears both as a .decision event and inside
        // the final .completed result.
        let byKey = Dictionary(results.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })

        if let failure {
            TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
            print("LIVE DECISION >>> failed cleanly: \(failure.userMessage) | \(failure.technicalDetail)")
            XCTAssertFalse(failure.userMessage.isEmpty)
        } else {
            TerminalEventInvariant.assertExactlyOneTerminalEvent(events)
            print("LIVE DECISION >>> approve=\(String(describing: byKey["approve"]?.value)) "
                  + "category=\(String(describing: byKey["category"]?.value))")
            XCTAssertEqual(byKey.count, 2)
            if let approve = byKey["approve"] {
                guard case .bool = approve.value else {
                    return XCTFail("approve value is not a bool: \(approve.value)")
                }
                XCTAssertEqual(approve.method, .generated)
            }
            if let category = byKey["category"] {
                guard case .string(let s) = category.value else {
                    return XCTFail("category value is not a string: \(category.value)")
                }
                XCTAssertTrue(["refund", "exchange", "reject"].contains(s))
            }
        }
    }
}
