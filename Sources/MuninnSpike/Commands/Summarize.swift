import ArgumentParser
import Foundation
import MuninnCore
import MuninnSystem

struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Summarize a transcript.json on one engine and write summary.json and summary.md.")

    @Argument(help: "transcript.json written by transcribe.")
    var transcript: String

    @Option(help: "Engine: macbook, studio or claude. Claude sends the transcript off this machine.")
    var engine: EngineKind

    @Option(help: "Language hint, for example nl.")
    var language: String?

    @Option(help: "LLM model name for this run, replacing the engine's model in settings (for example qwen3:30b-a3b).")
    var llmModel: String?

    @Option(help: "Meeting title given to the model.")
    var title = "Spike"

    @Option(help: ArgumentHelp(Spike.dateHelp))
    var date: String?

    @Option(help: "Output directory.")
    var out: String

    func validate() throws {
        if let date { _ = try Spike.parseDate(date) }
    }

    func run() async throws {
        let directory = try Spike.outputDirectory(out)
        let settings = Engines.settings(Spike.settings(), overridingModel: llmModel, for: engine)
        let secrets = KeychainSecrets()
        let transcriptURL = Spike.fileURL(self.transcript)
        let transcript = try Spike.readJSON(Transcript.self, from: transcriptURL)
        let callDate = try date.map(Spike.parseDate) ?? Spike.modificationDate(transcriptURL) ?? Date()
        let clean = try await RuleTranscriptCleaner().clean(transcript)

        let meeting = Meeting(
            id: MeetingID(rawValue: "spike"),
            title: title,
            startedAt: callDate,
            endedAt: nil,
            captureMode: .micOnly,
            language: language ?? transcript.language,
            accountID: nil,
            association: nil,
            client: nil,
            candidateEvents: [],
            attendees: [],
            recipients: [],
            flags: [],
            speakerNames: [:],
            status: .summarizing,
            summaryEngine: nil,
            engineNotice: nil,
            exportedNotePath: nil,
            draftWebLink: nil,
            metrics: ProcessingMetrics()
        )

        print("Summarizing \(transcript.segments.count) segments on \(Engines.describe(engine, settings: settings))")
        let summarizer = LLMSummarizer(clientFor: { try EngineClients.make($0, settings: settings, secrets: secrets) })
        let started = Date()
        let summary = try await summarizer.summarize(meeting: meeting, transcript: transcript, clean: clean, engine: engine)
        let elapsed = Date().timeIntervalSince(started)

        try Spike.writeJSON(summary, to: directory.appendingPathComponent("summary.json"))
        let markdown = Self.markdown(summary)
        try Spike.write(markdown, to: directory.appendingPathComponent("summary.md"))

        let actions = summary.subjects.reduce(0) { $0 + $1.actions.count }
        print("Subjects:  \(summary.subjects.count), action points: \(actions), language: \(summary.language)")
        print("Elapsed:   \(Spike.seconds(elapsed))")
        print("Wrote:     \(directory.path)/summary.json, summary.md")
    }

    private static func markdown(_ summary: Summary) -> String {
        let sections = summary.subjects.map { subject -> String in
            var lines = ["## \(subject.title)", ""]
            lines += subject.bullets.map { "- \($0.text) [\($0.sources.map { "S\($0)" }.joined(separator: ", "))]" }
            lines += subject.actions.map { action in
                var line = "- [ ] \(action.owner): \(action.text)"
                if let due = action.due { line += " (due \(due))" }
                return line
            }
            return lines.joined(separator: "\n")
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
}
