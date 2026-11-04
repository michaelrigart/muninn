import Foundation
import MuninnCore
import os

public struct LiveEnvironmentProbe: EnvironmentProbing {
    public static let claudeKeyName = "claude.apiKey"
    static let timeout: TimeInterval = 2

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "system")

    private let secrets: any SecretsReading
    private let activity: ActivityRecording
    private let session: URLSession
    private let tracker = Tracker()

    public init(secrets: KeychainSecrets, activity: ActivityRecording = NoActivity(), session: URLSession = LiveEnvironmentProbe.makeSession()) {
        self.secrets = secrets
        self.activity = activity
        self.session = session
    }

    init(secrets: any SecretsReading, activity: ActivityRecording = NoActivity(), session: URLSession) {
        self.secrets = secrets
        self.activity = activity
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    public func environment(settings: Settings) async -> EngineEnvironment {
        let sequence = tracker.begin()
        let studio = Self.endpointURL(settings.studio)
        let thisMac = Self.endpointURL(settings.macbook)
        async let studioAnswer = reachable(studio)
        async let thisMacAnswer = thisMac == nil ? true : reachable(thisMac)
        let key: String?
        var keyUnreadable = false
        do {
            key = try secrets.get(Self.claudeKeyName)
        } catch {
            Self.logger.error("Reading \(Self.claudeKeyName, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            key = nil
            keyUnreadable = true
        }
        let studioConfigured = EndpointURL.parseBase(settings.studio.baseURL) != nil
        let studioReachable = await studioAnswer
        let thisMacReachable = await thisMacAnswer
        let thisMacTracked = thisMac != nil && settings.defaultEngine != .claude
        tracker.apply(
            sequence,
            thisMac: thisMacTracked ? thisMacReachable : nil,
            networkMac: studioConfigured ? studioReachable : nil,
            keyReadable: !keyUnreadable,
            api: settings.macbook.api,
            time: Date(),
            record: activity.record
        )
        return EngineEnvironment(
            studioConfigured: studioConfigured,
            studioReachable: studioReachable,
            memoryPressure: SystemMemoryPressure.current(),
            claudeKeyPresent: key?.isEmpty == false,
            thisMacReachable: thisMacReachable,
            claudeKeyUnreadable: keyUnreadable
        )
    }

    private static func describe(_ error: Error) -> String {
        if case KeychainError.status(let status) = error { return String(status) }
        return String(describing: type(of: error))
    }

    static func endpointURL(_ endpoint: EngineEndpoint) -> URL? {
        guard let base = EndpointURL.parseBase(endpoint.baseURL) else { return nil }
        let path = endpoint.api == .ollama ? "api/tags" : "v1/models"
        return EndpointURL.make(base: base, path: path)
    }

    private func reachable(_ url: URL?) async -> Bool {
        guard let url else { return false }
        return await isReachable(url)
    }

    private func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Overlapping probes can finish out of order; a result older than the last one applied is dropped.
    private final class Tracker: @unchecked Sendable {
        private let lock = NSLock()
        private var tracker = ReachabilityTracker()
        private var issued = 0
        private var applied = 0

        func begin() -> Int {
            lock.lock()
            defer { lock.unlock() }
            issued += 1
            return issued
        }

        func apply(
            _ sequence: Int, thisMac: Bool?, networkMac: Bool?, keyReadable: Bool, api: EndpointAPI, time: Date,
            record: (ActivityEntry) -> Void
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard sequence > applied else { return }
            applied = sequence
            let entries = tracker.entries(thisMac: thisMac, networkMac: networkMac, keyReadable: keyReadable, api: api, time: time)
            for entry in entries { record(entry) }
        }
    }
}
