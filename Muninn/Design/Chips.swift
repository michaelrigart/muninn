import MuninnCore
import SwiftUI

/// Secondary text that switches to the primary style on a selected row, where the row's accent background would drop
/// a fixed grey below readable contrast.
private struct RowSecondaryText: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    let colour: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(colour))
    }
}

extension View {
    func rowSecondaryText(_ colour: Color = Theme.secondaryText) -> some View {
        modifier(RowSecondaryText(colour: colour))
    }
}

/// A small neutral label, such as a meeting's client.
struct Chip: View {
    @Environment(\.backgroundProminence) private var prominence
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.meta)
            .rowSecondaryText()
            .lineLimit(1)
            .padding(.horizontal, Space.xs + 2)
            .padding(.vertical, 1)
            .background(prominence == .increased ? Color.clear : Theme.neutralSoft, in: RoundedRectangle(cornerRadius: Radius.chip))
    }
}

/// A header chip: an icon or a coloured dot and a short label on a soft fill. Wrap it in a `Button` with `.token` to open a popover.
struct Token: View {
    enum Role { case normal, attention, placeholder }
    enum Mark { case symbol(String), dot(Color) }

    let label: String
    let mark: Mark?
    var role: Role = .normal

    init(label: String, mark: Mark?, role: Role = .normal) {
        self.label = label
        self.mark = mark
        self.role = role
    }

    init(label: String, systemImage: String?, role: Role = .normal) {
        self.init(label: label, mark: systemImage.map(Mark.symbol), role: role)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            switch mark {
            case .symbol(let name):
                Image(systemName: name)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            case .dot(let colour):
                Circle()
                    .fill(colour)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            Text(label)
                .multilineTextAlignment(.leading)
        }
        .font(Theme.meta)
        .foregroundStyle(foreground)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.chip)
            ZStack {
                shape.fill(Theme.contentBackground)
                shape.fill(fill)
            }
        }
    }

    private var foreground: Color {
        switch role {
        case .normal: Theme.secondaryText
        case .attention: Theme.attentionText
        case .placeholder: Theme.tertiaryText
        }
    }

    private var fill: Color {
        role == .attention ? Theme.attentionSoft : Theme.neutralSoft
    }
}

private struct TokenButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .opacity(!isEnabled ? 0.55 : configuration.isPressed ? 0.7 : 1)
    }
}

struct TokenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TokenButtonBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == TokenButtonStyle {
    static var token: TokenButtonStyle { TokenButtonStyle() }
}

/// An attendee: a coloured circle with their initials, then their first name.
struct PersonChip: View {
    let name: String
    let email: String

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            Text(PersonLabel.initials(name: name, email: email))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.contentBackground)
                .frame(width: 18, height: 18)
                .background(Theme.speaker(SpeakerColours.personIndex(name: name, email: email)), in: Circle())
            Text(PersonLabel.shortName(name: name, email: email))
                .font(Theme.meta)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .help(name.isEmpty ? email : "\(name)\n\(email)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.isEmpty ? email : name)
    }
}
