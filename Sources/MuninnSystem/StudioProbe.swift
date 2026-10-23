import Foundation
import MuninnCore
import os

public struct LiveEnvironmentProbe: EnvironmentProbing {
    public static let claudeKeyName = "claude.apiKey"
    static let timeout: TimeInterval = 2

    private static let logger = Logger(subsystem: "be.netronix.muninn", category: "system")

    private let secrets: any SecretsReading
    private let session: URLSession

    public init(secrets: KeychainSecrets, session: URLSession = LiveEnvironmentProbe.makeSession()) {
        self.secrets = secrets
        self.session = session
    }

    init(secrets: any SecretsReading, session: URLSession) {
        self.secrets = secrets
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    public func environment(settings: Settings) async -> EngineEnvironment {
        let studio = Self.endpointURL(settings.studio)
        let reachable: Bool
        if let studio {
            reachable = await isReachable(studio)
        } else {
            reachable = false
        }
        let key: String?
        do {
            key = try secrets.get(Self.claudeKeyName)
        } catch {
            Self.logger.error("Reading \(Self.claudeKeyName, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
            key = nil
        }
        return EngineEnvironment(
            studioConfigured: EndpointURL.parseBase(settings.studio.baseURL) != nil,
            studioReachable: reachable,
            memoryPressure: SystemMemoryPressure.current(),
            claudeKeyPresent: key?.isEmpty == false
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

    private func isReachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
