import Testing
@testable import MuninnSpeech

@Suite struct LiveModelTests {
    @Test func onlyParakeetModelsStreamLive() {
        #expect(SpeechModelID.parakeetV3.supportsLive)
        #expect(SpeechModelID.parakeetUltra.supportsLive)
        #expect(!SpeechModelID.whisperLargeV3Turbo.supportsLive)
    }

    @Test func aStoredWhisperOrUnknownLiveModelFallsBackToTheDefault() {
        #expect(SpeechModelID.liveModel(named: "parakeet-ultra") == .parakeetUltra)
        #expect(SpeechModelID.liveModel(named: "whisper-large-v3-turbo") == .parakeetV3)
        #expect(SpeechModelID.liveModel(named: "nonsense") == .parakeetV3)
    }
}
