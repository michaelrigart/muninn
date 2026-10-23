import ArgumentParser
import Foundation
import MuninnSpeech

struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tell speakers apart in one audio file and write turns.json.")

    @Argument(help: "Audio file.")
    var audio: String

    @Option(help: "Output directory.")
    var out: String

    func run() async throws {
        let url = Spike.fileURL(audio)
        let directory = try Spike.outputDirectory(out)
        let audioSeconds = try AudioFile.duration(url)

        print("Diarizing \(url.lastPathComponent) (\(Spike.seconds(audioSeconds)) of audio); the first run downloads the models")
        let started = Date()
        let turns = try await FluidDiarizer().diarize(audio: url)
        let elapsed = Date().timeIntervalSince(started)

        try Spike.writeJSON(turns, to: directory.appendingPathComponent("turns.json"))
        let speakers = Dictionary(grouping: turns, by: \.speaker).mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
        print("Turns:     \(turns.count)")
        print("Speakers:  \(speakers.count)")
        for (speaker, spoken) in speakers.sorted(by: { $0.key < $1.key }) {
            print("  \(speaker): \(Spike.seconds(spoken)) spoken")
        }
        print("Elapsed:   \(Spike.seconds(elapsed)) (includes model load)")
        print("Wrote:     \(directory.path)/turns.json")
    }
}
