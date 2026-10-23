import Foundation
import Testing
@testable import MuninnCore

struct SummaryTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func meeting(flags: [Flag] = [], speakerNames: [String: String] = [:], language: String? = "en") -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "2026-10-23-0900-sync"), title: "Sync", startedAt: now, endedAt: nil,
            captureMode: .micOnly, language: language, accountID: nil, association: nil, client: nil,
            candidateEvents: [], attendees: [], recipients: [], flags: flags, speakerNames: speakerNames,
            status: .summarizing, summaryEngine: nil, engineNotice: nil, exportedNotePath: nil,
            draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    static func segment(_ id: Int, _ start: TimeInterval, _ end: TimeInterval, speaker: String = "jan", text: String = "text") -> Segment {
        Segment(id: id, track: .system, speaker: speaker, start: start, end: end, text: text, words: [])
    }

    static let transcript = Transcript(segments: [
        segment(1, 0, 20), segment(3, 62, 80), segment(7, 100, 120, speaker: "you"), segment(9, 120, 140),
    ], language: "en")

    static let clean = CleanTranscript(segments: [
        CleanSegment(id: 1, text: "Hello."), CleanSegment(id: 3, text: "We ship Friday."),
        CleanSegment(id: 7, text: "I will test it."), CleanSegment(id: 9, text: "Done."),
    ])

    @Test func userTextFormat() {
        let meeting = Self.meeting(speakerNames: ["jan": "Jan"])
        let request = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean)
        #expect(request.user.contains("[S3 01:02 Jan] We ship Friday."))
        #expect(request.user.contains("[S7 01:40 Me] I will test it."))
        #expect(request.jsonSchema != nil)
        let lowercase = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean)
        #expect(lowercase.user.contains("[S3 01:02 Jan]"))
    }

    @Test func systemPromptRules() {
        let request = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean, retryNote: "Return JSON only.")
        #expect(request.system.contains("language of the call"))
        #expect(request.system.contains("Group by subject"))
        #expect(request.system.contains("owner"))
        #expect(request.system.contains("`You` is Me"))
        #expect(request.system.contains("only when one was said"))
        #expect(request.system.contains("sources"))
        #expect(request.system.contains("Cover every flagged segment"))
        #expect(request.system.contains("Never invent facts"))
        #expect(request.system.contains("Return JSON only."))
    }

    @Test func attendeesLineOmitsOwnAddresses() {
        var meeting = Self.meeting()
        meeting.attendees = [
            Attendee(name: "Sam R", email: "Sam@Example.com"), Attendee(name: "Jan Peeters", email: "jan@acme.be"),
            Attendee(name: "", email: "kim@acme.be"),
        ]
        let request = SummaryRequestBuilder.build(
            meeting: meeting, transcript: Self.transcript, clean: Self.clean, selfAddresses: ["sam@example.com"]
        )
        #expect(request.user.contains("\nAttendees: Jan Peeters <jan@acme.be>, kim@acme.be\n"))
        #expect(!request.user.contains("Sam R"))
    }

    @Test func attendeesLineAbsentWithoutOtherAttendees() {
        let none = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean)
        #expect(!none.user.contains("Attendees"))
        var meeting = Self.meeting()
        meeting.attendees = [Attendee(name: "Me", email: "me@example.com")]
        let onlyMe = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean, selfAddresses: ["ME@example.com"])
        #expect(!onlyMe.user.contains("Attendees"))
    }

    @Test func attendeeNamingRuleIsInTheSystemPrompt() {
        let request = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean)
        #expect(request.system.contains("only when the conversation makes clear who is speaking; otherwise keep the `S<n>` label"))
    }

    @Test func userNameComesFromTheCaller() {
        let request = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean, userName: "Ada")
        #expect(request.system.contains("`You` is Ada"))
        #expect(request.user.contains("[S7 01:40 Ada] I will test it."))
        let blank = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean, userName: "  ")
        #expect(blank.system.contains("`You` is Me"))
    }

    @Test func userNameResolvesFromTheSystemFullName() {
        #expect(SummaryRequestBuilder.resolvedUserName("Ada", systemFullName: "Grace Hopper") == "Ada")
        #expect(SummaryRequestBuilder.resolvedUserName("", systemFullName: "Grace Hopper") == "Grace")
        #expect(SummaryRequestBuilder.resolvedUserName("  ", systemFullName: "  Grace  Hopper ") == "Grace")
        #expect(SummaryRequestBuilder.resolvedUserName("", systemFullName: "") == "Me")
        #expect(SummaryRequestBuilder.resolvedUserName("") == "Me")
        #expect(SummaryRequestBuilder.defaultUserName == "Me")
    }

    @Test func summarizerPassesSettingsToTheRequest() async throws {
        var settings = Settings.defaults
        settings.userName = "Ada"
        settings.accounts[0].selfAddresses = ["me@example.com"]
        var meeting = Self.meeting()
        meeting.attendees = [Attendee(name: "Me", email: "me@example.com"), Attendee(name: "Jan", email: "jan@acme.be")]
        let reply = #"{"language":"en","subjects":[]}"#
        let client = ScriptedClient([.success(reply)])
        let captured = settings
        let summarizer = LLMSummarizer(clientFor: { _ in client }, settings: { captured }, now: { Self.now })
        _ = try await summarizer.summarize(meeting: meeting, transcript: Self.transcript, clean: Self.clean, engine: .claude)
        let request = try #require(client.requests.first)
        #expect(request.system.contains("`You` is Ada"))
        #expect(request.user.contains("Attendees: Jan <jan@acme.be>"))
        #expect(!request.user.contains("me@example.com"))
    }

    @Test func flaggedLine() {
        let meeting = Self.meeting(flags: [Flag(offset: 70), Flag(offset: 110)])
        let request = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean)
        #expect(request.user.hasSuffix("Flagged segments: S3, S7"))
        let none = SummaryRequestBuilder.build(meeting: Self.meeting(), transcript: Self.transcript, clean: Self.clean)
        #expect(!none.user.contains("Flagged segments"))
    }

    @Test func flagMapping() {
        let ids = FlagCoverage.flaggedSegmentIDs([Flag(offset: 62), Flag(offset: 80), Flag(offset: 500), Flag(offset: 70)], in: Self.transcript)
        #expect(ids == [3, 9])
    }

    @Test func flagInGapMapsToPrecedingSegment() {
        #expect(FlagCoverage.flaggedSegmentIDs([Flag(offset: 90)], in: Self.transcript) == [3])
        #expect(FlagCoverage.flaggedSegmentIDs([Flag(offset: 5)], in: Transcript(segments: [], language: nil)) == [])
    }

    @Test func flagBeforeFirstMapsToFirst() {
        let late = Transcript(segments: [Self.segment(4, 10, 20), Self.segment(5, 20, 30)], language: "en")
        #expect(FlagCoverage.flaggedSegmentIDs([Flag(offset: 2)], in: late) == [4])
    }

    @Test func overlapPrefersContainingSegment() {
        let overlapping = Transcript(segments: [
            Self.segment(0, 0, 60, speaker: "you", text: "the important decision"), Self.segment(1, 10, 12, text: "Yeah."),
        ], language: "en")
        #expect(FlagCoverage.flaggedSegmentIDs([Flag(offset: 30)], in: overlapping) == [0])
    }

    @Test func promptAsksForISOLanguage() {
        let request = SummaryRequestBuilder.build(meeting: Self.meeting(language: "nl"), transcript: Self.transcript, clean: Self.clean)
        #expect(request.system.contains("ISO 639-1"))
        #expect(request.user.contains("Language hint: nl"))
        let bare = SummaryRequestBuilder.build(meeting: Self.meeting(language: nil), transcript: Transcript(segments: Self.transcript.segments, language: nil), clean: Self.clean)
        #expect(!bare.user.contains("Language hint"))
        #expect(request.maxTokens == SummaryRequestBuilder.summaryMaxTokens)
    }

    @Test func parserNormalisesLanguageNames() throws {
        for (raw, expected) in [("Dutch", "nl"), ("nl-BE", "nl"), ("Français", "fr"), ("english", "en"), ("en-US", "en"), ("DE", "de"), ("German", "ge")] {
            let json = "{\"language\":\"\(raw)\",\"subjects\":[]}"
            let result = try SummaryParser.parse(json, transcript: Self.transcript, flags: [], engine: .claude, now: Self.now)
            #expect(result.summary.language == expected)
        }
    }

    @Test func callDateLinePresent() {
        var components = DateComponents(year: 2026, month: 10, day: 23, hour: 9)
        components.timeZone = TimeZone(identifier: "Europe/Brussels")
        let start = Calendar(identifier: .gregorian).date(from: components)!
        var meeting = Self.meeting()
        meeting.startedAt = start
        let request = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean, timeZone: TimeZone(identifier: "Europe/Brussels")!)
        #expect(request.user.hasPrefix("Call date: 2026-10-23 (Friday)\n"))
        #expect(request.system.contains("relative due dates"))
    }

    @Test func callDateFollowsTheTimeZone() {
        var components = DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 30)
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        var meeting = Self.meeting()
        meeting.startedAt = Calendar(identifier: .gregorian).date(from: components)!
        let la = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(la.user.hasPrefix("Call date: 2026-10-26 (Monday)\n"))
        let brussels = SummaryRequestBuilder.build(meeting: meeting, transcript: Self.transcript, clean: Self.clean, timeZone: TimeZone(identifier: "Europe/Brussels")!)
        #expect(brussels.user.hasPrefix("Call date: 2026-10-27 (Tuesday)\n"))
    }

    static let json = """
    {"language":"en","subjects":[{"title":"Release","bullets":[{"text":"Ship Friday","sources":[3,99]}],
    "actions":[{"owner":"Sam","text":"Test","due":"2026-11-07","sources":[7,42]},
    {"owner":"Jan","text":"Deploy","due":"next week","sources":[3]}]}]}
    """

    @Test func parserDropsUnknownSources() throws {
        let result = try SummaryParser.parse(Self.json, transcript: Self.transcript, flags: [], engine: .claude, now: Self.now)
        #expect(result.summary.subjects[0].bullets[0].sources == [3])
        #expect(result.summary.subjects[0].actions[0].sources == [7])
        #expect(result.summary.engine == .claude)
        #expect(result.summary.generatedAt == Self.now)
        #expect(result.summary.language == "en")
    }

    @Test func parserNullsBadDue() throws {
        let result = try SummaryParser.parse(Self.json, transcript: Self.transcript, flags: [], engine: .studio, now: Self.now)
        #expect(result.summary.subjects[0].actions[0].due == "2026-11-07")
        #expect(result.summary.subjects[0].actions[1].due == nil)
    }

    @Test func parserToleratesFences() throws {
        let wrapped = "Here you go:\n```json\n" + Self.json + "\n```"
        let result = try SummaryParser.parse(wrapped, transcript: Self.transcript, flags: [], engine: .macbook, now: Self.now)
        #expect(result.summary.subjects.count == 1)
    }

    @Test func parserThrowsOnProse() {
        #expect(throws: SummaryParseError.notJSON("No JSON object in the reply")) {
            try SummaryParser.parse("I could not summarise this.", transcript: Self.transcript, flags: [], engine: .claude, now: Self.now)
        }
        do {
            _ = try SummaryParser.parse("{\"language\":\"en\"}", transcript: Self.transcript, flags: [], engine: .claude, now: Self.now)
            Issue.record("expected a throw")
        } catch let error as SummaryParseError {
            guard case .schemaMismatch = error else {
                Issue.record("expected schemaMismatch, got \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func uncoveredFlagsReported() throws {
        let flags = [Flag(offset: 70), Flag(offset: 110)]
        let result = try SummaryParser.parse(Self.json, transcript: Self.transcript, flags: flags, engine: .claude, now: Self.now)
        #expect(result.uncoveredFlagSegments == [])
        let uncovered = try SummaryParser.parse(Self.json, transcript: Self.transcript, flags: [Flag(offset: 10), Flag(offset: 130)], engine: .claude, now: Self.now)
        #expect(uncovered.uncoveredFlagSegments == [1, 9])
    }

    @Test func ensureCoveredAppendsSubject() {
        let base = Summary(language: "en", subjects: [], engine: .claude, generatedAt: Self.now)
        let english = FlagCoverage.ensureCovered(base, uncovered: [3, 7], clean: Self.clean)
        #expect(english.subjects.last?.title == "Flagged moments")
        #expect(english.subjects.last?.bullets == [Bullet(text: "We ship Friday.", sources: [3]), Bullet(text: "I will test it.", sources: [7])])
        var dutch = base
        dutch.language = "nl"
        #expect(FlagCoverage.ensureCovered(dutch, uncovered: [3], clean: Self.clean).subjects.last?.title == "Gemarkeerde momenten")
        var french = base
        french.language = "fr"
        #expect(FlagCoverage.ensureCovered(french, uncovered: [3], clean: Self.clean).subjects.last?.title == "Moments signalés")
        #expect(FlagCoverage.ensureCovered(base, uncovered: [], clean: Self.clean) == base)
    }

    @Test func schemaIsStrict() {
        func check(_ node: JSONValue) {
            switch node {
            case .object(let dict):
                if dict["type"] == .string("object") {
                    #expect(dict["additionalProperties"] == .bool(false))
                    if case .object(let props)? = dict["properties"], case .array(let required)? = dict["required"] {
                        #expect(Set(props.keys) == Set(required.compactMap { if case .string(let s) = $0 { s } else { nil } }))
                    } else {
                        Issue.record("object node without properties/required")
                    }
                }
                dict.values.forEach(check)
            case .array(let items):
                items.forEach(check)
            default:
                break
            }
        }
        check(SummarySchema.jsonSchema)
    }
}
