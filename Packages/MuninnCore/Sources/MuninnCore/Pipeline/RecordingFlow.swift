import Foundation

public struct CallIdentity: Equatable, Sendable {
    public var appName: String
    public var bundleID: String
    public var pid: pid_t

    public init(appName: String, bundleID: String, pid: pid_t) {
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
    }
}

public enum TapPlan: Equatable, Sendable {
    /// `bundleID` is the watch-list entry the call was detected under; the tap covers every audio process of that app.
    case process(bundleID: String, pid: pid_t), allSystemAudio, micOnly
}

public enum RecordingFlowState: Equatable, Sendable {
    case idle
    case offering(CallIdentity)
    case confirmAllAudio(CallIdentity)
    case recording(TapPlan, call: CallIdentity?)
}

public enum RecordingFlowEvent: Equatable, Sendable {
    case callStarted(appName: String, bundleID: String, pid: pid_t)
    case callEnded(bundleID: String)
    case recordTapped, declined, processTapFailed, confirmAllAudio, cancel, manualConversation, stopped
}

public enum RecordingFlow {
    public static func next(_ s: RecordingFlowState, _ e: RecordingFlowEvent) -> RecordingFlowState {
        switch (s, e) {
        case (_, .stopped):
            return .idle
        case (.idle, .callStarted(let appName, let bundleID, let pid)):
            return .offering(CallIdentity(appName: appName, bundleID: bundleID, pid: pid))
        case (.idle, .manualConversation):
            return .recording(.micOnly, call: nil)
        case (.offering(let call), .recordTapped):
            return .recording(.process(bundleID: call.bundleID, pid: call.pid), call: call)
        case (.offering, .declined):
            return .idle
        case (.recording(.process, let call?), .processTapFailed):
            return .confirmAllAudio(call)
        case (.confirmAllAudio(let call), .confirmAllAudio):
            return .recording(.allSystemAudio, call: call)
        case (.confirmAllAudio, .cancel):
            return .idle
        case (.offering(let call), .callEnded(let bundleID)), (.confirmAllAudio(let call), .callEnded(let bundleID)):
            return bundleID == call.bundleID ? .idle : s
        default:
            return s
        }
    }

    /// Whether the call detector must be restarted to follow the watch list. A recording keeps the detector it started with,
    /// because dropping an app would drop that app's `.ended` and the recording would never auto-stop. Every other state follows
    /// the list at once, so an edit made during a recording is applied wherever the recording ends: stop, failed start, cancelled
    /// all-audio, discard or quit.
    public static func detectorNeedsRestart(running: [String]?, wanted: [String]?, state: RecordingFlowState) -> Bool {
        if case .recording = state { return false }
        return wanted != nil && running != wanted
    }
}
