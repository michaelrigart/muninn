import Foundation
import os

public enum CallEvent: Equatable, Sendable {
    case started(bundleID: String, pid: pid_t)
    case ended(bundleID: String)
}

public struct CallDiff {
    static let ownBundleID = "be.netronix.muninn"

    static var ignoredBundleIDs: Set<String> {
        Set([ownBundleID, Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    public static func events(
        previous: Set<String>,
        current: [AudioProcessInfo],
        watchList: [String]
    ) -> (events: [CallEvent], inputBundles: Set<String>) {
        let ignored = ignoredBundleIDs
        var pids: [String: pid_t] = [:]
        var order: [String] = []
        let entries = watchList
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for process in current where process.isRunningInput {
            guard !ignored.contains(where: { matches(process.bundleID, entry: $0) }) else { continue }
            guard let entry = entries.first(where: { matches(process.bundleID, entry: $0) }) else { continue }
            if pids[entry] == nil {
                pids[entry] = process.pid
                order.append(entry)
            }
        }
        let inputBundles = Set(order)
        let started = order.filter { !previous.contains($0) }.map { CallEvent.started(bundleID: $0, pid: pids[$0] ?? 0) }
        let ended = previous.subtracting(inputBundles).sorted().map { CallEvent.ended(bundleID: $0) }
        return (started + ended, inputBundles)
    }
}

func matches(_ bundleID: String, entry: String) -> Bool {
    let bundle = bundleID.lowercased()
    let entry = entry.lowercased()
    return !entry.isEmpty && (bundle == entry || bundle.hasPrefix(entry + "."))
}

public final class CallDetector: @unchecked Sendable {
    private let listing: AudioProcessListing
    private let watchList: @Sendable () -> [String]
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "be.netronix.muninn.call-detector")
    private let stream: AsyncStream<CallEvent>
    private let continuation: AsyncStream<CallEvent>.Continuation
    private let lock = NSLock()
    private let logger = Logger(subsystem: "be.netronix.muninn", category: "detection")
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var lastFailure: String?
    private var previous: Set<String> = []

    public init(listing: AudioProcessListing, watchList: @escaping @Sendable () -> [String], interval: TimeInterval = 1.0) {
        self.listing = listing
        self.watchList = watchList
        self.interval = interval
        (stream, continuation) = AsyncStream.makeStream(of: CallEvent.self, bufferingPolicy: .unbounded)
    }

    public var events: AsyncStream<CallEvent> { stream }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil, !stopped else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        lock.lock()
        stopped = true
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation.finish()
    }

    private func tick() {
        let current: [AudioProcessInfo]
        do {
            current = try listing.processes()
            lastFailure = nil
        } catch {
            let description = String(describing: error)
            if description != lastFailure {
                lastFailure = description
                logger.error("Listing audio processes failed: \(description, privacy: .public)")
            }
            return
        }
        let diff = CallDiff.events(previous: previous, current: current, watchList: watchList())
        previous = diff.inputBundles
        for event in diff.events { continuation.yield(event) }
    }

    deinit {
        timer?.cancel()
        continuation.finish()
    }
}
