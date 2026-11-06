import MuninnCore
import SwiftUI

/// The selected meeting's title, one meta line and one row of chips: its event, account and client, and attendees.
struct MeetingHeader: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let transcript: Transcript?
    let speakerIndices: [String: Int]
    let edit: ((inout Meeting) -> Void) -> Void
    let report: (Error) -> Void
    let onRename: (_ speaker: String, _ name: String) -> Void

    private static let shownAttendees = 4

    private var people: [Attendee] {
        meeting.attendees.filter { !$0.isResource }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            CommitTextField(title: "Title", value: meeting.title) { title in
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { edit { $0.title = trimmed } }
            }
            .textFieldStyle(.plain)
            .font(Theme.meetingTitle)

            metaLine

            ChipRow {
                EventChip(meeting: meeting, report: report)
                DetailsChip(meeting: meeting, edit: edit)
                speakerChips
                attendeeChips
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.m)
    }

    private var metaLine: some View {
        HStack(spacing: Space.s) {
            Text(MeetingLabels.meta(start: meeting.startedAt, end: meeting.endedAt, language: meeting.language, calendar: .current, locale: .current))
            if ProcessingDisplay.needsAttention(meeting, snapshot: model.pipelineSnapshot) {
                Label("Needs attention", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.attentionText)
            } else if let title = model.progress(for: meeting).title {
                Label(title, systemImage: "hourglass")
            }
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.secondaryText)
    }

    @ViewBuilder
    private var speakerChips: some View {
        let speakers = TranscriptSpeakers.headerSpeakers(meeting: meeting, transcript: transcript, userName: model.resolvedUserName)
        ForEach(speakers, id: \.label) { choice in
            SpeakerChip(
                choice: choice,
                colourIndex: speakerIndices[choice.label] ?? 0,
                initialName: meeting.speakerNames[choice.label] ?? "",
                onRename: onRename
            )
        }
    }

    @ViewBuilder
    private var attendeeChips: some View {
        let people = people
        ForEach(Array(people.prefix(Self.shownAttendees).enumerated()), id: \.offset) { _, attendee in
            PersonChip(name: attendee.name, email: attendee.email)
        }
        if people.count > Self.shownAttendees {
            let others = people.dropFirst(Self.shownAttendees)
            Token(label: "+\(others.count)", systemImage: nil)
                .help(others.map { $0.name.isEmpty ? $0.email : $0.name }.joined(separator: "\n"))
        }
    }
}
