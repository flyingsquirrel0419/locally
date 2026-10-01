import Foundation
import LocallyCore
import LocallyRuntime
import Observation

/// Drives the decision playground: owns the schema under construction, runs
/// it through a DecisionRuntime that wraps the router-chosen text runtime,
/// and exposes per-question results. Nothing is simulated — every value on
/// screen comes from the runtime's events or the schema parser.
@Observable
@MainActor
final class DecisionPlaygroundViewModel {

    /// One editable question row in the builder.
    struct EditableQuestion: Identifiable {
        enum Kind: String, CaseIterable, Identifiable {
            case boolean, choice, multiChoice, probability, noul, score, ranking, structured
            var id: String { rawValue }
        }

        let id = UUID()
        var key: String
        var kind: Kind
        var instructions: String = ""
        /// Comma-separated options/items for choice/ranking kinds.
        var optionsText: String = ""
        var scoreMin: Double = 1
        var scoreMax: Double = 5
        var scoreInteger: Bool = true
        /// Raw JSON-schema text for the structured kind.
        var schemaText: String = #"{"type": "object", "properties": {}, "required": []}"#
    }

    /// One answered question for the results list.
    struct AnsweredQuestion: Identifiable {
        let id = UUID()
        let key: String
        let valueText: String
        let method: String
        /// Top-1 probability when the scored path produced a distribution.
        let probability: Double?
        let latency: TimeInterval
    }

    var stateText = ""
    var questions: [EditableQuestion] = []
    /// Raw-schema editing mode: when on, `rawSchemaText` is the source of
    /// truth and the builder is disabled.
    var editingRawJSON = false
    var rawSchemaText = ""

    private(set) var results: [AnsweredQuestion] = []
    private(set) var schemaError: String?
    private(set) var lastError: String?
    private(set) var isPreparing = false
    private(set) var prepared = false

    var isRunning: Bool { runTask != nil }

    private let model: ModelDescriptor
    private let router: RuntimeRouter
    private let device: DeviceCapabilities
    private var textRuntime: (any ModelCompatibleRuntime)?
    private var runTask: Task<Void, Never>?
    private var loadAttempted = false

    init(model: ModelDescriptor, router: RuntimeRouter, device: DeviceCapabilities) {
        self.model = model
        self.router = router
        self.device = device
    }

    /// Load the router-chosen text runtime once; decision runs wrap it.
    func prepareIfNeeded() async {
        guard !loadAttempted else { return }
        loadAttempted = true
        isPreparing = true
        defer { isPreparing = false }
        guard let runtime = router.runtime(for: model, on: device) else {
            lastError = String(localized: "decision.noRuntime", table: "Decision")
            return
        }
        do {
            try await runtime.load(model)
            textRuntime = runtime
            prepared = true
        } catch let error as LocallyError {
            lastError = error.userMessage
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addQuestion() {
        let key = "q\(questions.count + 1)"
        questions.append(EditableQuestion(key: key, kind: .boolean))
        if editingRawJSON { syncRawFromBuilder() }
    }

    func removeQuestion(_ id: UUID) {
        questions.removeAll { $0.id == id }
        if editingRawJSON { syncRawFromBuilder() }
    }

    /// Serialize the builder state into the raw schema document.
    func syncRawFromBuilder() {
        var questionObjects: [String: JSONValue] = [:]
        for question in questions {
            questionObjects[question.key] = Self.schemaObject(for: question)
        }
        let document: JSONValue = .object([
            "state": .string(stateText),
            "questions": .object(questionObjects),
        ])
        guard let data = try? JSONEncoder().encode(document),
              let text = String(data: data, encoding: .utf8) else { return }
        rawSchemaText = text
    }

    /// Parse the raw schema back into the builder (best-effort; unparseable
    /// questions are skipped and the parse error surfaces on Run).
    func syncBuilderFromRaw() {
        guard let data = rawSchemaText.data(using: .utf8),
              let schema = try? DecisionSchemaParser.parse(data: data) else { return }
        stateText = schema.state
        questions = schema.questions.compactMap(Self.editableQuestion(for:))
    }

    /// Build the schema document from the active editor and validate it.
    /// Returns nil and sets `schemaError` on failure.
    private func buildSchema() -> DecisionSchema? {
        schemaError = nil
        if editingRawJSON {
            guard let data = rawSchemaText.data(using: .utf8) else {
                schemaError = String(localized: "decision.schema.invalidUTF8", table: "Decision")
                return nil
            }
            do {
                return try DecisionSchemaParser.parse(data: data)
            } catch let error as DecisionSchemaError {
                schemaError = error.description
                return nil
            } catch {
                schemaError = error.localizedDescription
                return nil
            }
        }
        var questionObjects: [String: JSONValue] = [:]
        for question in questions {
            let trimmedKey = question.key.trimmingCharacters(in: .whitespaces)
            guard !trimmedKey.isEmpty else {
                schemaError = String(localized: "decision.schema.emptyKey", table: "Decision")
                return nil
            }
            if let message = Self.validate(question) {
                schemaError = "\(trimmedKey): \(message)"
                return nil
            }
            questionObjects[trimmedKey] = Self.schemaObject(for: question)
        }
        guard !questionObjects.isEmpty else {
            schemaError = String(localized: "decision.schema.noQuestions", table: "Decision")
            return nil
        }
        let document: JSONValue = .object([
            "state": .string(stateText),
            "questions": .object(questionObjects),
        ])
        do {
            guard let data = try? JSONEncoder().encode(document) else { return nil }
            return try DecisionSchemaParser.parse(data: data)
        } catch let error as DecisionSchemaError {
            schemaError = error.description
            return nil
        } catch {
            schemaError = error.localizedDescription
            return nil
        }
    }

    func run() {
        guard !isRunning, prepared, let textRuntime else { return }
        guard let schema = buildSchema() else { return }
        results = []
        lastError = nil

        let decisionRuntime = DecisionRuntime(wrapping: textRuntime, model: model)
        let document: JSONValue = .object([
            "state": .string(schema.state),
            "questions": .object(Dictionary(uniqueKeysWithValues: schema.questions.map {
                ($0.key, Self.schemaObject(for: $0))
            })),
        ])
        let request = AIRequest(model: model, input: .json(document))
        let start = ContinuousClock.now

        runTask = Task { [weak self] in
            guard let self else { return }
            let stream = decisionRuntime.run(request)
            var perQuestion: [AnsweredQuestion] = []
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .decision(let decision):
                        perQuestion.append(Self.answered(
                            decision, since: start,
                            alreadyAnswered: perQuestion.count))
                        self.results = perQuestion
                    case .completed(let result):
                        // Terminal: rebuild from the full artifact list so a
                        // consumer that joined late still sees everything.
                        let all = result.artifacts.compactMap { artifact -> DecisionResult? in
                            guard case .decision(let d) = artifact else { return nil }
                            return d
                        }
                        if !all.isEmpty {
                            perQuestion = all.enumerated().map { index, decision in
                                Self.answered(decision, since: start, alreadyAnswered: index)
                            }
                            self.results = perQuestion
                        }
                    case .failed(let error):
                        self.lastError = error.userMessage
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled { self.lastError = error.localizedDescription }
            }
            self.runTask = nil
        }
    }

    func stop() {
        runTask?.cancel()
    }

    // MARK: - Schema mapping

    private static func schemaObject(for question: EditableQuestion) -> JSONValue {
        var fields: [String: JSONValue] = [
            "instructions": .string(question.instructions),
        ]
        switch question.kind {
        case .boolean:
            fields["type"] = .string("boolean")
        case .choice, .multiChoice:
            fields["type"] = .string("choice")
            fields["options"] = .array(splitList(question.optionsText).map { .string($0) })
            if question.kind == .multiChoice { fields["multi"] = .bool(true) }
        case .probability:
            fields["type"] = .string("probability")
        case .noul:
            fields["type"] = .string("noul")
        case .score:
            fields["type"] = .string("score")
            fields["min"] = .number(question.scoreMin)
            fields["max"] = .number(question.scoreMax)
            if question.scoreInteger { fields["integer"] = .bool(true) }
        case .ranking:
            fields["type"] = .string("ranking")
            fields["items"] = .array(splitList(question.optionsText).map { .string($0) })
        case .structured:
            fields["type"] = .string("structured")
            if let data = question.schemaText.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                fields["schema"] = value
            } else {
                fields["schema"] = .object([:])
            }
        }
        return .object(fields)
    }

    private static func schemaObject(for question: DecisionSchema.Question) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string(question.typeName),
            "instructions": .string(question.instructions),
        ]
        switch question.type {
        case .choice(let options, let multi):
            fields["options"] = .array(options.map { .string($0) })
            if multi { fields["multi"] = .bool(true) }
        case .score(let min, let max, let integer):
            fields["min"] = .number(min)
            fields["max"] = .number(max)
            if integer { fields["integer"] = .bool(true) }
        case .noul(let levels):
            fields["levels"] = .number(Double(levels))
        case .ranking(let items):
            fields["items"] = .array(items.map { .string($0) })
        case .structured(let schema):
            fields["schema"] = encode(schema: schema)
        case .boolean, .probability:
            break
        }
        return .object(fields)
    }

    private static func encode(schema: JSONSchema) -> JSONValue {
        switch schema {
        case .object(let properties, let required):
            return .object([
                "type": .string("object"),
                "properties": .object(properties.mapValues(encode(schema:))),
                "required": .array(required.sorted().map { .string($0) }),
            ])
        case .array(let items, let minItems, let maxItems):
            var fields: [String: JSONValue] = ["type": .string("array"), "items": encode(schema: items)]
            if let minItems { fields["minItems"] = .number(Double(minItems)) }
            if let maxItems { fields["maxItems"] = .number(Double(maxItems)) }
            return .object(fields)
        case .string(let enumValues, let minLength, let maxLength):
            var fields: [String: JSONValue] = ["type": .string("string")]
            if let enumValues { fields["enum"] = .array(enumValues.map { .string($0) }) }
            if let minLength { fields["minLength"] = .number(Double(minLength)) }
            if let maxLength { fields["maxLength"] = .number(Double(maxLength)) }
            return .object(fields)
        case .number(let min, let max):
            var fields: [String: JSONValue] = ["type": .string("number")]
            if let min { fields["min"] = .number(min) }
            if let max { fields["max"] = .number(max) }
            return .object(fields)
        case .integer(let min, let max):
            var fields: [String: JSONValue] = ["type": .string("integer")]
            if let min { fields["min"] = .number(Double(min)) }
            if let max { fields["max"] = .number(Double(max)) }
            return .object(fields)
        case .boolean: return .object(["type": .string("boolean")])
        case .null: return .object(["type": .string("null")])
        case .enumeration(let values):
            return .object(["enum": .array(values)])
        }
    }

    private static func editableQuestion(for question: DecisionSchema.Question) -> EditableQuestion? {
        var editable = EditableQuestion(key: question.key, kind: .boolean)
        editable.instructions = question.instructions
        switch question.type {
        case .boolean: editable.kind = .boolean
        case .probability: editable.kind = .probability
        case .noul: editable.kind = .noul
        case .choice(let options, let multi):
            editable.kind = multi ? .multiChoice : .choice
            editable.optionsText = options.joined(separator: ", ")
        case .score(let min, let max, let integer):
            editable.kind = .score
            editable.scoreMin = min
            editable.scoreMax = max
            editable.scoreInteger = integer
        case .ranking(let items):
            editable.kind = .ranking
            editable.optionsText = items.joined(separator: ", ")
        case .structured(let schema):
            editable.kind = .structured
            let value = encode(schema: schema)
            if let data = try? JSONEncoder().encode(value),
               let text = String(data: data, encoding: .utf8) {
                editable.schemaText = text
            }
        }
        return editable
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Builder-side validation before the schema even reaches the parser,
    /// so errors point at the row the user is editing.
    private static func validate(_ question: EditableQuestion) -> String? {
        switch question.kind {
        case .choice, .multiChoice, .ranking:
            let items = splitList(question.optionsText)
            if items.count < 2 {
                return String(localized: "decision.schema.needTwoOptions", table: "Decision")
            }
            if Set(items).count != items.count {
                return String(localized: "decision.schema.duplicateOptions", table: "Decision")
            }
        case .score:
            if question.scoreMin >= question.scoreMax {
                return String(localized: "decision.schema.badRange", table: "Decision")
            }
        case .structured:
            guard let data = question.schemaText.data(using: .utf8),
                  (try? JSONDecoder().decode(JSONValue.self, from: data)) != nil else {
                return String(localized: "decision.schema.badSchemaJSON", table: "Decision")
            }
        case .boolean, .probability, .noul:
            break
        }
        return nil
    }

    private static func answered(_ decision: DecisionResult,
                                 since start: ContinuousClock.Instant,
                                 alreadyAnswered: Int) -> AnsweredQuestion {
        // Per-question latency: the stream emits one completed event per
        // question, so the wall time so far minus nothing finer is the honest
        // figure available here.
        let latency = start.duration(to: .now).seconds
        let topProbability = decision.probabilities?
            .filter { !$0.key.hasPrefix("_") }
            .values.max()
        return AnsweredQuestion(
            key: decision.key,
            valueText: describe(decision.value),
            method: decision.method?.rawValue
                ?? String(localized: "decision.method.unknown", table: "Decision"),
            probability: topProbability,
            latency: latency)
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(format: "%.3f", n)
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return items.map(describe).joined(separator: ", ")
        case .object(let object):
            guard let data = try? JSONEncoder().encode(value),
                  let text = String(data: data, encoding: .utf8) else { return "{…}" }
            _ = object
            return text
        case .null: return "null"
        }
    }
}

private extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
