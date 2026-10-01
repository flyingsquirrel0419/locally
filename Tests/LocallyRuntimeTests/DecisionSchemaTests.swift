import XCTest
@testable import LocallyRuntime
import LocallyCore

final class DecisionSchemaTests: XCTestCase {

    private func parse(_ json: String) throws -> DecisionSchema {
        try DecisionSchemaParser.parse(data: Data(json.utf8))
    }

    private func pathError(_ json: String) -> DecisionSchemaError? {
        do { _ = try parse(json); return nil } catch let e as DecisionSchemaError { return e } catch { return nil }
    }

    func testValidBoolean() throws {
        let schema = try parse(#"{"state": "ticket 42", "questions": {"refund": {"type": "boolean", "instructions": "Should this be reviewed?"}}}"#)
        XCTAssertEqual(schema.state, "ticket 42")
        XCTAssertEqual(schema.questions.count, 1)
        XCTAssertEqual(schema.questions[0].key, "refund")
        XCTAssertEqual(schema.questions[0].type, .boolean)
        XCTAssertEqual(schema.questions[0].instructions, "Should this be reviewed?")
    }

    func testValidChoice() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "choice", "options": ["a", "b", "c"]}}}"#)
        XCTAssertEqual(schema.questions[0].type, .choice(options: ["a", "b", "c"], multi: false))
    }

    func testValidMultiChoice() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "choice", "options": ["a", "b"], "multi": true}}}"#)
        XCTAssertEqual(schema.questions[0].type, .choice(options: ["a", "b"], multi: true))
    }

    func testValidScore() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "score", "min": 1, "max": 5, "integer": true}}}"#)
        XCTAssertEqual(schema.questions[0].type, .score(min: 1, max: 5, integer: true))
    }

    func testValidProbability() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "probability"}}}"#)
        XCTAssertEqual(schema.questions[0].type, .probability)
    }

    func testValidNoulDefaultsToFiveLevels() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "noul"}}}"#)
        XCTAssertEqual(schema.questions[0].type, .noul(levels: 5))
    }

    func testValidNoulThreeLevels() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "noul", "levels": 3}}}"#)
        XCTAssertEqual(schema.questions[0].type, .noul(levels: 3))
    }

    func testValidRanking() throws {
        let schema = try parse(#"{"state": "s", "questions": {"q": {"type": "ranking", "items": ["x", "y", "z"]}}}"#)
        XCTAssertEqual(schema.questions[0].type, .ranking(items: ["x", "y", "z"]))
    }

    func testValidStructured() throws {
        let json = #"{"state": "s", "questions": {"q": {"type": "structured", "schema": {"type": "object", "properties": {"name": {"type": "string"}, "age": {"type": "integer", "min": 0}}, "required": ["name"]}}}}"#
        let schema = try parse(json)
        guard case .structured(let js) = schema.questions[0].type,
              case .object(let properties, let required) = js else {
            return XCTFail("expected structured object schema")
        }
        XCTAssertEqual(required, ["name"])
        XCTAssertEqual(properties.count, 2)
        guard case .integer(let min, _) = properties["age"] else { return XCTFail("age not integer") }
        XCTAssertEqual(min, 0)
    }

    // MARK: - Invalid inputs with path-specific errors

    func testUnknownTypeReportsPath() {
        let error = pathError(#"{"state": "s", "questions": {"refund": {"type": "foo"}}}"#)
        XCTAssertEqual(error?.path, "questions.refund.type")
        XCTAssertEqual(error?.message, "unknown type 'foo'")
    }

    func testMissingState() {
        let error = pathError(#"{"questions": {"q": {"type": "boolean"}}}"#)
        XCTAssertEqual(error?.path, "state")
    }

    func testMissingQuestions() {
        let error = pathError(#"{"state": "s"}"#)
        XCTAssertEqual(error?.path, "questions")
    }

    func testEmptyQuestions() {
        let error = pathError(#"{"state": "s", "questions": {}}"#)
        XCTAssertEqual(error?.path, "questions")
    }

    func testRootNotObject() {
        let error = pathError(#"["not", "an", "object"]"#)
        XCTAssertEqual(error?.path, "$")
    }

    func testNotJSON() {
        let error = pathError("this is not json")
        XCTAssertEqual(error?.path, "$")
        XCTAssertTrue(error?.message.contains("not valid JSON") ?? false)
    }

    func testChoiceRequiresTwoOptions() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "choice", "options": ["only"]}}}"#)
        XCTAssertEqual(error?.path, "questions.q.options")
    }

    func testChoiceDuplicateOptionsRejected() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "choice", "options": ["a", "a"]}}}"#)
        XCTAssertEqual(error?.message, "options must be unique")
    }

    func testScoreRequiresMinBelowMax() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "score", "min": 5, "max": 1}}}"#)
        XCTAssertEqual(error?.path, "questions.q.min")
    }

    func testIntegerScoreRejectsFractionalBounds() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "score", "min": 0.5, "max": 5, "integer": true}}}"#)
        XCTAssertNotNil(error)
    }

    func testNoulRejectsFourLevels() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "noul", "levels": 4}}}"#)
        XCTAssertEqual(error?.path, "questions.q.levels")
        XCTAssertTrue(error?.message.contains("3 or 5") ?? false)
    }

    func testRankingRequiresItems() {
        let error = pathError(#"{"state": "s", "questions": {"q": {"type": "ranking"}}}"#)
        XCTAssertEqual(error?.path, "questions.q.items")
    }

    func testStructuredRejectsUnsupportedKeyword() {
        let json = #"{"state": "s", "questions": {"q": {"type": "structured", "schema": {"type": "string", "pattern": "^a+$"}}}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "questions.q.schema.pattern")
        XCTAssertTrue(error?.message.contains("unsupported schema keyword") ?? false)
    }

    func testStructuredRejectsUnknownSchemaType() {
        let json = #"{"state": "s", "questions": {"q": {"type": "structured", "schema": {"type": "date"}}}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "questions.q.schema.type")
    }

    func testStructuredRequiredMustReferenceDeclaredProperty() {
        let json = #"{"state": "s", "questions": {"q": {"type": "structured", "schema": {"type": "object", "properties": {"a": {"type": "string"}}, "required": ["b"]}}}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "questions.q.schema.required")
    }

    // MARK: - Limits

    func testDocumentSizeLimit() {
        let padding = String(repeating: "x", count: DecisionSchemaParser.maxDocumentBytes)
        let json = #"{"state": ""# + padding + #"", "questions": {"q": {"type": "boolean"}}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "$")
        XCTAssertTrue(error?.message.contains("limit") ?? false)
    }

    func testQuestionCountLimit() {
        var questions: [String] = []
        for i in 0..<(DecisionSchemaParser.maxQuestions + 1) {
            questions.append(#" "q\#(i)": {"type": "boolean"} "#)
        }
        let json = #"{"state": "s", "questions": {\#(questions.joined(separator: ","))}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "questions")
        XCTAssertTrue(error?.message.contains("limit") ?? false)
    }

    func testOptionsCountLimit() {
        let options = (0..<(DecisionSchemaParser.maxOptions + 1)).map { "\"opt\($0)\"" }.joined(separator: ",")
        let json = #"{"state": "s", "questions": {"q": {"type": "choice", "options": [\#(options)]}}}"#
        let error = pathError(json)
        XCTAssertEqual(error?.path, "questions.q.options")
    }

    func testSchemaDepthLimit() {
        var schema = #"{"type": "string"}"#
        for _ in 0...DecisionSchemaParser.maxSchemaDepth {
            schema = #"{"type": "array", "items": \#(schema)}"#
        }
        let json = #"{"state": "s", "questions": {"q": {"type": "structured", "schema": \#(schema)}}}"#
        let error = pathError(json)
        XCTAssertTrue(error?.message.contains("nesting") ?? false)
    }

    func testQuestionOrderIsDeterministic() throws {
        let schema = try parse(#"{"state": "s", "questions": {"b": {"type": "boolean"}, "a": {"type": "boolean"}, "c": {"type": "boolean"}}}"#)
        XCTAssertEqual(schema.questions.map(\.key), ["a", "b", "c"])
    }

    // MARK: - Noul scale

    func testNoulLabels() {
        XCTAssertEqual(NoulScale.labels(levels: 5), ["no", "unlikely", "unsure", "likely", "yes"])
        XCTAssertEqual(NoulScale.labels(levels: 3), ["no", "unsure", "yes"])
    }

    func testNoulProbabilityMapping() {
        XCTAssertEqual(NoulScale.probability(of: "no", levels: 5)!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(NoulScale.probability(of: "unsure", levels: 5)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(NoulScale.probability(of: "yes", levels: 5)!, 0.9, accuracy: 1e-9)
        XCTAssertEqual(NoulScale.probability(of: "unsure", levels: 3)!, 0.5, accuracy: 1e-9)
        XCTAssertNil(NoulScale.probability(of: "maybe", levels: 5))
    }

    func testNoulLabelForProbability() {
        XCTAssertEqual(NoulScale.label(for: 0.0, levels: 5), "no")
        XCTAssertEqual(NoulScale.label(for: 0.5, levels: 5), "unsure")
        XCTAssertEqual(NoulScale.label(for: 0.79, levels: 5), "likely")
        XCTAssertEqual(NoulScale.label(for: 1.0, levels: 5), "yes")
        XCTAssertEqual(NoulScale.label(for: 0.99, levels: 3), "yes")
    }

    // MARK: - Math

    func testSoftmaxSumsToOne() {
        let probs = DecisionEngine.softmax([0.0, -1.0, -2.0, -0.5])
        XCTAssertEqual(probs.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertTrue(probs[0] > probs[3] && probs[3] > probs[1] && probs[1] > probs[2])
    }

    func testSoftmaxUniformWhenAllMinusInfinity() {
        let probs = DecisionEngine.softmax([-.infinity, -.infinity])
        XCTAssertEqual(probs, [0.5, 0.5])
    }

    func testProbabilityYes() {
        XCTAssertEqual(DecisionEngine.probabilityYes(logYes: 0, logNo: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(DecisionEngine.probabilityYes(logYes: 0, logNo: -.infinity), 1.0)
        XCTAssertEqual(DecisionEngine.probabilityYes(logYes: -.infinity, logNo: 0), 0.0)
        // logYes = ln 3, logNo = ln 1 → 3/4
        let p = DecisionEngine.probabilityYes(logYes: log(3.0), logNo: 0)
        XCTAssertEqual(p, 0.75, accuracy: 1e-12)
    }
}
