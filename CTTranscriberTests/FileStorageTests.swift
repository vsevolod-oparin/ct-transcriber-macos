import XCTest
@testable import CT_Transcriber

final class FileStorageTests: XCTestCase {

    func testAttachmentKindAudio() {
        let mp3 = URL(fileURLWithPath: "/tmp/test.mp3")
        XCTAssertEqual(FileStorage.attachmentKind(for: mp3), .audio)

        let m4a = URL(fileURLWithPath: "/tmp/test.m4a")
        XCTAssertEqual(FileStorage.attachmentKind(for: m4a), .audio)

        let wav = URL(fileURLWithPath: "/tmp/test.wav")
        XCTAssertEqual(FileStorage.attachmentKind(for: wav), .audio)

        let ogg = URL(fileURLWithPath: "/tmp/test.ogg")
        XCTAssertEqual(FileStorage.attachmentKind(for: ogg), .audio)

        let opus = URL(fileURLWithPath: "/tmp/test.opus")
        XCTAssertEqual(FileStorage.attachmentKind(for: opus), .audio)
    }

    func testAttachmentKindVideo() {
        let mp4 = URL(fileURLWithPath: "/tmp/test.mp4")
        XCTAssertEqual(FileStorage.attachmentKind(for: mp4), .video)

        let webm = URL(fileURLWithPath: "/tmp/test.webm")
        XCTAssertEqual(FileStorage.attachmentKind(for: webm), .video)

        let mkv = URL(fileURLWithPath: "/tmp/test.mkv")
        XCTAssertEqual(FileStorage.attachmentKind(for: mkv), .video)

        let mov = URL(fileURLWithPath: "/tmp/test.mov")
        XCTAssertEqual(FileStorage.attachmentKind(for: mov), .video)
    }

    func testAttachmentKindImage() {
        let png = URL(fileURLWithPath: "/tmp/test.png")
        XCTAssertEqual(FileStorage.attachmentKind(for: png), .image)

        let jpg = URL(fileURLWithPath: "/tmp/test.jpg")
        XCTAssertEqual(FileStorage.attachmentKind(for: jpg), .image)
    }

    func testAttachmentKindText() {
        let txt = URL(fileURLWithPath: "/tmp/test.txt")
        XCTAssertEqual(FileStorage.attachmentKind(for: txt), .text)

        let py = URL(fileURLWithPath: "/tmp/test.py")
        XCTAssertEqual(FileStorage.attachmentKind(for: py), .text)

        let unknown = URL(fileURLWithPath: "/tmp/test.xyz123")
        XCTAssertEqual(FileStorage.attachmentKind(for: unknown), .text)
    }
}
