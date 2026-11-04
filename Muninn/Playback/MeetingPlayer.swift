import AppKit
import AVFoundation
import Combine
import MuninnAudio
import MuninnCore

/// The playback time on its own, so only the views that show the time redraw while playing.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var time: TimeInterval = 0

    func update(_ time: TimeInterval) {
        guard time.isFinite, time != self.time else { return }
        self.time = time
    }
}

/// Plays one meeting's recorded tracks in sync and remembers where each meeting was left.
@MainActor
final class MeetingPlayer: ObservableObject {
    enum State: Equatable {
        case idle, loading, unavailable, failed(Problem), ready
    }

    static let saveInterval: TimeInterval = 10

    @Published private(set) var meetingID: MeetingID?
    @Published private(set) var state = State.idle
    /// Follows the player's `timeControlStatus`, so it never disagrees with what the player is doing.
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var tracks: [Track] = []
    /// Playback began for this meeting in this session.
    @Published private(set) var hasStarted = false
    @Published var speed: Float = 1 {
        didSet { applySpeed() }
    }
    @Published var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    @Published var mix = PlaybackMix.both {
        didSet { applyMix() }
    }
    let clock = PlaybackClock()
    /// Every seek asked for, with its target, once the clock is there.
    let seeks = PassthroughSubject<TimeInterval, Never>()
    var timeline: SegmentTimeline?

    private let positions: PlaybackPositions
    private let store: MeetingStore
    private let activity: ActivityCenter
    private let player = AVPlayer()
    private var composition: PlaybackComposition?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemStatusObservation: AnyCancellable?
    private var playingObservation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    /// Bumped whenever the item goes, so a load or seek that finishes after it is dropped.
    private var generation = 0
    private var pendingSeeks = 0
    private var startedIDs: Set<MeetingID> = []
    private var recordedFailures: Set<MeetingID> = []
    private var recordedSkips: Set<MeetingID> = []
    private var lastSave = Date()

    init(positions: PlaybackPositions, store: MeetingStore, activity: ActivityCenter) {
        self.positions = positions
        self.store = store
        self.activity = activity
        player.actionAtItemEnd = .pause
        player.defaultRate = speed
        player.volume = volume
        playingObservation = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                MainActor.assumeIsolated { self?.statusChanged(status) }
            }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
    }

    /// A recording meeting stays `.idle`: its files are still being written. The meeting already loaded is left
    /// alone while it is loading or ready; anything else loads again, the newest load winning.
    func load(_ meeting: Meeting?) {
        guard let meeting else {
            stop()
            return
        }
        if meeting.id == meetingID, state == .loading || state == .ready { return }
        if meeting.id != meetingID { pause() }
        tearDown()
        meetingID = meeting.id
        hasStarted = startedIDs.contains(meeting.id)
        guard meeting.status != .recording else { return }

        state = .loading
        let mic = store.audioURL(meeting.id, track: .mic)
        let system = store.audioURL(meeting.id, track: .system)
        let generation = generation
        loadTask = Task { [weak self] in
            do {
                let loaded = try await PlaybackComposition.load(mic: mic, system: system)
                self?.finishLoading(loaded, meeting: meeting, generation: generation)
            } catch {
                self?.fail(error, meeting: meeting, generation: generation)
            }
        }
    }

    func play() {
        guard state == .ready, let id = meetingID else { return }
        if clock.time >= duration - 0.05 { seek(to: 0) }
        player.play()
        startedIDs.insert(id)
        hasStarted = true
        lastSave = Date()
    }

    func pause() {
        player.pause()
        savePosition()
    }

    func toggle() {
        if player.rate != 0 { pause() } else { play() }
    }

    func seek(to time: TimeInterval, play: Bool = false) {
        guard state == .ready, time.isFinite, let id = meetingID else { return }
        let target = move(to: time)
        positions.set(target, for: id)
        lastSave = Date()
        seeks.send(target)
        if play { self.play() }
    }

    func skip(by delta: TimeInterval) {
        guard state == .ready else { return }
        seek(to: Playback.skip(from: clock.time, by: delta, duration: duration))
    }

    /// Saves the position and unloads.
    func stop() {
        pause()
        tearDown()
        meetingID = nil
        hasStarted = false
    }

    /// Forgets a meeting that is going away, without saving its position.
    func unload(_ id: MeetingID) {
        startedIDs.remove(id)
        recordedFailures.remove(id)
        recordedSkips.remove(id)
        guard id == meetingID else { return }
        tearDown()
        meetingID = nil
        hasStarted = false
    }

    private func finishLoading(_ loaded: PlaybackComposition?, meeting: Meeting, generation: Int) {
        guard generation == self.generation, let id = meetingID else { return }
        guard let loaded, loaded.duration.isFinite, loaded.duration > 0 else {
            state = .unavailable
            return
        }
        if !loaded.skipped.isEmpty, recordedSkips.insert(id).inserted {
            activity.record(.warning, .recording, "Part of the recording couldn't be played", meeting: meeting,
                            details: ProblemDetails(stage: .playingRecording))
        }
        composition = loaded
        tracks = loaded.tracks
        duration = loaded.duration
        let item = AVPlayerItem(asset: loaded.composition)
        item.audioTimePitchAlgorithm = .timeDomain
        item.audioMix = loaded.audioMix(effectiveMix)
        player.replaceCurrentItem(with: item)
        addObservers(for: item, meeting: meeting)
        state = .ready
        move(to: PlaybackPositions.resumeTime(stored: positions.position(for: id), duration: loaded.duration))
    }

    /// Seeks with zero tolerance; the periodic time is ignored until the seek lands, so the clock doesn't jump back.
    @discardableResult
    private func move(to time: TimeInterval) -> TimeInterval {
        let target = min(max(time, 0), duration)
        let generation = generation
        pendingSeeks += 1
        player.seek(to: Self.cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.pendingSeeks = max(self.pendingSeeks - 1, 0)
            }
        }
        clock.update(target)
        return target
    }

    /// A load that threw, or an item that failed while playing: translated at `.playingRecording`, recorded once per
    /// meeting in Activity.
    private func fail(_ error: Error, meeting: Meeting, generation: Int) {
        guard generation == self.generation else { return }
        let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .playingRecording))
        if recordedFailures.insert(meeting.id).inserted {
            activity.record(problem, area: ProblemStage.playingRecording.area, meeting: meeting)
        }
        state = .failed(problem)
    }

    private func tearDown() {
        generation += 1
        pendingSeeks = 0
        loadTask?.cancel()
        loadTask = nil
        removeObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        composition = nil
        state = .idle
        duration = 0
        tracks = []
        clock.update(0)
    }

    private func addObservers(for item: AVPlayerItem, meeting: Meeting) {
        removeObservers()
        let generation = generation
        itemStatusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] status in
                guard status == .failed else { return }
                let error = item?.error
                MainActor.assumeIsolated { self?.itemFailed(error, meeting: meeting, generation: generation) }
            }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        }
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemStatusObservation = nil
    }

    private func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        let playing = status != .paused
        if playing != isPlaying { isPlaying = playing }
    }

    /// Saves where playback had got to, drops the item and shows the failure, which Try again reloads.
    private func itemFailed(_ error: Error?, meeting: Meeting, generation: Int) {
        guard generation == self.generation else { return }
        savePosition()
        tearDown()
        fail(error ?? AVError(.unknown), meeting: meeting, generation: self.generation)
    }

    private func tick(_ time: CMTime) {
        guard pendingSeeks == 0, let seconds = Self.seconds(time) else { return }
        clock.update(seconds)
        if isPlaying, Date().timeIntervalSince(lastSave) >= Self.saveInterval { savePosition() }
    }

    private func reachedEnd() {
        clock.update(duration)
        savePosition()
    }

    private func savePosition() {
        guard state == .ready, let id = meetingID else { return }
        let time = pendingSeeks > 0 ? clock.time : Self.seconds(player.currentTime()) ?? clock.time
        positions.set(time, for: id)
        lastSave = Date()
    }

    private var effectiveMix: PlaybackMix {
        tracks.count > 1 ? mix : .both
    }

    private func applySpeed() {
        player.defaultRate = speed
        if player.rate != 0 { player.rate = speed }
    }

    private func applyMix() {
        guard let composition, let item = player.currentItem else { return }
        item.audioMix = composition.audioMix(effectiveMix)
    }

    private static func seconds(_ time: CMTime) -> TimeInterval? {
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : nil
    }

    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
