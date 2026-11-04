import Foundation
import Testing
@testable import MuninnCore

struct TranscriptLayoutTests {
    private let transcript = Transcript(segments: [
        Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 4, text: "um we uh ship friday",
                words: [Word(text: "um", start: 0, end: 0.5), Word(text: "we", start: 0.6, end: 0.9), Word(text: "uh", start: 1, end: 1.4),
                        Word(text: "ship", start: 1.5, end: 2), Word(text: "friday", start: 2.2, end: 3.8)]),
        Segment(id: 1, track: .system, speaker: "S1", start: 3, end: 8, text: "sounds good",
                words: [Word(text: "sounds", start: 3.2, end: 3.9), Word(text: "good", start: 4, end: 7.5)]),
        Segment(id: 2, track: .system, speaker: "S1", start: 10, end: 14, text: "next topic", words: []),
    ], language: "en")
    private let clean = CleanTranscript(segments: [
        CleanSegment(id: 0, text: "We ship Friday."), CleanSegment(id: 1, text: "Sounds good."), CleanSegment(id: 2, text: "Next topic."),
    ])

    private func layout(_ mode: TranscriptMode, clean: CleanTranscript? = nil, flags: [Flag] = []) -> TranscriptLayout {
        TranscriptLayout.make(transcript: transcript, clean: clean ?? self.clean, mode: mode, speakerNames: [:], userName: "Ann", flags: flags)
    }

    private func substring(_ layout: TranscriptLayout, _ range: NSRange?) -> String? {
        range.map { (layout.string as NSString).substring(with: $0) }
    }

    @Test func verbatimLayoutPlacesSpeakersAndTimestamps() {
        let layout = layout(.verbatim)
        #expect(layout.string == "\tAnn\n00:00\tum we uh ship friday\n\tS1\n00:03\tsounds good\n00:10\tnext topic\n")
        #expect(layout.speakerLines.map(\.name) == ["Ann", "S1"])
        #expect(layout.speakerLines.map { substring(layout, $0.range) } == ["Ann", "S1"])
        #expect(substring(layout, layout.segments[0].timestamp) == "00:00")
        #expect(substring(layout, layout.segments[0].text) == "um we uh ship friday")
        #expect(substring(layout, layout.segments[0].line) == "00:00\tum we uh ship friday")
    }

    @Test func cleanModeSkipsRemovedWords() {
        let layout = layout(.clean)
        let segment = layout.segments[0]
        #expect(substring(layout, segment.text) == "We ship Friday.")
        #expect(segment.words.map { substring(layout, $0.range) } == [nil, "We", nil, "ship", "Friday."])
        #expect(segment.words.map(\.start) == [0, 0.6, 1, 1.5, 2.2])
    }

    @Test func changesModeMarksRemovedTokens() {
        let layout = layout(.changes)
        let segment = layout.segments[0]
        #expect(substring(layout, segment.text) == "um we uh ship friday")
        #expect(segment.removed.compactMap { substring(layout, $0) } == ["um", "uh"])
        #expect(segment.words.allSatisfy { $0.range != nil })
    }

    @Test func positionPicksTheWordBeingSpoken() {
        let layout = layout(.verbatim)
        #expect(layout.position(at: 1.6) == ReadAlongPosition(segment: 0, word: 3))
        let position = layout.position(at: 1.45)
        #expect(position == ReadAlongPosition(segment: 0, word: 2))
        #expect(substring(layout, layout.segments[0].words[2].range) == "uh")
    }

    @Test func cleanModeHighlightsNothingDuringARemovedWord() {
        let layout = layout(.clean)
        #expect(layout.position(at: 1.2) == ReadAlongPosition(segment: 0, word: 2))
        #expect(layout.segments[0].words[2].range == nil)
    }

    @Test func overlappingSegmentsPickTheLatestStart() {
        #expect(layout(.verbatim).position(at: 3.5) == ReadAlongPosition(segment: 1, word: 0))
    }

    @Test func gapHighlightsNothing() {
        #expect(layout(.verbatim).position(at: 9) == nil)
    }

    @Test func aLongEarlierSegmentDoesNotHideALaterGap() {
        let long = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 20, text: "long one", words: []),
            Segment(id: 1, track: .mic, speaker: "you", start: 2, end: 3, text: "short one", words: []),
        ], language: "en")
        let layout = TranscriptLayout.make(transcript: long, clean: nil, mode: .verbatim, speakerNames: [:], userName: "Ann", flags: [])
        #expect(layout.position(at: 2.5) == ReadAlongPosition(segment: 1, word: nil))
        #expect(layout.position(at: 5) == ReadAlongPosition(segment: 0, word: nil))
        #expect(layout.position(at: 25) == nil)
    }

    @Test func segmentWithoutWordsHighlightsWhole() {
        #expect(layout(.verbatim).position(at: 11) == ReadAlongPosition(segment: 2, word: nil))
    }

    @Test func cleanModeBeforeTheFirstKeptWord() {
        let layout = layout(.clean)
        #expect(layout.position(at: 0.2) == ReadAlongPosition(segment: 0, word: 0))
        #expect(layout.segments[0].words[0].range == nil)
    }

    @Test func seekTimeFromAClick() throws {
        let layout = layout(.verbatim)
        let ship = try #require(layout.segments[0].words[3].range)
        #expect(layout.seekTime(atOffset: ship.location + 2) == 1.5)
        #expect(layout.seekTime(atOffset: layout.segments[1].timestamp.location + 1) == 3)
        let speaker = layout.speakerLines[1]
        #expect(layout.seekTime(atOffset: speaker.range.location + 1) == nil)
        #expect(layout.speakerLine(atOffset: speaker.range.location + 1)?.speaker == "S1")
        #expect(layout.speakerLine(atOffset: layout.segments[1].timestamp.location) == nil)
    }

    @Test func flaggedSegmentsCarryAMarker() {
        let layout = layout(.verbatim, flags: [Flag(offset: 11)])
        let segment = layout.segments[2]
        #expect(substring(layout, segment.line)?.hasPrefix("00:10 \u{2691}\u{FE0E}\t") == true)
        #expect(substring(layout, segment.flag) == "\u{2691}\u{FE0E}")
        #expect(layout.segments[0].flag == nil)
    }

    @Test func emptyCleanTextLeavesTheSegmentOut() {
        let blank = CleanTranscript(segments: [CleanSegment(id: 0, text: "We ship Friday."), CleanSegment(id: 1, text: ""), CleanSegment(id: 2, text: "Next topic.")])
        let layout = layout(.clean, clean: blank)
        #expect(layout.segments.map(\.segmentID) == [0, 2])
        #expect(layout.segmentIndex(forSegmentID: 2) == 1)
        #expect(layout.segmentIndex(forSegmentID: 1) == nil)
    }

    @Test func rangesStayExactWithNonBMPCharacters() throws {
        let emoji = Transcript(segments: [
            Segment(id: 0, track: .system, speaker: "S1", start: 0, end: 4, text: "great party\u{1F389} idea team",
                    words: [Word(text: "great", start: 0, end: 1), Word(text: "party", start: 1, end: 2),
                            Word(text: "idea", start: 2, end: 3), Word(text: "team", start: 3, end: 4)]),
            Segment(id: 1, track: .system, speaker: "S2", start: 5, end: 8, text: "r\u{00E9}sum\u{00E9} ok",
                    words: [Word(text: "r\u{00E9}sum\u{00E9}", start: 5, end: 6), Word(text: "ok", start: 6, end: 7)]),
        ], language: "en")
        let names = ["S1": "Zo\u{00EB} \u{1F600}"]
        for mode in TranscriptMode.allCases {
            let layout = TranscriptLayout.make(transcript: emoji, clean: nil, mode: mode, speakerNames: names, userName: "Ann", flags: [Flag(offset: 5)])
            let string = layout.string as NSString
            #expect(layout.speakerLines.map { string.substring(with: $0.range) } == ["Zo\u{00EB} \u{1F600}", "S2"])
            #expect(layout.segments[0].words.map { $0.range.map { string.substring(with: $0) } } == ["great", "party\u{1F389}", "idea", "team"])
            #expect(layout.segments[1].words.map { $0.range.map { string.substring(with: $0) } } == ["r\u{00E9}sum\u{00E9}", "ok"])
            #expect(string.substring(with: layout.segments[1].timestamp) == "00:05")
            #expect(string.substring(with: try #require(layout.segments[1].flag)) == "\u{2691}\u{FE0E}")
            let idea = try #require(layout.segments[0].words[2].range)
            #expect(layout.seekTime(atOffset: idea.location) == 2)
        }
    }

    @Test func whitespaceInShownTextCollapsesToOneLinePerSegment() {
        let spread = CleanTranscript(segments: [CleanSegment(id: 0, text: "We ship\nFriday.\tOK"), CleanSegment(id: 1, text: "Sounds good."), CleanSegment(id: 2, text: "Next topic.")])
        let layout = layout(.clean, clean: spread)
        #expect(substring(layout, layout.segments[0].text) == "We ship Friday. OK")
        #expect(layout.string.filter { $0 == "\n" }.count == 5)
        #expect(layout.string.filter { $0 == "\t" }.count == 5)
    }

    @Test func segmentsStartingTogetherPickTheLaterInTheList() {
        let together = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 5, text: "hello", words: []),
            Segment(id: 1, track: .system, speaker: "S1", start: 0, end: 5, text: "hi there", words: []),
        ], language: "en")
        let layout = TranscriptLayout.make(transcript: together, clean: nil, mode: .verbatim, speakerNames: [:], userName: "Ann", flags: [])
        #expect(layout.position(at: 2) == ReadAlongPosition(segment: 1, word: nil))
    }

    @Test func cleanModeWithoutCleanTextMapsTokensLikeVerbatim() {
        let dots = Transcript(segments: [
            Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 3, text: "wait \u{2026} done",
                    words: [Word(text: "wait", start: 0, end: 1), Word(text: "\u{2026}", start: 1, end: 2), Word(text: "done", start: 2, end: 3)]),
        ], language: "en")
        for clean in [nil, CleanTranscript(segments: [])] {
            let layout = TranscriptLayout.make(transcript: dots, clean: clean, mode: .clean, speakerNames: [:], userName: "Ann", flags: [])
            #expect(layout.segments[0].words.map { substring(layout, $0.range) } == ["wait", "\u{2026}", "done"])
        }
    }

    @Test func previousStartGoesBackWithinTheFirstSecond() {
        let timeline = SegmentTimeline(transcript: transcript)
        #expect(timeline.previousStart(before: 10.5) == 3)
        #expect(timeline.previousStart(before: 12) == 10)
        #expect(timeline.previousStart(before: 0.5) == 0)
        #expect(timeline.nextStart(after: 3) == 10)
        #expect(timeline.nextStart(after: 10) == nil)
    }
}
