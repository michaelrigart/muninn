import Foundation

/// The distinct segment start times, sorted, for the previous and next segment controls.
public struct SegmentTimeline: Sendable {
    private let starts: [TimeInterval]

    public init(transcript: Transcript) {
        starts = Array(Set(transcript.segments.map(\.start))).sorted()
    }

    /// The latest start before `time − 1.0`, or 0: within the first second of a segment, previous goes back one.
    public func previousStart(before time: TimeInterval) -> TimeInterval {
        let limit = time - 1.0
        let index = partitionPoint { $0 < limit }
        return index > 0 ? starts[index - 1] : 0
    }

    /// The earliest start after `time + 0.05`, or nil.
    public func nextStart(after time: TimeInterval) -> TimeInterval? {
        let limit = time + 0.05
        let index = partitionPoint { $0 <= limit }
        return index < starts.count ? starts[index] : nil
    }

    /// The count of leading starts for which `predicate` holds; `starts` is sorted, so they form a prefix.
    private func partitionPoint(_ predicate: (TimeInterval) -> Bool) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(starts[mid]) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
