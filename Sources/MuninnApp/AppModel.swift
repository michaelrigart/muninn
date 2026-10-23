import AVFoundation
import Combine
import Foundation
import MuninnCore
import MuninnSpeech
import MuninnSystem
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "app")

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
    var error: String
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
        }
    }
    @Published var settings: Settings
    @Published var selectedMeetingID: MeetingID?
    /// Bumped to ask the always-alive menu bar label to open the Meetings window.
    @Published var openMeetingsRequest = 0
    /// The last failed draft or export per meeting, shown in that meeting's error banner.
    @Published var actionErrors: [MeetingID: String] = [:]
    @Published var actionNotices: [MeetingID: String] = [:]
    /// Recap edits that couldn't be saved, per meeting, kept until a save succeeds.
    @Published var unsavedSummaries: [MeetingID: UnsavedSummary] = [:]
    /// Accounts whose stored sign-in Microsoft rejected during the last calendar refresh.
    @Published var signInNeeded: Set<String> = []
    /// Meetings whose event is being fetched for a change. Drafts, exports and regeneration wait for it.
    @Published var eventChangesInFlight: Set<MeetingID> = []
    /// Why the flag hotkey couldn't be registered, if it couldn't.
    @Published var hotkeyError: String?

    let paths: MuninnPaths
    let store: MeetingStore
    let settingsStore: SettingsStore
    let secrets: KeychainSecrets
    let pipeline: ProcessingPipeline
    let graph: GraphServices
    let calendar: CalendarCache

    var actionsInFlight: Set<String> = []
    private let settingsBox: SettingsBox
    private let recordingGate: FlagBox
    private var setupTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    /// Meetings already announced this session; processing or regenerating one on request lets it announce again.
    private var notified: Set<MeetingID> = []
    /// Meetings deleted this session. A pipeline callback that is still in flight for one of them is dropped.
    var deletedIDs: Set<MeetingID> = []
    /// Set once the "choose your vault" notice has been shown for auto-filing, so it appears once per session.
    var vaultNoticeShown = false

    init() {
        let paths = MuninnPaths(home: FileManager.default.homeDirectoryForCurrentUser, environment: ProcessInfo.processInfo.environment)
        let store = MeetingStore(root: paths.meetings)
        let settingsStore = SettingsStore(file: paths.settingsFile)
        let secrets = KeychainSecrets()
        let loaded = settingsStore.load()
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
                        return LLMTranscriptCleaner(client: try Self.client(for: engine, settings: settings, secrets: secrets))
                    } catch {
                        logger.error("LLM cleanup unavailable, using rules: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return RuleTranscriptCleaner()
            },
            summarizer: LLMSummarizer(clientFor: { engine in
                try Self.client(for: engine, settings: box.value, secrets: secrets)
            }, settings: { box.value }),
            probe: LiveEnvironmentProbe(secrets: secrets),
            isRecording: { gate.value }
        )

        calendar.onSignInState = { [weak self] id, needed in
            guard let self else { return }
            if needed { signInNeeded.insert(id) } else { signInNeeded.remove(id) }
        }
        reloadMeetings()
        let pipeline = self.pipeline
        setupTask = Task { [weak self] in
            await pipeline.setOnChange { meeting in
                Task { @MainActor in self?.apply(meeting) }
            }
        }
        RecapNotifications.start { [weak self] id in self?.showMeeting(id) }
        startLifecycle()
    }

    /// Recovers meetings a quit or crash left unfinished, then retries waiting ones every minute; the calendar cache refreshes on its own loop.
    private func startLifecycle() {
        let pipeline = self.pipeline
        let setup = setupTask
        let interrupted = recoverInterruptedMeetings()
        lifecycleTask = Task {
            await setup?.value
            for id in interrupted {
                await pipeline.process(id)
            }
            while !Task.isCancelled {
                await pipeline.resumeWaiting()
                try? await Task.sleep(for: .seconds(60))
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
                    case .transcribe:
                        try mutate(meeting.id) { $0 = MeetingActions.finishRecording($0, endedAt: endedAt) }
                        ids.append(meeting.id)
                    case .markUnreadable:
                        try mutate(meeting.id) {
                            $0.status = .failed(LaunchRecovery.unreadableMessage)
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

    func showMeeting(_ id: MeetingID) {
        selectedMeetingID = id
        openMeetingsRequest += 1
    }

    nonisolated static func client(for engine: EngineKind, settings: Settings, secrets: KeychainSecrets) throws -> LLMClient {
        try EngineClients.make(engine, settings: settings, secrets: secrets)
    }

    func reloadMeetings() {
        do {
            let previous = Dictionary(meetings.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
            let loaded = try store.list()
            meetings = loaded
            for meeting in loaded where meeting.status == .ready && previous[meeting.id].map({ $0 != .ready }) == true {
                recapReady(meeting)
            }
        } catch {
            logger.error("Listing meetings failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Every change to a meeting goes through here, so the move to `.ready` is seen whoever made it.
    func apply(_ meeting: Meeting) {
        var becameReady = false
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            guard !deletedIDs.contains(meeting.id) else { return }
            becameReady = meeting.status == .ready && meetings[index].status != .ready
            meetings[index] = meeting
        } else {
            guard !deletedIDs.contains(meeting.id), store.exists(meeting.id) else { return }
            meetings.append(meeting)
        }
        meetings.sort { $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt > $1.startedAt }
        if becameReady { recapReady(meeting) }
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
            return
        }
        settingsBox.value = s
        settings = s
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
            actionErrors[id] = MeetingActionError.eventChangeInProgress.errorDescription
            return
        }
        guard unsavedSummaries[id] == nil else {
            actionErrors[id] = MeetingActionError.unsavedEdits.errorDescription
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
