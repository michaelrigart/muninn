import Foundation

public struct RGB: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

public enum Palette {
    public static let accentLight = RGB(hex: 0x1D6779)
    public static let accentDark = RGB(hex: 0x5FB0C2)
    public static let attentionTextLight = RGB(hex: 0x9A5B00)
    public static let attentionFillLight = RGB(hex: 0xD68A00)
    public static let attentionDark = RGB(hex: 0xE8A33A)
    public static let problemLight = RGB(hex: 0xC4302B)
    public static let problemDark = RGB(hex: 0xFF6B63)
    public static let successLight = RGB(hex: 0x2E7D4F)
    public static let successDark = RGB(hex: 0x5CC489)
    public static let recording = RGB(hex: 0xED1B2E)

    public static let contentLight = RGB(hex: 0xFFFFFF)
    public static let contentDark = RGB(hex: 0x1E1E1E)

    /// The system label colour: black in light, white in dark, at this opacity.
    public static let primaryTextAlpha = 0.85
    public static let secondaryTextLight = RGB(hex: 0x5C5C5C)
    public static let secondaryTextDark = RGB(hex: 0xA6A6A6)
    public static let tertiaryTextLight = RGB(hex: 0x6E6E6E)
    public static let tertiaryTextDark = RGB(hex: 0x8C8C8C)

    public static let softLight = 0.10
    public static let softDark = 0.13
    public static let neutral = RGB(hex: 0x808080)
    public static let neutralSoftAlpha = 0.08
}

/// WCAG 2 contrast.
public enum Contrast {
    public static func luminance(_ colour: RGB) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.red) + 0.7152 * linear(colour.green) + 0.0722 * linear(colour.blue)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    public static func composite(_ top: RGB, alpha: Double, over bottom: RGB) -> RGB {
        RGB(
            red: top.red * alpha + bottom.red * (1 - alpha),
            green: top.green * alpha + bottom.green * (1 - alpha),
            blue: top.blue * alpha + bottom.blue * (1 - alpha)
        )
    }
}
