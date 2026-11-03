import Foundation
import Testing
import MuninnCore
@testable import MuninnSpeech

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> Word {
    Word(text: text, start: start, end: end)
}

@Test func wordsJoinSubwordTokens() {
    let tokens = [
        TimedToken(text: "▁hel", start: 0.0, end: 0.2),
        TimedToken(text: "lo", start: 0.2, end: 0.5),
        TimedToken(text: "▁world", start: 0.6, end: 1.0),
    ]
    let words = SegmentBuilder.words(from: tokens)
    #expect(words == [word("hello", 0.0, 0.5), word("world", 0.6, 1.0)])
}

@Test func wordsTreatLeadingSpaceAsBoundaryAndSkipEmpty() {
    let tokens = [
        TimedToken(text: " good", start: 0.0, end: 0.3),
        TimedToken(text: " ", start: 0.3, end: 0.35),
        TimedToken(text: " day", start: 0.4, end: 0.7),
        TimedToken(text: ".", start: 0.7, end: 0.8),
    ]
    let words = SegmentBuilder.words(from: tokens)
    #expect(words == [word("good", 0.0, 0.3), word("day.", 0.4, 0.8)])
}

@Test func segmentsSplitOnPause() {
    let words = [word("one", 0, 0.5), word("two", 0.6, 1.0), word("three", 2.5, 3.0)]
    let segments = SegmentBuilder.segments(from: words, track: .mic)
    #expect(segments.map(\.text) == ["one two", "three"])
    #expect(segments.map(\.id) == [0, 1])
    #expect(segments[0].start == 0 && segments[0].end == 1.0)
    #expect(segments[1].start == 2.5 && segments[1].end == 3.0)
    #expect(segments.allSatisfy { $0.speaker == "" && $0.track == .mic })
    #expect(segments[0].words == Array(words[0...1]))
}

@Test func segmentsSplitOnSentenceEnd() {
    let words = [word("Hi.", 0, 0.4), word("How", 0.5, 0.8), word("are", 0.8, 1.0), word("you?", 1.0, 1.3), word("Fine!", 1.4, 1.8), word("ok", 1.9, 2.0)]
    let segments = SegmentBuilder.segments(from: words, track: .system)
    #expect(segments.map(\.text) == ["Hi.", "How are you?", "Fine!", "ok"])
    #expect(segments.map(\.id) == [0, 1, 2, 3])
}

@Test func segmentsCapDuration() {
    let words = (0..<10).map { word("w\($0)", Double($0), Double($0) + 0.9) }
    let segments = SegmentBuilder.segments(from: words, track: .mic, pauseGap: 5, maxDuration: 4)
    #expect(segments.map(\.text) == ["w0 w1 w2 w3", "w4 w5 w6 w7", "w8 w9"])
    #expect(segments.allSatisfy { $0.end - $0.start <= 4 })
}

@Test func segmentsOfNoWordsAreEmpty() {
    #expect(SegmentBuilder.segments(from: [], track: .mic).isEmpty)
}

@Test func realignKeepsTimingsWhenTextIsUnchanged() {
    let words = [word("we", 0, 0.2), word("use", 0.2, 0.5), word("kubernetes", 0.5, 1.2)]
    #expect(SegmentBuilder.realign(words, to: "we use kubernetes") == words)
}

@Test func realignSpreadsReplacedWordsOverTheirSpan() {
    let words = [word("we", 0, 0.2), word("use", 0.2, 0.5), word("cooper", 0.5, 0.9), word("nettys", 0.9, 1.3), word("daily", 1.3, 1.8)]
    let aligned = SegmentBuilder.realign(words, to: "we use Kubernetes daily")
    #expect(aligned == [word("we", 0, 0.2), word("use", 0.2, 0.5), word("Kubernetes", 0.5, 1.3), word("daily", 1.3, 1.8)])
}

@Test func realignSplitsAMultiWordReplacementEvenly() {
    let words = [word("open", 0, 0.5), word("a", 0.5, 1.0)]
    let aligned = SegmentBuilder.realign(words, to: "Open AI")
    #expect(aligned.map(\.text) == ["Open", "AI"])
    #expect(aligned[0].start == 0 && aligned[1].end == 1.0)
}

@Test func factoryDispatchesEveryModel() {
    for id in SpeechModelID.allCases {
        let transcriber = TranscriberFactory.make(id)
        switch id {
        case .whisperLargeV3Turbo:
            #expect(transcriber is WhisperKitTranscriber)
        case .parakeetV3, .parakeetUltra:
            #expect(transcriber is ParakeetTranscriber)
        }
    }
    #expect(SpeechModelID.allCases.count == 3)
    #expect(SpeechModelID(rawValue: "parakeet-ultra") == .parakeetUltra)
}

@Test func parakeetTranscriberThrowsForAWhisperModel() async {
    let transcriber = ParakeetTranscriber(model: .whisperLargeV3Turbo)
    await #expect(throws: SpeechError.unsupportedModel(.whisperLargeV3Turbo)) {
        _ = try await transcriber.transcribe(audio: URL(fileURLWithPath: "/nonexistent.wav"), track: .mic, vocabulary: [])
    }
}

@Test func realignKeepsUntouchedTimingsBetweenDistantCorrections() {
    let words = [word("acme", 1, 1.5), word("hello", 600, 600.4), word("acme", 3000, 3000.5)]
    let aligned = SegmentBuilder.realign(words, to: "Acme hello Acme")
    #expect(aligned == [word("Acme", 1, 1.5), word("hello", 600, 600.4), word("Acme", 3000, 3000.5)])
}

@Test func realignHandlesInsertionsAndDeletions() {
    let words = [word("a", 0, 1), word("b", 1, 2), word("c", 2, 3)]
    #expect(SegmentBuilder.realign(words, to: "a c") == [word("a", 0, 1), word("c", 2, 3)])
    let inserted = SegmentBuilder.realign(words, to: "a b x c")
    #expect(inserted.map(\.text) == ["a", "b", "x", "c"])
    #expect(inserted[0] == words[0] && inserted[1] == words[1] && inserted[3] == words[2])
}

@Test func piecesWithoutWordsBecomeWordlessSegments() {
    let pieces = [
        SegmentBuilder.Piece(text: "hello there.", start: 0, end: 2, words: [word("hello", 0, 1), word("there.", 1, 2)]),
        SegmentBuilder.Piece(text: " no alignment ", start: 2, end: 5, words: []),
        SegmentBuilder.Piece(text: "", start: 5, end: 6, words: []),
        SegmentBuilder.Piece(text: "bye", start: 6, end: 7, words: [word("bye", 6, 7)]),
    ]
    let segments = SegmentBuilder.segments(from: pieces, track: .system)
    #expect(segments.map(\.text) == ["hello there.", "no alignment", "bye"])
    #expect(segments.map(\.id) == [0, 1, 2])
    #expect(segments[1].words.isEmpty && segments[1].start == 2 && segments[1].end == 5)
}

@Test func promptBuilderStopsBeforeTheTokenLimit() {
    let encode: (String) -> [Int] = { Array(repeating: 1, count: $0.count) }
    let result = PromptBuilder.tokens(for: ["abc", "def", "ghijkl"], limit: 12, encode: encode)
    #expect(result.tokens.count == 4 + 5)
    #expect(result.dropped == 1)
    let all = PromptBuilder.tokens(for: ["abc"], limit: 100, encode: encode)
    #expect(all.dropped == 0 && all.tokens.count == 4)
}

private actor LoadCounter {
    var loads = 0
    func next() -> Int { loads += 1; return loads }
}

@Test func keyedLoadOnceSharesConcurrentLoadsAndRetriesFailures() async throws {
    let cache = KeyedLoadOnce<String, Int>()
    let counter = LoadCounter()
    let values = try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<5 {
            group.addTask {
                try await cache.value(for: "k") {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    return await counter.next()
                }
            }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(values == [1, 1, 1, 1, 1])
    #expect(await counter.loads == 1)

    struct Boom: Error {}
    await #expect(throws: Boom.self) { try await cache.value(for: "bad") { throw Boom() } }
    #expect(try await cache.value(for: "bad") { 7 } == 7)
}

@Test func liveTranscriberRejectsAWhisperModelAndEndsItsStream() async {
    let live = ParakeetLiveTranscriber(model: .whisperLargeV3Turbo)
    await #expect(throws: SpeechError.unsupportedModel(.whisperLargeV3Turbo)) { try await live.start() }
    await #expect(throws: SpeechError.alreadyStarted) { try await live.start() }
    await live.feed(LiveAudioChunk(track: .mic, samples: [0, 0], time: 0))
    await live.finish()
    var count = 0
    for await _ in live.updates { count += 1 }
    #expect(count == 0)
}

@Test func realignMapsEqualSizedHunksOneToOne() {
    let words = [word("a", 0, 1), word("b", 1, 5), word("c", 5, 6), word("d", 6, 7)]
    let aligned = SegmentBuilder.realign(words, to: "a X Y d")
    #expect(aligned == [word("a", 0, 1), word("X", 1, 5), word("Y", 5, 6), word("d", 6, 7)])
}

@Test func whisperPromptLimitMatchesWhisperKitsCap() {
    #expect(WhisperKitTranscriber.promptTokenLimit == 111)
}

private struct LoaderFailed: Error {}

@Test func finishWhileStartingStopsStartAndEndsTheStream() async {
    let live = ParakeetLiveTranscriber(model: .parakeetV3) { _ in
        try await Task.sleep(nanoseconds: 200_000_000)
        throw LoaderFailed()
    }
    let starting = Task { try await live.start() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    await live.finish()
    await #expect(throws: LoaderFailed.self) { try await starting.value }
    var count = 0
    for await _ in live.updates { count += 1 }
    #expect(count == 0)
    await #expect(throws: SpeechError.alreadyStarted) { try await live.start() }
}
