import Foundation

public enum ActivityLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case info, warning, problem
}

public enum ActivityArea: String, Codable, Hashable, Sendable, CaseIterable {
    case recording, transcription, recap, outlook, obsidian, accounts, engines, app

    public var label: String {
        switch self {
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .recap: "Recap"
        case .outlook: "Outlook"
        case .obsidian: "Obsidian"
        case .accounts: "Accounts"
        case .engines: "Engines"
        case .app: "App"
        }
    }
}

public enum ProblemAction: String, Codable, Hashable, Sendable, CaseIterable {
    case tryAgain, writeWithClaude, writeOnThisMac, writeWithAnotherEngine, engineSettings, changeKey, signInAgain, recordingSettings

    public var label: String {
        switch self {
        case .tryAgain: "Try again"
        case .writeWithClaude: "Write with Claude"
        case .writeOnThisMac: "Write on This Mac"
        case .writeWithAnotherEngine: "Write with another engine"
        case .engineSettings: "Engine settings"
        case .changeKey: "Change key…"
        case .signInAgain: "Sign in again"
        case .recordingSettings: "Recording settings"
        }
    }
}

public enum ProviderErrorCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case modelNotFound, unauthorized, rateLimited, overloaded, contextTooLong, badRequest, serverError, expiredSignIn, refused, incomplete, unknown
}

public enum Provider: String, Codable, Hashable, Sendable {
    case ollama, openAICompatible, anthropic, microsoftGraph, microsoftSignIn

    public var label: String {
        switch self {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible server"
        case .anthropic: "Anthropic"
        case .microsoftGraph: "Microsoft Graph"
        case .microsoftSignIn: "Microsoft sign-in"
        }
    }

    public static func endpoint(_ api: EndpointAPI) -> Provider {
        switch api {
        case .ollama: .ollama
        case .openAICompatible: .openAICompatible
        }
    }
}

public struct RequestFacts: Codable, Hashable, Sendable {
    public var method: String
    public var path: String
    public var host: String?

    public init(method: String, path: String, host: String? = nil) {
        self.method = method
        self.path = path
        self.host = host
    }

    /// Keeps only the path and host, so no query, user info or long identifier leaves the URL.
    public init(method: String, url: URL) {
        let segments = url.path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            segment.count > 32 ? "{id}" : String(segment)
        }
        self.init(method: method, path: segments.joined(separator: "/"), host: url.host)
    }

    fileprivate func redacted() -> RequestFacts {
        RequestFacts(method: Redaction.redact(method), path: Redaction.redact(path), host: host.map(Redaction.redact))
    }
}

public enum ProblemStage: String, Codable, Hashable, Sendable, CaseIterable {
    case recording, transcribing, identifyingSpeakers, cleaningUp, writingRecap, preparingSpeechModel, liveTranscript
    case creatingDraft, searchingPeople, filingNote, changingEvent, readingCalendar, signingIn
    case savingSettings, savingEdits, loadingMeetings, deletingMeeting, other

    public var phrase: String {
        switch self {
        case .recording: "recording"
        case .transcribing: "transcribing"
        case .identifyingSpeakers: "telling the speakers apart"
        case .cleaningUp: "cleaning up the transcript"
        case .writingRecap: "writing the recap"
        case .preparingSpeechModel: "getting the speech model ready"
        case .liveTranscript: "transcribing live"
        case .creatingDraft: "creating the Outlook draft"
        case .searchingPeople: "searching for people"
        case .filingNote: "filing the note in Obsidian"
        case .changingEvent: "changing the event"
        case .readingCalendar: "reading the calendar"
        case .signingIn: "signing in"
        case .savingSettings: "saving the settings"
        case .savingEdits: "saving your changes"
        case .loadingMeetings: "loading the meetings"
        case .deletingMeeting: "deleting the meeting"
        case .other: "working"
        }
    }

    public var area: ActivityArea {
        switch self {
        case .recording: .recording
        case .transcribing, .identifyingSpeakers, .cleaningUp, .preparingSpeechModel, .liveTranscript: .transcription
        case .writingRecap, .savingEdits: .recap
        case .creatingDraft, .searchingPeople: .outlook
        case .filingNote: .obsidian
        case .changingEvent, .readingCalendar, .signingIn: .accounts
        case .savingSettings, .loadingMeetings, .deletingMeeting, .other: .app
        }
    }
}

public struct ProblemDetails: Codable, Hashable, Sendable {
    public var errorDomain: String?
    public var errorCode: Int?
    public var request: RequestFacts?
    public var httpStatus: Int?
    public var engine: EngineKind?
    public var provider: Provider?
    public var model: String?
    public var category: ProviderErrorCategory?
    public var graphCode: String?
    public var path: String?
    /// The display name of the Microsoft account involved, from Muninn's settings.
    public var account: String?
    public var stage: ProblemStage?
    public var elapsedSeconds: Double?
    public var appVersion: String?
    public var osVersion: String?
    public var fromEarlierVersion: Bool

    public init(
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        request: RequestFacts? = nil,
        httpStatus: Int? = nil,
        engine: EngineKind? = nil,
        provider: Provider? = nil,
        model: String? = nil,
        category: ProviderErrorCategory? = nil,
        graphCode: String? = nil,
        path: String? = nil,
        account: String? = nil,
        stage: ProblemStage? = nil,
        elapsedSeconds: Double? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil,
        fromEarlierVersion: Bool = false
    ) {
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.request = request
        self.httpStatus = httpStatus
        self.engine = engine
        self.provider = provider
        self.model = model
        self.category = category
        self.graphCode = graphCode
        self.path = path
        self.account = account
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.fromEarlierVersion = fromEarlierVersion
    }

    public func redacted() -> ProblemDetails {
        var copy = self
        copy.errorDomain = errorDomain.map(Redaction.redact)
        copy.request = request?.redacted()
        copy.model = model.map(Redaction.redact)
        copy.graphCode = graphCode.map(Redaction.redact)
        copy.path = path.map(Redaction.redact)
        copy.account = account.map(Redaction.redact)
        copy.appVersion = appVersion.map(Redaction.redact)
        copy.osVersion = osVersion.map(Redaction.redact)
        return copy
    }

    public func lines(includeHost: Bool) -> [String] {
        let safe = redacted()
        var lines: [String] = []
        if let domain = safe.errorDomain, let code = safe.errorCode {
            lines.append("Error: \(domain) \(code)")
        } else if let domain = safe.errorDomain {
            lines.append("Error: \(domain)")
        } else if let code = safe.errorCode {
            lines.append("Error: \(code)")
        }
        if let request = safe.request {
            var line = "Request: \(request.method) \(request.path)"
            if includeHost, let host = request.host { line += " on \(host)" }
            lines.append(line)
        }
        if let status = safe.httpStatus { lines.append("HTTP status: \(status)") }
        if let engine = safe.engine { lines.append("Engine: \(engine.displayName)") }
        if let provider = safe.provider { lines.append("Provider: \(provider.label)") }
        if let model = safe.model { lines.append("Model: \(model)") }
        if let category = safe.category { lines.append("Category: \(category.rawValue)") }
        if let graphCode = safe.graphCode { lines.append("Microsoft Graph code: \(graphCode)") }
        if let path = safe.path { lines.append("File: \(path)") }
        if let account = safe.account { lines.append("Account: \(account)") }
        if let stage = safe.stage { lines.append("Stage: \(stage.phrase)") }
        if let elapsed = safe.elapsedSeconds { lines.append("Elapsed: \(String(format: "%.1f", elapsed)) s") }
        if safe.fromEarlierVersion { lines.append("From an earlier version of Muninn") }
        if let appVersion = safe.appVersion, let osVersion = safe.osVersion {
            lines.append("Muninn \(appVersion) · macOS \(osVersion)")
        }
        return lines
    }

    public func text(includeHost: Bool) -> String {
        lines(includeHost: includeHost).joined(separator: "\n")
    }
}

public struct Problem: Codable, Hashable, Sendable {
    public var severity: ActivityLevel
    public var title: String
    public var explanation: String
    public var actions: [ProblemAction]
    public var details: ProblemDetails

    public init(severity: ActivityLevel, title: String, explanation: String, actions: [ProblemAction], details: ProblemDetails = ProblemDetails()) {
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.actions = actions
        self.details = details
    }

    /// A copy with other actions, for a channel where the catalogue's actions don't apply.
    public func with(actions: [ProblemAction]) -> Problem {
        var copy = self
        copy.actions = actions
        return copy
    }
}

public struct SystemInfo: Equatable, Sendable {
    public var appVersion: String
    public var osVersion: String

    public init(appVersion: String, osVersion: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
    }

    public static var current: SystemInfo {
        let info = Bundle.main.infoDictionary
        let appVersion: String
        if let short = info?["CFBundleShortVersionString"] as? String, let build = info?["CFBundleVersion"] as? String {
            appVersion = "\(short) (\(build))"
        } else {
            appVersion = MuninnVersion.current
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return SystemInfo(appVersion: appVersion, osVersion: osVersion)
    }
}

public struct ProblemContext: Sendable {
    public var stage: ProblemStage
    public var engine: EngineKind?
    public var endpointAPI: EndpointAPI?
    public var model: String?
    public var claudeKeyPresent: Bool
    public var accountName: String?
    public var subject: String?
    public var elapsed: TimeInterval?

    public init(
        stage: ProblemStage,
        engine: EngineKind? = nil,
        endpointAPI: EndpointAPI? = nil,
        model: String? = nil,
        claudeKeyPresent: Bool = false,
        accountName: String? = nil,
        subject: String? = nil,
        elapsed: TimeInterval? = nil
    ) {
        self.stage = stage
        self.engine = engine
        self.endpointAPI = endpointAPI
        self.model = model
        self.claudeKeyPresent = claudeKeyPresent
        self.accountName = accountName
        self.subject = subject
        self.elapsed = elapsed
    }

    public static func engine(_ engine: EngineKind, settings: Settings, stage: ProblemStage, claudeKeyPresent: Bool, elapsed: TimeInterval? = nil) -> ProblemContext {
        let endpoint: EngineEndpoint? = switch engine {
        case .macbook: settings.macbook
        case .studio: settings.studio
        case .claude: nil
        }
        return ProblemContext(
            stage: stage,
            engine: engine,
            endpointAPI: endpoint?.api,
            model: endpoint?.model ?? settings.claudeModel,
            claudeKeyPresent: claudeKeyPresent,
            elapsed: elapsed
        )
    }
}

public protocol ProblemConvertible: Error {
    func problem(in context: ProblemContext) -> Problem
}

extension WaitReason {
    /// True when the wait won't clear by itself and needs the user to act.
    public var needsYou: Bool {
        switch self {
        case .studioNotConfigured, .claudeKeyMissing: true
        case .studioUnreachable, .memoryPressure, .recording: false
        }
    }
}
