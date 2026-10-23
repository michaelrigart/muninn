import Foundation

public struct MuninnPaths: Sendable {
    public var data: URL
    public var config: URL
    public var cache: URL

    public init(home: URL, environment: [String: String]) {
        func base(_ key: String, fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/") {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        data = base("XDG_DATA_HOME", fallback: ".local/share").appendingPathComponent("muninn", isDirectory: true)
        config = base("XDG_CONFIG_HOME", fallback: ".config").appendingPathComponent("muninn", isDirectory: true)
        cache = base("XDG_CACHE_HOME", fallback: ".cache").appendingPathComponent("muninn", isDirectory: true)
    }

    public var meetings: URL {
        data.appendingPathComponent("meetings", isDirectory: true)
    }

    public var settingsFile: URL {
        config.appendingPathComponent("settings.json")
    }
}
