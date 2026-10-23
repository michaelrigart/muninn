import Foundation

public protocol TranscriptCleaning: Sendable {
    func clean(_ transcript: Transcript) async throws -> CleanTranscript
}

public struct RuleTranscriptCleaner: TranscriptCleaning {
    public init() {}

    public func clean(_ transcript: Transcript) async throws -> CleanTranscript {
        CleanTranscript(segments: transcript.segments.map {
            CleanSegment(id: $0.id, text: RuleCleaner.clean($0.text))
        })
    }
}
