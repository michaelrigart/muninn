import Foundation

/// Reduces a failed reply to a category or a code from a fixed list, so no response text survives in an error.
public enum ProviderErrorClassifier {
    public static let knownGraphCodes: Set<String> = [
        "ErrorAccessDenied", "ErrorItemNotFound", "ErrorInvalidRequest", "ErrorInvalidIdMalformed", "ErrorInvalidRecipients",
        "ErrorQuotaExceeded", "ErrorSendAsDenied", "ErrorMessageSizeExceeded", "ErrorExceededMessageLimit",
        "ErrorMailboxNotEnabledForRESTAPI", "MailboxNotEnabledForRESTAPI", "ErrorNonExistentMailbox", "ErrorInternalServerError",
        "ErrorServerBusy", "ErrorTimeoutExpired", "InvalidAuthenticationToken", "AuthenticationError", "Authorization_RequestDenied",
        "Request_ResourceNotFound", "Request_BadRequest", "Forbidden", "Unauthorized", "BadRequest", "TooManyRequests",
        "ApplicationThrottled", "ServiceUnavailable", "generalException", "itemNotFound", "accessDenied", "invalidRequest",
        "activityLimitReached", "serviceNotAvailable", "unauthenticated", "quotaLimitReached",
    ]

    public static let knownOAuthCodes: Set<String> = [
        "invalid_request", "invalid_client", "invalid_grant", "unauthorized_client", "unsupported_grant_type", "invalid_scope",
        "authorization_pending", "slow_down", "access_denied", "expired_token", "authorization_declined", "bad_verification_code",
        "interaction_required", "consent_required", "login_required", "temporarily_unavailable", "server_error",
    ]

    public static func category(status: Int, body: Data, provider: Provider) -> ProviderErrorCategory {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = root?["error"] as? [String: Any]
        switch provider {
        case .ollama:
            if status == 404, let text = root?["error"] as? String, text.range(of: "not found", options: .caseInsensitive) != nil {
                return .modelNotFound
            }
        case .anthropic:
            if let type = detail?["type"] as? String {
                switch type {
                case "authentication_error", "permission_error": return .unauthorized
                case "rate_limit_error": return .rateLimited
                case "overloaded_error": return .overloaded
                case "not_found_error": return .modelNotFound
                case "invalid_request_error":
                    let message = detail?["message"] as? String ?? ""
                    return message.range(of: "prompt is too long", options: .caseInsensitive) != nil ? .contextTooLong : .badRequest
                case "api_error": return .serverError
                default: break
                }
            }
        case .openAICompatible:
            switch detail?["code"] as? String {
            case "model_not_found": return .modelNotFound
            case "context_length_exceeded": return .contextTooLong
            case "invalid_api_key": return .unauthorized
            default: break
            }
        case .microsoftGraph, .microsoftSignIn:
            break
        }
        return fallback(status: status, provider: provider)
    }

    private static func fallback(status: Int, provider: Provider) -> ProviderErrorCategory {
        switch status {
        case 401, 403: .unauthorized
        case 404: provider == .ollama || provider == .openAICompatible ? .modelNotFound : .unknown
        case 429: .rateLimited
        case 503, 529: .overloaded
        case 400, 413, 422: .badRequest
        case 500..<600: .serverError
        default: .unknown
        }
    }

    /// The Graph `error.code` when it is a known one, `"other"` for any other code, nil when the reply has none.
    public static func graphCode(in body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let code = (root["error"] as? [String: Any])?["code"] as? String else { return nil }
        return knownGraphCodes.contains(code) ? code : "other"
    }

    public static func oauthCode(_ code: String?) -> String {
        guard let code, knownOAuthCodes.contains(code) else { return "unrecognised" }
        return code
    }
}
