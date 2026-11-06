import Foundation
import Testing
@testable import MuninnCore

struct MeetingFolderWatcherTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("muninn-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeMeeting(_ name: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        return folder
    }

    private func watch(_ root: URL, _ counter: Counter, debounce: TimeInterval = 0.1) -> MeetingFolderWatcher {
        MeetingFolderWatcher(
            directory: root,
            queue: DispatchQueue(label: "watcher-tests"),
            debounce: debounce,
            onChange: { counter.increment() }
        )
    }

    private func wait(upTo seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func aFolderAppearingFiresOnce() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let watcher = watch(root, counter, debounce: 0.5)
        defer { watcher.stop() }

        _ = try makeMeeting("20261106-0900-standup", in: root)
        _ = try makeMeeting("20261106-1000-review", in: root)
        try await wait(upTo: 3) { counter.count > 0 }
        try await Task.sleep(for: .milliseconds(1000))
        #expect(counter.count == 1)
    }

    @Test func aFolderGoingAwayFires() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let folder = try makeMeeting("20261106-0900-standup", in: root)
        let counter = Counter()
        let watcher = watch(root, counter)
        defer { watcher.stop() }

        try FileManager.default.moveItem(at: folder, to: elsewhere.appendingPathComponent(folder.lastPathComponent))
        try await wait(upTo: 3) { counter.count > 0 }
        #expect(counter.count == 1)
    }

    @Test func changesInsideAMeetingFolderDoNotFire() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeMeeting("20261106-0900-standup", in: root)
        let counter = Counter()
        let watcher = watch(root, counter)
        defer { watcher.stop() }

        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try Data("{\"a\":1}".utf8).write(to: folder.appendingPathComponent("meeting.json"))
        try await wait(upTo: 0.5) { counter.count > 0 }
        #expect(counter.count == 0)
    }

    @Test func stopEndsWatching() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = Counter()
        let watcher = watch(root, counter)

        watcher.stop()
        _ = try makeMeeting("20261106-0900-standup", in: root)
        try await wait(upTo: 0.5) { counter.count > 0 }
        #expect(counter.count == 0)
    }

    @Test func deletingOrRenamingTheFolderStopsWatching() async throws {
        let root = try temporaryRoot()
        let renamed = root.deletingLastPathComponent()
            .appendingPathComponent("muninn-watcher-renamed-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: renamed)
        }
        let counter = Counter()
        let watcher = watch(root, counter)
        defer { watcher.stop() }

        try FileManager.default.moveItem(at: root, to: renamed)
        try await wait(upTo: 0.5) { counter.count > 0 }
        _ = try makeMeeting("20261106-0900-standup", in: renamed)
        try await wait(upTo: 0.5) { counter.count > 0 }
        #expect(counter.count == 0)
    }
}
