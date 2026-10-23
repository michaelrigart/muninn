import Foundation

public enum AutoFileDecision: Equatable, Sendable {
    /// Not eligible, or nothing to say.
    case skip
    /// The recap has bullets or actions that cite no transcript segment, so a person has to look first.
    case unsourced(Int)
    /// The meeting would have been filed but no vault is chosen; `showNotice` is true only the first time in a session.
    case vaultNotChosen(showNotice: Bool)
    case file
}

public enum MeetingActions {
    public static func canDraft(_ m: Meeting, accounts: [AccountSettings]) -> Bool {
        !accountRemoved(m, accounts: accounts) && m.accountID != nil && m.recipients.contains(where: \.included)
    }

    /// The meeting names an account that is no longer in the settings; it can't draft until another account is chosen.
    public static func accountRemoved(_ m: Meeting, accounts: [AccountSettings]) -> Bool {
        guard let id = m.accountID else { return false }
        return !accounts.contains(where: { $0.id == id })
    }

    public static let accountRemovedLabel = "Account removed — choose an account"

    /// A meeting can be deleted unless it is recording or being processed; waiting, ready and failed ones can.
    public static func canDelete(_ m: Meeting) -> Bool {
        switch m.status {
        case .recording, .transcribing, .diarizing, .cleaning, .summarizing: false
        case .waiting, .ready, .failed: true
        }
    }

    /// The event can be changed until a draft or an export exists for the meeting.
    public static func canChangeEvent(_ m: Meeting) -> Bool {
        m.draftWebLink == nil && m.draftID == nil && m.exportedNotePath == nil
    }

    /// Whether and how to file a meeting automatically. The eligibility checks come first (enabled, ready, not exported,
    /// settled, no unsaved edits or event change under way, no unsourced items); the missing-vault check comes last, so the
    /// once-per-session notice is spent only on a meeting that would otherwise have been filed.
    public static func autoFileDecision(
        _ m: Meeting, settings: Settings, hasUnsavedEdits: Bool, eventChangeInFlight: Bool, unsourcedItems: Int, vaultNoticeShown: Bool
    ) -> AutoFileDecision {
        guard settings.autoFileToObsidian, !hasUnsavedEdits, !eventChangeInFlight else { return .skip }
        guard m.status == .ready, m.exportedNotePath == nil, m.candidateEvents.isEmpty else { return .skip }
        if unsourcedItems > 0 { return .unsourced(unsourcedItems) }
        guard settings.hasVault else { return .vaultNotChosen(showNotice: !vaultNoticeShown) }
        return .file
    }

    /// Why a manual export can't write anywhere, or nil when it can proceed.
    public static func exportRefusal(settings: Settings) -> String? {
        settings.hasVault ? nil : vaultNotChosenNotice
    }

    public static let vaultNotChosenNotice = "Choose your Obsidian vault in Settings first"

    public static let eventNotChangedNotice = "The event wasn't changed because a draft or note already exists."

    /// Applies an event fetched for the meeting, judged against the meeting as it is now: a draft or note created while the
    /// event was being fetched keeps the old event, and the change is dropped (nil).
    public static func changeEvent(_ m: Meeting, to event: CalendarEvent, accounts: [AccountSettings], clientDomains: [String: String]) -> Meeting? {
        guard canChangeEvent(m) else { return nil }
        return MeetingPreparation.choose(event, for: m, accounts: accounts, clientDomains: clientDomains)
    }

    /// How many bullets and action points cite no transcript segment. They are kept in the recap and marked in the editor,
    /// but a draft or a note should not carry them to a client unnoticed.
    public static func unsourcedItemCount(in summary: Summary) -> Int {
        summary.subjects.reduce(0) { total, subject in
            total + subject.bullets.filter { $0.sources.isEmpty }.count + subject.actions.filter { $0.sources.isEmpty }.count
        }
    }

    /// Returns a meeting to the no-event state: the untitled title, no event, no attendees, and no recipients the event supplied.
    /// Recipients the user added by hand (anyone who is not an attendee of the event) stay. The account and client are cleared
    /// only when an event had set them, so a choice made by hand on a meeting that never had one survives.
    public static func clearEvent(_ m: Meeting, appName: String?, timeZone: TimeZone) -> Meeting {
        var result = m
        let hadEvent = m.association != nil
        let eventPeople = Set(m.attendees.map { $0.email.lowercased() })
        result.candidateEvents = []
        result.association = nil
        result.attendees = []
        result.recipients = m.recipients.filter { !eventPeople.contains($0.attendee.email.lowercased()) }
        result.title = RecipientBuilder.untitledTitle(appName: appName ?? "Conversation", at: m.startedAt, timeZone: timeZone)
        if hadEvent {
            result.accountID = nil
            result.client = nil
        }
        return result
    }

    /// Closes a recording: the pipeline skips `.recording`, so this is what hands the meeting to transcription.
    public static func finishRecording(_ m: Meeting, endedAt: Date) -> Meeting {
        var result = m
        result.endedAt = endedAt
        if result.status == .recording { result.status = .transcribing }
        return result
    }

    public static func addRecipient(_ a: Attendee, to m: Meeting, selfAddresses: [String]) -> Meeting {
        let email = a.email.lowercased()
        guard !selfAddresses.contains(where: { $0.lowercased() == email }),
              !m.recipients.contains(where: { $0.attendee.email.lowercased() == email })
        else { return m }
        var result = m
        result.recipients.append(Recipient(attendee: a, included: true))
        return result
    }

    public static func setIncluded(_ email: String, _ included: Bool, in m: Meeting) -> Meeting {
        var result = m
        let key = email.lowercased()
        for index in result.recipients.indices where result.recipients[index].attendee.email.lowercased() == key {
            result.recipients[index].included = included
        }
        return result
    }
}
