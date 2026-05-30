import XCTest

@testable import DS4Control

final class ChatMessageTests: XCTestCase {
    func testDefaults() {
        let message = ChatMessage(role: .user, content: "hi")
        XCTAssertEqual(message.role, .user)
        XCTAssertEqual(message.content, "hi")
        XCTAssertFalse(message.isStreaming)
    }

    func testUniqueIDs() {
        let a = ChatMessage(role: .assistant, content: "")
        let b = ChatMessage(role: .assistant, content: "")
        XCTAssertNotEqual(a.id, b.id)
    }

    func testStreamingFlag() {
        let message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        XCTAssertTrue(message.isStreaming)
    }

    func testEquatableByValue() {
        let id = UUID()
        let a = ChatMessage(id: id, role: .user, content: "x")
        let b = ChatMessage(id: id, role: .user, content: "x")
        XCTAssertEqual(a, b)
    }
}
