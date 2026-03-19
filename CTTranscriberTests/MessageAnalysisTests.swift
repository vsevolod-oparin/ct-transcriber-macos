import XCTest
@testable import CT_Transcriber

final class MessageAnalysisTests: XCTestCase {

    func testShortMessage() {
        let a = MessageAnalysis(content: "Hello, world!")
        XCTAssertEqual(a.lineCount, 1)
        XCTAssertFalse(a.isLong)
        XCTAssertFalse(a.isError)
        XCTAssertFalse(a.hasTimestamps)
        XCTAssertTrue(a.collapsedPreview.isEmpty)
    }

    func testMultilineMessage() {
        let lines = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        let a = MessageAnalysis(content: lines)
        XCTAssertEqual(a.lineCount, 20)
        XCTAssertTrue(a.isLong)
        XCTAssertFalse(a.collapsedPreview.isEmpty)
        XCTAssertTrue(a.collapsedPreview.hasPrefix("Line 1\n"))
        XCTAssertTrue(a.collapsedPreview.hasSuffix("..."))
    }

    func testErrorDetection() {
        let a1 = MessageAnalysis(content: "⚠ [LLM] Something went wrong")
        XCTAssertTrue(a1.isError)

        let a2 = MessageAnalysis(content: "⚠ [Transcription] Failed")
        XCTAssertTrue(a2.isError)

        let a3 = MessageAnalysis(content: "Transcription cancelled.")
        XCTAssertTrue(a3.isError)

        let a4 = MessageAnalysis(content: "Normal message")
        XCTAssertFalse(a4.isError)
    }

    func testTimestampDetection() {
        let a1 = MessageAnalysis(content: "[0:00 → 0:05] Hello there")
        XCTAssertTrue(a1.hasTimestamps)

        let a2 = MessageAnalysis(content: "No timestamps here")
        XCTAssertFalse(a2.hasTimestamps)
    }

    func testEmptyContent() {
        let a = MessageAnalysis(content: "")
        // Empty string counts as 1 line (same as any text editor)
        XCTAssertEqual(a.lineCount, 1)
        XCTAssertFalse(a.isLong)
        XCTAssertFalse(a.isError)
        XCTAssertFalse(a.hasTimestamps)
    }

    func testLargeContent() {
        // Test with content larger than sampling threshold (4096 bytes)
        let longLine = String(repeating: "x", count: 100)
        let lines = (1...100).map { _ in longLine }.joined(separator: "\n")
        let a = MessageAnalysis(content: lines)
        XCTAssertTrue(a.lineCount > 50) // Estimated, not exact
        XCTAssertTrue(a.isLong)
    }

    func testUnicodeContent() {
        let emoji = "👨‍👩‍👧‍👦 Family emoji test\n第二行\n三行目\nFourth"
        let a = MessageAnalysis(content: emoji)
        XCTAssertEqual(a.lineCount, 4)
        XCTAssertFalse(a.isLong)
    }
}
