import MuninnCore
import SwiftUI

/// Chooses the sender, recipients and subject of an Outlook draft, previews the recap that goes in it and creates the draft.
struct DraftSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let summary: Summary?

    @State private var subject: String
    @State private var creating = false
    @State private var editError: Problem?
    @FocusState private var recipientsFocused: Bool

    init(meeting: Meeting, summary: Summary?) {
        self.meeting = meeting
        self.summary = summary
        _subject = State(initialValue: RecapEmail.subject(title: meeting.title, date: meeting.startedAt, timeZone: .current))
    }

    private var refusal: String? {
        MeetingCommands.draftRefusal(meeting, accounts: model.settings.accounts)
    }

    private var account: AccountSettings? {
        model.settings.accounts.first { $0.id == meeting.accountID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Outlook draft")
                .font(.headline)
            fromRow
            RecipientsEditor(meeting: meeting, edit: edit, focused: $recipientsFocused)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Subject").modifier(SectionLabel())
                TextField("Subject", text: $subject)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Recap").modifier(SectionLabel())
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
    }

    private var fromRow: some View {
        HStack(spacing: Space.s) {
            Text("From").modifier(SectionLabel())
            if let account {
                Text(account.displayName)
                    .font(Theme.interface)
            } else {
                Text(meeting.accountID == nil ? "Choose an account in the meeting's details" : MeetingActions.accountRemovedLabel)
                    .font(Theme.interface)
                    .foregroundStyle(Theme.attentionText)
            }
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                if let summary {
                    ForEach(Array(summary.subjects.enumerated()), id: \.offset) { _, subject in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(subject.title)
                                .font(Theme.subject)
                            ForEach(Array(subject.bullets.enumerated()), id: \.offset) { _, bullet in
                                Text("\u{2022} \(bullet.text)")
                            }
                            ForEach(Array(subject.actions.enumerated()), id: \.offset) { _, action in
                                Text(actionLine(action))
                            }
                        }
                    }
                } else {
                    Text("There's no recap yet")
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .font(Theme.reading)
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
            .textSelection(.enabled)
        }
        .background(Theme.contentBackground, in: RoundedRectangle(cornerRadius: Radius.card))
        .frame(minHeight: 120)
    }

    private func actionLine(_ action: ActionPoint) -> String {
        let owner = meeting.speakerNames[action.owner] ?? action.owner
        var line = "\(owner): \(action.text)"
        if let due = action.due, let formatted = RecapEmail.dueDate(due) {
            line += " (\(formatted))"
        }
        return line
    }

    private var buttons: some View {
        HStack(spacing: Space.s) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(creating)
            if creating {
                ProgressView().controlSize(.small)
            }
            Button(creating ? "Creating…" : "Create draft", action: create)
                .keyboardShortcut(recipientsFocused ? nil : .defaultAction)
                .disabled(refusal != nil || creating)
                .help(refusal ?? "Create the draft in Outlook")
        }
    }

    private func create() {
        creating = true
        let id = meeting.id
        let subject = subject
        Task {
            let outcome = await model.createDraft(id, subject: subject)
            creating = false
            if outcome == .created || outcome == .review { dismiss() }
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
            Text("Recipients (\(meeting.recipients.filter(\.included).count) of \(meeting.recipients.count))")
                .modifier(SectionLabel())
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
        let value = trimmedQuery
        guard value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else { return nil }
        return Attendee(name: "", email: value)
    }

    private var candidates: [Attendee] {
        let known = Set(meeting.recipients.map { $0.attendee.email.lowercased() })
        var list = results.filter { !known.contains($0.email.lowercased()) }
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
