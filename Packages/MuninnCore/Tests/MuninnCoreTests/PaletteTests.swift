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
