import ArgumentParser
import Foundation
import MuninnCore
import MuninnSpeech
import MuninnSystem

struct EndToEnd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "e2e",
        abstract: "Run the processing pipeline on a recorded folder and print per-stage seconds."
    )

    @Argument(help: "Folder holding mic.caf and, for a call, system.caf.")
    var recording: String

    @Option(help: "Summary engine: macbook, studio or claude. Claude sends the transcript off this machine.")
    var engine: EngineKind

    @Option(help: "Final model; defaults to the finalModel setting.")
    var model: SpeechModelID?

    @Option(help: "LLM model name for this run, replacing the engine's model in settings (for example qwen3:30b-a3b).")
    var llmModel: String?

    @Option(help: ArgumentHelp(Spike.dateHelp))
    var date: String?

    @Option(help: "Output directory; the processed meeting lands in <out>/store and the load samples in <out>/load.csv.")
    var out: String

    func validate() throws {
        if let date { _ = try Spike.parseDate(date) }
    }

    func run() async throws {
        let source = Spike.fileURL(recording)
        let micSource = source.appendingPathComponent("mic.caf")
        let systemSource = source.appendingPathComponent("system.caf")
        guard FileManager.default.fileExists(atPath: micSource.path) else {
            throw SpikeError("\(micSource.path) does not exist")
        }
        let hasSystem = FileManager.default.fileExists(atPath: systemSource.path)

        let directory = try Spike.outputDirectory(out)
        let store = MeetingStore(root: directory.appendingPathComponent("store", isDirectory: true))
        var settings = Engines.settings(Spike.settings(), overridingModel: llmModel, for: engine)
        if let model { settings.finalModel = model.rawValue }
        let finalModel = SpeechModelID(rawValue: settings.finalModel) ?? .parakeetV3
        let secrets = KeychainSecrets()
        let frozen = settings

        let audioSeconds = try AudioFile.duration(micSource)
        // The recording's modification time is when it ended.
        let endedAt = Spike.modificationDate(micSource) ?? Date()
        let startedAt = try date.map(Spike.parseDate) ?? endedAt.addingTimeInterval(-audioSeconds)
        var meeting = Meeting(
            id: MeetingID.make(startedAt: startedAt, title: "e2e", timeZone: .current, existing: store.existingIDs()),
            title: "End to end",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(audioSeconds),
            captureMode: hasSystem ? .call(appBundleID: "spike") : .micOnly,
            language: nil,
            accountID: nil,
            association: nil,
            client: nil,
            candidateEvents: [],
            attendees: [],
            recipients: [],
            flags: [],
            speakerNames: [:],
            status: .transcribing,
            summaryEngine: nil,
            engineNotice: nil,
            exportedNotePath: nil,
            draftWebLink: nil,
            metrics: ProcessingMetrics(),
            requestedEngine: engine
        )
        try store.create(meeting)
        try FileManager.default.copyItem(at: micSource, to: store.audioURL(meeting.id, track: .mic))
        if hasSystem {
            try FileManager.default.copyItem(at: systemSource, to: store.audioURL(meeting.id, track: .system))
        }

        let pipeline = ProcessingPipeline(
            store: store,
            settings: { frozen },
            transcriber: FixedModelTranscriber(model: finalModel),
            diarizer: FluidDiarizer(),
            cleaner: { settings, decision in
                if settings.useLLMCleanup, case .run(let engine, _, _) = decision,
                   let client = try? EngineClients.make(engine, settings: settings, secrets: secrets) {
                    return LLMTranscriptCleaner(client: client)
                }
                return RuleTranscriptCleaner()
            },
            summarizer: LLMSummarizer(clientFor: { try EngineClients.make($0, settings: frozen, secrets: secrets) }, settings: { frozen }),
            probe: LiveEnvironmentProbe(secrets: secrets)
        )

        print("Processing \(meeting.id.rawValue): \(Spike.seconds(audioSeconds)) of audio, \(hasSystem ? "call" : "mic only"), \(finalModel.rawValue), summary on \(Engines.describe(engine, settings: settings))")
        let sampler = LoadSampler()
        let sampling = sampler.runInBackground()
        let started = Date()
        await pipeline.process(meeting.id)
        let total = Date().timeIntervalSince(started)
        sampling.cancel()
        await sampling.value
        try sampler.write(to: directory.appendingPathComponent("load.csv"))

        meeting = try store.load(meeting.id)
        let metrics = meeting.metrics
        print("")
        print("Transcribe:  \(format(metrics.transcribeSeconds))")
        print("Diarize:     \(format(metrics.diarizeSeconds))")
        print("Clean:       \(format(metrics.cleanSeconds))")
        print("Summarize:   \(format(metrics.summarizeSeconds))")
        print("Total:       \(Spike.seconds(total)) (hang-up to draft, wall clock)")
        print("Status:      \(meeting.status)")
        if let notice = meeting.engineNotice { print("Notice:      \(notice)") }
        print("Output:      \(store.directory(meeting.id).path)")
        sampler.printSummary()
        print("Load:        \(directory.path)/load.csv")
    }

    private func format(_ value: Double?) -> String {
        value.map { Spike.seconds($0) } ?? "not run"
    }
}

private struct FixedModelTranscriber: Transcribing {
    let model: SpeechModelID

    func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] {
        try await TranscriberFactory.make(model).transcribe(audio: audio, track: track, vocabulary: vocabulary)
    }
}
