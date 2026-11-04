import MuninnCore
import SwiftUI

/// The Meetings window's sidebar column: smart lists, then the meetings grouped by day.
struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var searchText: [MeetingID: SearchText] = [:]

    private struct SearchText {
        var recap: String
        var transcript: String
    }

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
        let groups = MeetingGrouping.groups(filtered)
        List(selection: $model.selectedMeetingID) {
            ForEach(groups) { group in
                Section(group.group.title) {
                    ForEach(group.meetings) { meeting in
                        SidebarRow(meeting: meeting, group: group.group)
                            .tag(meeting.id)
                            .contextMenu {
                                let reason = MeetingCommands.disabledReason(.moveToTrash, model.commandContext(for: meeting, includePreviousRecap: false))
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
            VStack(spacing: 2) {
                smartList(.all, title: "All meetings", systemImage: "tray.full", count: nil)
                smartList(.needsAttention, title: "Needs attention", systemImage: "exclamationmark.circle", count: attentionCount > 0 ? attentionCount : nil)
            }
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.s)
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search meetings")
        .task(id: SearchKey(active: !trimmedQuery.isEmpty, stamps: model.meetings.map { Stamp(id: $0.id, status: $0.status, engine: $0.summaryEngine) }, reloadRevision: model.reloadRevision)) {
            await loadSearchText()
        }
    }

    private func smartList(_ filter: SidebarFilter, title: String, systemImage: String, count: Int?) -> some View {
        let selected = model.sidebarFilter == filter
        return Button {
            model.sidebarFilter = filter
        } label: {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                if let count {
                    Text("\(count)")
                        .font(Theme.meta)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .font(Theme.interface)
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: Radius.card))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return meetings.filter {
            let text = searchText[$0.id]
            return MeetingSearch.matches($0, term: term, recapText: text?.recap, transcriptText: text?.transcript)
        }
    }

    private func loadSearchText() async {
        guard !trimmedQuery.isEmpty else { return }
        let store = model.store
        let ids = model.meetings.map(\.id)
        let loaded = await Task.detached {
            var result: [MeetingID: SearchText] = [:]
            for id in ids {
                let recap = (try? store.loadSummary(id)).map(MeetingSearch.recapText) ?? ""
                let transcript = (try? String(contentsOf: store.cleanTranscriptMarkdownURL(id), encoding: .utf8))
                    ?? (try? String(contentsOf: store.transcriptMarkdownURL(id), encoding: .utf8))
                    ?? ""
                result[id] = SearchText(recap: recap, transcript: transcript)
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        searchText = loaded
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let group: DayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Text(meeting.title)
                    .font(Theme.interface.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: Space.xs)
                sign
            }
            HStack(spacing: Space.xs + 2) {
                Text(MeetingLabels.sidebarTime(start: meeting.startedAt, end: meeting.endedAt, group: group, now: Date(), calendar: .current, locale: .current))
                    .font(Theme.meta)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let client = meeting.client, !client.isEmpty {
                    Chip(text: client)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var sign: some View {
        let sign = SidebarSign.sign(
            for: meeting,
            progress: model.progress(for: meeting),
            needsAttention: ProcessingDisplay.needsAttention(meeting, snapshot: model.pipelineSnapshot)
        )
        switch sign {
        case .progress(let step, let label):
            ProgressView(value: Double(step) / 4)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .help(label)
                .accessibilityLabel(label)
        case .queued:
            ProgressView()
                .controlSize(.mini)
                .help("Waiting its turn")
                .accessibilityLabel("Waiting its turn")
        case .attention:
            Circle()
                .fill(Theme.attentionFill)
                .frame(width: 8, height: 8)
                .help("Needs attention")
                .accessibilityElement()
                .accessibilityLabel("Needs attention")
        case .recording:
            Image(systemName: "record.circle")
                .foregroundStyle(Theme.recording)
                .help("Recording")
                .accessibilityLabel("Recording")
        case .draftCreated:
            note("Draft created")
        case .filed:
            note("Filed")
        case .none:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.meta)
            .foregroundStyle(Theme.tertiaryText)
            .lineLimit(1)
            .help(text)
            .accessibilityLabel(text)
    }
}
