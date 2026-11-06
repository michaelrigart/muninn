import Foundation

/// Decides which meetings to announce as needing attention: each one once when it enters the state, held while a recording runs.
public struct AttentionTracker: Sendable {
    private var needing: Set<MeetingID>
    private var held: Set<MeetingID> = []

    public init(seed meetings: [Meeting]) {
        needing = Set(meetings.filter(\.needsAttention).map(\.id))
    }

    public mutating func update(_ meetings: [Meeting], isRecording: Bool) -> [MeetingID] {
        let now = Set(meetings.filter(\.needsAttention).map(\.id))
        held = held.union(now.subtracting(needing)).intersection(now)
        needing = now.union(needing.subtracting(meetings.map(\.id)))
        guard !isRecording else { return [] }
        let announce = meetings.map(\.id).filter(held.contains)
        held = []
        return announce
    }
}
