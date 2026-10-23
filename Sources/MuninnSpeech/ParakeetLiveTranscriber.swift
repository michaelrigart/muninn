import AVFoundation
import FluidAudio
import Foundation
import MuninnCore

/// `text` is the cumulative text of the track so far, not one window: consumers replace the
/// track's whole text with the latest update. `isFinal` is advisory (FluidAudio's confirmation
/// of the newest window; the update `finish()` produces per track is always final).
public struct LiveTranscriptUpdate: Sendable {
    public var track: Track
    public var text: String
    public var isFinal: Bool
    /// Recording time the text reaches; compare with wall clock to measure lag.
    public var audioTime: TimeInterval
    public var producedAt: Date

    public init(track: Track, text: String, isFinal: Bool, audioTime: TimeInterval, producedAt: Date) {
        self.track = track
        self.text = text
        self.isFinal = isFinal
        self.audioTime = audioTime
        self.producedAt = producedAt
    }
}

public final class ParakeetLiveTranscriber: @unchecked Sendable {
    private let session: Session
    private let stream: AsyncStream<LiveTranscriptUpdate>

    public convenience init(model: SpeechModelID) {
        self.init(model: model, modelLoader: { try await ParakeetModels.models(for: $0) })
    }

    init(model: SpeechModelID, modelLoader: @escaping @Sendable (AsrModelVersion) async throws -> AsrModels) {
        let (stream, continuation) = AsyncStream<LiveTranscriptUpdate>.makeStream()
        self.stream = stream
        session = Session(model: model, continuation: continuation, modelLoader: modelLoader)
    }

    public var updates: AsyncStream<LiveTranscriptUpdate> { stream }

    public func start() async throws {
        try await session.start()
    }

    public func feed(_ chunk: LiveAudioChunk) async {
        await session.feed(chunk)
    }

    public func finish() async {
        await session.finish()
    }
}

extension ParakeetLiveTranscriber {
    /// Short windows keep the preview close to real time; the batch pass produces the final text.
    static let streamingConfig = SlidingWindowAsrConfig(
        chunkSeconds: 4,
        hypothesisChunkSeconds: 1,
        leftContextSeconds: 2,
        rightContextSeconds: 1,
        minContextForConfirmation: 6,
        confirmationThreshold: 0.8
    )

    actor Session {
        private enum State {
            case idle, starting, running, finishing, finished
        }

        private struct Lane {
            var manager: SlidingWindowAsrManager
            var consumer: Task<Void, Never>
            var origin: TimeInterval?
            var fedUntil: TimeInterval = 0
        }

        private let model: SpeechModelID
        private let continuation: AsyncStream<LiveTranscriptUpdate>.Continuation
        private let modelLoader: @Sendable (AsrModelVersion) async throws -> AsrModels
        private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        private var state = State.idle
        private var lanes: [Track: Lane] = [:]

        init(
            model: SpeechModelID,
            continuation: AsyncStream<LiveTranscriptUpdate>.Continuation,
            modelLoader: @escaping @Sendable (AsrModelVersion) async throws -> AsrModels
        ) {
            self.model = model
            self.continuation = continuation
            self.modelLoader = modelLoader
        }

        func start() async throws {
            guard state == .idle else { throw SpeechError.alreadyStarted }
            state = .starting
            do {
                guard let version = model.parakeetVersion else { throw SpeechError.unsupportedModel(model) }
                let models = try await modelLoader(version)
                try ensureStarting()
                for track in [Track.mic, .system] {
                    let manager = SlidingWindowAsrManager(config: ParakeetLiveTranscriber.streamingConfig)
                    let updates: AsyncStream<SlidingWindowTranscriptionUpdate>
                    do {
                        try await manager.loadModels(models)
                        try await manager.startStreaming(source: track == .mic ? .microphone : .system)
                        updates = await manager.transcriptionUpdates
                        try ensureStarting()
                    } catch {
                        await manager.cleanup()
                        throw error
                    }
                    let consumer = Task { [weak self] in
                        for await update in updates {
                            await self?.emit(update, track: track)
                        }
                    }
                    lanes[track] = Lane(manager: manager, consumer: consumer)
                }
                state = .running
            } catch {
                await abort()
                throw error
            }
        }

        /// `finish()` may run while `start()` is suspended; whatever `start()` built is then torn down.
        private func ensureStarting() throws {
            if state != .starting { throw CancellationError() }
        }

        func feed(_ chunk: LiveAudioChunk) async {
            guard state == .running, var lane = lanes[chunk.track], let format, !chunk.samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else { return }
            buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.samples.count) }
            if lane.origin == nil { lane.origin = chunk.time }
            lane.fedUntil = max(lane.fedUntil, chunk.time + Double(chunk.samples.count) / 16_000)
            lanes[chunk.track] = lane
            await lane.manager.streamAudio(buffer)
        }

        /// Lanes stay in place until every consumer has drained, so the flush and the backlog
        /// of updates are still emitted.
        func finish() async {
            switch state {
            case .idle, .starting:
                state = .finished
                continuation.finish()
                return
            case .finishing, .finished:
                return
            case .running:
                break
            }
            state = .finishing
            for (track, lane) in lanes {
                var finalText: String?
                do {
                    finalText = try await lane.manager.finish()
                } catch {
                    SpeechLog.logger.error("Live \(track.rawValue, privacy: .public) transcription failed to finish: \(String(describing: error), privacy: .public)")
                }
                await lane.manager.cancel()
                await lane.consumer.value
                if let text = finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, let last = lanes[track] {
                    continuation.yield(LiveTranscriptUpdate(
                        track: track,
                        text: text,
                        isFinal: true,
                        audioTime: last.fedUntil,
                        producedAt: Date()
                    ))
                }
            }
            lanes = [:]
            state = .finished
            continuation.finish()
        }

        private func abort() async {
            let aborted = lanes
            lanes = [:]
            state = .finished
            for lane in aborted.values {
                lane.consumer.cancel()
                await lane.manager.cleanup()
            }
            continuation.finish()
        }

        private func emit(_ update: SlidingWindowTranscriptionUpdate, track: Track) async {
            guard let lane = lanes[track] else { return }
            let text = await lane.manager.cumulativeText()
            guard !text.isEmpty else { return }
            let audioTime = update.tokenTimings.last.map { (lane.origin ?? 0) + $0.endTime } ?? lane.fedUntil
            continuation.yield(LiveTranscriptUpdate(
                track: track,
                text: text,
                isFinal: update.isConfirmed,
                audioTime: audioTime,
                producedAt: Date()
            ))
        }
    }
}

extension SlidingWindowAsrManager {
    /// Confirmed and volatile text read inside one actor turn, so a promotion cannot fall between them.
    func cumulativeText() -> String {
        [confirmedTranscript, volatileTranscript]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
