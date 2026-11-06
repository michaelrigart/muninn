import Foundation

public enum MeetingCommand: CaseIterable, Sendable {
    case regenerate, emailRecap, obsidian, previousVersion, moveToTrash
}

/// What the window knows about a meeting when it decides which commands to offer.
public struct MeetingCommandContext: Sendable {
    public var meeting: Meeting
    public var progress: MeetingProgress
    public var hasRecap: Bool
    public var hasPreviousRecap: Bool
    public var unsavedEdits: Bool
    public var eventChanging: Bool

    public init(meeting: Meeting, progress: MeetingProgress, hasRecap: Bool, hasPreviousRecap: Bool, unsavedEdits: Bool, eventChanging: Bool) {
        self.meeting = meeting
        self.progress = progress
        self.hasRecap = hasRecap
        self.hasPreviousRecap = hasPreviousRecap
        self.unsavedEdits = unsavedEdits
        self.eventChanging = eventChanging
    }

    /// Muninn is processing the meeting or about to.
    var isBusy: Bool {
        switch meeting.status {
        case .transcribing, .diarizing, .cleaning, .summarizing: return true
        default: break
        }
        switch progress {
        case .working, .preparingSpeechModel, .queued: return true
        case .none, .waiting, .failed: return false
        }
    }
}

public enum MeetingCommands {
    private static let wait = "Wait until Muninn has finished this meeting"
    private static let stopRecording = "Stop the recording first"
    private static let save = "Save your recap edits first"
    private static let eventChange = "Wait for the event change"

    /// Why the command is unavailable, or nil when it is available. The first reason that applies wins.
    public static func disabledReason(_ command: MeetingCommand, _ c: MeetingCommandContext) -> String? {
        let status = c.meeting.status
        let recording = status == .recording
        switch command {
        case .regenerate:
            if recording || status == .waiting(.recording) { return "Choose an engine once the recording has ended" }
            if c.isBusy { return wait }
            if c.unsavedEdits { return save }
            if c.eventChanging { return eventChange }
        case .emailRecap, .obsidian:
            if recording || c.isBusy || status != .ready { return "The recap isn't ready yet" }
            if !c.hasRecap { return "There's no recap yet" }
            if c.unsavedEdits { return save }
            if c.eventChanging { return eventChange }
            if !c.meeting.candidateEvents.isEmpty { return "Choose the event first" }
        case .previousVersion:
            if !c.hasPreviousRecap { return "There's no previous version" }
            if c.isBusy { return wait }
            if c.unsavedEdits { return save }
        case .moveToTrash:
            if recording { return stopRecording }
            if !MeetingActions.canDelete(c.meeting) || c.isBusy { return wait }
        }
        return nil
    }

    /// Why a speaker can't be changed now, or nil when it can: the transcript is only edited while Muninn isn't working on the meeting.
    public static func speakerChangeRefusal(status: ProcessingStatus, progress: MeetingProgress, hasJob: Bool) -> String? {
        switch status {
        case .recording: return stopRecording
        case .transcribing, .diarizing, .cleaning, .summarizing, .waiting: return wait
        case .ready, .failed: break
        }
        switch progress {
        case .working, .preparingSpeechModel, .queued, .waiting: return wait
        case .none, .failed: break
        }
        return hasJob ? wait : nil
    }

    /// Why a draft can't be made for the meeting, or nil when it can.
    public static func draftRefusal(_ m: Meeting, accounts: [AccountSettings]) -> String? {
        if m.accountID == nil { return "Choose an account in the meeting's details" }
        if MeetingActions.accountRemoved(m, accounts: accounts) { return MeetingActions.accountRemovedLabel }
        if !m.recipients.contains(where: \.included) { return "Choose at least one recipient" }
        return nil
    }
}

/// A speaker change refused because Muninn is recording or working on the meeting.
public struct SpeakerChangeRefused: ProblemConvertible, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func problem(in context: ProblemContext) -> Problem {
        Problem(severity: .warning, title: "The speaker wasn't changed", explanation: "\(reason).", actions: [], details: ProblemDetails())
    }
}
