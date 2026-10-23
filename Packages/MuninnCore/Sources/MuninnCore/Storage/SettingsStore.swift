import Foundation

public final class SettingsStore: @unchecked Sendable {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    public func save(_ settings: Settings) throws {
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path), !isReadable() {
            try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("\(file.lastPathComponent).unreadable-\(Self.stamp())"))
        }
        try StorageJSON.encoder().encode(settings).write(to: file, options: .atomic)
    }

    private func isReadable() -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        return (try? JSONDecoder().decode(Settings.self, from: data)) != nil
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
