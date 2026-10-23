import ArgumentParser
import Foundation
import MuninnAudio
import MuninnCore

struct CaptureOptions: ParsableArguments {
    @Option(help: "Bundle ID (or prefix) of the app to tap, for example com.microsoft.teams2.")
    var app: String?

    @ArgumentParser.Flag(help: "Tap all system audio instead of one app.")
    var allSystem = false

    @ArgumentParser.Flag(help: "Record the mic only, with no system track.")
    var micOnly = false

    @ArgumentParser.Flag(help: "Enable voice processing (echo cancellation) on the mic.")
    var voiceProcessing = false

    @ArgumentParser.Flag(help: "Overwrite mic.caf and system.caf if they already exist in the output directory. They are moved aside as *.caf.previous while recording starts, put back if it fails, and deleted once it has started. A *.caf.previous left by an interrupted start makes the capture refuse until you recover or delete it.")
    var force = false

    var chosen: Int { [app != nil, allSystem, micOnly].filter { $0 }.count }

    var isDefault: Bool { chosen == 0 && !voiceProcessing && !force }
}

/// Ctrl-C asks a running capture to stop early; the files and CSVs are still written.
final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            self?.lock.withLock { self?.requested = true }
            Spike.log("Stopping early; finishing the files.")
        }
        source.resume()
    }

    var isRequested: Bool { lock.withLock { requested } }

    deinit {
        source.cancel()
        signal(SIGINT, SIG_DFL)
    }
}

struct CaptureRun {
    let session: RecordingSession
    let tap: TapTarget?
    let micURL: URL
    let systemURL: URL
    /// Held until the capture is done, so two captures can't write into one folder.
    let lock: FileLock

    static func make(_ options: CaptureOptions, in directory: URL) throws -> CaptureRun {
        let lock = try takeLock(in: directory)
        let micURL = directory.appendingPathComponent("mic.caf")
        let systemURL = directory.appendingPathComponent("system.caf")
        do {
            try FileReplacement.requireNoAsideCopies([micURL, systemURL])
        } catch {
            throw SpikeError(error.localizedDescription)
        }
        try protectExisting([micURL, systemURL], force: options.force)
        var tap: TapTarget?
        if let app = options.app {
            tap = try resolve(app)
        } else if options.allSystem {
            tap = .allSystemAudio
        }
        let session = RecordingSession(config: RecordingConfig(
            micURL: micURL,
            systemURL: tap == nil ? nil : systemURL,
            tap: tap,
            voiceProcessing: options.voiceProcessing
        ))
        return CaptureRun(session: session, tap: tap, micURL: micURL, systemURL: systemURL, lock: lock)
    }

    /// An exclusive lock on `<directory>/.capture.lock`, taken before the overwrite check so two captures can't both pass it.
    private static func takeLock(in directory: URL) throws -> FileLock {
        let url = directory.appendingPathComponent(".capture.lock")
        let lock: FileLock?
        do {
            lock = try FileLock.tryAcquire(url)
        } catch {
            throw SpikeError("Couldn't lock \(directory.path) for the capture: \(error.localizedDescription)")
        }
        guard let lock else { throw SpikeError("Another capture is writing to \(directory.path)") }
        return lock
    }

    /// Refuses to record over earlier captures unless `force` is set; `start()` deletes them once the recording has started.
    /// A mic-only capture would otherwise leave an old system.caf for `e2e` to combine.
    static func protectExisting(_ urls: [URL], force: Bool) throws {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        guard force else {
            let names = existing.map(\.lastPathComponent).joined(separator: " and ")
            throw SpikeError("\(names) already exist\(existing.count == 1 ? "s" : "") in \(existing[0].deletingLastPathComponent().path). Pass --force to delete both files and record again, or choose another --out.")
        }
    }

    /// Moves the earlier captures aside only now, once the tap is resolved, and puts them back if the recording can't start
    /// (`session.start()` can still fail, for example when the app has no audio process yet), deleting any track file the failed
    /// start created. They are deleted once it has started.
    func start() async throws {
        let aside = try FileReplacement.moveAside([micURL, systemURL])
        do {
            try await session.start()
        } catch {
            aside.restore()
            throw error
        }
        aside.discard()
    }

    /// Calls `tick(second)` once a second for `seconds` seconds, or until Ctrl-C.
    func wait(seconds: Int, stop: StopSignal, tick: (Int) -> Void) async throws {
        for second in 1...seconds {
            try await Task.sleep(for: .seconds(1))
            tick(second)
            if stop.isRequested { break }
        }
    }

    func levels(_ second: Int) -> String {
        var line = String(format: "t=%4d s  mic %7.1f dBFS", second, session.micLevel)
        if tap != nil { line += String(format: "  system %7.1f dBFS", session.systemLevel) }
        if let interruption = session.interruption { line += "  interruption: \(interruption)" }
        return line
    }

    func report(duration: TimeInterval, deliveredChunks: Int?) {
        print("")
        print("Duration:       \(Spike.seconds(duration))")
        describe("mic.caf", micURL)
        if tap != nil { describe("system.caf", systemURL) }
        let delivered = deliveredChunks.map { "\($0) delivered, " } ?? ""
        print("Live chunks:    \(delivered)\(session.droppedLiveChunks) dropped")
        let errors = session.writeErrors
        print("Write errors:   \(errors.isEmpty ? "none" : errors.map { "\($0.key.rawValue): \($0.value)" }.sorted().joined(separator: "; "))")
        print("Interruption:   \(session.interruption.map { String(describing: $0) } ?? "none")")
    }

    var fileNames: String { tap != nil ? "mic.caf, system.caf" : "mic.caf" }

    private func describe(_ name: String, _ url: URL) {
        let length = (try? AudioFile.duration(url)).map { Spike.seconds($0) } ?? "unreadable"
        print("\(name.padding(toLength: 15, withPad: " ", startingAt: 0))\(Spike.megabytes(Spike.fileSize(url))), \(length) of audio")
    }

    private static func resolve(_ bundleID: String) throws -> TapTarget {
        let processes = try CoreAudioProcessList().processes()
        let entry = bundleID.lowercased()
        let isMatch: (AudioProcessInfo) -> Bool = {
            let bundle = $0.bundleID.lowercased()
            return bundle == entry || bundle.hasPrefix(entry + ".")
        }
        guard let match = processes.first(where: isMatch) else {
            let known = processes.sorted { $0.bundleID < $1.bundleID }.map { "\($0.bundleID)  (pid \($0.pid))" }.joined(separator: "\n  ")
            throw SpikeError("No audio process matches \(bundleID). Audio processes right now:\n  \(known)")
        }
        let all = processes.filter(isMatch)
        print("Tapping \(all.count) audio process(es) of \(bundleID): \(all.map { "\($0.bundleID) (pid \($0.pid))" }.joined(separator: ", "))")
        return .app(bundleID: bundleID, pid: match.pid)
    }
}
