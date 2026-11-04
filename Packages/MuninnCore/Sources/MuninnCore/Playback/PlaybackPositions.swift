import Foundation
import os

private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "playback")

/// Where each meeting's recording was left, so playback resumes there.
public final class PlaybackPositions: @unchecked Sendable {
    static let finishedMargin: TimeInterval = 2

    private let file: URL
    private let lock = NSLock()
    private var positions: [String: TimeInterval]

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let stored = try? JSONDecoder().decode([String: TimeInterval].self, from: data) {
            positions = stored
        } else {
            positions = [:]
        }
    }

    public func position(for id: MeetingID) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return positions[id.rawValue]
    }

    public func set(_ time: TimeInterval, for id: MeetingID) {
        lock.lock()
        defer { lock.unlock() }
        positions[id.rawValue] = time
        save()
    }

    public func remove(_ id: MeetingID) {
        lock.lock()
        defer { lock.unlock() }
        positions[id.rawValue] = nil
        save()
    }

    /// Where to start: the stored time, or the beginning when there is none or the recording was nearly finished.
    public static func resumeTime(stored: TimeInterval?, duration: TimeInterval) -> TimeInterval {
        guard let stored, stored >= 0, stored < duration - finishedMargin else { return 0 }
        return stored
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try StorageJSON.encoder().encode(positions).write(to: file, options: .atomic)
        } catch {
            logger.error("Could not write the playback positions: \(error.localizedDescription, privacy: .public)")
        }
    }
}
