import XCTest
@testable import CT_Transcriber

final class AppSettingsTests: XCTestCase {

    func testDefaultSettingsDecodable() {
        guard let url = Bundle.main.url(forResource: "default-settings", withExtension: "json") else {
            // In test context, bundle may not have resources — test with inline JSON
            return
        }
        let data = try! Data(contentsOf: url)
        let settings = try! JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcription.condaEnvName, "ct-transcriber-metal-env")
        XCTAssertEqual(settings.transcription.beamSize, 4)
        XCTAssertEqual(settings.transcription.temperature, 1.0)
        XCTAssertEqual(settings.transcription.device, "mps")
        XCTAssertTrue(settings.transcription.vadFilter)
        XCTAssertFalse(settings.llm.providers.isEmpty)
    }

    func testSettingsRoundTrip() {
        let json = """
        {"general":{"theme":"dark","fontScale":1.5},"transcription":{"condaEnvName":"test-env","ctranslate2SourcePath":"","ct2PackageURL":"","modelsDirectory":"","selectedModelID":"test","models":[],"beamSize":3,"temperature":0.5,"language":"en","vadFilter":false,"conditionOnPreviousText":true,"flashAttention":false,"skipTimestamps":true,"maxParallelTranscriptions":2,"device":"cpu"},"llm":{"activeProviderID":"00000000-0000-0000-0000-000000000000","providers":[]}}
        """
        let data = Data(json.utf8)
        let settings = try! JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.general.theme, .dark)
        XCTAssertEqual(settings.general.fontScale, 1.5)
        XCTAssertEqual(settings.transcription.condaEnvName, "test-env")
        XCTAssertEqual(settings.transcription.beamSize, 3)
        XCTAssertEqual(settings.transcription.temperature, 0.5)
        XCTAssertEqual(settings.transcription.language, "en")
        XCTAssertFalse(settings.transcription.vadFilter)
        XCTAssertTrue(settings.transcription.conditionOnPreviousText)
        XCTAssertTrue(settings.transcription.skipTimestamps)
        XCTAssertEqual(settings.transcription.maxParallelTranscriptions, 2)
        XCTAssertEqual(settings.transcription.device, "cpu")

        // Encode and decode again
        let encoder = JSONEncoder()
        let reencoded = try! encoder.encode(settings)
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: reencoded)
        XCTAssertEqual(settings, decoded)
    }

    func testProviderConfigRoundTrip() {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"Test","apiType":"OpenAI Compatible","baseURL":"https://api.test.com","completionsPath":"v1/chat/completions","modelsPath":"v1/models","defaultModel":"gpt-4","fallbackModels":["gpt-3.5"],"temperature":0.7,"maxTokens":4096,"apiKey":"sk-test","extraHeaders":{"X-Custom":"value"}}
        """
        let config = try! JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.name, "Test")
        XCTAssertEqual(config.apiKey, "sk-test")
        XCTAssertEqual(config.extraHeaders["X-Custom"], "value")
        XCTAssertEqual(config.fallbackModels, ["gpt-3.5"])

        let reencoded = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(ProviderConfig.self, from: reencoded)
        XCTAssertEqual(config, decoded)
    }
}
