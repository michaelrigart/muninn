import AppKit
import MuninnCore
import SwiftUI

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    static let chip: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
}

enum Theme {
    static let accent = dynamic(light: Palette.accentLight, dark: Palette.accentDark)
    static let accentSoft = Color(nsColor: AppKit.accentSoft)
    static let accentMid = Color(nsColor: AppKit.accentMid)
    static let attentionText = Color(nsColor: AppKit.attentionText)
    static let attentionFill = dynamic(light: Palette.attentionFillLight, dark: Palette.attentionDark)
    static let attentionSoft = dynamic(light: Palette.attentionFillLight, lightAlpha: Palette.softLight, dark: Palette.attentionDark, darkAlpha: Palette.softDark)
    static let problem = dynamic(light: Palette.problemLight, dark: Palette.problemDark)
    static let problemSoft = dynamic(light: Palette.problemLight, lightAlpha: Palette.softLight, dark: Palette.problemDark, darkAlpha: Palette.softDark)
    static let success = dynamic(light: Palette.successLight, dark: Palette.successDark)
    static let successSoft = dynamic(light: Palette.successLight, lightAlpha: Palette.softLight, dark: Palette.successDark, darkAlpha: Palette.softDark)
    static let neutralSoft = dynamic(light: Palette.neutral, lightAlpha: Palette.neutralSoftAlpha, dark: Palette.neutral, darkAlpha: Palette.neutralSoftAlpha)
    static let recording = dynamic(light: Palette.recording, dark: Palette.recording)

    static let primaryText = Color(nsColor: AppKit.primaryText)
    static let secondaryText = Color(nsColor: AppKit.secondaryText)
    static let tertiaryText = Color(nsColor: AppKit.tertiaryText)
    static let contentBackground = Color(nsColor: .textBackgroundColor)

    /// The colour for a speaker index; indices wrap around the palette.
    static func speaker(_ index: Int) -> Color {
        Color(nsColor: AppKit.speaker(index))
    }

    static let meetingTitle = Font.system(size: 27, weight: .semibold, design: .serif)
    static let subject = Font.system(size: 19, weight: .semibold, design: .serif)
    static let reading = Font.system(size: 14.5)
    static let interface = Font.system(size: 13)
    static let meta = Font.system(size: 12.5)
    static let label = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 11.5, design: .monospaced)

    static let readingWidth: CGFloat = 760

    /// The same colours as `NSColor`, for the transcript's text view. The SwiftUI colours above wrap these.
    enum AppKit {
        static let primaryText = NSColor.labelColor
        static let secondaryText = dynamic(light: Palette.secondaryTextLight, dark: Palette.secondaryTextDark)
        static let tertiaryText = dynamic(light: Palette.tertiaryTextLight, dark: Palette.tertiaryTextDark)
        static let attentionText = dynamic(light: Palette.attentionTextLight, dark: Palette.attentionDark)
        static let accentSoft = dynamic(light: Palette.accentLight, lightAlpha: Palette.softLight, dark: Palette.accentDark, darkAlpha: Palette.softDark)
        static let accentMid = dynamic(light: Palette.accentLight, lightAlpha: Palette.midLight, dark: Palette.accentDark, darkAlpha: Palette.midDark)

        static func speaker(_ index: Int) -> NSColor {
            let slot = ((index % SpeakerColours.count) + SpeakerColours.count) % SpeakerColours.count
            return dynamic(light: Palette.speakerLight[slot], dark: Palette.speakerDark[slot])
        }
    }

    private static func dynamic(light: RGB, lightAlpha: Double = 1, dark: RGB, darkAlpha: Double = 1) -> Color {
        Color(nsColor: AppKit.dynamic(light: light, lightAlpha: lightAlpha, dark: dark, darkAlpha: darkAlpha))
    }
}

private extension Theme.AppKit {
    static func dynamic(light: RGB, lightAlpha: Double = 1, dark: RGB, darkAlpha: Double = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
                return NSColor(dark, alpha: darkAlpha)
            }
            return NSColor(light, alpha: lightAlpha)
        }
    }
}

private extension NSColor {
    convenience init(_ colour: RGB, alpha: Double) {
        self.init(srgbRed: colour.red, green: colour.green, blue: colour.blue, alpha: alpha)
    }
}

/// A section label: small, semibold, uppercase, tertiary.
struct SectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.label)
            .textCase(.uppercase)
            .foregroundStyle(Theme.tertiaryText)
    }
}
