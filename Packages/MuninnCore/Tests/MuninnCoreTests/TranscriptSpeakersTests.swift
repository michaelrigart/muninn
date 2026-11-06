import Foundation
import Testing
@testable import MuninnCore

struct TranscriptSpeakersTests {
    private func segment(_ id: Int, _ speaker: String, track: Track = .system) -> Segment {
        Segment(id: id, track: track, speaker: speaker, start: Double(id), end: Double(id) + 1, text: "", words: [])
    }

    private func transcript(_ speakers: [String]) -> Transcript {
        Transcript(segments: speakers.enumerated().map { segment($0.offset, $0.element) }, language: nil)
    }

    private func meeting(attendees: [Attendee]) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: "m1"), title: "Sync", startedAt: Date(timeIntervalSince1970: 1_792_000_000), endedAt: nil,
            captureMode: .micOnly, language: "en", accountID: "work", association: nil, client: nil,
            candidateEvents: [], attendees: attendees, recipients: [], flags: [], speakerNames: [:], status: .ready,
            summaryEngine: nil, engineNotice: nil, exportedNotePath: nil, metrics: ProcessingMetrics()
        )
    }

    @Test func labelNumbers() {
        #expect(TranscriptSpeakers.number(of: "S1") == 1)
        #expect(TranscriptSpeakers.number(of: "S12") == 12)
        for label in ["S0", "S01", "s1", "S", "you", "S1a", "S\u{0663}", "S99999999999999999999"] {
            #expect(TranscriptSpeakers.number(of: label) == nil)
        }
    }

    @Test func orderPutsYouFirstThenByNumber() {
        let t = transcript(["S3", "you", "S10", "S2", "Guest", "S3"])

        #expect(TranscriptSpeakers.ordered(in: t) == ["you", "S2", "S3", "S10", "Guest"])
    }

    @Test func newLabelSkipsEveryLabelThatStillCarriesMeaning() {
        let t = transcript(["S1", "S2"])

        #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: [:], recapOwners: []) == "S3")
        #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: ["S5": "Ann"], recapOwners: ["you", "Ann"]) == "S6")
        #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: ["S5": "Ann"], recapOwners: ["S7"]) == "S8")
        #expect(TranscriptSpeakers.newLabel(transcript: Transcript(segments: [], language: nil), speakerNames: [:], recapOwners: []) == "S1")
    }

    @Test func changeTouchesOnlyTheChosenSegments() {
        let words = [Word(text: "hello", start: 0, end: 0.5), Word(text: "there", start: 0.5, end: 1)]
        let t = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 1, text: "hello there", words: words),
            Segment(id: 1, track: .system, speaker: "S1", start: 1, end: 2, text: "hi", words: words),
            Segment(id: 2, track: .system, speaker: "S2", start: 2, end: 3, text: "yes", words: words),
            Segment(id: 3, track: .mic, speaker: "you", start: 3, end: 4, text: "ok", words: words),
        ], language: "en")

        let changed = TranscriptSpeakers.changing([1, 2, 99], to: "S9", in: t)

        #expect(changed.segments.map(\.speaker) == ["you", "S9", "S9", "you"])
        #expect(changed.language == "en")
        for (before, after) in zip(t.segments, changed.segments) {
            var expected = before
            if [1, 2].contains(before.id) { expected.speaker = "S9" }
            #expect(after == expected)
        }
        #expect(TranscriptSpeakers.changing([], to: "S9", in: t) == t)
    }

    @Test func commonSpeakerTicksOnlyWhenAllAgree() {
        let t = transcript(["S1", "S1", "S2"])

        #expect(TranscriptSpeakers.commonSpeaker(of: [0, 1], in: t) == "S1")
        #expect(TranscriptSpeakers.commonSpeaker(of: [1, 2], in: t) == nil)
        #expect(TranscriptSpeakers.commonSpeaker(of: [99], in: t) == nil)
        #expect(TranscriptSpeakers.commonSpeaker(of: [0, 99], in: t) == "S1")
    }

    @Test func orderAndHeaderLeaveOutYouWithoutLines() {
        let t = transcript(["S1"])

        #expect(TranscriptSpeakers.ordered(in: t) == ["S1"])
        #expect(TranscriptSpeakers.headerSpeakers(meeting: meeting(attendees: []), transcript: t, userName: "Me") == [SpeakerChoice(label: "S1", title: "S1")])
    }

    @Test func menuOffersYouAlwaysAndTellsTwinsApart() {
        let t = Transcript(segments: ["S1", "S2", "S1"].enumerated().map { segment($0.offset, $0.element, track: .mic) }, language: nil)
        let names = ["S1": "Sarah", "S2": "Sarah", "S3": "Old"]

        #expect(TranscriptSpeakers.menuChoices(transcript: t, speakerNames: names, userName: "Me") == [
            SpeakerChoice(label: "you", title: "Me"), SpeakerChoice(label: "S1", title: "Sarah (S1)"), SpeakerChoice(label: "S2", title: "Sarah (S2)"),
        ])
        #expect(TranscriptSpeakers.menuChoices(transcript: t, speakerNames: ["S1": "Me"], userName: "Me") == [
            SpeakerChoice(label: "you", title: "Me (you)"), SpeakerChoice(label: "S1", title: "Me (S1)"), SpeakerChoice(label: "S2", title: "S2"),
        ])
        #expect(TranscriptSpeakers.menuChoices(transcript: transcript(["you", "S1", "you"]), speakerNames: [:], userName: "Me") == [
            SpeakerChoice(label: "you", title: "Me"), SpeakerChoice(label: "S1", title: "S1"),
        ])
    }

    @Test func headerSpeakersOnlyWithoutPeople() {
        let t = transcript(["S2", "you", "S1"])
        let names = ["S2": "Bea"]
        let expected = [
            SpeakerChoice(label: "you", title: "Me"), SpeakerChoice(label: "S1", title: "S1"), SpeakerChoice(label: "S2", title: "Bea"),
        ]
        var named = meeting(attendees: [])
        named.speakerNames = names
        var withRoom = meeting(attendees: [Attendee(name: "Room 1", email: "room@example.com", type: "resource")])
        withRoom.speakerNames = names
        var withPerson = meeting(attendees: [Attendee(name: "Ann", email: "ann@example.com")])
        withPerson.speakerNames = names

        #expect(TranscriptSpeakers.headerSpeakers(meeting: named, transcript: t, userName: "Me") == expected)
        #expect(TranscriptSpeakers.headerSpeakers(meeting: withRoom, transcript: t, userName: "Me") == expected)
        #expect(TranscriptSpeakers.headerSpeakers(meeting: withPerson, transcript: t, userName: "Me") == [])
        #expect(TranscriptSpeakers.headerSpeakers(meeting: named, transcript: nil, userName: "Me") == [])
    }
}
