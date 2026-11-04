import Foundation

public enum MeetingSearch {
    public static func recapText(_ summary: Summary) -> String {
        summary.subjects.flatMap { subject in
            [subject.title] + subject.bullets.map(\.text) + subject.actions.flatMap { [$0.owner, $0.text] }
        }.joined(separator: "\n")
    }

    public static func matches(_ meeting: Meeting, term: String, recapText: String?, transcriptText: String?) -> Bool {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        return meeting.title.localizedStandardContains(term)
            || (meeting.client?.localizedStandardContains(term) ?? false)
            || meeting.attendees.contains { $0.name.localizedStandardContains(term) || $0.email.localizedStandardContains(term) }
            || (recapText?.localizedStandardContains(term) ?? false)
            || (transcriptText?.localizedStandardContains(term) ?? false)
    }
}
