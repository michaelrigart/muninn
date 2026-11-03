import Foundation
import Testing
@testable import MuninnCore

@Suite struct ProblemTests {
    private let allWaitReasons: [WaitReason] = [.studioUnreachable, .studioNotConfigured, .memoryPressure, .claudeKeyMissing, .recording]

    private var allSampleProblems: [Problem] {
        var problems: [Problem] = [
            Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: false),
            Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: false, waiting: true),
            Problems.thisMacServerNotRunning(api: .openAICompatible, claudeKeyPresent: true, waiting: false),
            Problems.thisMacServerNotRunning(api: .openAICompatible, claudeKeyPresent: false, waiting: true),
            Problems.thisMacAddressInvalid(),
            Problems.networkMacUnreachable(),
            Problems.networkMacNotSetUp(),
            Problems.claudeUnreachable(),
            Problems.modelNotInstalled(model: "qwen3:8b", engine: .macbook, api: .ollama),
            Problems.modelNotInstalled(model: "m", engine: .studio, api: .openAICompatible),
            Problems.claudeKeyRejected(),
            Problems.claudeBusy(),
            Problems.claudeKeyMissing(),
            Problems.recapIncomplete(engine: .studio),
            Problems.recapRefused(engine: .claude),
            Problems.transcriptTooLong(model: "qwen3:8b"),
            Problems.signInExpired(account: "Work"),
            Problems.signInFailed(account: "Work"),
            Problems.microsoftUnreachable(),
            Problems.outlookDraftFailed(),
            Problems.calendarUnreadable(account: "Work"),
            Problems.keychainUnreadable(),
            Problems.keychainUnwritable(),
            Problems.speechModelUnavailable(model: "parakeet"),
            Problems.couldNotSave(what: "the settings"),
            Problems.hotkeyInUse(keys: "⌃⌥F"),
            Problems.hotkeyUnsupported(keys: "⌃⌥F"),
            Problems.somethingWentWrong(stage: .writingRecap),
            Problems.legacyFailure(),
            Problems.legacyEngineNotice(),
            Problems.recordingUnreadable(),
            Problems.recordingDidNotStart(),
            Problems.recordingPartlyUnsaved(tracks: "microphone"),
            Problems.recordingTrackStopped(track: "microphone"),
            Problems.noCallAudio(app: "Teams"),
            Problems.writtenOnThisMac(because: .studioNotConfigured),
            Problems.writtenOnThisMac(because: .studioUnreachable),
            Problems.regenerationFailed(Problems.claudeBusy()),
            Problems.diarisationDegraded(mode: .call(appBundleID: "com.example.call")),
            Problems.diarisationDegraded(mode: .micOnly),
            Problems.eventNotChanged(),
            Problems.vaultNotChosen(),
            Problems.notFiledAutomatically(unsourced: 1),
            Problems.notFiledAutomatically(unsourced: 3),
            Problems.draftWithoutLink(),
        ]
        for reason in allWaitReasons {
            problems.append(Problems.waiting(reason, api: .ollama, claudeKeyPresent: true))
            problems.append(Problems.waiting(reason, api: .openAICompatible, claudeKeyPresent: false))
            problems.append(Problems.keptRecap(reason, api: .ollama))
        }
        return problems
    }

    @Test func thisMacServerTitleFollowsTheAPI() {
        #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: false).title == "Ollama isn't running on This Mac")
        #expect(Problems.thisMacServerNotRunning(api: .openAICompatible, claudeKeyPresent: true, waiting: false).title == "The model server on This Mac isn't running")
    }

    @Test func thisMacServerOffersClaudeOnlyWithAKey() {
        #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: true).actions == [.writeWithClaude, .tryAgain, .engineSettings])
        #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: false, waiting: true).actions == [.tryAgain, .engineSettings])
    }

    @Test func modelNotInstalledNamesThePullCommandForOllamaOnly() {
        #expect(Problems.modelNotInstalled(model: "qwen3:8b", engine: .macbook, api: .ollama).explanation.contains("ollama pull qwen3:8b"))
        #expect(!Problems.modelNotInstalled(model: "m", engine: .studio, api: .openAICompatible).explanation.contains("ollama"))
    }

    @Test func catalogueFollowsTheCopyRules() {
        for problem in allSampleProblems {
            #expect(problem.actions.count <= 3)
            #expect(!problem.title.hasSuffix("."))
            #expect(problem.title.first?.isUppercase == true)
            #expect(!"\(problem.title) \(problem.explanation)".localizedCaseInsensitiveContains("summar"))
        }
    }

    @Test func detailsTextOmitsTheHostUnlessAsked() {
        let details = ProblemDetails(request: RequestFacts(method: "POST", path: "/api/chat", host: "studio.local"))
        #expect(!details.text(includeHost: false).contains("studio.local"))
        #expect(details.text(includeHost: true).contains("Request: POST /api/chat on studio.local"))
    }

    @Test func requestFactsHideLongPathSegments() {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/events/\(String(repeating: "A", count: 40))")!
        #expect(RequestFacts(method: "GET", url: url) == RequestFacts(method: "GET", path: "/v1.0/me/events/{id}", host: "graph.microsoft.com"))
    }

    @Test func problemsRoundTripThroughJSON() throws {
        let details = ProblemDetails(
            errorDomain: "NSURLErrorDomain", errorCode: -1004,
            request: RequestFacts(method: "POST", path: "/api/chat", host: "studio.local"),
            httpStatus: 500, engine: .studio, provider: .ollama, model: "qwen3:8b", category: .serverError,
            graphCode: "generalException", path: "meetings/x.json", account: "Work", stage: .writingRecap,
            elapsedSeconds: 1.5, appVersion: "1.0 (1)", osVersion: "26.1", fromEarlierVersion: true
        )
        let problem = Problem(severity: .warning, title: "T", explanation: "E", actions: [.tryAgain, .engineSettings], details: details)
        let decoded = try JSONDecoder().decode(Problem.self, from: JSONEncoder().encode(problem))
        #expect(decoded == problem)
    }

    @Test func redactionRemovesKeysAndTokens() {
        #expect(Redaction.redact("key sk-ant-api03-abcdefghijklmnop") == "key [redacted]")
        #expect(!Redaction.redact("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl").contains("eyJ"))
        #expect(Redaction.redact(String(repeating: "aB3", count: 16)) == "[redacted]")
        #expect(Redaction.redact("2026-11-03-1400-supplier-call-about-the-quarterly-numbers") == "2026-11-03-1400-supplier-call-about-the-quarterly-numbers")
        #expect(Redaction.redact("qwen3:8b") == "qwen3:8b")
    }

    @Test func detailsRedactEveryStringField() {
        let details = ProblemDetails(request: RequestFacts(method: "POST", path: "/sk-ant-api03-abcdefgh/api/chat", host: "studio.local"), model: "sk-ant-api03-zzzzzzzz")
        #expect(!details.text(includeHost: true).contains("sk-ant-api03"))
        #expect(details.redacted().request?.path == "/[redacted]/api/chat")
    }

    @Test func requestFactsDropQueryAndUserInfo() {
        #expect(RequestFacts(method: "GET", url: URL(string: "http://me:secret@studio.local:11434/api/tags?key=abc")!) == RequestFacts(method: "GET", path: "/api/tags", host: "studio.local"))
    }

    @Test func detailsLinesFollowTheDocumentedOrderAndFormats() {
        let details = ProblemDetails(
            errorDomain: "D", errorCode: 7, request: RequestFacts(method: "GET", path: "/p", host: "h"),
            httpStatus: 404, engine: .claude, provider: .anthropic, model: "m", category: .modelNotFound,
            graphCode: "g", path: "f.json", account: "Work", stage: .signingIn, elapsedSeconds: 2.26,
            appVersion: "1 (2)", osVersion: "26.0", fromEarlierVersion: true
        )
        #expect(details.lines(includeHost: true) == [
            "Error: D 7", "Request: GET /p on h", "HTTP status: 404", "Engine: Claude", "Provider: Anthropic",
            "Model: m", "Category: modelNotFound", "Microsoft Graph code: g", "File: f.json", "Account: Work",
            "Stage: signing in", "Elapsed: 2.3 s", "From an earlier version of Muninn", "Muninn 1 (2) · macOS 26.0",
        ])
        #expect(ProblemDetails().lines(includeHost: true).isEmpty)
    }

    @Test func stagePhrasesAndAreas() {
        #expect(ProblemStage.writingRecap.phrase == "writing the recap")
        #expect(ProblemStage.writingRecap.area == .recap)
        #expect(ProblemStage.creatingDraft.area == .outlook)
    }

    @Test func waitNeedsYouOnlyForReasonsThatDontClear() {
        #expect(WaitReason.studioNotConfigured.needsYou && WaitReason.claudeKeyMissing.needsYou)
        #expect(!WaitReason.studioUnreachable.needsYou && !WaitReason.memoryPressure.needsYou && !WaitReason.recording.needsYou)
    }

    @Test func engineContextTakesTheModelFromSettings() {
        let context = ProblemContext.engine(.studio, settings: .defaults, stage: .writingRecap, claudeKeyPresent: false)
        #expect(context.model == "gpt-oss:20b" && context.endpointAPI == .ollama)
        #expect(ProblemContext.engine(.claude, settings: .defaults, stage: .writingRecap, claudeKeyPresent: true).model == "claude-opus-5-5")
    }

    @Test func withActionsReplacesOnlyTheActions() {
        let problem = Problems.keychainUnreadable().with(actions: [.tryAgain])
        #expect(problem.actions == [.tryAgain] && problem.title == Problems.keychainUnreadable().title)
    }

    @Test func accountProblemsCarryTheAccount() {
        #expect(Problems.signInExpired(account: "Work").details.account == "Work")
        #expect(Problems.signInFailed(account: "Work").details.account == "Work")
        #expect(Problems.calendarUnreadable(account: "Work").details.account == "Work")
    }

    @Test func regenerationFailedKeepsTheCause() {
        let cause = Problems.claudeBusy()
        let kept = Problems.regenerationFailed(cause)
        #expect(kept.title == cause.title && kept.actions == cause.actions)
        #expect(kept.explanation.hasSuffix("Muninn kept the recap you had."))
    }

    @Test func recordingTrackStoppedCapitalisesTheTrack() {
        #expect(Problems.recordingTrackStopped(track: "microphone").title == "Microphone is no longer being saved")
    }

    @Test func legacyProblemsMarkTheEarlierVersion() {
        #expect(Problems.legacyFailure().details.fromEarlierVersion)
        #expect(Problems.legacyEngineNotice().details.fromEarlierVersion)
    }
}
