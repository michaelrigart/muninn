import AppKit
import MuninnCore
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "meetings")

enum MeetingActionError: LocalizedError {
    case eventUnsettled
    case notReady
    case noSummary
    case noRecipients
    case unknownAccount(String)
    case vaultNotChosen
    case vaultMissing(String)
    case linkNotSaved(Error)
    case unsavedEdits
    case eventChangeInProgress
    case draftOrExportInProgress

    var errorDescription: String? {
        switch self {
        case .eventUnsettled: "Choose the event first."
        case .notReady: "The meeting isn't processed yet."
        case .noSummary: "There is no summary yet."
        case .noRecipients: "Choose an account and at least one recipient."
        case .unknownAccount(let id): "Account \(id) is not in the settings."
        case .vaultNotChosen: MeetingActions.vaultNotChosenNotice
        case .vaultMissing(let path): "The Obsidian vault folder doesn't exist: \(path)"
        case .unsavedEdits: "Save your summary edits first."
        case .eventChangeInProgress: "The event is being changed. Try again in a moment."
        case .draftOrExportInProgress: "A draft or an export is being made. Change the event once it has finished."
        case .linkNotSaved(let error): "The draft was created, but saving its details failed: \(SignInFlow.describe(error))"
        }
    }
}

extension AppModel {
    /// Applies `change` to the latest stored copy of the meeting under the store's lock, so neither a stale snapshot nor a
    /// concurrent pipeline write is lost. `change` must not call the store (the lock is not reentrant).
    func mutate(_ id: MeetingID, _ change: (inout Meeting) -> Void) throws {
        let meeting = try store.update(id) { change(&$0) }
        apply(meeting)
    }

    /// Asks first, then removes the meeting's folder. A meeting that is recording, being processed or has a job queued is refused;
    /// an exported Obsidian note is never touched, but its links to the audio and transcript stop working.
    func deleteMeeting(_ id: MeetingID) {
        Task { await confirmAndDelete(id) }
    }

    private func confirmAndDelete(_ id: MeetingID) async {
        guard let meeting = try? store.load(id) else { return }
        guard await canDelete(meeting) else {
            _ = Alerts.ask(
                "This meeting can't be deleted yet",
                "It is still recording or being processed. Delete it once it has finished.",
                buttons: ["OK"]
            )
            return
        }
        guard Alerts.ask(
            "Delete \u{201C}\(meeting.title)\u{201D}?",
            "This permanently deletes its recording, transcript and recap from Muninn's folder. A note already exported to Obsidian is not touched, but its links to the audio and to Muninn's transcript files will stop working.",
            buttons: ["Delete", "Cancel"],
            destructiveFirst: true
        ) == 0 else { return }
        guard let current = try? store.load(id), await canDelete(current) else { return }
        do {
            deletedIDs.insert(id)
            try store.delete(id)
        } catch {
            deletedIDs.remove(id)
            logger.error("Deleting \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            actionErrors[id] = "Couldn't delete the meeting: \(Self.describe(error))"
            return
        }
        meetings.removeAll { $0.id == id }
        actionErrors[id] = nil
        actionNotices[id] = nil
        unsavedSummaries[id] = nil
        if selectedMeetingID == id { selectedMeetingID = nil }
    }

    private func canDelete(_ meeting: Meeting) async -> Bool {
        guard MeetingActions.canDelete(meeting) else { return false }
        return await !pipeline.hasJob(for: meeting.id)
    }

    /// The calendar events from two hours before to two hours after the meeting started, across the signed-in accounts.
    /// Accounts that couldn't be read are reported in `failures` instead of hiding the others' events.
    func eventsAround(_ meeting: Meeting) async -> (events: [CalendarEvent], failures: [String]) {
        let from = meeting.startedAt.addingTimeInterval(-2 * 3600)
        let to = meeting.startedAt.addingTimeInterval(2 * 3600)
        var events: [CalendarEvent] = []
        var failures: [String] = []
        for account in settings.accounts {
            guard let client = graph.signedInClient(for: account) else { continue }
            do {
                events += try await client.events(from: from, to: to).filter { !$0.isCancelled && !$0.isAllDay }
            } catch {
                logger.warning("Fetching events for \(account.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failures.append("\(account.displayName): \(Self.describe(error))")
            }
        }
        events.sort { ($0.start, $0.accountID) < ($1.start, $1.accountID) }
        return (events, failures)
    }

    /// Fetches the chosen event and applies it, unless a draft or note appeared meanwhile. Drafts, exports and regeneration
    /// are held off for the meeting while the fetch is pending, and the event is judged against the meeting as it is when the fetch ends.
    func chooseEvent(_ ref: CalendarEventRef, for id: MeetingID) async {
        guard eventChangesInFlight.insert(id).inserted else { return }
        var applied = false
        await perform("load the calendar event", for: id) {
            guard !isDraftOrExportRunning(id) else { throw MeetingActionError.draftOrExportInProgress }
            guard let account = settings.accounts.first(where: { $0.id == ref.accountID }) else {
                throw MeetingActionError.unknownAccount(ref.accountID)
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
                actionNotices[id] = MeetingActions.eventNotChangedNotice
            }
        }
        eventChangesInFlight.remove(id)
        if applied { Task { await autoFile(id) } }
    }

    /// "No event": the meeting returns to the no-event state (untitled, no attendees, client or event recipients) and can now be drafted and filed.
    func dismissEventChoice(for id: MeetingID) throws {
        guard !eventChangesInFlight.contains(id) else { throw MeetingActionError.eventChangeInProgress }
        guard !isDraftOrExportRunning(id) else { throw MeetingActionError.draftOrExportInProgress }
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
            actionNotices[id] = MeetingActions.eventNotChangedNotice
        }
    }

    private func isDraftOrExportRunning(_ id: MeetingID) -> Bool {
        actionsInFlight.contains("create the Outlook draft|\(id.rawValue)") || actionsInFlight.contains("export to Obsidian|\(id.rawValue)")
    }

    func createDraft(_ id: MeetingID) {
        Task {
            await perform("create the Outlook draft", for: id) {
                guard !eventChangesInFlight.contains(id) else { throw MeetingActionError.eventChangeInProgress }
                let meeting = try store.load(id)
                guard unsavedSummaries[id] == nil else { throw MeetingActionError.unsavedEdits }
                guard meeting.candidateEvents.isEmpty else { throw MeetingActionError.eventUnsettled }
                guard meeting.status == .ready else { throw MeetingActionError.notReady }
                guard MeetingActions.canDraft(meeting, accounts: settings.accounts), let accountID = meeting.accountID else { throw MeetingActionError.noRecipients }
                guard let summary = try store.loadSummary(id) else { throw MeetingActionError.noSummary }
                guard let account = settings.accounts.first(where: { $0.id == accountID }) else {
                    throw MeetingActionError.unknownAccount(accountID)
                }
                if meeting.draftID != nil || meeting.draftWebLink != nil,
                   Alerts.ask("A draft already exists", "A draft already exists. Create another?", buttons: ["Create Another", "Cancel"]) != 0 {
                    return
                }
                guard confirmUnsourcedItems(MeetingActions.unsourcedItemCount(in: summary), for: id) else { return }
                let result = try await graph.client(for: account).createDraft(
                    subject: RecapEmail.subject(title: meeting.title, date: meeting.startedAt, timeZone: .current),
                    html: RecapEmail.html(summary: summary, speakerNames: meeting.speakerNames),
                    to: meeting.recipients.filter(\.included).map(\.attendee)
                )
                var saveFailure: Error?
                do {
                    try mutate(id) {
                        $0.draftID = result.id
                        $0.draftWebLink = result.webLink?.absoluteString ?? $0.draftWebLink
                    }
                } catch {
                    saveFailure = error
                }
                if let link = result.webLink {
                    NSWorkspace.shared.open(link)
                } else {
                    actionNotices[id] = "Draft created in Outlook. Graph returned no link; find it in Drafts."
                }
                if let saveFailure { throw MeetingActionError.linkNotSaved(saveFailure) }
            }
        }
    }

    /// "N recap items have no transcript source": the phrase shared by the question and the auto-file notice.
    static func unsourcedPhrase(_ count: Int) -> String {
        count == 1 ? "1 recap item has no transcript source" : "\(count) recap items have no transcript source"
    }

    /// Before a recap leaves Muninn (draft or note): asks whether items without a transcript source may go along.
    /// "Review first" opens the meeting and stops, so the items can be checked in the editor.
    func confirmUnsourcedItems(_ count: Int, for id: MeetingID) -> Bool {
        guard count > 0 else { return true }
        switch Alerts.ask(
            "\(Self.unsourcedPhrase(count)). Include \(count == 1 ? "it" : "them") anyway?",
            "They are marked in the recap editor. Nothing is sent or filed unless you include them.",
            buttons: ["Include", "Review first", "Cancel"]
        ) {
        case 0:
            return true
        case 1:
            showMeeting(id)
            return false
        default:
            return false
        }
    }

    /// Runs one user-visible action per meeting at a time; a failure lands in `actionErrors` for the meeting's banner.
    func perform(_ action: String, for id: MeetingID, _ body: () async throws -> Void) async {
        let key = "\(action)|\(id.rawValue)"
        guard actionsInFlight.insert(key).inserted else { return }
        defer { actionsInFlight.remove(key) }
        actionErrors[id] = nil
        actionNotices[id] = nil
        do {
            try await body()
        } catch {
            logger.error("Couldn't \(action, privacy: .public) for \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            actionErrors[id] = "Couldn't \(action): \(Self.describe(error))"
        }
    }

    static func describe(_ error: Error) -> String {
        SignInFlow.describe(error)
    }
}
