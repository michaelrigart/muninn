import Foundation

public struct LaneSpan: Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: String

    public init(start: TimeInterval, end: TimeInterval, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public struct PlaybackLane: Hashable, Sendable {
    public var track: Track
    public var spans: [LaneSpan]

    public init(track: Track, spans: [LaneSpan]) {
        self.track = track
        self.spans = spans
    }
}

public enum PlaybackLanes {
    static let mergeGap: TimeInterval = 0.5

    /// One lane per track that has segments, the microphone first. Consecutive spans of one speaker less than
    /// half a second apart become one.
    public static func lanes(for transcript: Transcript) -> [PlaybackLane] {
        [Track.mic, .system].compactMap { track in
            let segments = transcript.segments.filter { $0.track == track }.sorted { $0.start < $1.start }
            guard !segments.isEmpty else { return nil }
            var spans: [LaneSpan] = []
            for segment in segments {
                if let last = spans.last, last.speaker == segment.speaker, segment.start - last.end < mergeGap {
                    spans[spans.count - 1].end = max(last.end, segment.end)
                } else {
                    spans.append(LaneSpan(start: segment.start, end: segment.end, speaker: segment.speaker))
                }
            }
            return PlaybackLane(track: track, spans: spans)
        }
    }
}

public enum PlaybackMix: String, CaseIterable, Sendable {
    case both, callOnly, meOnly

    public var label: String {
        switch self {
        case .both: "Both"
        case .callOnly: "Call only"
        case .meOnly: "Me only"
        }
    }

    public func volume(for track: Track) -> Float {
        switch (self, track) {
        case (.both, _), (.callOnly, .system), (.meOnly, .mic): 1
        case (.callOnly, .mic), (.meOnly, .system): 0
        }
    }
}

public enum Playback {
    public static let speeds: [Float] = [1, 1.25, 1.5, 2]
    public static let skipInterval: TimeInterval = 15

    public static func speedLabel(_ speed: Float) -> String {
        "\(speed.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX"))))×"
    }

    public static func skip(from time: TimeInterval, by delta: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(time + delta, 0), duration)
    }
}
