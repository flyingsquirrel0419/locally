import XCTest
@testable import LocallyRuntime
import LocallyCore

final class DecisionJSONTests: XCTestCase {

    // MARK: - JSON extraction

    func testExtractPlainObject() {
        let raw = JSONExtractor.firstObject(in: #"{"a": 1}"#)
        XCTAssertEqual(raw, #"{"a": 1}"#)
    }

    func testExtractObjectWithSurroundingProse() {
        let text = "Sure! Here is the answer: {\"refund\": true} — hope that helps."
        XCTAssertEqual(JSONExtractor.firstObject(in: text), #"{"refund": true}"#)
    }

    func testExtractNestedBraces() {
        let text = #"prefix {"outer": {"inner": [1, {"deep": true}]}} suffix"#
        XCTAssertEqual(JSONExtractor.firstObject(in: text),
                       #"{"outer": {"inner": [1, {"deep": true}]}}"#)
    }

    func testExtractIgnoresBracesInsideStrings() {
        let text = #"{"template": "use {x} and }here", "ok": true}"#
        XCTAssertEqual(JSONExtractor.firstObject(in: text),
                       #"{"template": "use {x} and }here", "ok": true}"#)
    }

    func testExtractIgnoresEscapedQuotes() {
        let text = #"{"quote": "she said \"hi}\" loudly", "ok": 1}"#
        XCTAssertEqual(JSONExtractor.firstObject(in: text),
                       #"{"quote": "she said \"hi}\" loudly", "ok": 1}"#)
    }

    func testExtractFromCodeFence() {
        let text = "Answer:\n```json\n{\"refund\": false}\n```\nDone."
        XCTAssertEqual(JSONExtractor.firstObject(in: text), #"{"refund": false}"#)
    }

    func testExtractFromUnlabeledCodeFence() {
        let text = "```\n{\"a\": [1, 2]}\n```"
        XCTAssertEqual(JSONExtractor.firstObject(in: text), #"{"a": [1, 2]}"#)
    }

    func testNoObjectReturnsNil() {
        XCTAssertNil(JSONExtractor.firstObject(in: "no json here at all"))
        XCTAssertNil(JSONExtractor.firstObject(in: ""))
    }

    func testUnbalancedObjectReturnsNil() {
        XCTAssertNil(JSONExtractor.firstObject(in: #"{"a": 1"#))
    }

    func testFirstBalancedWinsOverLaterGarbage() {
        let text = #"{"a": 1} and then {unbalanced"#
        XCTAssertEqual(JSONExtractor.firstObject(in: text), #"{"a": 1}"#)
    }

    func testDecodeFirstObject() {
        let value = JSONExtractor.decodeFirstObject(in: #"blah {"x": [1, "two", null]} blah"#)
        guard case .object(let fields) = value, case .array(let arr) = fields["x"] else {
            return XCTFail("expected object with array x")
        }
        XCTAssertEqual(arr.count, 3)
    }

    // MARK: - Output validation

    private func question(_ type: DecisionSchema.QuestionType, key: String = "q") -> DecisionSchema.Question {
        DecisionSchema.Question(key: key, type: type, instructions: "")
    }

    func testValidateChoice() throws {
        let q = question(.choice(options: ["a", "b"], multi: false))
        XCTAssertEqual(try DecisionOutputValidator.validate(.string("a"), for: q), .string("a"))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("c"), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(1), for: q))
    }

    func testValidateMultiChoice() throws {
        let q = question(.choice(options: ["a", "b", "c"], multi: true))
        XCTAssertEqual(try DecisionOutputValidator.validate(.array([.string("a"), .string("c")]), for: q),
                       .array([.string("a"), .string("c")]))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.array([]), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.array([.string("z")]), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("a"), for: q))
    }

    func testValidateScore() throws {
        let q = question(.score(min: 1, max: 5, integer: false))
        XCTAssertEqual(try DecisionOutputValidator.validate(.number(3.5), for: q), .number(3.5))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(0.9), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(5.1), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("3"), for: q))
    }

    func testValidateIntegerScore() throws {
        let q = question(.score(min: 1, max: 5, integer: true))
        XCTAssertEqual(try DecisionOutputValidator.validate(.number(4), for: q), .number(4))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(4.5), for: q))
    }

    func testValidateBoolean() throws {
        let q = question(.boolean)
        XCTAssertEqual(try DecisionOutputValidator.validate(.bool(true), for: q), .bool(true))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("true"), for: q))
    }

    func testValidateProbability() throws {
        let q = question(.probability)
        XCTAssertEqual(try DecisionOutputValidator.validate(.number(0.25), for: q), .number(0.25))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(1.5), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.number(-0.1), for: q))
    }

    func testValidateNoul() throws {
        let q = question(.noul(levels: 5))
        XCTAssertEqual(try DecisionOutputValidator.validate(.string("Likely"), for: q), .string("likely"))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("definitely"), for: q))
    }

    func testValidateRankingRequiresPermutation() throws {
        let q = question(.ranking(items: ["a", "b", "c"]))
        XCTAssertEqual(try DecisionOutputValidator.validate(.array([.string("c"), .string("a"), .string("b")]), for: q),
                       .array([.string("c"), .string("a"), .string("b")]))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.array([.string("a"), .string("a"), .string("b")]), for: q))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.array([.string("a")]), for: q))
    }

    func testValidateStructuredObject() throws {
        let schema: JSONSchema = .object(
            properties: [
                "name": .string(enumValues: nil, minLength: 1, maxLength: nil),
                "age": .integer(min: 0, max: 150),
                "tags": .array(items: .string(enumValues: nil, minLength: nil, maxLength: nil),
                               minItems: nil, maxItems: 3),
            ],
            required: ["name"])
        let q = question(.structured(schema))
        let good: JSONValue = .object([
            "name": .string("ada"),
            "age": .number(36),
            "tags": .array([.string("x"), .string("y")]),
        ])
        XCTAssertEqual(try DecisionOutputValidator.validate(good, for: q), good)

        // missing required
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.object(["age": .number(3)]), for: q)) { error in
            guard let failure = error as? DecisionOutputValidator.ValidationFailure else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(failure.description.contains("name"))
        }
        // integer out of range
        XCTAssertThrowsError(try DecisionOutputValidator.validate(
            .object(["name": .string("a"), "age": .number(200)]), for: q))
        // array over maxItems
        XCTAssertThrowsError(try DecisionOutputValidator.validate(
            .object(["name": .string("a"),
                     "tags": .array([.string("1"), .string("2"), .string("3"), .string("4")])]), for: q))
        // wrong type at a nested path reports the path
        XCTAssertThrowsError(try DecisionOutputValidator.validate(
            .object(["name": .string("a"), "age": .string("old")]), for: q)) { error in
            guard let failure = error as? DecisionOutputValidator.ValidationFailure else {
                return XCTFail("wrong error type")
            }
            XCTAssertEqual(failure.path, "q.age")
        }
    }

    func testValidateStructuredEnum() throws {
        let q = question(.structured(.enumeration([.string("red"), .string("blue")])))
        XCTAssertEqual(try DecisionOutputValidator.validate(.string("red"), for: q), .string("red"))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("green"), for: q))
    }

    func testValidateStructuredStringEnumAndLength() throws {
        let q = question(.structured(.string(enumValues: ["s", "m"], minLength: nil, maxLength: nil)))
        XCTAssertEqual(try DecisionOutputValidator.validate(.string("m"), for: q), .string("m"))
        XCTAssertThrowsError(try DecisionOutputValidator.validate(.string("xl"), for: q))
    }
}
