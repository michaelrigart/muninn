import Testing
@testable import MuninnCore

struct CleanupTests {
    static let examples = [
        "Euh, ja, dus we could do the cutover on the on the 14th, hmm, if the backup is done by then.",
        "Allez, bon, we doen dat.",
        "I mean, it, it should.",
        "we doen dat morgen",
    ]

    @Test func cleansFillersAndRepeats() {
        let input = "Euh, ja, dus we could do the cutover on the on the 14th, hmm, if the backup is done by then."
        #expect(RuleCleaner.clean(input) == "Ja, dus we could do the cutover on the 14th, if the backup is done by then.")
    }

    @Test func keepsMeaningfulWords() {
        #expect(RuleCleaner.clean("Allez, bon, we doen dat.") == "Allez, bon, we doen dat.")
    }

    @Test func verifierAcceptsDeletions() {
        #expect(CleanupVerifier.isDeletionOnly(verbatim: "I mean, it, it should.", clean: "It should."))
    }

    @Test func verifierRejectsRephrase() {
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "we doen dat morgen", clean: "we doen het morgen"))
    }

    @Test func ruleOutputAlwaysVerifies() {
        for example in Self.examples {
            #expect(CleanupVerifier.isDeletionOnly(verbatim: example, clean: RuleCleaner.clean(example)))
        }
    }

    @Test func changeViewMarksRemoved() {
        let tokens = ChangeView.tokens(verbatim: "Euh, ja, dus we", clean: "Ja, dus we")
        #expect(tokens.map(\.removed) == [true, false, false, false])
        #expect(tokens.map(\.text) == ["Euh,", "ja,", "dus", "we"])
    }

    @Test func ruleCleanerTranscript() async throws {
        let segments = [
            Segment(id: 3, track: .mic, speaker: "you", start: 0, end: 1, text: "Euh, ja.", words: []),
            Segment(id: 7, track: .system, speaker: "A", start: 1, end: 2, text: "We doen dat.", words: []),
        ]
        let clean = try await RuleTranscriptCleaner().clean(Transcript(segments: segments, language: "nl"))
        #expect(clean.segments.map(\.id) == [3, 7])
        #expect(clean.segments.map(\.text) == ["Ja.", "We doen dat."])
    }

    @Test func repeatsNeverMergeSentences() {
        #expect(RuleCleaner.clean("We do it. It works.") == "We do it. It works.")
        #expect(RuleCleaner.clean("Klopt dat? Dat klopt.") == "Klopt dat? Dat klopt.")
    }

    @Test func keepsMeaningBearingRepeats() {
        #expect(RuleCleaner.clean("Ik denk dat dat klopt.") == "Ik denk dat dat klopt.")
        #expect(RuleCleaner.clean("Nous nous voyons demain.") == "Nous nous voyons demain.")
        #expect(RuleCleaner.clean("Het nummer is 0470 12 12 34.") == "Het nummer is 0470 12 12 34.")
    }

    @Test func fillerPunctuationNotDoubled() {
        #expect(RuleCleaner.clean("Done. Euh.") == "Done.")
        #expect(RuleCleaner.clean("Is dat zo? Euh?") == "Is dat zo?")
    }

    @Test func capitalisesOnlyLetters() {
        #expect(RuleCleaner.clean("3rd quarter looks good.") == "3rd quarter looks good.")
    }

    @Test func survivorInheritsCapital() {
        #expect(RuleCleaner.clean("Ok. The, the plan works.") == "Ok. The plan works.")
    }

    @Test func keepsEhBien() {
        #expect(RuleCleaner.clean("Eh bien, on y va.") == "Eh bien, on y va.")
    }

    @Test func verifierGuardsNumbersAndNegations() {
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "about 1.5 million", clean: "about 15 million"))
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "we doen dat niet", clean: "we doen dat"))
    }

    @Test func punctuationTokensNeverRemoved() {
        let tokens = ChangeView.tokens(verbatim: "a - b", clean: "a b")
        #expect(tokens.map(\.removed) == [false, false, false])
    }

    @Test func sentenceEndGuardBlocksCollapse() {
        #expect(RuleCleaner.clean("We do it. Do it now.") == "We do it. Do it now.")
    }

    @Test func digitGuardBlocksCollapse() {
        #expect(RuleCleaner.clean("Bel 0470 12 34 12 34.") == "Bel 0470 12 34 12 34.")
    }

    @Test func protectedWordGuardBlocksCollapse() {
        let input = "No, no, not, not now."
        let output = RuleCleaner.clean(input)
        #expect(CleanupVerifier.isDeletionOnly(verbatim: input, clean: output))
        #expect(Tokenizer.normalizedWords(output).filter { $0 == "not" }.count == 2)
    }

    @Test func fillerAfterColonOrSemicolonAddsNoPunctuation() {
        #expect(RuleCleaner.clean("Namely; euh.") == "Namely;")
    }

    @Test func verifierProtectsContractedNegations() {
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "it isn't done", clean: "it done"))
    }

    @Test func verifierKeepsSignsAndUnits() {
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "the delta is -500", clean: "the delta is 500"))
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "we grew 5% last year", clean: "we grew 5 last year"))
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "it costs \u{20AC}5", clean: "it costs 5"))
        #expect(!CleanupVerifier.isDeletionOnly(verbatim: "call +32 now", clean: "call 32 now"))
        #expect(CleanupVerifier.isDeletionOnly(verbatim: "well, -500", clean: "-500"))
        #expect(CleanupVerifier.isDeletionOnly(verbatim: "euh 5% and (-5)", clean: "5% and (-5)"))
    }

    @Test func tokenizerNormalisesSignsUnitsAndHyphens() {
        #expect(Tokenizer.normalize("-500,") == "-500")
        #expect(Tokenizer.normalize("(-5)") == "-5")
        #expect(Tokenizer.normalize("5%.") == "5%")
        #expect(Tokenizer.normalize("$12") == "$12")
        #expect(Tokenizer.normalize("-well") == "well")
        #expect(Tokenizer.normalize("5-6") == "5-6")
        #expect(Tokenizer.normalize("%") == "")
    }
}
