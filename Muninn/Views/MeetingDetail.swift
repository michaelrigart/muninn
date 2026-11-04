import AppKit
import MuninnCore
import SwiftUI

struct MeetingDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var player: MeetingPlayer
    @Environment(\.undoManager) private var undoManager
    let meeting: Meeting
    @Binding var tab: DetailTab
    @Binding var transcriptMode: TranscriptMode

    @State private var summary: Summary?
    @State private var document: RecapDocument?
    @State private var recapFocus = RecapFocus()
    @State private var transcript: Transcript?
    @State private var clean: CleanTranscript?
    @State private var lanes: [PlaybackLane] = []
    @State private var speakerIndices: [String: Int] = [:]
    @State private var saveError: Problem?
    @State private var showingDraft = false
    @StateObject private var transcriptController = TranscriptController()

    private var summaryUnsaved: Bool { model.unsavedSummaries[meeting.id] != nil }
    private var canPlay: Bool { player.meetingID == meeting.id && player.state == .ready }

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
                recapEditor
            case .transcript:
                if let transcript {
                    TranscriptTextView(
                        meeting: meeting,
                        transcript: transcript,
                        clean: clean,
                        mode: transcriptMode,
                        controller: transcriptController,
                        onRename: renameSpeaker,
                        onSeek: listen(from:)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        TranscriptFollowButton(controller: transcriptController, meetingID: meeting.id)
                    }
                } else {
                    ContentUnavailableView("No transcript yet", systemImage: "text.alignleft")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if meeting.status != .recording {
                PlayerBar(meeting: meeting, lanes: lanes, speakerIndices: speakerIndices)
            }
        }
        .navigationTitle(meeting.title)
        .toolbar {
            MeetingToolbar(
                meeting: meeting,
                summary: summary,
                tab: $tab,
                transcriptMode: $transcriptMode,
                transcript: transcriptController,
                hasTranscript: transcript != nil,
                restorePrevious: restorePrevious,
                openDraft: { showingDraft = true }
            )
        }
        .sheet(isPresented: $showingDraft) { DraftSheet(meeting: meeting, summary: summary) }
        .onReceive(player.seeks) { _ in
            if player.meetingID == meeting.id { transcriptController.following = true }
        }
        .onDisappear {
            guard let document else { return }
            document.endTyping(undoManager: undoManager)
            undoManager?.removeAllActions(withTarget: document)
        }
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
            player.timeline = transcript.map(SegmentTimeline.init(transcript:))
            clean = model.loadFile("transcript.clean.json", for: meeting) { try store.loadClean(id) }
            lanes = transcript.map(PlaybackLanes.lanes(for:)) ?? []
            speakerIndices = transcript.map(SpeakerColours.indices(for:)) ?? [:]
            adoptDocument()
        }
    }

    private var recapEditor: some View {
        let context = model.commandContext(for: meeting, hasRecap: summary != nil)
        return RecapEditor(
            meeting: meeting,
            document: document,
            focus: recapFocus,
            summary: summary,
            segmentStarts: segmentStarts,
            canPlay: canPlay,
            onSource: show(segment:),
            hasPreviousVersion: context.hasPreviousRecap,
            onPreviousVersion: restorePrevious,
            previousVersionReason: MeetingCommands.disabledReason(.previousVersion, context)
        )
    }

    private var segmentStarts: [Int: TimeInterval] {
        Dictionary(
            (transcript?.segments ?? []).map { ($0.id, $0.start) },
            uniquingKeysWith: min
        )
    }

    /// Points the recap document at the loaded summary: a new document the first time, `replace` afterwards when the
    /// recap changed, which drops the undo history of what was replaced.
    private func adoptDocument() {
        guard let summary else {
            if let document {
                recapFocus.resign()
                document.endTyping(undoManager: undoManager)
                undoManager?.removeAllActions(withTarget: document)
            }
            document = nil
            return
        }
        guard let document else {
            self.document = RecapDocument(summary: summary, save: saveSummary)
            return
        }
        var loaded = summary
        loaded.edited = document.summary.edited
        guard loaded != document.summary else { return }
        RecapEditing(document: document, undoManager: undoManager, focus: recapFocus).replace(with: summary)
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
            adoptDocument()
        } catch {
            do {
                summary = try model.store.loadSummary(meeting.id)
                report(error)
            } catch let reloadError {
                summary = nil
                model.activity.record(failure: reloadError, in: ProblemContext(stage: .loadingMeetings), meeting: meeting)
                report(error)
            }
            adoptDocument()
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

    /// With the recording ready, plays from the segment and follows it; without, scrolls to it and tints it.
    private func show(segment id: Int) {
        tab = .transcript
        if canPlay, let start = segmentStarts[id] {
            player.seek(to: start, play: true)
        } else {
            transcriptController.reveal(segmentID: id)
        }
    }

    private func listen(from time: TimeInterval) {
        guard canPlay else { return }
        player.seek(to: time, play: true)
    }

    private func renameSpeaker(_ speaker: String, to name: String) {
        guard let transcript else { return }
        do {
            try model.renameSpeaker(speaker, to: name, in: meeting.id, transcript: transcript, clean: clean)
        } catch {
            report(error)
        }
    }
}
