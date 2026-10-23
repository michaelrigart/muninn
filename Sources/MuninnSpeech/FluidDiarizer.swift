import FluidAudio
import Foundation
import MuninnCore

public struct FluidDiarizer: Diarizing {
    private static let managers = KeyedLoadOnce<String, OfflineDiarizerManager>()
    private static let gate = SerialGate()

    public init() {}

    public func diarize(audio: URL) async throws -> [SpeakerTurn] {
        let manager = try await Self.managers.value(for: "offline") {
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
            return manager
        }
        let result: DiarizationResult
        do {
            result = try await Self.gate.run { try await manager.process(audio) }
        } catch OfflineDiarizationError.noSpeechDetected {
            return []
        }
        return result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
        }
    }
}
