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
    @Binding var transcriptMode: TranscriptMode
    let transcript: TranscriptController
    let hasTranscript: Bool
    let restorePrevious: () -> Void
    let openDraft: () -> Void

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
        if tab == .transcript {
            let noTranscript = hasTranscript ? nil : "There's no transcript yet"
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Transcript view", selection: $transcriptMode) {
                    ForEach(TranscriptMode.allCases, id: \.self) { mode in
                        Text(mode.label)
                            .tag(mode)
                            .help(ifPresent: mode == .changes ? "Show changes" : nil)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Transcript view")

                Button {
                    transcript.showFind()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f")
                .disabled(noTranscript != nil)
                .help(noTranscript ?? "Search the transcript")

                CopyAllButton(transcript: transcript, disabledReason: noTranscript)
            }
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
            .help(regenerate ?? ((summary?.engine ?? meeting.summaryEngine) == nil ? "Write the recap with another engine" : "Write the recap again with another engine"))

            Button(action: openDraft) {
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
                    .help(ifPresent: trash)
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

/// "Copy all", which reads "Copied" for 2 s after a copy.
private struct CopyAllButton: View {
    let transcript: TranscriptController
    let disabledReason: String?

    @State private var copied = false

    var body: some View {
        Button {
            transcript.copyAll()
            copied = true
        } label: {
            Label(copied ? "Copied" : "Copy all", systemImage: "doc.on.doc")
        }
        .disabled(disabledReason != nil)
        .help(disabledReason ?? "Copy the whole transcript")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

extension View {
    /// A tooltip only when there is something to say, so an enabled control has none.
    @ViewBuilder
    func help(ifPresent reason: String?) -> some View {
        if let reason { help(reason) } else { self }
    }
}
