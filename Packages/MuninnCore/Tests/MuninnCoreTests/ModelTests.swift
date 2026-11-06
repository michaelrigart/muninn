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

    @Test func olderFilesWithDraftFieldsDecode() throws {
        let original = Self.meeting()
        var object = try #require(try JSONSerialization.jsonObject(with: StorageJSON.encoder().encode(original)) as? [String: Any])
        object["draftID"] = "AAMk-draft"
        object["draftWebLink"] = "https://outlook.test/d"
        let decoded = try StorageJSON.decoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == original)

        let reencoded = try #require(try JSONSerialization.jsonObject(with: StorageJSON.encoder().encode(decoded)) as? [String: Any])
        #expect(reencoded["draftID"] == nil)
        #expect(reencoded["draftWebLink"] == nil)
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
        let original = Self.meeting(mode: .micOnly, status: .failed(Problems.somethingWentWrong(stage: .other)), association: nil, client: "Acme", accountID: "other")
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
        for status in [ProcessingStatus.recording, .transcribing, .diarizing, .cleaning, .summarizing, .ready, .failed(Problems.legacyFailure()), .waiting(.studioUnreachable), .waiting(.studioNotConfigured)] {
            #expect(try JSONDecoder().decode(ProcessingStatus.self, from: encoder.encode(status)) == status)
        }
    }

    private func storedMeeting(mode: CaptureMode = .call(appBundleID: "us.zoom.xos"), status: Any? = nil, engineNotice: Any? = nil, transcriptNotice: Any? = nil) throws -> (meeting: Meeting, json: String) {
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.meeting(mode: mode, status: .ready))) as? [String: Any])
        if let status { object["status"] = status }
        if let engineNotice { object["engineNotice"] = engineNotice }
        if let transcriptNotice { object["transcriptNotice"] = transcriptNotice }
        let data = try JSONSerialization.data(withJSONObject: object)
        let meeting = try JSONDecoder().decode(Meeting.self, from: data)
        return (meeting, String(decoding: try JSONEncoder().encode(meeting), as: UTF8.self))
    }

    @Test func failedStatusRoundTripsItsProblem() throws {
        let status = ProcessingStatus.failed(Problems.claudeBusy())
        let encoded = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(ProcessingStatus.self, from: encoded) == status)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["type"] as? String == "failed")
        #expect(object["problem"] != nil)
        #expect(object["message"] == nil)
    }

    @Test func legacyFailureStringLoadsAsAGenericProblem() throws {
        let stored = try storedMeeting(status: ["type": "failed", "message": "Error Domain=NSURLErrorDomain Code=-1004 \(SEED)"])
        guard case .failed(let problem) = stored.meeting.status else {
            Issue.record("expected failed, got \(stored.meeting.status)")
            return
        }
        #expect(problem.title == "This meeting couldn't be finished" && problem.actions == [.tryAgain] && problem.details.fromEarlierVersion)
        #expect(!stored.json.contains("Henderson"))
    }

    @Test func aFailedStatusWithNeitherAProblemNorAMessageStillLoads() throws {
        let stored = try storedMeeting(status: ["type": "failed", "problem": "not a problem"])
        #expect(stored.meeting.status == .failed(Problems.legacyFailure()))
    }

    @Test func legacyEngineNoticeLoadsWithoutItsText() throws {
        let stored = try storedMeeting(engineNotice: "Claude failed: \(SEED) — kept the existing summary")
        #expect(stored.meeting.engineNotice?.title == "An earlier recap attempt didn't finish" && stored.meeting.engineNotice?.severity == .problem)
        #expect(stored.meeting.engineNotice?.actions == [.tryAgain, .writeWithAnotherEngine] && stored.meeting.needsAttention)
        #expect(!stored.json.contains("Henderson"))
    }

    @Test func legacyFallbackNoticeStaysAWarning() throws {
        let unreachable = try storedMeeting(engineNotice: "Network Mac unreachable — summarized on This Mac")
        #expect(unreachable.meeting.engineNotice == Problems.writtenOnThisMac(because: .studioUnreachable) && !unreachable.meeting.needsAttention)
        let notSetUp = try storedMeeting(engineNotice: "Network Mac not set up — summarized on This Mac")
        #expect(notSetUp.meeting.engineNotice == Problems.writtenOnThisMac(because: .studioNotConfigured) && !notSetUp.meeting.needsAttention)
    }

    @Test func legacyDiarisationNoticeBecomesATranscriptNotice() throws {
        let call = try storedMeeting(engineNotice: "Couldn't tell the other speakers apart; the call side is one speaker.")
        #expect(call.meeting.transcriptNotice?.title == "Couldn't tell the other speakers apart" && call.meeting.engineNotice == nil)
        let mic = try storedMeeting(mode: .micOnly, engineNotice: "Couldn't tell the speakers apart; the conversation is one speaker.")
        #expect(mic.meeting.transcriptNotice == Problems.diarisationDegraded(mode: .micOnly) && mic.meeting.engineNotice == nil)
    }

    @Test func legacyNoticeJoiningBothPartsSplitsIntoTwoNotices() throws {
        let stored = try storedMeeting(engineNotice: "Couldn't tell the other speakers apart; the call side is one speaker. Network Mac unreachable — summarized on This Mac")
        #expect(stored.meeting.transcriptNotice == Problems.diarisationDegraded(mode: .call(appBundleID: "us.zoom.xos")))
        #expect(stored.meeting.engineNotice == Problems.writtenOnThisMac(because: .studioUnreachable))
    }

    @Test func aLegacyNoticeDoesNotReplaceAStoredTranscriptNotice() throws {
        let stored = try storedMeeting(
            engineNotice: "Couldn't tell the other speakers apart; the call side is one speaker.",
            transcriptNotice: try JSONSerialization.jsonObject(with: JSONEncoder().encode(Problems.diarisationDegraded(mode: .micOnly)))
        )
        #expect(stored.meeting.transcriptNotice == Problems.diarisationDegraded(mode: .micOnly))
    }

    @Test func noticesRoundTripAndAnOddStoredNoticeDoesNotFailTheMeeting() throws {
        var original = Self.meeting()
        original.engineNotice = Problems.keptRecap(.studioUnreachable, api: .ollama)
        original.transcriptNotice = Problems.diarisationDegraded(mode: original.captureMode)
        #expect(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(original)) == original)

        let odd = try storedMeeting(engineNotice: 5, transcriptNotice: ["title": 5])
        #expect(odd.meeting.engineNotice == nil && odd.meeting.transcriptNotice == nil)
        #expect(odd.meeting.title == "Acme monthly sync")
    }

    @Test func needsAttention() {
        func meeting(_ status: ProcessingStatus, notice: Problem? = nil) -> Meeting {
            var meeting = Self.meeting(status: status)
            meeting.engineNotice = notice
            return meeting
        }
        #expect(meeting(.failed(Problems.claudeBusy())).needsAttention)
        #expect(meeting(.waiting(.claudeKeyMissing)).needsAttention)
        #expect(meeting(.waiting(.studioNotConfigured)).needsAttention)
        #expect(!meeting(.waiting(.studioUnreachable)).needsAttention)
        #expect(meeting(.ready, notice: Problems.keptRecap(.memoryPressure, api: .ollama)).needsAttention)
        #expect(!meeting(.ready, notice: Problems.writtenOnThisMac(because: .studioUnreachable)).needsAttention)
        #expect(!meeting(.ready).needsAttention)
        #expect(!meeting(.recording).needsAttention)
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
