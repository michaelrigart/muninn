/// Detects a capture callback that stopped arriving while the recording is active. It arms on the first
/// callback: before that the tap legitimately waits for the tapped process's first audio.
struct StallWatchdog {
    enum Change: Equatable {
        case stalled
        case resumed
    }

    let timeout: Double
    private var lastActivity: Double
    private var armed = false
    private var stalled = false
    private var heardSinceStall = false

    init(timeout: Double = 3, now: Double) {
        self.timeout = timeout
        self.lastActivity = now
    }

    mutating func noteCallback(at now: Double) {
        armed = true
        lastActivity = now
        if stalled { heardSinceStall = true }
    }

    mutating func check(now: Double, active: Bool) -> Change? {
        guard armed else { return nil }
        if stalled {
            guard heardSinceStall else { return nil }
            stalled = false
            heardSinceStall = false
            return .resumed
        }
        guard active else {
            lastActivity = max(lastActivity, now)
            return nil
        }
        if now - lastActivity >= timeout {
            stalled = true
            return .stalled
        }
        return nil
    }
}
