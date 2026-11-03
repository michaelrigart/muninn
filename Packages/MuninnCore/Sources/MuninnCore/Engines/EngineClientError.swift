import Foundation

public enum EngineClientError: Error, Equatable {
    case invalidBaseURL(EngineKind)
    case missingClaudeKey
}
