import MuninnCore
import SwiftUI

struct MeetingGroup: Identifiable {
    let title: String
    let meetings: [Meeting]

    var id: String { title }
}

enum MeetingGrouping {
    static func groups(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [MeetingGroup] {
        let titles = ["Today", "Yesterday", "This week", "Earlier"]
        var buckets: [String: [Meeting]] = [:]
        for meeting in meetings {
            let title: String
            if calendar.isDate(meeting.startedAt, inSameDayAs: now) {
                title = titles[0]
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(meeting.startedAt, inSameDayAs: yesterday) {
                title = titles[1]
            } else if calendar.isDate(meeting.startedAt, equalTo: now, toGranularity: .weekOfYear) {
                title = titles[2]
            } else {
                title = titles[3]
            }
            buckets[title, default: []].append(meeting)
        }
        return titles.compactMap { title in
            buckets[title].map { MeetingGroup(title: title, meetings: $0) }
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var summaryText: [MeetingID: String] = [:]

    private struct Stamp: Hashable {
        let id: MeetingID
        let status: ProcessingStatus
        let engine: EngineKind?
    }

    private struct SearchKey: Hashable {
        let active: Bool
        let stamps: [Stamp]
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            if let id = model.selectedMeetingID, let meeting = model.meetings.first(where: { $0.id == id }) {
                MeetingDetail(meeting: meeting)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "waveform")
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .task(id: SearchKey(active: !trimmedQuery.isEmpty, stamps: model.meetings.map { Stamp(id: $0.id, status: $0.status, engine: $0.summaryEngine) })) {
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
                Section(group.title) {
                    ForEach(group.meetings) { meeting in
                        SidebarRow(meeting: meeting)
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Delete Meeting…", role: .destructive) { model.deleteMeeting(meeting.id) }
                                    .disabled(!MeetingActions.canDelete(meeting))
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
                Text("All meetings").tag(SidebarFilter.all)
                Text("Needs attention (\(model.meetings.filter(\.needsAttention).count))").tag(SidebarFilter.needsAttention)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
    }

    private var emptyText: String {
        if !trimmedQuery.isEmpty { return "No matches" }
        return model.sidebarFilter == .needsAttention ? "Nothing needs attention" : "No meetings yet"
    }

    private var filtered: [Meeting] {
        let term = trimmedQuery
        let meetings = model.sidebarFilter == .needsAttention ? model.meetings.filter(\.needsAttention) : model.meetings
        guard !term.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.localizedStandardContains(term)
                || (meeting.client?.localizedStandardContains(term) ?? false)
                || meeting.attendees.contains { $0.name.localizedStandardContains(term) || $0.email.localizedStandardContains(term) }
                || (summaryText[meeting.id]?.localizedStandardContains(term) ?? false)
        }
    }

    private func loadSummaryText() async {
        guard !trimmedQuery.isEmpty else { return }
        let store = model.store
        let ids = model.meetings.map(\.id)
        let loaded = await Task.detached {
            var result: [MeetingID: String] = [:]
            for id in ids {
                guard let summary = try? store.loadSummary(id) else { continue }
                result[id] = summary.subjects.flatMap { subject in
                    [subject.title] + subject.bullets.map(\.text) + subject.actions.flatMap { [$0.owner, $0.text] }
                }.joined(separator: "\n")
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
