import Foundation

public enum ExportOutcome: Equatable, Sendable {
    case written(URL)
    case alreadyExists(URL)
}

public enum ObsidianExportError: Error, Equatable, Sendable {
    case outsideVault
}

public struct ObsidianExporter: Sendable {
    public let vault: URL
    private static let exportLock = NSLock()

    public init(vault: URL) {
        if vault.path.hasPrefix("~") {
            self.vault = URL(fileURLWithPath: (vault.path as NSString).expandingTildeInPath)
        } else {
            self.vault = vault
        }
    }

    public static func attachmentName(forNote relativePath: String, source: URL) -> String {
        let stem = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        return "\(stem) - \(source.lastPathComponent)"
    }

    public func export(note: String, relativePath: String, attachments: [URL], overwrite: Bool) throws -> ExportOutcome {
        Self.exportLock.lock()
        defer { Self.exportLock.unlock() }
        let fileManager = FileManager.default
        let destination = vault.appendingPathComponent(relativePath)
        let vaultComponents = vault.standardized.pathComponents
        let destinationComponents = destination.standardized.pathComponents
        guard destinationComponents.count > vaultComponents.count, Array(destinationComponents.prefix(vaultComponents.count)) == vaultComponents else {
            throw ObsidianExportError.outsideVault
        }
        if !overwrite, fileManager.fileExists(atPath: destination.path) {
            return .alreadyExists(destination)
        }
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var temporaries: [(temporary: URL, target: URL)] = []
        var created: [URL] = []
        var noteCreated = false
        do {
            if !overwrite {
                let staged = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
                try Data(note.utf8).write(to: staged)
                do {
                    try fileManager.moveItem(at: staged, to: destination)
                    noteCreated = true
                } catch {
                    try? fileManager.removeItem(at: staged)
                    if fileManager.fileExists(atPath: destination.path) { return .alreadyExists(destination) }
                    throw error
                }
            }
            for attachment in attachments {
                let target = directory.appendingPathComponent(Self.attachmentName(forNote: relativePath, source: attachment))
                let temporary = directory.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
                try fileManager.copyItem(at: attachment, to: temporary)
                temporaries.append((temporary, target))
            }
            for (temporary, target) in temporaries {
                if fileManager.fileExists(atPath: target.path) {
                    _ = try fileManager.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try fileManager.moveItem(at: temporary, to: target)
                    created.append(target)
                }
            }
            if overwrite {
                try Data(note.utf8).write(to: destination, options: .atomic)
            }
        } catch {
            for (temporary, _) in temporaries { try? fileManager.removeItem(at: temporary) }
            for target in created { try? fileManager.removeItem(at: target) }
            if noteCreated { try? fileManager.removeItem(at: destination) }
            throw error
        }
        return .written(destination)
    }
}
