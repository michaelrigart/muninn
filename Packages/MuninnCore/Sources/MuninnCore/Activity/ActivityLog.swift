import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "activity")

public final class ActivityLog: ActivityRecording, @unchecked Sendable {
    static let retention: TimeInterval = 14 * 24 * 3600
    static let maxBytes = 5_000_000
    static let trimmedBytes = 4_000_000

    public let file: URL
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = StorageJSON.decoder()
    private var observer: (@Sendable (ActivityEntry) -> Void)?

    public init(file: URL, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.clock = clock
        let encoder = StorageJSON.encoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
    }

    public func record(_ entry: ActivityEntry) {
        let safe = entry.redacted()
        lock.lock()
        let handler = observer
        append(safe)
        lock.unlock()
        handler?(safe)
    }

    /// Newest first. Lines that don't decode are skipped.
    public func entries() -> [ActivityEntry] {
        lock.lock()
        defer { lock.unlock() }
        let decoded = lines().enumerated().compactMap { index, line in
            (try? decoder.decode(ActivityEntry.self, from: line)).map { (index, $0) }
        }
        return decoded.sorted { ($0.1.time, $0.0) > ($1.1.time, $1.0) }.map(\.1)
    }

    public func prune() {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = clock().addingTimeInterval(-Self.retention)
        let all = lines()
        let kept = all.filter { line in
            guard let entry = try? decoder.decode(ActivityEntry.self, from: line) else { return false }
            return entry.time >= cutoff
        }
        let data = Self.joined(kept)
        guard kept.count != all.count || data.count > Self.maxBytes else { return }
        write(data.count > Self.maxBytes ? Self.newest(data, keeping: Self.trimmedBytes) : data)
    }

    public func setObserver(_ handler: (@Sendable (ActivityEntry) -> Void)?) {
        lock.lock()
        observer = handler
        lock.unlock()
    }

    // MARK: File

    private func append(_ entry: ActivityEntry) {
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forUpdating: file)
            let size: UInt64
            do {
                defer { try? handle.close() }
                size = try handle.seekToEnd()
                if size > 0 {
                    try handle.seek(toOffset: size - 1)
                    if try handle.read(upToCount: 1)?.first != 0x0A { line.insert(0x0A, at: 0) }
                    try handle.seekToEnd()
                }
                try handle.write(contentsOf: line)
            }
            if size + UInt64(line.count) > UInt64(Self.maxBytes) {
                trim()
            }
        } catch {
            logger.error("Could not write the activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func trim() {
        guard let data = try? Data(contentsOf: file) else { return }
        write(Self.newest(data, keeping: Self.trimmedBytes))
    }

    private func write(_ data: Data) {
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            logger.error("Could not rewrite the activity log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
    }

    private static func joined(_ lines: [Data]) -> Data {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    /// The last `limit` bytes, starting at a whole line.
    private static func newest(_ data: Data, keeping limit: Int) -> Data {
        guard data.count > limit else { return data }
        let tail = data.suffix(limit)
        let startsOnALine = data[data.index(tail.startIndex, offsetBy: -1)] == 0x0A
        guard !startsOnALine else { return Data(tail) }
        guard let newline = tail.firstIndex(of: 0x0A) else { return Data() }
        return Data(tail[tail.index(after: newline)...])
    }
}
