import Foundation
import LocallyCore

/// A parsed and validated decision schema: a state description plus a set of
/// typed questions to answer about it.
///
/// Input shape:
/// ```json
/// {
///   "state": "...",
///   "questions": {
///     "refund": {"type": "noul", "instructions": "Should this be reviewed?"}
///   }
/// }
/// ```
public struct DecisionSchema: Sendable, Hashable {
    public var state: String
    /// Question order is preserved as declared in the input document.
    public var questions: [Question]

    public struct Question: Sendable, Hashable, Identifiable {
        public var key: String
        public var type: QuestionType
        public var instructions: String

        public var id: String { key }

        public init(key: String, type: QuestionType, instructions: String) {
            self.key = key
            self.type = type
            self.instructions = instructions
        }
    }

    /// A typed question with its constraints.
    public enum QuestionType: Sendable, Hashable {
        /// Pick one (or, with multi, several) of `options`.
        case choice(options: [String], multi: Bool)
        /// Numeric score in [min, max]; `integer` restricts to whole numbers.
        case score(min: Double, max: Double, integer: Bool)
        /// Yes/no answer.
        case boolean
        /// Calibrated probability of "yes" in [0, 1].
        case probability
        /// Calibrated probability of yes expressed as an ordinal label.
        /// Five levels by default, three when `levels == 3`. See
        /// `NoulScale.probability` for the label → probability mapping.
        case noul(levels: Int)
        /// Order `items` from most to least preferred.
        case ranking(items: [String])
        /// Free-form JSON validated against a JSON-Schema subset.
        case structured(JSONSchema)
    }

    public init(state: String, questions: [Question]) {
        self.state = state
        self.questions = questions
    }
}

/// The JSON-Schema subset the decision runtime accepts for `structured`
/// questions. Supported keywords: type (object/array/string/number/integer/
/// boolean/null), properties, required, enum, min/max (numeric bounds),
/// minLength/maxLength, minItems/maxItems, items. Anything else is rejected
/// explicitly at parse time.
public indirect enum JSONSchema: Sendable, Hashable {
    case object(properties: [String: JSONSchema], required: Set<String>)
    case array(items: JSONSchema, minItems: Int?, maxItems: Int?)
    case string(enumValues: [String]?, minLength: Int?, maxLength: Int?)
    case number(min: Double?, max: Double?)
    case integer(min: Int?, max: Int?)
    case boolean
    case null
    /// Any JSON value (only reachable via `{"type": "any"}`... not supported;
    /// kept for enum-completeness of parsed documents is NOT allowed — this
    /// case exists so `enum` constraints on mixed-type fields can be modeled.
    case enumeration([JSONValue])
}

/// Errors from parsing or validating decision input. `path` is a JSON-path
/// style locator into the input document (e.g. "questions.refund.type").
public struct DecisionSchemaError: Error, Sendable, Hashable, CustomStringConvertible {
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }

    public var userMessage: String {
        "The decision request is invalid — \(description)"
    }
}

/// Parses and validates decision schema documents.
public enum DecisionSchemaParser {
    /// Hard input limits: anything larger is rejected before parsing work.
    public static let maxDocumentBytes = 64 * 1024
    public static let maxQuestions = 64
    public static let maxOptions = 64
    public static let maxItems = 64
    public static let maxStateLength = 16 * 1024
    public static let maxInstructionsLength = 4 * 1024
    public static let maxSchemaDepth = 8
    public static let maxSchemaProperties = 64
    public static let maxEnumValues = 256
    public static let maxKeyLength = 128

    /// Parse from raw JSON data (the transport form).
    public static func parse(data: Data) throws -> DecisionSchema {
        guard data.count <= maxDocumentBytes else {
            throw DecisionSchemaError(path: "$", message: "document is \(data.count) bytes; limit is \(maxDocumentBytes)")
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw DecisionSchemaError(path: "$", message: "document is not valid JSON")
        }
        return try parse(value)
    }

    /// Parse from an already-decoded JSONValue.
    public static func parse(_ value: JSONValue) throws -> DecisionSchema {
        guard case .object(let root) = value else {
            throw DecisionSchemaError(path: "$", message: "root must be an object")
        }
        guard let stateValue = root["state"], case .string(let state) = stateValue else {
            throw DecisionSchemaError(path: "state", message: "missing or not a string")
        }
        guard state.count <= maxStateLength else {
            throw DecisionSchemaError(path: "state", message: "state is \(state.count) characters; limit is \(maxStateLength)")
        }
        guard let questionsValue = root["questions"], case .object(let questionsObject) = questionsValue else {
            throw DecisionSchemaError(path: "questions", message: "missing or not an object")
        }
        guard !questionsObject.isEmpty else {
            throw DecisionSchemaError(path: "questions", message: "must contain at least one question")
        }
        guard questionsObject.count <= maxQuestions else {
            throw DecisionSchemaError(path: "questions", message: "\(questionsObject.count) questions; limit is \(maxQuestions)")
        }

        var questions: [DecisionSchema.Question] = []
        // JSON objects decode into dictionaries (unordered); sort keys so the
        // engine is deterministic regardless of decoder behavior.
        for key in questionsObject.keys.sorted() {
            guard key.count <= maxKeyLength else {
                throw DecisionSchemaError(path: "questions", message: "question key exceeds \(maxKeyLength) characters")
            }
            let questionValue = questionsObject[key]!
            let path = "questions.\(key)"
            guard case .object(let qobj) = questionValue else {
                throw DecisionSchemaError(path: path, message: "question must be an object")
            }
            guard let typeValue = qobj["type"], case .string(let typeName) = typeValue else {
                throw DecisionSchemaError(path: "\(path).type", message: "missing or not a string")
            }
            let instructions: String
            if let iv = qobj["instructions"] {
                guard case .string(let s) = iv else {
                    throw DecisionSchemaError(path: "\(path).instructions", message: "must be a string")
                }
                instructions = s
            } else {
                instructions = ""
            }
            guard instructions.count <= maxInstructionsLength else {
                throw DecisionSchemaError(path: "\(path).instructions",
                                          message: "instructions exceed \(maxInstructionsLength) characters")
            }
            let type = try parseType(typeName, object: qobj, path: path)
            questions.append(DecisionSchema.Question(key: key, type: type, instructions: instructions))
        }
        return DecisionSchema(state: state, questions: questions)
    }

    private static func parseType(_ name: String, object qobj: [String: JSONValue],
                                  path: String) throws -> DecisionSchema.QuestionType {
        switch name {
        case "choice":
            guard let optionsValue = qobj["options"], case .array(let optionValues) = optionsValue else {
                throw DecisionSchemaError(path: "\(path).options", message: "choice requires an options array")
            }
            guard optionValues.count >= 2 else {
                throw DecisionSchemaError(path: "\(path).options", message: "choice requires at least 2 options")
            }
            guard optionValues.count <= maxOptions else {
                throw DecisionSchemaError(path: "\(path).options", message: "\(optionValues.count) options; limit is \(maxOptions)")
            }
            var options: [String] = []
            for (index, optionValue) in optionValues.enumerated() {
                guard case .string(let option) = optionValue else {
                    throw DecisionSchemaError(path: "\(path).options[\(index)]", message: "option must be a string")
                }
                options.append(option)
            }
            if Set(options).count != options.count {
                throw DecisionSchemaError(path: "\(path).options", message: "options must be unique")
            }
            var multi = false
            if let multiValue = qobj["multi"] {
                guard case .bool(let b) = multiValue else {
                    throw DecisionSchemaError(path: "\(path).multi", message: "must be a boolean")
                }
                multi = b
            }
            return .choice(options: options, multi: multi)

        case "score":
            guard let minValue = qobj["min"], case .number(let min) = minValue else {
                throw DecisionSchemaError(path: "\(path).min", message: "score requires a numeric min")
            }
            guard let maxValue = qobj["max"], case .number(let max) = maxValue else {
                throw DecisionSchemaError(path: "\(path).max", message: "score requires a numeric max")
            }
            guard min.isFinite, max.isFinite, min < max else {
                throw DecisionSchemaError(path: "\(path).min", message: "require finite min < max")
            }
            var integer = false
            if let integerValue = qobj["integer"] {
                guard case .bool(let b) = integerValue else {
                    throw DecisionSchemaError(path: "\(path).integer", message: "must be a boolean")
                }
                integer = b
            }
            if integer {
                guard min == min.rounded() && max == max.rounded() else {
                    throw DecisionSchemaError(path: "\(path).min", message: "integer score requires whole-number min/max")
                }
                guard max - min <= 1000 else {
                    throw DecisionSchemaError(path: "\(path).max", message: "integer score range is too wide to enumerate (> 1000 steps)")
                }
            }
            return .score(min: min, max: max, integer: integer)

        case "boolean":
            return .boolean

        case "probability":
            return .probability

        case "noul":
            var levels = 5
            if let levelsValue = qobj["levels"] {
                guard case .number(let n) = levelsValue, n == n.rounded() else {
                    throw DecisionSchemaError(path: "\(path).levels", message: "must be an integer")
                }
                levels = Int(n)
            }
            guard levels == 3 || levels == 5 else {
                throw DecisionSchemaError(path: "\(path).levels", message: "noul supports 3 or 5 levels, got \(levels)")
            }
            return .noul(levels: levels)

        case "ranking":
            guard let itemsValue = qobj["items"], case .array(let itemValues) = itemsValue else {
                throw DecisionSchemaError(path: "\(path).items", message: "ranking requires an items array")
            }
            guard itemValues.count >= 2 else {
                throw DecisionSchemaError(path: "\(path).items", message: "ranking requires at least 2 items")
            }
            guard itemValues.count <= maxItems else {
                throw DecisionSchemaError(path: "\(path).items", message: "\(itemValues.count) items; limit is \(maxItems)")
            }
            var items: [String] = []
            for (index, itemValue) in itemValues.enumerated() {
                guard case .string(let item) = itemValue else {
                    throw DecisionSchemaError(path: "\(path).items[\(index)]", message: "item must be a string")
                }
                items.append(item)
            }
            if Set(items).count != items.count {
                throw DecisionSchemaError(path: "\(path).items", message: "items must be unique")
            }
            return .ranking(items: items)

        case "structured":
            guard let schemaValue = qobj["schema"] else {
                throw DecisionSchemaError(path: "\(path).schema", message: "structured requires a schema object")
            }
            let schema = try parseJSONSchema(schemaValue, path: "\(path).schema", depth: 0)
            return .structured(schema)

        default:
            throw DecisionSchemaError(path: "\(path).type", message: "unknown type '\(name)'")
        }
    }

    /// Supported JSON-Schema keywords per node. Anything else is rejected.
    private static let supportedKeywords: Set<String> = [
        "type", "properties", "required", "enum",
        "min", "max", "minimum", "maximum",
        "minLength", "maxLength", "minItems", "maxItems", "items",
    ]

    private static func parseJSONSchema(_ value: JSONValue, path: String, depth: Int) throws -> JSONSchema {
        guard depth <= maxSchemaDepth else {
            throw DecisionSchemaError(path: path, message: "schema nesting exceeds \(maxSchemaDepth) levels")
        }
        guard case .object(let object) = value else {
            throw DecisionSchemaError(path: path, message: "schema node must be an object")
        }
        for key in object.keys {
            if !supportedKeywords.contains(key) {
                throw DecisionSchemaError(path: "\(path).\(key)", message: "unsupported schema keyword '\(key)'")
            }
        }

        // `enum` is valid on any node and overrides the type constraint.
        var enumValues: [JSONValue]?
        if let enumValue = object["enum"] {
            guard case .array(let values) = enumValue, !values.isEmpty else {
                throw DecisionSchemaError(path: "\(path).enum", message: "enum must be a non-empty array")
            }
            guard values.count <= maxEnumValues else {
                throw DecisionSchemaError(path: "\(path).enum", message: "\(values.count) values; limit is \(maxEnumValues)")
            }
            enumValues = values
        }

        guard let typeValue = object["type"], case .string(let typeName) = typeValue else {
            throw DecisionSchemaError(path: "\(path).type", message: "schema node requires a type string")
        }

        switch typeName {
        case "object":
            var properties: [String: JSONSchema] = [:]
            if let propertiesValue = object["properties"] {
                guard case .object(let propertyObjects) = propertiesValue else {
                    throw DecisionSchemaError(path: "\(path).properties", message: "must be an object")
                }
                guard propertyObjects.count <= maxSchemaProperties else {
                    throw DecisionSchemaError(path: "\(path).properties",
                                              message: "\(propertyObjects.count) properties; limit is \(maxSchemaProperties)")
                }
                for (propertyKey, propertyValue) in propertyObjects {
                    properties[propertyKey] = try parseJSONSchema(
                        propertyValue, path: "\(path).properties.\(propertyKey)", depth: depth + 1)
                }
            }
            var required: Set<String> = []
            if let requiredValue = object["required"] {
                guard case .array(let requiredValues) = requiredValue else {
                    throw DecisionSchemaError(path: "\(path).required", message: "must be an array of property names")
                }
                for requiredItem in requiredValues {
                    guard case .string(let name) = requiredItem else {
                        throw DecisionSchemaError(path: "\(path).required", message: "entries must be strings")
                    }
                    guard properties[name] != nil else {
                        throw DecisionSchemaError(path: "\(path).required",
                                                  message: "'\(name)' is not a declared property")
                    }
                    required.insert(name)
                }
            }
            if let enumValues { return .enumeration(enumValues) }
            return .object(properties: properties, required: required)

        case "array":
            guard let itemsValue = object["items"] else {
                throw DecisionSchemaError(path: "\(path).items", message: "array schema requires items")
            }
            let items = try parseJSONSchema(itemsValue, path: "\(path).items", depth: depth + 1)
            let minItems = try optionalInt(object["minItems"], path: "\(path).minItems")
            let maxItems = try optionalInt(object["maxItems"], path: "\(path).maxItems")
            if let enumValues { return .enumeration(enumValues) }
            return .array(items: items, minItems: minItems, maxItems: maxItems)

        case "string":
            let minLength = try optionalInt(object["minLength"], path: "\(path).minLength")
            let maxLength = try optionalInt(object["maxLength"], path: "\(path).maxLength")
            if let enumValues {
                var strings: [String] = []
                for (index, enumItem) in enumValues.enumerated() {
                    guard case .string(let s) = enumItem else {
                        throw DecisionSchemaError(path: "\(path).enum[\(index)]",
                                                  message: "string enum values must be strings")
                    }
                    strings.append(s)
                }
                return .string(enumValues: strings, minLength: minLength, maxLength: maxLength)
            }
            return .string(enumValues: nil, minLength: minLength, maxLength: maxLength)

        case "number":
            let min = try optionalNumber(object["min"] ?? object["minimum"], path: "\(path).min")
            let max = try optionalNumber(object["max"] ?? object["maximum"], path: "\(path).max")
            if let min, let max, min > max {
                throw DecisionSchemaError(path: "\(path).min", message: "min exceeds max")
            }
            if let enumValues { return .enumeration(enumValues) }
            return .number(min: min, max: max)

        case "integer":
            let minD = try optionalNumber(object["min"] ?? object["minimum"], path: "\(path).min")
            let maxD = try optionalNumber(object["max"] ?? object["maximum"], path: "\(path).max")
            if let minD, minD != minD.rounded() {
                throw DecisionSchemaError(path: "\(path).min", message: "integer min must be a whole number")
            }
            if let maxD, maxD != maxD.rounded() {
                throw DecisionSchemaError(path: "\(path).max", message: "integer max must be a whole number")
            }
            if let minD, let maxD, minD > maxD {
                throw DecisionSchemaError(path: "\(path).min", message: "min exceeds max")
            }
            if let enumValues { return .enumeration(enumValues) }
            return .integer(min: minD.map(Int.init), max: maxD.map(Int.init))

        case "boolean":
            if let enumValues { return .enumeration(enumValues) }
            return .boolean

        case "null":
            if let enumValues { return .enumeration(enumValues) }
            return .null

        default:
            throw DecisionSchemaError(path: "\(path).type", message: "unsupported schema type '\(typeName)'")
        }
    }

    private static func optionalInt(_ value: JSONValue?, path: String) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let n) = value, n == n.rounded(), n >= 0 else {
            throw DecisionSchemaError(path: path, message: "must be a non-negative integer")
        }
        return Int(n)
    }

    private static func optionalNumber(_ value: JSONValue?, path: String) throws -> Double? {
        guard let value else { return nil }
        guard case .number(let n) = value, n.isFinite else {
            throw DecisionSchemaError(path: path, message: "must be a finite number")
        }
        return n
    }
}

/// The "noul" ordinal scale: a calibrated probability of yes expressed with a
/// label. Five-level form: no / unlikely / unsure / likely / yes. Three-level
/// form: no / unsure / yes. Each label maps to the center probability of its
/// band, which is what `probability(of:)` returns and what scored backends
/// calibrate against.
public enum NoulScale {
    public static func labels(levels: Int) -> [String] {
        switch levels {
        case 3: return ["no", "unsure", "yes"]
        default: return ["no", "unlikely", "unsure", "likely", "yes"]
        }
    }

    /// Band-center probability for a label. Bands partition [0, 1] evenly;
    /// the label's probability is its band midpoint (3 levels: 1/6, 1/2, 5/6;
    /// 5 levels: 0.1, 0.3, 0.5, 0.7, 0.9).
    public static func probability(of label: String, levels: Int) -> Double? {
        let labels = labels(levels: levels)
        guard let index = labels.firstIndex(of: label.lowercased()) else { return nil }
        return (Double(index) + 0.5) / Double(labels.count)
    }

    /// The label whose band contains `probability`.
    public static func label(for probability: Double, levels: Int) -> String {
        let labels = labels(levels: levels)
        let clamped = min(max(probability, 0), 1)
        var index = Int(clamped * Double(labels.count))
        if index >= labels.count { index = labels.count - 1 }
        return labels[index]
    }
}
