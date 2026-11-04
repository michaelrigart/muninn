import Foundation

public struct SpeechModelPreparation: Equatable, Sendable {
    public var model: String
    /// nil when the progress isn't known.
    public var fraction: Double?

    public init(model: String, fraction: Double?) {
        self.model = model
        self.fraction = fraction
    }
}

public enum MeetingProgress: Equatable, Sendable {
    case none
    case queued(ahead: Int)
    case working(PipelineWork)
    case preparingSpeechModel(SpeechModelPreparation)
    case waiting(WaitReason)
    case failed(Problem)
}

extension MeetingProgress {
    /// What Muninn is doing with the meeting, in a few words; nil when it is doing nothing or the meeting waits or failed.
    public var title: String? {
        switch self {
        case .working(let work): work.stage.title
        case .queued: "Waiting its turn"
        case .preparingSpeechModel: "Getting the speech model ready"
        case .none, .waiting, .failed: nil
        }
    }
}

public enum ProcessingDisplay {
    public static func progress(for meeting: Meeting, snapshot: PipelineSnapshot, speechModel: SpeechModelPreparation?) -> MeetingProgress {
        let running = snapshot.current == nil ? 0 : 1
        if let current = snapshot.current, current.meetingID == meeting.id {
            if current.stage == .transcribing, let speechModel { return .preparingSpeechModel(speechModel) }
            return .working(current)
        }
        if case .waiting(let reason) = meeting.status, reason != .queued { return .waiting(reason) }
        if let index = snapshot.queued.firstIndex(of: meeting.id) { return .queued(ahead: index + running) }
        switch meeting.status {
        case .failed(let problem): return .failed(problem)
        case .transcribing, .diarizing, .cleaning, .summarizing, .waiting(.queued):
            return .queued(ahead: snapshot.queued.count + running)
        default: return .none
        }
    }

    /// The stored `needsAttention`, except that a meeting running or waiting its turn is not asking for the user.
    public static func needsAttention(_ meeting: Meeting, snapshot: PipelineSnapshot) -> Bool {
        if snapshot.current?.meetingID == meeting.id || snapshot.queued.contains(meeting.id) { return false }
        return meeting.needsAttention
    }

    public static func workLine(meetings: [Meeting], snapshot: PipelineSnapshot) -> String? {
        guard let current = snapshot.current, let meeting = meetings.first(where: { $0.id == current.meetingID }) else { return nil }
        return "\(current.stage.title) · \(meeting.title) · step \(current.stage.step) of 4"
    }

    public static func attentionLine(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 meeting needs attention"
        default: "\(count) meetings need attention"
        }
    }

    public static func attentionReason(_ meeting: Meeting, api: EndpointAPI) -> String? {
        guard meeting.needsAttention else { return nil }
        switch meeting.status {
        case .failed(let problem): return problem.title
        case .waiting(let reason): return Problems.waiting(reason, api: api, claudeKeyPresent: false).title
        default: return meeting.engineNotice?.title
        }
    }
}
