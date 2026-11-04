import AppKit
import MuninnCore
import SwiftUI

struct MeetingDetail: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    @Binding var tab: DetailTab
    @Binding var transcriptMode: TranscriptMode

    @State private var summary: Summary?
    @State private var transcript: Transcript?
    @State private var clean: CleanTranscript?
    @State private var scrollTarget: Int?
    @State private var saveError: Problem?
    @State private var showingDraft = false

    private var summaryUnsaved: Bool { model.unsavedSummaries[meeting.id] != nil }

    private struct LoadKey: Hashable {
        let id: MeetingID
        let status: ProcessingStatus
        let engine: EngineKind?
        let reloadRevision: Int
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
            if let success = model.actionSuccesses[meeting.id] {
                successCard(success)
            }
            MeetingStatusCards(meeting: meeting)
            MeetingHeader(meeting: meeting, edit: edit, report: report)
            Divider()
            switch tab {
            case .recap:
                if summaryUnsaved {
                    Label("Unsaved recap changes", systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Theme.attentionText)
                        .padding(.vertical, Space.s)
                }
                SummaryEditor(meeting: meeting, summary: summary, onEdit: saveSummary, onSource: show(segment:))
            case .transcript:
                TranscriptView(meeting: meeting, transcript: transcript, clean: clean, mode: $transcriptMode, target: $scrollTarget, report: report)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar { MeetingToolbar(meeting: meeting, summary: summary, tab: $tab, restorePrevious: restorePrevious, openDraft: { showingDraft = true }) }
        .sheet(isPresented: $showingDraft) { DraftSheet(meeting: meeting, summary: summary) }
        .task(id: LoadKey(id: meeting.id, status: meeting.status, engine: meeting.summaryEngine, reloadRevision: model.reloadRevision)) {
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

    private func successCard(_ success: ActionSuccess) -> some View {
        let id = meeting.id
        let card: StatusCard
        switch success {
        case .draftCreated(let link):
            card = StatusCard(
                role: .success,
                title: "Draft created",
                actions: link.map { link in [StatusCard.Action(label: "Open in Outlook", run: { NSWorkspace.shared.open(link) })] } ?? [],
                onDismiss: { model.actionSuccesses[id] = nil }
            )
        case .filed(let url):
            card = StatusCard(
                role: .success,
                title: "Filed in Obsidian",
                actions: [StatusCard.Action(label: "Reveal", run: { NSWorkspace.shared.activateFileViewerSelecting([url]) })],
                onDismiss: { model.actionSuccesses[id] = nil }
            )
        }
        return card.inset()
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
