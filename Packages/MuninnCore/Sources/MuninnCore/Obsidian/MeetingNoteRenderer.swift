import Foundation

public struct NoteOptions: Sendable {
    public var transcriptLink: URL
    public var embeddedTranscript: String?
    public var audioLinks: [URL]
    public var embeddedAudioFileNames: [String]
    public var timeZone: TimeZone
    public var relatedNotes: [String]

    public init(transcriptLink: URL, embeddedTranscript: String?, audioLinks: [URL], embeddedAudioFileNames: [String], timeZone: TimeZone = .current, relatedNotes: [String] = []) {
        self.transcriptLink = transcriptLink
        self.embeddedTranscript = embeddedTranscript
        self.audioLinks = audioLinks
        self.embeddedAudioFileNames = embeddedAudioFileNames
        self.timeZone = timeZone
        self.relatedNotes = relatedNotes
    }
}

public enum MeetingNoteRenderer {
    public static func render(meeting: Meeting, summary: Summary, options: NoteOptions) -> String {
        var lines: [String] = ["---", "type: meeting", "date: \(DayFormat.string(from: meeting.startedAt, timeZone: options.timeZone))", "title: \(quoted(meeting.title))"]
        if let client = meeting.client { lines.append("client: \(quoted(client))") }
        if let account = meeting.accountID { lines.append("account: \(quoted(account))") }
        let emails = meeting.attendees.map(\.email).filter { !$0.isEmpty }
        if emails.isEmpty {
            lines.append("attendees: []")
        } else {
            lines.append("attendees:")
            lines += emails.map { "  - \(quoted($0))" }
        }
        if let engine = meeting.summaryEngine { lines.append("engine: \(engine.rawValue)") }
        lines += ["muninn: \(meeting.id.rawValue)", "---", "", "# \(meeting.title)", "", "## Summary"]
        for subject in summary.subjects {
            lines += ["", "### \(subject.title)"]
            lines += subject.bullets.map { "- \($0.text)" }
            for action in subject.actions {
                let owner = meeting.speakerNames[action.owner] ?? action.owner
                var line = "- [ ] \(action.text) [owner:: \(owner)]"
                if let due = action.due { line += " [due:: \(due)]" }
                lines.append(line)
            }
        }
        lines += ["", "## Attendees", ""]
        lines += meeting.attendees.filter { !$0.email.isEmpty }.map { "- \($0.name) <\($0.email)>" }
        if !options.relatedNotes.isEmpty {
            lines += ["", "## Related", ""]
            lines += options.relatedNotes.map { "- [[\(linkName($0))]]" }
        }
        lines += ["", "## Transcript", ""]
        if let embedded = options.embeddedTranscript {
            lines.append(embedded)
        } else {
            lines.append("[Full transcript](\(options.transcriptLink.absoluteString))")
        }
        if !options.audioLinks.isEmpty || !options.embeddedAudioFileNames.isEmpty {
            lines.append("")
            for url in options.audioLinks {
                lines.append("[\(audioLabel(url))](\(url.absoluteString))")
            }
            lines += options.embeddedAudioFileNames.map { "![[\($0)]]" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func audioLabel(_ url: URL) -> String {
        switch url.deletingPathExtension().lastPathComponent {
        case "mic": "Audio (mic)"
        case "system": "Audio (call)"
        default: "Audio (\(url.lastPathComponent))"
        }
    }

    private static func linkName(_ name: String) -> String {
        String(name.filter { !"[]|".contains($0) })
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
