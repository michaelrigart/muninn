import Foundation

public enum EndpointAPI: String, Codable, Sendable {
    case ollama, openAICompatible
}

public struct EngineEndpoint: Codable, Equatable, Sendable {
    public var api: EndpointAPI
    public var baseURL: String
    public var model: String
    public var keepAlive: String

    public init(api: EndpointAPI, baseURL: String, model: String, keepAlive: String) {
        self.api = api
        self.baseURL = baseURL
        self.model = model
        self.keepAlive = keepAlive
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: EngineEndpoint(api: .ollama, baseURL: "", model: "", keepAlive: "0"))
    }

    init(from decoder: Decoder, defaults: EngineEndpoint) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        api = c.lossy(EndpointAPI.self, .api, default: defaults.api)
        baseURL = c.lossy(String.self, .baseURL, default: defaults.baseURL)
        model = c.lossy(String.self, .model, default: defaults.model)
        keepAlive = c.lossy(String.self, .keepAlive, default: defaults.keepAlive)
    }
}

public struct AccountSettings: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var vaultArea: String
    public var tenant: String
    public var clientID: String
    public var selfAddresses: [String]

    public init(id: String, displayName: String, vaultArea: String, tenant: String, clientID: String, selfAddresses: [String]) {
        self.id = id
        self.displayName = displayName
        self.vaultArea = vaultArea
        self.tenant = tenant
        self.clientID = clientID
        self.selfAddresses = selfAddresses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let base = Settings.defaults.accounts.first { $0.id == id }
        self.id = id
        displayName = c.lossy(String.self, .displayName, default: base?.displayName ?? id)
        vaultArea = c.lossy(String.self, .vaultArea, default: base?.vaultArea ?? displayName)
        tenant = c.lossy(String.self, .tenant, default: base?.tenant ?? "organizations")
        clientID = c.lossy(String.self, .clientID, default: base?.clientID ?? "")
        selfAddresses = c.lossy([String].self, .selfAddresses, default: base?.selfAddresses ?? [])
    }
}

public struct Hotkey: Codable, Equatable, Sendable {
    public var key: String
    public var modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: Settings.defaults.flagHotkey)
    }

    init(from decoder: Decoder, defaults: Hotkey) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lossy(String.self, .key, default: defaults.key)
        modifiers = c.lossy([String].self, .modifiers, default: defaults.modifiers)
    }
}

public struct RecordingSettings: Codable, Equatable, Sendable {
    /// Echo cancellation on the microphone, for calls on the laptop speakers.
    public var voiceProcessing: Bool

    public init(voiceProcessing: Bool = false) {
        self.voiceProcessing = voiceProcessing
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: RecordingSettings())
    }

    init(from decoder: Decoder, defaults: RecordingSettings) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceProcessing = c.lossy(Bool.self, .voiceProcessing, default: defaults.voiceProcessing)
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var defaultEngine: EngineKind
    public var macbook: EngineEndpoint
    public var studio: EngineEndpoint
    public var claudeModel: String
    public var claudeEffort: String
    public var useLLMCleanup: Bool
    public var accounts: [AccountSettings]
    /// IDs of removed accounts; never given to a new account, so cached or stored references to them stay unambiguous.
    public var retiredAccountIDs: [String]
    public var vaultPath: String
    public var notePattern: String
    public var inboxFolder: String
    public var clientDomains: [String: String]
    public var autoFileToObsidian: Bool
    public var vaultIncludesTranscript: Bool
    public var vaultIncludesAudio: Bool
    public var dictionary: [String]
    public var watchList: [String]
    public var flagHotkey: Hotkey
    public var showPill: Bool
    public var liveModel: String
    public var finalModel: String
    public var userName: String
    public var recording: RecordingSettings

    public init(
        defaultEngine: EngineKind,
        macbook: EngineEndpoint,
        studio: EngineEndpoint,
        claudeModel: String,
        claudeEffort: String,
        useLLMCleanup: Bool,
        accounts: [AccountSettings],
        vaultPath: String,
        notePattern: String,
        inboxFolder: String,
        clientDomains: [String: String],
        autoFileToObsidian: Bool,
        vaultIncludesTranscript: Bool,
        vaultIncludesAudio: Bool,
        dictionary: [String],
        watchList: [String],
        flagHotkey: Hotkey,
        showPill: Bool,
        liveModel: String,
        finalModel: String,
        userName: String,
        recording: RecordingSettings = RecordingSettings(),
        retiredAccountIDs: [String] = []
    ) {
        self.defaultEngine = defaultEngine
        self.macbook = macbook
        self.studio = studio
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
        self.useLLMCleanup = useLLMCleanup
        self.accounts = accounts
        self.retiredAccountIDs = retiredAccountIDs
        self.vaultPath = vaultPath
        self.notePattern = notePattern
        self.inboxFolder = inboxFolder
        self.clientDomains = clientDomains
        self.autoFileToObsidian = autoFileToObsidian
        self.vaultIncludesTranscript = vaultIncludesTranscript
        self.vaultIncludesAudio = vaultIncludesAudio
        self.dictionary = dictionary
        self.watchList = watchList
        self.flagHotkey = flagHotkey
        self.showPill = showPill
        self.liveModel = liveModel
        self.finalModel = finalModel
        self.userName = userName
        self.recording = recording
    }

    /// False until the user chooses a vault folder; nothing is exported or auto-filed before that.
    public var hasVault: Bool {
        !vaultPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let defaults = Settings(
        defaultEngine: .macbook,
        macbook: EngineEndpoint(api: .ollama, baseURL: "http://127.0.0.1:11434", model: "qwen3:8b", keepAlive: "0"),
        studio: EngineEndpoint(api: .ollama, baseURL: "", model: "gpt-oss:20b", keepAlive: "10m"),
        claudeModel: "claude-opus-5-5",
        claudeEffort: "medium",
        useLLMCleanup: false,
        accounts: [
            AccountSettings(id: "work", displayName: "Work", vaultArea: "Work", tenant: "organizations", clientID: "", selfAddresses: []),
        ],
        vaultPath: "",
        notePattern: "Meetings/{client}/{date} {title}.md",
        inboxFolder: "Inbox",
        clientDomains: [:],
        autoFileToObsidian: false,
        vaultIncludesTranscript: false,
        vaultIncludesAudio: false,
        dictionary: [],
        watchList: [
            "com.microsoft.teams2", "com.microsoft.teams", "us.zoom.xos", "com.cisco.webexmeetingsapp",
            "com.tinyspeck.slackmacgap", "com.apple.FaceTime", "app.zen-browser.zen", "com.google.Chrome",
            "com.apple.Safari", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser",
        ],
        flagHotkey: Hotkey(key: "F", modifiers: ["control", "option", "command"]),
        showPill: true,
        liveModel: "parakeet-v3",
        finalModel: "parakeet-v3",
        userName: ""
    )

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.defaults
        defaultEngine = c.lossy(EngineKind.self, .defaultEngine, default: d.defaultEngine)
        macbook = Self.merged(c, .macbook, default: d.macbook) { try EngineEndpoint(from: $0, defaults: $1) }
        studio = Self.merged(c, .studio, default: d.studio) { try EngineEndpoint(from: $0, defaults: $1) }
        claudeModel = c.lossy(String.self, .claudeModel, default: d.claudeModel)
        claudeEffort = c.lossy(String.self, .claudeEffort, default: d.claudeEffort)
        useLLMCleanup = c.lossy(Bool.self, .useLLMCleanup, default: d.useLLMCleanup)
        accounts = (try? c.decodeIfPresent([LossyAccount].self, forKey: .accounts))?.compactMap(\.value) ?? d.accounts
        retiredAccountIDs = c.lossy([String].self, .retiredAccountIDs, default: d.retiredAccountIDs)
        vaultPath = c.lossy(String.self, .vaultPath, default: d.vaultPath)
        notePattern = c.lossy(String.self, .notePattern, default: d.notePattern)
        inboxFolder = c.lossy(String.self, .inboxFolder, default: d.inboxFolder)
        clientDomains = c.lossy([String: String].self, .clientDomains, default: d.clientDomains)
        autoFileToObsidian = c.lossy(Bool.self, .autoFileToObsidian, default: d.autoFileToObsidian)
        vaultIncludesTranscript = c.lossy(Bool.self, .vaultIncludesTranscript, default: d.vaultIncludesTranscript)
        vaultIncludesAudio = c.lossy(Bool.self, .vaultIncludesAudio, default: d.vaultIncludesAudio)
        dictionary = c.lossy([String].self, .dictionary, default: d.dictionary)
        watchList = c.lossy([String].self, .watchList, default: d.watchList)
        flagHotkey = Self.merged(c, .flagHotkey, default: d.flagHotkey) { try Hotkey(from: $0, defaults: $1) }
        showPill = c.lossy(Bool.self, .showPill, default: d.showPill)
        liveModel = c.lossy(String.self, .liveModel, default: d.liveModel)
        finalModel = c.lossy(String.self, .finalModel, default: d.finalModel)
        userName = c.lossy(String.self, .userName, default: d.userName)
        recording = Self.merged(c, .recording, default: d.recording) { try RecordingSettings(from: $0, defaults: $1) }
    }

    private static func merged<Key: CodingKey, T>(_ c: KeyedDecodingContainer<Key>, _ key: Key, default fallback: T, _ make: (Decoder, T) throws -> T) -> T {
        guard c.contains(key), (try? c.decodeNil(forKey: key)) == false,
              let decoder = try? c.superDecoder(forKey: key),
              let value = try? make(decoder, fallback) else { return fallback }
        return value
    }

    private struct LossyAccount: Decodable {
        let value: AccountSettings?

        init(from decoder: Decoder) throws {
            value = try? AccountSettings(from: decoder)
        }
    }
}

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key, default fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }
}
