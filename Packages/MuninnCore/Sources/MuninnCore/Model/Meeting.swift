import Foundation

public struct MeetingID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make(startedAt: Date, title: String, timeZone: TimeZone, existing: Set<String>) -> MeetingID {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let prefix = formatter.string(from: startedAt)
        let slug = slug(title)
        let base = slug.isEmpty ? prefix : "\(prefix)-\(slug)"
        var candidate = base
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return MeetingID(rawValue: candidate)
    }

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        var capped = String(slug.prefix(40))
        while capped.hasSuffix("-") { capped.removeLast() }
        return capped
    }
}

public struct Attendee: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    /// Graph's attendee type (`required`, `optional` or `resource`), when the invite said.
    public var type: String?
    /// Graph's response status (`accepted`, `declined`, …), when the invite said.
    public var response: String?

    public init(name: String, email: String, type: String? = nil, response: String? = nil) {
        self.name = name
        self.email = email
        self.type = type
        self.response = response
    }

    public var isResource: Bool { type?.lowercased() == "resource" }
    public var hasDeclined: Bool { response?.lowercased() == "declined" }
}

public struct Recipient: Codable, Hashable, Sendable {
    public var attendee: Attendee
    public var included: Bool

    public init(attendee: Attendee, included: Bool) {
        self.attendee = attendee
        self.included = included
    }
}

public enum CaptureMode: Codable, Hashable, Sendable {
    case call(appBundleID: String)
    case micOnly

    private enum CodingKeys: String, CodingKey {
        case type, appBundleID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "call":
            self = .call(appBundleID: try container.decode(String.self, forKey: .appBundleID))
        case "micOnly":
            self = .micOnly
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown capture mode \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .call(let appBundleID):
            try container.encode("call", forKey: .type)
            try container.encode(appBundleID, forKey: .appBundleID)
        case .micOnly:
            try container.encode("micOnly", forKey: .type)
        }
    }
}

public enum WaitReason: String, Codable, Hashable, Sendable {
    case studioUnreachable, studioNotConfigured, memoryPressure, claudeKeyMissing, recording
}

public enum ProcessingStatus: Codable, Hashable, Sendable {
    case recording, transcribing, diarizing, cleaning, summarizing
    case waiting(WaitReason)
    case ready
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case type, reason, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "recording": self = .recording
        case "transcribing": self = .transcribing
        case "diarizing": self = .diarizing
        case "cleaning": self = .cleaning
        case "summarizing": self = .summarizing
        case "waiting": self = .waiting(try container.decode(WaitReason.self, forKey: .reason))
        case "ready": self = .ready
        case "failed": self = .failed(try container.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown status \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recording: try container.encode("recording", forKey: .type)
        case .transcribing: try container.encode("transcribing", forKey: .type)
        case .diarizing: try container.encode("diarizing", forKey: .type)
        case .cleaning: try container.encode("cleaning", forKey: .type)
        case .summarizing: try container.encode("summarizing", forKey: .type)
        case .waiting(let reason):
            try container.encode("waiting", forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .ready: try container.encode("ready", forKey: .type)
        case .failed(let message):
            try container.encode("failed", forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

public struct EventAssociation: Codable, Hashable, Sendable {
    public var accountID: String
    public var eventID: String
    public var iCalUID: String?

    public init(accountID: String, eventID: String, iCalUID: String?) {
        self.accountID = accountID
        self.eventID = eventID
        self.iCalUID = iCalUID
    }
}

public struct CalendarEventRef: Codable, Hashable, Sendable {
    public var accountID: String
    public var eventID: String
    public var subject: String
    public var start: Date

    public init(accountID: String, eventID: String, subject: String, start: Date) {
        self.accountID = accountID
        self.eventID = eventID
        self.subject = subject
        self.start = start
    }
}

public struct Flag: Codable, Hashable, Sendable {
    /// Seconds since recording start.
    public var offset: TimeInterval

    public init(offset: TimeInterval) {
        self.offset = offset
    }
}

public struct ProcessingMetrics: Codable, Hashable, Sendable {
    public var transcribeSeconds: Double?
    public var diarizeSeconds: Double?
    public var cleanSeconds: Double?
    public var summarizeSeconds: Double?

    public init(transcribeSeconds: Double? = nil, diarizeSeconds: Double? = nil, cleanSeconds: Double? = nil, summarizeSeconds: Double? = nil) {
        self.transcribeSeconds = transcribeSeconds
        self.diarizeSeconds = diarizeSeconds
        self.cleanSeconds = cleanSeconds
        self.summarizeSeconds = summarizeSeconds
    }
}

public struct Meeting: Codable, Hashable, Sendable, Identifiable {
    public var id: MeetingID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var captureMode: CaptureMode
    public var language: String?
    public var accountID: String?
    public var association: EventAssociation?
    /// Independent of the calendar association.
    public var client: String?
    public var candidateEvents: [CalendarEventRef]
    public var attendees: [Attendee]
    public var recipients: [Recipient]
    public var flags: [Flag]
    public var speakerNames: [String: String]
    public var status: ProcessingStatus
    public var summaryEngine: EngineKind?
    public var engineNotice: String?
    public var exportedNotePath: String?
    public var draftWebLink: String?
    public var metrics: ProcessingMetrics
    public var requestedEngine: EngineKind?
    /// The Graph id of the recap draft, kept whether or not Graph returned a web link.
    public var draftID: String?
    /// IANA identifier of the zone the call happened in, so its date stays the same wherever it is summarised.
    public var timeZone: String?

    public init(
        id: MeetingID,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        captureMode: CaptureMode,
        language: String?,
        accountID: String?,
        association: EventAssociation?,
        client: String?,
        candidateEvents: [CalendarEventRef],
        attendees: [Attendee],
        recipients: [Recipient],
        flags: [Flag],
        speakerNames: [String: String],
        status: ProcessingStatus,
        summaryEngine: EngineKind?,
        engineNotice: String?,
        exportedNotePath: String?,
        draftWebLink: String?,
        metrics: ProcessingMetrics,
        requestedEngine: EngineKind? = nil,
        draftID: String? = nil,
        timeZone: String? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.captureMode = captureMode
        self.language = language
        self.accountID = accountID
        self.association = association
        self.client = client
        self.candidateEvents = candidateEvents
        self.attendees = attendees
        self.recipients = recipients
        self.flags = flags
        self.speakerNames = speakerNames
        self.status = status
        self.summaryEngine = summaryEngine
        self.engineNotice = engineNotice
        self.exportedNotePath = exportedNotePath
        self.draftWebLink = draftWebLink
        self.metrics = metrics
        self.requestedEngine = requestedEngine
        self.draftID = draftID
        self.timeZone = timeZone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(MeetingID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        captureMode = try c.decode(CaptureMode.self, forKey: .captureMode)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
        association = try c.decodeIfPresent(EventAssociation.self, forKey: .association)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        candidateEvents = try c.decode([CalendarEventRef].self, forKey: .candidateEvents)
        attendees = try c.decode([Attendee].self, forKey: .attendees)
        recipients = try c.decode([Recipient].self, forKey: .recipients)
        flags = try c.decode([Flag].self, forKey: .flags)
        speakerNames = try c.decode([String: String].self, forKey: .speakerNames)
        status = try c.decode(ProcessingStatus.self, forKey: .status)
        summaryEngine = try c.decodeIfPresent(EngineKind.self, forKey: .summaryEngine)
        engineNotice = try c.decodeIfPresent(String.self, forKey: .engineNotice)
        exportedNotePath = try c.decodeIfPresent(String.self, forKey: .exportedNotePath)
        draftWebLink = try c.decodeIfPresent(String.self, forKey: .draftWebLink)
        metrics = try c.decode(ProcessingMetrics.self, forKey: .metrics)
        requestedEngine = try c.decodeIfPresent(EngineKind.self, forKey: .requestedEngine)
        draftID = try c.decodeIfPresent(String.self, forKey: .draftID)
        timeZone = try? c.decodeIfPresent(String.self, forKey: .timeZone)
    }
}
