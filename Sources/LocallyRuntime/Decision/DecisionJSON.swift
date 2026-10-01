import Foundation
import LocallyCore

/// Extracts the first balanced top-level JSON object from model output.
/// Handles nested braces, braces inside string literals, and markdown code
/// fences. Returns nil when no balanced object exists.
public enum JSONExtractor {
    public static func firstObject(in text: String) -> String? {
        // Prefer the contents of a fenced ```json block when present.
        if let fenced = fencedBlock(in: text), balanced(in: fenced) != nil {
            return balanced(in: fenced)
        }
        return balanced(in: text)
    }

    /// Extract the payload of the first ``` fence, if any.
    static func fencedBlock(in text: String) -> String? {
        guard let openRange = text.range(of: "```") else { return nil }
        var rest = text[openRange.upperBound...]
        // Drop an optional language tag line (```json).
        if let newline = rest.firstIndex(of: "\n") {
            let tag = rest[rest.startIndex..<newline].trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, !tag.contains("{") {
                rest = rest[rest.index(after: newline)...]
            }
        }
        guard let closeRange = rest.range(of: "```") else {
            return String(rest)
        }
        return String(rest[rest.startIndex..<closeRange.lowerBound])
    }

    /// Find the first `{...}` span that balances, skipping braces inside
    /// string literals (which may be escaped).
    static func balanced(in text: String) -> String? {
        let scalars = Array(text)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false

        for (index, char) in scalars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                if start != nil { inString = true }
            case "{":
                if start == nil { start = index }
                depth += 1
            case "}":
                if start != nil {
                    depth -= 1
                    if depth == 0 {
                        return String(scalars[start!...index])
                    }
                }
            default:
                break
            }
        }
        return nil
    }

    /// Extract and decode the first balanced JSON object in `text`.
    public static func decodeFirstObject(in text: String) -> JSONValue? {
        guard let raw = firstObject(in: text), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// Validates decoded JSON output against a question's expected shape.
/// Every failure carries a path into the OUTPUT document.
public enum DecisionOutputValidator {
    public struct ValidationFailure: Error, Sendable, Hashable, CustomStringConvertible {
        public var path: String
        public var message: String
        public var description: String { "output.\(path): \(message)" }
    }

    /// Validate `value` as the answer to `question`. On success returns the
    /// normalized JSONValue for the result.
    public static func validate(_ value: JSONValue,
                                for question: DecisionSchema.Question) throws -> JSONValue {
        switch question.type {
        case .choice(let options, let multi):
            if multi {
                guard case .array(let values) = value else {
                    throw ValidationFailure(path: question.key, message: "expected an array of options")
                }
                guard !values.isEmpty else {
                    throw ValidationFailure(path: question.key, message: "expected at least one option")
                }
                var out: [JSONValue] = []
                for (index, item) in values.enumerated() {
                    guard case .string(let s) = item, options.contains(s) else {
                        throw ValidationFailure(path: "\(question.key)[\(index)]",
                                                message: "expected one of \(options.joined(separator: ", "))")
                    }
                    out.append(.string(s))
                }
                return .array(out)
            }
            guard case .string(let s) = value, options.contains(s) else {
                throw ValidationFailure(path: question.key,
                                        message: "expected one of \(options.joined(separator: ", "))")
            }
            return .string(s)

        case .score(let min, let max, let integer):
            guard case .number(let n) = value, n.isFinite else {
                throw ValidationFailure(path: question.key, message: "expected a number")
            }
            if integer && n != n.rounded() {
                throw ValidationFailure(path: question.key, message: "expected a whole number")
            }
            guard n >= min && n <= max else {
                throw ValidationFailure(path: question.key, message: "expected a value in [\(min), \(max)]")
            }
            return .number(n)

        case .boolean:
            guard case .bool = value else { throw ValidationFailure(path: question.key, message: "expected true or false") }
            return value

        case .probability:
            guard case .number(let n) = value, n.isFinite, n >= 0, n <= 1 else {
                throw ValidationFailure(path: question.key, message: "expected a number in [0, 1]")
            }
            return .number(n)

        case .noul(let levels):
            guard case .string(let s) = value,
                  NoulScale.labels(levels: levels).contains(s.lowercased()) else {
                throw ValidationFailure(path: question.key,
                                        message: "expected one of \(NoulScale.labels(levels: levels).joined(separator: ", "))")
            }
            return .string(s.lowercased())

        case .ranking(let items):
            guard case .array(let values) = value else {
                throw ValidationFailure(path: question.key, message: "expected an array of items")
            }
            var seen: [String] = []
            for (index, item) in values.enumerated() {
                guard case .string(let s) = item, items.contains(s) else {
                    throw ValidationFailure(path: "\(question.key)[\(index)]",
                                            message: "expected one of \(items.joined(separator: ", "))")
                }
                seen.append(s)
            }
            guard Set(seen).count == seen.count, seen.count == items.count else {
                throw ValidationFailure(path: question.key,
                                        message: "expected each item exactly once")
            }
            return .array(seen.map { .string($0) })

        case .structured(let schema):
            try validateAgainstSchema(value, schema: schema, path: question.key)
            return value
        }
    }

    static func validateAgainstSchema(_ value: JSONValue, schema: JSONSchema, path: String) throws {
        switch schema {
        case .enumeration(let allowed):
            guard allowed.contains(value) else {
                throw ValidationFailure(path: path, message: "value is not in the allowed set")
            }
        case .object(let properties, let required):
            guard case .object(let object) = value else {
                throw ValidationFailure(path: path, message: "expected an object")
            }
            for name in required where object[name] == nil {
                throw ValidationFailure(path: path, message: "missing required property '\(name)'")
            }
            for (name, propertySchema) in properties {
                if let propertyValue = object[name] {
                    try validateAgainstSchema(propertyValue, schema: propertySchema, path: "\(path).\(name)")
                }
            }
        case .array(let items, let minItems, let maxItems):
            guard case .array(let values) = value else {
                throw ValidationFailure(path: path, message: "expected an array")
            }
            if let minItems, values.count < minItems {
                throw ValidationFailure(path: path, message: "expected at least \(minItems) items")
            }
            if let maxItems, values.count > maxItems {
                throw ValidationFailure(path: path, message: "expected at most \(maxItems) items")
            }
            for (index, item) in values.enumerated() {
                try validateAgainstSchema(item, schema: items, path: "\(path)[\(index)]")
            }
        case .string(let enumValues, let minLength, let maxLength):
            guard case .string(let s) = value else {
                throw ValidationFailure(path: path, message: "expected a string")
            }
            if let enumValues, !enumValues.contains(s) {
                throw ValidationFailure(path: path, message: "expected one of \(enumValues.joined(separator: ", "))")
            }
            if let minLength, s.count < minLength {
                throw ValidationFailure(path: path, message: "string shorter than \(minLength) characters")
            }
            if let maxLength, s.count > maxLength {
                throw ValidationFailure(path: path, message: "string longer than \(maxLength) characters")
            }
        case .number(let min, let max):
            guard case .number(let n) = value, n.isFinite else {
                throw ValidationFailure(path: path, message: "expected a number")
            }
            if let min, n < min { throw ValidationFailure(path: path, message: "below minimum \(min)") }
            if let max, n > max { throw ValidationFailure(path: path, message: "above maximum \(max)") }
        case .integer(let min, let max):
            guard case .number(let n) = value, n.isFinite, n == n.rounded() else {
                throw ValidationFailure(path: path, message: "expected an integer")
            }
            if let min, n < Double(min) { throw ValidationFailure(path: path, message: "below minimum \(min)") }
            if let max, n > Double(max) { throw ValidationFailure(path: path, message: "above maximum \(max)") }
        case .boolean:
            guard case .bool = value else {
                throw ValidationFailure(path: path, message: "expected true or false")
            }
        case .null:
            guard case .null = value else {
                throw ValidationFailure(path: path, message: "expected null")
            }
        }
    }
}
