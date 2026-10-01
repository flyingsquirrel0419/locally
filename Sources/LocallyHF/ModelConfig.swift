import Foundation

/// Loose decoder for transformer config.json files. Fields are read
/// dynamically because architectures differ widely.
public struct ModelConfig: Sendable {
    public var raw: [String: JSONValue]

    public init(data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        self.raw = dict.mapValues(JSONValue.wrap)
    }

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public enum ConfigError: Error, Sendable {
        case notAnObject
    }

    public enum JSONValue: Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case array([JSONValue])
        case object([String: JSONValue])
        case null

        static func wrap(_ any: Any) -> JSONValue {
            switch any {
            case let s as String: return .string(s)
            case let b as Bool: return .bool(b)
            case let n as NSNumber: return .number(n.doubleValue)
            case let a as [Any]: return .array(a.map(wrap))
            case let o as [String: Any]: return .object(o.mapValues(wrap))
            default: return .null
            }
        }

        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var numberValue: Double? {
            if case .number(let n) = self { return n }
            return nil
        }

        public var intValue: Int? {
            numberValue.map(Int.init)
        }

        public var boolValue: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        public var objectValue: [String: JSONValue]? {
            if case .object(let o) = self { return o }
            return nil
        }

        public var arrayValue: [JSONValue]? {
            if case .array(let a) = self { return a }
            return nil
        }
    }

    public subscript(key: String) -> JSONValue? { raw[key] }

    /// First architecture name listed, e.g. "Qwen2ForCausalLM".
    public var architecture: String? {
        raw["architectures"]?.arrayValue?.first?.stringValue
    }

    public var modelType: String? { raw["model_type"]?.stringValue }

    /// max_position_embeddings, looking into nested text_config when present.
    public var maxPositionEmbeddings: Int? {
        raw["max_position_embeddings"]?.intValue
            ?? raw["text_config"]?.objectValue?["max_position_embeddings"]?.intValue
    }

    public var hasVisionConfig: Bool {
        raw["vision_config"]?.objectValue != nil
    }

    /// Config declares dynamic loading of repository code.
    public var requiresRemoteCode: Bool {
        if raw["auto_map"]?.objectValue != nil { return true }
        if let quantization = raw["quantization_config"]?.objectValue,
           quantization["quant_method"]?.stringValue == "custom" { return true }
        return false
    }

    /// Quantization declared by the config ("quantization" for MLX,
    /// "quantization_config" for bitsandbytes/GPTQ/AWQ style).
    public var declaredQuantization: (bits: Int, scheme: String?)? {
        if let group = raw["quantization"]?.objectValue,
           let bits = group["bits"]?.intValue {
            return (bits, group["group_size"]?.intValue.map { "group\($0)" })
        }
        if let qc = raw["quantization_config"]?.objectValue {
            if let bits = qc["bits"]?.intValue {
                return (bits, qc["quant_method"]?.stringValue ?? qc["load_in_\(bits)bit"]?.boolValue.map { _ in "bnb" } ?? nil)
            }
            if qc["load_in_4bit"]?.boolValue == true { return (4, "bnb") }
            if qc["load_in_8bit"]?.boolValue == true { return (8, "bnb") }
            if let method = qc["quant_method"]?.stringValue {
                return (4, method)
            }
        }
        return nil
    }
}
