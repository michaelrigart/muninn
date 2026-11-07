import AppKit
import MuninnCore
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "meetings")

/// What a filed note left behind for the meeting's success card.
enum ActionSuccess: Equatable {
    case filed(URL)
}

/// The answer to "N recap items have no transcript source".
enum UnsourcedChoice {
    case include, review, cancel
}

enum MeetingActionError: ProblemConvertible {
    case eventUnsettled
    case notReady
    case noSummary
    case unknownAccount
    case vaultNotChosen
    case vaultMissing(String)
    case unsavedEdits
    case eventChangeInProgress
    case exportInProgress

    func problem(in context: ProblemContext) -> Problem {
        switch self {
        case .eventUnsettled:
            return Self.warning("Choose the event first", "Muninn needs the calendar event before it can file the recap.")
        case .notReady:
            return Self.warning("The meeting isn't processed yet", "Wait for the recap, then try again.")
        case .noSummary:
            return Self.warning("There's no recap yet", "Write the recap first.")
        case .unknownAccount:
            return Self.warning("This meeting's account is no longer in Settings", "Choose another account for the meeting.")
        case .vaultNotChosen:
            return Problems.vaultNotChosen()
        case .vaultMissing(let path):
            return Self.warning("The Obsidian vault folder is missing", "Muninn can't find the vault folder. Choose it again in Obsidian settings.", ProblemDetails(path: path))
        case .unsavedEdits:
            return Self.warning("Save your recap edits first", "Muninn couldn't save your last changes. Save them, then try again.")
        case .eventChangeInProgress:
            return Self.warning("The event is being changed", "Try again in a moment.")
        case .exportInProgress:
            return Self.warning("A note is being filed", "Change the event once it has finished.")
        }
    }

    private static func warning(_ title: String, _ explanation: String, _ details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .warning, title: title, explanation: explanation, actions: [], details: details)
    }
}

extension AppModel {
    /// Applies `change` to the latest stored copy of the meeting under the store's lock, so neither a stale snapshot nor a
    /// concurrent pipeline write is lost. `change` must not call the store (the lock is not reentrant).
    func mutate(_ id: MeetingID, _ change: (inout Meeting) -> Void) throws {
        let meeting = try store.update(id) { change(&$0) }
        apply(meeting)
    }

    /// Names a transcript speaker for the meeting (a blank name puts the default back). The result says whether the Markdown
    /// transcript files carry the name.
    func renameSpeaker(_ speaker: String, to name: String, in id: MeetingID) throws -> SpeakerRenameResult {
        let result = try store.renameSpeaker(speaker, to: name, in: id, userName: resolvedUserName)
        apply(result.meeting)
        return result
    }

    /// Gives the chosen transcript lines to a speaker, unless Muninn is recording or working on the meeting. The check and
    /// the change happen in one step on the pipeline, so no job can be admitted between them.
    func changeSpeaker(of segmentIDs: Set<Int>, to target: SpeakerTarget, in id: MeetingID) async throws -> SpeakerChangeResult {
        try await pipeline.changeSpeaker(of: segmentIDs, to: target, in: id, userName: resolvedUserName)
    }

    /// Asks first, then moves the meeting's folder to the Trash. A meeting that is recording, being processed or has a job queued is refused;
    /// an exported Obsidian note is never touched, but its links to the audio and transcript stop working until the meeting is put back.
    func trashMeeting(_ id: MeetingID) {
        Task { await confirmAndTrash(id) }
    }

    private func confirmAndTrash(_ id: MeetingID) async {
        guard let meeting = try? store.load(id) else { return }
        guard await canTrash(meeting) else {
            _ = Alerts.ask(
                "This meeting can't be moved to the Trash yet",
                "It is still recording or being processed. Try again once it has finished.",
                buttons: ["OK"]
            )
            return
        }
        var detail = "You can put it back from the Trash in Finder, with its recording, transcript and recap."
        if meeting.exportedNotePath != nil {
            detail += " The note in Obsidian stays, but its links to the recording and transcript stop working until you put the meeting back."
        }
        guard Alerts.ask(
            "Move \u{201C}\(meeting.title)\u{201D} to the Trash?",
            detail,
            buttons: ["Cancel", "Move to Trash"],
            destructive: 1
        ) == 1 else { return }
        guard let current = try? store.load(id), await canTrash(current) else { return }
        do {
            deletedIDs.insert(id)
            try store.moveToTrash(id)
        } catch {
            deletedIDs.remove(id)
            logger.error("Moving \(id.rawValue, privacy: .public) to the Trash failed: \(String(describing: error), privacy: .public)")
            report(error, stage: .trashingMeeting, for: id)
            return
        }
        activity.record(.info, .app, "Moved to the Trash", meeting: current)
        meetings.removeAll { $0.id == id }
        actionErrors[id] = nil
        actionNotices[id] = nil
        actionSuccesses[id] = nil
        failedActions[id] = nil
        unsavedSummaries[id] = nil
        player.unload(id)
        playbackPositions.remove(id)
        if selectedMeetingID == id { selectedMeetingID = nil }
    }

    private func canTrash(_ meeting: Meeting) async -> Bool {
        guard MeetingActions.canDelete(meeting) else { return false }
        return await !pipeline.hasJob(for: meeting.id)
    }

    /// The calendar events from two hours before to two hours after the meeting started, across the signed-in accounts.
    /// Accounts that couldn't be read are reported in `failures` instead of hiding the others' events.
    func eventsAround(_ meeting: Meeting) async -> (events: [CalendarEvent], failures: [Problem]) {
        let from = meeting.startedAt.addingTimeInterval(-2 * 3600)
        let to = meeting.startedAt.addingTimeInterval(2 * 3600)
        var events: [CalendarEvent] = []
        var failures: [Problem] = []
        for account in settings.accounts {
            guard let client = graph.signedInClient(for: account) else { continue }
            do {
                events += try await client.events(from: from, to: to).filter { !$0.isCancelled && !$0.isAllDay }
            } catch {
                logger.warning("Fetching events for \(account.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                guard !ActivityCenter.isCancellation(error) else { continue }
                let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .readingCalendar, accountName: account.displayName))
                failures.append(problem)
            }
        }
        events.sort { ($0.start, $0.accountID) < ($1.start, $1.accountID) }
        return (events, failures)
    }

    /// Fetches the chosen event and applies it, unless a note appeared meanwhile. Exports and regeneration
    /// are held off for the meeting while the fetch is pending, and the event is judged against the meeting as it is when the fetch ends.
    func chooseEvent(_ ref: CalendarEventRef, for id: MeetingID) async {
        guard eventChangesInFlight.insert(id).inserted else { return }
        var applied = false
        await perform(.changingEvent, for: id, retry: nil) {
            guard !isExportRunning(id) else { throw MeetingActionError.exportInProgress }
            guard let account = settings.accounts.first(where: { $0.id == ref.accountID }) else {
                throw MeetingActionError.unknownAccount
            }
            let event = try await graph.client(for: account).event(id: ref.eventID)
            let accounts = settings.accounts
            let domains = settings.clientDomains
            var changed = false
            let stored = try store.update(id) { meeting in
                guard let result = MeetingActions.changeEvent(meeting, to: event, accounts: accounts, clientDomains: domains) else { return }
                meeting = result
                changed = true
            }
            apply(stored)
            if changed {
                applied = true
            } else {
                actionNotices[id] = Problems.eventNotChanged()
            }
        }
        eventChangesInFlight.remove(id)
        if applied { Task { await autoFile(id) } }
    }

    /// "No event": the meeting returns to the no-event state (untitled, no attendees, client or event recipients) and can now be filed.
    func dismissEventChoice(for id: MeetingID) throws {
        guard !eventChangesInFlight.contains(id) else { throw MeetingActionError.eventChangeInProgress }
        guard !isExportRunning(id) else { throw MeetingActionError.exportInProgress }
        var appName: String?
        if case .call(let bundleID) = try store.load(id).captureMode { appName = AppNames.name(bundleID: bundleID) }
        var cleared = false
        let stored = try store.update(id) { meeting in
            guard MeetingActions.canChangeEvent(meeting) else { return }
            meeting = MeetingActions.clearEvent(meeting, appName: appName, timeZone: .current)
            cleared = true
        }
        apply(stored)
        if cleared {
            Task { await autoFile(id) }
        } else {
            actionNotices[id] = Problems.eventNotChanged()
        }
    }

    private func isExportRunning(_ id: MeetingID) -> Bool {
        actionsInFlight.contains(Self.actionKey(.filingNote, id))
    }

    /// "N recap items have no transcript source": the phrase shared by the question and the auto-file notice.
    static func unsourcedPhrase(_ count: Int) -> String {
        count == 1 ? "1 recap item has no transcript source" : "\(count) recap items have no transcript source"
    }

    /// Before a recap leaves Muninn (copied or filed): asks whether items without a transcript source may go along.
    /// "Review first" opens the meeting and stops, so the items can be checked in the editor.
    func confirmUnsourcedItems(_ count: Int, for id: MeetingID) -> UnsourcedChoice {
        guard count > 0 else { return .include }
        switch Alerts.ask(
            "\(Self.unsourcedPhrase(count)). Include \(count == 1 ? "it" : "them") anyway?",
            "They are marked in the recap editor. Nothing is copied or filed unless you include them.",
            buttons: ["Include", "Review first", "Cancel"]
        ) {
        case 0:
            return .include
        case 1:
            showRecap(id)
            return .review
        default:
            return .cancel
        }
    }

    /// Runs one user-visible action per meeting at a time; a failure lands in `actionErrors` for the meeting's problem card.
    /// `retry` is what the problem card's "Try again" runs after a failure; nil leaves the card without one.
    func perform(_ stage: ProblemStage, for id: MeetingID, retry: RetryableAction?, _ body: () async throws -> Void) async {
        let key = Self.actionKey(stage, id)
        guard actionsInFlight.insert(key).inserted else { return }
        defer { actionsInFlight.remove(key) }
        actionErrors[id] = nil
        actionNotices[id] = nil
        actionSuccesses[id] = nil
        failedActions[id] = nil
        do {
            try await body()
        } catch {
            logger.error("Couldn't run \(stage.rawValue, privacy: .public) for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            report(error, stage: stage, retry: retry, for: id)
        }
    }

    /// Shows what went wrong with a meeting's action as a problem card and records it. A cancellation is not a failure.
    func report(_ error: Error, stage: ProblemStage, retry: RetryableAction? = nil, for id: MeetingID) {
        guard !ActivityCenter.isCancellation(error) else { return }
        let meeting = meetings.first { $0.id == id }
        let context = ProblemContext(
            stage: stage,
            accountName: meeting?.accountID.map(accountName),
            subject: stage == .filingNote ? "the note" : nil
        )
        let problem = ProblemTranslator.problem(for: error, in: context)
        actionErrors[id] = problem
        failedActions[id] = retry
        activity.record(problem, area: stage.area, meeting: meeting)
    }

    /// What a failed export needs to run again.
    enum RetryableAction: Equatable {
        case note
    }

    /// Runs the export that failed again.
    func retryAction(_ id: MeetingID) {
        switch failedActions[id] {
        case .note: exportToObsidian(id)
        case nil: break
        }
    }

    private static func actionKey(_ stage: ProblemStage, _ id: MeetingID) -> String {
        "\(stage.rawValue)|\(id.rawValue)"
    }
}
