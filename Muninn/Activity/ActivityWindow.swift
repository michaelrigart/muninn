import AppKit
import MuninnCore
import SwiftUI

struct ActivityCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Activity") {
                WindowPresenter.present { openWindow(id: "activity") }
            }
        }
    }
}

/// Reads the model for the ids of the meetings that exist and hands them to a window that rebuilds only when they change.
struct ActivityWindowHost: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ActivityWindow(model: model, meetingIDs: Set(model.meetings.map(\.id)))
            .equatable()
    }
}

struct ActivityWindow: View, Equatable {
    /// Not observed: the rows need the model only to open a meeting and to read the settings for the diagnostics.
    let model: AppModel
    let meetingIDs: Set<MeetingID>

    @EnvironmentObject private var activity: ActivityCenter

    @State private var filter = Filter.all
    @State private var query = ""
    @State private var selection: UUID?
    @State private var copiedDiagnostics = false

    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case problems = "Problems"

        var id: String { rawValue }
    }

    private struct Day: Identifiable {
        let start: Date
        let entries: [ActivityEntry]

        var id: Date { start }
    }

    nonisolated static func == (lhs: ActivityWindow, rhs: ActivityWindow) -> Bool {
        lhs.meetingIDs == rhs.meetingIDs
    }

    private static let timeFormatter: DateFormatter = formatter("HH:mm:ss")
    private static let stampFormatter: DateFormatter = formatter("yyyy-MM-dd HH:mm:ss")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    var body: some View {
        let shown = filtered
        let days = Self.days(shown)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.entries) { entry in
                                ActivityRow(
                                    entry: entry,
                                    time: Self.timeFormatter.string(from: entry.time),
                                    expanded: selection == entry.id,
                                    meetingExists: entry.meeting.map { meetingIDs.contains($0.id) } ?? false,
                                    copyText: copyText(entry),
                                    showMeeting: model.showMeeting
                                )
                                .tag(entry.id)
                            }
                        } header: {
                            Text(day.start.formatted(date: .complete, time: .omitted))
                        }
                    }
                }
                .overlay {
                    if shown.isEmpty {
                        Text(filter == .all && query.isEmpty ? "No activity yet" : emptyMessage)
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .task(id: activity.focusedEntryID) {
                    await focus(proxy)
                }
            }
            Divider()
            footer
        }
        .searchable(text: $query, prompt: "Search activity")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            ToolbarItem {
                Button(copiedDiagnostics ? "Copied" : "Copy diagnostics", action: copyDiagnostics)
            }
        }
        .tint(Theme.accent)
        .task(id: copiedDiagnostics) {
            guard copiedDiagnostics else { return }
            try? await Task.sleep(for: .seconds(2))
            copiedDiagnostics = false
        }
    }

    private var footer: some View {
        HStack {
            Button("Show log file in Finder") { activity.revealLogFile() }
                .buttonStyle(.link)
            Spacer()
            Text("Muninn keeps 14 days of activity.")
                .foregroundStyle(Theme.secondaryText)
        }
        .font(Theme.meta)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
    }

    private var emptyMessage: String {
        filter == .problems && query.isEmpty ? "No problems" : "No matches"
    }

    // MARK: Filtering

    private var filtered: [ActivityEntry] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return activity.entries.filter { entry in
            (filter == .all || entry.level == .problem) && (term.isEmpty || activity.matches(entry, term: term))
        }
    }

    private static func days(_ entries: [ActivityEntry], calendar: Calendar = .current) -> [Day] {
        var days: [Day] = []
        var current: (start: Date, entries: [ActivityEntry])?
        for entry in entries {
            let start = calendar.startOfDay(for: entry.time)
            if current?.start == start {
                current?.entries.append(entry)
            } else {
                if let current { days.append(Day(start: current.start, entries: current.entries)) }
                current = (start, [entry])
            }
        }
        if let current { days.append(Day(start: current.start, entries: current.entries)) }
        return days
    }

    // MARK: Actions

    private func focus(_ proxy: ScrollViewProxy) async {
        guard let id = activity.focusedEntryID else { return }
        if !filtered.contains(where: { $0.id == id }) {
            filter = .all
            query = ""
        }
        selection = id
        try? await Task.sleep(for: .milliseconds(50))
        proxy.scrollTo(id, anchor: .center)
        activity.focusedEntryID = nil
    }

    private func copyDiagnostics() {
        Task {
            let text = await activity.diagnostics(settings: model.settings)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedDiagnostics = true
        }
    }

    private func copyText(_ entry: ActivityEntry) -> String {
        var parts = [Self.stampFormatter.string(from: entry.time), entry.level.rawValue, entry.area.label]
        if let meeting = entry.meeting { parts.append(meeting.title.isEmpty ? meeting.id.rawValue : meeting.title) }
        parts.append(entry.message)
        return ([parts.joined(separator: " · ")] + (entry.details?.lines(includeHost: true) ?? [])).joined(separator: "\n")
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry
    let time: String
    let expanded: Bool
    let meetingExists: Bool
    let copyText: String
    let showMeeting: (MeetingID) -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(time)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.tertiaryText)
                icon
                Text(entry.area.label)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.secondaryText)
                Text(entry.message)
                    .font(Theme.interface)
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(expanded ? nil : 1)
                    .fixedSize(horizontal: false, vertical: expanded)
                Spacer(minLength: Space.s)
                if let meeting = entry.meeting, meetingExists {
                    Button(meeting.title.isEmpty ? meeting.id.rawValue : meeting.title) { showMeeting(meeting.id) }
                        .buttonStyle(.link)
                        .font(Theme.meta)
                        .lineLimit(1)
                }
            }
            if expanded {
                details
            }
        }
        .padding(.vertical, 2)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let text = entry.details?.text(includeHost: true), !text.isEmpty {
                Text(text)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(.leading, Space.xl)
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.level {
        case .info:
            Image(systemName: "info.circle")
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Info")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.attentionText)
                .accessibilityLabel("Warning")
        case .problem:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(Theme.problem)
                .accessibilityLabel("Problem")
        }
    }
}
