import ArgumentParser
import Foundation
import MuninnAudio
import MuninnCore
import MuninnSpeech

struct Live: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run live transcription and write lag.csv: replay an audio file in real time, or capture and transcribe at once with --capture. Ctrl-C ends a capture early and keeps the files."
    )

    private static let chunkSeconds = 0.3

    @Argument(help: "Audio file to replay in real time (omit with --capture).")
    var audio: String?

    @ArgumentParser.Flag(help: "Record and transcribe live in this process, sampling system load every second into load.csv.")
    var capture = false

    @Option(help: "Live model: parakeet-v3 or parakeet-ultra.")
    var model: SpeechModelID = .parakeetV3

    @Option(help: "Replay only: the track lane to feed (mic or system).")
    var track: Track = .mic

    @Option(help: "Capture only: how long to record.")
    var seconds: Int?

    @OptionGroup var options: CaptureOptions

    @Option(help: "Output directory.")
    var out: String

    func validate() throws {
        if capture {
            guard audio == nil else { throw ValidationError("--capture records live; do not pass an audio file.") }
            guard let seconds, seconds > 0 else { throw ValidationError("--capture needs a positive --seconds.") }
            guard options.chosen == 1 else {
                throw ValidationError("--capture needs exactly one of --app <bundleID>, --all-system or --mic-only.")
            }
        } else {
            guard audio != nil else { throw ValidationError("Pass an audio file to replay, or use --capture.") }
            guard seconds == nil, options.isDefault else {
                throw ValidationError("--seconds, --app, --all-system, --mic-only, --voice-processing and --force only apply with --capture.")
            }
        }
    }

    func run() async throws {
        let directory = try Spike.outputDirectory(out)
        if capture {
            try await runCapture(into: directory)
        } else {
            try await runReplay(into: directory)
        }
    }

    private func runReplay(into directory: URL) async throws {
        let url = Spike.fileURL(audio ?? "")
        print("Reading \(url.lastPathComponent)")
        let samples = try AudioFile.mono16k(url)
        let audioSeconds = Double(samples.count) / 16_000
        print("Replaying \(Spike.seconds(audioSeconds)) of audio in real time with \(model.rawValue); the first run downloads the model")

        let transcriber = ParakeetLiveTranscriber(model: model)
        try await transcriber.start()
        let collector = LagCollector.start(transcriber, origin: Date())

        let size = Int(Self.chunkSeconds * 16_000)
        let clock = ContinuousClock()
        let start = clock.now
        var index = 0
        var nextReport = 60.0
        while index * size < samples.count {
            let from = index * size
            let chunk = LiveAudioChunk(track: track, samples: Array(samples[from..<min(from + size, samples.count)]), time: Double(from) / 16_000)
            await transcriber.feed(chunk)
            index += 1
            let fed = Double(index * size) / 16_000
            if fed >= nextReport {
                print(String(format: "t=%5.0f s  footprint %.0f MB", fed, Double(Spike.footprint()) / 1_048_576))
                nextReport += 60
            }
            try await clock.sleep(until: start + .seconds(Double(index) * Self.chunkSeconds))
        }
        collector.markFinishing()
        await transcriber.finish()
        let result = await collector.result()
        try result.write(to: directory)
        print("")
        result.printSummary()
        print("Wrote:          \(directory.path)/lag.csv, live-<track>.txt")
    }

    private func runCapture(into directory: URL) async throws {
        let seconds = seconds ?? 0
        let run = try CaptureRun.make(options, in: directory)
        let session = run.session

        print("Loading \(model.rawValue); the first run downloads the model")
        let transcriber = ParakeetLiveTranscriber(model: model)
        try await transcriber.start()
        try await run.start()
        let collector = LagCollector.start(transcriber, origin: Date().addingTimeInterval(-session.elapsed))
        let feeder = Task {
            for await chunk in session.liveAudio { await transcriber.feed(chunk) }
        }

        let stop = StopSignal()
        print("Capturing and transcribing for \(seconds) s into \(directory.path) (Ctrl-C stops early)")
        let sampler = LoadSampler()
        var peakFootprint: UInt64 = 0
        try await run.wait(seconds: seconds, stop: stop) { second in
            let snapshot = sampler.sample()
            let footprint = Spike.footprint()
            peakFootprint = max(peakFootprint, footprint)
            if second % 10 == 0 || second == seconds {
                print(run.levels(second) + String(format: "  footprint %.0f MB  pressure %d  cpu %.0f %%", Double(footprint) / 1_048_576, snapshot.pressureLevel, snapshot.cpuBusyPercent))
            }
        }
        let duration = try await session.stop()
        await feeder.value
        collector.markFinishing()
        await transcriber.finish()
        let result = await collector.result()

        try result.write(to: directory)
        try sampler.write(to: directory.appendingPathComponent("load.csv"))

        run.report(duration: duration, deliveredChunks: nil)
        print(String(format: "Peak footprint: %.0f MB", Double(peakFootprint) / 1_048_576))
        sampler.printSummary()
        result.printSummary()
        print("Wrote:          \(directory.path)/lag.csv, load.csv, live-<track>.txt, \(run.fileNames)")
        withExtendedLifetime(stop) {}
    }
}

struct LagResult {
    struct Row {
        var track: Track
        var audio: Double
        var produced: Double
        var lag: Double
        /// Produced by the flush in `finish()`, so the lag measures the flush, not the live pass.
        var final: Bool
    }

    var rows: [Row] = []
    var texts: [Track: String] = [:]

    func write(to directory: URL) throws {
        var csv = "track,audio_time,produced_at,lag_seconds,final\n"
        for row in rows {
            csv += String(format: "%@,%.2f,%.2f,%.2f,%@\n", row.track.rawValue, row.audio, row.produced, row.lag, row.final ? "true" : "false")
        }
        try Spike.write(csv, to: directory.appendingPathComponent("lag.csv"))
        for (track, text) in texts {
            try Spike.write(text + "\n", to: directory.appendingPathComponent("live-\(track.rawValue).txt"))
        }
    }

    /// Lag statistics leave out the updates `finish()` produced.
    func printSummary() {
        for track in [Track.mic, .system] {
            let lags = rows.filter { $0.track == track && !$0.final }.map(\.lag).sorted()
            guard let last = lags.last else { continue }
            print(String(
                format: "Lag %@ %d updates, median %.2f s, p95 %.2f s, max %.2f s (%d final updates left out)",
                (track.rawValue + ":").padding(toLength: 8, withPad: " ", startingAt: 0), lags.count,
                lags[lags.count / 2], lags[min(lags.count - 1, Int(Double(lags.count) * 0.95))], last,
                rows.filter { $0.track == track && $0.final }.count
            ))
        }
    }
}

final class LagCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var finishedAt: Date?
    private var task: Task<LagResult, Never>?

    /// `produced_at` and the lag are measured from `origin`, the moment recording time was zero.
    static func start(_ transcriber: ParakeetLiveTranscriber, origin: Date) -> LagCollector {
        let collector = LagCollector()
        collector.task = Task {
            var result = LagResult()
            for await update in transcriber.updates {
                let produced = update.producedAt.timeIntervalSince(origin)
                result.rows.append(.init(
                    track: update.track, audio: update.audioTime, produced: produced, lag: produced - update.audioTime,
                    final: collector.lock.withLock { collector.finishedAt }.map { update.producedAt >= $0 } ?? false
                ))
                result.texts[update.track] = update.text
            }
            return result
        }
        return collector
    }

    /// Call just before `finish()`: updates produced after it are the flush.
    func markFinishing() {
        lock.withLock { finishedAt = Date() }
    }

    func result() async -> LagResult {
        await task?.value ?? LagResult()
    }
}
