import ArgumentParser
import MuninnCore

@main
struct MuninnSpike: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "muninn-spike",
        abstract: "Throwaway spike and bake-off tooling for Muninn.",
        version: "muninn-spike \(MuninnVersion.current)",
        subcommands: [
            Detect.self, Record.self, Transcribe.self, Diarize.self, Live.self,
            Summarize.self, EndToEnd.self, Measure.self, WER.self,
        ]
    )
}
