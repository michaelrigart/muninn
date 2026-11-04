import AppKit
import MuninnCore
import SwiftUI

/// The one component for progress, waits, warnings and problems.
struct StatusCard: View {
    enum Role {
        case progress, waiting, attention, problem, success
    }

    enum Progress {
        case indeterminate
        case fraction(Double)
    }

    struct Action: Identifiable {
        var label: String
        var run: () -> Void
        var menu: [(String, () -> Void)] = []
        var disabledReason: String?

        var id: String { label }
    }

    let role: Role
    let title: String
    var explanation: String?
    var meta: String?
    var since: Date?
    var steps: (current: Int, labels: [String])?
    var progress: Progress?
    var actions: [Action] = []
    var copyDetails: String?
    var showInActivity: (() -> Void)?
    var onDismiss: (() -> Void)?
    var compact = false

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            icon
            if compact {
                compactContent
            } else {
                content
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
                .help("Dismiss")
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, compact ? Space.s : Space.m)
        .background {
            let shape = RoundedRectangle(cornerRadius: Radius.card)
            ZStack {
                shape.fill(Theme.contentBackground)
                shape.fill(softFill)
            }
        }
        .tint(Theme.accent)
        .accessibilityElement(children: .contain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(Self.formatted(title, font: Self.titleFont))
                .foregroundStyle(Theme.primaryText)
            if let explanation {
                Text(Self.formatted(explanation))
                    .font(Theme.interface)
                    .foregroundStyle(Theme.secondaryText)
            }
            if meta != nil || since != nil {
                metaLine
            }
            if let steps {
                stepBar(current: steps.current, labels: steps.labels)
            }
            if let progress {
                progressBar(progress)
            }
            if !shownActions.isEmpty {
                HStack(spacing: Space.s) {
                    ForEach(shownActions) { action in
                        ActionButton(action: action, compact: false)
                    }
                }
                .padding(.top, Space.xs)
            }
            if copyDetails != nil || showInActivity != nil {
                HStack(spacing: Space.m) {
                    if let copyDetails {
                        Button(copied ? "Copied" : "Copy details") { copy(copyDetails) }
                    }
                    if let showInActivity {
                        Button("Show in Activity", action: showInActivity)
                    }
                }
                .buttonStyle(.borderless)
                .font(Theme.meta)
                .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var compactContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(compactText)
                .font(Theme.interface)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(shownActions) { action in
                ActionButton(action: action, compact: true)
            }
            if copyDetails != nil || showInActivity != nil {
                Menu {
                    if let copyDetails {
                        Button(copied ? "Copied" : "Copy details") { copy(copyDetails) }
                    }
                    if let showInActivity {
                        Button("Show in Activity", action: showInActivity)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Theme.secondaryText)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
        }
    }

    private var compactText: AttributedString {
        var result = Self.formatted(title, font: Self.titleFont)
        result.foregroundColor = Theme.primaryText
        if let explanation {
            var detail = Self.formatted(" " + explanation)
            detail.foregroundColor = Theme.secondaryText
            result += detail
        }
        return result
    }

    private var metaLine: some View {
        HStack(spacing: 0) {
            if let meta { Text(verbatim: meta) }
            if let since { Text(since, style: .timer) }
        }
        .font(Theme.mono)
        .foregroundStyle(Theme.secondaryText)
    }

    private var shownActions: [Action] {
        Array(actions.prefix(3))
    }

    private var icon: some View {
        Group {
            switch role {
            case .progress:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("In progress")
            case .waiting:
                Image(systemName: "clock")
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel("Waiting")
            case .attention:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.attentionFill)
                    .accessibilityLabel("Needs you")
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.problem)
                    .accessibilityLabel("Problem")
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                    .accessibilityLabel("Done")
            }
        }
        .font(.system(size: 14))
        .frame(width: 16, height: 16)
    }

    private var softFill: Color {
        switch role {
        case .progress: Theme.accentSoft
        case .waiting: Theme.neutralSoft
        case .attention: Theme.attentionSoft
        case .problem: Theme.problemSoft
        case .success: Theme.successSoft
        }
    }

    private func stepBar(current: Int, labels: [String]) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                VStack(alignment: .leading, spacing: Space.xs) {
                    Capsule()
                        .fill(index < current ? Theme.accent : Theme.secondaryText.opacity(0.25))
                        .frame(height: 4)
                    Text(verbatim: label)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(min(current, labels.count)) of \(labels.count)")
        .accessibilityValue(labels.indices.contains(current - 1) ? labels[current - 1] : "")
    }

    @ViewBuilder
    private func progressBar(_ progress: Progress) -> some View {
        switch progress {
        case .indeterminate:
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        case .fraction(let value):
            ProgressView(value: min(max(value, 0), 1))
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    private static let titleFont = Font.system(size: 13, weight: .semibold)

    /// The runs of `InlineCode` as one string: code in monospace, the rest in `font` when given.
    static func formatted(_ text: String, font: Font? = nil) -> AttributedString {
        var result = AttributedString()
        for run in InlineCode.runs(text) {
            var part = AttributedString(run.text)
            if run.isCode {
                part.font = Theme.mono
            } else if let font {
                part.font = font
            }
            result += part
        }
        return result
    }
}

private struct ActionButton: View {
    let action: StatusCard.Action
    let compact: Bool

    var body: some View {
        styled
            .controlSize(compact ? .small : .regular)
            .disabled(action.disabledReason != nil)
            .help(action.disabledReason ?? "")
    }

    @ViewBuilder
    private var styled: some View {
        if compact {
            control.buttonStyle(.borderless)
        } else {
            control.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var control: some View {
        if action.menu.isEmpty {
            Button(action.label, action: action.run)
        } else {
            Menu(action.label) {
                ForEach(Array(action.menu.enumerated()), id: \.offset) { _, item in
                    Button(item.0, action: item.1)
                }
            }
            .menuStyle(.button)
            .fixedSize()
        }
    }
}
