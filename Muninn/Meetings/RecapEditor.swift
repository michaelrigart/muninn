import AppKit
import MuninnCore
import SwiftUI

/// Which recap text fields have focus, and the window each one lives in. Resigning only when one does leaves other
/// responders, such as the sidebar list or another window, alone.
final class RecapFocus {
    private struct Focused {
        weak var window: NSWindow?
    }

    private var fields: [RecapField: Focused] = [:]

    /// Records the key window as the field's own when focus begins. Entries leave only when focus really ends.
    func set(_ field: RecapField, focused: Bool) {
        fields[field] = focused ? Focused(window: NSApp.keyWindow) : nil
    }

    /// Ends the editing of a focused recap field, through the field's own window (which need not be key), so its own
    /// undo history is gone before the document registers or drops anything.
    func resign() {
        for focused in fields.values {
            focused.window?.makeFirstResponder(nil)
        }
    }
}

/// The only way the interface changes the document: every structural change and `replace` resigns a focused field
/// first (Task 4's undo routing), so no call site can forget it.
struct RecapEditing {
    let document: RecapDocument
    let undoManager: UndoManager?
    let focus: RecapFocus

    func edit(_ actionName: String, _ change: (inout Summary) -> Void) {
        focus.resign()
        document.edit(actionName, undoManager: undoManager, change)
    }

    func type(_ field: RecapField, _ change: (inout Summary) -> Void) {
        document.type(field, undoManager: undoManager, change)
    }

    func endTyping() {
        document.endTyping(undoManager: undoManager)
    }

    func replace(with summary: Summary) {
        focus.resign()
        document.replace(with: summary, undoManager: undoManager)
    }
}

/// The recap as text: subjects, bullets and actions that read like a document and edit in place. Every change goes
/// through the `RecapDocument`, so it undoes with ⌘Z.
struct RecapEditor: View {
    @Environment(\.undoManager) private var undoManager
    let meeting: Meeting
    let document: RecapDocument?
    let focus: RecapFocus
    let summary: Summary?
    let segmentStarts: [Int: TimeInterval]
    let canPlay: Bool
    let onSource: (Int) -> Void
    let hasPreviousVersion: Bool
    let onPreviousVersion: () -> Void
    let previousVersionReason: String?

    var body: some View {
        ScrollView {
            if let summary, let document {
                let editing = RecapEditing(document: document, undoManager: undoManager, focus: focus)
                VStack(alignment: .leading, spacing: Space.l) {
                    ForEach(Array(summary.subjects.indices), id: \.self) { index in
                        SubjectView(
                            subject: summary.subjects[index],
                            index: index,
                            editing: editing,
                            segmentStarts: segmentStarts,
                            canPlay: canPlay,
                            onSource: onSource
                        )
                    }
                    Button {
                        editing.edit("Add subject") { $0.subjects.append(Subject(title: "New subject", bullets: [], actions: [])) }
                    } label: {
                        Label("Add subject", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .font(Theme.interface)
                    .foregroundStyle(Theme.secondaryText)
                    footer(summary)
                }
                .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                .padding(Space.l)
                .frame(maxWidth: .infinity)
            } else if meeting.status == .ready {
                Text("No recap yet.")
                    .font(Theme.reading)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(Space.l)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func footer(_ recap: Summary) -> some View {
        HStack(spacing: 0) {
            Text("Written by \(recap.engine.displayName) · \(recap.generatedAt.formatted(date: .abbreviated, time: .shortened))")
            if hasPreviousVersion {
                Text(" · ")
                Button("Previous version", action: onPreviousVersion)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .underline()
                    .disabled(previousVersionReason != nil)
                    .help(previousVersionReason ?? "Swap back to the recap that was replaced when this one was written")
            }
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.tertiaryText)
        .padding(.top, Space.m)
    }
}

private struct SubjectView: View {
    let subject: Subject
    let index: Int
    let editing: RecapEditing
    let segmentStarts: [Int: TimeInterval]
    let canPlay: Bool
    let onSource: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                RecapTextField(
                    field: .subjectTitle(index),
                    text: subject.title,
                    placeholder: "Subject",
                    font: Theme.subject,
                    editing: editing
                )
                RemoveButton(label: "Remove subject", visible: hovering) {
                    editing.edit("Remove subject") { $0.removeSubject(index) }
                }
            }
            .onHover { hovering = $0 }
            ForEach(Array(subject.bullets.indices), id: \.self) { bullet in
                BulletRow(
                    bullet: subject.bullets[bullet],
                    subject: index,
                    index: bullet,
                    editing: editing,
                    segmentStarts: segmentStarts,
                    canPlay: canPlay,
                    onSource: onSource
                )
            }
            if !subject.actions.isEmpty {
                Text("Actions")
                    .modifier(SectionLabel())
                    .padding(.top, Space.xs)
                ForEach(Array(subject.actions.indices), id: \.self) { action in
                    ActionRow(
                        action: subject.actions[action],
                        subject: index,
                        index: action,
                        editing: editing,
                        segmentStarts: segmentStarts,
                        canPlay: canPlay,
                        onSource: onSource
                    )
                }
            }
            HStack(spacing: Space.m) {
                Button("Add bullet") { editing.edit("Add bullet") { $0.addBullet(subject: index) } }
                Button("Add action") { editing.edit("Add action") { $0.addAction(subject: index) } }
            }
            .buttonStyle(.borderless)
            .font(Theme.interface)
            .foregroundStyle(Theme.secondaryText)
        }
    }
}

private struct BulletRow: View {
    let bullet: Bullet
    let subject: Int
    let index: Int
    let editing: RecapEditing
    let segmentStarts: [Int: TimeInterval]
    let canPlay: Bool
    let onSource: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("•")
                    .font(Theme.reading)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                RecapTextField(
                    field: .bulletText(subject, index),
                    text: bullet.text,
                    placeholder: "Bullet",
                    font: Theme.reading,
                    editing: editing,
                    multiline: true
                )
                SourceMarks(sources: bullet.sources, segmentStarts: segmentStarts, canPlay: canPlay, onSource: onSource)
                RemoveButton(label: "Remove bullet", visible: hovering) {
                    editing.edit("Remove bullet") { $0.removeBullet(subject: subject, index: index) }
                }
            }
            if bullet.sources.isEmpty {
                NoSourceMark().padding(.leading, Space.m)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct ActionRow: View {
    let action: ActionPoint
    let subject: Int
    let index: Int
    let editing: RecapEditing
    let segmentStarts: [Int: TimeInterval]
    let canPlay: Bool
    let onSource: (Int) -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "square")
                    .font(Theme.reading)
                    .foregroundStyle(Theme.tertiaryText)
                    .accessibilityHidden(true)
                RecapTextField(
                    field: .actionText(subject, index),
                    text: action.text,
                    placeholder: "Action",
                    font: Theme.reading,
                    editing: editing,
                    multiline: true
                )
                OwnerToken(
                    owner: action.owner,
                    hovering: hovering,
                    field: .actionOwner(subject, index),
                    editing: editing
                )
                DueToken(
                    due: action.due,
                    hovering: hovering,
                    subject: subject,
                    action: index,
                    editing: editing
                )
                SourceMarks(sources: action.sources, segmentStarts: segmentStarts, canPlay: canPlay, onSource: onSource)
                RemoveButton(label: "Remove action", visible: hovering) {
                    editing.edit("Remove action") { $0.removeAction(subject: subject, index: index) }
                }
            }
            if action.sources.isEmpty {
                NoSourceMark().padding(.leading, Space.m + Space.s)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// An icon button that appears while its row is hovered or it has keyboard focus. It stays in the layout and the
/// accessibility tree.
private struct RemoveButton: View {
    let label: String
    let visible: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .focused($focused)
        .opacity(visible || focused ? 1 : 0)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A plain text field of the recap. Every change goes to the document as typing; the run ends when the field loses
/// focus or disappears, and Return resigns focus.
struct RecapTextField: View {
    let field: RecapField
    let text: String
    let placeholder: String
    let font: Font
    let editing: RecapEditing
    var multiline = false
    var autofocus = false
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: binding, axis: multiline ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                editing.focus.set(field, focused: isFocused)
                if !isFocused { editing.endTyping() }
            }
            .onSubmit {
                editing.focus.resign()
                onSubmit()
            }
            .onAppear { if autofocus { focused = true } }
            .onDisappear {
                editing.focus.set(field, focused: false)
                editing.endTyping()
            }
    }

    private var binding: Binding<String> {
        Binding(
            get: { text },
            set: { value in editing.type(field) { $0.set(field, to: value) } }
        )
    }
}

extension Summary {
    mutating func set(_ field: RecapField, to value: String) {
        switch field {
        case .subjectTitle(let s):
            if subjects.indices.contains(s) { subjects[s].title = value }
        case .bulletText(let s, let b):
            if subjects[safe: s]?.bullets[safe: b] != nil { subjects[s].bullets[b].text = value }
        case .actionText(let s, let a):
            if subjects[safe: s]?.actions[safe: a] != nil { subjects[s].actions[a].text = value }
        case .actionOwner(let s, let a):
            if subjects[safe: s]?.actions[safe: a] != nil { subjects[s].actions[a].owner = value }
        }
    }

    mutating func setDue(_ due: String?, subject s: Int, action a: Int) {
        if subjects[safe: s]?.actions[safe: a] != nil { subjects[s].actions[a].due = due }
    }

    mutating func removeSubject(_ s: Int) {
        if subjects.indices.contains(s) { subjects.remove(at: s) }
    }

    mutating func removeBullet(subject s: Int, index b: Int) {
        if subjects[safe: s]?.bullets[safe: b] != nil { subjects[s].bullets.remove(at: b) }
    }

    mutating func removeAction(subject s: Int, index a: Int) {
        if subjects[safe: s]?.actions[safe: a] != nil { subjects[s].actions.remove(at: a) }
    }

    mutating func addBullet(subject s: Int) {
        if subjects.indices.contains(s) { subjects[s].bullets.append(Bullet(text: "", sources: [])) }
    }

    mutating func addAction(subject s: Int) {
        if subjects.indices.contains(s) { subjects[s].actions.append(ActionPoint(owner: "", text: "", due: nil, sources: [])) }
    }
}
