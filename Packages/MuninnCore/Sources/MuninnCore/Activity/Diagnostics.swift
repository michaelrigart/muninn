import Foundation

public struct PermissionReport: Equatable, Sendable {
    public var name: String
    public var state: String

    public init(name: String, state: String) {
        self.name = name
        self.state = state
    }
}

public struct DiagnosticsInput: Sendable {
    public var system: SystemInfo
    public var macClass: String
    public var settings: Settings
    public var permissions: [PermissionReport]
    public var entries: [ActivityEntry]
    public var homeDirectory: String
    /// Muninn's data folder; a file path keeps its structure only inside it.
    public var dataDirectory: String

    public init(system: SystemInfo, macClass: String, settings: Settings, permissions: [PermissionReport], entries: [ActivityEntry], homeDirectory: String, dataDirectory: String) {
        self.system = system
        self.macClass = macClass
        self.settings = settings
        self.permissions = permissions
        self.entries = entries
        self.homeDirectory = homeDirectory
        self.dataDirectory = dataDirectory
    }
}

/// The text behind "Copy diagnostics". It is written for a public issue, so the Engines and Activity sections
/// are masked: no meeting titles or ids, addresses, account names, hosts, home paths, keys or tokens.
public enum Diagnostics {
    public static let entryLimit = 200

    public static func text(_ input: DiagnosticsInput) -> String {
        let shown = newestFirst(input.entries).prefix(entryLimit)
        let masks = Masks(settings: input.settings, entries: Array(shown), homeDirectory: input.homeDirectory)

        var sections = [
            "Muninn diagnostics\nMuninn \(input.system.appVersion) · macOS \(input.system.osVersion) · \(input.macClass)",
            masks.apply(to: engines(input.settings)),
            (["Permissions"] + input.permissions.map { "\($0.name): \($0.state)" }).joined(separator: "\n"),
        ]
        sections.append(masks.apply(to: activity(Array(shown), dataDirectory: input.dataDirectory)))
        return sections.joined(separator: "\n\n")
    }

    private static func newestFirst(_ entries: [ActivityEntry]) -> [ActivityEntry] {
        entries.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time > b.element.time : a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Sections

    private static func engines(_ settings: Settings) -> String {
        [
            "Engines",
            "Default engine: \(settings.defaultEngine.displayName)",
            "\(EngineKind.macbook.displayName): \(endpoint(settings.macbook))",
            "\(EngineKind.studio.displayName): \(endpoint(settings.studio))",
            "Claude: model \(settings.claudeModel) · effort \(settings.claudeEffort)",
            "LLM cleanup: \(settings.useLLMCleanup ? "on" : "off")",
        ].joined(separator: "\n")
    }

    private static func endpoint(_ endpoint: EngineEndpoint) -> String {
        var line = "\(Provider.endpoint(endpoint.api).label) · model \(endpoint.model) · "
        guard let url = EndpointURL.parseBase(endpoint.baseURL), let scheme = url.scheme?.lowercased() else {
            return line + "no address"
        }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        line += "address \(scheme), port \(port)"
        return line
    }

    private static func activity(_ entries: [ActivityEntry], dataDirectory: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["Activity (last \(entries.count) entries, newest first)"]
        for entry in entries {
            var parts = [formatter.string(from: entry.time), entry.level.rawValue, entry.area.label]
            if let meeting = entry.meeting { parts.append(meeting.title.isEmpty ? meeting.id.rawValue : meeting.title) }
            parts.append(entry.message)
            lines.append(parts.joined(separator: " · "))
            for line in entry.details?.keepingPaths(under: dataDirectory).lines(includeHost: false) ?? [] {
                lines.append("    " + line)
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension ProblemDetails {
    static let outsidePath = "[path outside Muninn's folder]"

    /// A file path outside `directory` can hold a vault, client or meeting name; only its extension stays.
    func keepingPaths(under directory: String) -> ProblemDetails {
        guard let path else { return self }
        var root = directory
        while root.hasSuffix("/") { root.removeLast() }
        if !root.isEmpty, path == root || path.hasPrefix(root + "/") { return self }
        var copy = self
        let ext = (path as NSString).pathExtension
        let safe = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        copy.path = safe ? "\(Self.outsidePath).\(ext)" : Self.outsidePath
        return copy
    }
}

private struct Masks {
    private static let email = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    /// The shape `MeetingID.make` builds, for ids whose meeting is on no shown entry.
    private static let meetingID = #"\d{4}-\d{2}-\d{2}-\d{4}(?:-[a-z0-9]+)*"#
    private static let ipv4 = #"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?!\d)"#

    /// Longest first, so a title that holds an id's words never leaves part of itself behind.
    private let meetings: [(text: String, label: String)]
    private let accounts: [(text: String, label: String)]
    private let hosts: [String]
    private let home: String

    init(settings: Settings, entries: [ActivityEntry], homeDirectory: String) {
        var meetingLabels: [(text: String, label: String)] = []
        var seen: [String] = []
        for meeting in entries.compactMap(\.meeting) {
            if !seen.contains(meeting.id.rawValue) { seen.append(meeting.id.rawValue) }
            let label = "meeting \(Self.letters(seen.firstIndex(of: meeting.id.rawValue)!))"
            meetingLabels += [(meeting.id.rawValue, label), (meeting.title, label)]
        }
        meetings = Self.longestFirst(meetingLabels)

        var names: [[String]] = settings.accounts.map { [$0.displayName, $0.id] }
        let known = Set(names.joined())
        for account in entries.compactMap({ $0.details?.account }) where !known.contains(account) && !names.contains([account]) {
            names.append([account])
        }
        accounts = Self.longestFirst(names.enumerated().flatMap { index, strings in strings.map { ($0, "account \(index + 1)") } })

        let entryHosts = entries.compactMap { $0.details?.request?.host }
        let settingsHosts = [settings.macbook.baseURL, settings.studio.baseURL].compactMap { URL(string: $0)?.host }
        hosts = Array(Set((entryHosts + settingsHosts).filter { !$0.isEmpty })).sorted { $0.count > $1.count }

        var home = homeDirectory
        while home.hasSuffix("/") { home.removeLast() }
        self.home = home
    }

    func apply(to text: String) -> String {
        var result = text
        if !home.isEmpty {
            result = Self.replace(NSRegularExpression.escapedPattern(for: home) + #"(?![\w\-])"#, in: result, with: "~")
        }
        result = Self.replace(Self.email, in: result, with: "<email>")
        for host in hosts {
            result = Self.replace(#"(?<![\w\-])"# + NSRegularExpression.escapedPattern(for: host) + #"(?![\w\-])"#, in: result, with: "<host>", options: .caseInsensitive)
        }
        result = Self.replace(Self.ipv4, in: result, with: "<host>")
        for (string, label) in meetings {
            result = Self.replaceWord(string, in: result, with: label)
        }
        result = Self.replace(Self.meetingID, in: result, with: "another meeting")
        for (name, label) in accounts {
            result = Self.replaceWord(name, in: result, with: label)
        }
        return Redaction.redact(result)
    }

    private static func longestFirst(_ pairs: [(String, String)]) -> [(text: String, label: String)] {
        var distinct: [(text: String, label: String)] = []
        for (text, label) in pairs where !text.isEmpty && !distinct.contains(where: { $0.text == text }) {
            distinct.append((text, label))
        }
        return distinct.sorted { $0.text.count > $1.text.count }
    }

    private static func replaceWord(_ word: String, in text: String, with label: String) -> String {
        replace(#"(?<!\w)"# + NSRegularExpression.escapedPattern(for: word) + #"(?!\w)"#, in: text, with: label)
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String, options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// A, B, … Z, AA, AB, …
    private static func letters(_ index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            result = String(UnicodeScalar(UInt8(65 + n % 26))) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }
}
