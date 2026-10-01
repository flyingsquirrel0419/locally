import XCTest
@testable import LocallyRuntime
import LocallyCore

/// Loads the Decision fixtures from Tests/Fixtures/Decision and exercises
/// them end-to-end with mock backends.
final class DecisionFixtureTests: XCTestCase {

    private enum Fixtures {
        static let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Decision")

        static func data(_ name: String) throws -> Data {
            try Data(contentsOf: directory.appendingPathComponent(name))
        }
    }

    func testRefundRequestFixtureParsesAndRuns() async throws {
        let data = try Fixtures.data("refund-request.json")
        let schema = try DecisionSchemaParser.parse(data: data)
        XCTAssertEqual(schema.questions.map(\.key),
                       ["approve_refund", "confidence", "priority", "resolution", "review"])

        // The mock keys on candidate text alone, so "yes"/"no" are shared by
        // the boolean, probability, and noul questions. Scores chosen so the
        // intended winner of every question comes out on top:
        // boolean yes; noul label "likely" edges "yes" out.
        let scoring = MockScoringBackend(scores: [
            "yes": -0.3, "no": -2.5,
            "refund": -0.2, "replacement": -1.5, "repair": -3.0, "reject": -4.0,
            "1": -6, "2": -3, "3": -1, "4": -0.1, "5": -1.2,
            "unlikely": -1.5, "unsure": -1.0, "likely": -0.2,
        ])
        let engine = DecisionEngine(scoringBackend: scoring)
        let results = try await engine.answerAll(schema: schema)
        XCTAssertEqual(results.count, 5)
        for result in results {
            XCTAssertEqual(result.method, .scored)
            XCTAssertNotNil(result.probabilities)
        }
        XCTAssertEqual(results.first(where: { $0.key == "approve_refund" })?.value, .bool(true))
        XCTAssertEqual(results.first(where: { $0.key == "resolution" })?.value, .string("refund"))
        XCTAssertEqual(results.first(where: { $0.key == "review" })?.value, .string("likely"))
        XCTAssertEqual(results.first(where: { $0.key == "priority" })?.value, .number(4))
    }

    func testTicketTriageFixtureParsesAndRuns() async throws {
        let data = try Fixtures.data("ticket-triage.json")
        let schema = try DecisionSchemaParser.parse(data: data)
        XCTAssertEqual(schema.questions.map(\.key), ["order", "summary", "tags"])

        let generation = MockGenerationBackend(responses: [
            #"{"order": ["login-500", "ipad-alignment", "csv-export"]}"#,
            #"{"summary": {"title": "Login 500s", "severity": "critical", "affected_users": 400}}"#,
            #"{"tags": ["bug", "outage"]}"#,
        ])
        let engine = DecisionEngine(generationBackend: generation)
        let results = try await engine.answerAll(schema: schema)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].key, "order")
        guard case .array(let order) = results[0].value else { return XCTFail("order not array") }
        XCTAssertEqual(order.first, .string("login-500"))
        XCTAssertEqual(results[1].key, "summary")
        XCTAssertEqual(results[2].key, "tags")
        guard case .array(let tags) = results[2].value else { return XCTFail("tags not array") }
        XCTAssertEqual(tags.count, 2)
    }
}
