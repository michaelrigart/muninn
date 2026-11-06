import Foundation
import Testing
@testable import MuninnCore

struct WordAlignmentTests {
    private func words(_ texts: [String]) -> [Word] {
        texts.enumerated().map { Word(text: $1, start: Double($0), end: Double($0) + 1) }
    }

    @Test func tokensMatchWordsOneToOne() {
        let result = WordAlignment.tokenWords(text: "we ship friday", words: words(["we", "ship", "friday"]))
        #expect(result == [0, 1, 2])
    }

    @Test func mismatchedTokensAlignByForm() {
        let result = WordAlignment.tokenWords(
            text: "Well, we ship it Friday.", words: words(["well", "we", "ship", "friday"]))
        #expect(result == [0, 1, 2, nil, 3])
    }

    @Test func noWordsMeansNoTimings() {
        #expect(WordAlignment.tokenWords(text: "hello there", words: []) == [nil, nil])
    }

    @Test func cleanTokensMapToVerbatimTokens() {
        let result = ChangeView.alignment(verbatim: "um so we uh ship it", clean: "So we ship it.")
        #expect(result == [1, 2, 4, 5])
    }

    @Test func cleanWordsNotInTheVerbatimMapToNothing() {
        let result = ChangeView.alignment(verbatim: "we ship friday", clean: "We ship on Friday")
        #expect(result == [0, 1, nil, 2])
    }

    @Test func punctuationTokensMapToNothing() {
        let result = ChangeView.alignment(verbatim: "yes — fine", clean: "Yes — fine.")
        #expect(result == [0, nil, 2])
    }

    @Test func aLongInputAlignsInWindowsWithEveryKeptTokenPairedToItsOwn() {
        let verbatim = (0..<10_000).map { "w\($0)" }
        let removedRuns = [100..<103, 1_400..<1_500, 2_990..<3_010, 8_000..<8_001]
        let kept = verbatim.indices.filter { index in !removedRuns.contains { $0.contains(index) } }
        let started = Date()
        let result = WordAlignment.pairs(verbatim, kept.map { verbatim[$0] })
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(result.map(\.0) == kept)
        #expect(result.map(\.1) == Array(kept.indices))
    }
}
