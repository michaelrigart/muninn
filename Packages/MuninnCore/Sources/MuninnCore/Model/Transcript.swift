import Foundation

public enum Track: String, Codable, Hashable, Sendable {
    case mic, system
}

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct Segment: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var track: Track
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [Word]

    public init(id: Int, track: Track, speaker: String, start: TimeInterval, end: TimeInterval, text: String, words: [Word]) {
        self.id = id
        self.track = track
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

public struct Transcript: Codable, Hashable, Sendable {
    public static let youSpeaker = "you"

    public var segments: [Segment]
    public var language: String?

    public init(segments: [Segment], language: String?) {
        self.segments = segments
        self.language = language
    }
}

/// 16 kHz mono samples.
public struct LiveAudioChunk: Sendable {
    public var track: Track
    public var samples: [Float]
    public var time: TimeInterval

    public init(track: Track, samples: [Float], time: TimeInterval) {
        self.track = track
        self.samples = samples
        self.time = time
    }
}

public struct CleanSegment: Codable, Hashable, Sendable {
    public var id: Int
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public struct CleanTranscript: Codable, Hashable, Sendable {
    public var segments: [CleanSegment]

    public init(segments: [CleanSegment]) {
        self.segments = segments
    }

    public func text(for segment: Segment) -> String {
        segments.first(where: { $0.id == segment.id })?.text ?? segment.text
    }
}
