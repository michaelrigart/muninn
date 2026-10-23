import Foundation
import Testing
@testable import MuninnCore

@Suite struct ModelTests {
    static let brussels = TimeZone(identifier: "Europe/Brussels")!

    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = brussels
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    static func meeting(
        mode: CaptureMode = .call(appBundleID: "us.zoom.xos"),
        status: ProcessingStatus = .waiting(.memoryPressure),
        association: EventAssociation? = EventAssociation(accountID: "other", eventID: "e1", iCalUID: "u1"),
        client: String? = nil,
        accountID: String? = "other"
    ) -> Meeting {
        let ada = Attendee(name: "Ada", email: "ada@example.com")
        return Meeting(
            id: MeetingID(rawValue: "2026-10-22-1400-acme-monthly-sync"),
            title: "Acme monthly sync",
            startedAt: date(2026, 10, 22, 14, 0),
            endedAt: date(2026, 10, 22, 15, 0),
            captureMode: mode,
            language: "en",
            accountID: accountID,
            association: association,
            client: client,
            candidateEvents: [CalendarEventRef(accountID: "other", eventID: "e2", subject: "Other", start: date(2026, 10, 22, 14, 30))],
            attendees: [ada],
            recipients: [Recipient(attendee: ada, included: true)],
            flags: [Flag(offset: 12.5), Flag(offset: 300)],
            speakerNames: ["S1": "Ada"],
            status: status,
            summaryEngine: .studio,
            engineNotice: nil,
            exportedNotePath: nil,
            draftWebLink: nil,
            metrics: ProcessingMetrics(transcribeSeconds: 1.5, diarizeSeconds: nil, cleanSeconds: nil, summarizeSeconds: 3)
        )
    }

    @Test func meetingRoundTrips() throws {
        let original = Self.meeting()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded == original)
        #expect(decoded.flags.count == 2)
    }

    @Test func draftIDRoundTripsAndOlderFilesDecode() throws {
        var original = Self.meeting()
        original.draftID = "AAMk-draft"
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        #expect(decoded.draftID == "AAMk-draft")
        #expect(decoded == original)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.meeting())) as? [String: Any])
        object.removeValue(forKey: "draftID")
        let older = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.draftID == nil)
    }

    @Test func timeZoneRoundTripsAndDecodesLossily() throws {
        var original = Self.meeting()
        original.timeZone = "America/Los_Angeles"
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        #expect(decoded.timeZone == "America/Los_Angeles")
        #expect(decoded == original)

        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["timeZone"] = 5
        let wrong = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(wrong.timeZone == nil)
        #expect(wrong.title == original.title)
        object.removeValue(forKey: "timeZone")
        let older = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.timeZone == nil)
    }

    @Test func clientWithoutAssociationRoundTrips() throws {
        let original = Self.meeting(mode: .micOnly, status: .failed("boom"), association: nil, client: "Acme", accountID: "other")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original))
        #expect(decoded.association == nil)
        #expect(decoded.client == "Acme")
        #expect(decoded.accountID == "other")
        #expect(decoded == original)
    }

    @Test func statusAndModeUseStableRepresentations() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let waiting = String(decoding: try encoder.encode(ProcessingStatus.waiting(.memoryPressure)), as: UTF8.self)
        #expect(waiting == #"{"reason":"memoryPressure","type":"waiting"}"#)
        let call = String(decoding: try encoder.encode(CaptureMode.call(appBundleID: "a.b")), as: UTF8.self)
        #expect(call == #"{"appBundleID":"a.b","type":"call"}"#)
        for status in [ProcessingStatus.recording, .transcribing, .diarizing, .cleaning, .summarizing, .ready, .failed("x"), .waiting(.studioUnreachable), .waiting(.studioNotConfigured)] {
            #expect(try JSONDecoder().decode(ProcessingStatus.self, from: encoder.encode(status)) == status)
        }
    }

    @Test func idSlug() {
        let start = Self.date(2026, 10, 22, 14, 0)
        let id = MeetingID.make(startedAt: start, title: "Acme: monthly sync!", timeZone: Self.brussels, existing: [])
        #expect(id.rawValue == "2026-10-22-1400-acme-monthly-sync")
        let clash = MeetingID.make(startedAt: start, title: "Acme: monthly sync!", timeZone: Self.brussels, existing: [id.rawValue])
        #expect(clash.rawValue == "2026-10-22-1400-acme-monthly-sync-2")
    }

    @Test func idSlugFoldsDiacriticsAndCaps() {
        let start = Self.date(2026, 1, 5, 9, 5)
        let id = MeetingID.make(startedAt: start, title: "Café réunion", timeZone: Self.brussels, existing: [])
        #expect(id.rawValue == "2026-01-05-0905-cafe-reunion")
        let long = MeetingID.make(startedAt: start, title: String(repeating: "abcdefghij ", count: 10), timeZone: Self.brussels, existing: [])
        let slug = long.rawValue.dropFirst("2026-01-05-0905-".count)
        #expect(slug.count <= 40)
        #expect(!slug.hasSuffix("-"))
    }

    @Test func jsonValueEncodesPlain() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = JSONValue.object(["a": .array([.number(1), .null])])
        #expect(String(decoding: try encoder.encode(value), as: UTF8.self) == #"{"a":[1,null]}"#)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,null,true,"s"]}"#.utf8))
        #expect(decoded == .object(["a": .array([.number(1), .null, .bool(true), .string("s")])]))
    }

    @Test func transcriptAndSummaryRoundTrip() throws {
        let transcript = Transcript(
            segments: [Segment(id: 0, track: .mic, speaker: Transcript.youSpeaker, start: 0, end: 2, text: "Hi", words: [Word(text: "Hi", start: 0, end: 1)])],
            language: "en"
        )
        #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(transcript)) == transcript)
        let summary = Summary(
            language: "en",
            subjects: [Subject(title: "T", bullets: [Bullet(text: "b", sources: [0])], actions: [ActionPoint(owner: "Ada", text: "do", due: "2026-10-30", sources: [0])])],
            engine: .claude,
            generatedAt: Self.date(2026, 10, 22, 16, 0)
        )
        #expect(try JSONDecoder().decode(Summary.self, from: JSONEncoder().encode(summary)) == summary)
    }
}
