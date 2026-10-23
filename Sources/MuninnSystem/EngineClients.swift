import Foundation
import MuninnCore

public enum EngineClientError: LocalizedError, Equatable {
    case invalidBaseURL(EngineKind)
    case missingClaudeKey

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(.macbook): "Invalid This Mac engine URL"
        case .invalidBaseURL(.studio): "Invalid Network Mac engine URL"
        case .invalidBaseURL(.claude): "Invalid Claude engine URL"
        case .missingClaudeKey: "No Claude API key saved"
        }
    }
}

public enum EngineClients {
    public static let macbookContextTokens = 32768
    public static let studioContextTokens = 65536

    public static func make(_ engine: EngineKind, settings: Settings, secrets: KeychainSecrets) throws -> LLMClient {
        switch engine {
        case .macbook:
            return try endpointClient(settings.macbook, engine: engine)
        case .studio:
            return try endpointClient(settings.studio, engine: engine)
        case .claude:
            guard let key = try secrets.get(LiveEnvironmentProbe.claudeKeyName), !key.isEmpty else { throw EngineClientError.missingClaudeKey }
            return ClaudeClient(apiKey: key, model: settings.claudeModel, effort: settings.claudeEffort)
        }
    }

    static func endpointClient(_ endpoint: EngineEndpoint, engine: EngineKind) throws -> LLMClient {
        guard let url = EndpointURL.parseBase(endpoint.baseURL) else { throw EngineClientError.invalidBaseURL(engine) }
        switch endpoint.api {
        case .ollama:
            return OllamaClient(
                baseURL: url, model: endpoint.model, keepAlive: endpoint.keepAlive,
                contextTokens: engine == .studio ? studioContextTokens : macbookContextTokens
            )
        case .openAICompatible:
            return OpenAICompatibleClient(baseURL: url, model: endpoint.model, apiKey: nil)
        }
    }
}
