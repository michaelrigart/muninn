import MuninnCore
import SwiftUI

/// The Meetings window's sidebar column: smart lists, then the meetings grouped by day.
struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var searchText: [MeetingID: SearchText] = [:]
    @State private var textGeneration = 0
    @State private var matchedIDs: Set<MeetingID>?
    /// The recap and transcript text has loaded since the search began.
    @State private var searchTextLoaded = false
    /// The `textGeneration` that `matchedIDs` was matched against.
    @State private var matchedGeneration = -1

    private struct SearchText: Sendable {
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

    private struct MatchKey: Hashable {
        let term: String
        let meetings: [Meeting]
        let textGeneration: Int
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
                                    .help(ifPresent: reason)
                            }
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty {
                if isSearching {
                    HStack(spacing: Space.s) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Searching…")
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
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
        .task(id: MatchKey(term: trimmedQuery, meetings: model.meetings, textGeneration: textGeneration)) {
            await updateMatches()
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

    /// A query whose first text load, or the match against it, is still running.
    private var isSearching: Bool {
        !trimmedQuery.isEmpty && (!searchTextLoaded || matchedGeneration != textGeneration)
    }

    private var emptyText: String {
        if !trimmedQuery.isEmpty { return "No matches" }
        return model.sidebarFilter == .needsAttention ? "Nothing needs attention" : "No meetings yet"
    }

    /// With a query, a lookup in the ids matched off the main thread; until the first result arrives, the fields that need no file.
    private var filtered: [Meeting] {
        let meetings = model.sidebarFilter == .needsAttention ? model.meetings.filter { ProcessingDisplay.needsAttention($0, snapshot: model.pipelineSnapshot) } : model.meetings
        let term = trimmedQuery
        guard !term.isEmpty else { return meetings }
        if let matchedIDs { return meetings.filter { matchedIDs.contains($0.id) } }
        return meetings.filter { MeetingSearch.matches($0, term: term, recapText: nil, transcriptText: nil) }
    }

    private func loadSearchText() async {
        guard !trimmedQuery.isEmpty else {
            searchTextLoaded = false
            return
        }
        let store = model.store
        let ids = model.meetings.map(\.id)
        let loaded = await offMain {
            var result: [MeetingID: SearchText] = [:]
            for id in ids {
                if Task.isCancelled { break }
                let recap = (try? store.loadSummary(id)).map(MeetingSearch.recapText) ?? ""
                let transcript = (try? String(contentsOf: store.cleanTranscriptMarkdownURL(id), encoding: .utf8))
                    ?? (try? String(contentsOf: store.transcriptMarkdownURL(id), encoding: .utf8))
                    ?? ""
                result[id] = SearchText(recap: recap, transcript: transcript)
            }
            return result
        }
        guard !Task.isCancelled else { return }
        searchText = loaded
        searchTextLoaded = true
        textGeneration += 1
    }

    private func updateMatches() async {
        let term = trimmedQuery
        guard !term.isEmpty else {
            matchedIDs = nil
            return
        }
        let meetings = model.meetings
        let texts = searchText
        let generation = textGeneration
        let matched = await offMain {
            var ids = Set<MeetingID>()
            for meeting in meetings {
                if Task.isCancelled { break }
                let text = texts[meeting.id]
                if MeetingSearch.matches(meeting, term: term, recapText: text?.recap, transcriptText: text?.transcript) { ids.insert(meeting.id) }
            }
            return ids
        }
        guard !Task.isCancelled else { return }
        matchedIDs = matched
        matchedGeneration = generation
    }

    /// Runs `work` on a detached task that is cancelled with the caller, so `work` can stop early on `Task.isCancelled`.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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
                PlayingMark(meetingID: meeting.id)
                sign
            }
            HStack(spacing: Space.xs + 2) {
                Text(MeetingLabels.sidebarTime(start: meeting.startedAt, end: meeting.endedAt, group: group, now: Date(), calendar: .current, locale: .current))
                    .font(Theme.meta)
                    .rowSecondaryText()
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
            .rowSecondaryText()
            .lineLimit(1)
            .help(text)
            .accessibilityLabel(text)
    }
}

/// The animated level mark on the row of the meeting that is playing. Its own view, so only it follows the player.
private struct PlayingMark: View {
    @EnvironmentObject private var player: MeetingPlayer
    let meetingID: MeetingID

    var body: some View {
        if player.isPlaying, player.meetingID == meetingID {
            Image(systemName: "waveform")
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative)
                .help("Playing")
                .accessibilityLabel("Playing")
        }
    }
}
