import Foundation

public enum Problems {
    private static func place(_ engine: EngineKind) -> String {
        engine == .macbook ? "This Mac" : "the Network Mac"
    }

    public static func thisMacServerNotRunning(api: EndpointAPI, claudeKeyPresent: Bool, waiting: Bool, details: ProblemDetails = ProblemDetails()) -> Problem {
        let ollama = api == .ollama
        let explanation: String
        switch (waiting, ollama) {
        case (true, true): explanation = "Open Ollama and Muninn carries on within 15 seconds, or write this recap with another engine."
        case (true, false): explanation = "Start the model server and Muninn carries on within 15 seconds, or write this recap with another engine."
        case (false, true): explanation = "Muninn writes recaps on This Mac with Ollama. Open Ollama, then try again, or write this recap with another engine."
        case (false, false): explanation = "Muninn writes recaps on This Mac with its model server. Start it, then try again, or write this recap with another engine."
        }
        return Problem(
            severity: .problem,
            title: ollama ? "Ollama isn't running on This Mac" : "The model server on This Mac isn't running",
            explanation: explanation,
            actions: claudeKeyPresent ? [.writeWithClaude, .tryAgain, .engineSettings] : [.tryAgain, .engineSettings],
            details: details
        )
    }

    public static func thisMacAddressInvalid(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "This Mac's model server address isn't valid", explanation: "Fix the address in Engine settings, then try again.", actions: [.engineSettings, .tryAgain], details: details)
    }

    public static func networkMacUnreachable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The Network Mac can't be reached", explanation: "Check that it's awake and on the same network, then try again.", actions: [.tryAgain, .engineSettings], details: details)
    }

    public static func networkMacNotSetUp(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The Network Mac isn't set up", explanation: "Add its address in Engine settings, or write this recap with another engine.", actions: [.tryAgain, .engineSettings], details: details)
    }

    public static func claudeUnreachable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Claude can't be reached", explanation: "Muninn couldn't connect to Anthropic. Check the network connection and that a firewall isn't blocking Muninn, then try again.", actions: [.tryAgain, .writeOnThisMac], details: details)
    }

    public static func modelNotInstalled(model: String, engine: EngineKind, api: EndpointAPI, details: ProblemDetails = ProblemDetails()) -> Problem {
        let explanation = api == .ollama
            ? "Install it on \(place(engine)) with `ollama pull \(model)`, then try again."
            : "Install it on the model server on \(place(engine)), then try again."
        return Problem(severity: .problem, title: "The model \(model) isn't installed", explanation: explanation, actions: [.tryAgain], details: details)
    }

    public static func claudeKeyRejected(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Claude didn't accept the API key", explanation: "The key may be mistyped or revoked. Change it in Engine settings, then try again.", actions: [.changeKey, .tryAgain], details: details)
    }

    public static func claudeBusy(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Claude is busy right now", explanation: "Anthropic's servers are overloaded. Try again in a minute, or write this recap on This Mac.", actions: [.tryAgain, .writeOnThisMac], details: details)
    }

    public static func claudeKeyMissing(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "There's no Claude API key", explanation: "Add a key in Engine settings, or write this recap on This Mac.", actions: [.engineSettings, .writeOnThisMac], details: details)
    }

    public static func recapIncomplete(engine: EngineKind, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The recap came back incomplete", explanation: "\(engine.displayName)'s reply was cut off or couldn't be read. Try again, or write it with another engine.", actions: [.tryAgain, .writeWithAnotherEngine], details: details)
    }

    public static func recapRefused(engine: EngineKind, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "\(engine.displayName) declined to write this recap", explanation: "Write it with another engine.", actions: [.writeWithAnotherEngine], details: details)
    }

    public static func transcriptTooLong(model: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The transcript is too long for \(model)", explanation: "The model cut the transcript short. Write this recap on the Network Mac or with Claude.", actions: [.writeWithAnotherEngine], details: details)
    }

    public static func signInExpired(account: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Sign-in to \(account) expired", explanation: "Sign in again so Muninn can read the calendar and create drafts.", actions: [.signInAgain], details: details.with(account: account))
    }

    public static func signInFailed(account: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Sign-in to \(account) didn't finish", explanation: "Microsoft didn't accept the sign-in. Try again; if it keeps failing, copy the details.", actions: [.tryAgain], details: details.with(account: account))
    }

    public static func microsoftUnreachable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Microsoft can't be reached", explanation: "Check the network connection and that a firewall isn't blocking Muninn, then try again.", actions: [.tryAgain], details: details)
    }

    public static func outlookDraftFailed(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Outlook couldn't create the draft", explanation: "Microsoft Graph refused the request. Try again; if it keeps failing, copy the details.", actions: [.tryAgain], details: details)
    }

    public static func calendarUnreadable(account: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Muninn couldn't read the \(account) calendar", explanation: "Microsoft Graph refused the request. Muninn tries again in a minute.", actions: [.tryAgain], details: details.with(account: account))
    }

    public static func keychainUnreadable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Muninn couldn't read its saved key", explanation: "The Keychain refused access. Save the key again in Engine settings.", actions: [.engineSettings], details: details)
    }

    public static func keychainUnwritable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Muninn couldn't save to the Keychain", explanation: "The Keychain refused the change. Try again; if it keeps failing, check Muninn's items in Keychain Access.", actions: [.tryAgain], details: details)
    }

    public static func speechModelUnavailable(model: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The speech model couldn't be downloaded", explanation: "Muninn downloads \(model) the first time it's used. Check the network connection and that a firewall isn't blocking Muninn, then try again.", actions: [.tryAgain], details: details)
    }

    public static func couldNotSave(what: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Muninn couldn't save \(what)", explanation: "The disk may be full, or Muninn may not be allowed to write there. Free some space, then try again.", actions: [.tryAgain], details: details)
    }

    public static func hotkeyInUse(keys: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The shortcut \(keys) is used by another app", explanation: "Choose another shortcut in Recording settings, or quit the app that uses it.", actions: [.recordingSettings], details: details)
    }

    public static func hotkeyUnsupported(keys: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The shortcut \(keys) can't be used", explanation: "Choose another shortcut in Recording settings.", actions: [.recordingSettings], details: details)
    }

    public static func somethingWentWrong(stage: ProblemStage, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "Something went wrong while \(stage.phrase)", explanation: "Try again. If it keeps happening, copy the details and include them when you report it.", actions: [.tryAgain], details: details)
    }

    public static func legacyFailure(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "This meeting couldn't be finished", explanation: "An earlier version of Muninn stopped before it was done. Try again to finish it.", actions: [.tryAgain], details: details.with(fromEarlierVersion: true))
    }

    public static func legacyEngineNotice(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "An earlier recap attempt didn't finish", explanation: "An earlier version of Muninn kept this recap when a newer attempt didn't finish. Try again to rewrite it.", actions: [.tryAgain, .writeWithAnotherEngine], details: details.with(fromEarlierVersion: true))
    }

    public static func recordingUnreadable(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The recording couldn't be read", explanation: "Muninn quit while recording, and the audio files can't be opened.", actions: [], details: details)
    }

    public static func recordingDidNotStart(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .problem, title: "The recording didn't start", explanation: "Check that Muninn may use the microphone and record system audio in System Settings, then try again.", actions: [], details: details)
    }

    public static func recordingPartlyUnsaved(tracks: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .warning, title: "Part of the recording couldn't be saved", explanation: "The \(tracks) recording couldn't be fully written. Muninn kept the meeting; its transcript may be incomplete.", actions: [], details: details)
    }

    public static func recordingTrackStopped(track: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        let name = track.prefix(1).uppercased() + track.dropFirst()
        return Problem(severity: .problem, title: "\(name) is no longer being saved", explanation: "The rest of this recording won't include the \(track).", actions: [], details: details)
    }

    public static func noCallAudio(app: String, details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .warning, title: "No call audio for a minute", explanation: "Check that \(app) plays through This Mac and that Muninn may record system audio.", actions: [], details: details)
    }

    public static func writtenOnThisMac(because reason: WaitReason, details: ProblemDetails = ProblemDetails()) -> Problem {
        let explanation = reason == .studioNotConfigured
            ? "The Network Mac isn't set up, so This Mac wrote the recap."
            : "The Network Mac couldn't be reached, so This Mac wrote the recap."
        return Problem(severity: .warning, title: "Written on This Mac", explanation: explanation, actions: [], details: details)
    }

    public static func keptRecap(_ reason: WaitReason, api: EndpointAPI, details: ProblemDetails = ProblemDetails()) -> Problem {
        let sentence: String
        switch reason {
        case .studioUnreachable: sentence = "The Network Mac couldn't be reached"
        case .studioNotConfigured: sentence = "The Network Mac isn't set up"
        case .memoryPressure: sentence = "This Mac was short of memory"
        case .claudeKeyMissing: sentence = "There's no Claude API key"
        case .recording: sentence = "A recording was running"
        }
        return Problem(severity: .problem, title: "The recap wasn't rewritten", explanation: "\(sentence), so Muninn kept the recap you had.", actions: [.tryAgain, .writeWithAnotherEngine], details: details)
    }

    public static func regenerationFailed(_ cause: Problem) -> Problem {
        Problem(severity: .problem, title: cause.title, explanation: cause.explanation + " Muninn kept the recap you had.", actions: cause.actions, details: cause.details)
    }

    public static func diarisationDegraded(mode: CaptureMode, details: ProblemDetails = ProblemDetails()) -> Problem {
        switch mode {
        case .call:
            Problem(severity: .warning, title: "Couldn't tell the other speakers apart", explanation: "The call side of the transcript is one speaker.", actions: [], details: details)
        case .micOnly:
            Problem(severity: .warning, title: "Couldn't tell the speakers apart", explanation: "The whole conversation is one speaker in the transcript.", actions: [], details: details)
        }
    }

    public static func eventNotChanged(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .info, title: "The event wasn't changed", explanation: "A draft or a note already exists for this meeting.", actions: [], details: details)
    }

    public static func vaultNotChosen(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .warning, title: "Choose your Obsidian vault first", explanation: "Pick the vault folder in Obsidian settings, then file the recap.", actions: [], details: details)
    }

    public static func notFiledAutomatically(unsourced: Int, details: ProblemDetails = ProblemDetails()) -> Problem {
        let explanation = unsourced == 1
            ? "1 recap item has no transcript source. Check it, then file the recap."
            : "\(unsourced) recap items have no transcript source. Check them, then file the recap."
        return Problem(severity: .warning, title: "Not filed automatically", explanation: explanation, actions: [], details: details)
    }

    public static func draftWithoutLink(details: ProblemDetails = ProblemDetails()) -> Problem {
        Problem(severity: .info, title: "Draft created in Outlook", explanation: "Microsoft didn't return a link to it; find it in Outlook's Drafts.", actions: [], details: details)
    }

    public static func waiting(_ reason: WaitReason, api: EndpointAPI, claudeKeyPresent: Bool, details: ProblemDetails = ProblemDetails()) -> Problem {
        let claude: [ProblemAction] = claudeKeyPresent ? [.writeWithClaude] : []
        let title: String
        let explanation: String
        let actions: [ProblemAction]
        switch reason {
        case .studioUnreachable:
            title = "Waiting for the Network Mac"
            explanation = "It isn't answering. Muninn tries again by itself, or write this recap with another engine."
            actions = [.writeOnThisMac] + claude
        case .studioNotConfigured:
            let base = networkMacNotSetUp()
            title = base.title
            explanation = base.explanation
            actions = [.engineSettings, .writeOnThisMac] + claude
        case .memoryPressure:
            title = "Waiting for memory to free up"
            explanation = "This Mac is short of memory, so Muninn waits before running the model here."
            actions = [.writeOnThisMac] + claude
        case .claudeKeyMissing:
            let base = claudeKeyMissing()
            title = base.title
            explanation = base.explanation
            actions = base.actions
        case .recording:
            title = "Waiting for the recording to end"
            explanation = "Muninn doesn't run the model on This Mac while it records."
            actions = []
        }
        return Problem(severity: .warning, title: title, explanation: explanation, actions: actions, details: details)
    }
}

private extension ProblemDetails {
    func with(account: String) -> ProblemDetails {
        var copy = self
        copy.account = account
        return copy
    }

    func with(fromEarlierVersion: Bool) -> ProblemDetails {
        var copy = self
        copy.fromEarlierVersion = fromEarlierVersion
        return copy
    }
}
