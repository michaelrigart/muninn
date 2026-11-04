import AppKit
import MuninnCore
import SwiftUI

/// Ends the editing of a focused text field, so its own undo history is gone before the document registers or drops
/// anything. Call it before every `RecapDocument.edit` and `replace`.
func endFieldEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// The recap as text: subjects, bullets and actions that read like a document and edit in place. Every change goes
/// through the `RecapDocument`, so it undoes with ⌘Z.
struct RecapEditor: View {
    @Environment(\.undoManager) private var undoManager
    let meeting: Meeting
    let document: RecapDocument?
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
                VStack(alignment: .leading, spacing: Space.l) {
                    ForEach(Array(summary.subjects.indices), id: \.self) { index in
                        SubjectView(
                            subject: summary.subjects[index],
                            index: index,
                            document: document,
                            undoManager: undoManager,
                            segmentStarts: segmentStarts,
                            canPlay: canPlay,
                            onSource: onSource
                        )
                    }
                    Button {
                        change("Add subject", document) { $0.subjects.append(Subject(title: "New subject", bullets: [], actions: [])) }
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

    private func change(_ actionName: String, _ document: RecapDocument, _ change: (inout Summary) -> Void) {
        endFieldEditing()
        document.edit(actionName, undoManager: undoManager, change)
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
    let document: RecapDocument
    let undoManager: UndoManager?
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
                    document: document,
                    undoManager: undoManager
                )
                RemoveButton(label: "Remove subject", visible: hovering) {
                    change("Remove subject") { $0.removeSubject(index) }
                }
            }
            .onHover { hovering = $0 }
            ForEach(Array(subject.bullets.indices), id: \.self) { bullet in
                BulletRow(
                    bullet: subject.bullets[bullet],
                    subject: index,
                    index: bullet,
                    document: document,
                    undoManager: undoManager,
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
                        document: document,
                        undoManager: undoManager,
                        segmentStarts: segmentStarts,
                        canPlay: canPlay,
                        onSource: onSource
                    )
                }
            }
            HStack(spacing: Space.m) {
                Button("Add bullet") { change("Add bullet") { $0.addBullet(subject: index) } }
                Button("Add action") { change("Add action") { $0.addAction(subject: index) } }
            }
            .buttonStyle(.borderless)
            .font(Theme.interface)
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private func change(_ actionName: String, _ change: (inout Summary) -> Void) {
        endFieldEditing()
        document.edit(actionName, undoManager: undoManager, change)
    }
}

private struct BulletRow: View {
    let bullet: Bullet
    let subject: Int
    let index: Int
    let document: RecapDocument
    let undoManager: UndoManager?
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
                    document: document,
                    undoManager: undoManager,
                    multiline: true
                )
                SourceMarks(sources: bullet.sources, segmentStarts: segmentStarts, canPlay: canPlay, onSource: onSource)
                RemoveButton(label: "Remove bullet", visible: hovering) {
                    endFieldEditing()
                    document.edit("Remove bullet", undoManager: undoManager) { $0.removeBullet(subject: subject, index: index) }
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
    let document: RecapDocument
    let undoManager: UndoManager?
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
                    document: document,
                    undoManager: undoManager,
                    multiline: true
                )
                OwnerToken(
                    owner: action.owner,
                    hovering: hovering,
                    field: .actionOwner(subject, index),
                    document: document,
                    undoManager: undoManager
                )
                DueToken(
                    due: action.due,
                    hovering: hovering,
                    subject: subject,
                    action: index,
                    document: document,
                    undoManager: undoManager
                )
                SourceMarks(sources: action.sources, segmentStarts: segmentStarts, canPlay: canPlay, onSource: onSource)
                RemoveButton(label: "Remove action", visible: hovering) {
                    endFieldEditing()
                    document.edit("Remove action", undoManager: undoManager) { $0.removeAction(subject: subject, index: index) }
                }
            }
            if action.sources.isEmpty {
                NoSourceMark().padding(.leading, Space.m + Space.s)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// An icon button that appears while its row is hovered. It stays in the layout and the accessibility tree.
private struct RemoveButton: View {
    let label: String
    let visible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .opacity(visible ? 1 : 0)
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
    let document: RecapDocument
    let undoManager: UndoManager?
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
                if !isFocused { document.endTyping(undoManager: undoManager) }
            }
            .onSubmit {
                endFieldEditing()
                onSubmit()
            }
            .onAppear { if autofocus { focused = true } }
            .onDisappear { document.endTyping(undoManager: undoManager) }
    }

    private var binding: Binding<String> {
        Binding(
            get: { text },
            set: { value in document.type(field, undoManager: undoManager) { $0.set(field, to: value) } }
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
