import Foundation

public struct LLMRequest: Sendable {
    public var system: String
    public var user: String
    public var jsonSchema: JSONValue?
    public var maxTokens: Int

    public init(system: String, user: String, jsonSchema: JSONValue?, maxTokens: Int) {
        self.system = system
        self.user = user
        self.jsonSchema = jsonSchema
        self.maxTokens = maxTokens
    }
}

public enum SummaryRequestBuilder {
    public static let defaultUserName = "Me"
    /// Reply budget for Claude.
    public static let summaryMaxTokens = 16000
    /// Reply budget for the local engines (This Mac and the Network Mac); a smaller reserve keeps their context small.
    public static let localSummaryMaxTokens = 8192

    public static func summaryMaxTokens(for engine: EngineKind) -> Int {
        engine == .claude ? summaryMaxTokens : localSummaryMaxTokens
    }

    public static func resolvedUserName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultUserName : trimmed
    }

    /// The name for the user's own lines: the setting when set, else the first word of the system's full user name, else "Me".
    public static func resolvedUserName(_ name: String, systemFullName: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let first = systemFullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        return first.isEmpty ? defaultUserName : first
    }

    public static func build(
        meeting: Meeting,
        transcript: Transcript,
        clean: CleanTranscript,
        retryNote: String? = nil,
        userName: String = defaultUserName,
        selfAddresses: [String] = [],
        maxTokens: Int = summaryMaxTokens,
        timeZone: TimeZone = .current
    ) -> LLMRequest {
        let userName = resolvedUserName(userName)
        var system = """
        You summarise a recorded call from its transcript. Each transcript line reads `[S<id> <mm:ss> <speaker>] <text>`.
        Rules:
        - Write in the language of the call, and set `language` to its ISO 639-1 code (nl, fr or en).
        - Group by subject: each subject has a short title, bullets and action points.
        - Give every action point an owner, as named in the call (`You` is \(userName), the user), and a due date only when one was said, as YYYY-MM-DD; otherwise null. Resolve relative due dates ("next Friday") against the call date on the first line of the transcript message.
        - Name an action's owner, or a speaker, after an attendee only when the conversation makes clear who is speaking; otherwise keep the `S<n>` label.
        - Cite the segment ids that support each bullet and action point in `sources`, as integers without the S.
        - Cover every flagged segment: the user marked those moments as important, so each must appear in a bullet or action point.
        - Never invent facts: use only what the transcript says.
        - Reply with a single JSON object that matches the schema, and nothing else.
        """
        if let retryNote {
            system += "\n\n" + retryNote
        }

        var lines = ["Call date: " + callDate(meeting.startedAt, in: timeZone)]
        if let hint = meeting.language ?? transcript.language {
            lines.append("Language hint: \(hint)")
        }
        let own = Set(selfAddresses.map { $0.lowercased() })
        let attendees = meeting.attendees.filter { !own.contains($0.email.lowercased()) }.map { attendee in
            if attendee.email.isEmpty { return attendee.name }
            return attendee.name.isEmpty ? attendee.email : "\(attendee.name) <\(attendee.email)>"
        }.filter { !$0.isEmpty }
        if !attendees.isEmpty {
            lines.append("Attendees: " + attendees.joined(separator: ", "))
        }
        lines += transcript.segments.map { segment in
            let text = clean.text(for: segment)
            return "[S\(segment.id) \(timestamp(segment.start)) \(displayName(segment.speaker, speakerNames: meeting.speakerNames, userName: userName))] \(text)"
        }
        let flagged = FlagCoverage.flaggedSegmentIDs(meeting.flags, in: transcript)
        if !flagged.isEmpty {
            lines.append("Flagged segments: " + flagged.map { "S\($0)" }.joined(separator: ", "))
        }
        return LLMRequest(system: system, user: lines.joined(separator: "\n"), jsonSchema: SummarySchema.jsonSchema, maxTokens: maxTokens)
    }

    public static func displayName(_ speaker: String, meeting: Meeting, userName: String = defaultUserName) -> String {
        displayName(speaker, speakerNames: meeting.speakerNames, userName: userName)
    }

    public static func displayName(_ speaker: String, speakerNames: [String: String], userName: String = defaultUserName) -> String {
        if let name = speakerNames[speaker] { return name }
        if speaker == Transcript.youSpeaker { return resolvedUserName(userName) }
        return speaker.prefix(1).uppercased() + speaker.dropFirst()
    }

    private static func callDate(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd (EEEE)"
        return formatter.string(from: date)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
