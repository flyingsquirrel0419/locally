import Foundation

/// Parses the YAML front-matter block of a README model card. Only the
/// simple flat mappings HF cards use (key: value, key: [a, b], and "- item"
/// lists); nested YAML is out of scope — nothing here is executed.
public struct CardFrontMatter: Sendable {
    public var values: [String: [String]]

    public init(markdown: String) {
        self.values = CardFrontMatter.parse(markdown)
    }

    public func first(_ key: String) -> String? { values[key]?.first }

    public var pipelineTag: String? { first("pipeline_tag") }
    public var libraryName: String? { first("library_name") }
    public var tags: [String] { values["tags"] ?? [] }
    public var license: String? { first("license") }

    private static func parse(_ markdown: String) -> [String: [String]] {
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var body: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            body.append(line)
        }

        var result: [String: [String]] = [:]
        var currentKey: String?
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // "- item" list entries (indented or at column 0 under a bare key)
            if trimmed.hasPrefix("- "), let key = currentKey {
                result[key, default: []].append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                currentKey = nil
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { currentKey = nil; continue }
            currentKey = key
            if value.isEmpty {
                result[key] = result[key] ?? []
            } else if value.hasPrefix("["), value.hasSuffix("]") {
                let inner = value.dropFirst().dropLast()
                result[key] = inner.split(separator: ",").map {
                    unquote(String($0).trimmingCharacters(in: .whitespaces))
                }.filter { !$0.isEmpty }
            } else {
                result[key] = [unquote(value)]
            }
        }
        return result
    }

    private static func unquote(_ s: String) -> String {
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")),
           s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
