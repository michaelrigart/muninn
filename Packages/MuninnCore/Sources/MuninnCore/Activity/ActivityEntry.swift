import Foundation

public struct ActivityMeeting: Codable, Hashable, Sendable {
    public var id: MeetingID
    public var title: String

    public init(id: MeetingID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var time: Date
    public var level: ActivityLevel
    public var area: ActivityArea
    public var meeting: ActivityMeeting?
    public var message: String
    public var details: ProblemDetails?

    public init(
        id: UUID = UUID(),
        time: Date,
        level: ActivityLevel,
        area: ActivityArea,
        meeting: ActivityMeeting? = nil,
        message: String,
        details: ProblemDetails? = nil
    ) {
        self.id = id
        self.time = time
        self.level = level
        self.area = area
        self.meeting = meeting
        self.message = message
        self.details = details
    }

    public static func problem(_ problem: Problem, area: ActivityArea, meeting: ActivityMeeting?, time: Date) -> ActivityEntry {
        ActivityEntry(time: time, level: problem.severity, area: area, meeting: meeting, message: problem.title, details: problem.details)
    }

    public func redacted() -> ActivityEntry {
        var copy = self
        copy.message = Redaction.redact(message)
        copy.meeting = meeting.map { ActivityMeeting(id: $0.id, title: Redaction.redact($0.title)) }
        copy.details = details?.redacted()
        return copy
    }
}

public protocol ActivityRecording: Sendable {
    func record(_ entry: ActivityEntry)
}

public struct NoActivity: ActivityRecording {
    public init() {}

    public func record(_ entry: ActivityEntry) {}
}

public enum ActivityScope {
    /// The meeting the running work belongs to, so engines can record against it without being told which.
    @TaskLocal public static var meeting: ActivityMeeting?
}

public enum DurationText {
    public static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 {
            let minutes = total / 60
            let rest = total % 60
            return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }

    public static func minutes(_ seconds: TimeInterval) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        if total < 60 { return "\(total) min" }
        let hours = total / 60
        let rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
