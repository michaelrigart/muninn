import AppKit
import MuninnCore
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "obsidian")

extension AppModel {
    func exportToObsidian(_ id: MeetingID) {
        Task {
            await perform("export to Obsidian", for: id) {
                _ = try await export(id, askToOverwrite: true)
            }
        }
    }

    /// Files a ready, settled meeting automatically when that is enabled; an existing note is never overwritten.
    func autoFile(_ id: MeetingID) async {
        guard settings.autoFileToObsidian, unsavedSummaries[id] == nil, !eventChangesInFlight.contains(id) else { return }
        let meeting: Meeting
        do {
            meeting = try store.load(id)
        } catch {
            logger.error("Auto-filing \(id.rawValue, privacy: .public) skipped, loading failed: \(String(describing: error), privacy: .public)")
            return
        }
        let unsourced = (try? store.loadSummary(id)).map(MeetingActions.unsourcedItemCount(in:)) ?? 0
        switch MeetingActions.autoFileDecision(
            meeting, settings: settings, hasUnsavedEdits: unsavedSummaries[id] != nil, eventChangeInFlight: eventChangesInFlight.contains(id),
            unsourcedItems: unsourced, vaultNoticeShown: vaultNoticeShown
        ) {
        case .skip:
            return
        case .unsourced(let count):
            actionNotices[id] = "Not filed automatically: \(Self.unsourcedPhrase(count))"
            return
        case .vaultNotChosen(let showNotice):
            if showNotice {
                vaultNoticeShown = true
                actionNotices[id] = MeetingActions.vaultNotChosenNotice
            }
            logger.info("Not auto-filing \(id.rawValue, privacy: .public): no vault chosen")
            return
        case .file:
            break
        }
        await perform("export to Obsidian", for: id) {
            if try await !export(id, askToOverwrite: false) {
                logger.info("Not auto-filing \(id.rawValue, privacy: .public): a note already exists")
            }
        }
    }

    /// Returns false when nothing was written: a note already exists and was kept, or the user cancelled.
    private func export(_ id: MeetingID, askToOverwrite: Bool) async throws -> Bool {
        guard !eventChangesInFlight.contains(id) else { throw MeetingActionError.eventChangeInProgress }
        let meeting = try store.load(id)
        guard unsavedSummaries[id] == nil else { throw MeetingActionError.unsavedEdits }
        guard meeting.candidateEvents.isEmpty else { throw MeetingActionError.eventUnsettled }
        guard meeting.status == .ready else { throw MeetingActionError.notReady }
        guard let summary = try store.loadSummary(id) else { throw MeetingActionError.noSummary }

        let settings = self.settings
        if MeetingActions.exportRefusal(settings: settings) != nil { throw MeetingActionError.vaultNotChosen }
        let vault = URL(fileURLWithPath: (settings.vaultPath as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeetingActionError.vaultMissing(vault.path)
        }
        let unsourced = MeetingActions.unsourcedItemCount(in: summary)
        if unsourced > 0, !askToOverwrite || !confirmUnsourcedItems(unsourced, for: id) { return false }

        var relativePath = NotePlanner.relativePath(meeting: meeting, settings: settings, timeZone: .current)
        var overwrite = false
        if let stored = meeting.exportedNotePath, stored != relativePath,
           FileManager.default.fileExists(atPath: vault.appendingPathComponent(stored).path) {
            switch Alerts.ask(
                "The note has a different name now",
                "This meeting was filed as \(stored), but it would now be filed as \(relativePath).",
                buttons: ["Update Existing Note", "Create New Note", "Cancel"]
            ) {
            case 0:
                relativePath = stored
                overwrite = true
            case 1:
                break
            default:
                return false
            }
        }

        let audio = [Track.mic, Track.system].map { store.audioURL(id, track: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        let attachments = settings.vaultIncludesAudio ? audio : []
        let embedded = settings.vaultIncludesTranscript
            ? NotePlanner.transcriptBody(
                clean: try? String(contentsOf: store.cleanTranscriptMarkdownURL(id), encoding: .utf8),
                raw: try? String(contentsOf: store.transcriptMarkdownURL(id), encoding: .utf8)
            )
            : nil
        let note = MeetingNoteRenderer.render(meeting: meeting, summary: summary, options: NoteOptions(
            transcriptLink: store.transcriptMarkdownURL(id),
            embeddedTranscript: embedded,
            audioLinks: audio,
            embeddedAudioFileNames: attachments.map { ObsidianExporter.attachmentName(forNote: relativePath, source: $0) },
            timeZone: .current,
            relatedNotes: NotePlanner.relatedNotes(for: meeting, among: meetings)
        ))

        let exporter = ObsidianExporter(vault: vault)
        let path = relativePath
        func run(overwrite: Bool) async throws -> ExportOutcome {
            try await Task.detached {
                try exporter.export(note: note, relativePath: path, attachments: attachments, overwrite: overwrite)
            }.value
        }
        var outcome = try await run(overwrite: overwrite)
        if case .alreadyExists = outcome {
            guard askToOverwrite,
                  Alerts.ask("A note already exists", "\(path) is already in the vault. Overwrite?", buttons: ["Overwrite", "Cancel"], destructiveFirst: true) == 0
            else { return false }
            outcome = try await run(overwrite: true)
        }
        guard case .written = outcome else { return false }
        try mutate(id) { $0.exportedNotePath = path }
        return true
    }
}
