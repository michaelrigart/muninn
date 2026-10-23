import Foundation

public enum FileReplacementError: Error, Equatable {
    case asideCopyExists([String])
}

extension FileReplacementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .asideCopyExists(let paths):
            "\(paths.joined(separator: " and ")) already exist\(paths.count == 1 ? "s" : ""), left over from an earlier --force capture that was interrupted while starting. Rename \(paths.count == 1 ? "it" : "them") back (drop the .previous) to recover the capture, or delete \(paths.count == 1 ? "it" : "them"), then record again."
        }
    }
}

/// Files moved aside so new ones can take their place. The old files come back if the replacement fails and are deleted
/// once it has succeeded, so a failed attempt never costs the earlier files. Files that did not exist before are removed
/// again on a restore, so a failed start leaves no new file behind either.
public struct FileReplacement {
    public static let suffix = "previous"

    private let moved: [(original: URL, aside: URL)]
    private let created: [URL]

    /// Refuses when any `<name>.previous` copy already exists: it holds an earlier capture that a killed start never put back or
    /// discarded, and moving another file over it would destroy that capture.
    public static func requireNoAsideCopies(_ urls: [URL]) throws {
        let existing = urls.map { $0.appendingPathExtension(suffix) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard existing.isEmpty else { throw FileReplacementError.asideCopyExists(existing.map(\.path)) }
    }

    /// Moves each existing file in `urls` to `<name>.previous`; a file that doesn't exist yet is remembered as new.
    /// A failure puts back what was moved.
    public static func moveAside(_ urls: [URL]) throws -> FileReplacement {
        try requireNoAsideCopies(urls)
        var moved: [(original: URL, aside: URL)] = []
        var created: [URL] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else {
                created.append(url)
                continue
            }
            let aside = url.appendingPathExtension(suffix)
            do {
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                FileReplacement(moved: moved, created: []).restore()
                throw error
            }
            moved.append((url, aside))
        }
        return FileReplacement(moved: moved, created: created)
    }

    private init(moved: [(original: URL, aside: URL)], created: [URL]) {
        self.moved = moved
        self.created = created
    }

    public var isEmpty: Bool { moved.isEmpty }

    /// Puts the earlier files back, deleting whatever was written in their place, and deletes files that did not exist before.
    public func restore() {
        for url in created {
            try? FileManager.default.removeItem(at: url)
        }
        for item in moved {
            try? FileManager.default.removeItem(at: item.original)
            try? FileManager.default.moveItem(at: item.aside, to: item.original)
        }
    }

    /// Deletes the earlier files for good.
    public func discard() {
        for item in moved {
            try? FileManager.default.removeItem(at: item.aside)
        }
    }
}
