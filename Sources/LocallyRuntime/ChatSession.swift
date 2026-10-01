import Foundation
import LocallyCore

/// One turn in a text conversation. Shared by all text runtimes
/// (GGUF/llama.cpp today, MLX in a later week).
public struct ChatTurn: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable, Hashable {
        case system, user, assistant
    }
    public var id: UUID
    public var role: Role
    public var content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

/// Chat state plus the rendered prompt, shared between text runtimes.
public struct TextGenerationSession: Sendable {
    public var systemPrompt: String?
    public var turns: [ChatTurn]

    public init(systemPrompt: String? = nil, turns: [ChatTurn] = []) {
        self.systemPrompt = systemPrompt
        self.turns = turns
    }

    /// Render the conversation with a Jinja-style chat template. Handles the
    /// ChatML family (used by SmolLM2, Qwen, Mistral-Instruct and most
    /// instruct GGUFs). Returns nil for template features this renderer does
    /// not support, so callers can fall back to a built-in template.
    public func render(template: String?, addAssistantPrompt: Bool = true) -> String? {
        guard let template = template else { return nil }
        return ChatTemplate.render(template: template, systemPrompt: systemPrompt,
                                   turns: turns, addAssistantPrompt: addAssistantPrompt)
    }

    /// ChatML fallback when a model ships no usable template.
    public func renderChatML(addAssistantPrompt: Bool = true) -> String {
        var out = ""
        if let systemPrompt, !systemPrompt.isEmpty {
            out += "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        }
        for turn in turns {
            out += "<|im_start|>\(turn.role.rawValue)\n\(turn.content)<|im_end|>\n"
        }
        if addAssistantPrompt { out += "<|im_start|>assistant\n" }
        return out
    }
}

/// Minimal renderer for the common Jinja chat-template subset. Not a general
/// Jinja engine: supports `messages` loops, role/content access, `if`
/// conditions over `add_generation_prompt` and message fields, and string
/// literals. Anything outside that subset renders as nil so the caller falls
/// back to ChatML.
enum ChatTemplate {
    static func render(template: String, systemPrompt: String?,
                       turns: [ChatTurn], addAssistantPrompt: Bool) -> String? {
        // Supported shapes (SmolLM2/Qwen2/Mistral style):
        //   ... {% for message in messages %} ... {% endfor %}
        // with message.role / message.content / message['role'] access and
        // simple {% if ... %} blocks. Detect the loop; bail otherwise.
        guard let forRange = template.range(of: "{% for message in messages %}"),
              let endforRange = template.range(of: "{% endfor %}", range: forRange.upperBound..<template.endIndex)
        else { return nil }

        var messages = turns
        if let systemPrompt, !systemPrompt.isEmpty,
           !messages.contains(where: { $0.role == .system }) {
            messages.insert(ChatTurn(role: .system, content: systemPrompt), at: 0)
        }

        // Prologue: text before the loop; may reference bos_token and an
        // initial system block guarded by {% if messages[0]['role'] == 'system' %}
        let prologue = String(template[template.startIndex..<forRange.lowerBound])
        let loopBody = String(template[forRange.upperBound..<endforRange.lowerBound])
        let epilogue = String(template[endforRange.upperBound..<template.endIndex])

        var out = prologue.replacingOccurrences(of: "{{ bos_token }}", with: "")
        out = stripJinjaConditionals(out, messages: messages,
                                     addAssistantPrompt: addAssistantPrompt)
        for message in messages {
            var chunk = loopBody
            chunk = stripLoopConditionals(chunk, message: message)
            chunk = chunk.replacingOccurrences(of: "{{ message.content }}", with: message.content)
            chunk = chunk.replacingOccurrences(of: "{{ message['content'] }}", with: message.content)
            chunk = chunk.replacingOccurrences(of: "{{ message.role }}", with: message.role.rawValue)
            chunk = chunk.replacingOccurrences(of: "{{ message['role'] }}", with: message.role.rawValue)
            chunk = chunk.replacingOccurrences(of: "{% endif %}", with: "")
            chunk = chunk.replacingOccurrences(of: "{% if true %}", with: "")
            if chunk.contains("{{") || chunk.contains("{%") { return nil }
            out += chunk
        }
        var tail = epilogue.replacingOccurrences(of: "{{ bos_token }}", with: "")
        tail = stripJinjaConditionals(tail, messages: messages,
                                      addAssistantPrompt: addAssistantPrompt)
        if tail.contains("{{") { return nil }
        out += tail
        return out
    }

    /// Evaluate `{% if cond %}a{% else %}b{% endif %}` blocks outside the
    /// message loop. Supported conditions: `add_generation_prompt`,
    /// `messages[0]['role'] == 'system'` (and != variant).
    private static func stripJinjaConditionals(_ text: String, messages: [ChatTurn],
                                               addAssistantPrompt: Bool) -> String {
        var result = text
        while let ifStart = result.range(of: "{% if ") {
            guard let condEnd = result.range(of: "%}", range: ifStart.upperBound..<result.endIndex) else { break }
            let condition = String(result[ifStart.upperBound..<condEnd.lowerBound])
            // Find the endif that closes THIS if, skipping nested if blocks.
            var depth = 1
            var cursor = condEnd.upperBound
            var endifRange: Range<String.Index>?
            var elseRange: Range<String.Index>?
            while depth > 0 {
                guard let nextTag = result.range(of: "{%", range: cursor..<result.endIndex),
                      let tagEnd = result.range(of: "%}", range: nextTag.upperBound..<result.endIndex) else { break }
                let tag = result[nextTag.upperBound..<tagEnd.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if tag.hasPrefix("if ") { depth += 1 }
                if tag == "endif" {
                    depth -= 1
                    if depth == 0 { endifRange = nextTag.lowerBound..<tagEnd.upperBound }
                }
                if tag == "else", depth == 1, elseRange == nil {
                    elseRange = nextTag.lowerBound..<tagEnd.upperBound
                }
                cursor = tagEnd.upperBound
            }
            guard let endifRange else { break }
            let truthy = evaluate(condition: condition, messages: messages,
                                  addAssistantPrompt: addAssistantPrompt)
            let chosen: Substring
            if let elseRange {
                chosen = truthy ? result[condEnd.upperBound..<elseRange.lowerBound]
                                : result[elseRange.upperBound..<endifRange.lowerBound]
            } else {
                chosen = truthy ? result[condEnd.upperBound..<endifRange.lowerBound] : ""
            }
            result.replaceSubrange(ifStart.lowerBound..<endifRange.upperBound, with: String(chosen))
        }
        return result
    }

    private static func stripLoopConditionals(_ text: String, message: ChatTurn) -> String {
        var result = text
        while let ifStart = result.range(of: "{% if ") {
            guard let condEnd = result.range(of: "%}", range: ifStart.upperBound..<result.endIndex) else { break }
            let condition = String(result[ifStart.upperBound..<condEnd.lowerBound])
            var depth = 1
            var cursor = condEnd.upperBound
            var endifRange: Range<String.Index>?
            var elseRange: Range<String.Index>?
            while depth > 0 {
                guard let nextTag = result.range(of: "{%", range: cursor..<result.endIndex),
                      let tagEnd = result.range(of: "%}", range: nextTag.upperBound..<result.endIndex) else { break }
                let tag = result[nextTag.upperBound..<tagEnd.lowerBound]
                    .trimmingCharacters(in: .whitespaces)
                if tag.hasPrefix("if ") { depth += 1 }
                if tag == "endif" {
                    depth -= 1
                    if depth == 0 { endifRange = nextTag.lowerBound..<tagEnd.upperBound }
                }
                if tag == "else", depth == 1, elseRange == nil {
                    elseRange = nextTag.lowerBound..<tagEnd.upperBound
                }
                cursor = tagEnd.upperBound
            }
            guard let endifRange else { break }
            let truthy = evaluateMessageCondition(condition, message: message)
            let chosen: Substring
            if let elseRange {
                chosen = truthy ? result[condEnd.upperBound..<elseRange.lowerBound]
                                : result[elseRange.upperBound..<endifRange.lowerBound]
            } else {
                chosen = truthy ? result[condEnd.upperBound..<endifRange.lowerBound] : ""
            }
            result.replaceSubrange(ifStart.lowerBound..<endifRange.upperBound, with: String(chosen))
        }
        return result
    }

    private static func evaluate(condition: String, messages: [ChatTurn],
                                 addAssistantPrompt: Bool) -> Bool {
        let c = condition.trimmingCharacters(in: .whitespaces)
        if c == "add_generation_prompt" { return addAssistantPrompt }
        if c.contains("messages[0]['role']") || c.contains("messages[0].role") {
            let firstIsSystem = messages.first?.role == .system
            if c.contains("== 'system'") { return firstIsSystem }
            if c.contains("!= 'system'") { return !firstIsSystem }
        }
        return false
    }

    private static func evaluateMessageCondition(_ condition: String, message: ChatTurn) -> Bool {
        let c = condition.trimmingCharacters(in: .whitespaces)
        if c == "true" || c == "message['content']" || c == "message.content" { return true }
        for role in ["system", "user", "assistant", "tool"] {
            if c == "message['role'] == '\(role)'" || c == "message.role == '\(role)'" {
                return message.role.rawValue == role
            }
            if c == "message['role'] != '\(role)'" || c == "message.role != '\(role)'" {
                return message.role.rawValue != role
            }
        }
        return false
    }
}
