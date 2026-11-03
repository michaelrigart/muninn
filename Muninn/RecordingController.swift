import AppKit
import Combine
import Foundation
import MuninnAudio
import MuninnCore
import MuninnSpeech
import MuninnSystem
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "recording")

struct RecordingNotice: Equatable {
    enum Kind { case error, warning }

    var kind: Kind
    var message: String
}

@MainActor
final class RecordingController: ObservableObject {
    static let hangUpGrace: Duration = .seconds(5)
    private static let recheckWindow: TimeInterval = 3

    @Published private(set) var state: RecordingFlowState = .idle {
        didSet { stateChanged(from: oldValue) }
    }
    @Published private(set) var meetingID: MeetingID?
    @Published private(set) var isPaused = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var liveStatus: String?
    @Published private(set) var flagCount = 0
    @Published private(set) var interruption: RecordingInterruption?
    @Published private(set) var callAudioWarning: String?
    /// Watched apps that are using the microphone right now, whether or not an offer was declined; the idle menu records them.
    @Published private(set) var activeCalls: [CallIdentity] = []
    @Published var notice: RecordingNotice? {
        didSet { refreshPanels() }
    }

    /// Elapsed time, levels and live text; observed by the pill and the live transcript window only.
    let metrics = LiveMetrics()

    private let model: AppModel
    private lazy var promptPanel = CallPromptPanel(controller: self)
    private lazy var pillPanel = RecordingPillPanel(controller: self)

    private var settingsSubscription: AnyCancellable?
    private var detector: CallDetector?
    private var detectorTask: Task<Void, Never>?
    private var watchList: [String]?
    /// The list the running detector was started with; it lags `watchList` while a recording keeps its own detector.
    private var runningWatchList: [String]?
    private var hotkey: GlobalHotkey?
    private var hotkeySetting: Hotkey?
    private var showPill = true
    private var recheck: (bundleID: String, until: Date)?

    private var session: RecordingSession?
    private var transcriber: ParakeetLiveTranscriber?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    /// The call that ended while its recording was still starting; a tap failure must not then offer to record it.
    private var endedWhileStarting: String?
    private var liveTask: Task<Void, Never>?
    private var updatesTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var pendingMeetingID: MeetingID?
    private var stopRequested = false
    private var didStart = false
    private var liveRunning = false
    private var callAudioMonitor = CallAudioMonitor()
    private var monitorsCallAudio = false
    private var monitoredApp: String?
    private var noCallAudioPosted = false
    private var writeFailuresPosted: Set<Track> = []

    init(model: AppModel) {
        self.model = model
        settingsSubscription = model.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                MainActor.assumeIsolated { self?.apply(settings: settings) }
            }
    }

    var isActive: Bool {
        if case .recording = state { return true }
        return false
    }

    var isConversation: Bool {
        if case .recording(.micOnly, _) = state { return true }
        return false
    }

    var needsShutdown: Bool {
        isActive || stopTask != nil || pendingMeetingID != nil
    }

    // MARK: Detection

    func handle(_ event: CallEvent) {
        switch event {
        case .started(let bundleID, let pid):
            let identity = CallIdentity(appName: AppNames.name(bundleID: bundleID, pid: pid), bundleID: bundleID, pid: pid)
            if let index = activeCalls.firstIndex(where: { $0.bundleID == bundleID }) {
                activeCalls[index] = identity
            } else {
                activeCalls.append(identity)
            }
            if case .recording(_, let call?) = state, call.bundleID == bundleID {
                cancelAutoStop()
                endedWhileStarting = nil
            }
            if let recheck, recheck.bundleID == bundleID, Date() < recheck.until { return }
            send(.callStarted(appName: AppNames.name(bundleID: bundleID, pid: pid), bundleID: bundleID, pid: pid))
        case .ended(let bundleID):
            activeCalls.removeAll { $0.bundleID == bundleID }
            send(.callEnded(bundleID: bundleID))
            if case .recording(_, let call?) = state, call.bundleID == bundleID, isStarting { endedWhileStarting = bundleID }
            if case .recording(_, let call?) = state, call.bundleID == bundleID, !isFinishing, autoStopTask == nil {
                autoStopTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.hangUpGrace)
                    guard !Task.isCancelled, let self else { return }
                    self.autoStopTask = nil
                    await self.stop()
                }
            }
        }
    }

    // MARK: Starting

    /// Records the call it is asked for; any other state or call is ignored.
    func startCall(bundleID: String, pid: pid_t) {
        if case .idle = state {
            send(.callStarted(appName: AppNames.name(bundleID: bundleID, pid: pid), bundleID: bundleID, pid: pid))
        }
        guard case .offering(let call) = state, call.bundleID == bundleID, call.pid == pid else { return }
        record()
    }

    func record() {
        guard case .offering(let call) = state else { return }
        send(.recordTapped)
        launch(plan: .process(bundleID: call.bundleID, pid: call.pid), call: call)
    }

    func decline() {
        send(.declined)
    }

    func startConversation() {
        guard case .idle = state else { return }
        send(.manualConversation)
        launch(plan: .micOnly, call: nil)
    }

    func confirmAllAudio() {
        guard case .confirmAllAudio(let call) = state else { return }
        send(.confirmAllAudio)
        launch(plan: .allSystemAudio, call: call)
    }

    func cancelAllAudio() {
        send(.cancel)
    }

    // MARK: Controls

    func flag() {
        guard didStart, let session, let id = meetingID else { return }
        let offset = session.elapsed
        do {
            try model.mutate(id) { $0.flags.append(Flag(offset: offset)) }
            flagCount += 1
        } catch {
            logger.error("Saving the flag failed: \(String(describing: error), privacy: .public)")
            notice = RecordingNotice(kind: .error, message: "Couldn't save the flag: \(Self.describe(error))")
        }
    }

    func pause() {
        guard didStart, !isPaused else { return }
        session?.pause()
        isPaused = true
    }

    func resume() {
        guard didStart, isPaused else { return }
        session?.resume()
        isPaused = false
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard case .recording = state else { return }
        let endedAt = Date()
        isFinishing = true
        stopRequested = true
        cancelAutoStop()
        let task = Task { await self.performStop(endedAt: endedAt) }
        stopTask = task
        await task.value
        stopTask = nil
    }

    /// Finishes a recording in progress and drops an unused pending meeting, before the app quits.
    func shutdown() async {
        await stop()
        discardPending()
    }

    private func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    // MARK: Start

    private func launch(plan: TapPlan, call: CallIdentity?) {
        cancelAutoStop()
        endedWhileStarting = nil
        stopRequested = false
        didStart = false
        liveRunning = false
        isStarting = true
        isPaused = false
        flagCount = 0
        interruption = nil
        callAudioWarning = nil
        callAudioMonitor = CallAudioMonitor()
        monitorsCallAudio = false
        monitoredApp = call?.appName
        noCallAudioPosted = false
        writeFailuresPosted = []
        liveStatus = nil
        notice = nil
        metrics.reset()
        startTask = Task { [weak self] in
            await self?.runStart(plan: plan, call: call)
        }
    }

    private func runStart(plan: TapPlan, call: CallIdentity?) async {
        defer {
            isStarting = false
            startTask = nil
        }
        let id: MeetingID
        if plan == .allSystemAudio, let pending = pendingMeetingID {
            id = pending
            pendingMeetingID = nil
        } else {
            discardPending()
            let mode: CaptureMode = call.map { .call(appBundleID: $0.bundleID) } ?? .micOnly
            do {
                id = try await model.prepareMeeting(startedAt: Date(), mode: mode, appName: call?.appName).id
            } catch {
                fail(error, meeting: nil, prefix: "Couldn't create the meeting")
                return
            }
        }
        meetingID = id
        guard !stopRequested else { return }

        let system: (url: URL?, tap: TapTarget?)
        switch plan {
        case .process(let bundleID, let pid):
            system = (model.store.audioURL(id, track: .system), .app(bundleID: bundleID, pid: pid))
        case .allSystemAudio: system = (model.store.audioURL(id, track: .system), .allSystemAudio)
        case .micOnly: system = (nil, nil)
        }
        let session = RecordingSession(config: RecordingConfig(
            micURL: model.store.audioURL(id, track: .mic), systemURL: system.url, tap: system.tap,
            voiceProcessing: model.settings.recording.voiceProcessing
        ))
        self.session = session
        monitorsCallAudio = system.url != nil
        do {
            try await session.start()
        } catch {
            guard !stopRequested else { return }
            self.session = nil
            if case RecordingError.tapUnavailable(let reason) = error, case .process = plan, call != nil {
                logger.error("Process tap unavailable: \(reason, privacy: .public)")
                cancelAutoStop()
                meetingID = nil
                if let call, endedWhileStarting == call.bundleID {
                    discard(id)
                    send(.stopped)
                } else {
                    pendingMeetingID = id
                    send(.processTapFailed)
                }
            } else {
                fail(error, meeting: id, prefix: "Couldn't start recording")
            }
            return
        }
        guard !stopRequested else { return }
        didStart = true
        startTicker()
        startLive(session)
    }

    private func fail(_ error: Error, meeting id: MeetingID?, prefix: String) {
        cancelAutoStop()
        let detail = Self.describe(error)
        var message = "\(prefix): \(detail)"
        if let id {
            do {
                try model.mutate(id) {
                    $0.status = .failed(detail)
                    $0.endedAt = Date()
                }
            } catch {
                message += " The meeting could not be marked as failed: \(Self.describe(error))"
            }
        }
        logger.error("\(message, privacy: .public)")
        meetingID = nil
        session = nil
        notice = RecordingNotice(kind: .error, message: message)
        send(.stopped)
    }

    private func discard(_ id: MeetingID) {
        do {
            try model.store.delete(id)
        } catch {
            logger.error("Removing the unused meeting \(id.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            post(RecordingNotice(kind: .error, message: "Couldn't remove the unused meeting \(id.rawValue): \(Self.describe(error))"))
        }
        model.reloadMeetings()
    }

    private func post(_ new: RecordingNotice) {
        guard let current = notice else {
            notice = new
            return
        }
        guard !current.message.contains(new.message) else { return }
        notice = RecordingNotice(
            kind: current.kind == .error || new.kind == .error ? .error : .warning,
            message: current.message + "\n" + new.message
        )
    }

    private func discardPending() {
        guard let id = pendingMeetingID else { return }
        pendingMeetingID = nil
        discard(id)
    }

    // MARK: Live transcription

    private func startLive(_ session: RecordingSession) {
        let name = model.settings.liveModel
        let modelID = SpeechModelID.liveModel(named: name)
        if modelID.rawValue != name {
            logger.error("Live model \(name, privacy: .public) can't stream; using \(modelID.rawValue, privacy: .public)")
        }
        let transcriber = ParakeetLiveTranscriber(model: modelID)
        self.transcriber = transcriber
        updatesTask = Task { [weak self] in
            for await update in transcriber.updates {
                self?.metrics.setText(update.text, for: update.track)
            }
        }
        liveTask = Task.detached { [weak self] in
            do {
                try await transcriber.start()
            } catch {
                await self?.liveFailed(error, transcriber: transcriber)
                return
            }
            await self?.markLiveRunning(transcriber)
            for await chunk in session.liveAudio {
                await transcriber.feed(chunk)
            }
        }
    }

    private func markLiveRunning(_ transcriber: ParakeetLiveTranscriber) {
        if transcriber === self.transcriber { liveRunning = true }
    }

    private func liveFailed(_ error: Error, transcriber: ParakeetLiveTranscriber) {
        guard !(error is CancellationError), transcriber === self.transcriber else { return }
        logger.error("Live transcription unavailable: \(String(describing: error), privacy: .public)")
        liveStatus = "Live transcript unavailable: \(error.localizedDescription)"
    }

    // MARK: Stop

    private func performStop(endedAt: Date) async {
        let pendingStart = startTask
        if let session {
            do {
                _ = try await session.stop()
            } catch {
                logger.error("Stopping the recording failed: \(String(describing: error), privacy: .public)")
            }
        }
        await pendingStart?.value
        if let session {
            _ = try? await session.stop()
        }
        ticker?.cancel()
        ticker = nil
        if let transcriber {
            if liveRunning {
                await liveTask?.value
                await transcriber.finish()
            } else {
                liveTask?.cancel()
                await transcriber.finish()
            }
            await updatesTask?.value
        }
        let writeErrors = session?.writeErrors ?? [:]
        var finished: MeetingID?
        if let id = meetingID {
            if didStart {
                do {
                    try model.mutate(id) { $0 = MeetingActions.finishRecording($0, endedAt: endedAt) }
                } catch {
                    logger.error("Saving the meeting end failed: \(String(describing: error), privacy: .public)")
                    post(RecordingNotice(kind: .error, message: "Couldn't save the end of the recording: \(Self.describe(error))"))
                }
                finished = id
                if !writeErrors.isEmpty {
                    let tracks = writeErrors.keys.map { $0 == .mic ? "microphone" : "call audio" }.sorted().joined(separator: " and ")
                    let detail = writeErrors.values.first.map { ": \($0.localizedDescription)" } ?? ""
                    logger.error("Write errors on \(tracks, privacy: .public)\(detail, privacy: .public)")
                    post(RecordingNotice(
                        kind: .warning,
                        message: "The \(tracks) recording could not be fully written\(detail). The meeting was kept; its transcript may be incomplete."
                    ))
                }
            } else {
                discard(id)
            }
        }
        let recordedCall: CallIdentity?
        if case .recording(_, let call) = state { recordedCall = call } else { recordedCall = nil }
        session = nil
        transcriber = nil
        liveTask = nil
        updatesTask = nil
        meetingID = nil
        isPaused = false
        interruption = nil
        callAudioWarning = nil
        monitorsCallAudio = false
        metrics.reset()
        isFinishing = false
        send(.stopped)
        // The gate is open again by now, so this meeting's own job is not held behind the recording that just ended.
        if let finished { model.process(finished) }
        recheckDetector(recorded: recordedCall)
    }

    // MARK: Sampling

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func sample() {
        guard let session else { return }
        metrics.update(
            elapsed: session.elapsed.rounded(.down),
            micLevel: Self.normalise(session.micLevel),
            systemLevel: Self.normalise(session.systemLevel)
        )
        let current = session.interruption
        if current != interruption { interruption = current }
        for failure in session.interruptions.values {
            guard case .writeFailed = failure, writeFailuresPosted.insert(failure.track).inserted else { continue }
            let text = RecordingPillView.describe(failure)
            logger.error("\(text, privacy: .public)")
            post(RecordingNotice(kind: .error, message: "\(text). The rest of this recording will not be saved."))
        }
        guard monitorsCallAudio else { return }
        let silent = callAudioMonitor.update(
            elapsed: session.elapsed,
            micDB: session.micLevel,
            systemDB: session.systemLevel,
            paused: isPaused
        )
        let warning = silent ? Self.noCallAudioMessage(app: monitoredApp) : nil
        if warning != callAudioWarning { callAudioWarning = warning }
        if let warning, !noCallAudioPosted {
            noCallAudioPosted = true
            logger.warning("\(warning, privacy: .public)")
            post(RecordingNotice(kind: .warning, message: warning))
        }
    }

    private static func noCallAudioMessage(app: String?) -> String {
        "No call audio for a minute — check that \(app ?? "the call app") plays through this Mac and that Muninn may record system audio."
    }

    private static func normalise(_ db: Float) -> Float {
        ((max(-60, min(0, db)) + 60) / 60 * 20).rounded() / 20
    }

    // MARK: Flow

    private func send(_ event: RecordingFlowEvent) {
        let next = RecordingFlow.next(state, event)
        if next != state { state = next }
    }

    private func stateChanged(from old: RecordingFlowState) {
        model.isRecording = isActive
        if case .confirmAllAudio = old {
            switch state {
            case .confirmAllAudio, .recording: break
            default: discardPending()
            }
        }
        syncDetector()
        refreshPanels()
    }

    private func refreshPanels() {
        let wantsPrompt: Bool
        switch state {
        case .offering, .confirmAllAudio: wantsPrompt = true
        default: wantsPrompt = notice != nil
        }
        if wantsPrompt { promptPanel.show() } else { promptPanel.hide() }
        if showPill, isActive { pillPanel.show() } else { pillPanel.hide() }
    }

    // MARK: Settings

    private func apply(settings: MuninnCore.Settings) {
        if watchList != settings.watchList {
            watchList = settings.watchList
            syncDetector()
            dismissUnwatchedPrompt(settings.watchList)
        }
        if hotkeySetting != settings.flagHotkey {
            hotkeySetting = settings.flagHotkey
            registerHotkey(settings.flagHotkey)
        }
        if showPill != settings.showPill {
            showPill = settings.showPill
            refreshPanels()
        }
    }

    private func dismissUnwatchedPrompt(_ list: [String]) {
        let call: CallIdentity
        switch state {
        case .offering(let offered), .confirmAllAudio(let offered): call = offered
        default: return
        }
        let entries = Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if !entries.contains(call.bundleID.lowercased()) {
            send(.callEnded(bundleID: call.bundleID))
        }
    }

    /// Starts the detector on the current watch list when it is on another one and no recording holds it (see `RecordingFlow.detectorNeedsRestart`).
    /// A prompt for an app that the list dropped meanwhile goes too, because the new detector will never report that call ending.
    private func syncDetector() {
        guard RecordingFlow.detectorNeedsRestart(running: runningWatchList, wanted: watchList, state: state), let list = watchList else { return }
        restartDetector(watchList: list)
        dismissUnwatchedPrompt(list)
    }

    private func restartDetector(watchList list: [String]) {
        runningWatchList = list
        detectorTask?.cancel()
        detector?.stop()
        activeCalls = []
        let detector = CallDetector(listing: CoreAudioProcessList(), watchList: { list })
        self.detector = detector
        detectorTask = Task { [weak self] in
            for await event in detector.events {
                self?.handle(event)
            }
        }
        detector.start()
    }

    /// A new detector reports every watched app already using the microphone, so a call that began during the recording is offered. The call just recorded is not offered again.
    private func recheckDetector(recorded: CallIdentity?) {
        guard let list = watchList else { return }
        recheck = recorded.map { ($0.bundleID, Date().addingTimeInterval(Self.recheckWindow)) }
        restartDetector(watchList: list)
    }

    private func registerHotkey(_ setting: Hotkey) {
        hotkey?.unregister()
        hotkey = nil
        do {
            hotkey = try GlobalHotkey(hotkey: setting) { [weak self] in self?.flag() }
            model.hotkeyError = nil
        } catch {
            logger.error("Registering the flag hotkey failed: \(String(describing: error), privacy: .public)")
            let message = "The flag hotkey \(HotkeyText.format(setting)) couldn't be registered (\(Self.describe(error))). Another app may be using it."
            model.hotkeyError = message
            post(RecordingNotice(kind: .error, message: message))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
