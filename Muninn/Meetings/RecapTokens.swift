import MuninnCore
import SwiftUI

/// The owner of an action: a token that shows only when there is an owner or the row is hovered, and a popover to type it.
struct OwnerToken: View {
    let owner: String
    let hovering: Bool
    let field: RecapField
    let document: RecapDocument
    let undoManager: UndoManager?

    @State private var showing = false

    var body: some View {
        if !owner.isEmpty || hovering || showing {
            Button {
                endFieldEditing()
                showing = true
            } label: {
                Token(label: owner.isEmpty ? "Owner" : owner, systemImage: "person", role: owner.isEmpty ? .placeholder : .normal)
            }
            .buttonStyle(.token)
            .help("Change the owner")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                RecapTextField(
                    field: field,
                    text: owner,
                    placeholder: "Owner",
                    font: Theme.interface,
                    document: document,
                    undoManager: undoManager,
                    autofocus: true,
                    onSubmit: { showing = false }
                )
                .padding(Space.m)
                .frame(width: 240)
            }
        }
    }
}

/// The due date of an action: a token that shows only when there is a date or the row is hovered, and a popover to pick it.
struct DueToken: View {
    let due: String?
    let hovering: Bool
    let subject: Int
    let action: Int
    let document: RecapDocument
    let undoManager: UndoManager?

    @State private var showing = false

    var body: some View {
        if due != nil || hovering || showing {
            Button {
                endFieldEditing()
                showing = true
            } label: {
                token
            }
            .buttonStyle(.token)
            .help("Change the due date")
            .popover(isPresented: $showing, arrowEdge: .bottom) { picker }
        }
    }

    private var date: Date? {
        due.flatMap(DueDate.date(from:))
    }

    private var token: Token {
        guard let due else { return Token(label: "Due date", systemImage: "calendar", role: .placeholder) }
        guard let date else { return Token(label: "“\(due)” isn't a date", systemImage: "calendar", role: .attention) }
        return Token(label: "Due \(DueDate.label(for: date))", systemImage: "calendar")
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            DatePicker("Due date", selection: selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            Button("No due date") {
                showing = false
                setDue(nil)
            }
            .buttonStyle(.plain)
            .font(Theme.interface)
        }
        .padding(Space.m)
    }

    private var selection: Binding<Date> {
        Binding(
            get: { date ?? Date() },
            set: { setDue(DueDate.string(from: $0)) }
        )
    }

    private func setDue(_ due: String?) {
        endFieldEditing()
        document.edit("Change due date", undoManager: undoManager) { $0.setDue(due, subject: subject, action: action) }
    }
}

/// A transcript time the item came from. It plays from there when it can, and otherwise shows the segment.
struct SourceMark: View {
    let start: TimeInterval
    let canPlay: Bool
    let action: () -> Void

    private var description: String {
        canPlay ? "Play from \(Timestamp.format(start))" : "Show in the transcript"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if canPlay {
                    Image(systemName: "play.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(Timestamp.format(start))
            }
            .font(Theme.mono)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.xs + 2)
            .padding(.vertical, 1)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Radius.chip))
        }
        .buttonStyle(.token)
        .help(description)
        .accessibilityLabel(description)
    }
}

/// The source marks of a bullet or an action, or the warning when it cites nothing. A source missing from the
/// transcript shows no mark.
struct SourceMarks: View {
    let sources: [Int]
    let segmentStarts: [Int: TimeInterval]
    let canPlay: Bool
    let onSource: (Int) -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(sources, id: \.self) { id in
                if let start = segmentStarts[id] {
                    SourceMark(start: start, canPlay: canPlay) { onSource(id) }
                }
            }
        }
    }
}

struct NoSourceMark: View {
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text("No source in the transcript")
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.attentionText)
    }
}
