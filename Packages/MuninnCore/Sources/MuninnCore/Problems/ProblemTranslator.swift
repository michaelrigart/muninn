import Foundation

public enum ProblemTranslator {
    public static func problem(for error: Error, in context: ProblemContext, system: SystemInfo = .current) -> Problem {
        var problem = translate(error, in: context)
        problem.details = complete(problem.details, for: error, in: context, system: system).redacted()
        return problem
    }

    // MARK: Rules

    private static func translate(_ error: Error, in context: ProblemContext) -> Problem {
        if let convertible = error as? ProblemConvertible {
            return convertible.problem(in: context)
        }
        switch error {
        case let error as LLMError: return llm(error, in: context)
        case is URLError: return connection(in: context)
        case is SummaryParseError: return incompleteReply(in: context)
        case let error as GraphError: return graph(error, in: context)
        case let error as EngineClientError: return engineClient(error, in: context)
        default: break
        }
        let nsError = error as NSError
        if isDiskWriteFailure(nsError) {
            let url = nsError.userInfo[NSURLErrorKey] as? URL
            let path = (nsError.userInfo[NSFilePathErrorKey] as? String) ?? url?.path
            return Problems.couldNotSave(what: context.subject ?? "the meeting", details: ProblemDetails(path: path))
        }
        return Problems.somethingWentWrong(stage: context.stage)
    }

    private static func llm(_ error: LLMError, in context: ProblemContext) -> Problem {
        let engine = context.engine
        let claude = engine == .claude
        switch error {
        case .connection:
            return connection(in: context)
        case .http(_, let category, _):
            switch category {
            case .modelNotFound:
                return Problems.modelNotInstalled(model: context.model ?? "", engine: engine ?? .macbook, api: context.endpointAPI ?? .ollama)
            case .unauthorized where claude:
                return Problems.claudeKeyRejected()
            case .rateLimited where claude, .overloaded where claude:
                return Problems.claudeBusy()
            case .contextTooLong:
                return Problems.transcriptTooLong(model: context.model ?? "the model")
            default:
                return Problems.somethingWentWrong(stage: context.stage)
            }
        case .truncated, .emptyResponse, .decoding:
            return incompleteReply(in: context)
        case .refused:
            return Problems.recapRefused(engine: engine ?? .macbook)
        case .promptTruncated(let model, _):
            return Problems.transcriptTooLong(model: model)
        }
    }

    private static func connection(in context: ProblemContext) -> Problem {
        switch context.engine {
        case .macbook:
            return Problems.thisMacServerNotRunning(api: context.endpointAPI ?? .ollama, claudeKeyPresent: context.claudeKeyPresent, waiting: false)
        case .studio:
            return Problems.networkMacUnreachable()
        case .claude:
            return Problems.claudeUnreachable()
        case nil:
            switch context.stage {
            case .creatingDraft, .readingCalendar, .searchingPeople, .signingIn, .changingEvent:
                return microsoftUnreachable(in: context)
            case .preparingSpeechModel:
                return Problems.speechModelUnavailable(model: context.model ?? "the speech model")
            default:
                return Problems.somethingWentWrong(stage: context.stage)
            }
        }
    }

    private static func microsoftUnreachable(in context: ProblemContext) -> Problem {
        Problems.microsoftUnreachable(details: ProblemDetails(provider: microsoftProvider(for: context.stage)))
    }

    private static func incompleteReply(in context: ProblemContext) -> Problem {
        switch context.stage {
        case .writingRecap, .cleaningUp: Problems.recapIncomplete(engine: context.engine ?? .macbook)
        default: Problems.somethingWentWrong(stage: context.stage)
        }
    }

    private static func graph(_ error: GraphError, in context: ProblemContext) -> Problem {
        let account = context.accountName ?? "your Microsoft account"
        switch (error, context.stage) {
        case (.auth, .signingIn), (.http, .signingIn):
            return Problems.signInFailed(account: account)
        case (.notSignedIn, _), (.auth, _), (.http(401, _, _), _):
            return Problems.signInExpired(account: account)
        case (.http, .creatingDraft):
            return Problems.outlookDraftFailed()
        case (.http, .readingCalendar), (.http, .changingEvent):
            return Problems.calendarUnreadable(account: account)
        case (.connection, _):
            return microsoftUnreachable(in: context)
        default:
            return Problems.somethingWentWrong(stage: context.stage)
        }
    }

    private static func engineClient(_ error: EngineClientError, in context: ProblemContext) -> Problem {
        switch error {
        case .invalidBaseURL(.studio): Problems.networkMacNotSetUp()
        case .invalidBaseURL(.macbook): Problems.thisMacAddressInvalid()
        case .invalidBaseURL(.claude): Problems.somethingWentWrong(stage: context.stage)
        case .missingClaudeKey: Problems.claudeKeyMissing()
        }
    }

    private static func isDiskWriteFailure(_ error: NSError) -> Bool {
        switch error.domain {
        case NSCocoaErrorDomain:
            return (512...642).contains(error.code)
        case NSPOSIXErrorDomain:
            return [ENOSPC, EACCES, EROFS, EDQUOT].contains(Int32(truncatingIfNeeded: error.code))
        default:
            return false
        }
    }

    // MARK: Details

    private static func complete(_ details: ProblemDetails, for error: Error, in context: ProblemContext, system: SystemInfo) -> ProblemDetails {
        var details = details
        let facts = facts(of: error)
        if !(error is ProblemConvertible) {
            details.errorDomain = details.errorDomain ?? facts.domain
            details.errorCode = details.errorCode ?? facts.code
        }
        details.request = details.request ?? facts.request
        details.httpStatus = details.httpStatus ?? facts.httpStatus
        details.category = details.category ?? facts.category
        details.graphCode = details.graphCode ?? facts.graphCode
        details.engine = details.engine ?? context.engine
        if details.provider == nil {
            details.provider = error is GraphError
                ? microsoftProvider(for: context.stage)
                : context.engine.map { provider(for: $0, api: context.endpointAPI) }
        }
        details.model = details.model ?? context.model
        details.account = details.account ?? context.accountName
        details.stage = details.stage ?? context.stage
        details.elapsedSeconds = details.elapsedSeconds ?? context.elapsed
        details.appVersion = details.appVersion ?? system.appVersion
        details.osVersion = details.osVersion ?? system.osVersion
        return details
    }

    private struct ErrorFacts {
        var domain: String?
        var code: Int?
        var request: RequestFacts?
        var httpStatus: Int?
        var category: ProviderErrorCategory?
        var graphCode: String?
    }

    private static func facts(of error: Error) -> ErrorFacts {
        if let error = error as? LLMError {
            switch error {
            case .connection(let code, let request):
                return ErrorFacts(domain: NSURLErrorDomain, code: code, request: request)
            case .http(let status, let category, let request):
                return ErrorFacts(domain: "LLMError", request: request, httpStatus: status, category: category)
            default:
                return ErrorFacts(domain: "LLMError")
            }
        }
        if let error = error as? GraphError {
            switch error {
            case .connection(let code, let request):
                return ErrorFacts(domain: NSURLErrorDomain, code: code, request: request)
            case .http(let status, let code, let request):
                return ErrorFacts(domain: "GraphError", request: request, httpStatus: status, graphCode: code)
            default:
                return ErrorFacts(domain: "GraphError")
            }
        }
        if error is SummaryParseError { return ErrorFacts(domain: "SummaryParseError") }
        if error is EngineClientError { return ErrorFacts(domain: "EngineClientError") }
        let nsError = error as NSError
        var facts = ErrorFacts(domain: nsError.domain, code: nsError.code)
        if error is URLError, let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            facts.request = RequestFacts(method: "GET", url: url)
        }
        return facts
    }

    private static func provider(for engine: EngineKind, api: EndpointAPI?) -> Provider {
        switch engine {
        case .macbook, .studio: .endpoint(api ?? .ollama)
        case .claude: .anthropic
        }
    }

    private static func microsoftProvider(for stage: ProblemStage) -> Provider {
        stage == .signingIn ? .microsoftSignIn : .microsoftGraph
    }
}
