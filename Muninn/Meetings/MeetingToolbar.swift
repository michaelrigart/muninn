import MuninnCore
import SwiftUI

enum DetailTab: String, CaseIterable, Identifiable {
    case recap, transcript

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recap: "Recap"
        case .transcript: "Transcript"
        }
    }
}

/// The Meetings window's toolbar: the Recap / Transcript picker and the actions for the selected meeting.
struct MeetingToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let summary: Summary?
    @Binding var tab: DetailTab
    let restorePrevious: () -> Void

    private var context: MeetingCommandContext {
        model.commandContext(for: meeting, hasRecap: summary != nil)
    }

    var body: some ToolbarContent {
        let context = context
        let regenerate = MeetingCommands.disabledReason(.regenerate, context)
        let draft = MeetingCommands.disabledReason(.outlookDraft, context)
        let obsidian = MeetingCommands.disabledReason(.obsidian, context)
        let previous = MeetingCommands.disabledReason(.previousVersion, context)
        let trash = MeetingCommands.disabledReason(.moveToTrash, context)

        ToolbarItem(placement: .principal) {
            Picker("View", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("View")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Section("Write the recap with") {
                    ForEach(EngineKind.allCases, id: \.self) { engine in
                        Button {
                            model.regenerate(meeting.id, engine: engine)
                        } label: {
                            Text(engine.displayName)
                            if engine == .claude {
                                Text("Sends the transcript off the Mac to Anthropic")
                            }
                        }
                    }
                }
            } label: {
                Text(engineName)
            }
            .disabled(regenerate != nil)
            .help(regenerate ?? "Write the recap again with another engine")

            Button {
                model.createDraft(meeting.id)
            } label: {
                Label("Outlook draft", systemImage: "envelope")
            }
            .disabled(draft != nil)
            .help(draft ?? "Create a draft email with the recap in Outlook")

            Button {
                model.exportToObsidian(meeting.id)
            } label: {
                Label("Obsidian", systemImage: "tray.and.arrow.down")
            }
            .disabled(obsidian != nil)
            .help(obsidian ?? "Save the recap as a note in Obsidian")

            Menu {
                Button("Previous version", action: restorePrevious)
                    .disabled(previous != nil)
                    .help(previous ?? "Swap back to the recap that was replaced when this one was written")
                Divider()
                Button("Move to Trash…", role: .destructive) { model.trashMeeting(meeting.id) }
                    .disabled(trash != nil)
                    .help(trash ?? "")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
            .help("More")
        }
    }

    private var engineName: String {
        (summary?.engine ?? meeting.summaryEngine)?.displayName ?? "Write recap"
    }
}
