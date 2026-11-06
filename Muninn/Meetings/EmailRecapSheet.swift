import MuninnCore
import SwiftUI

/// Chooses the recipients and subject of the recap email, previews the recap and copies each part to the pasteboard, to paste into any mail app.
struct EmailRecapSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let summary: Summary?

    @State private var subject: String
    @State private var editError: Problem?
    @FocusState private var recipientsFocused: Bool

    private static let noRecap = "There's no recap yet"

    init(meeting: Meeting, summary: Summary?) {
        self.meeting = meeting
        self.summary = summary
        _subject = State(initialValue: RecapEmail.subject(title: meeting.title, date: meeting.startedAt, timeZone: .current))
    }

    private var trimmedSubject: String {
        subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Email recap")
                .font(.headline)
            VStack(alignment: .leading, spacing: Space.xs) {
                header(
                    "Recipients (\(meeting.recipients.filter(\.included).count) of \(meeting.recipients.count))",
                    part: "recipients",
                    help: "Copy the recipients",
                    disabledReason: meeting.recipients.contains(where: \.included) ? nil : "Tick at least one recipient"
                ) {
                    RecapPasteboard.copy(EmailRecipients.line(meeting.recipients))
                    return true
                }
                RecipientsEditor(meeting: meeting, edit: edit, focused: $recipientsFocused)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                header(
                    "Subject",
                    part: "subject",
                    help: "Copy the subject",
                    disabledReason: trimmedSubject.isEmpty ? "Type a subject" : nil
                ) {
                    RecapPasteboard.copy(trimmedSubject)
                    return true
                }
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                header(
                    "Recap",
                    part: "recap",
                    help: "Copy the recap",
                    disabledReason: summary == nil ? Self.noRecap : nil,
                    copy: copyRecap
                )
                preview
            }
            if let editError {
                ProblemCard(
                    problem: editError,
                    role: editError.severity == .warning ? .attention : nil,
                    compact: true,
                    handlers: model.problemHandlers(),
                    showInActivity: { model.showInActivity(editError, meeting: meeting.id) },
                    onDismiss: { self.editError = nil }
                )
            }
            if let problem = model.actionErrors[meeting.id] {
                ProblemCard(
                    problem: problem,
                    role: problem.severity == .warning ? .attention : nil,
                    compact: true,
                    handlers: model.problemHandlers(),
                    showInActivity: { model.showInActivity(problem, meeting: meeting.id) },
                    onDismiss: { model.actionErrors[meeting.id] = nil }
                )
            }
            buttons
        }
        .padding(Space.l)
        .frame(minWidth: 520, minHeight: 480)
        .onExitCommand { dismiss() }
    }

    private func header(_ label: String, part: String, help: String, disabledReason: String?, copy: @escaping () -> Bool) -> some View {
        HStack(spacing: Space.s) {
            Text(label).modifier(SectionLabel())
            Spacer()
            CopyButton(part: part, help: help, disabledReason: disabledReason, copy: copy)
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                if let summary {
                    let content = RecapEmail.content(summary: summary, speakerNames: meeting.speakerNames)
                    Text(content.greeting)
                    Text(content.intro)
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(section.title)
                                .font(Theme.subject)
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                Text(line(item))
                            }
                        }
                    }
                    Text(content.closing)
                } else {
                    Text(Self.noRecap)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .font(Theme.reading)
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
        }
        .background(Theme.contentBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .frame(minHeight: 120)
    }

    private func line(_ item: RecapEmail.Item) -> AttributedString {
        var line = AttributedString("\u{2022} ")
        if let owner = item.owner {
            var name = AttributedString(owner)
            name.inlinePresentationIntent = .stronglyEmphasized
            line += name
            line += AttributedString(": ")
        }
        line += AttributedString(item.text)
        return line
    }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(recipientsFocused ? nil : .defaultAction)
        }
    }

    /// Asks about unsourced items first; true only when the recap was copied.
    private func copyRecap() -> Bool {
        guard let summary else { return false }
        switch model.confirmUnsourcedItems(MeetingActions.unsourcedItemCount(in: summary), for: meeting.id) {
        case .include:
            RecapPasteboard.copyRecap(summary, speakerNames: meeting.speakerNames)
            return true
        case .review:
            dismiss()
            return false
        case .cancel:
            return false
        }
    }

    private func edit(_ change: (inout Meeting) -> Void) {
        do {
            try model.mutate(meeting.id, change)
        } catch {
            let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingEdits, subject: "your changes"))
            if editError != problem {
                model.activity.record(problem, area: .recap, meeting: meeting)
            }
            editError = problem
        }
    }
}

/// A borderless Copy button that reads "Copied" for 1.5 s after `copy` returns true.
private struct CopyButton: View {
    let part: String
    let help: String
    let disabledReason: String?
    let copy: () -> Bool

    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        Button {
            if copy() {
                copied = true
                copies += 1
                AccessibilityNotification.Announcement("Copied").post()
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel("Copy \(part)")
        .disabled(disabledReason != nil)
        .help(disabledReason ?? help)
        .task(id: copies) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }
}

/// The meeting's recipients as checkboxes, with a field to search people or type an address.
private struct RecipientsEditor: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let edit: ((inout Meeting) -> Void) -> Void
    var focused: FocusState<Bool>.Binding

    @State private var query = ""
    @State private var results: [Attendee] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if meeting.recipients.count > 6 {
                ScrollView { rows }.frame(height: 132)
            } else {
                rows
            }
            TextField(meeting.accountID == nil ? "Email address" : "Search people or type an email address", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onSubmit {
                    if let manual { add(manual) }
                }
            ForEach(candidates, id: \.email) { attendee in
                Button {
                    add(attendee)
                } label: {
                    Label("\(attendee.name.isEmpty ? attendee.email : "\(attendee.name) <\(attendee.email)>")", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.interface)
        .task(id: query) {
            await search()
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(meeting.recipients, id: \.attendee.email) { recipient in
                Toggle(isOn: includedBinding(recipient.attendee.email)) {
                    HStack(spacing: 6) {
                        Text(recipient.attendee.name.isEmpty ? recipient.attendee.email : recipient.attendee.name)
                        if !recipient.attendee.name.isEmpty {
                            Text(recipient.attendee.email)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manual: Attendee? {
        EmailRecipients.typedAddress(query)
    }

    private var candidates: [Attendee] {
        let known = Set(meeting.recipients.map { $0.attendee.email.lowercased() })
        var list = results.filter { !known.contains($0.email.lowercased()) && EmailRecipients.isValidAddress($0.email) }
        if let manual, !known.contains(manual.email.lowercased()), !list.contains(where: { $0.email.lowercased() == manual.email.lowercased() }) {
            list.insert(manual, at: 0)
        }
        return list
    }

    private func includedBinding(_ email: String) -> Binding<Bool> {
        Binding(
            get: { meeting.recipients.first(where: { $0.attendee.email.lowercased() == email.lowercased() })?.included ?? false },
            set: { included in edit { $0 = MeetingActions.setIncluded(email, included, in: $0) } }
        )
    }

    private func add(_ attendee: Attendee) {
        let selfAddresses = model.settings.accounts.flatMap(\.selfAddresses)
        edit { $0 = MeetingActions.addRecipient(attendee, to: $0, selfAddresses: selfAddresses) }
        query = ""
        results = []
    }

    private func search() async {
        let term = trimmedQuery
        guard let account = meeting.accountID, term.count >= 2 else {
            results = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let found = await model.searchPeople(account: account, query: term)
        guard !Task.isCancelled else { return }
        results = found
    }
}
