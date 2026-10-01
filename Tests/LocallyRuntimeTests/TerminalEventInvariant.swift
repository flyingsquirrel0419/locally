import XCTest
import LocallyCore

/// Shared invariant for every runtime's event stream: exactly one terminal
/// event (`.completed` or `.failed`), it is the last event, and nothing
/// follows it. Streams that throw mid-iteration surface their error as a
/// synthetic `.failed` for the purpose of the check — a thrown error still
/// terminates the stream, so "exactly one terminal" holds end to end.
enum TerminalEventInvariant {

    /// Collect a whole stream (errors become a trailing `.failed`).
    static func collect(_ stream: AsyncThrowingStream<AIEvent, Error>,
                        file: StaticString = #filePath,
                        line: UInt = #line) async -> [AIEvent] {
        var events: [AIEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch let error as LocallyError {
            events.append(.failed(error))
        } catch {
            events.append(.failed(.unknown(userMessage: "stream threw",
                                           technicalDetail: "\(error)")))
        }
        return events
    }

    /// Assert the terminal-event invariant on an already-collected stream.
    static func assertExactlyOneTerminalEvent(
        _ events: [AIEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let terminalCount = events.filter(\.isTerminal).count
        XCTAssertEqual(terminalCount, 1,
                       "expected exactly one terminal event, got \(terminalCount) in \(events)",
                       file: file, line: line)
        if let last = events.last {
            XCTAssertTrue(last.isTerminal,
                          "last event must be terminal, got \(last)",
                          file: file, line: line)
        }
    }

    /// Collect and assert in one call.
    static func assertStream(_ stream: AsyncThrowingStream<AIEvent, Error>,
                             file: StaticString = #filePath,
                             line: UInt = #line) async -> [AIEvent] {
        let events = await collect(stream, file: file, line: line)
        assertExactlyOneTerminalEvent(events, file: file, line: line)
        return events
    }
}
