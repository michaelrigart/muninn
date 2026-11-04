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
