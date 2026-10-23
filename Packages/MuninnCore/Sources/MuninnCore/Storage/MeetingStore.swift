import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "be.netronix.muninn", category: "storage")

/// Per-track transcription results kept when a job is held mid-transcription or before diarization. A track that has not been
/// transcribed yet is nil, so a resume transcribes only what is missing.
struct TrackResults: Codable, Equatable {
    var mic: [Segment]?
    var system: [Segment]?

    subscript(track: Track) -> [Segment]? {
        get { track == .mic ? mic : system }
        set {
            if track == .mic { mic = newValue } else { system = newValue }
        }
    }

    var isEmpty: Bool { mic == nil && system == nil }
}

public enum MeetingStoreError: Error, Equatable {
    case noPreviousSummary
}

extension MeetingStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPreviousSummary: "There is no previous recap to restore"
        }
    }
}

public final class MeetingStore: @unchecked Sendable {
    private let root: URL
    /// Called with each file the three-step restore is about to write or replace; lets a test make a step fail.
    var beforeRestoreWrite: ((URL) throws -> Void)?
    /// Swaps two files atomically and returns 0, or the errno. A test replaces it to simulate a volume without swap support.
    var swapFiles: (URL, URL) -> Int32 = { first, second in
        renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
    }
    /// Called each time a recovery failure is logged; lets a test count the log lines.
    var recoveryFailureLogged: ((MeetingID) -> Void)?
    private let failureLock = NSLock()
    private var loggedRecoveryFailures: Set<MeetingID> = []
    private static let writeLock = NSLock()
    private static let summaryLock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    public func directory(_ id: MeetingID) -> URL {
        root.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    public func audioURL(_ id: MeetingID, track: Track) -> URL {
        directory(id).appendingPathComponent("audio", isDirectory: true).appendingPathComponent("\(track.rawValue).caf")
    }

    public func transcriptMarkdownURL(_ id: MeetingID) -> URL {
        file(id, "transcript.md")
    }

    public func cleanTranscriptMarkdownURL(_ id: MeetingID) -> URL {
        file(id, "transcript.clean.md")
    }

    public func create(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(
            at: directory(meeting.id).appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try save(meeting)
    }

    public func exists(_ id: MeetingID) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory(id).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func delete(_ id: MeetingID) throws {
        let folder = directory(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func save(_ meeting: Meeting) throws {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        try write(meeting, to: file(meeting.id, "meeting.json"))
    }

    /// Loads, changes and saves a meeting under one lock, so concurrent updates to different fields all land.
    @discardableResult
    public func update(_ id: MeetingID, _ body: (inout Meeting) throws -> Void) throws -> Meeting {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        var meeting = try read(Meeting.self, from: file(id, "meeting.json"))
        try body(&meeting)
        try write(meeting, to: file(id, "meeting.json"))
        return meeting
    }

    public func load(_ id: MeetingID) throws -> Meeting {
        try read(Meeting.self, from: file(id, "meeting.json"))
    }

    public func list() throws -> [Meeting] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return folders
            .compactMap { try? load(MeetingID(rawValue: $0.lastPathComponent)) }
            .sorted { $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt > $1.startedAt }
    }

    public func existingIDs() -> Set<String> {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return Set(folders.map(\.lastPathComponent))
    }

    public func saveTranscript(_ transcript: Transcript, for id: MeetingID, speakerNames: [String: String], userName: String = SummaryRequestBuilder.defaultUserName) throws {
        let segments = transcript.segments.map {
            (id: $0.id, start: $0.start, speaker: SummaryRequestBuilder.displayName($0.speaker, speakerNames: speakerNames, userName: userName), text: $0.text)
        }
        try writeText(TranscriptMarkdown.render(segments: segments, title: title(id)), to: transcriptMarkdownURL(id))
        try write(transcript, to: file(id, "transcript.json"))
    }

    func saveTrackResults(_ results: TrackResults, for id: MeetingID) throws {
        try write(results, to: file(id, "tracks.json"))
    }

    func loadTrackResults(_ id: MeetingID) throws -> TrackResults? {
        try readIfPresent(TrackResults.self, from: file(id, "tracks.json"))
    }

    func deleteTrackResults(_ id: MeetingID) {
        try? FileManager.default.removeItem(at: file(id, "tracks.json"))
    }

    public func loadTranscript(_ id: MeetingID) throws -> Transcript? {
        try readIfPresent(Transcript.self, from: file(id, "transcript.json"))
    }

    public func saveClean(_ clean: CleanTranscript, transcript: Transcript, for id: MeetingID, speakerNames: [String: String], userName: String = SummaryRequestBuilder.defaultUserName) throws {
        let segments = transcript.segments.map {
            (id: $0.id, start: $0.start, speaker: SummaryRequestBuilder.displayName($0.speaker, speakerNames: speakerNames, userName: userName), text: clean.text(for: $0))
        }
        try writeText(TranscriptMarkdown.render(segments: segments, title: title(id)), to: cleanTranscriptMarkdownURL(id))
        try write(clean, to: file(id, "transcript.clean.json"))
    }

    public func loadClean(_ id: MeetingID) throws -> CleanTranscript? {
        try readIfPresent(CleanTranscript.self, from: file(id, "transcript.clean.json"))
    }

    public func saveSummary(_ summary: Summary, for id: MeetingID) throws {
        Self.summaryLock.lock()
        defer { Self.summaryLock.unlock() }
        try recoverSwapLocked(id)
        try writeSummary(summary, for: id)
    }

    public func loadSummary(_ id: MeetingID) throws -> Summary? {
        recoverSwapForRead(id)
        return try readIfPresent(Summary.self, from: file(id, "summary.json"))
    }

    /// Saves the user's own version of the summary and marks it edited.
    public func saveEditedSummary(_ summary: Summary, for id: MeetingID) throws {
        var edited = summary
        edited.edited = true
        try saveSummary(edited, for: id)
    }

    public func hasPreviousSummary(_ id: MeetingID) -> Bool {
        recoverSwapForRead(id)
        return FileManager.default.fileExists(atPath: file(id, "summary.previous.json").path)
    }

    public func loadPreviousSummary(_ id: MeetingID) throws -> Summary? {
        recoverSwapForRead(id)
        return try readIfPresent(Summary.self, from: file(id, "summary.previous.json"))
    }

    /// Copies the current summary to summary.previous.json, replacing any older one. Does nothing without a current summary.
    /// An edited previous summary is never replaced by an unedited current one, so the restore point stays the user's last edit.
    public func keepPreviousSummary(_ id: MeetingID) throws {
        Self.summaryLock.lock()
        defer { Self.summaryLock.unlock() }
        try recoverSwapLocked(id)
        try keepPrevious(id)
    }

    /// Keeps the current summary as the previous one and saves the new summary, as one step.
    public func replaceSummary(_ summary: Summary, for id: MeetingID) throws {
        Self.summaryLock.lock()
        defer { Self.summaryLock.unlock() }
        try recoverSwapLocked(id)
        try keepPrevious(id)
        try writeSummary(summary, for: id)
    }

    /// Swaps the previous summary back in; the summary it replaces becomes the previous one. Returns the restored summary.
    /// The two files are swapped atomically (`RENAME_SWAP`), so no crash can lose the user's edit however often it is restored.
    /// A volume without swap support gets a three-step swap through `summary.swap.json`, which the store finishes on load.
    @discardableResult
    public func restorePreviousSummary(_ id: MeetingID) throws -> Summary {
        Self.summaryLock.lock()
        defer { Self.summaryLock.unlock() }
        try recoverSwapLocked(id)
        let previousURL = file(id, "summary.previous.json")
        let currentURL = file(id, "summary.json")
        guard FileManager.default.fileExists(atPath: previousURL.path) else { throw MeetingStoreError.noPreviousSummary }
        let previousData = try Data(contentsOf: previousURL)
        let restored = try StorageJSON.decoder().decode(Summary.self, from: previousData)
        guard let currentData = try? Data(contentsOf: currentURL) else {
            try replace(currentURL, with: previousData)
            try writeText(Self.markdown(restored), to: file(id, "summary.md"))
            try FileManager.default.removeItem(at: previousURL)
            return restored
        }
        try swapSummaries(id, currentData: currentData, previousData: previousData)
        do {
            try writeText(Self.markdown(restored), to: file(id, "summary.md"))
        } catch {
            try? swapSummaries(id, currentData: previousData, previousData: currentData)
            throw error
        }
        return restored
    }

    /// Exchanges `summary.json` and `summary.previous.json`, which hold `currentData` and `previousData`.
    private func swapSummaries(_ id: MeetingID, currentData: Data, previousData: Data) throws {
        let currentURL = file(id, "summary.json")
        let previousURL = file(id, "summary.previous.json")
        let code = swapFiles(currentURL, previousURL)
        if code == 0 { return }
        guard code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL || code == ENOSYS else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(code))])
        }
        let swapURL = file(id, "summary.swap.json")
        do {
            try replace(swapURL, with: currentData)
            try replace(currentURL, with: previousData)
            try beforeRestoreWrite?(previousURL)
            guard rename(swapURL.path, previousURL.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: previousURL.path, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
            }
        } catch {
            if (try? replace(currentURL, with: currentData)) != nil {
                try? FileManager.default.removeItem(at: swapURL)
            }
            throw error
        }
    }

    /// A read goes on with the files as they are when a leftover swap file can't be finished; the swap file stays for a later try.
    private func recoverSwapForRead(_ id: MeetingID) {
        do {
            try recoverSwap(id)
        } catch {
            guard firstRecoveryFailure(id) else { return }
            logger.error("Finishing the leftover swap of \(id.rawValue, privacy: .public) failed; keeping it for later: \(String(describing: error), privacy: .public)")
            recoveryFailureLogged?(id)
        }
    }

    /// True the first time a meeting's recovery failure is seen in this session, so a view that reads on every render logs it once.
    private func firstRecoveryFailure(_ id: MeetingID) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return loggedRecoveryFailures.insert(id).inserted
    }

    private func recoverSwap(_ id: MeetingID) throws {
        guard FileManager.default.fileExists(atPath: file(id, "summary.swap.json").path) else { return }
        Self.summaryLock.lock()
        defer { Self.summaryLock.unlock() }
        try recoverSwapLocked(id)
    }

    /// Finishes or discards a three-step swap that a crash interrupted. Once the previous file was copied over the current one
    /// (both hold the restored version), the swap file still holds the version to keep as the previous one; before that, nothing
    /// changed and the swap file is just removed.
    private func recoverSwapLocked(_ id: MeetingID) throws {
        let swapURL = file(id, "summary.swap.json")
        guard FileManager.default.fileExists(atPath: swapURL.path) else { return }
        let currentURL = file(id, "summary.json")
        let previousURL = file(id, "summary.previous.json")
        let swapData = try Data(contentsOf: swapURL)
        let current = try readIfPresent(currentURL)
        let previous = try readIfPresent(previousURL)
        guard let current, current == previous, swapData != current else {
            try FileManager.default.removeItem(at: swapURL)
            return
        }
        guard rename(swapURL.path, previousURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: previousURL.path, NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
        if let restored = try? StorageJSON.decoder().decode(Summary.self, from: current) {
            try writeText(Self.markdown(restored), to: file(id, "summary.md"))
        }
    }

    /// The file's bytes, or nil when it is confirmed missing; any other read error throws.
    private func readIfPresent(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func replace(_ url: URL, with data: Data) throws {
        try beforeRestoreWrite?(url)
        try data.write(to: url, options: .atomic)
    }

    private func writeSummary(_ summary: Summary, for id: MeetingID) throws {
        try write(summary, to: file(id, "summary.json"))
        try writeText(Self.markdown(summary), to: file(id, "summary.md"))
    }

    private func keepPrevious(_ id: MeetingID) throws {
        let current = file(id, "summary.json")
        guard FileManager.default.fileExists(atPath: current.path) else { return }
        let currentData = try Data(contentsOf: current)
        if let previous = try? read(Summary.self, from: file(id, "summary.previous.json")), previous.edited,
           let summary = try? StorageJSON.decoder().decode(Summary.self, from: currentData), !summary.edited {
            return
        }
        try currentData.write(to: file(id, "summary.previous.json"), options: .atomic)
    }

    static func markdown(_ summary: Summary) -> String {
        let sections = summary.subjects.map { subject -> String in
            var lines = ["## \(subject.title)", ""]
            lines += subject.bullets.map { "- \($0.text)" }
            lines += subject.actions.map { action in
                var line = "- [ ] \(action.owner): \(action.text)"
                if let due = action.due { line += " (due \(due))" }
                return line
            }
            return lines.joined(separator: "\n")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private func file(_ id: MeetingID, _ name: String) -> URL {
        directory(id).appendingPathComponent(name)
    }

    private func title(_ id: MeetingID) -> String {
        (try? load(id))?.title ?? id.rawValue
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try StorageJSON.encoder().encode(value).write(to: url, options: .atomic)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try StorageJSON.decoder().decode(type, from: Data(contentsOf: url))
    }

    private func readIfPresent<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(type, from: url)
    }
}
