import XCTest
@testable import CT_Transcriber

final class LLMErrorTests: XCTestCase {

    func testIsCancelled() {
        XCTAssertTrue(LLMError.cancelled.isCancelled)
        XCTAssertFalse(LLMError.noAPIKey.isCancelled)
        XCTAssertFalse(LLMError.invalidURL.isCancelled)
        XCTAssertFalse(LLMError.httpError(statusCode: 401, body: "Unauthorized").isCancelled)
        XCTAssertFalse(LLMError.decodingError("bad json").isCancelled)
        XCTAssertFalse(LLMError.networkError(URLError(.timedOut)).isCancelled)
    }

    func testErrorDescriptions() {
        XCTAssertNotNil(LLMError.noAPIKey.errorDescription)
        XCTAssertNotNil(LLMError.invalidURL.errorDescription)
        XCTAssertNotNil(LLMError.cancelled.errorDescription)
        XCTAssertTrue(LLMError.httpError(statusCode: 500, body: "error").errorDescription!.contains("500"))
    }
}

final class TranscriptionErrorTests: XCTestCase {

    func testIsCancelled() {
        XCTAssertTrue(TranscriptionError.cancelled.isCancelled)
        XCTAssertFalse(TranscriptionError.environmentNotReady.isCancelled)
        XCTAssertFalse(TranscriptionError.scriptNotFound.isCancelled)
        XCTAssertFalse(TranscriptionError.modelNotDownloaded.isCancelled)
        XCTAssertFalse(TranscriptionError.transcriptionFailed("err").isCancelled)
    }
}
