import MuninnCore
import SwiftUI

struct SummaryEditor: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let summary: Summary?
    let onEdit: (Summary) -> Void
    let onSource: (Int) -> Void
    let onRestore: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                banners
                toolbar
                if let summary {
                    ForEach(Array(summary.subjects.indices), id: \.self) { index in
                        subjectView(index)
                    }
                    Button {
                        mutate { $0.subjects.append(Subject(title: "New subject", bullets: [], actions: [])) }
                    } label: {
                        Label("Add subject", systemImage: "plus")
                    }
                } else if meeting.status == .ready {
                    Text("No summary yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mutate(_ change: (inout Summary) -> Void) {
        guard var updated = summary else { return }
        change(&updated)
        onEdit(updated)
    }

    @ViewBuilder
    private var banners: some View {
        switch meeting.status {
        case .waiting(.recording):
            banner(symbol: "pause.circle.fill", tint: .orange, text: WaitReason.recording.text) {}
        case .waiting(let reason):
            banner(symbol: "pause.circle.fill", tint: .orange, text: reason.text) {
                Button("Run on This Mac anyway") { model.regenerate(meeting.id, engine: .macbook) }
                    .disabled(hasUnsavedEdits || eventChanging)
                    .help(blockedHelp)
                if reason == .claudeKeyMissing {
                    SettingsLink {
                        Text("Add a Claude API key in Settings")
                    }
                } else {
                    Button("Use Claude") { model.regenerate(meeting.id, engine: .claude) }
                        .disabled(hasUnsavedEdits || eventChanging)
                        .help(blockedHelp)
                }
            }
        case .failed(let message):
            banner(symbol: "exclamationmark.triangle.fill", tint: .red, text: message) {
                Button("Retry") { model.process(meeting.id) }
            }
        case .ready:
            EmptyView()
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(meeting.status.label + "…")
                    .foregroundStyle(.secondary)
            }
        }
        if let notice = meeting.engineNotice {
            banner(symbol: "info.circle.fill", tint: .blue, text: notice) {}
        }
    }

    private func banner<Buttons: View>(symbol: String, tint: Color, text: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            buttons()
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu("Written by: \(engineName) ▾") {
                ForEach(EngineKind.allCases, id: \.self) { engine in
                    Button(engine.displayName) { model.regenerate(meeting.id, engine: engine) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy || heldForRecording || hasUnsavedEdits || eventChanging)
            .help(heldForRecording ? "Choose an engine once the recording has ended" : blockedHelp)
            if model.store.hasPreviousSummary(meeting.id) {
                Button("Restore Previous Recap", action: onRestore)
                    .disabled(isBusy || hasUnsavedEdits)
                    .help(hasUnsavedEdits ? "Save your edits first" : "Swap back to the recap that was replaced when this one was written")
            }
            Spacer()
            if eventUnsettled {
                Text("Choose the event above first")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("✉ Outlook draft") { model.createDraft(meeting.id) }
                .disabled(hasUnsavedEdits || eventChanging || eventUnsettled || meeting.status != .ready || !MeetingActions.canDraft(meeting, accounts: model.settings.accounts))
                .help(hasUnsavedEdits ? "Save your edits first" : eventChanging ? "Wait for the event change" : eventUnsettled ? "Choose the event, account and client before drafting" : "")
            Button("◆ To Obsidian") { model.exportToObsidian(meeting.id) }
                .disabled(hasUnsavedEdits || eventChanging || eventUnsettled || meeting.status != .ready || summary == nil)
                .help(hasUnsavedEdits ? "Save your edits first" : eventChanging ? "Wait for the event change" : eventUnsettled ? "Choose the event, account and client before exporting" : "")
        }
    }

    private var hasUnsavedEdits: Bool {
        model.unsavedSummaries[meeting.id] != nil
    }

    private var eventChanging: Bool {
        model.eventChangesInFlight.contains(meeting.id)
    }

    private var blockedHelp: String {
        hasUnsavedEdits ? "Save your edits first" : eventChanging ? "Wait for the event change" : ""
    }

    private var eventUnsettled: Bool {
        !meeting.candidateEvents.isEmpty
    }

    private var engineName: String {
        (summary?.engine ?? meeting.summaryEngine)?.displayName ?? "none"
    }

    private var heldForRecording: Bool {
        meeting.status == .waiting(.recording)
    }

    private var isBusy: Bool {
        switch meeting.status {
        case .recording, .transcribing, .diarizing, .cleaning, .summarizing: true
        default: false
        }
    }

    private func subjectView(_ s: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Subject", text: subjectTitle(s))
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects.remove(at: s) } }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove subject")
            }
            ForEach(Array((summary?.subjects[safe: s]?.bullets ?? []).indices), id: \.self) { b in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        TextField("Bullet", text: bulletText(s, b), axis: .vertical)
                            .textFieldStyle(.plain)
                        sourceChips(summary?.subjects[safe: s]?.bullets[safe: b]?.sources ?? [])
                        removeButton { if $0.subjects[safe: s]?.bullets[safe: b] != nil { $0.subjects[s].bullets.remove(at: b) } }
                    }
                    unsourcedMarker(summary?.subjects[safe: s]?.bullets[safe: b]?.sources ?? [])
                }
            }
            ForEach(Array((summary?.subjects[safe: s]?.actions ?? []).indices), id: \.self) { a in
                actionRow(s, a)
            }
            HStack(spacing: 12) {
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].bullets.append(Bullet(text: "", sources: [])) } }
                } label: {
                    Label("Bullet", systemImage: "plus")
                }
                Button {
                    mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].actions.append(ActionPoint(owner: "", text: "", due: nil, sources: [])) } }
                } label: {
                    Label("Action", systemImage: "plus")
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func actionRow(_ s: Int, _ a: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            actionFields(s, a)
            unsourcedMarker(summary?.subjects[safe: s]?.actions[safe: a]?.sources ?? [])
        }
    }

    @ViewBuilder
    private func unsourcedMarker(_ sources: [Int]) -> some View {
        if sources.isEmpty {
            Label("No transcript source — check this", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func actionFields(_ s: Int, _ a: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.square")
                .foregroundStyle(.secondary)
            TextField("Owner", text: actionOwner(s, a))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            TextField("Action", text: actionText(s, a), axis: .vertical)
                .textFieldStyle(.plain)
            dueControl(s, a)
            sourceChips(summary?.subjects[safe: s]?.actions[safe: a]?.sources ?? [])
            removeButton { if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions.remove(at: a) } }
        }
    }

    private func removeButton(_ remove: @escaping (inout Summary) -> Void) -> some View {
        Button {
            mutate(remove)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }

    private func sourceChips(_ sources: [Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(sources, id: \.self) { id in
                Button("S\(id)") { onSource(id) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Show in transcript")
            }
        }
    }

    private func subjectTitle(_ s: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.title ?? "" },
            set: { value in mutate { if $0.subjects.indices.contains(s) { $0.subjects[s].title = value } } }
        )
    }

    private func bulletText(_ s: Int, _ b: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.bullets[safe: b]?.text ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.bullets[safe: b] != nil { $0.subjects[s].bullets[b].text = value }
                }
            }
        )
    }

    private func actionOwner(_ s: Int, _ a: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.owner ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].owner = value }
                }
            }
        )
    }

    private func actionText(_ s: Int, _ a: Int) -> Binding<String> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.text ?? "" },
            set: { value in
                mutate {
                    if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].text = value }
                }
            }
        )
    }

    private func dueControl(_ s: Int, _ a: Int) -> some View {
        let due = summary?.subjects[safe: s]?.actions[safe: a]?.due
        return HStack(spacing: 6) {
            Toggle("Due date", isOn: hasDue(s, a))
                .toggleStyle(.checkbox)
            if let due {
                if let date = DueDate.date(from: due) {
                    DatePicker("Due date", selection: dueDate(s, a, fallback: date), displayedComponents: .date)
                        .labelsHidden()
                } else {
                    Button("“\(due)” is not a date: pick one") { setDue(s, a, DueDate.string(from: Date())) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
    }

    private func hasDue(_ s: Int, _ a: Int) -> Binding<Bool> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.due != nil },
            set: { on in setDue(s, a, on ? DueDate.string(from: Date()) : nil) }
        )
    }

    private func dueDate(_ s: Int, _ a: Int, fallback: Date) -> Binding<Date> {
        Binding(
            get: { summary?.subjects[safe: s]?.actions[safe: a]?.due.flatMap(DueDate.date(from:)) ?? fallback },
            set: { setDue(s, a, DueDate.string(from: $0)) }
        )
    }

    private func setDue(_ s: Int, _ a: Int, _ due: String?) {
        mutate {
            if $0.subjects[safe: s]?.actions[safe: a] != nil { $0.subjects[s].actions[a].due = due }
        }
    }
}
