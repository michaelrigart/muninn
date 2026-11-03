import Foundation

public enum MeetingActivity {
    public static func entries(from old: Meeting?, to new: Meeting, settings: Settings, time: Date) -> [ActivityEntry] {
        guard let old else { return [] }
        let meeting = ActivityMeeting(id: new.id, title: new.title)
        var result: [ActivityEntry] = []
        if old.status != new.status {
            if let entry = statusEntry(from: old.status, to: new, meeting: meeting, settings: settings, time: time) {
                result.append(entry)
            }
        }
        if let notice = new.engineNotice, notice != old.engineNotice {
            result.append(.problem(notice, area: .recap, meeting: meeting, time: time))
        }
        if let notice = new.transcriptNotice, notice != old.transcriptNotice {
            result.append(.problem(notice, area: .transcription, meeting: meeting, time: time))
        }
        return result
    }

    private static func statusEntry(from old: ProcessingStatus, to new: Meeting, meeting: ActivityMeeting, settings: Settings, time: Date) -> ActivityEntry? {
        switch new.status {
        case .failed(let problem):
            return .problem(problem, area: problem.details.stage?.area ?? .app, meeting: meeting, time: time)
        case .waiting(let reason):
            guard reason != .queued else { return nil }
            let problem = Problems.waiting(reason, api: settings.macbook.api, claudeKeyPresent: false)
            return ActivityEntry(time: time, level: .warning, area: reason == .recording ? .recording : .engines, meeting: meeting, message: problem.title)
        case .diarizing where old == .transcribing:
            guard let ended = new.endedAt, let took = new.metrics.transcribeSeconds else { return nil }
            let length = DurationText.short(ended.timeIntervalSince(new.startedAt))
            return ActivityEntry(time: time, level: .info, area: .transcription, meeting: meeting, message: "Transcribed \(length) of audio in \(DurationText.short(took))")
        case .ready where old == .summarizing:
            guard let engine = new.summaryEngine, let took = new.metrics.summarizeSeconds else { return nil }
            let model = ProblemContext.engine(engine, settings: settings, stage: .writingRecap, claudeKeyPresent: false).model ?? ""
            return ActivityEntry(time: time, level: .info, area: .recap, meeting: meeting, message: "Recap written by \(engine.displayName) · \(model) · \(DurationText.short(took))")
        default:
            return nil
        }
    }
}
