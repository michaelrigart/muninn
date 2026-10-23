import Foundation

public enum EngineKind: String, Codable, Hashable, Sendable, CaseIterable {
    case macbook, studio, claude

    /// The label the UI and notices show; the identifiers stay for stored data.
    public var displayName: String {
        switch self {
        case .macbook: "This Mac"
        case .studio: "Network Mac"
        case .claude: "Claude"
        }
    }
}

public struct Bullet: Codable, Hashable, Sendable {
    public var text: String
    public var sources: [Int]

    public init(text: String, sources: [Int]) {
        self.text = text
        self.sources = sources
    }
}

public struct ActionPoint: Codable, Hashable, Sendable {
    public var owner: String
    public var text: String
    public var due: String?
    public var sources: [Int]

    public init(owner: String, text: String, due: String?, sources: [Int]) {
        self.owner = owner
        self.text = text
        self.due = due
        self.sources = sources
    }
}

public struct Subject: Codable, Hashable, Sendable {
    public var title: String
    public var bullets: [Bullet]
    public var actions: [ActionPoint]

    public init(title: String, bullets: [Bullet], actions: [ActionPoint]) {
        self.title = title
        self.bullets = bullets
        self.actions = actions
    }
}

public struct Summary: Codable, Hashable, Sendable {
    public var language: String
    public var subjects: [Subject]
    public var engine: EngineKind
    public var generatedAt: Date
    /// True once the user has saved their own changes to this summary.
    public var edited: Bool

    public init(language: String, subjects: [Subject], engine: EngineKind, generatedAt: Date, edited: Bool = false) {
        self.language = language
        self.subjects = subjects
        self.engine = engine
        self.generatedAt = generatedAt
        self.edited = edited
    }

    private enum CodingKeys: String, CodingKey {
        case language, subjects, engine, generatedAt, edited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decode(String.self, forKey: .language)
        subjects = try c.decode([Subject].self, forKey: .subjects)
        engine = try c.decode(EngineKind.self, forKey: .engine)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        edited = c.lossy(Bool.self, .edited, default: false)
    }
}
