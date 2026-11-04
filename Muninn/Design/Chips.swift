import SwiftUI

/// A small neutral label, such as a meeting's client.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, Space.xs + 2)
            .padding(.vertical, 1)
            .background(Theme.neutralSoft, in: RoundedRectangle(cornerRadius: Radius.chip))
    }
}
