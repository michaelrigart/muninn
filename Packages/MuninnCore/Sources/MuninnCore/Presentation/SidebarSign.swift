import Foundation

/// What a sidebar row shows beside a meeting's title.
public enum SidebarSign: Equatable, Sendable {
    case progress(step: Int, label: String)
    case queued, attention, recording, draftCreated, filed, none

    public static func sign(for meeting: Meeting, progress: MeetingProgress, needsAttention: Bool) -> SidebarSign {
        switch progress {
        case .working(let work): return .progress(step: work.stage.step, label: work.stage.title)
        case .preparingSpeechModel: return .progress(step: 1, label: "Getting the speech model ready")
        case .queued: return .queued
        case .none, .waiting, .failed: break
        }
        if needsAttention { return .attention }
        if case .recording = meeting.status { return .recording }
        if meeting.draftID != nil || meeting.draftWebLink != nil { return .draftCreated }
        if meeting.exportedNotePath != nil { return .filed }
        return .none
    }
}
