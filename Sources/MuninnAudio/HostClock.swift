import AVFoundation

/// A recording timeline in host time. Paused intervals do not count, so a buffer's host time maps to a
/// position that is the same for every track.
final class HostClock {
    private let lock = NSLock()
    private var start: UInt64 = 0
    private var pauses: [(from: UInt64, to: UInt64?)] = []
    private var end: UInt64?

    static func now() -> UInt64 { mach_absolute_time() }

    func begin(at hostTime: UInt64) {
        lock.withLock { start = hostTime }
    }

    func pause(at hostTime: UInt64) {
        lock.withLock {
            guard end == nil, pauses.last?.to != nil || pauses.isEmpty else { return }
            pauses.append((hostTime, nil))
        }
    }

    func resume(at hostTime: UInt64) {
        lock.withLock {
            guard end == nil, let last = pauses.last, last.to == nil else { return }
            pauses[pauses.count - 1].to = hostTime
        }
    }

    func finish(at hostTime: UInt64) {
        lock.withLock { if end == nil { end = hostTime } }
    }

    func isPaused(at hostTime: UInt64) -> Bool {
        lock.withLock {
            if let end, hostTime >= end { return true }
            return pauses.contains { hostTime >= $0.from && hostTime < ($0.to ?? UInt64.max) }
        }
    }

    struct Interval: Equatable {
        var from: UInt64
        var to: UInt64
    }

    /// The parts of `from..<to` that are recorded: outside every pause and before the end.
    func activeIntervals(from: UInt64, to: UInt64) -> [Interval] {
        lock.withLock {
            let high = min(to, end ?? to)
            guard high > from else { return [] }
            var result: [Interval] = []
            var cursor = from
            for pause in pauses {
                let pauseEnd = pause.to ?? UInt64.max
                if pauseEnd <= cursor { continue }
                if pause.from >= high { break }
                if pause.from > cursor { result.append(Interval(from: cursor, to: pause.from)) }
                cursor = max(cursor, pauseEnd)
                if cursor >= high { break }
            }
            if cursor < high { result.append(Interval(from: cursor, to: high)) }
            return result
        }
    }

    func seconds(at hostTime: UInt64) -> Double {
        lock.withLock {
            let limit = min(hostTime, end ?? hostTime)
            guard limit > start else { return 0 }
            var total = AVAudioTime.seconds(forHostTime: limit - start)
            for pause in pauses {
                let low = max(pause.from, start)
                let high = min(pause.to ?? limit, limit)
                if high > low { total -= AVAudioTime.seconds(forHostTime: high - low) }
            }
            return max(0, total)
        }
    }
}
