import Foundation
import Testing
@testable import MuninnCore

@Suite struct ProblemTests {
    private let allWaitReasons: [WaitReason] = [.studioUnreachable, .studioNotConfigured, .memoryPressure, .claudeKeyMissing, .recording, .thisMacUnreachable, .claudeKeyUnreadable, .queued]

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
            Problems.couldNotDelete(what: "the meeting"),
            Problems.signedInProfileUnreadable(account: "Work"),
            Problems.signInUnreadable(account: "Work"),
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
        func key(_ suffix: String) -> String { "sk-ant-api03-\(suffix)" }
        let details = ProblemDetails(
            errorDomain: key("domainxx"),
            request: RequestFacts(method: key("methodxx"), path: "/\(key("pathxxxx"))/api/chat", host: key("hostxxxx")),
            model: key("modelxxx"),
            graphCode: key("graphxxx"),
            path: key("filexxxx"),
            account: key("accountx"),
            appVersion: key("appverxx"),
            osVersion: key("osverxxx")
        )
        let suffixes = ["domainxx", "methodxx", "pathxxxx", "hostxxxx", "modelxxx", "graphxxx", "filexxxx", "accountx", "appverxx", "osverxxx"]
        let redacted = "\(details.redacted())"
        let text = details.text(includeHost: true)
        for suffix in suffixes {
            #expect(!redacted.contains(suffix))
            #expect(!text.contains(suffix))
        }
        #expect(!text.contains("sk-ant-"))
        #expect(details.redacted().request?.path == "/[redacted]/api/chat")
    }

    @Test func redactionKeepsWordsThatMerelyEndInSk() {
        #expect(Redaction.redact("2026-11-03-1400-task-force-weekly-sync") == "2026-11-03-1400-task-force-weekly-sync")
        #expect(Redaction.redact("risk-assessment-review") == "risk-assessment-review")
        #expect(Redaction.redact("key sk-ant-api03-abcdefghijklmnop") == "key [redacted]")
        #expect(Redaction.redact("(sk-proj-abcdefghijklmnopqrstu)") == "([redacted])")
    }

    @Test func everyFactoryHasItsSeverityAndActions() {
        let cases: [(Problem, ActivityLevel, [ProblemAction])] = [
            (Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: false), .problem, [.writeWithClaude, .tryAgain, .engineSettings]),
            (Problems.thisMacServerNotRunning(api: .openAICompatible, claudeKeyPresent: false, waiting: true), .problem, [.tryAgain, .engineSettings]),
            (Problems.thisMacAddressInvalid(), .problem, [.engineSettings, .tryAgain]),
            (Problems.networkMacUnreachable(), .problem, [.tryAgain, .engineSettings]),
            (Problems.networkMacNotSetUp(), .problem, [.tryAgain, .engineSettings]),
            (Problems.claudeUnreachable(), .problem, [.tryAgain, .writeOnThisMac]),
            (Problems.modelNotInstalled(model: "m", engine: .macbook, api: .ollama), .problem, [.tryAgain]),
            (Problems.claudeKeyRejected(), .problem, [.changeKey, .tryAgain]),
            (Problems.claudeBusy(), .problem, [.tryAgain, .writeOnThisMac]),
            (Problems.claudeKeyMissing(), .problem, [.engineSettings, .writeOnThisMac]),
            (Problems.recapIncomplete(engine: .studio), .problem, [.tryAgain, .writeWithAnotherEngine]),
            (Problems.recapRefused(engine: .claude), .problem, [.writeWithAnotherEngine]),
            (Problems.transcriptTooLong(model: "m"), .problem, [.writeWithAnotherEngine]),
            (Problems.signInExpired(account: "Work"), .problem, [.signInAgain]),
            (Problems.signInFailed(account: "Work"), .problem, [.tryAgain]),
            (Problems.microsoftUnreachable(), .problem, [.tryAgain]),
            (Problems.outlookDraftFailed(), .problem, [.tryAgain]),
            (Problems.calendarUnreadable(account: "Work"), .problem, [.tryAgain]),
            (Problems.keychainUnreadable(), .problem, [.engineSettings]),
            (Problems.keychainUnwritable(), .problem, [.tryAgain]),
            (Problems.speechModelUnavailable(model: "m"), .problem, [.tryAgain]),
            (Problems.couldNotSave(what: "x"), .problem, [.tryAgain]),
            (Problems.couldNotDelete(what: "x"), .problem, [.tryAgain]),
            (Problems.signedInProfileUnreadable(account: "Work"), .problem, [.tryAgain]),
            (Problems.signInUnreadable(account: "Work"), .problem, [.signInAgain]),
            (Problems.hotkeyInUse(keys: "k"), .problem, [.recordingSettings]),
            (Problems.hotkeyUnsupported(keys: "k"), .problem, [.recordingSettings]),
            (Problems.somethingWentWrong(stage: .other), .problem, [.tryAgain]),
            (Problems.legacyFailure(), .problem, [.tryAgain]),
            (Problems.legacyEngineNotice(), .problem, [.tryAgain, .writeWithAnotherEngine]),
            (Problems.recordingUnreadable(), .problem, []),
            (Problems.recordingDidNotStart(), .problem, []),
            (Problems.recordingPartlyUnsaved(tracks: "t"), .warning, []),
            (Problems.recordingTrackStopped(track: "t"), .problem, []),
            (Problems.noCallAudio(app: "a"), .warning, []),
            (Problems.writtenOnThisMac(because: .studioUnreachable), .warning, []),
            (Problems.regenerationFailed(Problems.claudeBusy()), .problem, [.tryAgain, .writeOnThisMac]),
            (Problems.diarisationDegraded(mode: .micOnly), .warning, []),
            (Problems.diarisationDegraded(mode: .call(appBundleID: "x")), .warning, []),
            (Problems.eventNotChanged(), .info, []),
            (Problems.vaultNotChosen(), .warning, []),
            (Problems.notFiledAutomatically(unsourced: 2), .warning, []),
            (Problems.draftWithoutLink(), .info, []),
            (Problems.waiting(.studioUnreachable, api: .ollama, claudeKeyPresent: true), .warning, [.writeOnThisMac, .writeWithClaude]),
            (Problems.waiting(.studioUnreachable, api: .ollama, claudeKeyPresent: false), .warning, [.writeOnThisMac]),
            (Problems.waiting(.studioNotConfigured, api: .ollama, claudeKeyPresent: true), .warning, [.engineSettings, .writeOnThisMac, .writeWithClaude]),
            (Problems.waiting(.studioNotConfigured, api: .ollama, claudeKeyPresent: false), .warning, [.engineSettings, .writeOnThisMac]),
            (Problems.waiting(.memoryPressure, api: .ollama, claudeKeyPresent: true), .warning, [.writeOnThisMac, .writeWithClaude]),
            (Problems.waiting(.memoryPressure, api: .ollama, claudeKeyPresent: false), .warning, [.writeOnThisMac]),
            (Problems.waiting(.claudeKeyMissing, api: .ollama, claudeKeyPresent: true), .warning, [.engineSettings, .writeOnThisMac]),
            (Problems.waiting(.claudeKeyMissing, api: .ollama, claudeKeyPresent: false), .warning, [.engineSettings, .writeOnThisMac]),
            (Problems.waiting(.recording, api: .ollama, claudeKeyPresent: true), .warning, []),
            (Problems.waiting(.recording, api: .ollama, claudeKeyPresent: false), .warning, []),
            (Problems.waiting(.thisMacUnreachable, api: .ollama, claudeKeyPresent: true), .warning, [.writeWithClaude, .tryAgain, .engineSettings]),
            (Problems.waiting(.thisMacUnreachable, api: .ollama, claudeKeyPresent: false), .warning, [.tryAgain, .engineSettings]),
            (Problems.waiting(.claudeKeyUnreadable, api: .ollama, claudeKeyPresent: true), .warning, [.engineSettings, .writeOnThisMac]),
            (Problems.waiting(.queued, api: .ollama, claudeKeyPresent: true), .info, []),
        ] + allWaitReasons.map { (Problems.keptRecap($0, api: .ollama), ActivityLevel.problem, [ProblemAction.tryAgain, .writeWithAnotherEngine]) }
        for (problem, severity, actions) in cases {
            #expect(problem.severity == severity, "\(problem.title)")
            #expect(problem.actions == actions, "\(problem.title)")
        }
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
        #expect(WaitReason.thisMacUnreachable.needsYou && WaitReason.claudeKeyUnreadable.needsYou)
        #expect(!WaitReason.queued.needsYou)
    }

    @Test func newWaitsReadInPlainWords() {
        let down = Problems.waiting(.thisMacUnreachable, api: .ollama, claudeKeyPresent: false)
        #expect(down.title == "Ollama isn't running on This Mac" && down.severity == .warning)
        #expect(Problems.waiting(.thisMacUnreachable, api: .openAICompatible, claudeKeyPresent: false).title == "The model server on This Mac isn't running")
        let queued = Problems.waiting(.queued, api: .ollama, claudeKeyPresent: true)
        #expect(queued.title == "Waiting its turn")
        #expect(queued.explanation == "Muninn carries on once the meetings ahead are done.")
        #expect(Problems.keptRecap(.thisMacUnreachable, api: .ollama).explanation == "Ollama isn't running on This Mac, so Muninn kept the recap you had.")
        #expect(Problems.keptRecap(.thisMacUnreachable, api: .openAICompatible).explanation == "The model server on This Mac isn't running, so Muninn kept the recap you had.")
        #expect(Problems.keptRecap(.claudeKeyUnreadable, api: .ollama).explanation == "Muninn couldn't read the Claude key, so Muninn kept the recap you had.")
        #expect(Problems.keptRecap(.queued, api: .ollama).explanation == "Another meeting was being processed, so Muninn kept the recap you had.")
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
        #expect(Problems.signedInProfileUnreadable(account: "Work").details.account == "Work")
        #expect(Problems.signInUnreadable(account: "Work").details.account == "Work")
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
