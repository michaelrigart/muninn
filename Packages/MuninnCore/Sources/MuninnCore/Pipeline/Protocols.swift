import Foundation

public struct SpeakerTurn: Codable, Hashable, Sendable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

public protocol Transcribing: Sendable {
    /// Segments come back with an empty speaker until attribution.
    func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment]
}

public protocol Diarizing: Sendable {
    func diarize(audio: URL) async throws -> [SpeakerTurn]
}

public protocol EnvironmentProbing: Sendable {
    func environment(settings: Settings) async -> EngineEnvironment
}
