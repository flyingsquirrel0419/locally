import Foundation
import LocallyCore

/// Answers each question of a DecisionSchema via a pluggable backend.
/// Token scoring (calibrated) is preferred when available; free-text
/// generation with strict output validation is the fallback.
public struct DecisionEngine: Sendable {
    public enum BackendPreference: Sendable, Hashable {
        /// Use the scoring backend when one is provided, else generation.
        case automatic
        case scoringOnly
        case generationOnly
    }

    public var scoringBackend: (any TokenScoringBackend)?
    public var generationBackend: (any TextGenerationBackend)?
    public var preference: BackendPreference
    /// Chat template to render prompts through; nil uses ChatML.
    public var chatTemplate: String?
    /// Retry budget for generation output that fails validation: one retry
    /// with the validation error appended, then a DecisionError.
    public var maxGenerationAttempts: Int

    public init(scoringBackend: (any TokenScoringBackend)? = nil,
                generationBackend: (any TextGenerationBackend)? = nil,
                preference: BackendPreference = .automatic,
                chatTemplate: String? = nil,
                maxGenerationAttempts: Int = 2) {
        self.scoringBackend = scoringBackend
        self.generationBackend = generationBackend
        self.preference = preference
        self.chatTemplate = chatTemplate
        self.maxGenerationAttempts = max(1, maxGenerationAttempts)
    }

    /// Which method a question will use with the configured backends.
    public func method(for question: DecisionSchema.Question) -> DecisionResult.Method? {
        let canScore = scoringBackend != nil && preference != .generationOnly
        let canGenerate = generationBackend != nil && preference != .scoringOnly
        if canScore { return .scored }
        if canGenerate { return .generated }
        return nil
    }

    /// Answer one question. Emits nothing; callers assemble events.
    public func answer(question: DecisionSchema.Question,
                       schema: DecisionSchema) async throws -> DecisionResult {
        guard let method = method(for: question) else {
            throw DecisionError.backendFailed(
                userMessage: "No decision backend is available.",
                detail: "engine has neither a scoring nor a generation backend that is enabled")
        }
        switch method {
        case .scored:
            return try await answerScored(question: question, schema: schema)
        case .generated:
            return try await answerGenerated(question: question, schema: schema)
        }
    }

    public func answerAll(schema: DecisionSchema) async throws -> [DecisionResult] {
        var results: [DecisionResult] = []
        for question in schema.questions {
            results.append(try await answer(question: question, schema: schema))
        }
        return results
    }

    // MARK: - Scored path

    private func answerScored(question: DecisionSchema.Question,
                              schema: DecisionSchema) async throws -> DecisionResult {
        guard let scoringBackend else {
            throw DecisionError.backendFailed(userMessage: "Scoring backend unavailable.", detail: "nil backend")
        }
        let prompt = renderPrompt(for: question, schema: schema, style: .continuation)

        switch question.type {
        case .choice(let options, let multi):
            let logProbs = try await score(scoringBackend, prompt: prompt, candidates: options)
            let probs = Self.softmax(logProbs)
            var table: [String: Double] = [:]
            for (option, p) in zip(options, probs) { table[option] = p }
            if multi {
                // Independent Bernoulli per option: P(option) vs P(not option).
                var picked: [JSONValue] = []
                for option in options {
                    let yes = try await score(scoringBackend, prompt: prompt, candidates: [option]).first ?? -.infinity
                    let no = log1p(-exp(min(yes, 0)))
                    let p = 1 / (1 + exp(no - yes))
                    table[option] = p
                    if p >= 0.5 { picked.append(.string(option)) }
                }
                if picked.isEmpty, let best = table.max(by: { $0.value < $1.value })?.key {
                    picked = [.string(best)]
                }
                return DecisionResult(key: question.key, value: .array(picked),
                                      type: "choice", probabilities: table, method: .scored)
            }
            let best = zip(options, probs).max(by: { $0.1 < $1.1 })!.0
            return DecisionResult(key: question.key, value: .string(best),
                                  type: "choice", probabilities: table, method: .scored)

        case .boolean:
            let logProbs = try await score(scoringBackend, prompt: prompt, candidates: ["yes", "no"])
            let p = Self.probabilityYes(logYes: logProbs[0], logNo: logProbs[1])
            return DecisionResult(key: question.key, value: .bool(p >= 0.5),
                                  type: "boolean",
                                  probabilities: ["yes": p, "no": 1 - p],
                                  method: .scored)

        case .probability:
            let logProbs = try await score(scoringBackend, prompt: prompt, candidates: ["yes", "no"])
            let p = Self.probabilityYes(logYes: logProbs[0], logNo: logProbs[1])
            return DecisionResult(key: question.key, value: .number(p),
                                  type: "probability",
                                  probabilities: ["yes": p, "no": 1 - p],
                                  method: .scored)

        case .noul(let levels):
            let labels = NoulScale.labels(levels: levels)
            let logProbs = try await score(scoringBackend, prompt: prompt, candidates: labels)
            let probs = Self.softmax(logProbs)
            var table: [String: Double] = [:]
            var expected = 0.0
            for (label, p) in zip(labels, probs) {
                table[label] = p
                expected += p * (NoulScale.probability(of: label, levels: levels) ?? 0)
            }
            let best = zip(labels, probs).max(by: { $0.1 < $1.1 })!.0
            return DecisionResult(key: question.key, value: .string(best),
                                  type: "noul",
                                  probabilities: table + ["_probabilityOfYes": expected],
                                  method: .scored)

        case .score(let min, let max, let integer):
            if integer {
                let lo = Int(min), hi = Int(max)
                let candidates = (lo...hi).map(String.init)
                let logProbs = try await score(scoringBackend, prompt: prompt, candidates: candidates)
                let probs = Self.softmax(logProbs)
                var table: [String: Double] = [:]
                var expectation = 0.0
                for (candidate, p) in zip(candidates, probs) {
                    table[candidate] = p
                    expectation += Double(candidate)! * p
                }
                let best = zip(candidates, probs).max(by: { $0.1 < $1.1 })!.0
                return DecisionResult(key: question.key, value: .number(Double(best)!),
                                      type: "score",
                                      probabilities: table + ["_expectation": expectation],
                                      method: .scored)
            }
            // Continuous score: probability-style yes/no on "above midpoint"
            // anchors at deciles; expectation over the 11 anchor points.
            let anchors = stride(from: 0, through: 10, by: 1).map { min + (max - min) * Double($0) / 10 }
            var weights: [Double] = []
            for anchor in anchors {
                let anchorPrompt = prompt + "\nIs the score at least \(Self.formatNumber(anchor))? Answer yes or no."
                let logProbs = try await score(scoringBackend, prompt: anchorPrompt, candidates: ["yes", "no"])
                weights.append(Self.probabilityYes(logYes: logProbs[0], logNo: logProbs[1]))
            }
            // Convert cumulative P(score >= a) into a point distribution.
            var masses: [Double] = [1 - (weights.first ?? 1)]
            for i in 1..<weights.count { masses.append(Swift.max(weights[i - 1] - weights[i], 0)) }
            masses.append(weights.last ?? 0)
            let total = masses.reduce(0, +)
            let expectation = total > 0
                ? zip(anchors, masses).reduce(0) { $0 + $1.0 * $1.1 } / total
                : (min + max) / 2
            var table: [String: Double] = ["_expectation": expectation]
            for (anchor, mass) in zip(anchors, masses) {
                table[Self.formatNumber(anchor)] = total > 0 ? mass / total : 0
            }
            return DecisionResult(key: question.key, value: .number(expectation),
                                  type: "score", probabilities: table, method: .scored)

        case .ranking(let items):
            // Per-item relevance scoring: P(item is the best) via softmax over
            // per-item scores, then sort descending.
            var logProbs: [Double] = []
            for item in items {
                let itemPrompt = prompt + "\nItem: \(item)\nRelevance (high or low):"
                let pair = try await score(scoringBackend, prompt: itemPrompt, candidates: ["high", "low"])
                logProbs.append(pair[0] - pair[1])
            }
            let probs = Self.softmax(logProbs)
            var table: [String: Double] = [:]
            for (item, p) in zip(items, probs) { table[item] = p }
            let ordered = zip(items, probs).sorted { $0.1 > $1.1 }.map { $0.0 }
            return DecisionResult(key: question.key, value: .array(ordered.map { .string($0) }),
                                  type: "ranking", probabilities: table, method: .scored)

        case .structured:
            // Structured output cannot be token-scored; fall through to
            // generation when available.
            guard generationBackend != nil, preference != .scoringOnly else {
                throw DecisionError.backendFailed(
                    userMessage: "This question needs free-text generation, which is not available.",
                    detail: "structured question '\(question.key)' has no generation backend")
            }
            return try await answerGenerated(question: question, schema: schema)
        }
    }

    private func score(_ backend: any TokenScoringBackend,
                       prompt: String, candidates: [String]) async throws -> [Double] {
        do {
            let logProbs = try await backend.logProbabilities(prompt: prompt, candidates: candidates)
            guard logProbs.count == candidates.count else {
                throw DecisionError.backendFailed(
                    userMessage: "The scoring backend returned a malformed result.",
                    detail: "expected \(candidates.count) log-probs, got \(logProbs.count)")
            }
            return logProbs
        } catch let error as DecisionError {
            throw error
        } catch {
            throw DecisionError.backendFailed(
                userMessage: "The scoring backend failed.",
                detail: "\(error)")
        }
    }

    // MARK: - Generated path

    private func answerGenerated(question: DecisionSchema.Question,
                                 schema: DecisionSchema) async throws -> DecisionResult {
        guard let generationBackend else {
            throw DecisionError.backendFailed(userMessage: "Generation backend unavailable.", detail: "nil backend")
        }
        let basePrompt = renderPrompt(for: question, schema: schema, style: .json)
        var prompt = basePrompt
        var lastFailure: String = "no output"
        var rawText = ""

        for attempt in 0..<maxGenerationAttempts {
            do {
                rawText = try await generationBackend.generate(prompt: prompt, maxTokens: 512)
            } catch let error as LocallyError {
                throw DecisionError.backendFailed(userMessage: error.userMessage, detail: error.technicalDetail)
            } catch {
                throw DecisionError.backendFailed(
                    userMessage: "The model failed to produce an answer.", detail: "\(error)")
            }
            guard let object = JSONExtractor.decodeFirstObject(in: rawText),
                  case .object(let fields) = object else {
                lastFailure = "output contained no JSON object"
                prompt = Self.retryPrompt(base: basePrompt, problem: lastFailure)
                continue
            }
            guard let value = fields[question.key] else {
                lastFailure = "JSON object is missing the key '\(question.key)'"
                prompt = Self.retryPrompt(base: basePrompt, problem: lastFailure)
                continue
            }
            do {
                let validated = try DecisionOutputValidator.validate(value, for: question)
                return DecisionResult(key: question.key, value: validated,
                                      type: question.typeName, method: .generated,
                                      rawText: rawText)
            } catch let failure as DecisionOutputValidator.ValidationFailure {
                lastFailure = failure.description
                prompt = Self.retryPrompt(base: basePrompt, problem: lastFailure)
                _ = attempt
            }
        }
        throw DecisionError.invalidOutput(
            userMessage: "The model could not produce a valid answer for '\(question.key)'.",
            detail: "after \(maxGenerationAttempts) attempts: \(lastFailure)")
    }

    static func retryPrompt(base: String, problem: String) -> String {
        base + "\n\nYour previous answer was invalid: \(problem). Respond again with only the corrected JSON object."
    }

    // MARK: - Prompt building (deterministic, temperature 0 by contract)

    enum PromptStyle {
        /// Prompt ends mid-answer so a scoring backend can rank continuations.
        case continuation
        /// Prompt demands a single JSON object answer.
        case json
    }

    func renderPrompt(for question: DecisionSchema.Question,
                      schema: DecisionSchema, style: PromptStyle) -> String {
        var body = "State:\n\(schema.state)\n\n"
        body += "Question key: \(question.key)\n"
        if !question.instructions.isEmpty {
            body += "Instructions: \(question.instructions)\n"
        }
        body += Self.typeDirective(for: question, style: style)

        let session = TextGenerationSession(turns: [ChatTurn(role: .user, content: body)])
        if let rendered = session.render(template: chatTemplate) {
            return rendered
        }
        return session.renderChatML()
    }

    static func typeDirective(for question: DecisionSchema.Question, style: PromptStyle) -> String {
        let key = question.key
        switch question.type {
        case .choice(let options, let multi):
            let list = options.joined(separator: ", ")
            switch style {
            case .continuation:
                return multi
                    ? "For each option decide if it applies. Options: \(list).\nAnswer:"
                    : "Choose exactly one of: \(list).\nAnswer:"
            case .json:
                return multi
                    ? "Choose any number of: \(list). Respond with only: {\"\(key)\": [\"<option>\", ...]}"
                    : "Choose exactly one of: \(list). Respond with only: {\"\(key)\": \"<option>\"}"
            }
        case .boolean:
            switch style {
            case .continuation: return "Answer yes or no.\nAnswer:"
            case .json: return "Answer yes or no. Respond with only: {\"\(key)\": true} or {\"\(key)\": false}"
            }
        case .probability:
            switch style {
            case .continuation: return "Is the answer yes?\nAnswer:"
            case .json: return "Give the probability that the answer is yes as a number from 0 to 1. Respond with only: {\"\(key)\": <number>}"
            }
        case .noul(let levels):
            let labels = NoulScale.labels(levels: levels).joined(separator: ", ")
            switch style {
            case .continuation: return "Answer with one of: \(labels).\nAnswer:"
            case .json: return "Answer with one of: \(labels). Respond with only: {\"\(key)\": \"<label>\"}"
            }
        case .score(let min, let max, let integer):
            let kind = integer ? "whole number" : "number"
            switch style {
            case .continuation: return "Give a \(kind) score from \(formatNumber(min)) to \(formatNumber(max)).\nAnswer:"
            case .json: return "Give a \(kind) score from \(formatNumber(min)) to \(formatNumber(max)). Respond with only: {\"\(key)\": <number>}"
            }
        case .ranking(let items):
            let list = items.joined(separator: ", ")
            switch style {
            case .continuation: return "Rank these items from best to worst: \(list)."
            case .json: return "Rank these items from best to worst: \(list). Respond with only: {\"\(key)\": [\"<item>\", ...]} listing every item exactly once."
            }
        case .structured(let schema):
            let schemaText = Self.describe(schema: schema)
            return "Respond with only a JSON object shaped like: {\"\(key)\": \(schemaText)}"
        }
    }

    /// Compact JSON-Schema rendering for prompts (types and required fields).
    static func describe(schema: JSONSchema) -> String {
        switch schema {
        case .object(let properties, let required):
            let fields = properties.keys.sorted().map { name -> String in
                let marker = required.contains(name) ? "" : "?"
                return "\"\(name)\(marker)\": \(describe(schema: properties[name]!))"
            }
            return "{\(fields.joined(separator: ", "))}"
        case .array(let items, _, _):
            return "[\(describe(schema: items))]"
        case .string(let enumValues, _, _):
            if let enumValues { return enumValues.map { "\"\($0)\"" }.joined(separator: " | ") }
            return "\"string\""
        case .number(let min, let max):
            return "number\(rangeSuffix(min: min, max: max))"
        case .integer(let min, let max):
            return "integer\(rangeSuffix(min: min.map(Double.init), max: max.map(Double.init)))"
        case .boolean: return "true | false"
        case .null: return "null"
        case .enumeration(let values):
            return values.map { Self.describeValue($0) }.joined(separator: " | ")
        }
    }

    private static func describeValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return formatNumber(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array: return "[...]"
        case .object: return "{...}"
        }
    }

    private static func rangeSuffix(min: Double?, max: Double?) -> String {
        switch (min, max) {
        case let (lo?, hi?): return " in [\(formatNumber(lo)), \(formatNumber(hi))]"
        case let (lo?, nil): return " >= \(formatNumber(lo))"
        case let (nil, hi?): return " <= \(formatNumber(hi))"
        case (nil, nil): return ""
        }
    }

    static func formatNumber(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(n)
    }

    // MARK: - Math

    /// Numerically stable softmax over log-probabilities.
    public static func softmax(_ logProbs: [Double]) -> [Double] {
        guard let maxLog = logProbs.max() else { return [] }
        if maxLog == -.infinity { return logProbs.map { _ in 1.0 / Double(logProbs.count) } }
        let exps = logProbs.map { exp($0 - maxLog) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    /// P(yes) = e^logYes / (e^logYes + e^logNo), computed stably.
    public static func probabilityYes(logYes: Double, logNo: Double) -> Double {
        if logYes == -.infinity { return 0 }
        if logNo == -.infinity { return 1 }
        let m = max(logYes, logNo)
        let yes = exp(logYes - m)
        let no = exp(logNo - m)
        return yes / (yes + no)
    }
}

private extension Dictionary where Key == String, Value == Double {
    static func + (lhs: [String: Double], rhs: [String: Double]) -> [String: Double] {
        var out = lhs
        for (k, v) in rhs { out[k] = v }
        return out
    }
}

extension DecisionSchema.Question {
    /// Stable string name for the question type, used in DecisionResult.type.
    public var typeName: String {
        switch type {
        case .choice: return "choice"
        case .score: return "score"
        case .boolean: return "boolean"
        case .probability: return "probability"
        case .noul: return "noul"
        case .ranking: return "ranking"
        case .structured: return "structured"
        }
    }
}
