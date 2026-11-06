import Testing
@testable import MuninnCore

@Test func contrastMaths() {
    #expect(abs(Contrast.ratio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)) - 21) < 0.01)
    #expect(abs(Contrast.luminance(RGB(hex: 0xFFFFFF)) - 1) < 0.0001)
}

@Test(arguments: [Palette.accentLight, Palette.attentionTextLight, Palette.problemLight, Palette.successLight])
func lightRoleTextMeetsAA(_ colour: RGB) {
    #expect(Contrast.ratio(colour, Palette.contentLight) >= 4.5)
}

@Test(arguments: [Palette.accentDark, Palette.attentionDark, Palette.problemDark, Palette.successDark])
func darkRoleTextMeetsAA(_ colour: RGB) {
    #expect(Contrast.ratio(colour, Palette.contentDark) >= 4.5)
}

@Test func tertiaryTextMeetsAAOnContent() {
    #expect(Contrast.ratio(Palette.tertiaryTextLight, Palette.contentLight) >= 4.5)
    #expect(Contrast.ratio(Palette.tertiaryTextDark, Palette.contentDark) >= 4.5)
}

@Test func primaryAndSecondaryTextMeetAAEverywhere() {
    let lightBackgrounds = [Palette.contentLight] + [Palette.accentLight, Palette.attentionFillLight, Palette.problemLight, Palette.successLight]
        .map { Contrast.composite($0, alpha: Palette.softLight, over: Palette.contentLight) }
        + [Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentLight)]
    let darkBackgrounds = [Palette.contentDark] + [Palette.accentDark, Palette.attentionDark, Palette.problemDark, Palette.successDark]
        .map { Contrast.composite($0, alpha: Palette.softDark, over: Palette.contentDark) }
        + [Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentDark)]

    for background in lightBackgrounds {
        let primary = Contrast.composite(RGB(hex: 0x000000), alpha: Palette.primaryTextAlpha, over: background)
        #expect(Contrast.ratio(primary, background) >= 4.5)
        #expect(Contrast.ratio(Palette.secondaryTextLight, background) >= 4.5)
    }
    for background in darkBackgrounds {
        let primary = Contrast.composite(RGB(hex: 0xFFFFFF), alpha: Palette.primaryTextAlpha, over: background)
        #expect(Contrast.ratio(primary, background) >= 4.5)
        #expect(Contrast.ratio(Palette.secondaryTextDark, background) >= 4.5)
    }
}

@Test func accentTextMeetsAAOnEverySoftFill() {
    let lightFills = [Palette.accentLight, Palette.attentionFillLight, Palette.problemLight, Palette.successLight]
        .map { Contrast.composite($0, alpha: Palette.softLight, over: Palette.contentLight) }
        + [Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentLight)]
    let darkFills = [Palette.accentDark, Palette.attentionDark, Palette.problemDark, Palette.successDark]
        .map { Contrast.composite($0, alpha: Palette.softDark, over: Palette.contentDark) }
        + [Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentDark)]

    for fill in lightFills { #expect(Contrast.ratio(Palette.accentLight, fill) >= 4.5) }
    for fill in darkFills { #expect(Contrast.ratio(Palette.accentDark, fill) >= 4.5) }
}

@Test func speakerColoursMeetAA() {
    let lightSoft = Contrast.composite(Palette.accentLight, alpha: Palette.softLight, over: Palette.contentLight)
    let darkSoft = Contrast.composite(Palette.accentDark, alpha: Palette.softDark, over: Palette.contentDark)

    #expect(Palette.speakerLight.count == SpeakerColours.count)
    #expect(Palette.speakerDark.count == SpeakerColours.count)
    for colour in Palette.speakerLight {
        #expect(Contrast.ratio(colour, Palette.contentLight) >= 4.5)
        #expect(Contrast.ratio(colour, lightSoft) >= 4.5)
    }
    for colour in Palette.speakerDark {
        #expect(Contrast.ratio(colour, Palette.contentDark) >= 4.5)
        #expect(Contrast.ratio(colour, darkSoft) >= 4.5)
    }
}

@Test func primaryTextMeetsAAOnTheCurrentWord() {
    let light = Contrast.composite(Palette.accentLight, alpha: Palette.midLight, over: Palette.contentLight)
    let dark = Contrast.composite(Palette.accentDark, alpha: Palette.midDark, over: Palette.contentDark)
    let lightText = Contrast.composite(RGB(hex: 0x000000), alpha: Palette.primaryTextAlpha, over: light)
    let darkText = Contrast.composite(RGB(hex: 0xFFFFFF), alpha: Palette.primaryTextAlpha, over: dark)

    #expect(Contrast.ratio(lightText, light) >= 4.5)
    #expect(Contrast.ratio(darkText, dark) >= 4.5)
}

@Test func speakerIndicesFollowFirstAppearance() {
    func segment(_ id: Int, _ speaker: String) -> Segment {
        Segment(id: id, track: .system, speaker: speaker, start: Double(id), end: Double(id) + 1, text: "", words: [])
    }
    let transcript = Transcript(
        segments: ["S2", "you", "S1", "S3", "S4", "S5", "S6", "S2"].enumerated().map { segment($0.offset, $0.element) },
        language: nil
    )

    #expect(SpeakerColours.indices(for: transcript) == ["you": 0, "S2": 1, "S1": 2, "S3": 3, "S4": 4, "S5": 5, "S6": 1])
}

@Test func personIndexIsStable() {
    #expect(SpeakerColours.personIndex(name: "Ann Example", email: "") == 2)
    #expect(SpeakerColours.personIndex(name: "ANN EXAMPLE ", email: "") == 2)
    #expect(SpeakerColours.personIndex(name: "Bob Example", email: "") == 4)
    #expect(SpeakerColours.personIndex(name: "", email: "ann.example@example.com") == 3)
}

@Test func tertiaryAndAttentionTextMeetAAOnTheirChipFills() {
    let lightNeutral = Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentLight)
    let darkNeutral = Contrast.composite(Palette.neutral, alpha: Palette.neutralSoftAlpha, over: Palette.contentDark)
    let lightAttention = Contrast.composite(Palette.attentionFillLight, alpha: Palette.softLight, over: Palette.contentLight)
    let darkAttention = Contrast.composite(Palette.attentionDark, alpha: Palette.softDark, over: Palette.contentDark)

    #expect(Contrast.ratio(Palette.tertiaryTextLight, lightNeutral) >= 4.5)
    #expect(Contrast.ratio(Palette.tertiaryTextDark, darkNeutral) >= 4.5)
    #expect(Contrast.ratio(Palette.attentionTextLight, lightAttention) >= 4.5)
    #expect(Contrast.ratio(Palette.attentionDark, darkAttention) >= 4.5)
}
