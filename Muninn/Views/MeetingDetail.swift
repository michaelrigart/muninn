import MuninnCore
import SwiftUI

private enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case transcript = "Transcript"

    var id: String { rawValue }
}

struct MeetingDetail: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    @State private var tab = DetailTab.summary
    @State private var summary: Summary?
    @State private var transcript: Transcript?
    @State private var clean: CleanTranscript?
    @State private var scrollTarget: Int?
    @State private var saveError: Problem?

    private var summaryUnsaved: Bool { model.unsavedSummaries[meeting.id] != nil }

    private struct LoadKey: Hashable {
        let id: MeetingID
        let status: ProcessingStatus
        let engine: EngineKind?
    }

    var body: some View {
        VStack(spacing: 0) {
            if let saveError {
                problemCard(saveError, tryAgain: saveRetry, onDismiss: { self.saveError = nil })
            }
            if let actionError = model.actionErrors[meeting.id] {
                problemCard(
                    actionError,
                    tryAgain: model.failedActions[meeting.id] == nil ? nil : { model.retryAction(meeting.id) },
                    onDismiss: { model.actionErrors[meeting.id] = nil }
                )
            }
            if let notice = model.actionNotices[meeting.id] {
                problemCard(notice, onDismiss: { model.actionNotices[meeting.id] = nil })
            }
            MeetingStatusCards(meeting: meeting)
            MeetingHeader(meeting: meeting, edit: edit, report: report)
            Divider()
            HStack(spacing: 12) {
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                if summaryUnsaved {
                    Label("Unsaved summary changes", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 8)
            switch tab {
            case .summary:
                SummaryEditor(meeting: meeting, summary: summary, onEdit: saveSummary, onSource: show(segment:), onRestore: restorePrevious)
            case .transcript:
                TranscriptView(meeting: meeting, transcript: transcript, clean: clean, target: $scrollTarget, report: report)
            }
        }
        .task(id: LoadKey(id: meeting.id, status: meeting.status, engine: meeting.summaryEngine)) {
            let store = model.store
            let id = meeting.id
            if let unsaved = model.unsavedSummaries[id] {
                summary = unsaved.summary
                if saveError == nil { saveError = unsaved.problem }
            } else {
                summary = model.loadFile("summary.json", for: meeting) { try store.loadSummary(id) }
            }
            transcript = model.loadFile("transcript.json", for: meeting) { try store.loadTranscript(id) }
            clean = model.loadFile("transcript.clean.json", for: meeting) { try store.loadClean(id) }
        }
    }

    private func edit(_ change: (inout Meeting) -> Void) {
        do {
            try model.mutate(meeting.id, change)
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        show(problem(for: error))
    }

    private func problem(for error: Error) -> Problem {
        ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingEdits, subject: "your changes"))
    }

    private func show(_ problem: Problem) {
        if saveError != problem {
            model.activity.record(problem, area: .recap, meeting: meeting)
        }
        saveError = problem
    }

    private func saveSummary(_ updated: Summary) {
        var updated = updated
        updated.edited = true
        summary = updated
        do {
            try model.store.saveEditedSummary(updated, for: meeting.id)
            if summaryUnsaved { saveError = nil }
            model.unsavedSummaries[meeting.id] = nil
        } catch {
            let failure = problem(for: error)
            model.unsavedSummaries[meeting.id] = UnsavedSummary(summary: updated, problem: failure)
            show(failure)
        }
    }

    private func restorePrevious() {
        do {
            summary = try model.restorePreviousSummary(meeting.id)
            model.unsavedSummaries[meeting.id] = nil
            saveError = nil
        } catch {
            do {
                summary = try model.store.loadSummary(meeting.id)
                report(error)
            } catch let reloadError {
                summary = nil
                model.activity.record(failure: reloadError, in: ProblemContext(stage: .loadingMeetings), meeting: meeting)
                report(error)
            }
        }
    }

    private var saveRetry: (() -> Void)? {
        guard summaryUnsaved, let summary else { return nil }
        return { saveSummary(summary) }
    }

    private func problemCard(_ problem: Problem, tryAgain: (() -> Void)? = nil, onDismiss: @escaping () -> Void) -> some View {
        ProblemCard(
            problem: problem,
            role: problem.severity == .warning ? .attention : nil,
            handlers: model.problemHandlers(tryAgain: tryAgain),
            showInActivity: { model.showInActivity(problem, meeting: meeting.id) },
            onDismiss: onDismiss
        )
        .inset()
    }

    private func show(segment id: Int) {
        scrollTarget = id
        tab = .transcript
    }
}

private struct MeetingHeader: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let edit: ((inout Meeting) -> Void) -> Void
    let report: (Error) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CommitTextField(title: "Title", value: meeting.title) { title in
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { edit { $0.title = trimmed } }
                }
                .textFieldStyle(.plain)
                .font(.title2.bold())
                Menu {
                    Button("Delete Meeting…", role: .destructive) { model.deleteMeeting(meeting.id) }
                        .disabled(!MeetingActions.canDelete(meeting))
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }

            HStack(spacing: 12) {
                Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let duration {
                    Label(duration, systemImage: "clock")
                }
                if let language = meeting.language {
                    Label(language.uppercased(), systemImage: "globe")
                }
                if ProcessingDisplay.needsAttention(meeting, snapshot: model.pipelineSnapshot) {
                    Label("Needs attention", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.attentionText)
                } else if let title = model.progress(for: meeting).title {
                    Label(title, systemImage: "hourglass")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !meeting.attendees.isEmpty {
                Label(meeting.attendees.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: ", "), systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !meeting.candidateEvents.isEmpty {
                eventPicker
            } else if MeetingActions.canChangeEvent(meeting) {
                ChangeEventButton(meeting: meeting, report: report)
            }

            HStack(spacing: 12) {
                Picker("Account", selection: accountBinding) {
                    Text("None").tag(String?.none)
                    if MeetingActions.accountRemoved(meeting, accounts: model.settings.accounts), let removed = meeting.accountID {
                        Text(MeetingActions.accountRemovedLabel).tag(Optional(removed))
                    }
                    ForEach(model.settings.accounts, id: \.id) { account in
                        Text(account.displayName).tag(Optional(account.id))
                    }
                }
                .fixedSize()
                HStack(spacing: 4) {
                    Text("Client")
                    CommitTextField(title: "Client", value: meeting.client ?? "") { client in
                        let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
                        edit { $0.client = trimmed.isEmpty ? nil : trimmed }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                }
            }

            RecipientsEditor(meeting: meeting, edit: edit)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var duration: String? {
        guard let end = meeting.endedAt, end > meeting.startedAt else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: end.timeIntervalSince(meeting.startedAt))
    }

    private var accountBinding: Binding<String?> {
        Binding(
            get: { meeting.accountID },
            set: { account in
                edit {
                    $0.accountID = account
                    if let association = $0.association, association.accountID != account { $0.association = nil }
                }
            }
        )
    }

    private var eventPicker: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.orange)
            Text("Which event was this?")
            Menu("Choose event") {
                ForEach(meeting.candidateEvents, id: \.pickerID) { ref in
                    Button("\(ref.subject) (\(ref.start.formatted(date: .omitted, time: .shortened)), \(accountName(ref.accountID)))") {
                        let id = meeting.id
                        Task { await model.chooseEvent(ref, for: id) }
                    }
                }
                Divider()
                Button("No event") {
                    do {
                        try model.dismissEventChoice(for: meeting.id)
                    } catch {
                        report(error)
                    }
                }
            }
            .fixedSize()
            .disabled(model.eventChangesInFlight.contains(meeting.id))
        }
        .font(.callout)
    }

    private func accountName(_ id: String) -> String {
        model.settings.accounts.first(where: { $0.id == id })?.displayName ?? id
    }
}

private struct ChangeEventButton: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let report: (Error) -> Void

    @State private var showing = false
    @State private var loading = false
    @State private var events: [CalendarEvent] = []
    @State private var failures: [Problem] = []

    var body: some View {
        Button("Change Event…") { showing = true }
            .disabled(model.eventChangesInFlight.contains(meeting.id))
            .buttonStyle(.link)
            .font(.callout)
            .help("Pick another calendar event for this meeting, until a draft or export exists")
            .popover(isPresented: $showing, arrowEdge: .bottom) { chooser }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events around \(meeting.startedAt.formatted(date: .omitted, time: .shortened))")
                .font(.headline)
            if loading {
                ProgressView().controlSize(.small)
            } else if events.isEmpty {
                Text("No events within two hours of the start.")
                    .foregroundStyle(.secondary)
            }
            ForEach(events, id: \.pickerID) { event in
                Button {
                    showing = false
                    let ref = CalendarEventRef(accountID: event.accountID, eventID: event.eventID, subject: event.subject, start: event.start)
                    let id = meeting.id
                    Task { await model.chooseEvent(ref, for: id) }
                } label: {
                    Text("\(event.subject) (\(event.start.formatted(date: .omitted, time: .shortened)), \(accountName(event.accountID)))")
                        .fontWeight(isCurrent(event) ? .semibold : .regular)
                }
                .buttonStyle(.plain)
            }
            ForEach(failures, id: \.self) { failure in
                ProblemCard(
                    problem: failure,
                    compact: true,
                    handlers: failureHandlers,
                    showInActivity: { model.showInActivity(failure) }
                )
            }
            Divider()
            Button("No event") {
                showing = false
                do {
                    try model.dismissEventChoice(for: meeting.id)
                } catch {
                    report(error)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
        .task { await load() }
    }

    private var failureHandlers: ProblemHandlers {
        var handlers = model.problemHandlers(tryAgain: { Task { await load() } })
        handlers.signInAgain = {
            showing = false
            model.showSettings(.accounts)
        }
        return handlers
    }

    private func isCurrent(_ event: CalendarEvent) -> Bool {
        meeting.association?.accountID == event.accountID && meeting.association?.eventID == event.eventID
    }

    private func accountName(_ id: String) -> String {
        model.settings.accounts.first(where: { $0.id == id })?.displayName ?? id
    }

    private func load() async {
        loading = true
        let result = await model.eventsAround(meeting)
        events = result.events
        failures = result.failures
        loading = false
    }
}

private extension CalendarEvent {
    var pickerID: String { "\(accountID)|\(eventID)" }
}

private extension CalendarEventRef {
    var pickerID: String { "\(accountID)|\(eventID)" }
}

private struct RecipientsEditor: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let edit: ((inout Meeting) -> Void) -> Void

    @State private var expanded = false
    @State private var query = ""
    @State private var results: [Attendee] = []

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(meeting.recipients, id: \.attendee.email) { recipient in
                    Toggle(isOn: includedBinding(recipient.attendee.email)) {
                        HStack(spacing: 6) {
                            Text(recipient.attendee.name.isEmpty ? recipient.attendee.email : recipient.attendee.name)
                            if !recipient.attendee.name.isEmpty {
                                Text(recipient.attendee.email)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                TextField(meeting.accountID == nil ? "Email address" : "Search people or type an email address", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
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
            .padding(.top, 4)
        } label: {
            Text("Recipients (\(meeting.recipients.filter(\.included).count) of \(meeting.recipients.count))")
        }
        .font(.callout)
        .task(id: query) {
            await search()
        }
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
