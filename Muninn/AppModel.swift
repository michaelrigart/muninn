import AVFoundation
import Combine
import Foundation
import MuninnCore
import MuninnSpeech
import MuninnSystem
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")

private struct SettingsTranscriber: Transcribing {
    let settings: @Sendable () -> MuninnCore.Settings

    func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] {
        let name = settings().finalModel
        let id = SpeechModelID(rawValue: name) ?? {
            logger.error("Unknown final model \(name, privacy: .public); using parakeet-v3")
            return .parakeetV3
        }()
        return try await TranscriberFactory.make(id).transcribe(audio: audio, track: track, vocabulary: vocabulary)
    }
}

private final class SettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Settings

    init(_ settings: Settings) {
        current = settings
    }

    /// The settings with an empty user name resolved, as the pipeline needs them.
    var value: Settings {
        get {
            var settings = lock.withLock { current }
            settings.userName = SummaryRequestBuilder.resolvedUserName(settings.userName, systemFullName: NSFullUserName())
            return settings
        }
        set { lock.withLock { current = newValue } }
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = false

    var value: Bool {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Summary edits that couldn't be written, kept per meeting so navigating away doesn't lose them.
struct UnsavedSummary {
    var summary: Summary
    var problem: Problem
}

enum SidebarFilter {
    case all, needsAttention
}

enum SettingsTab: Hashable {
    case engines, accounts, obsidian, recording, dictionary, permissions
}

@MainActor
final class AppModel: ObservableObject {
    @Published var meetings: [Meeting] = []
    /// True only while audio is being captured (starting and finishing included). Setting it keeps the pipeline's gate in step
    /// and hands held work back as soon as a recording ends or fails to start.
    @Published var isRecording = false {
        didSet {
            recordingGate.value = isRecording
            if oldValue, !isRecording { resumeHeldProcessing() }
            if oldValue != isRecording { announceAttention() }
        }
    }
    /// Decides which meetings to announce; nil until the first load, so meetings already waiting at launch stay quiet.
    private var attention: AttentionTracker?
    @Published var settings: Settings
    @Published var selectedMeetingID: MeetingID?
    /// Bumped to ask the always-alive menu bar label to open the Meetings, Activity or Settings window.
    @Published var openMeetingsRequest = 0
    @Published private(set) var openActivityRequest = 0
    @Published private(set) var openSettingsRequest = 0
    /// Bumped to ask an open Meetings window to show the Recap tab.
    @Published private(set) var showRecapRequest = 0
    /// The last failed draft, export or event change per meeting, shown as that meeting's problem card.
    @Published var actionErrors: [MeetingID: Problem] = [:]
    @Published var actionNotices: [MeetingID: Problem] = [:]
    /// The last draft or filed note per meeting, shown as that meeting's success card until it is dismissed or another action starts.
    @Published var actionSuccesses: [MeetingID: ActionSuccess] = [:]
    /// What to run again for a failed draft or export, so the problem card can retry it.
    @Published var failedActions: [MeetingID: RetryableAction] = [:]
    /// Recap edits that couldn't be saved, per meeting, kept until a save succeeds.
    @Published var unsavedSummaries: [MeetingID: UnsavedSummary] = [:]
    /// Accounts whose stored sign-in Microsoft rejected during the last calendar refresh.
    @Published var signInNeeded: Set<String> = []
    /// Meetings whose event is being fetched for a change. Drafts, exports and regeneration wait for it.
    @Published var eventChangesInFlight: Set<MeetingID> = []
    /// Why the flag hotkey couldn't be registered, if it couldn't.
    @Published var hotkeyError: Problem?
    /// Why the settings couldn't be saved, and the settings that failed, so the card can save them again.
    @Published var settingsProblem: Problem?
    @Published private(set) var failedSettings: MuninnCore.Settings?
    /// What the pipeline is running and what waits for its turn.
    @Published private(set) var pipelineSnapshot = PipelineSnapshot.idle
    /// The speech models being downloaded or loaded.
    @Published private(set) var speechModels: [SpeechModelPreparation] = []
    /// Whether a Claude API key is stored; a Keychain read that fails counts as absent.
    @Published private(set) var claudeKeyPresent = false
    @Published var sidebarFilter = SidebarFilter.all
    @Published var settingsTab = SettingsTab.engines
    /// Bumped by every reload, so views that read a meeting's files or texts read them again.
    @Published private(set) var reloadRevision = 0

    let paths: MuninnPaths
    let store: MeetingStore
    let settingsStore: SettingsStore
    let secrets: KeychainSecrets
    let pipeline: ProcessingPipeline
    let graph: GraphServices
    let calendar: CalendarCache
    let activity: ActivityCenter
    let playbackPositions: PlaybackPositions
    let player: MeetingPlayer

    var actionsInFlight: Set<String> = []
    private let settingsBox: SettingsBox
    private let recordingGate: FlagBox
    private var setupTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var folderWatcher: MeetingFolderWatcher?
    /// Meetings already announced this session; processing or regenerating one on request lets it announce again.
    private var notified: Set<MeetingID> = []
    /// Meetings deleted or moved to the Trash, cleared again when a reload lists them. A pipeline callback that is still
    /// in flight for one of them is dropped.
    var deletedIDs: Set<MeetingID> = []
    /// Set once the "choose your vault" notice has been shown for auto-filing, so it appears once per session.
    var vaultNoticeShown = false
    /// The meeting and file whose load failure was already recorded this session, so a failing file is recorded once.
    private var recordedLoadFailures: Set<String> = []

    init() {
        let paths = MuninnPaths(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        let store = MeetingStore(root: paths.meetings)
        let settingsStore = SettingsStore(file: paths.settingsFile)
        let secrets = KeychainSecrets()
        let loaded = settingsStore.load()
        let activity = ActivityCenter(log: ActivityLog(file: paths.activityFile), dataDirectory: paths.data.path)
        let log = activity.log
        SpeechModelActivity.shared.setActivity(log)
        let box = SettingsBox(loaded)
        let gate = FlagBox()
        do {
            try FileManager.default.createDirectory(at: paths.meetings, withIntermediateDirectories: true)
        } catch {
            logger.error("Creating the meetings folder failed: \(String(describing: error), privacy: .public)")
        }

        self.paths = paths
        self.store = store
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.settings = loaded
        self.settingsBox = box
        self.activity = activity
        let playbackPositions = PlaybackPositions(file: paths.playbackFile)
        self.playbackPositions = playbackPositions
        self.player = MeetingPlayer(positions: playbackPositions, store: store, activity: activity)
        self.recordingGate = gate
        let graph = GraphServices(secrets: secrets)
        self.graph = graph
        self.calendar = CalendarCache(graph: graph)
        self.pipeline = ProcessingPipeline(
            store: store,
            settings: { box.value },
            transcriber: SettingsTranscriber(settings: { box.value }),
            diarizer: FluidDiarizer(),
            cleaner: { settings, decision in
                if settings.useLLMCleanup, case .run(let engine, _, _) = decision {
                    do {
                        return LLMTranscriptCleaner(client: try Self.client(for: engine, settings: settings, secrets: secrets), activity: log)
                    } catch {
                        logger.error("LLM cleanup unavailable, using rules: \(error.localizedDescription, privacy: .public)")
                        let context = ProblemContext.engine(engine, settings: settings, stage: .cleaningUp, claudeKeyPresent: false)
                        log.record(ActivityEntry(
                            time: Date(),
                            level: .warning,
                            area: .transcription,
                            meeting: ActivityScope.meeting,
                            message: "Cleanup used the rule cleaner",
                            details: ProblemTranslator.problem(for: error, in: context).details
                        ))
                    }
                }
                return RuleTranscriptCleaner()
            },
            summarizer: LLMSummarizer(clientFor: { engine in
                try Self.client(for: engine, settings: box.value, secrets: secrets)
            }, settings: { box.value }, activity: log),
            probe: LiveEnvironmentProbe(secrets: secrets, activity: log),
            isRecording: { gate.value }
        )

        calendar.onSignInState = { [weak self] id, needed in
            guard let self else { return }
            if needed {
                if signInNeeded.insert(id).inserted {
                    activity.record(Problems.signInExpired(account: accountName(id)), area: .accounts)
                }
            } else {
                signInNeeded.remove(id)
            }
        }
        calendar.onFetchFailure = { [weak self] id, error in
            guard let self else { return }
            activity.record(failure: error, in: ProblemContext(stage: .readingCalendar, accountName: accountName(id)))
        }
        reloadMeetings()
        folderWatcher = MeetingFolderWatcher(directory: paths.meetings, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.reloadMeetings() }
        }
        refreshClaudeKey()
        SpeechModelActivity.shared.setObserver { [weak self] models in
            Task { @MainActor in self?.speechModels = models }
        }
        speechModels = SpeechModelActivity.shared.preparing
        let pipeline = self.pipeline
        setupTask = Task { [weak self] in
            await pipeline.setOnChange { meeting in
                Task { @MainActor in self?.apply(meeting) }
            }
            await pipeline.setOnSnapshot { snapshot in
                Task { @MainActor in self?.pipelineSnapshot = snapshot }
            }
            self?.pipelineSnapshot = await pipeline.snapshot()
        }
        RecapNotifications.start { [weak self] id in self?.showRecap(id) }
        startLifecycle()
    }

    /// Recovers meetings a quit or crash left unfinished, then re-checks waiting ones every `WaitRetry.interval`; the calendar cache refreshes on its own loop.
    private func startLifecycle() {
        let pipeline = self.pipeline
        let setup = setupTask
        let interrupted = recoverInterruptedMeetings()
        lifecycleTask = Task { [weak self] in
            await setup?.value
            for id in interrupted {
                await pipeline.process(id)
            }
            var tick = 0
            while !Task.isCancelled {
                self?.refreshClaudeKey()
                await pipeline.requeueWaiting(only: WaitRetry.reasons(forTick: tick))
                tick += 1
                try? await Task.sleep(for: WaitRetry.interval)
            }
        }
        calendarTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshCalendar().value
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Checks the Claude key's presence in the Keychain again; called when it may have changed. The check runs off the
    /// main actor and reads no key data, so a Keychain access prompt can't freeze the interface. An error counts as absent.
    func refreshClaudeKey() {
        let secrets = self.secrets
        Task { [weak self] in
            let present = await Task.detached {
                do {
                    return try secrets.contains(LiveEnvironmentProbe.claudeKeyName)
                } catch {
                    logger.error("Checking for the Claude key failed: \(String(describing: error), privacy: .public)")
                    return false
                }
            }.value
            guard let self, claudeKeyPresent != present else { return }
            claudeKeyPresent = present
        }
    }

    func progress(for meeting: Meeting) -> MeetingProgress {
        ProcessingDisplay.progress(for: meeting, snapshot: pipelineSnapshot, speechModel: speechModels.first)
    }

    func commandContext(for meeting: Meeting, hasRecap: Bool = false, includePreviousRecap: Bool = true) -> MeetingCommandContext {
        MeetingCommandContext(
            meeting: meeting,
            progress: progress(for: meeting),
            hasRecap: hasRecap,
            hasPreviousRecap: includePreviousRecap && store.hasPreviousSummary(meeting.id),
            unsavedEdits: unsavedSummaries[meeting.id] != nil,
            eventChanging: eventChangesInFlight.contains(meeting.id)
        )
    }

    func dismissEngineNotice(_ id: MeetingID) {
        dismissNotice(id) { $0.engineNotice = nil }
    }

    func dismissTranscriptNotice(_ id: MeetingID) {
        dismissNotice(id) { $0.transcriptNotice = nil }
    }

    private func dismissNotice(_ id: MeetingID, _ change: (inout Meeting) -> Void) {
        do {
            try mutate(id, change)
        } catch {
            logger.error("Dismissing a notice of \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            activity.record(failure: error, in: ProblemContext(stage: .savingEdits, subject: "the meeting"))
        }
    }

    @discardableResult
    func refreshCalendar() -> Task<Void, Never> {
        calendar.refresh(settings.accounts)
    }

    /// Meetings mid-stage are processed again. One left `.recording` has no live recorder. It is deleted only when every
    /// audio file it has opens and is empty; if any file can't be opened it is kept and marked failed, never thrown away.
    /// Otherwise it is closed at its newest audio file's modification date and transcribed.
    private func recoverInterruptedMeetings() -> [MeetingID] {
        var ids: [MeetingID] = []
        for meeting in meetings {
            switch meeting.status {
            case .transcribing, .diarizing, .cleaning, .summarizing:
                ids.append(meeting.id)
            case .recording:
                let urls = [Track.mic, Track.system].map { store.audioURL(meeting.id, track: $0) }
                let probes = urls.map(probe)
                let newest = zip(urls, probes).filter { $0.1 != .missing }.compactMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0.0.path))?[.modificationDate] as? Date
                }.max()
                let endedAt = max(newest ?? Date(), meeting.startedAt)
                do {
                    switch LaunchRecovery.decide(probes) {
                    case .delete:
                        try store.delete(meeting.id)
                        meetings.removeAll { $0.id == meeting.id }
                        activity.record(.info, .recording, "Removed an empty interrupted recording", meeting: meeting)
                    case .transcribe:
                        try mutate(meeting.id) { $0 = MeetingActions.finishRecording($0, endedAt: endedAt) }
                        ids.append(meeting.id)
                        activity.record(.info, .recording, "Recovered an interrupted recording", meeting: meeting)
                    case .markUnreadable:
                        // `apply` records the failed status, and the stage puts it under Recording.
                        try mutate(meeting.id) {
                            $0.status = .failed(Problems.recordingUnreadable(details: ProblemDetails(stage: .recording)))
                            $0.endedAt = endedAt
                        }
                    }
                } catch {
                    logger.error("Recovering meeting \(meeting.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            default:
                break
            }
        }
        return ids
    }

    /// Opens a track the way the readers do: a header-only file is what a crash right after start leaves, and a file
    /// that won't open is reported as such rather than counted as empty.
    private func probe(_ url: URL) -> TrackProbe {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            return .frames(try AVAudioFile(forReading: url).length)
        } catch {
            logger.error("Audio file \(url.lastPathComponent, privacy: .public) is unreadable: \(String(describing: error), privacy: .public)")
            return .unreadable
        }
    }

    /// The display name of an account for messages, falling back to its id once it is gone from the settings.
    func accountName(_ id: String) -> String {
        settings.accounts.first { $0.id == id }?.displayName ?? id
    }

    /// Reads one of a meeting's files for its detail view. A failure shows as missing and is recorded once per meeting and file.
    func loadFile<T>(_ name: String, for meeting: Meeting, _ read: () throws -> T?) -> T? {
        do {
            return try read()
        } catch {
            guard !ActivityCenter.isCancellation(error), recordedLoadFailures.insert("\(meeting.id.rawValue)|\(name)").inserted else { return nil }
            logger.error("Loading \(name, privacy: .public) of \(meeting.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            var problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .loadingMeetings))
            problem.details.path = paths.meetings.appendingPathComponent(meeting.id.rawValue).appendingPathComponent(name).path
            activity.record(problem, area: .app, meeting: meeting)
            return nil
        }
    }

    func showMeeting(_ id: MeetingID) {
        selectedMeetingID = id
        openMeetingsRequest += 1
    }

    /// Opens the meeting on its Recap tab, even if the window is already open on the Transcript.
    func showRecap(_ id: MeetingID) {
        showMeeting(id)
        showRecapRequest += 1
    }

    /// Opens Settings on a pane, from anywhere, including the floating panels that have no window actions of their own.
    func showSettings(_ tab: SettingsTab) {
        settingsTab = tab
        openSettingsRequest += 1
    }

    /// Opens the Activity window on the newest entry with the problem's title, and the meeting's when one is given.
    /// A problem the log doesn't hold (one from a popover, an older version or beyond the 14 days) is recorded first.
    func showInActivity(_ problem: Problem, meeting: MeetingID? = nil) {
        if !activity.focus(problemTitle: problem.title, meetingID: meeting) {
            let reference = meeting.flatMap { id in meetings.first { $0.id == id } }.map { ActivityMeeting(id: $0.id, title: $0.title) }
            activity.recordAndFocus(problem, area: problem.details.stage?.area ?? .app, meeting: reference)
        }
        openActivityRequest += 1
    }

    /// The handlers every problem card outside the meeting's status cards shares: the actions that open a Settings pane.
    func problemHandlers(tryAgain: (() -> Void)? = nil) -> ProblemHandlers {
        ProblemHandlers(
            tryAgain: tryAgain,
            engineSettings: { [weak self] in self?.showSettings(.engines) },
            changeKey: { [weak self] in self?.showSettings(.engines) },
            signInAgain: { [weak self] in self?.showSettings(.accounts) },
            recordingSettings: { [weak self] in self?.showSettings(.recording) }
        )
    }

    nonisolated static func client(for engine: EngineKind, settings: Settings, secrets: KeychainSecrets) throws -> LLMClient {
        try EngineClients.make(engine, settings: settings, secrets: secrets)
    }

    func reloadMeetings() {
        var loaded = false
        do {
            let previous = Dictionary(meetings.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            let list = try store.list()
            meetings = list
            deletedIDs.subtract(list.map(\.id))
            reloadRevision += 1
            loaded = true
            for meeting in list where meeting.status == .ready && previous[meeting.id].map({ $0 != .ready }) == true {
                recapReady(meeting)
            }
        } catch {
            logger.error("Listing meetings failed: \(String(describing: error), privacy: .public)")
            activity.record(failure: error, in: ProblemContext(stage: .loadingMeetings))
        }
        announceAttention(loaded: loaded)
    }

    private func announceAttention(loaded: Bool = false) {
        guard var tracker = attention else {
            if loaded { attention = AttentionTracker(seed: meetings) }
            return
        }
        let ids = tracker.update(meetings, isRecording: isRecording)
        attention = tracker
        for id in ids {
            guard let meeting = meetings.first(where: { $0.id == id }) else { continue }
            RecapNotifications.needsAttention(meeting, reason: ProcessingDisplay.attentionReason(meeting, api: settings.macbook.api) ?? "")
        }
    }

    /// Every change to a meeting goes through here, so the move to `.ready` is seen whoever made it.
    func apply(_ meeting: Meeting) {
        var becameReady = false
        var previous: Meeting?
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            guard !deletedIDs.contains(meeting.id) else { return }
            previous = meetings[index]
            becameReady = meeting.status == .ready && meetings[index].status != .ready
            meetings[index] = meeting
        } else {
            guard !deletedIDs.contains(meeting.id), store.exists(meeting.id) else { return }
            meetings.append(meeting)
        }
        meetings.sort { $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt > $1.startedAt }
        for entry in MeetingActivity.entries(from: previous, to: meeting, settings: settings, time: Date()) {
            activity.log.record(entry)
        }
        if becameReady { recapReady(meeting) }
        announceAttention()
    }

    private func recapReady(_ meeting: Meeting) {
        let id = meeting.id
        guard notified.insert(id).inserted else { return }
        RecapNotifications.recapReady(meeting)
        Task { await autoFile(id) }
    }

    /// The user's own name for transcripts and recaps: the setting, else the first word of the macOS full name, else "Me".
    var resolvedUserName: String {
        SummaryRequestBuilder.resolvedUserName(settings.userName, systemFullName: NSFullUserName())
    }

    func saveSettings(_ s: MuninnCore.Settings) {
        do {
            try settingsStore.save(s)
        } catch {
            logger.error("Saving settings failed: \(String(describing: error), privacy: .public)")
            guard !ActivityCenter.isCancellation(error) else { return }
            let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingSettings, subject: "the settings"))
            activity.record(problem, area: .app)
            settingsProblem = problem
            failedSettings = s
            return
        }
        settingsProblem = nil
        failedSettings = nil
        settingsBox.value = s
        settings = s
    }

    func dismissSettingsProblem() {
        settingsProblem = nil
        failedSettings = nil
    }

    func prepareMeeting(startedAt: Date, mode: CaptureMode, appName: String?) async throws -> Meeting {
        let match = await eventMatch(at: startedAt)
        let meeting = MeetingPreparation.prepare(
            startedAt: startedAt,
            mode: mode,
            appName: appName,
            match: match,
            accounts: settings.accounts,
            clientDomains: settings.clientDomains,
            timeZone: .current,
            existingIDs: store.existingIDs()
        )
        do {
            try store.create(meeting)
        } catch {
            logger.error("Creating meeting \(meeting.id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        deletedIDs.remove(meeting.id)
        apply(meeting)
        return meeting
    }

    func eventMatch(at: Date) async -> EventMatch {
        await calendar.match(at: at, accounts: settings.accounts)
    }

    func searchPeople(account: String, query: String) async -> [Attendee] {
        guard let match = settings.accounts.first(where: { $0.id == account }) else { return [] }
        do {
            return try await graph.client(for: match).searchPeople(query)
        } catch {
            logger.warning("People search for \(account, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if !ActivityCenter.isCancellation(error) {
                let context = ProblemContext(stage: .searchingPeople, accountName: match.displayName)
                activity.record(
                    .warning, .outlook, "People search failed",
                    details: ProblemTranslator.problem(for: error, in: context).details
                )
            }
            return []
        }
    }

    func process(_ id: MeetingID) {
        notified.remove(id)
        let pipeline = self.pipeline
        let setup = setupTask
        Task {
            await setup?.value
            await pipeline.process(id)
        }
    }

    /// Not awaited by callers: it runs every waiting meeting to completion, one after another.
    private func resumeHeldProcessing() {
        let pipeline = self.pipeline
        let setup = setupTask
        Task {
            await setup?.value
            await pipeline.resumeWaiting()
        }
    }

    /// Whether the stored recap carries the user's own edits; read from the store, because the editor's copy is only marked after a save.
    func hasEditedSummary(_ id: MeetingID) -> Bool {
        ((try? store.loadSummary(id)) ?? nil)?.edited == true
    }

    /// Swaps the previous recap back in and brings the meeting's engine and language in line with it.
    @discardableResult
    func restorePreviousSummary(_ id: MeetingID) throws -> Summary {
        let restored = try store.restorePreviousSummary(id)
        try mutate(id) {
            $0.summaryEngine = restored.engine
            $0.language = restored.language
        }
        return restored
    }

    func regenerate(_ id: MeetingID, engine: EngineKind) {
        guard !eventChangesInFlight.contains(id) else {
            report(MeetingActionError.eventChangeInProgress, stage: .writingRecap, for: id)
            return
        }
        guard unsavedSummaries[id] == nil else {
            report(MeetingActionError.unsavedEdits, stage: .writingRecap, for: id)
            return
        }
        if hasEditedSummary(id),
           Alerts.ask(
               "Replace your edited recap?",
               "The current version is kept and can be restored.",
               buttons: ["Replace", "Cancel"]
           ) != 0 {
            return
        }
        notified.remove(id)
        let pipeline = self.pipeline
        let setup = setupTask
        Task {
            await setup?.value
            await pipeline.regenerate(id, engine: engine)
        }
    }
}
