import MuninnCore
import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var tab = DetailTab.recap
    @State private var transcriptMode = TranscriptMode.clean
    @State private var summaryText: [MeetingID: String] = [:]

    private struct Stamp: Hashable {
        let id: MeetingID
        let status: ProcessingStatus
        let engine: EngineKind?
    }

    private struct SearchKey: Hashable {
        let active: Bool
        let stamps: [Stamp]
        let reloadRevision: Int
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let id = model.selectedMeetingID, let meeting = model.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting, tab: $tab, transcriptMode: $transcriptMode)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "waveform")
                    .navigationTitle("Meetings")
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .task(id: SearchKey(active: !trimmedQuery.isEmpty, stamps: model.meetings.map { Stamp(id: $0.id, status: $0.status, engine: $0.summaryEngine) }, reloadRevision: model.reloadRevision)) {
            await loadSummaryText()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sidebar: some View {
        let groups = MeetingGrouping.groups(filtered)
        return List(selection: $model.selectedMeetingID) {
            ForEach(groups) { group in
                Section(group.group.title) {
                    ForEach(group.meetings) { meeting in
                        SidebarRow(meeting: meeting)
                            .tag(meeting.id)
                            .contextMenu {
                                let reason = MeetingCommands.disabledReason(.moveToTrash, model.commandContext(for: meeting))
                                Button("Move to Trash…", role: .destructive) { model.trashMeeting(meeting.id) }
                                    .disabled(reason != nil)
                                    .help(reason ?? "")
                            }
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $model.sidebarFilter) {
                Text("All").tag(SidebarFilter.all)
                Text("Needs attention (\(attentionCount))").tag(SidebarFilter.needsAttention)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
    }

    private var attentionCount: Int {
        model.meetings.filter { ProcessingDisplay.needsAttention($0, snapshot: model.pipelineSnapshot) }.count
    }

    private var emptyText: String {
        if !trimmedQuery.isEmpty { return "No matches" }
        return model.sidebarFilter == .needsAttention ? "Nothing needs attention" : "No meetings yet"
    }

    private var filtered: [Meeting] {
        let term = trimmedQuery
        let meetings = model.sidebarFilter == .needsAttention ? model.meetings.filter { ProcessingDisplay.needsAttention($0, snapshot: model.pipelineSnapshot) } : model.meetings
        guard !term.isEmpty else { return meetings }
        return meetings.filter { MeetingSearch.matches($0, term: term, recapText: summaryText[$0.id], transcriptText: nil) }
    }

    private func loadSummaryText() async {
        guard !trimmedQuery.isEmpty else { return }
        let store = model.store
        let ids = model.meetings.map(\.id)
        let loaded = await Task.detached {
            var result: [MeetingID: String] = [:]
            for id in ids {
                guard let summary = try? store.loadSummary(id) else { continue }
                result[id] = MeetingSearch.recapText(summary)
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        summaryText = loaded
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meeting.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                sign
            }
            Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var sign: some View {
        let progress = model.progress(for: meeting)
        switch progress {
        case .working(let work):
            ring(step: work.stage.step, label: progress.title)
        case .preparingSpeechModel:
            ring(step: 1, label: progress.title)
        case .queued:
            ProgressView()
                .controlSize(.mini)
                .help("Waiting its turn")
                .accessibilityLabel("Waiting its turn")
        default:
            if meeting.needsAttention {
                Circle()
                    .fill(Theme.attentionFill)
                    .frame(width: 8, height: 8)
                    .help("Needs attention")
                    .accessibilityElement()
                    .accessibilityLabel("Needs attention")
            } else if meeting.status == .recording {
                Image(systemName: "record.circle")
                    .foregroundStyle(Theme.recording)
                    .help("Recording")
                    .accessibilityLabel("Recording")
            }
        }
    }

    private func ring(step: Int, label: String?) -> some View {
        ProgressView(value: Double(step) / 4)
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .help(label ?? "")
            .accessibilityLabel(label ?? "")
    }
}
