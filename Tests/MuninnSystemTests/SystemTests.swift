import Carbon.HIToolbox
import Foundation
import Testing
import MuninnCore
@testable import MuninnSystem

@Test func hotkeyParserControlOptionCommandF() throws {
    let parsed = try #require(HotkeyParser.carbon(Hotkey(key: "F", modifiers: ["control", "option", "command"])))
    #expect(parsed.keyCode == 3)
    #expect(parsed.modifiers == UInt32(controlKey | optionKey | cmdKey))
}

@Test func hotkeyParserRejectsUnknownInput() {
    #expect(HotkeyParser.carbon(Hotkey(key: "?", modifiers: ["command"])) == nil)
    #expect(HotkeyParser.carbon(Hotkey(key: "F", modifiers: ["hyper"])) == nil)
}

@Test func hotkeyParserRequiresControlOptionOrCommand() throws {
    #expect(HotkeyParser.carbon(Hotkey(key: "F", modifiers: [])) == nil)
    #expect(HotkeyParser.carbon(Hotkey(key: "F", modifiers: ["shift"])) == nil)
    let parsed = try #require(HotkeyParser.carbon(Hotkey(key: "F", modifiers: ["shift", "command"])))
    #expect(parsed.modifiers == UInt32(shiftKey | cmdKey))
}

@Test func hotkeyTextParsesModifiersAndKey() throws {
    let hotkey = try #require(HotkeyText.parse("ctrl + Alt+cmd+f"))
    #expect(hotkey == Hotkey(key: "F", modifiers: ["control", "option", "command"]))
    #expect(HotkeyText.parse("shift+command+F5") == Hotkey(key: "F5", modifiers: ["shift", "command"]))
}

@Test func hotkeyTextRejectsMalformedInput() {
    #expect(HotkeyText.parse("") == nil)
    #expect(HotkeyText.parse("F") == nil)
    #expect(HotkeyText.parse("command+") == nil)
    #expect(HotkeyText.parse("hyper+F") == nil)
    #expect(HotkeyText.parse("F+command") == nil)
}

@Test func hotkeyTextFormatRoundTripsDefault() throws {
    let hotkey = Hotkey(key: "F", modifiers: ["control", "option", "command"])
    #expect(HotkeyText.format(hotkey) == "control+option+command+F")
    #expect(HotkeyText.parse(HotkeyText.format(hotkey)) == hotkey)
}

@Test func memoryPressureMapsRawValues() {
    #expect(SystemMemoryPressure.level(fromRaw: 1) == .normal)
    #expect(SystemMemoryPressure.level(fromRaw: 2) == .warning)
    #expect(SystemMemoryPressure.level(fromRaw: 4) == .critical)
    #expect(SystemMemoryPressure.level(fromRaw: 0) == nil)
    #expect(SystemMemoryPressure.level(fromRaw: 3) == nil)
    #expect(SystemMemoryPressure.level(fromRaw: 8) == nil)
}

@Test func memoryPressureReadsValidLevel() throws {
    if SystemMemoryPressure.read() == nil {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0)
        if errno == EPERM || errno == EACCES {
            withKnownIssue("Reading kern.memorystatus_vm_pressure_level is denied in this environment (agent sandbox, errno \(errno))") {
                _ = try #require(SystemMemoryPressure.read())
            }
            return
        }
    }
    _ = try #require(SystemMemoryPressure.read())
    #expect([MemoryPressureLevel.normal, .warning, .critical].contains(SystemMemoryPressure.current()))
}

@Test func keychainRoundTrip() throws {
    let secrets = KeychainSecrets(service: "be.netronix.muninn.tests")
    let key = "round-trip-\(UUID().uuidString)"
    defer { try? secrets.delete(key) }
    do {
        #expect(try secrets.get(key) == nil)
        try secrets.set("first", for: key)
        #expect(try secrets.get(key) == "first")
        try secrets.set("second", for: key)
        #expect(try secrets.get(key) == "second")

        let tokens = KeychainTokenStore(secrets: secrets)
        let account = "acct-\(UUID().uuidString)"
        defer { try? tokens.delete(account: account) }
        let set = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_800_000_000.25))
        try tokens.save(set, account: account)
        #expect(try tokens.load(account: account) == set)

        try secrets.set(#"{"accessToken":"a","refreshToken":"r","expiresAt":"2027-01-15T08:00:00Z"}"#, for: "graph.\(account)")
        #expect(try tokens.load(account: account)?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))

        try tokens.delete(account: account)
        #expect(try tokens.load(account: account) == nil)

        try secrets.delete(key)
        #expect(try secrets.get(key) == nil)
    } catch KeychainError.status(let status)
        where status == errSecInteractionNotAllowed || status == errSecNotAvailable
            || status == errSecAuthFailed || status == errSecMissingEntitlement
    {
        withKnownIssue("Keychain access is unavailable in this environment (OSStatus \(status))") {
            throw KeychainError.status(status)
        }
    }
}

@Test func studioEndpointURLNormalisesBaseURL() {
    func url(_ api: EndpointAPI, _ base: String) -> String? {
        LiveEnvironmentProbe.endpointURL(EngineEndpoint(api: api, baseURL: base, model: "m", keepAlive: "0"))?.absoluteString
    }
    #expect(url(.ollama, "http://studio:11434/") == "http://studio:11434/api/tags")
    #expect(url(.openAICompatible, "http://studio:8080") == "http://studio:8080/v1/models")
    #expect(url(.openAICompatible, "http://studio:8080/v1/") == "http://studio:8080/v1/models")
    #expect(url(.ollama, "studio:11434") == nil)
    #expect(url(.ollama, "ftp://studio") == nil)
}

// MARK: - Probe

private struct StubSecrets: SecretsReading {
    var result: Result<String?, Error>

    func get(_ key: String) throws -> String? {
        #expect(key == "claude.apiKey")
        return try result.get()
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requested: [String: [String]] = [:]

    static func register(host: String, reply: Reply) {
        lock.lock()
        defer { lock.unlock() }
        replies[host] = reply
        requested[host] = []
    }

    static func paths(host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested[host] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.lock()
        Self.requested[host, default: []].append("\(request.httpMethod ?? "")  \(request.url?.path ?? "")")
        let reply = Self.replies[host]
        Self.lock.unlock()
        switch reply {
        case .status(let code):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
        }
    }

    override func stopLoading() {}
}

private func probe(secrets: Result<String?, Error> = .success(nil)) -> LiveEnvironmentProbe {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return LiveEnvironmentProbe(secrets: StubSecrets(result: secrets), session: URLSession(configuration: configuration))
}

private func settings(api: EndpointAPI, base: String) -> Settings {
    var settings = Settings.defaults
    settings.studio = EngineEndpoint(api: api, baseURL: base, model: "m", keepAlive: "0")
    return settings
}

@Test(arguments: ["", "  \n"])
func probeUnreachableForEmptyBaseURL(base: String) async {
    StubProtocol.register(host: "", reply: .status(200))
    let environment = await probe().environment(settings: settings(api: .ollama, base: base))
    #expect(!environment.studioConfigured)
    #expect(!environment.studioReachable)
    #expect(StubProtocol.paths(host: "").isEmpty)
}

@Test func defaultSettingsLeaveTheNetworkMacUnconfigured() async {
    let environment = await probe().environment(settings: .defaults)
    #expect(!environment.studioConfigured)
    #expect(!environment.studioReachable)
}

@Test(arguments: [(200, true), (204, true), (404, false), (500, false)])
func probeReachabilityFollowsStatus(status: Int, reachable: Bool) async {
    let host = "status-\(status).studio.test"
    StubProtocol.register(host: host, reply: .status(status))
    let environment = await probe().environment(settings: settings(api: .ollama, base: "http://\(host):11434"))
    #expect(environment.studioConfigured)
    #expect(environment.studioReachable == reachable)
}

@Test(arguments: [(EndpointAPI.ollama, "/api/tags"), (.openAICompatible, "/v1/models")])
func probeRequestsPathPerAPI(api: EndpointAPI, path: String) async {
    let host = "path-\(api.rawValue.lowercased()).studio.test"
    StubProtocol.register(host: host, reply: .status(200))
    _ = await probe().environment(settings: settings(api: api, base: "http://\(host)"))
    #expect(StubProtocol.paths(host: host) == ["GET  \(path)"])
}

@Test func probeUnreachableOnTransportError() async {
    let host = "failing.studio.test"
    StubProtocol.register(host: host, reply: .failure(.timedOut))
    let environment = await probe().environment(settings: settings(api: .ollama, base: "http://\(host)"))
    #expect(environment.studioConfigured)
    #expect(!environment.studioReachable)
}

@Test func defaultProbeSessionHasTwoSecondDeadlines() {
    let configuration = LiveEnvironmentProbe.makeSession().configuration
    #expect(configuration.timeoutIntervalForRequest == 2)
    #expect(configuration.timeoutIntervalForResource == 2)
}

private struct StubFailure: Error {}

@Test(arguments: [
    (Result<String?, Error>.success("sk-ant-test"), true),
    (.success(""), false),
    (.success(nil), false),
    (.failure(KeychainError.status(errSecInteractionNotAllowed)), false),
    (.failure(StubFailure()), false),
])
func probeClaudeKeyPresence(secrets: Result<String?, Error>, present: Bool) async {
    let environment = await probe(secrets: secrets).environment(settings: settings(api: .ollama, base: ""))
    #expect(environment.claudeKeyPresent == present)
}

@Test func engineClientsBuildEndpointClientsFromSettings() throws {
    var settings = Settings.defaults
    settings.studio = EngineEndpoint(api: .openAICompatible, baseURL: "http://studio.local:1234", model: "m", keepAlive: "0")
    #expect(try EngineClients.endpointClient(settings.macbook, engine: .macbook) is OllamaClient)
    #expect(try EngineClients.endpointClient(settings.studio, engine: .studio) is OpenAICompatibleClient)
}

@Test func engineClientsCapTheContextPerEngine() throws {
    var settings = Settings.defaults
    settings.studio = EngineEndpoint(api: .ollama, baseURL: "http://studio.local:11434", model: "m", keepAlive: "10m")
    let macbook = try #require(try EngineClients.endpointClient(settings.macbook, engine: .macbook) as? OllamaClient)
    let studio = try #require(try EngineClients.endpointClient(settings.studio, engine: .studio) as? OllamaClient)
    #expect(macbook.contextTokens == 32768)
    #expect(studio.contextTokens == 65536)
}

@Test func engineClientsRejectInvalidBaseURL() {
    let blank = Settings.defaults.studio
    #expect(throws: EngineClientError.invalidBaseURL(.studio)) {
        try EngineClients.endpointClient(blank, engine: .studio)
    }
    #expect(EngineClientError.invalidBaseURL(.studio).errorDescription == "Invalid Network Mac engine URL")
    #expect(EngineClientError.missingClaudeKey.errorDescription == "No Claude API key saved")
}
