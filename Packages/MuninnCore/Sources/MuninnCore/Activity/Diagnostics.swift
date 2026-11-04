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
    /// The extensions of the files Muninn writes; any other can be part of a person's or client's name.
    static let keptExtensions: Set<String> = ["md", "json", "jsonl", "m4a", "wav", "caf", "txt"]

    /// A file path outside `directory` can hold a vault, client or meeting name; only a known extension stays.
    func keepingPaths(under directory: String) -> ProblemDetails {
        guard let path else { return self }
        let standard = (path as NSString).standardizingPath
        var root = (directory as NSString).standardizingPath
        while root.hasSuffix("/") { root.removeLast() }
        var copy = self
        if !root.isEmpty, standard == root || standard.hasPrefix(root + "/") {
            copy.path = standard
            return copy
        }
        let ext = (standard as NSString).pathExtension
        copy.path = Self.keptExtensions.contains(ext.lowercased()) ? "\(Self.outsidePath).\(ext)" : Self.outsidePath
        return copy
    }
}

private struct Masks {
    /// An address with or without a dot in its domain, so `ann@studio` counts too.
    private static let email = #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*"#
    /// The user and password in a URL such as `http://user:password@host`.
    private static let userInfo = #"(?<=://)[^\s/?#@]+(?=@)"#
    /// The shape `MeetingID.make` builds, for ids whose meeting is on no shown entry.
    private static let meetingID = #"\d{4}-\d{2}-\d{2}-\d{4}(?:-[a-z0-9]+)*"#
    private static let ipv4 = #"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?!\d)"#

    private struct Literal {
        var text: String
        var label: String
        var pattern: String
    }

    /// Each is matched on the same text, and overlapping matches are replaced as one run, so no mask can split another.
    private let masks: [(regex: NSRegularExpression, label: String)]

    init(settings: Settings, entries: [ActivityEntry], homeDirectory: String) {
        var found: [Literal] = []
        func word(_ text: String) -> String { #"(?<!\w)"# + NSRegularExpression.escapedPattern(for: text) + #"(?!\w)"# }
        func token(_ text: String) -> String { #"(?<![\w\-])"# + NSRegularExpression.escapedPattern(for: text) + #"(?![\w\-])"# }
        /// A host and any subdomains in front of it, in any case.
        func host(_ text: String) -> String { #"(?i:(?<![\w\-])(?:[A-Za-z0-9\-]+\.)*"# + NSRegularExpression.escapedPattern(for: text) + #"(?![\w\-]))"# }

        var home = homeDirectory
        while home.hasSuffix("/") { home.removeLast() }
        found.append(Literal(text: home, label: "~", pattern: NSRegularExpression.escapedPattern(for: home) + #"(?![\w\-])"#))

        var seen: [String] = []
        for meeting in entries.compactMap(\.meeting) {
            if !seen.contains(meeting.id.rawValue) { seen.append(meeting.id.rawValue) }
            let label = "meeting \(Self.letters(seen.firstIndex(of: meeting.id.rawValue)!))"
            found.append(Literal(text: meeting.id.rawValue, label: label, pattern: token(meeting.id.rawValue)))
            found.append(Literal(text: meeting.title, label: label, pattern: word(meeting.title)))
        }

        var names: [[String]] = settings.accounts.map { [$0.displayName, $0.id] }
        let known = Set(names.joined())
        for account in entries.compactMap({ $0.details?.account }) where !known.contains(account) && !names.contains([account]) {
            names.append([account])
        }
        for (index, strings) in names.enumerated() {
            for name in strings { found.append(Literal(text: name, label: "account \(index + 1)", pattern: word(name))) }
        }

        let entryHosts = entries.compactMap { $0.details?.request?.host }
        let settingsHosts = [settings.macbook.baseURL, settings.studio.baseURL].compactMap { URL(string: $0)?.host }
        for text in entryHosts + settingsHosts {
            found.append(Literal(text: text, label: "<host>", pattern: host(text)))
        }

        var distinct: [Literal] = []
        for literal in found where !literal.text.isEmpty && !distinct.contains(where: { $0.pattern == literal.pattern }) {
            distinct.append(literal)
        }
        let patterns = distinct.map { ($0.pattern, $0.label) }
            + [(Self.email, "<email>"), (Self.userInfo, "<email>"), (Self.ipv4, "<host>"), (Self.meetingID, "another meeting")]
        masks = patterns.compactMap { pattern, label in (try? NSRegularExpression(pattern: pattern)).map { ($0, label) } }
    }

    /// A run takes the label of its first match: the earliest to start, then the longest, then the earliest-listed mask.
    func apply(to text: String) -> String {
        let source = text as NSString
        var matches: [(range: NSRange, label: String, order: Int)] = []
        for (order, mask) in masks.enumerated() {
            matches += mask.regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { ($0.range, mask.label, order) }
        }
        matches.sort { ($0.range.location, -$0.range.length, $0.order) < ($1.range.location, -$1.range.length, $1.order) }

        var runs: [(range: NSRange, label: String)] = []
        for match in matches {
            if let last = runs.last, match.range.location < NSMaxRange(last.range) {
                runs[runs.count - 1].range = NSUnionRange(last.range, match.range)
            } else {
                runs.append((match.range, match.label))
            }
        }
        var masked = ""
        var cursor = 0
        for run in runs {
            masked += source.substring(with: NSRange(location: cursor, length: run.range.location - cursor)) + run.label
            cursor = NSMaxRange(run.range)
        }
        return Redaction.redact(masked + source.substring(from: cursor))
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
