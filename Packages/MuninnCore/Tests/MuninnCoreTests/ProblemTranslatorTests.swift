import Foundation
import Testing
@testable import MuninnCore

@Suite struct ProblemTranslatorTests {
    private let system = SystemInfo(appVersion: "test (1)", osVersion: "26.1")
    private let request = RequestFacts(method: "POST", path: "/api/chat", host: "127.0.0.1")

    private func engineContext(_ engine: EngineKind, stage: ProblemStage = .writingRecap, settings: Settings = .defaults, claudeKeyPresent: Bool = false) -> ProblemContext {
        .engine(engine, settings: settings, stage: stage, claudeKeyPresent: claudeKeyPresent)
    }

    private func translate(_ error: Error, _ context: ProblemContext) -> Problem {
        ProblemTranslator.problem(for: error, in: context, system: system)
    }

    @Test func connectionRefusedOnThisMacWithAKey() {
        let error = LLMError.connection(code: -1004, request: request)
        let problem = translate(error, engineContext(.macbook, claudeKeyPresent: true))
        #expect(problem.title == "Ollama isn't running on This Mac")
        #expect(problem.actions == [.writeWithClaude, .tryAgain, .engineSettings])
        #expect(problem.details.errorCode == -1004 && problem.details.request?.path == "/api/chat")
        #expect(problem.details.stage == .writingRecap && problem.details.engine == .macbook && problem.details.provider == .ollama && problem.details.model == "qwen3:8b")
        #expect(problem.details.appVersion == "test (1)" && problem.details.osVersion == "26.1")
    }

    @Test func timeoutOnAnOpenAICompatibleThisMacWithoutAKey() {
        var settings = Settings.defaults
        settings.macbook.api = .openAICompatible
        let problem = translate(URLError(.timedOut), engineContext(.macbook, settings: settings))
        #expect(problem.title == "The model server on This Mac isn't running")
        #expect(problem.actions == [.tryAgain, .engineSettings])
        #expect(problem.details.errorDomain == NSURLErrorDomain && problem.details.errorCode == -1001)
        #expect(problem.details.provider == .openAICompatible)
    }

    @Test func aBareURLErrorTakesItsRequestFromTheFailingURL() {
        let url = URL(string: "http://studio.local:11434/api/chat?x=1")!
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let problem = translate(error, engineContext(.studio))
        #expect(problem.details.request == RequestFacts(method: "GET", path: "/api/chat", host: "studio.local"))
    }

    @Test func networkMacUnreachable() {
        let error = LLMError.connection(code: -1004, request: request)
        let problem = translate(error, engineContext(.studio))
        #expect(problem.title == "The Network Mac can't be reached")
        #expect(problem.details.errorDomain == NSURLErrorDomain && problem.details.errorCode == -1004)
    }

    @Test func claudeUnreachable() {
        let problem = translate(LLMError.connection(code: -1009, request: request), engineContext(.claude))
        #expect(problem.title == "Claude can't be reached")
        #expect(problem.details.provider == .anthropic)
    }

    @Test(arguments: [ProblemStage.creatingDraft, .readingCalendar, .searchingPeople, .signingIn, .changingEvent])
    func connectionWithoutAnEngineAtAMicrosoftStage(stage: ProblemStage) {
        let problem = translate(URLError(.notConnectedToInternet), ProblemContext(stage: stage))
        #expect(problem.title == "Microsoft can't be reached")
    }

    @Test func connectionWhilePreparingTheSpeechModel() {
        let named = translate(URLError(.notConnectedToInternet), ProblemContext(stage: .preparingSpeechModel, model: "parakeet"))
        #expect(named.title == "The speech model couldn't be downloaded")
        #expect(named.explanation.contains("parakeet"))
        let unnamed = translate(URLError(.notConnectedToInternet), ProblemContext(stage: .preparingSpeechModel))
        #expect(unnamed.explanation.contains("the speech model"))
    }

    @Test func connectionAnywhereElseIsGeneric() {
        let problem = translate(URLError(.notConnectedToInternet), ProblemContext(stage: .filingNote))
        #expect(problem.title == "Something went wrong while filing the note in Obsidian")
    }

    @Test func muninnErrorsDontReportBridgedCodes() {
        let error = LLMError.http(status: 429, category: .rateLimited, request: request)
        let problem = translate(error, engineContext(.claude))
        #expect(problem.details.errorDomain == "LLMError" && problem.details.errorCode == nil)
        #expect(problem.details.httpStatus == 429 && problem.details.category == .rateLimited)
        #expect(problem.details.request == request)
    }

    @Test func modelNotFoundOnTheNetworkMac() {
        let error = LLMError.http(status: 404, category: .modelNotFound, request: request)
        let problem = translate(error, engineContext(.studio))
        #expect(problem.title == "The model gpt-oss:20b isn't installed")
        #expect(problem.explanation.contains("ollama pull gpt-oss:20b"))
        #expect(problem.actions == [.tryAgain])
    }

    @Test(arguments: [401, 403]) func claudeRejectsTheKey(status: Int) {
        let error = LLMError.http(status: status, category: .unauthorized, request: request)
        let problem = translate(error, engineContext(.claude))
        #expect(problem.title == "Claude didn't accept the API key")
        #expect(problem.actions == [.changeKey, .tryAgain])
    }

    @Test(arguments: [ProviderErrorCategory.rateLimited, .overloaded]) func claudeIsBusy(category: ProviderErrorCategory) {
        let error = LLMError.http(status: 529, category: category, request: request)
        let problem = translate(error, engineContext(.claude))
        #expect(problem.title == "Claude is busy right now")
        #expect(problem.actions == [.tryAgain, .writeOnThisMac])
    }

    @Test func rateLimitingOnAnotherEngineIsGeneric() {
        let error = LLMError.http(status: 429, category: .rateLimited, request: request)
        #expect(translate(error, engineContext(.studio)).title == "Something went wrong while writing the recap")
    }

    @Test func contextTooLongNamesTheModel() {
        let error = LLMError.http(status: 400, category: .contextTooLong, request: request)
        #expect(translate(error, engineContext(.macbook)).title == "The transcript is too long for qwen3:8b")
    }

    @Test func incompleteRepliesAtTheRecapStage() {
        let errors: [Error] = [LLMError.truncated, LLMError.emptyResponse, LLMError.decoding, SummaryParseError.notJSON, SummaryParseError.schemaMismatch]
        for error in errors {
            for stage in [ProblemStage.writingRecap, .cleaningUp] {
                let problem = translate(error, engineContext(.studio, stage: stage))
                #expect(problem.title == "The recap came back incomplete")
                #expect(problem.actions == [.tryAgain, .writeWithAnotherEngine])
            }
        }
    }

    @Test func incompleteRepliesElsewhereAreGeneric() {
        let problem = translate(LLMError.truncated, ProblemContext(stage: .identifyingSpeakers))
        #expect(problem.title == "Something went wrong while telling the speakers apart")
    }

    @Test func summaryParseErrorsNameTheirType() {
        let problem = translate(SummaryParseError.notJSON, engineContext(.macbook))
        #expect(problem.details.errorDomain == "SummaryParseError" && problem.details.errorCode == nil)
    }

    @Test func promptTruncatedIsTooLong() {
        let problem = translate(LLMError.promptTruncated(model: "qwen3:8b", contextTokens: 32768), engineContext(.macbook))
        #expect(problem.title == "The transcript is too long for qwen3:8b")
    }

    @Test func refusalNamesTheEngine() {
        let problem = translate(LLMError.refused(nil), engineContext(.claude))
        #expect(problem.title == "Claude declined to write this recap")
    }

    @Test func expiredSignIn() {
        let context = ProblemContext(stage: .readingCalendar, accountName: "Work")
        let errors: [Error] = [GraphError.auth("invalid_grant"), GraphError.notSignedIn, GraphError.http(status: 401, code: nil, request: request)]
        for error in errors {
            let problem = translate(error, context)
            #expect(problem.title == "Sign-in to Work expired")
            #expect(problem.actions == [.signInAgain])
            #expect(problem.details.account == "Work")
        }
    }

    @Test func expiredSignInWithoutAnAccountName() {
        let problem = translate(GraphError.notSignedIn, ProblemContext(stage: .readingCalendar))
        #expect(problem.title == "Sign-in to your Microsoft account expired")
    }

    @Test func signInThatFails() {
        let problem = translate(GraphError.auth("authorization_declined"), ProblemContext(stage: .signingIn, accountName: "Work"))
        #expect(problem.title == "Sign-in to Work didn't finish")
        #expect(problem.details.provider == .microsoftSignIn)
    }

    @Test func graphErrorWhileDrafting() {
        let graphRequest = RequestFacts(method: "POST", path: "/v1.0/me/messages", host: "graph.microsoft.com")
        let error = GraphError.http(status: 500, code: "ErrorInternalServerError", request: graphRequest)
        let problem = translate(error, ProblemContext(stage: .creatingDraft, accountName: "Work"))
        #expect(problem.title == "Outlook couldn't create the draft")
        #expect(problem.details.httpStatus == 500 && problem.details.graphCode == "ErrorInternalServerError")
        #expect(problem.details.provider == .microsoftGraph && problem.details.request == graphRequest)
        #expect(problem.details.errorDomain == "GraphError" && problem.details.errorCode == nil)
    }

    @Test(arguments: [ProblemStage.readingCalendar, .changingEvent]) func graphErrorWhileReadingTheCalendar(stage: ProblemStage) {
        let error = GraphError.http(status: 503, code: nil, request: request)
        let problem = translate(error, ProblemContext(stage: stage, accountName: "Work"))
        #expect(problem.title == "Muninn couldn't read the Work calendar")
    }

    @Test func graphErrorAtAnotherStageIsGeneric() {
        let error = GraphError.http(status: 503, code: nil, request: request)
        #expect(translate(error, ProblemContext(stage: .searchingPeople)).title == "Something went wrong while searching for people")
        #expect(translate(GraphError.decoding, ProblemContext(stage: .creatingDraft)).title == "Something went wrong while creating the Outlook draft")
    }

    @Test func microsoftUnreachableWhileDrafting() {
        let error = GraphError.connection(code: -1009, request: request)
        let problem = translate(error, ProblemContext(stage: .creatingDraft))
        #expect(problem.title == "Microsoft can't be reached")
        #expect(problem.details.errorDomain == NSURLErrorDomain && problem.details.errorCode == -1009)
    }

    @Test func engineClientErrors() {
        let context = ProblemContext(stage: .writingRecap)
        let studio = translate(EngineClientError.invalidBaseURL(.studio), context)
        #expect(studio.title == "The Network Mac isn't set up")
        #expect(studio.details.errorDomain == "EngineClientError" && studio.details.errorCode == nil)
        #expect(translate(EngineClientError.invalidBaseURL(.macbook), context).title == "This Mac's model server address isn't valid")
        #expect(translate(EngineClientError.missingClaudeKey, context).title == "There's no Claude API key")
    }

    @Test func diskWriteFailures() {
        let cocoa = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/x/summary.json"])
        let context = ProblemContext(stage: .savingEdits, subject: "the recap")
        let first = translate(cocoa, context)
        #expect(first.title == "Muninn couldn't save the recap")
        #expect(first.details.path == "/x/summary.json")
        let second = translate(POSIXError(.ENOSPC), context)
        #expect(second.title == "Muninn couldn't save the recap")
        #expect(second.details.errorDomain == NSPOSIXErrorDomain && second.details.errorCode == Int(ENOSPC))
    }

    @Test func diskWriteFailureTakesItsPathFromTheURLKeyAndDefaultsTheSubject() {
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: URL(fileURLWithPath: "/x/meeting.json")])
        let problem = translate(error, ProblemContext(stage: .savingEdits))
        #expect(problem.title == "Muninn couldn't save the meeting")
        #expect(problem.details.path == "/x/meeting.json")
    }

    @Test func otherCocoaErrorsAreGeneric() {
        let problem = translate(CocoaError(.fileNoSuchFile), ProblemContext(stage: .loadingMeetings))
        #expect(problem.title == "Something went wrong while loading the meetings")
    }

    @Test func anythingElseNamesTheStage() {
        struct Boom: Error {}
        let problem = translate(Boom(), ProblemContext(stage: .identifyingSpeakers))
        #expect(problem.title == "Something went wrong while telling the speakers apart")
        #expect(problem.actions == [.tryAgain])
        #expect(problem.details.errorDomain?.contains("Boom") == true)
    }

    @Test func contextFieldsFillTheDetails() {
        let context = ProblemContext(stage: .writingRecap, engine: .studio, endpointAPI: .openAICompatible, model: "m", accountName: "Work", elapsed: 12.5)
        let problem = translate(NSError(domain: "Test", code: 7), context)
        #expect(problem.details.errorDomain == "Test" && problem.details.errorCode == 7)
        #expect(problem.details.engine == .studio && problem.details.provider == .openAICompatible && problem.details.model == "m")
        #expect(problem.details.account == "Work" && problem.details.elapsedSeconds == 12.5)
    }

    private struct Convertible: ProblemConvertible {
        func problem(in context: ProblemContext) -> Problem {
            Problems.hotkeyInUse(keys: "⌃⌥⌘F")
        }
    }

    @Test func convertibleErrorsSpeakForThemselves() {
        let problem = translate(Convertible(), ProblemContext(stage: .savingSettings))
        #expect(problem.title == "The shortcut ⌃⌥⌘F is used by another app")
        #expect(problem.details.stage == .savingSettings)
        #expect(problem.details.appVersion == "test (1)" && problem.details.osVersion == "26.1")
    }

    private struct Coded: ProblemConvertible {
        var code: Int?

        func problem(in context: ProblemContext) -> Problem {
            Problems.keychainUnreadable(details: ProblemDetails(errorDomain: "Own", errorCode: code))
        }
    }

    @Test func aConvertibleErrorKeepsItsOwnDomainAndCodeNilIncluded() {
        let none = translate(Coded(code: nil), ProblemContext(stage: .savingSettings))
        #expect(none.details.errorDomain == "Own" && none.details.errorCode == nil)
        let set = translate(Coded(code: 5), ProblemContext(stage: .savingSettings))
        #expect(set.details.errorDomain == "Own" && set.details.errorCode == 5)
    }

    @Test func fieldsARuleAlreadySetSurvive() {
        let problem = translate(GraphError.notSignedIn, ProblemContext(stage: .readingCalendar, accountName: "Other"))
        #expect(problem.details.account == "Other")
        let named = translate(GraphError.notSignedIn, ProblemContext(stage: .readingCalendar))
        #expect(named.details.account == "your Microsoft account")
    }

    @Test func detailsAreRedacted() {
        let key = "sk-ant-" + String(repeating: "a", count: 20)
        let problem = translate(NSError(domain: key, code: 1), ProblemContext(stage: .writingRecap))
        #expect(problem.details.errorDomain?.contains(key) == false)
    }

    @Test func translatedProblemsNeverCarryErrorText() throws {
        let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: SEED, NSLocalizedFailureReasonErrorKey: SEED])
        let problem = translate(error, ProblemContext(stage: .writingRecap))
        let encoded = String(decoding: try JSONEncoder().encode(problem), as: UTF8.self)
        #expect(!encoded.contains("Henderson"))
    }
}
