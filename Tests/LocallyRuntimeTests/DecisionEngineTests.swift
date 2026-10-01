import XCTest
@testable import LocallyRuntime
import LocallyCore

final class DecisionEngineTests: XCTestCase {

    private func schema(_ questions: [String: DecisionSchema.QuestionType],
                        state: String = "test state") -> DecisionSchema {
        DecisionSchema(state: state, questions: questions.keys.sorted().map {
            DecisionSchema.Question(key: $0, type: questions[$0]!, instructions: "inst \($0)")
        })
    }

    // MARK: - Scored path

    func testScoredBoolean() async throws {
        let backend = MockScoringBackend(scores: ["yes": -0.1, "no": -3.0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["flag": .boolean])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.method, .scored)
        XCTAssertEqual(result.value, .bool(true))
        let pYes = result.probabilities?["yes"] ?? 0
        XCTAssertGreaterThan(pYes, 0.9)
        XCTAssertEqual(result.probabilities?["no"] ?? 0, 1 - pYes, accuracy: 1e-12)
    }

    func testScoredBooleanNoWins() async throws {
        let backend = MockScoringBackend(scores: ["yes": -4.0, "no": -0.2])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["flag": .boolean])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .bool(false))
        XCTAssertLessThan(result.probabilities?["yes"] ?? 1, 0.1)
    }

    func testScoredChoice() async throws {
        let backend = MockScoringBackend(scores: ["red": -0.1, "green": -2.0, "blue": -4.0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["color": .choice(options: ["red", "green", "blue"], multi: false)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .string("red"))
        XCTAssertEqual(result.probabilities?.count, 3)
        XCTAssertEqual(result.probabilities!.values.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(result.probabilities!["red"]!, result.probabilities!["green"]!)
    }

    func testScoredMultiChoicePicksAboveHalf() async throws {
        // Scoring path for multi choice: per-option P(option applies). With
        // defaultLogProb -10 the "no" side of each option's implicit pair is
        // derived from log1p; here "a" and "b" are strongly likely, "c" is not.
        let backend = MockScoringBackend(scores: ["a": -0.01, "b": -0.05, "c": -5.0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["tags": .choice(options: ["a", "b", "c"], multi: true)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        guard case .array(let picked) = result.value else { return XCTFail("expected array") }
        let names = picked.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
        XCTAssertFalse(names.contains("c"))
    }

    func testScoredProbability() async throws {
        let backend = MockScoringBackend(scores: ["yes": log(3.0), "no": 0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["chance": .probability])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .number(0.75))
    }

    func testScoredNoul() async throws {
        let backend = MockScoringBackend(scores: [
            "no": -6, "unlikely": -2, "unsure": -1, "likely": -0.05, "yes": -5,
        ])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["review": .noul(levels: 5)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .string("likely"))
        XCTAssertEqual(result.type, "noul")
        let expected = result.probabilities?["_probabilityOfYes"] ?? 0
        XCTAssertGreaterThan(expected, 0.5)
        XCTAssertLessThan(expected, 0.9)
    }

    func testScoredIntegerScore() async throws {
        let backend = MockScoringBackend(scores: ["1": -5, "2": -3, "3": -0.1, "4": -2, "5": -6])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["stars": .score(min: 1, max: 5, integer: true)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .number(3))
        let expectation = result.probabilities?["_expectation"] ?? 0
        XCTAssertGreaterThan(expectation, 2.5)
        XCTAssertLessThan(expectation, 3.5)
    }

    func testScoredRankingOrdersByRelevance() async throws {
        let backend = MockScoringBackend(scores: ["high": -0.1, "low": -3.0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["order": .ranking(items: ["x", "y"])])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        guard case .array(let values) = result.value else { return XCTFail("expected array") }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(result.probabilities?.count, 2)
        XCTAssertEqual(result.probabilities!.values.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    // MARK: - Generated path

    func testGeneratedBoolean() async throws {
        let backend = MockGenerationBackend(responses: [#"{"flag": true}"#])
        let engine = DecisionEngine(generationBackend: backend)
        let s = schema(["flag": .boolean])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.method, .generated)
        XCTAssertEqual(result.value, .bool(true))
        XCTAssertNil(result.probabilities)
        XCTAssertEqual(result.rawText, #"{"flag": true}"#)
    }

    func testGeneratedChoiceFromFencedOutput() async throws {
        let backend = MockGenerationBackend(responses: ["Here you go:\n```json\n{\"color\": \"green\"}\n```\n"])
        let engine = DecisionEngine(generationBackend: backend)
        let s = schema(["color": .choice(options: ["red", "green"], multi: false)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .string("green"))
    }

    func testGeneratedStructured() async throws {
        let backend = MockGenerationBackend(responses: [#"{"profile": {"name": "ada", "age": 36}}"#])
        let engine = DecisionEngine(generationBackend: backend)
        let schemaType: JSONSchema = .object(
            properties: ["name": .string(enumValues: nil, minLength: nil, maxLength: nil),
                         "age": .integer(min: nil, max: nil)],
            required: ["name", "age"])
        let s = schema(["profile": .structured(schemaType)])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        guard case .object(let fields) = result.value else { return XCTFail("expected object") }
        XCTAssertEqual(fields["name"], .string("ada"))
    }

    func testRetryOnInvalidThenSucceeds() async throws {
        let backend = MockGenerationBackend(responses: [
            #"{"flag": "yes please}"#,   // invalid: string not bool
            #"{"flag": false}"#,          // valid on retry
        ])
        let engine = DecisionEngine(generationBackend: backend)
        let s = schema(["flag": .boolean])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.value, .bool(false))
        XCTAssertEqual(backend.prompts.count, 2)
        XCTAssertTrue(backend.prompts[1].contains("invalid"), "retry prompt should name the validation failure")
    }

    func testRetryExhaustedThrowsInvalidOutput() async throws {
        let backend = MockGenerationBackend(responses: [
            #"{"flag": "maybe}"#,  // invalid both times (queue replays last)
        ])
        let engine = DecisionEngine(generationBackend: backend)
        let s = schema(["flag": .boolean])
        do {
            _ = try await engine.answer(question: s.questions[0], schema: s)
            XCTFail("expected invalidOutput")
        } catch DecisionError.invalidOutput(let userMessage, let detail) {
            XCTAssertFalse(userMessage.isEmpty)
            XCTAssertTrue(detail.contains("attempts"))
        }
    }

    func testNoJSONObjectAtAllFailsAfterRetries() async throws {
        let backend = MockGenerationBackend(responses: ["I cannot answer that."])
        let engine = DecisionEngine(generationBackend: backend)
        let s = schema(["flag": .boolean])
        do {
            _ = try await engine.answer(question: s.questions[0], schema: s)
            XCTFail("expected invalidOutput")
        } catch DecisionError.invalidOutput(_, let detail) {
            XCTAssertTrue(detail.contains("no JSON object"))
        }
    }

    // MARK: - Mixed / fallback behavior

    func testStructuredFallsBackToGenerationWhenScoringConfigured() async throws {
        let scoring = MockScoringBackend()
        let generation = MockGenerationBackend(responses: [#"{"doc": {"ok": true}}"#])
        let engine = DecisionEngine(scoringBackend: scoring, generationBackend: generation)
        let s = schema(["doc": .structured(.object(
            properties: ["ok": .boolean], required: ["ok"]))])
        let result = try await engine.answer(question: s.questions[0], schema: s)
        XCTAssertEqual(result.method, .generated)
    }

    func testNoBackendsThrows() async {
        let engine = DecisionEngine()
        let s = schema(["flag": .boolean])
        do {
            _ = try await engine.answer(question: s.questions[0], schema: s)
            XCTFail("expected backendFailed")
        } catch DecisionError.backendFailed { } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testScoringOnlyPreferenceSkipsGeneration() async {
        let generation = MockGenerationBackend(responses: [#"{"flag": true}"#])
        let engine = DecisionEngine(generationBackend: generation, preference: .scoringOnly)
        let s = schema(["flag": .boolean])
        do {
            _ = try await engine.answer(question: s.questions[0], schema: s)
            XCTFail("expected backendFailed")
        } catch DecisionError.backendFailed { } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAnswerAllPreservesQuestionOrder() async throws {
        let backend = MockScoringBackend(scores: ["yes": -0.1, "no": -2.0])
        let engine = DecisionEngine(scoringBackend: backend)
        let s = schema(["b": .boolean, "a": .boolean])
        let results = try await engine.answerAll(schema: s)
        XCTAssertEqual(results.map(\.key), ["a", "b"])
    }

    // MARK: - Prompt building

    func testPromptIncludesStateAndInstructions() async throws {
        let backend = MockGenerationBackend(responses: [#"{"flag": true}"#])
        let engine = DecisionEngine(generationBackend: backend)
        let question = DecisionSchema.Question(key: "flag", type: .boolean,
                                               instructions: "Check the refund policy.")
        let s = DecisionSchema(state: "Order #9 arrived broken.", questions: [question])
        _ = try await engine.answer(question: question, schema: s)
        let prompt = backend.prompts.first ?? ""
        XCTAssertTrue(prompt.contains("Order #9 arrived broken."))
        XCTAssertTrue(prompt.contains("Check the refund policy."))
        XCTAssertTrue(prompt.contains("\"flag\""))
    }

    func testContinuationPromptEndsWithAnswerCue() {
        let engine = DecisionEngine(scoringBackend: MockScoringBackend())
        let question = DecisionSchema.Question(key: "flag", type: .boolean, instructions: "")
        let s = DecisionSchema(state: "state text", questions: [question])
        let prompt = engine.renderPrompt(for: question, schema: s, style: .continuation)
        // ChatML renders "<|im_start|>assistant\n" after the user turn; the
        // continuation cue sits at the end of the user message itself.
        let assistantMarker = "<|im_start|>assistant"
        guard let markerRange = prompt.range(of: assistantMarker, options: .backwards) else {
            return XCTFail("expected ChatML assistant marker in prompt: \(prompt)")
        }
        let userPart = prompt[prompt.startIndex..<markerRange.lowerBound]
        XCTAssertTrue(userPart.hasSuffix("Answer:<|im_end|>\n") || userPart.hasSuffix("Answer:"),
                      "user turn should end with the answer cue, got: ...\(userPart.suffix(40))")
    }
}
