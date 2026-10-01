import XCTest
@testable import LocallyRuntime

final class ChatSessionTests: XCTestCase {

    func testChatMLFallback() {
        let session = TextGenerationSession(
            systemPrompt: "Be terse.",
            turns: [
                ChatTurn(role: .user, content: "Hi"),
                ChatTurn(role: .assistant, content: "Hello"),
                ChatTurn(role: .user, content: "Bye"),
            ])
        XCTAssertEqual(session.renderChatML(), """
        <|im_start|>system
        Be terse.<|im_end|>
        <|im_start|>user
        Hi<|im_end|>
        <|im_start|>assistant
        Hello<|im_end|>
        <|im_start|>user
        Bye<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testRendersSmolLM2StyleTemplate() {
        // Shape of SmolLM2/Qwen2 GGUF tokenizer.chat_template.
        let template = """
        {% for message in messages %}{% if message['role'] == 'system' %}{% if true %}<|im_start|>system
        {{ message['content'] }}<|im_end|>
        {% endif %}{% else %}<|im_start|>{{ message['role'] }}
        {{ message['content'] }}<|im_end|>
        {% endif %}{% endfor %}{% if add_generation_prompt %}<|im_start|>assistant
        {% endif %}
        """
        let session = TextGenerationSession(
            systemPrompt: "You are helpful.",
            turns: [ChatTurn(role: .user, content: "2+2?")])
        guard let rendered = session.render(template: template) else {
            return XCTFail("renderer did not support the template")
        }
        XCTAssertTrue(rendered.contains("<|im_start|>user"))
        XCTAssertTrue(rendered.contains("2+2?"))
        XCTAssertTrue(rendered.hasSuffix("<|im_start|>assistant\n"))
    }

    func testUnsupportedTemplateReturnsNil() {
        let template = "{{ custom_function(messages) }}"
        let session = TextGenerationSession(turns: [ChatTurn(role: .user, content: "hi")])
        XCTAssertNil(session.render(template: template))
    }
}

#if canImport(CLlama) || canImport(llama)
final class PieceAssemblerTests: XCTestCase {
    func testSplitMultibyteCharacter() {
        var assembler = PieceAssembler()
        // "é" is 0xC3 0xA9 in UTF-8; split across two pieces.
        XCTAssertEqual(assembler.append([0xC3]), "")
        XCTAssertEqual(assembler.append([0xA9]), "")
        XCTAssertEqual(assembler.flush(), "é")
    }

    func testPlainASCIIStreamsImmediately() {
        // Aggregate check: appended + flushed == original
        var assembler = PieceAssembler()
        let streamed = assembler.append(Array("hello".utf8)) + assembler.flush()
        XCTAssertEqual(streamed, "hello")
    }
}
#endif
