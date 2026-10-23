import Foundation

public struct SummaryParseResult {
    public var summary: Summary
    public var uncoveredFlagSegments: [Int]
    /// Short descriptions of bullets and actions that cite no existing transcript segment.
    public var unsourcedItems: [String]

    public init(summary: Summary, uncoveredFlagSegments: [Int], unsourcedItems: [String] = []) {
        self.summary = summary
        self.uncoveredFlagSegments = uncoveredFlagSegments
        self.unsourcedItems = unsourcedItems
    }
}

public enum SummaryParseError: Error, Equatable {
    case notJSON(String)
    case schemaMismatch(String)
}

public enum SummaryParser {
    private struct Payload: Decodable {
        struct Item: Decodable {
            var text: String
            var sources: [Int]
        }
        struct Action: Decodable {
            var owner: String
            var text: String
            var due: String?
            var sources: [Int]
        }
        struct Subject: Decodable {
            var title: String
            var bullets: [Item]
            var actions: [Action]
        }
        var language: String
        var subjects: [Subject]
    }

    public static func parse(_ text: String, transcript: Transcript, flags: [Flag], engine: EngineKind, now: Date) throws -> SummaryParseResult {
        guard let object = LLMTransport.outermostJSONObject(in: text) else {
            throw SummaryParseError.notJSON("No JSON object in the reply")
        }
        let data = Data(object.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw SummaryParseError.notJSON("The reply is not valid JSON")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw SummaryParseError.schemaMismatch(String(describing: error))
        }

        let known = Set(transcript.segments.map(\.id))
        func valid(_ sources: [Int]) -> [Int] { sources.filter(known.contains) }

        let subjects = payload.subjects.map { subject in
            Subject(
                title: subject.title,
                bullets: subject.bullets.map { Bullet(text: $0.text, sources: valid($0.sources)) },
                actions: subject.actions.map {
                    ActionPoint(owner: $0.owner, text: $0.text, due: $0.due.flatMap(validDate), sources: valid($0.sources))
                }
            )
        }
        let cited = Set(subjects.flatMap { $0.bullets.flatMap(\.sources) + $0.actions.flatMap(\.sources) })
        let uncovered = FlagCoverage.flaggedSegmentIDs(flags, in: transcript).filter { !cited.contains($0) }
        let summary = Summary(language: normalisedLanguage(payload.language), subjects: subjects, engine: engine, generatedAt: now)
        let unsourced = subjects.flatMap { subject in
            subject.bullets.filter { $0.sources.isEmpty }.map { describe("bullet", $0.text) }
                + subject.actions.filter { $0.sources.isEmpty }.map { describe("action", $0.text) }
        }
        return SummaryParseResult(summary: summary, uncoveredFlagSegments: uncovered, unsourcedItems: unsourced)
    }

    private static func describe(_ kind: String, _ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortened = trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
        return "\(kind) \"\(shortened)\""
    }

    private static func normalisedLanguage(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "dutch", "nederlands", "nl-be": return "nl"
        case "french", "français", "francais", "fr-be": return "fr"
        case "english", "en-gb", "en-us": return "en"
        default: return String(name.prefix(2))
        }
    }

    private static func validDate(_ value: String) -> String? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return value
    }
}
