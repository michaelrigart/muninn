import Foundation
import Testing
@testable import MuninnCore

@Suite struct FileSafetyTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func aHeldLockRefusesASecondHolderUntilItIsReleased() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".capture.lock")
        let first = try #require(try FileLock.tryAcquire(url))
        #expect(try FileLock.tryAcquire(url) == nil)
        first.release()
        let second = try FileLock.tryAcquire(url)
        #expect(second != nil)
    }

    @Test func aLockIsReleasedWhenTheHolderGoesAway() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".capture.lock")
        var holder: FileLock? = try FileLock.tryAcquire(url)
        #expect(holder != nil)
        #expect(try FileLock.tryAcquire(url) == nil)
        holder = nil
        #expect(try FileLock.tryAcquire(url) != nil)
    }

    @Test func aLockFailureOtherThanWouldBlockThrowsInsteadOfReadingAsHeld() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".capture.lock")
        for code in [ENOTSUP, EOPNOTSUPP, ENOLCK] {
            #expect(throws: FileLockError(path: url.path, code: code)) {
                try FileLock.tryAcquire(url) { _, _ in
                    errno = code
                    return -1
                }
            }
        }
        #expect(try FileLock.tryAcquire(url) != nil)
    }

    @Test func wouldBlockStillMeansHeld() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(".capture.lock")
        let result = try FileLock.tryAcquire(url) { _, _ in
            errno = EWOULDBLOCK
            return -1
        }
        #expect(result == nil)
    }

    @Test func aLockFailureNamesThePathAndTheReason() {
        let message = FileLockError(path: "/data/muninn.lock", code: ENOTSUP).errorDescription ?? ""
        #expect(message.contains("/data/muninn.lock"))
        #expect(message.contains("errno"))
    }

    @Test func lockingAFileInAMissingFolderThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)/x.lock")
        #expect(throws: (any Error).self) { try FileLock.tryAcquire(url) }
    }

    @Test func movedAsideFilesComeBackWhenTheReplacementFails() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Data("old mic".utf8).write(to: mic)
        try Data("old system".utf8).write(to: system)

        let replacement = try FileReplacement.moveAside([mic, system])
        #expect(!FileManager.default.fileExists(atPath: mic.path))
        #expect(text(mic.appendingPathExtension("previous")) == "old mic")

        try Data("partial".utf8).write(to: mic)
        replacement.restore()
        #expect(text(mic) == "old mic")
        #expect(text(system) == "old system")
        #expect(!FileManager.default.fileExists(atPath: mic.appendingPathExtension("previous").path))
    }

    @Test func movedAsideFilesAreDeletedOnceTheReplacementSucceeded() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        try Data("old".utf8).write(to: mic)

        let replacement = try FileReplacement.moveAside([mic, dir.appendingPathComponent("system.caf")])
        try Data("new".utf8).write(to: mic)
        replacement.discard()
        #expect(text(mic) == "new")
        #expect(!FileManager.default.fileExists(atPath: mic.appendingPathExtension("previous").path))
    }

    @Test func nothingIsMovedWhenNoFileExists() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let replacement = try FileReplacement.moveAside([dir.appendingPathComponent("mic.caf")])
        #expect(replacement.isEmpty)
        replacement.restore()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func anExistingAsideCopyIsNeverReplaced() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        try Data("earlier capture".utf8).write(to: mic.appendingPathExtension("previous"))
        try Data("partial".utf8).write(to: mic)
        #expect(throws: FileReplacementError.self) { try FileReplacement.moveAside([mic]) }
        #expect(throws: FileReplacementError.self) { try FileReplacement.requireNoAsideCopies([mic, dir.appendingPathComponent("system.caf")]) }
        #expect(text(mic.appendingPathExtension("previous")) == "earlier capture")
        #expect(text(mic) == "partial")
    }

    @Test func theRefusalNamesTheLeftoverFiles() {
        let message = FileReplacementError.asideCopyExists(["/out/mic.caf.previous"]).errorDescription ?? ""
        #expect(message.contains("/out/mic.caf.previous"))
        #expect(message.contains("delete"))
    }

    @Test func aRestoreAlsoDeletesFilesThatDidNotExistBefore() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try Data("old mic".utf8).write(to: mic)

        let replacement = try FileReplacement.moveAside([mic, system])
        try Data("partial mic".utf8).write(to: mic)
        try Data("partial system".utf8).write(to: system)
        replacement.restore()

        #expect(text(mic) == "old mic")
        #expect(!FileManager.default.fileExists(atPath: system.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["mic.caf"])
    }

    @Test func aRestoreWithNoEarlierFilesLeavesNoNewOnes() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let replacement = try FileReplacement.moveAside([mic])
        try Data("partial".utf8).write(to: mic)
        replacement.restore()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func discardKeepsTheNewFiles() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let replacement = try FileReplacement.moveAside([mic])
        try Data("new".utf8).write(to: mic)
        replacement.discard()
        #expect(text(mic) == "new")
    }
}
